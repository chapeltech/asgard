#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name parity)
user="$prefix-user@$REALM"
appid="$prefix-app"
appid_princ="$appid@$REALM"
owner="$prefix-owner@$REALM"
ka_json=$(tmp_json)
bf_json=$(tmp_json)
http_json=$(tmp_json)

cleanup() {
	cleanup_principal "$user"
	cleanup_principal "$appid_princ"
	cleanup_subject "$owner"
}
trap cleanup EXIT

run_ok "create parity user" bifrost create_user "$user"
run_ok "normalise parity user" bifrost modify "$user" attributes-=needchange

normal_query_cmd "$ka_json" admin_json query "$user"
normal_query_cmd "$http_json" http_query_json "$user"
json_eq_files "native bifrost query matches krb5_admin" \
    "$ka_json" "$http_json"

normal_query_cmd "$bf_json" bifrost_json query "$user"
json_eq_files "bifrost fallback query matches krb5_admin" \
    "$ka_json" "$bf_json"

run_ok "create parity owner subject" bifrost create_subject "$owner" type=krb5
run_ok "create parity appid" bifrost create_appid "$appid"
run_ok "modify parity appid" bifrost modify "$appid"	\
    "desc=parity appid" "owner=$owner"

normal_query_cmd "$ka_json" admin_json query "$appid_princ"
normal_query_cmd "$http_json" http_query_json "$appid_princ"
json_eq_files "native bifrost appid query matches krb5_admin" \
    "$ka_json" "$http_json"

finish_tests
