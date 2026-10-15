#!/bin/zsh
# Creates a self-signed code-signing certificate ("ShotIt Local") in the login keychain, once.
# install.sh signs with it so macOS keeps the Screen Recording / Accessibility grants across rebuilds:
# the signature requirement becomes "com.shotit.app + this certificate" instead of a per-build hash.
# The certificate only exists on this Mac and is tied to no Apple account.
set -euo pipefail
NAME="ShotIt Local"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

# --allow-codesign: let codesign use the key without a keychain password prompt on every install.
# Asks for your login password (read silently, never stored or put on a command line history).
if [[ "${1:-}" == "--allow-codesign" ]]; then
  read -rs "pw?Login keychain password: " </dev/tty; echo
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$pw" "$KEYCHAIN" >/dev/null
  unset pw
  echo "codesign can now use the key without prompting."
  exit 0
fi

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists."
  exit 0
fi

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
cat > "$tmp/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF

# /usr/bin/openssl (LibreSSL) writes a PKCS#12 that `security import` accepts; Homebrew's OpenSSL 3 does not.
/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$tmp/cert.cnf" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
/usr/bin/openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -name "$NAME" \
  -out "$tmp/id.p12" -passout pass:shotit
security import "$tmp/id.p12" -k "$KEYCHAIN" -P shotit -T /usr/bin/codesign >/dev/null
# Trust it for code signing (may ask for your login password).
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$tmp/cert.pem"
echo "Created \"$NAME\"."
security find-identity -p codesigning | grep "\"$NAME\""
