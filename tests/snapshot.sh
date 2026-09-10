#!/bin/sh

set -eu

SCRIPT=${1:-scripts/asgard-snapshot}
TMP=$(mktemp -d)
capture=
promotion=
cleanup() {
	[ -z "$capture" ] || kill "$capture" 2>/dev/null || :
	[ -z "$promotion" ] || kill "$promotion" 2>/dev/null || :
	wait 2>/dev/null || :
	rm -rf "$TMP"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM

mkdir "$TMP/bin" "$TMP/heimdal"
sed "s|/var/heimdal|$TMP/heimdal|g" "$SCRIPT" > "$TMP/snapshot"
SNAPS=$TMP/heimdal/snaps
export TEST_TMP=$TMP TEST_GENERATION=one TZ=UTC
export TEST_CP=$(command -v cp) TEST_MV=$(command -v mv)
export TEST_DATE=$(command -v date)

# Substitute database tools, but exercise the real lock and filesystem updates.
cat > "$TMP/bin/bifrost" <<'EOF'
#!/bin/sh -e
test "$1 $2" = '-l backup_hdb'
echo "hdb $TEST_GENERATION" >> "$TEST_TMP/calls"
printf '%s\n' "$TEST_GENERATION" > "$3"
if [ "${TEST_BLOCK:-}" = yes ]; then
	touch "$TEST_TMP/entered"
	read -r release < "$TEST_TMP/release"
fi
test "${TEST_FAIL:-}" != hdb
EOF

cat > "$TMP/bin/sqlite3" <<'EOF'
#!/bin/sh -e
test "$1" = -readonly
test "$2" = "$TEST_TMP/heimdal/krb5_admin.db"
test "$3" = '.timeout 60000'
echo "admin $TEST_GENERATION" >> "$TEST_TMP/calls"
dst=${4#".backup "}
printf '%s\n' "$TEST_GENERATION" > "$dst"
test "${TEST_FAIL:-}" != sqlite
if [ "${TEST_FAIL:-}" = interrupt ]; then
	kill -TERM "$PPID"
	exit 1
fi
if [ "${TEST_FAIL:-}" = empty ]; then
	: > "$dst"
fi
EOF

cat > "$TMP/bin/date" <<'EOF'
#!/bin/sh
case "$*" in
+%H)	echo 00 ;;
+%w)	echo 0 ;;
+%U)	echo 36 ;;
*)	exec "$TEST_DATE" "$@" ;;
esac
EOF

cat > "$TMP/bin/cp" <<'EOF'
#!/bin/sh -e
if [ "${TEST_FAIL:-}" = copy ]; then
	"$TEST_CP" "$1" "$3"
	exit 1
fi
exec "$TEST_CP" "$@"
EOF

cat > "$TMP/bin/mv" <<'EOF'
#!/bin/sh -e
test "${TEST_FAIL:-}" != publish
exec "$TEST_MV" "$@"
EOF

chmod 755 "$TMP/bin/"*
PATH="$TMP/bin:$PATH"
export PATH

snapshot() {
	sh -e "$TMP/snapshot" "$@"
}

pair() {
	test "$(cat "$SNAPS/$1/heimdal.db")" = "$2"
	test "$(cat "$SNAPS/$1/krb5_admin.db")" = "$2"
}

fails() {
	if snapshot "$1" > "$TMP/error" 2>&1; then
		echo "snapshot $1 unexpectedly succeeded" >&2
		exit 1
	fi
	grep -F "asgard-snapshot: $1 failed" "$TMP/error" >/dev/null
}

snapshot hourly
pair hourly/00 one
old=$(readlink "$SNAPS/hourly/00")
success=$(cat "$SNAPS/hourly/last-success")
test -n "$success"
snapshot daily
snapshot weekly
pair daily/0 one
pair weekly/36 one
test "$(wc -l < "$TMP/calls")" -eq 2

export TEST_GENERATION=two
for failure in hdb sqlite empty publish interrupt; do
	TEST_FAIL=$failure fails hourly
	pair hourly/00 one
	test "$(readlink "$SNAPS/hourly/00")" = "$old"
	test "$(cat "$SNAPS/hourly/last-success")" = "$success"
	test "$(find "$SNAPS/hourly" -type d | wc -l)" -eq 2
done

snapshot hourly
pair hourly/00 two
test ! -e "$SNAPS/hourly/$old"
TEST_FAIL=copy fails daily
pair daily/0 one
snapshot daily
pair daily/0 two
TEST_FAIL=copy fails weekly
pair weekly/36 one
snapshot weekly
pair weekly/36 two

touch -d yesterday "$SNAPS/hourly/00/last-success"
fails daily
pair daily/0 two
touch -d yesterday "$SNAPS/daily/0/last-success"
fails weekly
pair weekly/36 two

# A promotion must wait until the capture has published its complete pair.
mkfifo "$TMP/release"
timeout 10 env TEST_BLOCK=yes TEST_GENERATION=three \
    sh -e "$TMP/snapshot" hourly > "$TMP/hourly-log" 2>&1 &
capture=$!
for attempt in $(seq 1 100); do
	[ ! -e "$TMP/entered" ] || break
	sleep 0.01
done
test -e "$TMP/entered"
timeout 10 sh -e "$TMP/snapshot" daily > "$TMP/daily-log" 2>&1 &
promotion=$!
sleep 0.1
pair hourly/00 two
pair daily/0 two
kill -0 "$promotion"
printf 'release\n' > "$TMP/release"
wait "$capture"
wait "$promotion"
capture=
promotion=
pair hourly/00 three
pair daily/0 three
test -s "$SNAPS/daily/last-success"

echo 'snapshot tests passed'
