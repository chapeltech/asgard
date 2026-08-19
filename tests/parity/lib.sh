#!/bin/sh

set -eu
. /tests/lib.sh

PARITY_DIR=${PARITY_DIR:-/tests/parity}

parity_norm_json() {
	jq -S '
	    def norm:
	        if type == "object" then
	            with_entries(.value |= norm)
	        elif type == "array" then
	            map(norm) | sort_by(tojson)
	        else
	            .
	        end;
	    norm
	'
}

parity_json_cmd() {
	out=$1
	shift
	raw=$(tmp_json)
	err="$TEST_TMP/json.err"

	if ! "$@" >"$raw" 2>"$err"; then
		printf 'command failed: %s\n' "$*" >&2
		printf '%s\n' '--- stderr ---' >&2
		cat "$err" >&2
		fail "create parity json for $*"
	fi

	if ! parity_norm_json <"$raw" >"$out"; then
		printf 'invalid json from: %s\n' "$*" >&2
		printf '%s\n' '--- stdout ---' >&2
		cat "$raw" >&2
		fail "parse parity json for $*"
	fi
}

json_subset_files() {
	name=$1
	want=$2
	got=$3

	if jq -n -e --slurpfile want "$want" --slurpfile got "$got" '
	    def subset($want; $got):
	        if ($want | type) == "object" then
	            (($got | type) == "object") and
	            (((($want | keys_unsorted) | length) == 0) or
	            all(($want | keys_unsorted[]); . as $key |
	                (($got | has($key)) and
	                subset($want[$key]; $got[$key]))))
	        elif ($want | type) == "array" then
	            (($got | type) == "array") and
	            ((($want | length) == 0) or
	            all($want[]; . as $entry |
	                any($got[]; subset($entry; .))))
	        else
	            $want == $got
	        end;
	    subset($want[0]; $got[0])
	' >/dev/null; then
		pass "$name"
		return
	fi

	printf '%s\n' '--- expected subset ---' >&2
	jq -S . "$want" >&2
	printf '%s\n' '--- actual ---' >&2
	jq -S . "$got" >&2
	fail "$name"
}

compare_legacy_bifrost_json() {
	name=$1
	shift
	want=$(tmp_json)
	got=$(tmp_json)

	parity_json_cmd "$want" krb5_admin -J "$@"
	parity_json_cmd "$got" bifrost -J "$@"
	json_subset_files "$name" "$want" "$got"
}

compare_legacy_bifrost_native_json() {
	name=$1
	shift
	want=$(tmp_json)
	got=$(tmp_json)

	parity_json_cmd "$want" krb5_admin -J "$@"
	parity_json_cmd "$got" bifrost -J -h "$KDC1" "$@"
	json_subset_files "$name" "$want" "$got"
}

compare_exit() {
	name=$1
	shift

	if "$@" >/dev/null 2>"$TEST_TMP/exit.err"; then
		pass "$name"
	else
		printf 'command failed: %s\n' "$*" >&2
		cat "$TEST_TMP/exit.err" >&2
		fail "$name"
	fi
}

compare_legacy_bifrost_fail() {
	name=$1
	shift

	if krb5_admin -J "$@" >"$TEST_TMP/legacy-fail.out" \
	    2>"$TEST_TMP/legacy-fail.err"; then
		printf 'legacy command unexpectedly succeeded: krb5_admin -J %s\n' \
		    "$*" >&2
		cat "$TEST_TMP/legacy-fail.out" >&2
		fail "$name"
	fi

	if bifrost -J "$@" >"$TEST_TMP/bifrost-fail.out" \
	    2>"$TEST_TMP/bifrost-fail.err"; then
		printf 'bifrost command unexpectedly succeeded: bifrost -J %s\n' \
		    "$*" >&2
		cat "$TEST_TMP/bifrost-fail.out" >&2
		fail "$name"
	fi

	pass "$name"
}

normal_principal_state_cmd() {
	out=$1
	tool=$2
	principal=$3
	raw=$(tmp_json)

	case "$tool" in
	krb5_admin)
		parity_json_cmd "$raw" krb5_admin -J query "$principal"
		;;
	bifrost)
		parity_json_cmd "$raw" bifrost -J query "$principal"
		;;
	*)
		fail "unknown principal state tool $tool"
		;;
	esac
	normal_query_principal <"$raw" >"$out"
}

compare_principal_state() {
	name=$1
	legacy_principal=$2
	bifrost_principal=$3
	want=$(tmp_json)
	got=$(tmp_json)

	normal_principal_state_cmd "$want" krb5_admin "$legacy_principal"
	normal_principal_state_cmd "$got" bifrost "$bifrost_principal"
	json_eq_files "$name" "$want" "$got"
}

normal_host_query() {
	jq -S '{
	    realm: (.realm // null),
	    ip_addr: (.ip_addr // null),
	    is_logical: (((.is_logical // 0) | tostring)),
	    bootbinding: (.bootbinding // null),
	    label: ((.label // []) | sort),
	    owner: ((.owner // []) | sort),
	    member: ((.member // []) | sort)
	}'
}

normal_host_state_cmd() {
	out=$1
	tool=$2
	host=$3
	raw=$(tmp_json)

	case "$tool" in
	krb5_admin)
		parity_json_cmd "$raw" krb5_admin -J query_host "$host"
		;;
	bifrost)
		parity_json_cmd "$raw" bifrost -J query_host "$host"
		;;
	*)
		fail "unknown host state tool $tool"
		;;
	esac
	normal_host_query <"$raw" >"$out"
}

compare_host_state() {
	name=$1
	legacy_host=$2
	bifrost_host=$3
	want=$(tmp_json)
	got=$(tmp_json)

	normal_host_state_cmd "$want" krb5_admin "$legacy_host"
	normal_host_state_cmd "$got" bifrost "$bifrost_host"
	json_eq_files "$name" "$want" "$got"
}

normal_subject_query() {
	jq -S '{
	    type: (.type // null),
	    owner: ((.owner // []) | sort),
	    member: ((.member // []) | sort)
	}'
}

normal_subject_state_cmd() {
	out=$1
	tool=$2
	kind=$3
	subject=$4
	raw=$(tmp_json)

	case "$tool:$kind" in
	krb5_admin:subject)
		parity_json_cmd "$raw" krb5_admin -J query_subject "$subject"
		;;
	bifrost:subject)
		parity_json_cmd "$raw" bifrost -J query_subject "$subject"
		;;
	krb5_admin:group)
		parity_json_cmd "$raw" krb5_admin -J query_group "$subject"
		;;
	bifrost:group)
		parity_json_cmd "$raw" bifrost -J query_group "$subject"
		;;
	*)
		fail "unknown subject state tool $tool $kind"
		;;
	esac
	normal_subject_query <"$raw" >"$out"
}

compare_subject_state() {
	name=$1
	kind=$2
	legacy_subject=$3
	bifrost_subject=$4
	want=$(tmp_json)
	got=$(tmp_json)

	normal_subject_state_cmd "$want" krb5_admin "$kind" "$legacy_subject"
	normal_subject_state_cmd "$got" bifrost "$kind" "$bifrost_subject"
	json_eq_files "$name" "$want" "$got"
}

manifest_entries() {
	file=$1

	grep -v '^[[:space:]]*#' "$file" |
	    awk -F'|' 'NF > 0 && $1 != "" { print $1 }' |
	    sort -u
}

require_manifest_entries() {
	name=$1
	expected=$2
	actual=$3
	missing="$TEST_TMP/$name.missing"
	extra="$TEST_TMP/$name.extra"

	comm -23 "$expected" "$actual" >"$missing"
	comm -13 "$expected" "$actual" >"$extra"
	if [ -s "$missing" ] || [ -s "$extra" ]; then
		printf '%s manifest mismatch\n' "$name" >&2
		if [ -s "$missing" ]; then
			printf '%s\n' '--- missing rows ---' >&2
			cat "$missing" >&2
		fi
		if [ -s "$extra" ]; then
			printf '%s\n' '--- unknown rows ---' >&2
			cat "$extra" >&2
		fi
		fail "$name manifest is complete"
	fi
	pass "$name manifest is complete"
}
