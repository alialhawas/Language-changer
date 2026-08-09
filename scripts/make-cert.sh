#!/bin/bash
set -euo pipefail

# Creates a self-signed code-signing identity named "Dodoma Dev" in the login
# keychain. A stable identity is required so that macOS TCC keeps the
# Accessibility and Input Monitoring grants across rebuilds; ad-hoc signatures
# change on every build and the grants are dropped.

IDENTITY="Dodoma Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# Guard on certificate existence rather than on `find-identity -v`, which lists
# only identities that are already valid. A run interrupted at the password or
# trust prompt leaves an untrusted certificate behind; without this check a
# re-run would add a second "Dodoma Dev" and codesign would then refuse to sign
# because the identity is ambiguous.
if security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
        echo "Code-signing identity '$IDENTITY' already exists and is valid. Nothing to do."
        exit 0
    fi

    echo "A certificate named '$IDENTITY' is already in the login keychain, but it is"
    echo "not usable as a code-signing identity. A previous run most likely stopped at"
    echo "the keychain password prompt or the trust prompt."
    echo
    echo "Refusing to create a second '$IDENTITY' certificate: duplicates make codesign"
    echo "fail with an ambiguous-identity error."
    echo
    echo "Remove the existing certificate and re-run this script:"
    echo "    security delete-identity -c \"$IDENTITY\" -t \"$KEYCHAIN\""
    echo "    scripts/make-cert.sh"
    echo
    echo "If that reports no matching identity, the private key is missing; use:"
    echo "    security delete-certificate -c \"$IDENTITY\" -t \"$KEYCHAIN\""
    exit 1
fi

WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

KEY_PEM="$WORKDIR/key.pem"
CERT_PEM="$WORKDIR/cert.pem"
P12="$WORKDIR/cert.p12"
CONF="$WORKDIR/codesign.cnf"

cat > "$CONF" <<EOF
[ req ]
distinguished_name = dn
prompt             = no
x509_extensions    = v3_codesign

[ dn ]
CN = $IDENTITY

[ v3_codesign ]
basicConstraints     = critical,CA:false
keyUsage             = critical,digitalSignature
extendedKeyUsage     = critical,codeSigning
subjectKeyIdentifier = hash
EOF

echo "==> Generating self-signed code-signing certificate"
openssl req -x509 -newkey rsa:2048 \
    -keyout "$KEY_PEM" \
    -out "$CERT_PEM" \
    -days 3650 \
    -nodes \
    -subj "/CN=$IDENTITY" \
    -config "$CONF" \
    -extensions v3_codesign

# $1 is an optional extra openssl flag, e.g. -legacy.
export_p12() {
    openssl pkcs12 -export ${1:+"$1"} \
        -inkey "$KEY_PEM" \
        -in "$CERT_PEM" \
        -out "$P12" \
        -name "$IDENTITY" \
        -passout pass:
}

echo "==> Bundling key and certificate into a PKCS#12 archive"
export_p12

echo "==> Importing into the login keychain"
if ! security import "$P12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign; then
    if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
        echo "    Import failed. Re-exporting with legacy PKCS#12 encryption."
        export_p12 -legacy
        security import "$P12" -k "$KEYCHAIN" -P "" -T /usr/bin/codesign
    else
        echo "FAILURE: could not import the certificate into $KEYCHAIN."
        exit 1
    fi
fi

echo
echo "==> Authorising /usr/bin/codesign to use the new private key"
echo "    macOS needs the login keychain password to update the key's"
echo "    partition list. Without this step every 'make sign' raises a GUI"
echo "    prompt asking you to allow keychain access."
printf "    Login keychain password: "
read -r -s KEYCHAIN_PASSWORD
echo

# -l scopes the update to this key only. Without it, -s would rewrite the
# partition list of every signing key in the login keychain.
security set-key-partition-list \
    -S apple-tool:,apple:,codesign: \
    -s \
    -l "$IDENTITY" \
    -k "$KEYCHAIN_PASSWORD" \
    "$KEYCHAIN" >/dev/null
unset KEYCHAIN_PASSWORD

echo "==> Marking the certificate as trusted for code signing"
echo "    macOS may raise a GUI authorisation prompt here."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$CERT_PEM"

echo
if security find-identity -v -p codesigning | grep -q "$IDENTITY"; then
    echo "SUCCESS: code-signing identity '$IDENTITY' is available."
    echo "Run 'make install' to build, bundle and sign Dodoma."
    exit 0
fi

echo "FAILURE: '$IDENTITY' is not listed by 'security find-identity -v -p codesigning'."
echo "Inspect the output above and retry, or sign ad-hoc (grants will not persist)."
exit 1
