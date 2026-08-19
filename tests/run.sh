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
    /tests/bifrost-parity.sh					\
    /tests/parity/manifest.sh					\
    /tests/parity/krb5-admin-matrix.sh				\
    /tests/parity/krb5-prestash-matrix.sh			\
    /tests/parity/krb5-keytab-matrix.sh
do
	echo
	echo "===== $test"
	/bin/sh "$test"
done
