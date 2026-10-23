# Sourced by appliance.sh after master/slave enrollment.

set -eu

action_compose() (
	cd "$WORK/$1"
	shift
	docker compose "$@"
)

action_admin() (
	cd "$WORK/$1"
	shift
	"$ASGARD" bifrost "$@"
)

action_supervisor() {
	action_compose "$1" exec -T kdc supervisorctl \
	    -c /etc/supervisord.conf "$2" asgard-actiond
}

action_wait() {
	for _ in $(seq 1 120); do
		if action_admin "$1" -J query_action "$2" \
		    > "$WORK/action.json" &&
		    jq -e "$3" "$WORK/action.json" >/dev/null; then
			return
		fi
		sleep 1
	done
	cat "$WORK/action.json" >&2
	echo "action $2 did not reach expected state on $1: $3" >&2
	exit 1
}

action_assert_pending() {
	action_admin "$1" -J query_action "$ACTION_ID" > "$WORK/action.json"
	jq -e '.state == "queued" and .attempts == 0' "$WORK/action.json"
}

action_assert_no_tickets() {
	if docker exec --user www-data "$CLIENT" \
	    klist -c FILE:/var/spool/tickets/www-data; then
		echo 'client received tickets while the master worker was stopped' >&2
		exit 1
	fi
}

action_check_tickets() {
	# Client credentials are checked by use, never by reading KDC key material.
	for _ in $(seq 1 30); do
		if docker exec --user www-data "$CLIENT" \
		    klist -c FILE:/var/spool/tickets/www-data \
		    > "$WORK/client-tickets" 2> "$WORK/client-tickets.error"; then
			break
		fi
		sleep 1
	done
	if ! grep -F "www-data@$REALM" "$WORK/client-tickets"; then
		cat "$WORK/client-tickets.error" >&2
		echo 'delivered client tickets could not be used' >&2
		exit 1
	fi
	docker exec --user www-data "$CLIENT" timeout 30 kinit \
	    -c FILE:/tmp/action-test.ccache \
	    -C PEM-FILE:/var/spool/certs/www-data "www-data@$REALM"
	docker exec --user www-data "$CLIENT" \
	    kgetcred -c FILE:/tmp/action-test.ccache \
	    "host/$SLAVE@$REALM"
}

CLIENT=$NETWORK-client
CLIENT_HOST=client.appliance.example
echo 'Enrolling the appliance action client'
docker run -d --name "$CLIENT" --network "$NETWORK" \
    --network-alias "$CLIENT_HOST" --hostname "$CLIENT_HOST" \
    --entrypoint /cmd "$CLIENT_IMAGE" start-client >/dev/null
docker exec -i "$CLIENT" sh -ec 'cat > /etc/krb5.conf' <<EOM
[libdefaults]
	default_realm = $REALM
	rdns = false
	pkinit_anchors = FILE:/etc/krb5/ca-pub.pem
[realms]
	$REALM = {
		kdc = $MASTER
		kpasswd_server = $MASTER
	}
EOM
docker cp "$WORK/ca.pem" "$CLIENT:/etc/krb5/ca-pub.pem"
docker exec "$CLIENT" chmod 644 /etc/krb5/ca-pub.pem
docker exec -i "$CLIENT" sh -ec 'cat > /etc/krb5/krb5_hostd.conf' <<'EOM'
do "/etc/krb5/krb5_keytab.conf" or die $@ || $!;
$tixdir = ["/var/spool/tickets"];
$certdir = ["/var/spool/certs"];
$use_fetch = 1;
1;
EOM
docker exec "$CLIENT" sh -ec ': > /etc/krb5/krb5_admind.conf'
action_admin master create_host "$CLIENT_HOST" "realm=$REALM"
CLIENT_BINDING=$(docker exec "$CLIENT" krb5_keytab bootstrap/RANDOM)
krb5_admin -h "$MASTER" bind_host "$CLIENT_HOST" "$CLIENT_BINDING"
docker exec "$CLIENT" krb5_keytab
action_admin master create_appid www-data "owner=admin@$REALM"

action_supervisor master stop
if (cd "$WORK/master" && "$ASGARD" status); then
	echo 'master with a stopped worker reported ready' >&2
	exit 1
fi
test "$(action_admin master query_config bifrostd)" = 0
test "$(action_admin slave query_config bifrostd)" = 0
timeout 15 "$ASGARD" bifrost query_realm "$REALM" >/dev/null
# Both local Bifrost and remote legacy administration return without a worker.
(
	cd "$WORK/master"
	timeout 15 "$ASGARD" bifrost insert_ticket "www-data@$REALM" "$CLIENT_HOST"
)
timeout 15 krb5_admin -h "$MASTER" refresh_ticket "www-data@$REALM" "$CLIENT_HOST"
action_admin master -J list_actions action_type=deliver_prestash \
    "target_name=$CLIENT_HOST" > "$WORK/actions.json"
ACTION_ID=$(jq -er '
    map(select(.state == "queued" and .attempts == 0)) |
    if length == 1 then .[0].action_id else error("expected one queued action") end
' "$WORK/actions.json")

# Administrative replication copies the queue, but a slave must not claim it.
action_wait slave "$ACTION_ID" '.state == "queued" and .attempts == 0'
for _ in $(seq 1 7); do
	sleep 1
	action_assert_pending slave
done
action_assert_pending master
action_assert_no_tickets
action_compose slave up -d --force-recreate
(cd "$WORK/slave" && "$ASGARD" setup-slave "$REALM" "$SLAVE")
for _ in $(seq 1 7); do
	sleep 1
	action_assert_pending slave
done
action_assert_no_tickets
action_supervisor slave stop
(cd "$WORK/slave" && "$ASGARD" status)
action_supervisor slave start
echo 'stopped worker leaves admin calls available; recreated slave does not consume copied actions'

# Starting the worker is the only change; no new mutation wakes the queue.
action_supervisor master start
action_wait master "$ACTION_ID" '.state == "done" and .attempts == 1'
action_check_tickets
(cd "$WORK/master" && "$ASGARD" status)
echo 'worker restart drains existing work without another mutation'

docker exec "$CLIENT" rm -f /var/spool/tickets/www-data /var/spool/certs/www-data
docker stop "$CLIENT" >/dev/null
timeout 15 krb5_admin -h "$MASTER" refresh_ticket "www-data@$REALM" "$CLIENT_HOST"
action_admin master -J list_actions action_type=deliver_prestash \
    "target_name=$CLIENT_HOST" > "$WORK/actions.json"
PREVIOUS_ACTION_ID=$ACTION_ID
ACTION_ID=$(jq -er 'max_by(.action_id).action_id' "$WORK/actions.json")
test "$ACTION_ID" -gt "$PREVIOUS_ACTION_ID"
action_wait master "$ACTION_ID" \
    '.state == "failed" and .attempts >= 1 and .last_error != null and .not_before != null'
FAILED_ATTEMPTS=$(jq -r .attempts "$WORK/action.json")
docker start "$CLIENT" >/dev/null
# In particular, do not call retry_action or refresh_ticket after recovery.
action_wait master "$ACTION_ID" ".state == \"done\" and .attempts > $FAILED_ATTEMPTS"
action_check_tickets
echo 'unavailable client is retried automatically after recovery'
