#!/bin/sh -e

set -eu

# Run the real SQLite and rsync programs in an isolated filesystem.
if [ "${1-}" != inside ]; then
	ROOT=$(cd "$(dirname "$0")/.." && pwd)
	SQLITE3=${SQLITE3:-$(command -v sqlite3)}
	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT
	trap 'exit 1' HUP INT TERM
	bwrap --unshare-user --unshare-pid --die-with-parent \
	    --ro-bind /usr /usr --symlink usr/bin /bin \
	    --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
	    --ro-bind /etc/passwd /etc/passwd --ro-bind /etc/group /etc/group \
	    --ro-bind "$ROOT" /src --ro-bind "$SQLITE3" /sqlite3 \
	    --dir /var/heimdal --dir /run/asgard --dir /scripts \
	    --bind "$TMP" /test --proc /proc --dev /dev \
	    --setenv PATH /test/bin:/usr/bin:/bin \
	    sh /src/tests/admin-sync.sh inside
	exit
fi

mkdir -p /test/bin /test/source /var/heimdal/admin-sync
# The unprivileged namespace cannot switch to the image's root uid/gid.
sed -e '/^uid = root$/d' -e '/^gid = root$/d' \
    /src/etc/rsyncd.conf > /etc/rsyncd.conf
ln -s /sqlite3 /test/bin/sqlite3
for file in asgard-admin-sync asgard-rsync asgard-install-admin-db; do
	ln -s "/src/scripts/$file" "/scripts/$file"
done
cat > /scripts/asgard-install-certificates <<'EOF'
#!/bin/sh -e
[ ! -f /test/certificate-failure ]
for file in kdc-priv.pem kx509-priv.pem realms; do
	cmp "$1/$file" "/test/source/$file"
done
echo installed >> /test/certificates
EOF
cat > /cmd <<'EOF'
#!/bin/sh -e
[ "$*" = reconcile ]
[ ! -f /test/reconcile-failure ]
echo reconciled >> /test/reconciled
EOF
cat > /test/bin/timeout <<'EOF'
#!/bin/sh
if [ -f /test/short-timeout ]; then
	shift 3
	exec /usr/bin/timeout -k 1 1 "$@"
fi
exec /usr/bin/timeout "$@"
EOF
chmod 755 /cmd /scripts/asgard-install-certificates /test/bin/timeout

DB=/var/heimdal/krb5_admin.db
SOURCE=/test/source/krb5_admin.db.bak
MARKER=/var/heimdal/admin-sync.time
STATUS=/var/heimdal/admin-sync/receive.status
echo kdc1.example.com > /var/heimdal/master
echo EXAMPLE.COM > /var/heimdal/realm
echo kdc > /test/source/kdc-priv.pem
echo issuer > /test/source/kx509-priv.pem
echo EXAMPLE.COM > /test/source/realms
export KNC_CREDS=iprop/kdc1.example.com@EXAMPLE.COM
export RSYNC_CONNECT_PROG=/scripts/asgard-rsync

sqlite3 "$SOURCE" '
CREATE TABLE realms(realm TEXT, kind TEXT, master TEXT);
CREATE TABLE hosts(name TEXT, realm TEXT);
CREATE TABLE realm_kdcs(realm TEXT, host TEXT);
CREATE TABLE payload(value TEXT);
INSERT INTO realms VALUES ("EXAMPLE.COM", "local", "kdc1.example.com");
INSERT INTO hosts VALUES ("kdc1.example.com", "EXAMPLE.COM");
INSERT INTO payload VALUES ("first");'
sqlite3 "$DB" 'CREATE TABLE unseeded(value TEXT);'

push() {
	rm -f "$STATUS"
	rsync -a /test/source/ slave::krb5_admin/ > /test/transfer.log 2>&1 || true
	for i in $(seq 1 100); do
		if [ -f "$STATUS" ] && ! grep -q receiving "$STATUS"; then
			return
		fi
		sleep .1
	done
	cat /test/transfer.log >&2
	echo 'receiver did not finish' >&2
	exit 1
}

expect_failure() {
	old=$(sqlite3 "$DB" 'SELECT value FROM payload')
	echo 1 > "$MARKER"
	push
	grep -q failed "$STATUS"
	[ "$(cat "$MARKER")" = 1 ]
	[ "$(sqlite3 "$DB" 'SELECT value FROM payload')" = "$old" ]
}

push
if ! grep -q applied "$STATUS"; then
	cat /test/transfer.log /var/heimdal/admin-sync/receive.error >&2
	exit 1
fi
test -s "$MARKER"
[ "$(sqlite3 "$DB" 'SELECT value FROM payload')" = first ]
test ! -e /test/reconciled
touch /var/heimdal/setup.done
echo 'initial import over an unseeded database: passed'

# Keep a WAL read transaction open across the next import.
mkfifo /test/sqlite.in
sqlite3 "$DB" < /test/sqlite.in > /test/sqlite.out &
reader=$!
exec 8> /test/sqlite.in
printf '%s\n' 'PRAGMA journal_mode=WAL;' 'BEGIN;' \
    'SELECT value FROM payload;' '.shell touch /test/reader-ready' >&8
while [ ! -f /test/reader-ready ]; do sleep .1; done
inode=$(stat -c %i "$DB")
sqlite3 "$SOURCE" 'UPDATE payload SET value = "second"'
push
grep -q applied "$STATUS"
[ "$(stat -c %i "$DB")" = "$inode" ]
printf '%s\n' 'SELECT value FROM payload;' 'COMMIT;' \
    'SELECT value FROM payload;' '.quit' >&8
exec 8>&-
wait "$reader"
printf 'wal\nfirst\nfirst\nsecond\n' > /test/expected
cmp /test/expected /test/sqlite.out
echo 'open WAL reader retains its snapshot and sees new state after commit: passed'

cp "$SOURCE" /test/good.db
echo not-a-database > "$SOURCE"
expect_failure
cp /test/good.db "$SOURCE"
sqlite3 "$SOURCE" 'DROP TABLE hosts'
expect_failure
cp /test/good.db "$SOURCE"
echo 'corrupt database and missing schema preserve the live database: passed'

mv /test/source/realms /test/saved-realms
sqlite3 "$SOURCE" 'UPDATE payload SET value = "incomplete"'
expect_failure
mv /test/saved-realms /test/source/realms
cp /test/good.db "$SOURCE"
echo 'incomplete file set cannot import the database: passed'

export KNC_CREDS=iprop/other.example.com@EXAMPLE.COM
expect_failure
export KNC_CREDS=iprop/kdc1.example.com@EXAMPLE.COM
sqlite3 "$DB" 'UPDATE realms SET master = "new.example.com"'
expect_failure
sqlite3 "$DB" 'UPDATE realms SET master = "kdc1.example.com"'
echo 'validated policy supersedes bootstrap authorization: passed'

rm "$MARKER"
sqlite3 "$SOURCE" 'UPDATE realms SET realm = "WRONG.EXAMPLE"'
push
grep -q failed "$STATUS"
test ! -e "$MARKER"
cp /test/good.db "$SOURCE"
push
grep -q applied "$STATUS"
echo 'initial policy must match the persisted bootstrap realm and master: passed'

touch /test/certificate-failure
expect_failure
rm /test/certificate-failure
touch /test/reconcile-failure
push
grep -q 'failed reconcile' "$STATUS"
[ "$(cat "$MARKER")" != 1 ]
rm /test/reconcile-failure
echo 'certificate failure blocks the marker; reconciliation failure stays visible: passed'

# A busy writer forces the bounded restore path to fail without replacement.
sqlite3 "$DB" < /test/sqlite.in > /test/writer.out &
writer=$!
exec 8> /test/sqlite.in
printf '%s\n' 'BEGIN IMMEDIATE;' '.shell touch /test/writer-ready' >&8
while [ ! -f /test/writer-ready ]; do sleep .1; done
touch /test/short-timeout
expect_failure
printf '%s\n' 'ROLLBACK;' '.quit' >&8
exec 8>&-
wait "$writer"
rm /test/short-timeout
push
grep -q applied "$STATUS"
[ "$(stat -c %i "$DB")" = "$inode" ]
echo 'bounded busy-writer failure and subsequent retry: passed'

# Exercise one push round, including stalls in both kinit and its transport.
cat > /scripts/asgard-certificates <<'EOF'
#!/bin/sh
echo /test/source
EOF
cat > /test/bin/hostname <<'EOF'
#!/bin/sh
echo kdc1.example.com
EOF
cat > /test/bin/bifrost <<'EOF'
#!/bin/sh
case "$*" in
'-l search_realm kind=local') echo EXAMPLE.COM ;;
'-J -l query_realm EXAMPLE.COM')
	echo '{"master":"kdc1.example.com","kdc":["good.example.com","bad.example.com","slow-kinit.example.com","slow-knc.example.com"]}'
	;;
*) exit 1 ;;
esac
EOF
cat > /test/bin/kinit <<'EOF'
#!/bin/sh
case "$KRB5CCNAME" in
*bad.example.com) exit 7 ;;
*slow-kinit.example.com) exec /usr/bin/sleep 100 ;;
esac
EOF
cat > /test/bin/rsync <<'EOF'
#!/bin/sh -e
[ "$#" = 7 ]
[ "$1 $2" = '--timeout=30 -a' ]
[ "$3" = /var/heimdal/krb5_admin.db.bak ]
[ "$4 $5 $6" = '/test/source/kdc-priv.pem /test/source/kx509-priv.pem /test/source/realms' ]
case "$7" in
slow-knc.example.com::krb5_admin/)
	knc &
	wait
	;;
good.example.com::krb5_admin/) exit 0 ;;
*) exit 1 ;;
esac
EOF
cat > /test/bin/knc <<'EOF'
#!/bin/sh
echo $$ > /test/knc.pid
exec /usr/bin/sleep 100
EOF
cat > /test/bin/sleep <<'EOF'
#!/bin/sh
[ "$1" = 30 ] || exec /usr/bin/sleep "$@"
if [ -f /test/round-started ]; then
	kill -TERM "$PPID"
else
	touch /test/round-started
fi
EOF
chmod 755 /scripts/asgard-certificates /test/bin/hostname /test/bin/bifrost \
    /test/bin/kinit /test/bin/rsync /test/bin/knc /test/bin/sleep
touch /test/short-timeout /run/asgard/certificates.changed
echo 1 > /var/heimdal/admin-sync/push-bad.example.com.last-success
before=$(wc -l < /test/reconciled)
if /scripts/asgard-admin-sync; then
	echo 'sender ignored termination after its first round' >&2
	exit 1
fi
grep -q failed /var/heimdal/admin-sync/push.status
grep -q transferred /var/heimdal/admin-sync/push-good.example.com.status
test -s /var/heimdal/admin-sync/push-good.example.com.last-success
grep -q 'failed 7' /var/heimdal/admin-sync/push-bad.example.com.status
[ "$(cat /var/heimdal/admin-sync/push-bad.example.com.last-success)" = 1 ]
for host in slow-kinit slow-knc; do
	grep -q 'failed 124' "/var/heimdal/admin-sync/push-$host.example.com.status"
done
test ! -e "/proc/$(cat /test/knc.pid)"
test -z "$(find /run/asgard -name 'krb5cc-admin-sync.*' -print)"
[ "$(wc -l < /test/reconciled)" -eq "$((before + 1))" ]
echo 'parallel destinations, bounded kinit/knc, collected failures and self renewal: passed'
