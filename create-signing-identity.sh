#!/bin/zsh
# Creates a stable self-signed code-signing identity in the login keychain so
# that the Accessibility (TCC) permission granted to "Internal Display Off"
# survives rebuilds. Run this ONCE. Afterwards, build.sh signs with it
# automatically and you only ever grant Accessibility permission a single time.
#
# Ad-hoc signatures (the default fallback) change their cdhash on every build,
# which silently invalidates the granted permission even though the toggle in
# System Settings still looks ON.
set -euo pipefail

IDENTITY="${SIGN_IDENTITY:-InternalDisplayOff Signing}"

if security find-identity -v -p codesigning 2>/dev/null | grep -qF "$IDENTITY"; then
  echo "Identity '$IDENTITY' already exists. Nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $IDENTITY
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

# Self-signed cert + key, valid ~10 years.
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" \
  -days 3650 -config "$TMP/openssl.cnf" >/dev/null 2>&1

openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
  -out "$TMP/identity.p12" -passout pass: -name "$IDENTITY"

# Import into the login keychain and allow codesign to use the key without
# repeated prompts.
security import "$TMP/identity.p12" -k ~/Library/Keychains/login.keychain-db \
  -P "" -T /usr/bin/codesign

echo
echo "Created code-signing identity: $IDENTITY"
echo "Now run ./build.sh — it will sign with this identity, and the"
echo "Accessibility permission will stick across future rebuilds."
