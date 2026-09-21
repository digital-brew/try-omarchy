#!/bin/bash
# Create a self-signed code-signing identity for local Try Omarchy builds.
#
# `make build` ad-hoc signs by default, so macOS sees every rebuild as a new
# app and forgets its Accessibility and Camera grants, and the bridged
# networking daemon re-registers. Signing with one stable certificate keeps
# the app's designated requirement constant across rebuilds. An Apple
# Development certificate from Xcode does the same; this script is for Macs
# without one. Gatekeeper is not involved: locally built apps carry no
# quarantine flag.
#
# Usage: create-development-signing-identity.sh [NAME]   (default: Try Omarchy Development)
set -euo pipefail

name=${1:-Try Omarchy Development}
keychain="$HOME/Library/Keychains/login.keychain-db"

fail() {
  echo "create-development-signing-identity: $*" >&2
  exit 1
}

name_pattern='^[A-Za-z0-9][A-Za-z0-9 ._-]*$'
[[ $name =~ $name_pattern ]] || fail "identity name has unsupported characters"
[[ -f $keychain ]] || fail "login keychain not found at $keychain"
if security find-identity -v -p codesigning 2>/dev/null | grep -Fq "\"$name\""; then
  echo "Identity '$name' already exists and is valid for code signing."
  exit 0
fi
if security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
  fail "a certificate named '$name' exists but is not a valid code-signing identity; delete it in Keychain Access or pick another name"
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/try-omarchy-signing.XXXXXX")
trap 'rm -rf "$work"' EXIT
chmod 0700 "$work"

# A leaf certificate marked for code signing only, ten years, RSA 2048.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$work/key.pem" -out "$work/cert.pem" \
  -subj "/CN=$name/OU=Try Omarchy local builds" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "subjectKeyIdentifier=hash" >/dev/null 2>&1
password=$(openssl rand -hex 16)
openssl pkcs12 -export -legacy -inkey "$work/key.pem" -in "$work/cert.pem" \
  -name "$name" -out "$work/identity.p12" -passout "pass:$password" 2>/dev/null ||
  openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
    -name "$name" -out "$work/identity.p12" -passout "pass:$password"

# Import the key so codesign may use it, then trust the certificate for code
# signing. macOS asks for the login password once for the trust change.
security import "$work/identity.p12" -k "$keychain" -P "$password" \
  -T /usr/bin/codesign -T /usr/bin/security >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$work/cert.pem"

if security find-identity -v -p codesigning | grep -Fq "\"$name\""; then
  echo "Created code-signing identity '$name'."
  echo "Persist it for builds with:  printf 'DEVELOPMENT_SIGN_IDENTITY = %s\n' '$name' > local.mk"
else
  fail "the identity was imported but is not yet valid for code signing; check its trust settings in Keychain Access"
fi
