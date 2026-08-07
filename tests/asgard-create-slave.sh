#!/bin/sh

set -eu

SCRIPT=${1:-./asgard-create-slave}
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
	"test -s /var/heimdal/krb5.conf.d/EXAMPLE_COM.conf")
		test -f "$TEST_STATE/configured"
		;;
	"/cmd setup-slave EXAMPLE.COM kdc1.example.com")
		cat >/dev/null
		touch "$TEST_STATE/configured"
		;;
		"krb5_keytab bootstrap/RANDOM")
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
*" ca")
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

chmod 755 "$STUBS"/*
cd "$TMP"

TEST_LOG=$LOG TEST_STATE=$STATE ASGARD_IMAGE=local/asgard:test \
    PATH="$STUBS:$PATH" "$SCRIPT" EXAMPLE.COM

grep -Fx '# asgard-create-slave: EXAMPLE.COM kdc2.example.com' \
    docker-compose.yml >/dev/null
grep -Fx '    image: local/asgard:test' docker-compose.yml >/dev/null
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

TEST_LOG=$LOG TEST_STATE=$STATE ASGARD_IMAGE=local/asgard:test \
    PATH="$STUBS:$PATH" "$SCRIPT" EXAMPLE.COM

test "$(grep -c ' bind_host ' "$LOG")" = 1
