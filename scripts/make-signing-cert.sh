#!/usr/bin/env bash
# Creates a self-signed code-signing identity in a dedicated keychain so every build of Macasnap
# has the same designated requirement. With ad-hoc signing the requirement is the cdhash, which
# changes on every rebuild and makes macOS silently drop the Screen Recording grant.
# Idempotent: does nothing if the identity already exists.
#
# Restore a backup (see scripts/backup-signing-cert.sh) instead of generating a new identity:
#   scripts/make-signing-cert.sh --restore macasnap-signing.p12   (asks for the .p12 password)
set -euo pipefail

NAME="Macasnap Self-Signed"
KEYCHAIN="$HOME/Library/Keychains/macasnap-signing.keychain-db"
KEYCHAIN_PASS="macasnap" # guards nothing secret; only this local signing key lives here

if security find-certificate -c "$NAME" "$KEYCHAIN" >/dev/null 2>&1; then
    echo "Identity '$NAME' already exists in $KEYCHAIN"
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if [[ "${1:-}" == "--restore" ]]; then
    P12="${2:?usage: $0 --restore FILE.p12}"
    read -r -s -p "Password for $P12: " P12_PASS
    echo
else
    cat > "$TMP/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF

    # LibreSSL writes PKCS#12 with algorithms `security import` accepts.
    /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cnf" \
        -keyout "$TMP/key.pem" -out "$TMP/cert.pem" 2>/dev/null
    P12="$TMP/id.p12"
    P12_PASS="macasnap"
    /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" \
        -out "$P12" -passout pass:"$P12_PASS" -name "$NAME"
fi

[[ -f "$KEYCHAIN" ]] || security create-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASS" "$KEYCHAIN"
security set-keychain-settings "$KEYCHAIN" # no auto-lock
security import "$P12" -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASS" "$KEYCHAIN" >/dev/null

# Add to the user search list so codesign can find it.
EXISTING=$(security list-keychains -d user | tr -d '"')
if ! grep -qF "$KEYCHAIN" <<<"$EXISTING"; then
    # shellcheck disable=SC2086
    security list-keychains -d user -s $EXISTING "$KEYCHAIN"
fi
echo "Installed identity '$NAME' in $KEYCHAIN"
