#!/bin/sh

set -eu
. /tests/parity/lib.sh

HDB=/var/heimdal/heimdal.db
DB=/var/kerberos/krb5_admin.db
BASELINE_HDB="$TEST_TMP/local-hdb-baseline.db"
BASELINE_DB="$TEST_TMP/local-admin-baseline.sqlite3"

for db in "$HDB" "$DB"; do
	if [ ! -f "$db" ]; then
		fail "local parity source database exists: $db"
	fi
done

cp "$HDB" "$BASELINE_HDB"
sqlite3 "$DB" ".timeout 60000" ".backup $BASELINE_DB"
run_ok "local admin parity baseline quick_check" \
    /bin/sh -c "test \"\$(sqlite3 '$BASELINE_DB' 'PRAGMA quick_check;')\" = ok"

local_pair() {
	name=$1
	KA_HDB="$TEST_TMP/$name.krb5-admin-hdb"
	KA_DB="$TEST_TMP/$name.krb5-admin.sqlite3"
	BF_HDB="$TEST_TMP/$name.bifrost-hdb"
	BF_DB="$TEST_TMP/$name.bifrost.sqlite3"

	cp "$BASELINE_HDB" "$KA_HDB.db"
	cp "$BASELINE_DB" "$KA_DB"
	cp "$BASELINE_HDB" "$BF_HDB.db"
	cp "$BASELINE_DB" "$BF_DB"
}

drop_krb5_admin_tables() {
	db=$1

	sqlite3 "$db" <<'EOS'
DROP TABLE IF EXISTS krb5_admin_simple_acls;
DROP TABLE IF EXISTS db_version;
DROP TABLE IF EXISTS features;
DROP TABLE IF EXISTS account_principal_map;
DROP TABLE IF EXISTS external_account_principal_map;
DROP TABLE IF EXISTS aclgroups;
DROP TABLE IF EXISTS appid_cstraints;
DROP TABLE IF EXISTS appid_acls;
DROP TABLE IF EXISTS acls_owner;
DROP TABLE IF EXISTS appids;
DROP TABLE IF EXISTS prestashed;
DROP TABLE IF EXISTS host_secrets;
DROP TABLE IF EXISTS host_secret_ids;
DROP TABLE IF EXISTS hosts_owner;
DROP TABLE IF EXISTS hostmap;
DROP TABLE IF EXISTS host_labels;
DROP TABLE IF EXISTS acls;
DROP TABLE IF EXISTS hosts;
DROP TABLE IF EXISTS labels;
EOS
}

local_initdb_pair() {
	name=$1
	KA_HDB="$TEST_TMP/$name.krb5-admin-hdb"
	KA_DB="$TEST_TMP/$name.krb5-admin.sqlite3"
	BF_HDB="$TEST_TMP/$name.bifrost-hdb"
	BF_DB="$TEST_TMP/$name.bifrost.sqlite3"

	cp "$BASELINE_HDB" "$KA_HDB.db"
	cp "$BASELINE_DB" "$KA_DB"
	cp "$BASELINE_HDB" "$BF_HDB.db"
	cp "$BASELINE_DB" "$BF_DB"
	drop_krb5_admin_tables "$KA_DB"
	drop_krb5_admin_tables "$BF_DB"
}

ka_local_json() {
	out=$1
	shift
	parity_json_cmd "$out" krb5_admin -J -l \
	    -D "db:$KA_HDB" -S "$KA_DB" "$@"
}

bf_local_json() {
	out=$1
	shift
	parity_json_cmd "$out" bifrost -J -l \
	    -D "db:$BF_HDB" -S "$BF_DB" "$@"
}

compare_local_json() {
	name=$1
	shift
	want=$(tmp_json)
	got=$(tmp_json)

	ka_local_json "$want" "$@"
	bf_local_json "$got" "$@"
	json_subset_files "$name" "$want" "$got"
}

compare_local_json_type() {
	name=$1
	type=$2
	shift 2
	want=$(tmp_json)
	got=$(tmp_json)

	ka_local_json "$want" "$@"
	bf_local_json "$got" "$@"
	if jq -e --arg type "$type" \
	    'type == $type' "$want" >/dev/null &&
	    jq -e --arg type "$type" \
	    'type == $type' "$got" >/dev/null; then
		pass "$name"
	else
		printf '%s\n' '--- krb5_admin output ---' >&2
		jq -S . "$want" >&2
		printf '%s\n' '--- bifrost output ---' >&2
		jq -S . "$got" >&2
		fail "$name"
	fi
}

compare_local_json_string_length() {
	name=$1
	length=$2
	shift 2
	want=$(tmp_json)
	got=$(tmp_json)

	ka_local_json "$want" "$@"
	bf_local_json "$got" "$@"
	if jq -e --argjson length "$length" \
	    'type == "string" and (length == $length)' "$want" >/dev/null &&
	    jq -e --argjson length "$length" \
	    'type == "string" and (length == $length)' "$got" >/dev/null; then
		pass "$name"
	else
		printf '%s\n' '--- krb5_admin output ---' >&2
		jq -S . "$want" >&2
		printf '%s\n' '--- bifrost output ---' >&2
		jq -S . "$got" >&2
		fail "$name"
	fi
}

compare_local_json_object_keys() {
	name=$1
	shift
	want=$(tmp_json)
	got=$(tmp_json)
	want_keys=$(tmp_json)
	got_keys=$(tmp_json)

	ka_local_json "$want" "$@"
	bf_local_json "$got" "$@"
	jq -S 'keys' "$want" >"$want_keys"
	jq -S 'keys' "$got" >"$got_keys"
	if diff -u "$want_keys" "$got_keys" >"$TEST_TMP/json-keys.diff"; then
		pass "$name"
	else
		printf '%s\n' '--- krb5_admin keys ---' >&2
		cat "$want_keys" >&2
		printf '%s\n' '--- bifrost keys ---' >&2
		cat "$got_keys" >&2
		fail "$name"
	fi
}

compare_local_null_mutation() {
	name=$1
	shift
	compare_local_json "$name" "$@"
}

compare_local_exit_mutation() {
	name=$1
	shift
	ka_out="$TEST_TMP/local-exit.ka.out"
	ka_err="$TEST_TMP/local-exit.ka.err"
	bf_out="$TEST_TMP/local-exit.bf.out"
	bf_err="$TEST_TMP/local-exit.bf.err"

	if ! krb5_admin -l -D "db:$KA_HDB" -S "$KA_DB" "$@" \
	    >"$ka_out" 2>"$ka_err"; then
		printf 'krb5_admin command failed: %s\n' "$*" >&2
		cat "$ka_err" >&2
		fail "$name"
	fi
	if ! bifrost -l -D "db:$BF_HDB" -S "$BF_DB" "$@" \
	    >"$bf_out" 2>"$bf_err"; then
		printf 'bifrost command failed: %s\n' "$*" >&2
		cat "$bf_err" >&2
		fail "$name"
	fi
	pass "$name"
}

compare_local_fail() {
	name=$1
	shift
	ka_out="$TEST_TMP/local-fail.ka.out"
	ka_err="$TEST_TMP/local-fail.ka.err"
	bf_out="$TEST_TMP/local-fail.bf.out"
	bf_err="$TEST_TMP/local-fail.bf.err"

	if krb5_admin -J -l -D "db:$KA_HDB" -S "$KA_DB" "$@" \
	    >"$ka_out" 2>"$ka_err"; then
		printf 'krb5_admin command unexpectedly succeeded: %s\n' "$*" >&2
		cat "$ka_out" >&2
		fail "$name"
	fi
	if bifrost -J -l -D "db:$BF_HDB" -S "$BF_DB" "$@" \
	    >"$bf_out" 2>"$bf_err"; then
		printf 'bifrost command unexpectedly succeeded: %s\n' "$*" >&2
		cat "$bf_out" >&2
		fail "$name"
	fi
	pass "$name"
}

compare_local_table_names() {
	name=$1
	want="$TEST_TMP/tables.want"
	got="$TEST_TMP/tables.got"

	sqlite3 "$KA_DB" \
	    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name" \
	    >"$want"
	sqlite3 "$BF_DB" \
	    "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name" \
	    >"$got"

	if diff -u "$want" "$got" >"$TEST_TMP/tables.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/tables.diff" >&2
		fail "$name"
	fi
}

local_principal_state() {
	out=$1
	tool=$2
	hdb=$3
	db=$4
	principal=$5
	raw=$(tmp_json)

	parity_json_cmd "$raw" "$tool" -J -l \
	    -D "db:$hdb" -S "$db" query "$principal"
	normal_query <"$raw" >"$out"
}

compare_local_principal() {
	name=$1
	principal=$2
	want=$(tmp_json)
	got=$(tmp_json)

	local_principal_state "$want" krb5_admin "$KA_HDB" "$KA_DB" \
	    "$principal"
	local_principal_state "$got" bifrost "$BF_HDB" "$BF_DB" \
	    "$principal"
	json_eq_files "$name" "$want" "$got"
}

local_host_state() {
	out=$1
	tool=$2
	hdb=$3
	db=$4
	host=$5
	raw=$(tmp_json)

	parity_json_cmd "$raw" "$tool" -J -l \
	    -D "db:$hdb" -S "$db" query_host "$host"
	normal_host_query <"$raw" >"$out"
}

compare_local_host() {
	name=$1
	host=$2
	want=$(tmp_json)
	got=$(tmp_json)

	local_host_state "$want" krb5_admin "$KA_HDB" "$KA_DB" "$host"
	local_host_state "$got" bifrost "$BF_HDB" "$BF_DB" "$host"
	json_eq_files "$name" "$want" "$got"
}

local_host_secret_id_state() {
	db=$1
	out=$2

	sqlite3 "$db" <<'EOS' >"$out"
SELECT id, length(secret), secret IS NOT NULL
FROM host_secret_ids
ORDER BY id;
EOS
}

compare_local_host_secret_ids() {
	name=$1
	want="$TEST_TMP/host-secret-ids.want"
	got="$TEST_TMP/host-secret-ids.got"

	local_host_secret_id_state "$KA_DB" "$want"
	local_host_secret_id_state "$BF_DB" "$got"
	if diff -u "$want" "$got" >"$TEST_TMP/host-secret-ids.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/host-secret-ids.diff" >&2
		fail "$name"
	fi
}

local_host_secret_binding_state() {
	db=$1
	out=$2

	sqlite3 "$db" <<'EOS' >"$out"
SELECT name, id
FROM host_secrets
ORDER BY name, id;
EOS
}

compare_local_host_secret_bindings() {
	name=$1
	want="$TEST_TMP/host-secret-bindings.want"
	got="$TEST_TMP/host-secret-bindings.got"

	local_host_secret_binding_state "$KA_DB" "$want"
	local_host_secret_binding_state "$BF_DB" "$got"
	if diff -u "$want" "$got" >"$TEST_TMP/host-secret-bindings.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/host-secret-bindings.diff" >&2
		fail "$name"
	fi
}

local_subject_state() {
	out=$1
	tool=$2
	hdb=$3
	db=$4
	kind=$5
	state_subject=$6
	raw=$(tmp_json)

	case "$kind" in
	subject) verb=query_subject ;;
	group) verb=query_group ;;
	*) fail "unknown local subject kind $kind" ;;
	esac

	parity_json_cmd "$raw" "$tool" -J -l \
	    -D "db:$hdb" -S "$db" "$verb" "$state_subject"
	normal_subject_query <"$raw" >"$out"
}

compare_local_subject() {
	subject_test_name=$1
	subject_kind=$2
	subject_name=$3
	want=$(tmp_json)
	got=$(tmp_json)

	local_subject_state "$want" krb5_admin "$KA_HDB" "$KA_DB" \
	    "$subject_kind" "$subject_name"
	local_subject_state "$got" bifrost "$BF_HDB" "$BF_DB" \
	    "$subject_kind" "$subject_name"
	json_eq_files "$subject_test_name" "$want" "$got"
}

local_pair native
compare_local_json "local query native parity" query admin
compare_local_null_mutation "local modify native output parity" \
    modify admin attributes-=needchange
compare_local_principal "local modify native post-state parity" \
    admin

local_initdb_pair initdb
compare_local_null_mutation "local init_db output parity" init_db
compare_local_table_names "local init_db table-name parity"

local_pair keyfetch
compare_local_json "local fetch parity" fetch admin
compare_local_json "local fetch_old parity" fetch_old admin
compare_local_json_string_length "local generate_ecdh_key1 output shape parity" \
    64 generate_ecdh_key1

prefix=$(unique_name local-parity)
user="$prefix-user@$REALM"
service="service/$prefix.example.com@$REALM"
appid="$prefix-app"
appid_princ="$appid@$REALM"
owner="$prefix-owner@$REALM"
subject="$prefix-subject@$REALM"
group="$prefix-group"
host="$prefix.example.com"
host2="$prefix-2.example.com"
logical="$prefix-logical.example.com"
acl="$prefix-acl@$REALM"
aclgroup="$prefix-aclgroup"
account="$prefix-account"

local_pair principal
compare_local_json_type "local create_user output shape parity" string \
    create_user "$user"
compare_local_principal "local create_user post-state parity" "$user"
compare_local_null_mutation "local principal modify output parity" \
    modify "$user" attributes-=needchange
compare_local_principal "local principal modify post-state parity" "$user"
compare_local_json_type "local reset_passwd output shape parity" string \
    reset_passwd "$user"
compare_local_principal "local reset_passwd post-state parity" "$user"
compare_local_json_type "local change_passwd output shape parity" string \
    change_passwd "$user" "$prefix-password"
compare_local_principal "local change_passwd post-state parity" "$user"
compare_local_null_mutation "local disable output parity" disable "$user"
compare_local_principal "local disable post-state parity" "$user"
compare_local_null_mutation "local enable output parity" enable "$user"
compare_local_principal "local enable post-state parity" "$user"
compare_local_null_mutation "local create service output parity" \
    create "$service"
compare_local_principal "local create service post-state parity" "$service"
compare_local_null_mutation "local remove output parity" remove "$user"

local_pair subjects
compare_local_null_mutation "local create owner subject output parity" \
    create_subject "$owner" type=krb5
compare_local_null_mutation "local create subject output parity" \
    create_subject "$subject" type=krb5 "owner=$owner"
compare_local_subject "local create_subject post-state parity" \
    subject "$subject"
compare_local_json "local query_subject parity" query_subject "$subject"
compare_local_json "local list_subject parity" list_subject type=krb5
compare_local_json "local search_subject parity" search_subject type=krb5
compare_local_null_mutation "local create group output parity" \
    create_group "$group" "owner=$owner"
compare_local_null_mutation "local modify group output parity" \
    modify_group "$group" "member+=$subject"
compare_local_subject "local modify_group post-state parity" group "$group"
compare_local_json "local query_group parity" query_group "$group"
compare_local_json "local list_group parity" list_group
compare_local_json "local search_group parity" search_group type=group
compare_local_null_mutation "local remove group output parity" \
    remove_group "$group"
compare_local_null_mutation "local remove subject output parity" \
    remove_subject "$subject"

local_pair appid
compare_local_null_mutation "local appid owner subject output parity" \
    create_subject "$owner" type=krb5
compare_local_null_mutation "local create_appid output parity" \
    create_appid "$appid"
compare_local_null_mutation "local modify appid output parity" \
    modify "$appid_princ" "owner=$owner" desc="local parity appid"
compare_local_principal "local create_appid post-state parity" "$appid_princ"
compare_local_json "local is_appid_owner true parity" \
    is_appid_owner "$owner" "$appid_princ"
compare_local_json "local is_owner alias true parity" \
    is_owner "$owner" "$appid_princ"
compare_local_json "local is_pwner alias true parity" \
    is_pwner "$owner" "$appid_princ"

local_pair hosts
compare_local_null_mutation "local create host owner subject output parity" \
    create_subject "$owner" type=krb5
compare_local_null_mutation "local create host output parity" \
    create_host "$host" realm="$REALM" ip_addr=10.91.0.1
compare_local_host "local create_host post-state parity" "$host"
compare_local_json "local query_host parity" query_host "$host"
compare_local_json "local search_host parity" search_host realm="$REALM"
compare_local_null_mutation "local create service for host output parity" \
    create "$service"
compare_local_null_mutation "local bind_host output parity" \
    bind_host "$host" "$service"
compare_local_host "local bind_host post-state parity" "$host"
compare_local_null_mutation "local create second host output parity" \
    create_host "$host2" realm="$REALM" ip_addr=10.91.0.2
compare_local_null_mutation "local create logical host output parity" \
    create_logical_host "$logical" "owner=$owner"
compare_local_null_mutation "local insert_hostmap output parity" \
    insert_hostmap "$logical" "$host"
compare_local_null_mutation "local insert_hostmap second output parity" \
    insert_hostmap "$logical" "$host2"
compare_local_json "local query_hostmap parity" query_hostmap "$logical"
compare_local_json "local list_table hosts parity" list_table hosts
compare_local_null_mutation "local remove_hostmap output parity" \
    remove_hostmap "$logical" "$host2"
compare_local_null_mutation "local remove host output parity" \
    remove_host "$host2"

local_pair hostlocks
compare_local_null_mutation "local lock host principal setup parity" \
    create "$service"
compare_local_null_mutation "local lock_hostprinc output parity" \
    lock_hostprinc "$service"
compare_local_fail "local standalone unlock_hostprinc failure parity" \
    unlock_hostprinc "$service"

local_pair hostsecrets
compare_local_null_mutation "local host-secret host output parity" \
    create_host "$host" realm="$REALM" ip_addr=10.91.0.4
compare_local_null_mutation "local new_host_secret output parity" \
    new_host_secret
compare_local_host_secret_ids "local new_host_secret state parity"
compare_local_json "local bind_host_secret output parity" \
    bind_host_secret "$host"
compare_local_host_secret_bindings "local bind_host_secret state parity"
compare_local_json_type "local read_host_secret output shape parity" string \
    read_host_secret "$host"

local_pair acls
compare_local_null_mutation "local create acl owner subject output parity" \
    create_subject "$owner" type=krb5
compare_local_null_mutation "local add_acl output parity" add_acl "$acl" krb5
compare_local_null_mutation "local add_acl group output parity" \
    add_acl "$aclgroup" group "owner=$owner"
compare_local_null_mutation "local insert_aclgroup output parity" \
    insert_aclgroup "$aclgroup" "$acl"
compare_local_json "local query_acl parity" query_acl
compare_local_json "local query_aclgroup parity" query_aclgroup "$aclgroup"
compare_local_null_mutation "local add_acl_owner output parity" \
    add_acl_owner "$aclgroup" "$acl"
compare_local_json "local query_acl_owner parity" query_acl_owner "$aclgroup"
compare_local_exit_mutation "local remove_acl_owner exit parity" \
    remove_acl_owner "$aclgroup" "$acl"
compare_local_null_mutation "local remove_aclgroup output parity" \
    remove_aclgroup "$aclgroup" "$acl"

local_pair sacls
compare_local_null_mutation "local create sacl subject output parity" \
    create_subject "$subject" type=krb5
compare_local_null_mutation "local sacls_add output parity" \
    sacls_add query "$subject"
compare_local_json "local sacls_query parity" sacls_query verb=query
compare_local_null_mutation "local sacls_del output parity" \
    sacls_del query "$subject"

local_pair maps-tickets
compare_local_null_mutation "local create map host output parity" \
    create_host "$host" realm="$REALM" ip_addr=10.91.0.3
compare_local_null_mutation "local principal_map_add output parity" \
    principal_map_add "$account" HTTP "$host"
compare_local_json "local principal_map_query parity" \
    principal_map_query "$account" "HTTP/$host@$REALM"
compare_local_null_mutation "local principal_map_remove output parity" \
    principal_map_remove "$account" HTTP "$host"
compare_local_null_mutation "local create ticket appid output parity" \
    create_appid "$appid"
compare_local_null_mutation "local insert_ticket output parity" \
    insert_ticket "$appid_princ" "$host"
compare_local_json "local query_ticket principal parity" \
    query_ticket principal "$appid_princ"
compare_local_json "local query_ticket host parity" query_ticket host "$host"
compare_local_null_mutation "local refresh_ticket output parity" \
    refresh_ticket "$appid_princ" "$host"
compare_local_json_object_keys "local fetch_tickets principal set parity" \
    fetch_tickets "$REALM" "$host"
compare_local_null_mutation "local remove_ticket output parity" \
    remove_ticket "$appid_princ" "$host"

finish_tests
