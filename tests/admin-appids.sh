#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name appid)
appid="$prefix-app"
appid_princ="$appid@$REALM"
owner1="$prefix-owner1@$REALM"
owner2="$prefix-owner2@$REALM"
cstraint="$prefix-cstraint@$REALM"
query_json=$(tmp_json)

cleanup() {
	cleanup_principal "$appid_princ"
	bifrost del_label "$cstraint" >/dev/null 2>&1 || true
	cleanup_subject "$owner1"
	cleanup_subject "$owner2"
}
trap cleanup EXIT

run_ok "create owner subject 1" \
    bifrost create_subject "$owner1" type=krb5
run_ok "create owner subject 2" \
    bifrost create_subject "$owner2" type=krb5
run_ok "create constraint label" \
    bifrost add_label "$cstraint" "constraint label"

run_ok "bifrost fallback creates appid" bifrost create_appid "$appid"
json_cmd "$query_json" bifrost_json query "$appid_princ"
json_field_eq "appid principal" "$query_json" .principal "$appid_princ"
json_array_has "appid default owner" "$query_json" .owner "$ADMIN"

run_ok "replace appid fields" bifrost modify "$appid"		\
    "desc=first description" "owner=$owner1" "cstraint=$cstraint"
json_cmd "$query_json" bifrost_json query "$appid_princ"
json_field_eq "appid desc replaced" "$query_json" .desc \
    "first description"
json_array_has "appid owner replaced" "$query_json" .owner "$owner1"
json_array_has "appid cstraint set" "$query_json" .cstraint "$cstraint"

run_ok "add appid owner" bifrost modify "$appid" "owner+=$owner2"
json_cmd "$query_json" bifrost_json query "$appid_princ"
json_array_has "appid owner 1 remains" "$query_json" .owner "$owner1"
json_array_has "appid owner 2 added" "$query_json" .owner "$owner2"

run_ok "delete appid owner" bifrost modify "$appid" "owner-=$owner1"
json_cmd "$query_json" bifrost_json query "$appid_princ"
json_array_lacks "appid owner 1 removed" "$query_json" .owner "$owner1"
json_array_has "appid owner 2 remains" "$query_json" .owner "$owner2"

finish_tests
