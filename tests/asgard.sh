#!/bin/sh

set -eu

SCRIPT=${1:-./asgard}
SCRIPT=$(cd "$(dirname "$SCRIPT")" && pwd)/$(basename "$SCRIPT")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
STUBS=$TMP/bin
STATE=$TMP/state
LOG=$TMP/calls
mkdir "$STUBS" "$STATE"

cat > "$STUBS/docker" <<'EOM'
#!/bin/sh
echo "docker $*" >> "$TEST_LOG"

[ "$1 $2" = "compose version" ] && exit 0
[ "$1 $2" = "compose up" ] && exit 0

if [ "$1 $2 $3 $4" = "compose exec -T kdc" ]; then
	shift 4
	case "$*" in
	true)	exit 0 ;;
	"test -f /var/heimdal/setup.done")
		test -f "$TEST_STATE/setup.done"
		;;
	"/cmd setup-master EXAMPLE.COM")
		touch "$TEST_STATE/setup.done"
		;;
	"/cmd setup-slave EXAMPLE.COM kdc1.example.com")
		cat >/dev/null
		echo test-bootstrap-binding
		;;
		"/cmd activate-slave")
			touch "$TEST_STATE/setup.done"
			;;
	*)	echo "unexpected docker exec: $*" >&2; exit 1 ;;
	esac
	exit
fi

echo "unexpected docker invocation: $*" >&2
exit 1
EOM

cat > "$STUBS/krb5_admin" <<'EOM'
#!/bin/sh
echo "krb5_admin $*" >> "$TEST_LOG"
case "$*" in
*" master")	echo kdc1.example.com ;;
*" print_ca")
	cat <<'EOF'
-----BEGIN CERTIFICATE-----
dGVzdA==
-----END CERTIFICATE-----
EOF
	;;
*)	exit 1 ;;
esac
EOM

cat > "$STUBS/bifrost" <<'EOM'
#!/bin/sh
echo "bifrost $*" >> "$TEST_LOG"
case "$*" in
*" query_host "*)	exit 1 ;;
*)			exit 0 ;;
esac
EOM

cat > "$STUBS/hostname" <<'EOM'
#!/bin/sh
[ "$1" = -f ] && echo kdc2.example.com
EOM

cat > "$STUBS/klist" <<'EOM'
#!/bin/sh
exit 0
EOM

cat > "$STUBS/hxtool" <<'EOM'
#!/bin/sh
[ "$1" = validate ]
EOM

chmod 755 "$STUBS"/*
cd "$TMP"

TEST_LOG=$LOG TEST_STATE=$STATE PATH="$STUBS:$PATH" \
    "$SCRIPT" setup-slave EXAMPLE.COM

grep -Fx '# asgard: setup-slave EXAMPLE.COM kdc2.example.com' \
    docker-compose.yml >/dev/null
grep -Fx '    image: ghcr.io/chapeltech/asgard:latest' \
    docker-compose.yml >/dev/null
grep -Fx '    network_mode: host' docker-compose.yml >/dev/null
grep -Fx '    restart: unless-stopped' docker-compose.yml >/dev/null
grep -Fx '      - kdc:/var/heimdal' docker-compose.yml >/dev/null
grep -Fx \
    'bifrost -M -r EXAMPLE.COM modify_realm EXAMPLE.COM kdc+=kdc2.example.com' \
    "$LOG" >/dev/null
grep -Fx \
    'bifrost -M -r EXAMPLE.COM bind_host kdc2.example.com test-bootstrap-binding' \
    "$LOG" >/dev/null
test -f "$STATE/setup.done"
test ! -e .asgard-bootstrap-binding

TEST_LOG=$LOG TEST_STATE=$STATE PATH="$STUBS:$PATH" \
    "$SCRIPT" setup-slave EXAMPLE.COM

test "$(grep -c ' bind_host ' "$LOG")" = 1

mkdir "$TMP/master" "$TMP/master-state"
cd "$TMP/master"
TEST_LOG=$TMP/master-calls TEST_STATE=$TMP/master-state PATH="$STUBS:$PATH" \
    "$SCRIPT" setup-master EXAMPLE.COM kdc1.example.com
grep -Fx '# asgard: setup-master EXAMPLE.COM kdc1.example.com' \
    docker-compose.yml >/dev/null
grep -Fx '    hostname: kdc1.example.com' docker-compose.yml >/dev/null
grep -Fx 'docker compose exec -T kdc /cmd setup-master EXAMPLE.COM' \
    "$TMP/master-calls" >/dev/null
! grep -E '^(krb5_admin|bifrost) ' "$TMP/master-calls"
