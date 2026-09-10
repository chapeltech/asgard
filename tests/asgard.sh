#!/bin/sh

set -eu

SCRIPT=${1:-./asgard}
SCRIPT=$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
trap 'exit 1' HUP INT TERM
mkdir "$TMP/bin" "$TMP/master" "$TMP/slave" \
    "$TMP/master-state" "$TMP/slave-state"
TEST_LOG=$TMP/calls
TEST_STATE=$TMP/master-state
TEST_SLAVE_STATE=$TMP/slave-state
PATH="$TMP/bin:$PATH"
export TEST_LOG TEST_STATE TEST_SLAVE_STATE PATH

cat > "$TMP/bin/docker" <<'EOM'
#!/bin/sh -e
echo "docker $*" >> "$TEST_LOG"

[ "$1 $2" = "compose version" ] && exit 0
[ "$1 $2" = "compose up" ] && exit 0

if [ "$1 $2 $3 $4" = "compose exec -T kdc" ]; then
	shift 4
	case "$*" in
	true) exit 0 ;;
	'/cmd status')
		if [ -f "$TEST_STATE/restarting" ]; then
			mv "$TEST_STATE/restarting" "$TEST_STATE/ready"
			exit 1
		fi
		test -f "$TEST_STATE/ready"
		echo ready
		;;
	'/cmd setup-master EXAMPLE.COM')
		touch "$TEST_STATE/ready"
		;;
	'/cmd setup-slave EXAMPLE.COM kdc1.example.com')
		if [ -f "$TEST_STATE/configured" ]; then
			exit 0
		fi
		cat > "$TEST_STATE/ca.pem"
		echo test-bootstrap-binding
		;;
	'/cmd approve-slave EXAMPLE.COM kdc2.example.com test-bootstrap-binding')
		touch "$TEST_SLAVE_STATE/approved"
		;;
	'/cmd activate-slave')
		test -f "$TEST_STATE/approved" || exit 23
		touch "$TEST_STATE/configured" "$TEST_STATE/ready"
		;;
	'/cmd create-admin admin') echo "Created user with passwd 'test-password'" ;;
	'/cmd print-ca') echo test-public-ca ;;
	'/cmd bifrost modify_realm EXAMPLE.COM description=two words')
		test "$#" = 5
		test "$5" = 'description=two words'
		;;
	'/cmd bifrost fail') exit 23 ;;
	*) echo "unexpected docker exec: $*" >&2; exit 1 ;;
	esac
	exit
fi
echo "unexpected docker invocation: $*" >&2
exit 1
EOM

cat > "$TMP/bin/krb5_admin" <<'EOM'
#!/bin/sh -e
echo "krb5_admin $*" >> "$TEST_LOG"
case "$*" in
'-M -r EXAMPLE.COM master') echo kdc1.example.com ;;
'-M -r EXAMPLE.COM print_ca')
	printf '%s\n' '-----BEGIN CERTIFICATE-----' dGVzdA== \
	    '-----END CERTIFICATE-----'
	;;
*) exit 1 ;;
esac
EOM

cat > "$TMP/bin/bifrost" <<'EOM'
#!/bin/sh
echo "unexpected host-side bifrost: $*" >&2
exit 1
EOM

cat > "$TMP/bin/hostname" <<'EOM'
#!/bin/sh
[ "$1" = -f ] && echo kdc2.example.com
EOM

cat > "$TMP/bin/klist" <<'EOM'
#!/bin/sh
exit 0
EOM

cat > "$TMP/bin/hxtool" <<'EOM'
#!/bin/sh -e
[ "$1" = validate ]
test -s "${2#FILE:}"
EOM

chmod 755 "$TMP/bin"/*
cd "$TMP/master"
"$SCRIPT" setup-master EXAMPLE.COM kdc1.example.com
"$SCRIPT" setup-master EXAMPLE.COM kdc1.example.com
test "$("$SCRIPT" status)" = ready
test "$(grep -c ' /cmd setup-master ' "$TEST_LOG")" = 1
! grep -E '^(krb5_admin|bifrost) ' "$TEST_LOG"
grep -Fx '# asgard: setup-master EXAMPLE.COM kdc1.example.com' \
    docker-compose.yml >/dev/null
"$SCRIPT" create-admin admin > "$TMP/admin"
grep -Fx "Created user with passwd 'test-password'" "$TMP/admin"
test "$("$SCRIPT" print-ca)" = test-public-ca
"$SCRIPT" bifrost modify_realm EXAMPLE.COM 'description=two words'
RC=0
"$SCRIPT" bifrost fail || RC=$?
test "$RC" = 23

cd "$TMP/slave"
TEST_STATE=$TMP/slave-state
"$SCRIPT" setup-slave EXAMPLE.COM kdc2.example.com > "$TMP/enrollment"
grep -Fx '# asgard: setup-slave EXAMPLE.COM kdc2.example.com' \
    docker-compose.yml >/dev/null
grep -Fx '    image: ghcr.io/chapeltech/asgard:latest' docker-compose.yml
grep -Fx '    network_mode: host' docker-compose.yml
grep -Fx '    restart: unless-stopped' docker-compose.yml
grep -Fx '      - kdc:/var/heimdal' docker-compose.yml
test "$(cat .asgard-bootstrap-binding)" = test-bootstrap-binding
test -s "$TEST_STATE/ca.pem"
grep -Fx "asgard approve-slave 'EXAMPLE.COM' 'kdc2.example.com' 'test-bootstrap-binding'" \
    "$TMP/enrollment"
! grep -F ' /cmd activate-slave' "$TEST_LOG"
if "$SCRIPT" status; then
	echo 'an unapproved slave was reported ready' >&2
	exit 1
fi

RC=0
"$SCRIPT" setup-slave EXAMPLE.COM kdc2.example.com || RC=$?
test "$RC" = 23
test "$(cat .asgard-bootstrap-binding)" = test-bootstrap-binding

cd "$TMP/master"
TEST_STATE=$TMP/master-state
"$SCRIPT" approve-slave EXAMPLE.COM kdc2.example.com \
    "$(cat "$TMP/slave/.asgard-bootstrap-binding")"
cd "$TMP/slave"
TEST_STATE=$TMP/slave-state
printf '# retained operator edit\n' >> docker-compose.yml
cp docker-compose.yml "$TMP/edited.yml"
"$SCRIPT" setup-slave EXAMPLE.COM kdc2.example.com
test "$("$SCRIPT" status)" = ready
test ! -e .asgard-bootstrap-binding
"$SCRIPT" setup-slave EXAMPLE.COM
cmp docker-compose.yml "$TMP/edited.yml"

# A configured slave can still be starting after its binding has been removed.
rm "$TEST_STATE/ready"
touch "$TEST_STATE/restarting"
"$SCRIPT" setup-slave EXAMPLE.COM kdc2.example.com > "$TMP/restarted"
grep -Fx 'Asgard kdc2.example.com is ready for EXAMPLE.COM' "$TMP/restarted"
! grep -F 'approve-slave' "$TMP/restarted"
test ! -e .asgard-bootstrap-binding
test "$("$SCRIPT" status)" = ready
test "$(grep -c ' /cmd setup-slave ' "$TEST_LOG")" = 2
test "$(grep -c ' /cmd approve-slave ' "$TEST_LOG")" = 1
test "$(grep -c ' /cmd activate-slave' "$TEST_LOG")" = 2
if "$SCRIPT" setup-master OTHER.EXAMPLE kdc2.example.com; then
	echo 'setup accepted a Compose file for another realm' >&2
	exit 1
fi
cmp docker-compose.yml "$TMP/edited.yml"
echo 'Asgard host command tests passed'
