#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name princ)
user="$prefix-user@$REALM"
service="service/$prefix.example.com@$REALM"
password="Ff1passThePolicy--$prefix-user"
changed_password="Ff1passThePolicy--$prefix-changed"
initial_cc="$TEST_TMP/initial.ccache"
old_cc="$TEST_TMP/old.ccache"
changed_cc="$TEST_TMP/changed.ccache"
user_json=$(tmp_json)
service_json=$(tmp_json)
list_json=$(tmp_json)

cleanup() {
	cleanup_principal "$user"
	cleanup_principal "$service"
}
trap cleanup EXIT

run_ok "bifrost fallback creates user" \
    bifrost create_user "$user" "$password"
run_ok "bifrost fallback clears needchange" \
    bifrost modify "$user" attributes-=needchange
run_ok "created user obtains credentials" \
    kinit_ccache "$user" "$password" "$initial_cc"

json_cmd "$user_json" bifrost_json query "$user"
json_field_eq "created user principal" "$user_json" .principal "$user"
json_array_has "created user requires preauth" "$user_json" \
    .attributes +requires_preauth
json_array_lacks "created user needchange cleared" "$user_json" \
    .attributes +needchange

run_ok "bifrost fallback changes password" \
    bifrost change_passwd "$user" "$changed_password"
run_fail "old password no longer obtains credentials" \
    kinit_ccache "$user" "$password" "$old_cc"
run_ok "changed password obtains credentials" \
    kinit_ccache "$user" "$changed_password" "$changed_cc"

run_ok "bifrost fallback resets password" bifrost reset_passwd "$user"
json_cmd "$user_json" bifrost_json query "$user"
json_array_has "reset password requires change" "$user_json" \
    .attributes +needchange

run_ok "bifrost fallback disables user" bifrost disable "$user"
json_cmd "$user_json" bifrost_json query "$user"
json_array_has "disabled user has allow_tix removed" "$user_json" \
    .attributes -allow_tix

run_ok "bifrost fallback enables user" bifrost enable "$user"
json_cmd "$user_json" bifrost_json query "$user"
json_array_lacks "enabled user allows tickets" "$user_json" \
    .attributes -allow_tix

run_ok "bifrost fallback creates service" bifrost create "$service"
json_cmd "$service_json" bifrost_json query "$service"
json_field_eq "created service principal" "$service_json" .principal \
    "$service"
json_filter_true "created service has keys" "$service_json" \
    '(.keys | length) > 0'

json_cmd "$list_json" bifrost_json list "$prefix*@$REALM"
json_array_has "list contains created user" "$list_json" . "$user"

finish_tests
