#!/bin/sh

set -eu
. /tests/lib.sh

prefix=$(unique_name authz)
owner="$prefix-owner@$REALM"
other="$prefix-other@$REALM"
owner_cc="$TEST_TMP/owner.ccache"
other_cc="$TEST_TMP/other.ccache"
appid="$prefix-app"
appid_princ="$appid@$REALM"
subject_granted="$prefix-granted@$REALM"
subject_revoked="$prefix-revoked@$REALM"
query_json=$(tmp_json)
owner_pass="Ff1passThePolicy--$prefix-owner"
other_pass="Ff1passThePolicy--$prefix-other"

cleanup() {
	bifrost sacls_del create_subject "$owner" >/dev/null 2>&1 || true
	cleanup_principal "$appid_princ"
	cleanup_subject "$subject_granted"
	cleanup_subject "$subject_revoked"
	cleanup_subject "$owner"
	cleanup_subject "$other"
	cleanup_principal "$owner"
	cleanup_principal "$other"
}
trap cleanup EXIT

run_ok "create authz owner user" bifrost create_user "$owner" "$owner_pass"
run_ok "create authz other user" bifrost create_user "$other" "$other_pass"
run_ok "normalise authz owner" bifrost modify "$owner" attributes-=needchange
run_ok "normalise authz other" bifrost modify "$other" attributes-=needchange
run_ok "create authz owner subject" bifrost create_subject "$owner" type=krb5
run_ok "create authz other subject" bifrost create_subject "$other" type=krb5
run_ok "kinit authz owner" kinit_ccache "$owner" "$owner_pass" "$owner_cc"
run_ok "kinit authz other" kinit_ccache "$other" "$other_pass" "$other_cc"

run_fail "ungranted user cannot create subject" \
    bifrost_ccache "$owner_cc" create_subject "$subject_granted" type=krb5
run_ok "grant create_subject to user" \
    bifrost sacls_add create_subject "$owner"
run_ok "granted user can create subject" \
    bifrost_ccache "$owner_cc" create_subject "$subject_granted" type=krb5
run_ok "revoke create_subject from user" \
    bifrost sacls_del create_subject "$owner"
run_fail "revoked user cannot create subject" \
    bifrost_ccache "$owner_cc" create_subject "$subject_revoked" type=krb5

run_ok "create owned appid" bifrost create_appid "$appid"
run_ok "set appid owner" bifrost modify "$appid" "owner=$owner"
run_ok "appid owner can modify appid" \
    bifrost_ccache "$owner_cc" modify "$appid" "desc=owner update"
json_cmd "$query_json" bifrost_json query "$appid_princ"
json_field_eq "owner appid change persisted" \
    "$query_json" .desc "owner update"

run_fail "unrelated user cannot modify appid" \
    bifrost_ccache "$other_cc" modify "$appid" "desc=bad update"
json_cmd "$query_json" bifrost_json query "$appid_princ"
json_field_eq "unrelated appid change rejected" \
    "$query_json" .desc "owner update"

finish_tests
