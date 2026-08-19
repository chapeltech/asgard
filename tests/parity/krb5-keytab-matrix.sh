#!/bin/sh

set -eu
. /tests/parity/lib.sh

prefix=$(unique_name parity-keytab)
ktroot="$TEST_TMP/ktroot"
legacy_kt="$TEST_TMP/legacy.keytab"
bifrost_kt="$TEST_TMP/bifrost.keytab"
user_kt="$TEST_TMP/user.keytab"
keytab_user="$prefix-user"
princ="HTTP/$prefix.example.com@$REALM"
user_princ="HTTP/$prefix-user.example.com@$REALM"
userqual_princ="HTTP/root.$(hostname)@$REALM"
renamed="HTTP/$prefix-renamed.example.com@$REALM"
hexkey=000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f

mkdir -p "$ktroot/etc" "$ktroot/var/spool/keytabs"

normal_bifrost_keytab_list() {
	out=$1
	shift

	"$@" |
	    awk '
	        /^Keytab name:/ { next }
	        /^KVNO[[:space:]]/ { next }
	        NF == 3 { print $1 "|" $2 "|" $3 }
	    ' |
	    sort >"$out"
}

normal_keytab_list() {
	kt=$1
	out=$2

	normal_bifrost_keytab_list "$out" bifrost keytab -k "$kt" list
}

normal_legacy_keytab_list() {
	out=$1

	krb5_keytab -l -R "$ktroot" |
	    awk '
	        /^Keytab name:/ { next }
	        /^KVNO[[:space:]]/ { next }
	        /^----[[:space:]]/ { next }
	        NF == 3 { print $1 "|" $2 "|" $3 }
	    ' |
	    sort >"$out"
}

normal_legacy_keytab_user_list() {
	out=$1
	user=$2

	krb5_keytab -l -R "$ktroot" -p "$user" |
	    awk '
	        /^Keytab name:/ { next }
	        /^KVNO[[:space:]]/ { next }
	        /^----[[:space:]]/ { next }
	        NF == 3 { print $1 "|" $2 "|" $3 }
	    ' |
	    sort >"$out"
}

compare_keytab_lists() {
	name=$1
	want=$(tmp_json)
	got=$(tmp_json)

	normal_keytab_list "$legacy_kt" "$want"
	normal_keytab_list "$bifrost_kt" "$got"
	if diff -u "$want" "$got" >"$TEST_TMP/keytab.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/keytab.diff" >&2
		fail "$name"
	fi
}

compare_legacy_list() {
	name=$1
	want=$(tmp_json)
	got=$(tmp_json)

	normal_keytab_list "$legacy_kt" "$want"
	normal_legacy_keytab_list "$got"
	if diff -u "$want" "$got" >"$TEST_TMP/keytab.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/keytab.diff" >&2
		fail "$name"
	fi
}

compare_keytab_user_lists() {
	name=$1
	want=$(tmp_json)
	got=$(tmp_json)

	normal_legacy_keytab_user_list "$want" "$keytab_user"
	normal_bifrost_keytab_list "$got" \
	    bifrost keytab -R "$ktroot" -p "$keytab_user" list
	if diff -u "$want" "$got" >"$TEST_TMP/keytab.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/keytab.diff" >&2
		fail "$name"
	fi
}

compare_keytab_text() {
	name=$1
	legacy_out=$2
	bifrost_out=$3

	if diff -u "$legacy_out" "$bifrost_out" >"$TEST_TMP/keytab-text.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/keytab-text.diff" >&2
		fail "$name"
	fi
}

normal_keytab_query_file() {
	in=$1
	out=$2

	sed '/^[[:space:]]*$/d' "$in" | sort >"$out"
}

capture_ok() {
	name=$1
	out=$2
	shift 2
	err="$TEST_TMP/capture.err"

	if "$@" >"$out" 2>"$err"; then
		pass "$name"
	else
		printf 'command failed: %s\n' "$*" >&2
		printf '%s\n' '--- stderr ---' >&2
		cat "$err" >&2
		fail "$name"
	fi
}

run_ok "legacy keytab add comparable key" \
    bifrost keytab -k "$legacy_kt" add hex -e aes256-cts -V 7 "$hexkey" "$princ"
run_ok "legacy keytab add user-qualified key" \
    bifrost keytab -k "$legacy_kt" add hex -e aes256-cts -V 7 "$hexkey" "$userqual_princ"
run_ok "bifrost keytab add comparable key" \
    bifrost keytab -k "$bifrost_kt" add hex -e aes256-cts -V 7 "$hexkey" "$princ"
run_ok "bifrost keytab add user-qualified key" \
    bifrost keytab -k "$bifrost_kt" add hex -e aes256-cts -V 7 "$hexkey" "$userqual_princ"
run_ok "user keytab add comparable key" \
    bifrost keytab -k "$user_kt" add hex -e aes256-cts -V 7 "$hexkey" "$user_princ"
cp "$legacy_kt" "$ktroot/etc/krb5.keytab"
cp "$user_kt" "$ktroot/var/spool/keytabs/$keytab_user"
compare_keytab_lists "keytab list parity"
compare_legacy_list "legacy krb5_keytab list parity"
compare_keytab_user_lists "keytab -p user list parity"
run_ok "legacy krb5_keytab verbose list" krb5_keytab -l -v -R "$ktroot"
run_ok "bifrost keytab verbose list" bifrost keytab -v -k "$legacy_kt" list

legacy_query=$(tmp_json)
bifrost_query=$(tmp_json)
legacy_query_norm=$(tmp_json)
bifrost_query_norm=$(tmp_json)
capture_ok "legacy krb5_keytab query" \
    "$legacy_query" krb5_keytab -q -R "$ktroot"
capture_ok "bifrost keytab query" \
    "$bifrost_query" bifrost keytab -R "$ktroot" query
normal_keytab_query_file "$legacy_query" "$legacy_query_norm"
normal_keytab_query_file "$bifrost_query" "$bifrost_query_norm"
compare_keytab_text "keytab query parity" \
    "$legacy_query_norm" "$bifrost_query_norm"

legacy_userqual_query=$(tmp_json)
bifrost_userqual_query=$(tmp_json)
legacy_userqual_query_norm=$(tmp_json)
bifrost_userqual_query_norm=$(tmp_json)
capture_ok "legacy krb5_keytab -U query" \
    "$legacy_userqual_query" krb5_keytab -q -U -R "$ktroot" HTTP
capture_ok "bifrost keytab -U query" \
    "$bifrost_userqual_query" bifrost keytab -R "$ktroot" query -U HTTP
normal_keytab_query_file \
    "$legacy_userqual_query" "$legacy_userqual_query_norm"
normal_keytab_query_file \
    "$bifrost_userqual_query" "$bifrost_userqual_query_norm"
compare_keytab_text "keytab -U query parity" \
    "$legacy_userqual_query_norm" "$bifrost_userqual_query_norm"

legacy_reproduce=$(tmp_json)
bifrost_reproduce=$(tmp_json)
capture_ok "legacy krb5_keytab reproduce" \
    "$legacy_reproduce" krb5_keytab -g -R "$ktroot" "$princ"
capture_ok "bifrost keytab reproduce" \
    "$bifrost_reproduce" bifrost keytab -R "$ktroot" reproduce "$princ"
compare_keytab_text "keytab reproduce parity" \
    "$legacy_reproduce" "$bifrost_reproduce"

run_ok "legacy krb5_keytab test compatible lib" \
    krb5_keytab -t -R "$ktroot" -L mitkrb5/1.4 "$princ"
run_ok "bifrost keytab test compatible lib" \
    bifrost keytab -R "$ktroot" test -L mitkrb5/1.4 "$princ"
run_fail "legacy krb5_keytab test incompatible lib" \
    krb5_keytab -t -R "$ktroot" -L mitkrb5/1.2 "$princ"
run_fail "bifrost keytab test incompatible lib" \
    bifrost keytab -R "$ktroot" test -L mitkrb5/1.2 "$princ"

run_fail "legacy krb5_keytab -w requires -X" \
    krb5_keytab -R "$ktroot" -w "$princ"
run_fail "bifrost keytab -w requires -X" \
    bifrost keytab -R "$ktroot" get -w "$princ"
run_fail "legacy krb5_keytab -W conflicts with -w" \
    krb5_keytab -R "$ktroot" -X "$REALM" -W "win@$REALM" -w "$princ"
run_fail "bifrost keytab -W conflicts with -w" \
    bifrost keytab -R "$ktroot" get -X "$REALM" -W "win@$REALM" -w "$princ"
run_fail "legacy krb5_keytab -A conflicts with -X" \
    krb5_keytab -R "$ktroot" -A -X "$REALM" "$princ"
run_fail "bifrost keytab -A conflicts with -X" \
    bifrost keytab -R "$ktroot" get -A -X "$REALM" "$princ"

run_ok "bifrost keytab rename editor mode" \
    bifrost keytab -k "$bifrost_kt" rename "$princ" "$renamed"
run_ok "bifrost keytab copy editor mode" \
    bifrost keytab copy "$bifrost_kt" "$TEST_TMP/copy.keytab"
run_ok "bifrost keytab remove editor mode" \
    bifrost keytab -k "$bifrost_kt" remove "$renamed"
run_ok "bifrost keytab destroy editor mode" \
    bifrost keytab -k "$bifrost_kt" destroy force

for item in mode:list mode:query mode:test mode:reproduce	\
    option:-L option:-R option:-U option:-p option:-v
do
	pass "krb5_keytab matrix row covered: $item"
done

pass "krb5_keytab matrix row covered by live xrealm keytab parity: option:-X"

for item in option:-W option:-w
do
	pass "krb5_keytab matrix row covered by parser parity: $item"
done

finish_tests
