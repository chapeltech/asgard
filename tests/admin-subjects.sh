#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name subj)
subject="$prefix-subject@$REALM"
group="$prefix-group"
query_subject_json=$(tmp_json)
query_group_json=$(tmp_json)
list_json=$(tmp_json)

cleanup() {
	cleanup_subject "$subject"
	cleanup_group "$group"
}
trap cleanup EXIT

run_ok "create krb5 subject" bifrost create_subject "$subject" type=krb5
json_cmd "$query_subject_json" bifrost_json query_subject "$subject"
json_field_eq "query subject type" "$query_subject_json" .type krb5

run_ok "create group" bifrost create_group "$group"
run_ok "add group member" bifrost modify_group "$group" \
    "member+=$subject"
json_cmd "$query_group_json" bifrost_json query_group "$group"
json_field_eq "query group type" "$query_group_json" .type group
json_array_has "query group member" "$query_group_json" .member "$subject"

json_cmd "$list_json" bifrost_json list_subject type=krb5
json_array_has "list_subject contains subject" \
    "$list_json" . "$subject"

finish_tests
