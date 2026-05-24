#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name ticket)
host="$prefix.example.com"
appid="$prefix-app"
principal="$appid@$REALM"
query_json=$(tmp_json)

cleanup() {
	bifrost remove_ticket "$principal" "$host" >/dev/null 2>&1 || true
	cleanup_principal "$principal"
	cleanup_host "$host"
}
trap cleanup EXIT

run_ok "create ticket host" bifrost create_host "$host"	\
    ip_addr=10.40.0.1 realm="$REALM"
run_ok "create ticket appid" bifrost create_appid "$appid"

run_ok "insert ticket" bifrost insert_ticket "$principal" "$host"

json_cmd "$query_json" bifrost_json query_ticket principal "$principal"
json_array_has "ticket query by principal includes host" \
    "$query_json" . "$host"

json_cmd "$query_json" bifrost_json query_ticket host "$host"
json_array_has "ticket query by host includes principal" \
    "$query_json" . "$principal"

json_cmd "$query_json" bifrost_json query_ticket \
    principal "$principal" host "$host"
json_field_eq "ticket query exact match succeeds" "$query_json" . 1

run_ok "refresh ticket" bifrost refresh_ticket "$principal" "$host"
run_ok "remove ticket" bifrost remove_ticket "$principal" "$host"

json_cmd "$query_json" bifrost_json query_ticket \
    principal "$principal" host "$host"
json_field_eq "ticket query exact match removed" "$query_json" . 0

finish_tests
