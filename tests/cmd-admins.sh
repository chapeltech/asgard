#!/bin/sh

set -eu

CMD=${1:-./scripts/cmd}
CMD=$(cd "$(dirname "$CMD")" && pwd)/$(basename "$CMD")
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
CALLS=$TMP/calls

sed '/^debug=0$/,$d' "$CMD" > "$TMP/functions"
. "$TMP/functions"

krb5_admin() {

	printf '%s\n' "$*" >> "$CALLS"
	if [ "$2" = query_group ]; then
		return "$GROUP_EXISTS"
	fi
}

GROUP_EXISTS=1
create_bifrost_admins

cat > "$TMP/expected" <<'EOM'
-l query_group bifrost-admins
-l create_group bifrost-admins
-l sacls_add bind_host bifrost-admins
-l sacls_add create_user bifrost-admins
-l sacls_add create_subject bifrost-admins
-l sacls_add modify bifrost-admins
-l sacls_add principal_map_add bifrost-admins
-l sacls_add sacls_add bifrost-admins
EOM

cmp "$TMP/expected" "$CALLS"

: > "$CALLS"
GROUP_EXISTS=0
create_bifrost_admins

cat > "$TMP/expected" <<'EOM'
-l query_group bifrost-admins
EOM

cmp "$TMP/expected" "$CALLS"
