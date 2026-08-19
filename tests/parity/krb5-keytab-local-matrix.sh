#!/bin/sh

set -eu
. /tests/parity/lib.sh

prefix=$(unique_name parity-keytab-local)
legacy_root="$TEST_TMP/keytab-local-legacy"
bifrost_root="$TEST_TMP/keytab-local-bifrost"
legacy_kt="$legacy_root/etc/krb5.keytab"
bifrost_kt="$bifrost_root/etc/krb5.keytab"
legacy_princ="HTTP/$prefix-legacy.example.com@$REALM"
bifrost_princ="HTTP/$prefix-bifrost.example.com@$REALM"

mkdir -p "$legacy_root/etc" "$legacy_root/var/spool/keytabs"
mkdir -p "$bifrost_root/etc" "$bifrost_root/var/spool/keytabs"

normal_local_keytab_list() {
	kt=$1
	princ=$2
	out=$3

	bifrost keytab -k "$kt" list |
	    awk -v princ="$princ" '
	        /^Keytab name:/ { next }
	        /^KVNO[[:space:]]/ { next }
	        NF == 3 {
	            principal = $2
	            if (principal == princ) {
	                principal = "<principal>"
	            }
	            print $1 "|" principal "|" $3
	        }
	    ' |
	    sort >"$out"
}

compare_local_keytabs() {
	name=$1
	want=$(tmp_json)
	got=$(tmp_json)

	normal_local_keytab_list "$legacy_kt" "$legacy_princ" "$want"
	normal_local_keytab_list "$bifrost_kt" "$bifrost_princ" "$got"
	if diff -u "$want" "$got" >"$TEST_TMP/keytab-local.diff"; then
		pass "$name"
	else
		cat "$TEST_TMP/keytab-local.diff" >&2
		fail "$name"
	fi
}

run_ok "legacy keytab -Z default get" \
    krb5_keytab -Z -R "$legacy_root" "$legacy_princ"
run_ok "bifrost keytab -Z get" \
    bifrost keytab -R "$bifrost_root" get -Z "$bifrost_princ"
compare_local_keytabs "keytab -Z default get parity"

run_ok "legacy keytab -Z host get" \
    krb5_keytab -Z -A -R "$legacy_root"
run_ok "bifrost keytab -Z host get" \
    bifrost keytab -R "$bifrost_root" get -Z -A
compare_local_keytabs "keytab -Z -A parity"

run_ok "legacy keytab -Z forced get" \
    krb5_keytab -Z -f -R "$legacy_root" "$legacy_princ"
run_ok "bifrost keytab -Z forced get" \
    bifrost keytab -R "$bifrost_root" get -Z -f "$bifrost_princ"
compare_local_keytabs "keytab -Z -f parity"

run_ok "legacy keytab -Z rewrite get" \
    krb5_keytab -Z -F -R "$legacy_root" "$legacy_princ"
run_ok "bifrost keytab -Z rewrite get" \
    bifrost keytab -R "$bifrost_root" get -Z -F "$bifrost_princ"
compare_local_keytabs "keytab -Z -F parity"

run_ok "legacy keytab -Z change" \
    krb5_keytab -Z -c -R "$legacy_root" "$legacy_princ"
run_ok "bifrost keytab -Z change" \
    bifrost keytab -R "$bifrost_root" change -Z "$bifrost_princ"
compare_local_keytabs "keytab -Z change parity"
pass "krb5_admin protocol row covered by keytab -Z change parity: change"

for item in mode:default-get mode:change option:-A option:-F option:-Z option:-f
do
	pass "krb5_keytab local matrix row covered: $item"
done

finish_tests
