#!/usr/bin/env bash
# Backs up the "Macasnap Self-Signed" signing identity to Bitwarden as a secure note holding the
# base64 .p12 and its password. Every release must be signed with this identity (users' Screen
# Recording grants and the updater's signature check depend on it), so losing it strands them.
#
# Interactive: macOS asks to allow the key export (keychain password: macasnap), and the
# Bitwarden CLI asks for your login / master password. Restore with:
#   bw get notes "Macasnap signing certificate" | sed -n '/^-----BEGIN P12-----$/,/^-----END P12-----$/p' \
#       | sed '1d;$d' | base64 -d > macasnap-signing.p12
#   scripts/make-signing-cert.sh --restore macasnap-signing.p12
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/macasnap-signing.keychain-db"
ITEM_NAME="Macasnap signing certificate"
command -v bw >/dev/null || { echo "Install the Bitwarden CLI first: brew install bitwarden-cli" >&2; exit 1; }
[[ -f "$KEYCHAIN" ]] || { echo "No signing keychain at $KEYCHAIN" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
P12_PASS="$(/usr/bin/openssl rand -base64 24)"

echo "macOS will ask to allow exporting the key. Keychain password: macasnap"
security unlock-keychain -p macasnap "$KEYCHAIN"
security export -k "$KEYCHAIN" -t identities -f pkcs12 -P "$P12_PASS" -o "$TMP/id.p12"
/usr/bin/openssl pkcs12 -in "$TMP/id.p12" -passin pass:"$P12_PASS" -noout # fails if unreadable

case "$(bw status | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])')" in
    unauthenticated) BW_SESSION="$(bw login --raw)" ;;
    locked) BW_SESSION="$(bw unlock --raw)" ;;
    *) BW_SESSION="${BW_SESSION:-$(bw unlock --raw)}" ;;
esac
export BW_SESSION
bw sync >/dev/null

if bw list items --search "$ITEM_NAME" | /usr/bin/python3 -c 'import json,sys; sys.exit(0 if any(i["name"]==sys.argv[1] for i in json.load(sys.stdin)) else 1)' "$ITEM_NAME"; then
    echo "A Bitwarden item named '$ITEM_NAME' already exists; delete or rename it first." >&2
    exit 1
fi

ITEM_JSON="$(P12_B64="$(base64 < "$TMP/id.p12")" P12_PASS="$P12_PASS" ITEM_NAME="$ITEM_NAME" /usr/bin/python3 -c '
import json, os
notes = (
    "Macasnap code-signing identity (\"Macasnap Self-Signed\"). Every release must be signed with it.\n"
    "Restore: save the block below without the BEGIN/END lines, base64 -d it to macasnap-signing.p12, then run\n"
    "scripts/make-signing-cert.sh --restore macasnap-signing.p12 and enter the p12 password field.\n\n"
    "-----BEGIN P12-----\n" + os.environ["P12_B64"] + "\n-----END P12-----\n"
)
print(json.dumps({
    "type": 2, "name": os.environ["ITEM_NAME"], "notes": notes, "secureNote": {"type": 0},
    "fields": [{"name": "p12 password", "value": os.environ["P12_PASS"], "type": 1}],
}))')"
ID="$(printf '%s' "$ITEM_JSON" | bw encode | bw create item | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')"
bw lock >/dev/null
echo "Saved to Bitwarden as '$ITEM_NAME' (id $ID)."
