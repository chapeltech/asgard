#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name sacl)
subject="$prefix@$REALM"
query_json=$(tmp_json)

cleanup() {
	bifrost sacls_del query "$subject" >/dev/null 2>&1 || true
	cleanup_subject "$subject"
}
trap cleanup EXIT

run_ok "create sacl subject" bifrost create_subject "$subject" type=krb5
run_ok "add sacl" bifrost sacls_add query "$subject"
json_cmd "$query_json" bifrost_json sacls_query "verb=query"
json_array_has "sacl query includes subject" \
    "$query_json" . "$subject"

run_ok "delete sacl" bifrost sacls_del query "$subject"
json_cmd "$query_json" bifrost_json sacls_query "verb=query"
json_array_lacks "sacl query no longer includes subject" \
    "$query_json" . "$subject"

finish_tests
