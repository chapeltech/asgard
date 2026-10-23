#!/bin/sh

set -eu

# Usage: tests/appliance.sh [KDC_IMAGE [CLIENT_IMAGE]]
# Both images must contain the appliance changes under review.
if [ "${1:-}" != --driver ]; then
	[ "$#" -le 2 ] || exit 2
	KDC_IMAGE=${1:-asgard/kdc}
	CLIENT_IMAGE=${2:-asgard/client}
	# Container recreation must use the same build even if a tag moves mid-test.
	KDC_IMAGE=$(docker image inspect --format '{{.Id}}' "$KDC_IMAGE")
	CLIENT_IMAGE=$(docker image inspect --format '{{.Id}}' "$CLIENT_IMAGE")
	printf 'Appliance images: KDC=%s CLIENT=%s\n' "$KDC_IMAGE" "$CLIENT_IMAGE"
	ROOT=$(cd "$(dirname "$0")/.." && pwd)
	DOCKER=$(command -v docker)
	DOCKER=$(readlink -f "$DOCKER")
	COMPOSE=
	for DIR in "${DOCKER_CONFIG:-$HOME/.docker}/cli-plugins" \
	    /usr/local/lib/docker/cli-plugins /usr/local/libexec/docker/cli-plugins \
	    /usr/lib/docker/cli-plugins /usr/libexec/docker/cli-plugins; do
		if [ -x "$DIR/docker-compose" ]; then
			COMPOSE=$(readlink -f "$DIR/docker-compose")
			break
		fi
	done
	[ -n "$COMPOSE" ] || { echo 'Docker Compose plugin not found' >&2; exit 1; }
	test -S /var/run/docker.sock
	WORK=$(mktemp -d /tmp/asgard-appliance.XXXXXX)
	NETWORK=$(basename "$WORK" | tr '[:upper:].' '[:lower:]-')
	DRIVER=$NETWORK-driver
	CLIENT=$NETWORK-client
	NETWORK_CREATED=0
	DRIVER_CREATED=0

	cleanup() {
		RC=$?
		trap - EXIT HUP INT TERM
		set +e
		if docker container inspect "$CLIENT" >/dev/null 2>&1; then
			[ "$RC" = 0 ] || docker logs "$CLIENT" >&2
			docker rm -f "$CLIENT" >/dev/null
		fi
		for NODE in master slave; do
			[ -f "$WORK/$NODE/docker-compose.yml" ] || continue
			if [ "$RC" != 0 ]; then
				docker compose -p "$NETWORK-$NODE" \
				    -f "$WORK/$NODE/docker-compose.yml" logs --no-color >&2
			fi
			docker compose -p "$NETWORK-$NODE" \
			    -f "$WORK/$NODE/docker-compose.yml" down -v --remove-orphans
		done
		if [ "$DRIVER_CREATED" = 1 ]; then
			docker exec "$DRIVER" sh -c 'rm -rf "$1"/* "$1"/.[!.]*' sh "$WORK"
			docker rm -f "$DRIVER" >/dev/null
		fi
		[ "$NETWORK_CREATED" = 0 ] || docker network rm "$NETWORK" >/dev/null
		rm -rf "$WORK"
		exit "$RC"
	}
	trap cleanup EXIT
	trap 'exit 1' HUP INT TERM
	docker network create "$NETWORK" >/dev/null
	NETWORK_CREATED=1
	docker run -d --name "$DRIVER" --network "$NETWORK" \
	    --hostname admin.appliance.example --security-opt label=disable \
	    -v /var/run/docker.sock:/var/run/docker.sock:ro \
	    -v "$DOCKER:/usr/local/bin/docker:ro" \
	    -v "$COMPOSE:/usr/local/lib/docker/cli-plugins/docker-compose:ro" \
	    -v "$ROOT:/src:ro" -v "$WORK:$WORK" \
	    --entrypoint /bin/sleep "$CLIENT_IMAGE" infinity >/dev/null
	DRIVER_CREATED=1
	docker exec "$DRIVER" timeout 900 /bin/sh /src/tests/appliance.sh \
	    --driver "$WORK" "$NETWORK" "$KDC_IMAGE" "$CLIENT_IMAGE"
	exit 0
fi

WORK=$2
NETWORK=$3
KDC_IMAGE=$4
CLIENT_IMAGE=$5
REALM=APPLIANCE.EXAMPLE
MASTER=kdc1.appliance.example
SLAVE=kdc2.appliance.example
ASGARD=/src/asgard
umask 077
mkdir "$WORK/master" "$WORK/slave"
chmod 755 "$WORK/master" "$WORK/slave"

# Only the Docker topology differs from an operator's generated Compose file.
for NODE in master slave; do
	HOST=$MASTER
	[ "$NODE" = master ] || HOST=$SLAVE
	cat > "$WORK/$NODE/docker-compose.yml" <<EOM
# asgard: setup-$NODE $REALM $HOST
name: $NETWORK-$NODE
services:
  kdc:
    image: $KDC_IMAGE
    hostname: $HOST
    command: start-kdc
    restart: unless-stopped
    volumes:
      - kdc:/var/heimdal
    networks:
      default:
        aliases:
          - $HOST
volumes:
  kdc:
networks:
  default:
    external: true
    name: $NETWORK
EOM
	chmod 644 "$WORK/$NODE/docker-compose.yml"
	cat > "$WORK/$NODE.conf" <<EOM
[libdefaults]
	default_realm = $REALM
	rdns = false
	dns_lookup_kdc = false
	dns_lookup_realm = false
	ignore-acceptor-hostname = true
	pkinit_anchors = FILE:$WORK/ca.pem
[realms]
	$REALM = {
		kdc = tcp/$HOST
		kpasswd_server = $HOST
	}
[domain_realm]
	.appliance.example = $REALM
EOM
done
export KRB5_CONFIG=$WORK/master.conf KRB5CCNAME=FILE:$WORK/admin.ccache

cd "$WORK/master"
"$ASGARD" setup-master "$REALM" "$MASTER"
"$ASGARD" status
"$ASGARD" print-ca > "$WORK/ca.pem"
hxtool validate "FILE:$WORK/ca.pem"
"$ASGARD" create-admin admin > "$WORK/admin-created"
sed -n "s/^Created user with passwd '\(.*\)'$/\1/p" \
    "$WORK/admin-created" > "$WORK/initial-password"
test -s "$WORK/initial-password"

# Complete create-admin's normal password change, without altering its flags.
printf '%s\n' 'Appliance-test-9!changed' > "$WORK/password"
cat "$WORK/password" "$WORK/password" > "$WORK/change-password"
timeout 30 kinit --password-file="$WORK/initial-password" "admin@$REALM" \
    < "$WORK/change-password"
kdestroy
timeout 30 kinit --password-file="$WORK/password" "admin@$REALM"
krb5_admin -h "$MASTER" create_subject "before-enrollment@$REALM" type=krb5
krb5_admin -M -r "$REALM" print_ca > "$WORK/remote-ca.pem"
cmp "$WORK/ca.pem" "$WORK/remote-ca.pem"

cd "$WORK/slave"
"$ASGARD" setup-slave "$REALM" "$SLAVE" > "$WORK/enrollment"
test -s .asgard-bootstrap-binding
grep -F 'asgard approve-slave ' "$WORK/enrollment"
if "$ASGARD" status; then
	echo 'slave is ready before approval' >&2
	exit 1
fi
if KRB5_CONFIG=$WORK/slave.conf KRB5CCNAME=FILE:$WORK/unapproved.ccache \
    timeout 10 kinit --password-file="$WORK/password" "admin@$REALM"; then
	echo 'slave issued a ticket before approval and propagation' >&2
	exit 1
fi

cd "$WORK/master"
"$ASGARD" approve-slave "$REALM" "$SLAVE" \
    "$(cat "$WORK/slave/.asgard-bootstrap-binding")"
cd "$WORK/slave"
"$ASGARD" setup-slave "$REALM" "$SLAVE"
test ! -e .asgard-bootstrap-binding

# The worker tests use only appliance commands and action-query APIs on KDCs.
( . /src/tests/appliance-actions.sh )

for PASS in initial recreated; do
	if [ "$PASS" = recreated ]; then
		(
			cd "$WORK/master"
			docker compose up -d --force-recreate
			"$ASGARD" setup-master "$REALM" "$MASTER"
		)
		docker compose up -d --force-recreate
		"$ASGARD" setup-slave "$REALM" "$SLAVE"
	fi
	"$ASGARD" status
	# Each request below has only the slave configured, with a fresh ccache.
	export KRB5_CONFIG=$WORK/slave.conf KRB5CCNAME=FILE:$WORK/client.ccache
	rm -f "$WORK/client.ccache" "$WORK/issued.pem"
	timeout 30 kinit -r 1h --password-file="$WORK/password" "admin@$REALM"
	kgetcred "host/$SLAVE@$REALM"
	kinit -R
	klist
	IPROP_PRINCIPAL=iprop-$PASS@$REALM
	(
		cd "$WORK/master"
		"$ASGARD" bifrost create "$IPROP_PRINCIPAL"
	)
	for _ in $(seq 1 30); do
		if kgetcred "$IPROP_PRINCIPAL"; then
			break
		fi
		sleep 1
	done
	kgetcred "$IPROP_PRINCIPAL"
	krb5_admin -J -h "$SLAVE" query_subject "before-enrollment@$REALM" \
	    > "$WORK/subject.json"
	jq -e '.type == "krb5"' "$WORK/subject.json"
	KRB5_CONFIG=$WORK/master.conf KRB5CCNAME=FILE:$WORK/admin.ccache \
	    krb5_admin -h "$MASTER" create_subject "after-$PASS@$REALM" type=krb5
	for TRY in $(seq 1 60); do
		if krb5_admin -J -h "$SLAVE" query_subject "after-$PASS@$REALM" \
		    > "$WORK/subject.json" &&
		    jq -e '.type == "krb5"' "$WORK/subject.json" >/dev/null; then
			break
		fi
		sleep 1
	done
	jq -e '.type == "krb5"' "$WORK/subject.json"
	printf '%s\n' "$REALM" > "$WORK/realms"
	RC=0
	RSYNC_CONNECT_PROG='knc iprop@%H 4666' timeout 10 rsync --timeout=5 \
	    "$WORK/realms" "$SLAVE::krb5_admin/" > "$WORK/rejected-rsync.log" 2>&1 || RC=$?
	cat "$WORK/rejected-rsync.log"
	case "$RC" in
	0|124|137) echo 'expected replication authorization rejection' >&2; exit 1 ;;
	esac
	"$ASGARD" status
	kdestroy
	timeout 30 kinit -n "@$REALM"
	klist
	kdestroy
	timeout 30 kinit --password-file="$WORK/password" "admin@$REALM"
	heimtools kx509 -o "PEM-FILE:$WORK/issued.pem"
	hxtool verify --missing-revoke \
	    "cert:FILE:$WORK/issued.pem" "chain:FILE:$WORK/issued.pem" \
	    "anchor:FILE:$WORK/ca.pem"
	kdestroy
	timeout 30 kinit -C "PEM-FILE:$WORK/issued.pem" "admin@$REALM"
	kgetcred "host/$SLAVE@$REALM"
	kdestroy
	export KRB5_CONFIG=$WORK/master.conf KRB5CCNAME=FILE:$WORK/admin.ccache
done

# Neither setup nor approval should have enabled the optional HTTP daemon.
perl -MIO::Socket::INET -e '
	for my $host (@ARGV) {
		die "bifrostd is listening on $host\n" if IO::Socket::INET->new(
		    PeerAddr => $host, PeerPort => 3666, Timeout => 2);
	}
' "$MASTER" "$SLAVE"
echo 'Master/slave appliance acceptance passed'
