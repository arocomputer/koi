#!/bin/sh
# Makes "Koi Dev", a self-signed code signing certificate in the login
# keychain, so builds of Koi and Koid keep one identity across rebuilds.
# macOS ties permissions such as firewall access to that identity; ad hoc
# signatures change with every build. Optional: run once to keep those
# grants stable; macOS may ask for keychain access and certificate trust.
set -eu
name="Koi Dev"
if security find-identity -v -p codesigning | grep -q "\"$name\""; then
  echo "$name exists"
  exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -subj "/CN=$name" \
  -addext "keyUsage=critical,digitalSignature" -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -keyout "$tmp/key.pem" -out "$tmp/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$tmp/key.pem" -in "$tmp/cert.pem" -out "$tmp/dev.p12" -passout pass:koi \
  -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1
keychain="$HOME/Library/Keychains/login.keychain-db"
security import "$tmp/dev.p12" -k "$keychain" -P koi -T /usr/bin/codesign -T /usr/bin/security >/dev/null
# Trust it for code signing (user trust settings; macOS asks once).
security add-trusted-cert -r trustRoot -p codeSign -k "$keychain" "$tmp/cert.pem"
security find-identity -v -p codesigning | grep "\"$name\"" && echo "made $name"
