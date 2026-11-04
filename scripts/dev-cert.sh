#!/usr/bin/env bash
# Create a local self-signed code-signing identity so development builds keep a
# stable signature. macOS ties Screen Recording and the other permission grants
# to the signing identity; with ad-hoc signing every rebuild is a new identity
# and every launch re-prompts.
#
# Usage: scripts/dev-cert.sh      (idempotent; also `make dev-cert`)
#
# The final step changes the trust settings of your login keychain, so macOS
# asks for your login password once. The private key never leaves the keychain.
set -euo pipefail

NAME="Cutscene Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "Identity \"$NAME\" already exists; nothing to do."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

cat > "$TMP/openssl.cnf" <<CNF
[ req ]
distinguished_name = dn
x509_extensions = ext
prompt = no
[ dn ]
CN = $NAME
[ ext ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
CNF

# The system LibreSSL writes PKCS#12 in the legacy form the keychain accepts.
/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -config "$TMP/openssl.cnf" -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
    -name "$NAME" -passout pass:cutscene -out "$TMP/dev.p12"

# -T lets codesign use the key without a prompt on every build.
security import "$TMP/dev.p12" -k "$KEYCHAIN" -P cutscene \
    -T /usr/bin/codesign -T /usr/bin/security >/dev/null

echo "Trusting \"$NAME\" for code signing; macOS will ask for your login password."
if ! security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"; then
    cat <<MSG
Trust step failed. Finish it by hand: open Keychain Access, select the "login"
keychain, find the certificate "$NAME", open Get Info > Trust and set
"Code Signing" to "Always Trust".
MSG
    exit 1
fi

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "Created identity \"$NAME\". scripts/bundle.sh will use it automatically."
else
    echo "The identity was imported but is not yet valid for code signing; check its trust settings in Keychain Access."
    exit 1
fi
