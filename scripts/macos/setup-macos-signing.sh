#!/bin/zsh
set -euo pipefail

identity_name="${SCHOLIA_LOCAL_CODESIGN_IDENTITY:-Scholia Local Code Signing}"
keychain="$(security default-keychain -d user | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"

if security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -Fq "\"$identity_name\""; then
  printf 'Stable local signing identity is ready: %s\n' "$identity_name"
  exit 0
fi

if security find-certificate -c "$identity_name" "$keychain" >/dev/null 2>&1; then
  print -u2 "A certificate named '$identity_name' exists but is not a valid code-signing identity."
  print -u2 "Remove or repair it in Keychain Access, then run this command again."
  exit 1
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/scholia-signing.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT
private_key="$work_dir/scholia-signing.key"
certificate="$work_dir/scholia-signing.crt"
archive="$work_dir/scholia-signing.p12"
archive_password="$(openssl rand -hex 32)"
serial="$(openssl rand -hex 16)"

openssl req \
  -x509 \
  -newkey rsa:3072 \
  -sha256 \
  -days 3650 \
  -nodes \
  -set_serial "0x$serial" \
  -subj "/CN=$identity_name/O=Scholia/OU=Local Development" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -keyout "$private_key" \
  -out "$certificate" \
  >/dev/null 2>&1

openssl pkcs12 \
  -export \
  -name "$identity_name" \
  -inkey "$private_key" \
  -in "$certificate" \
  -out "$archive" \
  -passout "pass:$archive_password" \
  >/dev/null 2>&1

security import "$archive" \
  -k "$keychain" \
  -f pkcs12 \
  -P "$archive_password" \
  -x \
  -T /usr/bin/codesign \
  -T /usr/bin/security \
  >/dev/null
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$certificate"

if ! security find-identity -v -p codesigning "$keychain" 2>/dev/null | grep -Fq "\"$identity_name\""; then
  print -u2 "The local certificate was imported, but macOS does not accept it for code signing."
  exit 1
fi

fingerprint="$(security find-certificate -c "$identity_name" -Z "$keychain" \
  | sed -n 's/^SHA-256 hash: //p' \
  | head -n 1)"
printf 'Created stable local signing identity: %s\n' "$identity_name"
printf 'Certificate SHA-256: %s\n' "$fingerprint"
printf 'The private key is non-exportable and remains in %s.\n' "$keychain"
