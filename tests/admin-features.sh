#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name feature)
feature="$prefix-enabled"
query_json=$(tmp_json)

cleanup() {
	bifrost del_feature "$feature" >/dev/null 2>&1 || true
}
trap cleanup EXIT

bifrost -J has_feature "$feature" >"$query_json"
json_field_eq "feature absent initially" "$query_json" . 0

run_ok "add feature" bifrost add_feature "$feature"
bifrost -J has_feature "$feature" >"$query_json"
json_field_eq "feature present after add" "$query_json" . 1

run_ok "delete feature" bifrost del_feature "$feature"
bifrost -J has_feature "$feature" >"$query_json"
json_field_eq "feature absent after delete" "$query_json" . 0

run_ok "add feature again" bifrost add_feature "$feature"
bifrost -J has_feature "$feature" >"$query_json"
json_field_eq "feature present after second add" "$query_json" . 1

finish_tests
