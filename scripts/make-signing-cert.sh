#!/usr/bin/env bash
set -euo pipefail

# LOCAL DEVELOPMENT ONLY. Never use this identity for distribution.
# Creates a stable, self-signed code-signing certificate in the login keychain.
#
# Why: without a Developer ID, an unsigned build is signed ad-hoc, whose code identity
# (cdhash) changes on every rebuild. macOS keys Accessibility / Screen Recording / Camera
# grants to that identity, so every rebuild looks like a brand-new app and the permissions
# have to be granted again. A self-signed certificate is stable across rebuilds, so the
# app's designated requirement stays constant and the grants stick.
#
# Run this once. package-app.sh will then prefer this identity automatically.

CERT_NAME="${SOFTLOCK_SIGN_CERT_NAME:-SoftLock Self-Signed}"
KEYCHAIN="${SOFTLOCK_KEYCHAIN:-$HOME/Library/Keychains/login.keychain-db}"
P12_PASSWORD="$(openssl rand -hex 32)"

if security find-certificate -c "$CERT_NAME" >/dev/null 2>&1; then
  echo "Signing certificate '$CERT_NAME' already exists — nothing to do."
  exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/cert.conf" <<EOF
[req]
distinguished_name = dn
x509_extensions = v3
prompt = no
[dn]
CN = $CERT_NAME
[v3]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP/key.pem" \
  -out "$TMP/cert.pem" \
  -days 3650 \
  -config "$TMP/cert.conf" >/dev/null 2>&1

openssl pkcs12 -export \
  -inkey "$TMP/key.pem" \
  -in "$TMP/cert.pem" \
  -name "$CERT_NAME" \
  -out "$TMP/cert.p12" \
  -passout "pass:$P12_PASSWORD" >/dev/null 2>&1

# Import cert + private key, and allow codesign to use the key.
security import "$TMP/cert.p12" -k "$KEYCHAIN" -P "$P12_PASSWORD" -T /usr/bin/codesign >/dev/null

# Mark the certificate as trusted for code signing so codesign/Gatekeeper accept it locally.
security add-trusted-cert -d -r trustAsRoot \
  -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem" >/dev/null 2>&1 || \
  echo "Note: couldn't auto-trust the cert (may prompt once on first sign)." >&2

# Let codesign access the key without prompting on every build. This needs the keychain
# password; if it fails, codesign will simply ask you to 'Always Allow' once.
if [ -n "${SOFTLOCK_KEYCHAIN_PASSWORD:-}" ]; then
  security set-key-partition-list -S apple-tool:,apple: \
    -s -k "$SOFTLOCK_KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1 || true
fi

echo "Created signing certificate '$CERT_NAME'."
echo "Now run scripts/package-app.sh — it will sign with this stable identity."
