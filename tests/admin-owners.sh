#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name owner)
normal="$prefix-user@$REALM"
normal_cc="$TEST_TMP/normal.ccache"
host1="$prefix-1.example.com"
host2="$prefix-2.example.com"
logical="$prefix-logical.example.com"
group="$prefix-group"
query_json=$(tmp_json)

cleanup() {
	cleanup_host "$logical"
	cleanup_host "$host1"
	cleanup_host "$host2"
	cleanup_group "$group"
	cleanup_subject "$normal"
	cleanup_principal "$normal"
}
trap cleanup EXIT

normal_pass=$(create_user_password "$normal")
run_ok "normalise owner test user" \
    bifrost modify "$normal" attributes-=needchange
run_ok "create owner subject" bifrost create_subject "$normal" type=krb5
run_ok "kinit owner test user" kinit_ccache "$normal" "$normal_pass" \
    "$normal_cc"

run_ok "create owner host 1" bifrost create_host "$host1" \
    ip_addr=10.50.0.1 realm="$REALM"
run_ok "create owner host 2" bifrost create_host "$host2" \
    ip_addr=10.50.0.2 realm="$REALM"
run_ok "create owner logical host" bifrost create_logical_host "$logical"
run_ok "map owner logical host" bifrost insert_hostmap "$logical" "$host1"

run_fail "non-owner cannot modify logical host" \
    bifrost_ccache "$normal_cc" modify_host "$logical" "member+=$host2"

run_ok "grant logical host owner" bifrost modify_host "$logical" \
    "owner+=$normal"
json_cmd "$query_json" bifrost_json query_host_owner "$logical"
json_filter_true "host owner query includes normal user" "$query_json" \
    --arg owner "$normal" 'map(.owner) | index($owner)'

run_ok "owner modifies logical host" \
    bifrost_ccache "$normal_cc" modify_host "$logical" "member+=$host2"
json_cmd "$query_json" bifrost_json query_hostmap "$logical"
json_array_has "owner-added host appears in hostmap" \
    "$query_json" . "$host2"

run_ok "create owned group" bifrost create_group "$group" "owner=$normal"
json_cmd "$query_json" bifrost_json query_acl_owner "$group"
json_filter_true "group owner query includes normal user" "$query_json" \
    --arg owner "$normal" 'map(.owner) | index($owner)'

run_ok "owner modifies group" \
    bifrost_ccache "$normal_cc" modify_group "$group" "member+=$normal"
json_cmd "$query_json" bifrost_json query_group "$group"
json_array_has "owner-added group member appears" \
    "$query_json" .member "$normal"

run_fail "owner cannot remove own group ownership" \
    bifrost_ccache "$normal_cc" remove_acl_owner "$group" "$normal"

finish_tests
