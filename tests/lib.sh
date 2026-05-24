REALM=${REALM:-EXAMPLE.COM}
KDC1=${KDC1:-kdc1.example.com}
KDC2=${KDC2:-kdc2.example.com}
ADMIN=${ADMIN:-admin@$REALM}
TEST_TMP=${TEST_TMP:-/tmp/asgard-admin-tests.$$}

mkdir -p "$TEST_TMP"

pass_count=0
test_count=0

note() {
	printf '%s\n' "---- $*"
}

pass() {
	test_count=$((test_count + 1))
	pass_count=$((pass_count + 1))
	printf 'ok %d - %s\n' "$test_count" "$*"
}

fail() {
	test_count=$((test_count + 1))
	printf 'not ok %d - %s\n' "$test_count" "$*"
	exit 1
}

run_ok() {
	name=$1
	shift
	out="$TEST_TMP/run.out"
	err="$TEST_TMP/run.err"

	if "$@" >"$out" 2>"$err"; then
		pass "$name"
	else
		printf 'command failed: %s\n' "$*" >&2
		printf '%s\n' '--- stdout ---' >&2
		cat "$out" >&2
		printf '%s\n' '--- stderr ---' >&2
		cat "$err" >&2
		fail "$name"
	fi
}

run_fail() {
	name=$1
	shift
	out="$TEST_TMP/run.out"
	err="$TEST_TMP/run.err"

	if "$@" >"$out" 2>"$err"; then
		printf 'command unexpectedly succeeded: %s\n' "$*" >&2
		cat "$out" >&2
		fail "$name"
	else
		pass "$name"
	fi
}

tmp_json() {
	mktemp "$TEST_TMP/json.XXXXXX"
}

json_cmd() {
	out=$1
	shift
	raw="$TEST_TMP/json.raw"
	err="$TEST_TMP/json.err"

	if ! "$@" >"$raw" 2>"$err"; then
		printf 'command failed: %s\n' "$*" >&2
		printf '%s\n' '--- stderr ---' >&2
		cat "$err" >&2
		fail "create json for $*"
	fi

	if ! jq -S . "$raw" >"$out"; then
		printf 'invalid json from: %s\n' "$*" >&2
		printf '%s\n' '--- stdout ---' >&2
		cat "$raw" >&2
		fail "parse json for $*"
	fi
}

json_eq_files() {
	name=$1
	want=$2
	got=$3

	if diff -u "$want" "$got" >"$TEST_TMP/diff.out"; then
		pass "$name"
	else
		printf '%s\n' '--- json diff ---' >&2
		cat "$TEST_TMP/diff.out" >&2
		fail "$name"
	fi
}

json_field_eq() {
	name=$1
	file=$2
	filter=$3
	want=$4
	got=$(jq -r "$filter" "$file")

	if [ "$got" = "$want" ]; then
		pass "$name"
	else
		printf 'wanted: %s\n' "$want" >&2
		printf 'got:    %s\n' "$got" >&2
		fail "$name"
	fi
}

json_filter_true() {
	name=$1
	file=$2
	shift 2

	if jq -e "$@" "$file" >/dev/null; then
		pass "$name"
	else
		printf 'filter did not match: %s\n' "$*" >&2
		jq -S . "$file" >&2
		fail "$name"
	fi
}

json_filter_false() {
	name=$1
	file=$2
	shift 2

	if jq -e "$@" "$file" >/dev/null; then
		printf 'filter unexpectedly matched: %s\n' "$*" >&2
		jq -S . "$file" >&2
		fail "$name"
	else
		pass "$name"
	fi
}

json_key_exists() {
	name=$1
	file=$2
	key=$3

	if jq -e --arg key "$key" 'has($key)' "$file" >/dev/null; then
		pass "$name"
	else
		printf 'object did not contain key %s\n' "$key" >&2
		jq -S . "$file" >&2
		fail "$name"
	fi
}

json_key_field_eq() {
	name=$1
	file=$2
	key=$3
	field=$4
	want=$5
	got=$(jq -r --arg key "$key" --arg field "$field" \
	    '.[$key][$field]' "$file")

	if [ "$got" = "$want" ]; then
		pass "$name"
	else
		printf 'wanted: %s\n' "$want" >&2
		printf 'got:    %s\n' "$got" >&2
		fail "$name"
	fi
}

json_key_array_has() {
	name=$1
	file=$2
	key=$3
	field=$4
	want=$5

	if jq -e --arg key "$key" --arg field "$field"		\
	    --arg want "$want" '.[$key][$field] | index($want)'	\
	    "$file" >/dev/null; then
		pass "$name"
	else
		printf 'array did not contain %s\n' "$want" >&2
		jq -S --arg key "$key" --arg field "$field"	\
		    '.[$key][$field]' "$file" >&2
		fail "$name"
	fi
}

json_array_has() {
	name=$1
	file=$2
	filter=$3
	want=$4

	if jq -e --arg want "$want" "$filter | index(\$want)" "$file" \
	    >/dev/null; then
		pass "$name"
	else
		printf 'array did not contain %s\n' "$want" >&2
		jq -S "$filter" "$file" >&2
		fail "$name"
	fi
}

json_array_lacks() {
	name=$1
	file=$2
	filter=$3
	want=$4

	if jq -e --arg want "$want" "$filter | index(\$want)" "$file" \
	    >/dev/null; then
		printf 'array unexpectedly contained %s\n' "$want" >&2
		jq -S "$filter" "$file" >&2
		fail "$name"
	else
		pass "$name"
	fi
}

normal_query() {
	jq -S '{
	    principal: (.principal // null),
	    owner: ((.owner // []) | sort),
	    desc: (.desc // null),
	    cstraint: ((.cstraint // []) | sort),
	    policy: (.policy // null),
	    kvno: ((.kvno // null) | if . == null then null else tostring end),
	    attributes: ((.attributes // []) | sort),
	    keys: ((.keys // [])
	        | map({enctype: (.enctype | tostring), kvno: (.kvno | tostring)})
	        | sort_by(.kvno, .enctype))
	}'
}

normal_query_principal() {
	normal_query | jq -S '.principal = "<principal>"'
}

normal_query_cmd() {
	out=$1
	shift
	raw=$(tmp_json)

	json_cmd "$raw" "$@"
	normal_query <"$raw" >"$out"
}

admin_json() {
	krb5_admin -J "$@"
}

bifrost_json() {
	bifrost -J "$@"
}

create_user_password() {
	principal=$1

	bifrost create_user "$principal" | sed "s,^.*'\(.*\)',\1,"
}

kinit_ccache() {
	principal=$1
	password=$2
	ccache=$3

	printf '%s\n' "$password" | env KRB5CCNAME="FILE:$ccache" \
	    kinit "$principal"
}

bifrost_ccache() {
	ccache=$1
	shift

	env KRB5CCNAME="FILE:$ccache" bifrost "$@"
}

bifrost_http() {
	method=$1
	path=$2
	body=$3
	host=${4:-$KDC1}

	curl -sS --fail-with-body -X "$method"			\
	    -H 'content-type: application/json'			\
	    -H "x-bifrost-actor: $ADMIN"			\
	    -H "x-bifrost-negotiate: $ADMIN"			\
	    --data "$body"					\
	    "http://$host:2666$path"
}

json_string() {
	printf '%s' "$1" | jq -Rs .
}

http_query_json() {
	principal=$1
	body=$(json_string "$principal")

	bifrost_http QUERY /v1/kdc/query "$body"
}

unique_name() {
	prefix=$1
	printf 'bf-%s-%s' "$prefix" "$$"
}

cleanup_principal() {
	principal=$1
	bifrost remove "$principal" >/dev/null 2>&1 || true
}

cleanup_subject() {
	subject=$1
	bifrost remove_subject "$subject" >/dev/null 2>&1 || true
}

cleanup_group() {
	group=$1
	bifrost remove_group "$group" >/dev/null 2>&1 || true
}

cleanup_host() {
	host=$1
	bifrost remove_host "$host" >/dev/null 2>&1 || true
}

finish_tests() {
	printf 'completed %d tests\n' "$pass_count"
}
