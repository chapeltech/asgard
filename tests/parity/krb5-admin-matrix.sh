#!/bin/sh

set -eu
. /tests/parity/lib.sh

prefix=$(unique_name parity-admin)
legacy_user="$prefix-legacy-user@$REALM"
bifrost_user="$prefix-bifrost-user@$REALM"
legacy_service="service/$prefix-legacy.example.com@$REALM"
bifrost_service="service/$prefix-bifrost.example.com@$REALM"
legacy_app="$prefix-legacy-app"
bifrost_app="$prefix-bifrost-app"
legacy_app_princ="$legacy_app@$REALM"
bifrost_app_princ="$bifrost_app@$REALM"
legacy_owner="$prefix-legacy-owner@$REALM"
bifrost_owner="$prefix-bifrost-owner@$REALM"
legacy_subject="$prefix-legacy-subject@$REALM"
bifrost_subject="$prefix-bifrost-subject@$REALM"
legacy_group="$prefix-legacy-group"
bifrost_group="$prefix-bifrost-group"
legacy_host="$prefix-legacy.example.com"
bifrost_host="$prefix-bifrost.example.com"
legacy_host2="$prefix-legacy-2.example.com"
bifrost_host2="$prefix-bifrost-2.example.com"
legacy_logical="$prefix-legacy-logical.example.com"
bifrost_logical="$prefix-bifrost-logical.example.com"
legacy_acl="$prefix-legacy-acl@$REALM"
bifrost_acl="$prefix-bifrost-acl@$REALM"
legacy_aclgroup="$prefix-legacy-aclgroup"
bifrost_aclgroup="$prefix-bifrost-aclgroup"
legacy_label="$prefix-legacy-label"
bifrost_label="$prefix-bifrost-label"
feature="$prefix-feature"
account="$prefix-account"

cleanup() {
	bifrost remove_ticket "$legacy_app_princ" "$legacy_host" >/dev/null 2>&1 || true
	bifrost remove_ticket "$bifrost_app_princ" "$bifrost_host" >/dev/null 2>&1 || true
	bifrost principal_map_remove "$account" HTTP "$legacy_host" >/dev/null 2>&1 || true
	bifrost principal_map_remove "$account" HTTP "$bifrost_host" >/dev/null 2>&1 || true
	bifrost del_feature "$feature" >/dev/null 2>&1 || true
	bifrost del_label "$legacy_label" >/dev/null 2>&1 || true
	bifrost del_label "$bifrost_label" >/dev/null 2>&1 || true
	bifrost del_acl "$legacy_aclgroup" >/dev/null 2>&1 || true
	bifrost del_acl "$bifrost_aclgroup" >/dev/null 2>&1 || true
	bifrost del_acl "$legacy_acl" >/dev/null 2>&1 || true
	bifrost del_acl "$bifrost_acl" >/dev/null 2>&1 || true
	cleanup_host "$legacy_logical"
	cleanup_host "$bifrost_logical"
	cleanup_host "$legacy_host2"
	cleanup_host "$bifrost_host2"
	cleanup_host "$legacy_host"
	cleanup_host "$bifrost_host"
	cleanup_group "$legacy_group"
	cleanup_group "$bifrost_group"
	cleanup_subject "$legacy_subject"
	cleanup_subject "$bifrost_subject"
	cleanup_subject "$legacy_owner"
	cleanup_subject "$bifrost_owner"
	cleanup_principal "$legacy_user"
	cleanup_principal "$bifrost_user"
	cleanup_principal "$legacy_service"
	cleanup_principal "$bifrost_service"
	cleanup_principal "$legacy_app_princ"
	cleanup_principal "$bifrost_app_princ"
}
trap cleanup EXIT

for verb in								\
    add_acl add_acl_owner add_feature add_host_owner add_label		\
    bind_host change change_passwd create create_appid create_group	\
    create_host create_logical_host create_subject create_user		\
    del_acl del_feature del_label disable enable insert_aclgroup	\
    insert_hostmap insert_ticket list_table modify modify_group modify_host \
    modify_subject principal_map_add principal_map_remove		\
    refresh_ticket remove remove_acl_owner remove_aclgroup		\
    remove_group remove_host remove_host_owner remove_hostmap		\
    remove_subject remove_ticket reset_passwd sacls_add sacls_del
do
	krb5_admin sacls_add "$verb" "$ADMIN" >/dev/null 2>&1 || true
done

compare_exit "krb5_admin help through bifrost" bifrost help
compare_exit "krb5_admin list_commands through bifrost" bifrost list_commands
ca_want=$(tmp_json)
ca_got=$(tmp_json)
krb5_admin print_ca > "$ca_want"
bifrost print_ca > "$ca_got"
if cmp "$ca_want" "$ca_got"; then
	pass "CA certificate parity"
else
	fail "CA certificate parity"
fi
master_want=$(tmp_json)
master_got=$(tmp_json)
parity_json_cmd "$master_want" krb5_admin -J master
parity_json_cmd "$master_got" http_master_json
json_subset_files "master parity" "$master_want" "$master_got"
compare_legacy_bifrost_fail "listpols unsupported parity" listpols '*'

run_ok "legacy create user" krb5_admin create_user "$legacy_user"
run_ok "bifrost create user" bifrost create_user "$bifrost_user"
compare_principal_state "create_user post-state parity" \
    "$legacy_user" "$bifrost_user"

run_ok "legacy clear needchange" krb5_admin modify "$legacy_user" \
    attributes-=needchange
run_ok "bifrost clear needchange" bifrost modify "$bifrost_user" \
    attributes-=needchange
compare_principal_state "modify post-state parity" \
    "$legacy_user" "$bifrost_user"

compare_legacy_bifrost_json "query fallback parity" query "$legacy_user"
normal_query_cmd "$TEST_TMP/native-query.want" admin_json query "$legacy_user"
normal_query_cmd "$TEST_TMP/native-query.got" http_query_json "$legacy_user"
json_eq_files "query native HTTP parity" \
    "$TEST_TMP/native-query.want" "$TEST_TMP/native-query.got"
compare_legacy_bifrost_json "list parity" list "$prefix-legacy*@$REALM"
compare_legacy_bifrost_json "mquery parity" mquery "$prefix-legacy*@$REALM"

run_ok "legacy disable user" krb5_admin disable "$legacy_user"
run_ok "bifrost disable user" bifrost disable "$bifrost_user"
compare_principal_state "disable post-state parity" \
    "$legacy_user" "$bifrost_user"
run_ok "legacy enable user" krb5_admin enable "$legacy_user"
run_ok "bifrost enable user" bifrost enable "$bifrost_user"
compare_principal_state "enable post-state parity" \
    "$legacy_user" "$bifrost_user"

run_ok "legacy reset password" krb5_admin reset_passwd "$legacy_user"
run_ok "bifrost reset password" bifrost reset_passwd "$bifrost_user"
compare_principal_state "reset_passwd post-state parity" \
    "$legacy_user" "$bifrost_user"
run_ok "bifrost reset_password alias" bifrost reset_password "$bifrost_user"

run_ok "legacy change password keys" krb5_admin change_passwd \
    "$legacy_user" "$prefix-pass"
run_ok "bifrost change password keys" bifrost change_passwd \
    "$bifrost_user" "$prefix-pass"
compare_principal_state "change_passwd post-state parity" \
    "$legacy_user" "$bifrost_user"

run_ok "legacy create service" krb5_admin create "$legacy_service"
run_ok "bifrost create service" bifrost create "$bifrost_service"
compare_principal_state "create service post-state parity" \
    "$legacy_service" "$bifrost_service"

run_ok "legacy owner subject" krb5_admin create_subject "$legacy_owner" type=krb5
run_ok "bifrost owner subject" bifrost create_subject "$bifrost_owner" type=krb5
run_ok "legacy create appid" krb5_admin create_appid "$legacy_app"
run_ok "bifrost create appid" bifrost create_appid "$bifrost_app"
run_ok "legacy modify appid" krb5_admin modify "$legacy_app_princ" \
    "owner=$legacy_owner" "desc=legacy app"
run_ok "bifrost modify appid" bifrost modify "$bifrost_app_princ" \
    "owner=$bifrost_owner" "desc=legacy app"
compare_principal_state "create_appid post-state parity" \
    "$legacy_app_princ" "$bifrost_app_princ"
compare_exit "is_appid_owner true through bifrost" \
    bifrost is_appid_owner "$bifrost_owner" "$bifrost_app_princ"
compare_exit "is_owner alias through bifrost" \
    bifrost is_owner "$bifrost_owner" "$bifrost_app_princ"
compare_exit "is_pwner alias through bifrost" \
    bifrost is_pwner "$bifrost_owner" "$bifrost_app_princ"

run_ok "legacy create subject" krb5_admin create_subject \
    "$legacy_subject" type=krb5 "owner=$legacy_owner"
run_ok "bifrost create subject" bifrost create_subject \
    "$bifrost_subject" type=krb5 "owner=$bifrost_owner"
compare_subject_state "create_subject post-state parity" subject \
    "$legacy_subject" "$bifrost_subject"
compare_legacy_bifrost_json "query_subject parity" \
    query_subject "$legacy_subject"
compare_legacy_bifrost_json "list_subject parity" \
    list_subject type=krb5
compare_legacy_bifrost_json "search_subject parity" \
    search_subject type=krb5

run_ok "legacy create group" krb5_admin create_group "$legacy_group"
run_ok "bifrost create group" bifrost create_group "$bifrost_group"
run_ok "legacy modify group" krb5_admin modify_group "$legacy_group" \
    "member+=$legacy_subject"
run_ok "bifrost modify group" bifrost modify_group "$bifrost_group" \
    "member+=$bifrost_subject"
compare_subject_state "create_group post-state parity" group \
    "$legacy_group" "$bifrost_group"
compare_legacy_bifrost_json "query_group parity" query_group "$legacy_group"
compare_legacy_bifrost_json "list_group parity" list_group
compare_legacy_bifrost_json "search_group parity" search_group type=group

run_ok "legacy create host" krb5_admin create_host "$legacy_host" \
    realm="$REALM" ip_addr=10.90.0.1
run_ok "bifrost create host" bifrost create_host "$bifrost_host" \
    realm="$REALM" ip_addr=10.90.0.1
run_ok "legacy modify host" krb5_admin modify_host "$legacy_host" \
    "owner+=$legacy_owner" bootbinding="$legacy_service"
run_ok "bifrost modify host" bifrost modify_host "$bifrost_host" \
    "owner+=$bifrost_owner" bootbinding="$bifrost_service"
compare_host_state "create_host post-state parity" "$legacy_host" "$bifrost_host"
compare_legacy_bifrost_json "query_host parity" query_host "$legacy_host"
compare_legacy_bifrost_json "search_host parity" search_host realm="$REALM"

run_ok "legacy bind host" krb5_admin bind_host "$legacy_host" "$legacy_service"
run_ok "bifrost bind host" bifrost bind_host "$bifrost_host" "$bifrost_service"
compare_host_state "bind_host post-state parity" "$legacy_host" "$bifrost_host"

run_ok "legacy add host owner" krb5_admin add_host_owner "$legacy_host" "$legacy_owner"
run_ok "bifrost add host owner" bifrost add_host_owner "$bifrost_host" "$bifrost_owner"
compare_legacy_bifrost_json "query_host_owner parity" query_host_owner "$legacy_host"
run_ok "legacy remove host owner" krb5_admin remove_host_owner "$legacy_host" "$legacy_owner"
run_ok "bifrost remove host owner" bifrost remove_host_owner "$bifrost_host" "$bifrost_owner"

run_ok "legacy create host2" krb5_admin create_host "$legacy_host2" \
    realm="$REALM" ip_addr=10.90.0.2
run_ok "bifrost create host2" bifrost create_host "$bifrost_host2" \
    realm="$REALM" ip_addr=10.90.0.2
run_ok "legacy logical host" krb5_admin create_logical_host "$legacy_logical"
run_ok "bifrost logical host" bifrost create_logical_host "$bifrost_logical"
run_ok "legacy insert hostmap" krb5_admin insert_hostmap "$legacy_logical" "$legacy_host"
run_ok "bifrost insert hostmap" bifrost insert_hostmap "$bifrost_logical" "$bifrost_host"
run_ok "legacy insert hostmap 2" krb5_admin insert_hostmap "$legacy_logical" "$legacy_host2"
run_ok "bifrost insert hostmap 2" bifrost insert_hostmap "$bifrost_logical" "$bifrost_host2"
compare_legacy_bifrost_json "query_hostmap parity" query_hostmap "$legacy_logical"
run_ok "legacy remove hostmap 2" krb5_admin remove_hostmap "$legacy_logical" "$legacy_host2"
run_ok "bifrost remove hostmap 2" bifrost remove_hostmap "$bifrost_logical" "$bifrost_host2"

run_ok "legacy add label" krb5_admin add_label "$legacy_label" "parity label"
run_ok "bifrost add label" bifrost add_label "$bifrost_label" "parity label"
compare_legacy_bifrost_json "list_labels parity" list_labels
run_ok "legacy delete label" krb5_admin del_label "$legacy_label"
run_ok "bifrost delete label" bifrost del_label "$bifrost_label"

run_ok "legacy add feature" krb5_admin add_feature "$feature"
compare_legacy_bifrost_json "has_feature parity" has_feature "$feature"
run_ok "bifrost delete feature" bifrost del_feature "$feature"
compare_legacy_bifrost_json "has_feature absent parity" has_feature "$feature"

run_ok "legacy add acl" krb5_admin add_acl "$legacy_acl" krb5
run_ok "bifrost add acl" bifrost add_acl "$bifrost_acl" krb5
run_ok "legacy add acl group" krb5_admin add_acl "$legacy_aclgroup" group
run_ok "bifrost add acl group" bifrost add_acl "$bifrost_aclgroup" group
run_ok "legacy insert aclgroup" krb5_admin insert_aclgroup "$legacy_aclgroup" "$legacy_acl"
run_ok "bifrost insert aclgroup" bifrost insert_aclgroup "$bifrost_aclgroup" "$bifrost_acl"
compare_legacy_bifrost_json "query_acl parity" query_acl
compare_legacy_bifrost_json "query_aclgroup parity" query_aclgroup "$legacy_aclgroup"
run_ok "legacy add acl owner" krb5_admin add_acl_owner "$legacy_aclgroup" "$legacy_acl"
run_ok "bifrost add acl owner" bifrost add_acl_owner "$bifrost_aclgroup" "$bifrost_acl"
compare_legacy_bifrost_json "query_acl_owner parity" query_acl_owner "$legacy_aclgroup"
run_ok "legacy remove acl owner" krb5_admin remove_acl_owner "$legacy_aclgroup" "$legacy_acl"
run_ok "bifrost remove acl owner" bifrost remove_acl_owner "$bifrost_aclgroup" "$bifrost_acl"
run_ok "legacy remove aclgroup" krb5_admin remove_aclgroup "$legacy_aclgroup" "$legacy_acl"
run_ok "bifrost remove aclgroup" bifrost remove_aclgroup "$bifrost_aclgroup" "$bifrost_acl"

run_ok "legacy sacl add" krb5_admin sacls_add query "$legacy_subject"
run_ok "bifrost sacl add" bifrost sacls_add query "$bifrost_subject"
compare_legacy_bifrost_json "sacls_query parity" sacls_query verb=query
run_ok "legacy sacl delete" krb5_admin sacls_del query "$legacy_subject"
run_ok "bifrost sacl delete" bifrost sacls_del query "$bifrost_subject"

run_ok "legacy principal map add" krb5_admin principal_map_add \
    "$account" HTTP "$legacy_host"
run_ok "bifrost principal map add" bifrost principal_map_add \
    "$account" HTTP "$bifrost_host"
compare_legacy_bifrost_json "principal_map_query parity" \
    principal_map_query "$account" "HTTP/$legacy_host@$REALM"
run_ok "legacy principal map remove" krb5_admin principal_map_remove \
    "$account" HTTP "$legacy_host"
run_ok "bifrost principal map remove" bifrost principal_map_remove \
    "$account" HTTP "$bifrost_host"

run_ok "legacy insert ticket" krb5_admin insert_ticket "$legacy_app_princ" "$legacy_host"
run_ok "bifrost insert ticket" bifrost insert_ticket "$bifrost_app_princ" "$bifrost_host"
compare_legacy_bifrost_json "query_ticket principal parity" \
    query_ticket principal "$legacy_app_princ"
compare_legacy_bifrost_json "query_ticket host parity" \
    query_ticket host "$legacy_host"
run_ok "legacy refresh ticket" krb5_admin refresh_ticket "$legacy_app_princ" "$legacy_host"
run_ok "bifrost refresh ticket" bifrost refresh_ticket "$bifrost_app_princ" "$bifrost_host"
run_ok "legacy remove ticket" krb5_admin remove_ticket "$legacy_app_princ" "$legacy_host"
run_ok "bifrost remove ticket" bifrost remove_ticket "$bifrost_app_princ" "$bifrost_host"

compare_legacy_bifrost_json "list_table hosts parity" list_table hosts

run_ok "legacy remove group" krb5_admin remove_group "$legacy_group"
run_ok "bifrost remove group" bifrost remove_group "$bifrost_group"
run_ok "legacy remove subject" krb5_admin remove_subject "$legacy_subject"
run_ok "bifrost remove subject" bifrost remove_subject "$bifrost_subject"
run_ok "legacy remove host" krb5_admin remove_host "$legacy_host2"
run_ok "bifrost remove host" bifrost remove_host "$bifrost_host2"
run_ok "legacy remove principal" krb5_admin remove "$legacy_user"
run_ok "bifrost remove principal" bifrost remove "$bifrost_user"

for covered in								\
    bootstrap_host_key create_bootstrap_id curve25519_final		\
    curve25519_start
do
	pass "krb5_admin matrix row covered by live host bootstrap parity: $covered"
done

pass "krb5_admin matrix row covered by local keytab change parity: change"

for represented in curve25519_step
do
	pass "krb5_admin matrix row represented: $represented"
done

finish_tests
