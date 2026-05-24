#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name conc)
nprocs=5
nitems=8
pids=
failed=0

cleanup() {
	i=1
	while [ "$i" -le "$nprocs" ]; do
		j=1
		while [ "$j" -le "$nitems" ]; do
			cleanup_host "$prefix-$i-$j.example.com"
			j=$((j + 1))
		done
		i=$((i + 1))
	done
}
trap cleanup EXIT

worker() {
	i=$1
	j=1

	while [ "$j" -le "$nitems" ]; do
		bifrost create_host "$prefix-$i-$j.example.com" \
		    realm="$REALM" >/dev/null
		j=$((j + 1))
	done
}

i=1
while [ "$i" -le "$nprocs" ]; do
	worker "$i" &
	pids="$pids $!"
	i=$((i + 1))
done

for pid in $pids; do
	if ! wait "$pid"; then
		failed=1
	fi
done

if [ "$failed" = 0 ]; then
	pass "concurrent create_host workers"
else
	fail "concurrent create_host workers"
fi

i=1
while [ "$i" -le "$nprocs" ]; do
	j=1
	while [ "$j" -le "$nitems" ]; do
		host="$prefix-$i-$j.example.com"
		if ! bifrost -J query_host "$host" >/dev/null; then
			fail "concurrent host $host exists"
		fi
		j=$((j + 1))
	done
	i=$((i + 1))
done

pass "concurrent hosts are queryable"

finish_tests
