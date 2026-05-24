#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name pmap)
host="$prefix.example.com"
account="$prefix-account"
query_json=$(tmp_json)

cleanup() {
	bifrost principal_map_remove "$account" HTTP "$host" \
	    >/dev/null 2>&1 || true
	cleanup_host "$host"
}
trap cleanup EXIT

run_ok "create map host" bifrost create_host "$host"	\
    ip_addr=10.30.0.1 realm="$REALM"

run_ok "add principal map" bifrost principal_map_add \
    "$account" HTTP "$host"

json_cmd "$query_json" bifrost_json principal_map_query \
    "$account" "HTTP/$host@$REALM"
json_filter_true "principal map query finds mapping" "$query_json" \
    '. != null'

run_fail "reject malformed principal map" bifrost principal_map_add \
    "$account" 'HTTP@BAD#NAME' "$host"

run_ok "remove principal map" bifrost principal_map_remove \
    "$account" HTTP "$host"

json_cmd "$query_json" bifrost_json principal_map_query \
    "$account" "HTTP/$host@$REALM"
json_filter_true "principal map query no longer finds mapping" \
    "$query_json" '. == "0"'

finish_tests
