#!/bin/sh

set -eu
. /tests/parity/lib.sh

krb5_admin_module=$(perl -MKrb5Admin -e 'print $INC{"Krb5Admin.pm"}')

extract_krb5_admin_exports() {
	awk '
	    /our @KHARON_.*_EXPORT = qw\// {
	        collecting = 1
	        sub(/^.*qw\//, "")
	    }
	    collecting {
	        line = $0
	        if (line ~ /\/;/) {
	            sub(/\/;.*/, "", line)
	            collecting = 0
	        }
	        print line
	    }
	' "$krb5_admin_module" |
	    tr '[:space:]' '\n' |
	    sed '/^$/d' |
	    sort -u
}

krb5_expected=$(tmp_json)
krb5_actual=$(tmp_json)
{
	extract_krb5_admin_exports
	printf '%s\n' help is_owner is_pwner list_commands reset_password
} | sort -u >"$krb5_expected"
manifest_entries "$PARITY_DIR/krb5-admin-matrix.txt" >"$krb5_actual"
require_manifest_entries krb5_admin "$krb5_expected" "$krb5_actual"

prestash_expected=$(tmp_json)
prestash_actual=$(tmp_json)
printf '%s\n' fetch insert query refresh remove | sort -u >"$prestash_expected"
manifest_entries "$PARITY_DIR/krb5-prestash-matrix.txt" >"$prestash_actual"
require_manifest_entries krb5_prestash "$prestash_expected" "$prestash_actual"

keytab_expected=$(tmp_json)
keytab_actual=$(tmp_json)
cat >"$keytab_expected" <<'EOM'
mode:change
mode:default-get
mode:list
mode:query
mode:reproduce
mode:test
option:-A
option:-F
option:-L
option:-R
option:-U
option:-W
option:-X
option:-Z
option:-f
option:-p
option:-v
option:-w
EOM
sort -u "$keytab_expected" -o "$keytab_expected"
manifest_entries "$PARITY_DIR/krb5-keytab-matrix.txt" >"$keytab_actual"
require_manifest_entries krb5_keytab "$keytab_expected" "$keytab_actual"

finish_tests
