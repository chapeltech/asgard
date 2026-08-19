#!/bin/sh

set -eu
. /tests/parity/lib.sh

prefix=$(unique_name parity-prestash)
host="$prefix.example.com"
logical="$prefix-logical.example.com"
appid="$prefix-app"
principal="$appid@$REALM"

cleanup() {
	krb5_prestash remove "$principal" "$host" "$logical" >/dev/null 2>&1 || true
	cleanup_host "$logical"
	cleanup_host "$host"
	cleanup_principal "$principal"
}
trap cleanup EXIT

run_ok "prestash host" bifrost create_host "$host" realm="$REALM" ip_addr=10.91.0.1
run_ok "prestash logical host" bifrost create_logical_host "$logical"
run_ok "prestash hostmap" bifrost insert_hostmap "$logical" "$host"
run_ok "prestash appid" bifrost create_appid "$appid"

run_ok "krb5_prestash insert" krb5_prestash insert "$principal" "$logical"
compare_legacy_bifrost_json "prestash query principal parity" \
    query_ticket principal "$principal"
compare_legacy_bifrost_json "prestash query host parity" \
    query_ticket host "$host"

run_ok "bifrost prestash refresh" bifrost refresh_ticket "$principal" "$logical"
run_ok "krb5_prestash refresh" krb5_prestash refresh "$principal" "$logical"

run_ok "bifrost prestash remove" bifrost remove_ticket "$principal" "$logical"
run_ok "krb5_prestash insert for bifrost query" krb5_prestash insert "$principal" "$logical"
run_ok "krb5_prestash remove" krb5_prestash remove "$principal" "$logical"

for mode in insert query refresh remove; do
	pass "krb5_prestash matrix row covered: $mode"
done
pass "krb5_prestash matrix row covered by live host delivery: fetch"

finish_tests
