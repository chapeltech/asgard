#!/bin/sh

set -eu

for test in							\
    /tests/admin-principals.sh					\
    /tests/admin-appids.sh					\
    /tests/admin-subjects.sh					\
    /tests/admin-hosts.sh					\
    /tests/admin-sacls.sh					\
    /tests/admin-features.sh					\
    /tests/admin-principal-map.sh				\
    /tests/admin-tickets.sh					\
    /tests/admin-owners.sh					\
    /tests/admin-concurrency.sh				\
    /tests/bifrost-parity.sh
do
	echo
	echo "===== $test"
	/bin/sh "$test"
done
