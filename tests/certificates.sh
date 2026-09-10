#!/bin/sh -e

cd "$(dirname "$0")/.."
docker run --rm -i --network none --hostname kdc1.cert.example \
	--security-opt label=disable \
	--tmpfs /var/heimdal --tmpfs /run/asgard \
	-v "$(pwd):/src:ro" --entrypoint /bin/sh \
	"${1:-asgard/kdc}" -se <<'EOM'
umask 077
mkdir /tmp/bin
REAL_HXTOOL=$(command -v hxtool)
export REAL_HXTOOL

# Only database policy and injected failures are fixtures; crypto is real.
cat > /tmp/bin/bifrost <<'EOF'
#!/bin/sh -e
case "$*" in
'-l search_realm kind=local')
	jq -r '.[] | select(.kind == "local") | .realm' /tmp/realms.json
	;;
'-l search_realm kind=local kdc='*)
	jq -r --arg host "${4#kdc=}" \
	    '.[] | select(.kind == "local") |
	     select(.kdc | index($host) != null) | .realm' /tmp/realms.json
	;;
*) exit 1 ;;
esac
EOF
cat > /tmp/bin/hxtool <<'EOF'
#!/bin/sh -e
case "$*" in
'issue-certificate '*kx509-priv.pem*)
	[ ! -f /tmp/fail-issuer ] || exit 1
	;;
esac
exec "$REAL_HXTOOL" "$@"
EOF
chmod 755 /tmp/bin/*
PATH=/tmp/bin:$PATH
export PATH

cat > /tmp/realms.json <<'EOF'
[
 {"realm":"A.CERT.EXAMPLE", "kind":"local",
  "master":"kdc1.cert.example",
  "kdc":["kdc1.cert.example", "kdc2.cert.example"]},
 {"realm":"B.CERT.EXAMPLE", "kind":"local",
  "master":"kdc1.cert.example", "kdc":["kdc1.cert.example"]}
]
EOF
hxtool issue-certificate --self-signed --issue-ca --generate-key=rsa \
	--subject=CN=TestRoot --lifetime=20years \
	--certificate=FILE:/var/heimdal/ca-priv.pem
hxtool cc --no-private-keys /var/heimdal/ca-priv.pem /var/heimdal/ca-pub.pem
sha256sum /var/heimdal/ca-priv.pem > /tmp/root.sha256

ISSUE=/src/scripts/asgard-certificates
INSTALL=/src/scripts/asgard-install-certificates
HOST=kdc2.cert.example
DIR=$($ISSUE "$HOST")
test "$DIR" = /var/heimdal/kdcs/$HOST
OLD=$(readlink "$DIR")
test "$($ISSUE "$HOST")" = "$DIR"
test "$(readlink "$DIR")" = "$OLD"
test "$(cat "$DIR/realms")" = A.CERT.EXAMPLE
hxtool acert --end-entity --has-pkinit-san=krbtgt/A.CERT.EXAMPLE@A.CERT.EXAMPLE \
	"FILE:$DIR/kdc-priv.pem"
for name in kdc kx509; do
	hxtool acert --cert-num=0 --has-private-key "FILE:$DIR/$name-priv.pem"
	hxtool acert --cert-num=1 --lacks-private-key "FILE:$DIR/$name-priv.pem"
done
if $ISSUE ../ca-priv.pem; then exit 1; fi

$INSTALL "$DIR"
test -f /run/asgard/certificates.changed
rm /run/asgard/certificates.changed
INSTALLED=$(readlink /var/heimdal/certificates)
$INSTALL "$DIR"
test ! -e /run/asgard/certificates.changed
test "$(readlink /var/heimdal/certificates)" = "$INSTALLED"

# An unassigned realm must not change the slave's certificate.
jq '. += [{realm:"C.CERT.EXAMPLE", kind:"local", kdc:[]}]' \
	/tmp/realms.json > /tmp/realms.new
mv /tmp/realms.new /tmp/realms.json
test "$($ISSUE "$HOST")" = "$DIR"
test "$(readlink "$DIR")" = "$OLD"

# Assigning another realm reissues the generation; failure preserves it.
jq '.[1].kdc += ["kdc2.cert.example"]' /tmp/realms.json > /tmp/realms.new
mv /tmp/realms.new /tmp/realms.json
touch /tmp/fail-issuer
if $ISSUE "$HOST"; then exit 1; fi
test "$(readlink "$DIR")" = "$OLD"
test "$(readlink /var/heimdal/certificates)" = "$INSTALLED"
rm /tmp/fail-issuer
$ISSUE "$HOST"
test "$(readlink "$DIR")" != "$OLD"
set --
for R in A.CERT.EXAMPLE B.CERT.EXAMPLE; do
	set -- "$@" "--has-pkinit-san=krbtgt/$R@$R"
done
hxtool acert --end-entity "$@" "FILE:$DIR/kdc-priv.pem"
test "$(wc -l < "$DIR/realms")" = 2
$INSTALL "$DIR"
test -f /run/asgard/certificates.changed
rm /run/asgard/certificates.changed
INSTALLED=$(readlink /var/heimdal/certificates)

# The receiver must reject a valid certificate without its private key.
mkdir /tmp/bad
cp -L "$DIR"/* /tmp/bad/
cp /tmp/bad/kx509-pub.pem /tmp/bad/kx509-priv.pem
if $INSTALL /tmp/bad; then exit 1; fi
test "$(readlink /var/heimdal/certificates)" = "$INSTALLED"
test ! -e /run/asgard/certificates.changed

hxtool issue-certificate --self-signed --issue-ca --generate-key=rsa \
	--subject=CN=UntrustedIssuer --certificate=FILE:/tmp/bad/kx509-priv.pem
if $INSTALL /tmp/bad; then exit 1; fi
test "$(readlink /var/heimdal/certificates)" = "$INSTALLED"
test ! -e /run/asgard/certificates.changed

# Exercise expiry-based renewal while the realm manifest remains unchanged.
hxtool issue-certificate \
	--ca-certificate=FILE:/var/heimdal/ca-priv.pem \
	--generate-key=rsa --issue-ca --path-length=0 --ku=keyCertSign \
	--subject=CN=ExpiringIssuer --lifetime=1day \
	--certificate="FILE:$DIR/kx509-priv.pem"
OLD=$(readlink "$DIR")
$ISSUE "$HOST"
test "$(readlink "$DIR")" != "$OLD"

# A certificate actually issued by the node validates with its bundled issuer.
hxtool issue-certificate --ca-certificate="FILE:$DIR/kx509-priv.pem" \
	--generate-key=rsa --type=pkinit-client \
	--pk-init-principal=user@B.CERT.EXAMPLE --subject=CN=user \
	--certificate=FILE:/tmp/client.pem
if hxtool verify --missing-revoke cert:FILE:/tmp/client.pem \
    anchor:FILE:/var/heimdal/ca-pub.pem; then exit 1; fi
hxtool cc --append "$DIR/kx509-pub.pem" /tmp/client.pem
hxtool verify --missing-revoke cert:FILE:/tmp/client.pem \
	chain:FILE:/tmp/client.pem anchor:FILE:/var/heimdal/ca-pub.pem

# Even a private key accidentally present in ca-pub.pem must not be exported.
cp /var/heimdal/ca-priv.pem /var/heimdal/ca-pub.pem
MASTER=$($ISSUE kdc1.cert.example)
hxtool acert --end-entity "$@" \
	--has-pkinit-san=krbtgt/C.CERT.EXAMPLE@C.CERT.EXAMPLE \
	"FILE:$MASTER/kdc-priv.pem"
test "$(wc -l < "$MASTER/realms")" = 3
for name in kdc kx509; do
	hxtool acert --cert-num=1 --lacks-private-key "FILE:$MASTER/$name-priv.pem"
	hxtool acert --cert-num=0 --lacks-private-key "FILE:$MASTER/$name-pub.pem"
done
hxtool cc --no-private-keys /var/heimdal/ca-priv.pem /var/heimdal/ca-pub.pem

# Concurrent callers publish only one new generation.
jq '.[0].realm = "D.CERT.EXAMPLE"' /tmp/realms.json > /tmp/realms.new
mv /tmp/realms.new /tmp/realms.json
BEFORE=$(find /var/heimdal/kdcs -maxdepth 1 -type d | wc -l)
$ISSUE "$HOST" > /tmp/result1 &
PID1=$!
$ISSUE "$HOST" > /tmp/result2 &
PID2=$!
wait "$PID1"
wait "$PID2"
cmp /tmp/result1 /tmp/result2
AFTER=$(find /var/heimdal/kdcs -maxdepth 1 -type d | wc -l)
test "$AFTER" = "$((BEFORE + 1))"
sha256sum -c /tmp/root.sha256
echo 'Certificate issuance, installation, renewal and failure tests passed'
EOM
