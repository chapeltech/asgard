#!/bin/sh

set -eu

# Usage: tests/action-queue.sh [KDC_IMAGE [DEBIAN_IMAGE [ROCKY_IMAGE]]]
# Run only after the review KDC/client images are ready. Never builds or pulls.
# Requires Docker with privileged systemd containers/cgroups, jq and timeout.
# KDC access is exclusively through appliance/operator APIs, except for the
# deliberate Supervisor worker stop/start. No HTTP or explicit client fetches.
usage() {
	echo "usage: $0 [KDC_IMAGE [DEBIAN_IMAGE [ROCKY_IMAGE]]]"
}
case "${1:-}" in
-h|--help) usage; exit 0 ;;
esac
[ "$#" -le 3 ] || { usage >&2; exit 2; }
KDC_IMAGE=${1:-asgard/kdc:action-queue-review}
DEBIAN_IMAGE=${2:-asgard/client:action-queue-review}
ROCKY_IMAGE=${3:-asgard/rocky96-public:latest}
for COMMAND in docker jq timeout; do
	command -v "$COMMAND" >/dev/null 2>&1 || {
		echo "action-queue: missing $COMMAND" >&2
		exit 1
	}
done
for IMAGE in "$KDC_IMAGE" "$DEBIAN_IMAGE" "$ROCKY_IMAGE"; do
	timeout 15 docker image inspect "$IMAGE" >/dev/null || {
		echo "action-queue: image not ready: $IMAGE (coordinate with image builder)" >&2
		exit 1
	}
done

umask 077
WORK=$(mktemp -d /tmp/asgard-action-queue.XXXXXX)
NETWORK=$(basename "$WORK" | tr '[:upper:].' '[:lower:]-')
VOLUME=$NETWORK-kdc
MASTER=$NETWORK-master
DEBIAN=$NETWORK-debian
ROCKY=$NETWORK-rocky
REALM=ACTION-QUEUE.EXAMPLE
MASTER_HOST=kdc.action-queue.example
DEBIAN_HOST=debian.action-queue.example
ROCKY_HOST=rocky96.action-queue.example
CLUSTER=cluster.action-queue.example
CLIENT_PATH=/usr/lib/asgard/bin:/usr/lib/asgard/sbin:/usr/lib/asgard/libexec:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
CREATED=
NETWORK_CREATED=0
VOLUME_CREATED=0
PHASE=provisioning

fail() {
	echo "action-queue: $*" >&2
	exit 1
}

admin() {
	timeout -k 2 15 docker exec "$MASTER" timeout -k 1 12 \
	    /cmd bifrost -J "$@"
}

client() {
	BOX=$1
	shift
	timeout -k 2 180 docker exec "$BOX" timeout -k 1 175 "$@"
}

cleanup() {
	RC=$?
	trap - EXIT HUP INT TERM
	set +e
	if [ "$RC" != 0 ]; then
		echo "action-queue: failed during $PHASE" >&2
		admin list_actions action_type=deliver_prestash >&2
		for ID in $CREATED; do
			timeout 10 docker logs --tail 80 "$ID" >&2
		done
		for BOX in "$DEBIAN" "$ROCKY"; do
			timeout 10 docker exec "$BOX" journalctl --no-pager -n 80 \
			    -u krb5-hostd.service -u krb5-hostd-knc.service >&2
		done
	fi
	# IDs and uniquely named resources below belong only to this invocation.
	for ID in $CREATED; do
		timeout 30 docker rm -f -v "$ID" >/dev/null
	done
	[ "$VOLUME_CREATED" = 0 ] || timeout 30 docker volume rm "$VOLUME" >/dev/null
	[ "$NETWORK_CREATED" = 0 ] || timeout 30 docker network rm "$NETWORK" >/dev/null
	rm -rf "$WORK"
	exit "$RC"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

# The outer deadline includes all polling commands, not just the sleeps.
wait_for() {
	DESCRIPTION=$1
	shift
	if timeout -k 2 180 sh -c '
		log=$1
		shift
		until timeout -k 1 15 "$@" > "$log" 2>&1; do sleep 1; done
	' sh "$WORK/poll.log" "$@"; then
		return 0
	fi
	cat "$WORK/poll.log" >&2
	fail "timed out after 180s: $DESCRIPTION"
}

wait_action() {
	wait_for "action $1: $2" docker exec "$MASTER" sh -ec '
		result=$(timeout 10 /cmd bifrost -J query_action "$1")
		printf "%s\n" "$result"
		printf "%s\n" "$result" | jq -e "$2" >/dev/null
	' sh "$1" "$2"
	# Preserve the exact API observation, including the failure retry deadline.
	cp "$WORK/poll.log" "$WORK/action.json"
}

delivery_id() {
	admin list_actions action_type=deliver_prestash target_type=host \
	    "target_name=$1" > "$WORK/actions.json"
	jq -er --argjson previous "$2" '
	    map(select(.action_id > $previous)) |
	    if length == 1 then .[0].action_id
	    else error("expected exactly one new delivery action") end
	' "$WORK/actions.json"
}

last_action_id() {
	admin list_actions action_type=deliver_prestash > "$WORK/actions.json"
	jq -er 'map(.action_id) | max // 0' "$WORK/actions.json"
}

worker() {
	timeout -k 2 30 docker exec "$MASTER" timeout 25 \
	    supervisorctl -c /etc/supervisord.conf "$1" asgard-actiond
}

assert_absent() {
	client "$1" sh -ec '
		test ! -e "/var/spool/tickets/$1"
		test ! -e "/var/spool/certs/$1"
	' sh "$2"
}

assert_queued() {
	admin query_action "$1" > "$WORK/action.json"
	jq -e '.state == "queued" and .attempts == 0 and .not_before == null' \
	    "$WORK/action.json"
}

assert_https_off() {
	test "$(admin query_config bifrostd)" = 0
	client "$DEBIAN" perl -MIO::Socket::INET -e '
		die "KDC DNS unavailable\n" unless gethostbyname($ARGV[0]);
		die "optional Bifrost HTTPS listener is enabled\n"
		    if IO::Socket::INET->new(PeerAddr => $ARGV[0],
		        PeerPort => 3666, Timeout => 2);
	' "$MASTER_HOST"
}

verify_delivery() {
	wait_for "$1 credentials for $2" docker exec "$1" sh -ec '
		test -s "/var/spool/tickets/$1"
		test -s "/var/spool/certs/$1"
	' sh "$2"
	# Run as the recipient: this also tests ownership/readability of both files.
	timeout -k 2 90 docker exec --user "$2" "$1" timeout -k 1 85 sh -ec '
		user=$1 realm=$2 master=$3
		principal=$user@$realm
		cert=PEM-FILE:/var/spool/certs/$user
		cache=$(klist --json -c "FILE:/var/spool/tickets/$user")
		printf "%s\n" "$cache" | jq -e --arg p "$principal" \
		    ".principal == \$p and .expired == false"
		kgetcred -c "FILE:/var/spool/tickets/$user" "host/$master@$realm"

		hxtool verify --missing-revoke "cert:$cert" \
		    "chain:$cert" anchor:PEM-FILE:/etc/krb5/ca-pub.pem

		# A fresh cache proves the delivered private key/certificate work for PKINIT.
		export KRB5CCNAME=FILE:/tmp/$user-pkinit.ccache
		rm -f "/tmp/$user-pkinit.ccache"
		timeout 30 kinit -C "$cert" "$principal"
		cache=$(klist --json)
		printf "%s\n" "$cache" | jq -e --arg p "$principal" \
		    ".principal == \$p and .expired == false"
		kgetcred "host/$master@$realm"
		kdestroy
	' sh "$2" "$REALM" "$MASTER_HOST"
	client "$1" sh -ec '
		for unit in krb5-hostd.service krb5-hostd-knc.service; do
			systemctl is-active --quiet "$unit"
		done
		for unit in krb5-prestash-refresh.service krb5-prestash-refresh.timer; do
			test "$(systemctl show --property=LoadState --value "$unit")" = masked
		done
	'
	echo "action-queue: $1 received and used $2 tickets and certificate chain"
}

provision_client() {
	BOX=$1
	HOST=$2
	IMAGE=$3
	PHASE="systemd enrollment of $HOST"
	# Docker supplies the writable, namespaced cgroup mount for privileged
	# containers; binding the host hierarchy breaks private cgroups on this host.
	ID=$(timeout 30 docker create --name "$BOX" --network "$NETWORK" \
	    --network-alias "$HOST" --hostname "$HOST" \
	    --tty --privileged --cgroupns private --security-opt label=disable \
	    --tmpfs /run --tmpfs /run/lock \
	    --stop-signal SIGRTMIN+3 -e SYSTEMD_COLORS=0 \
	    -e container=docker -e PATH="$CLIENT_PATH" -e LC_ALL=C \
	    -e KRB5_CONFIG=/etc/krb5.conf \
	    --entrypoint /usr/lib/systemd/systemd "$IMAGE" --log-target=console)
	CREATED="$CREATED $ID"
	timeout 30 docker start "$BOX" >/dev/null
	wait_for "$BOX systemd" docker exec "$BOX" sh -ec '
		test "$(cat /proc/1/comm)" = systemd
		systemctl show --property=Version --value >/dev/null
	'
	# Disable scheduled and boot-time fetches before enrolling/assigning tickets.
	client "$BOX" systemctl mask --now \
	    krb5-prestash-refresh.service krb5-prestash-refresh.timer
	client "$BOX" sh -ec '
		mkdir -p /etc/krb5 /var/spool/tickets /var/spool/certs
		for user in aq-auto aq-queued aq-retry aq-cluster; do
			useradd --system --no-create-home --shell /bin/sh "$user"
		done
		: > /etc/krb5/krb5_admind.conf
	'
	timeout 15 docker cp "$WORK/krb5.conf" "$BOX:/etc/krb5.conf"
	timeout 15 docker cp "$WORK/ca.pem" "$BOX:/etc/krb5/ca-pub.pem"
	timeout 15 docker cp "$WORK/krb5_hostd.conf" "$BOX:/etc/krb5/krb5_hostd.conf"
	admin create_host "$HOST" "realm=$REALM"
	BINDING=$(client "$BOX" krb5_keytab bootstrap/RANDOM)
	test -n "$BINDING"
	admin bind_host "$HOST" "$BINDING"
	client "$BOX" krb5_keytab
	client "$BOX" sh -ec '
		unitdir=/usr/lib/systemd/system
		for unit in krb5-hostd.target krb5-hostd.socket krb5-hostd.service \
		    krb5-hostd-knc.socket krb5-hostd-knc.service; do
			path=$(systemctl show --property=FragmentPath --value "$unit")
			test "$(readlink -f "$path")" = "$unitdir/$unit"
			test -z "$(systemctl show --property=DropInPaths --value "$unit")"
		done
		systemctl is-enabled --quiet krb5-hostd.target
		systemctl stop krb5-hostd-knc.service krb5-hostd.service
		systemctl start krb5-hostd.target
		for unit in krb5-hostd.target krb5-hostd.socket krb5-hostd-knc.socket; do
			systemctl is-active --quiet "$unit"
		done
		test -S /run/krb5_hostd
	'
}

echo "action-queue: isolated master=$MASTER Debian=$DEBIAN_IMAGE Rocky=$ROCKY_IMAGE"
timeout 30 docker network create --internal "$NETWORK" >/dev/null
NETWORK_CREATED=1
timeout 30 docker volume create "$VOLUME" >/dev/null
VOLUME_CREATED=1
ID=$(timeout 30 docker create --name "$MASTER" --network "$NETWORK" \
    --network-alias "$MASTER_HOST" --hostname "$MASTER_HOST" \
    -v "$VOLUME:/var/heimdal" --entrypoint /cmd "$KDC_IMAGE" start-kdc)
CREATED="$CREATED $ID"
timeout 30 docker start "$MASTER" >/dev/null
timeout -k 2 180 docker exec "$MASTER" timeout -k 1 175 /cmd setup-master "$REALM"
wait_for 'master appliance readiness' docker exec "$MASTER" /cmd status
timeout 15 docker exec "$MASTER" /cmd print-ca > "$WORK/ca.pem"
test -s "$WORK/ca.pem"
cat > "$WORK/krb5.conf" <<EOM
[libdefaults]
	default_realm = $REALM
	rdns = false
	dns_lookup_kdc = false
	dns_lookup_realm = false
	pkinit_anchors = FILE:/etc/krb5/ca-pub.pem
[realms]
	$REALM = {
		kdc = $MASTER_HOST
		kpasswd_server = $MASTER_HOST
	}
[domain_realm]
	.action-queue.example = $REALM
EOM
cat > "$WORK/krb5_hostd.conf" <<'EOM'
do "/etc/krb5/krb5_keytab.conf" or die $@ || $!;
$tixdir = ["/var/spool/tickets"];
$certdir = ["/var/spool/certs"];
$use_fetch = 1;
1;
EOM
chmod 644 "$WORK/ca.pem" "$WORK/krb5.conf" "$WORK/krb5_hostd.conf"
provision_client "$DEBIAN" "$DEBIAN_HOST" "$DEBIAN_IMAGE"
provision_client "$ROCKY" "$ROCKY_HOST" "$ROCKY_IMAGE"
assert_https_off
timeout -k 2 30 docker exec "$MASTER" timeout 25 /cmd create-admin queue-admin >/dev/null
for APP in aq-auto aq-queued aq-retry aq-cluster; do
	admin create_appid "$APP"
done

PHASE='automatic insert_ticket delivery'
PREVIOUS=$(last_action_id)
assert_absent "$DEBIAN" aq-auto
assert_absent "$ROCKY" aq-auto
admin insert_ticket "aq-auto@$REALM" "$DEBIAN_HOST"
admin insert_ticket "aq-auto@$REALM" "$ROCKY_HOST"
DEBIAN_ACTION=$(delivery_id "$DEBIAN_HOST" "$PREVIOUS")
ROCKY_ACTION=$(delivery_id "$ROCKY_HOST" "$PREVIOUS")
wait_action "$DEBIAN_ACTION" '.state == "done" and .attempts == 1'
wait_action "$ROCKY_ACTION" '.state == "done" and .attempts == 1'
verify_delivery "$DEBIAN" aq-auto
verify_delivery "$ROCKY" aq-auto

PHASE='stopped worker queues prompt mutations and restart drains'
worker stop
PREVIOUS=$(last_action_id)
START=$(date +%s)
admin insert_ticket "aq-queued@$REALM" "$DEBIAN_HOST"
admin insert_ticket "aq-queued@$REALM" "$ROCKY_HOST"
echo "action-queue: stopped-worker mutations returned in $(($(date +%s) - START))s (15s limit each)"
DEBIAN_ACTION=$(delivery_id "$DEBIAN_HOST" "$PREVIOUS")
ROCKY_ACTION=$(delivery_id "$ROCKY_HOST" "$PREVIOUS")
assert_queued "$DEBIAN_ACTION"
assert_queued "$ROCKY_ACTION"
sleep 7
assert_queued "$DEBIAN_ACTION"
assert_queued "$ROCKY_ACTION"
assert_absent "$DEBIAN" aq-queued
assert_absent "$ROCKY" aq-queued
worker start
# From here through credential checks there are no administrative mutations.
wait_action "$DEBIAN_ACTION" '.state == "done" and .attempts == 1'
wait_action "$ROCKY_ACTION" '.state == "done" and .attempts == 1'
verify_delivery "$DEBIAN" aq-queued
verify_delivery "$ROCKY" aq-queued

PHASE='offline client first failure and automatic 60-second retry'
assert_absent "$ROCKY" aq-retry
PREVIOUS=$(last_action_id)
timeout 30 docker stop --time 10 "$ROCKY" >/dev/null
admin insert_ticket "aq-retry@$REALM" "$ROCKY_HOST"
RETRY_ACTION=$(delivery_id "$ROCKY_HOST" "$PREVIOUS")
wait_action "$RETRY_ACTION" '
    .state == "failed" and .attempts == 1 and
    (.last_error | type == "string" and length > 0) and
    .not_before == (.updated_at + 60)'
RETRY_AT=$(jq -er .not_before "$WORK/action.json")
cat "$WORK/action.json"
admin list_actions state=failed action_type=deliver_prestash \
    "target_name=$ROCKY_HOST" > "$WORK/actions.json"
jq -e --argjson id "$RETRY_ACTION" --argjson at "$RETRY_AT" '
    any(.[]; .action_id == $id and .attempts == 1 and .not_before == $at
        and (.last_error | length > 0))' "$WORK/actions.json"
timeout 30 docker start "$ROCKY" >/dev/null
# No retry_action, refresh_ticket, keytab call or fetch after recovery.
wait_action "$RETRY_ACTION" ".state == \"done\" and .attempts == 2 and
    .completed_at >= $RETRY_AT and .last_error == null"
verify_delivery "$ROCKY" aq-retry
echo 'action-queue: failed delivery was visible and retried after its 60s deadline'

PHASE='logical-host membership enqueues both client deliveries'
admin create_logical_host "$CLUSTER" "owner=queue-admin@$REALM"
worker stop
PREVIOUS=$(last_action_id)
admin insert_ticket "aq-cluster@$REALM" "$CLUSTER"
# There are no members yet: assigning the ticket alone cannot deliver it.
admin list_actions action_type=deliver_prestash > "$WORK/actions.json"
jq -e --argjson previous "$PREVIOUS" \
    'all(.[]; .action_id <= $previous)' "$WORK/actions.json"
# Exercise modify_host's membership slow path, not only insert_hostmap.
admin modify_host "$CLUSTER" "member+=$DEBIAN_HOST"
admin modify_host "$CLUSTER" "member+=$ROCKY_HOST"
admin query_hostmap "$CLUSTER" > "$WORK/hostmap.json"
jq -e --arg a "$DEBIAN_HOST" --arg b "$ROCKY_HOST" \
    'sort == ([$a, $b] | sort)' "$WORK/hostmap.json"
DEBIAN_ACTION=$(delivery_id "$DEBIAN_HOST" "$PREVIOUS")
ROCKY_ACTION=$(delivery_id "$ROCKY_HOST" "$PREVIOUS")
test "$DEBIAN_ACTION" != "$ROCKY_ACTION"
assert_queued "$DEBIAN_ACTION"
assert_queued "$ROCKY_ACTION"
assert_absent "$DEBIAN" aq-cluster
assert_absent "$ROCKY" aq-cluster
worker start
wait_action "$DEBIAN_ACTION" '.state == "done" and .attempts == 1'
wait_action "$ROCKY_ACTION" '.state == "done" and .attempts == 1'
verify_delivery "$DEBIAN" aq-cluster
verify_delivery "$ROCKY" aq-cluster
assert_https_off
wait_for 'final master appliance readiness' docker exec "$MASTER" /cmd status
echo 'action-queue: all appliance acceptance checks passed'
