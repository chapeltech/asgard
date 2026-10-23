#!/bin/sh

set -eu

# Service wiring tests with fake commands in an isolated filesystem.
if [ "${1:-}" != inside ]; then
	ROOT=$(cd "$(dirname "$0")/.." && pwd)
	TMP=$(mktemp -d)
	trap 'rm -rf "$TMP"' EXIT
	trap 'exit 1' HUP INT TERM
	bwrap --unshare-user --unshare-pid --die-with-parent \
	    --ro-bind /usr /usr --symlink usr/bin /bin \
	    --symlink usr/lib /lib --symlink usr/lib64 /lib64 \
	    --ro-bind "$ROOT" /src --ro-bind "$ROOT/scripts" /scripts \
	    --dir /etc/krb5 --dir /var/heimdal --dir /run/asgard \
	    --bind "$TMP" /test --proc /proc --dev /dev \
	    --setenv PATH /test/bin:/usr/bin:/bin \
	    sh /src/tests/actiond.sh inside
	exit
fi

mkdir /test/bin
cat > /test/bin/hostname <<'EOF'
#!/bin/sh -e
cat /test/hostname
EOF
cat > /test/bin/sleep <<'EOF'
#!/bin/sh -e
echo "$*" >> /test/sleeps
[ "$*" != infinity ] || exit 0
exec /usr/bin/sleep "$@"
EOF
cat > /test/bin/bifrost <<'EOF'
#!/bin/sh -e
case "$*" in
actiond) echo "$*" >> /test/bifrost ;;
'-l query_config bifrostd') echo 0 ;;
*) exit 1 ;;
esac
EOF
cat > /test/bin/ipropd-master <<'EOF'
#!/bin/sh -e
echo master >> /test/ipropd
EOF
cat > /test/bin/ipropd-slave <<'EOF'
#!/bin/sh -e
echo "slave $*" >> /test/ipropd
EOF
cat > /test/bin/supervisorctl <<'EOF'
#!/bin/sh -e
echo "$*" > /test/supervisor
for arg; do
	[ ! -f "/test/stopped-$arg" ] || exit 1
done
EOF
cat > /test/bin/kinit <<'EOF'
#!/bin/sh
exit 0
EOF
cp /test/bin/kinit /test/bin/hxtool
cp /test/bin/kinit /test/bin/krb5_keytab
cat > /test/bin/tini <<'EOF'
#!/bin/sh -e
test "$*" = '-- /usr/bin/supervisord -c /etc/supervisord.conf'
test "$BIFROST_IPROP_ACL" = /run/asgard/iprop-acl
echo started > /test/supervisor-started
EOF
chmod 755 /test/bin/*
echo kdc1.example.com > /test/hostname
echo kdc1.example.com > /var/heimdal/master
echo EXAMPLE.COM > /var/heimdal/realm
ln -s /var/heimdal/master /etc/krb5/master

wait_for_file() {
	for _ in $(seq 1 50); do
		[ ! -f "$1" ] || return 0
		/usr/bin/sleep .1
	done
	echo "timed out waiting for $1" >&2
	exit 1
}

# Neither the worker nor readiness can run before setup completes.
timeout 10 /scripts/asgard-actiond &
pid=$!
wait_for_file /test/sleeps
test ! -e /test/bifrost
if /scripts/asgard-status; then
	echo 'unconfigured master reported ready' >&2
	exit 1
fi
test ! -e /test/supervisor
touch /var/heimdal/setup.done
wait "$pid"
test "$(cat /test/bifrost)" = actiond
echo 'worker waits for setup and runs on the master: passed'

rm /test/bifrost /test/sleeps
echo kdc2.example.com > /test/hostname
/scripts/asgard-actiond
test ! -e /test/bifrost
test "$(cat /test/sleeps)" = infinity
echo 'slave never invokes the worker: passed'

mv /var/heimdal/master /test/master
if /scripts/asgard-actiond; then
	echo 'worker ignored missing master identity' >&2
	exit 1
fi
test ! -e /test/bifrost
mv /test/master /var/heimdal/master

echo kdc1.example.com > /test/hostname
rm /test/sleeps
timeout 10 /scripts/ipropd &
pid=$!
wait_for_file /test/sleeps
test ! -e /test/ipropd
if /scripts/asgard-status; then
	echo 'master without initial ACL reported ready' >&2
	exit 1
fi
touch /run/asgard/iprop-acl
wait "$pid"
test "$(cat /test/ipropd)" = master
echo 'master iprop waits for the initial ACL, including an empty ACL: passed'

rm /run/asgard/iprop-acl /test/ipropd /test/sleeps
echo kdc2.example.com > /test/hostname
/scripts/ipropd
test ! -e /test/sleeps
test "$(cat /test/ipropd)" = \
    'slave -k FILE:/etc/krb5.keytab kdc1.example.com'
echo 'slave iprop does not wait for a local ACL: passed'

touch /test/stopped-asgard-actiond
date +%s > /var/heimdal/admin-sync.time
test "$(/scripts/asgard-status)" = ready
if grep -q asgard-actiond /test/supervisor; then
	echo 'slave readiness checked the action worker' >&2
	exit 1
fi
echo kdc1.example.com > /test/hostname
touch /run/asgard/iprop-acl
if /scripts/asgard-status; then
	echo 'master with a stopped worker reported ready' >&2
	exit 1
fi
grep -q asgard-actiond /test/supervisor
rm /test/stopped-asgard-actiond
test "$(/scripts/asgard-status)" = ready
touch /test/stopped-ipropd
if /scripts/asgard-status; then
	echo 'master with stopped iprop reported ready' >&2
	exit 1
fi
echo 'readiness requires the worker only on the master: passed'

# Redirect only the final exec so the real startup path cannot launch services.
sed 's|/usr/bin/tini|/test/bin/tini|' /src/scripts/cmd > /test/cmd
cp /src/etc/inetd.conf /etc/inetd.conf
echo stale > /run/asgard/iprop-acl
sh -e /test/cmd start-kdc
test -f /test/supervisor-started
test ! -e /run/asgard/iprop-acl
grep -q '^#bifrost' /etc/inetd.conf
rm /test/supervisor-started
echo kdc2.example.com > /test/hostname
echo slave > /run/asgard/iprop-acl
sh -e /test/cmd start-kdc
test -f /test/supervisor-started
test "$(cat /run/asgard/iprop-acl)" = slave
echo 'startup invalidates only the master ACL and keeps HTTPS disabled: passed'

sed -n '/^\[program:asgard-actiond\]/,/^$/p' \
    /src/etc/supervisord.conf > /test/program
for setting in command=/scripts/asgard-actiond autorestart=true \
    autostart=true stopasgroup=true killasgroup=true; do
	grep -Fx "$setting" /test/program
done
echo 'Supervisor owns the worker and its child processes: passed'
