#!/bin/sh

set -eu

CMD=${1:-./scripts/cmd}
CMD=$(cd "$(dirname "$CMD")" && pwd)/$(basename "$CMD")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CALLS=$TMP/calls

sed '/^debug=0$/,$d' "$CMD" > "$TMP/functions"
. "$TMP/functions"

ASGARD_REALMS=$TMP/realms
cat > "$ASGARD_REALMS" <<'EOM'
A.MULTI.EXAMPLE
B.MULTI.EXAMPLE
EOM

krb5_keytab() {

	printf '%s\n' "$*" >> "$CALLS"
}

install_kdc_keytabs

cat > "$TMP/expected" <<'EOM'
-Z host@A.MULTI.EXAMPLE
-Z krb5_admin@A.MULTI.EXAMPLE
-Z HTTP@A.MULTI.EXAMPLE
-Z iprop@A.MULTI.EXAMPLE
-Z host@B.MULTI.EXAMPLE
-Z krb5_admin@B.MULTI.EXAMPLE
-Z HTTP@B.MULTI.EXAMPLE
-Z iprop@B.MULTI.EXAMPLE
EOM

cmp "$TMP/expected" "$CALLS"
