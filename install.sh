#!/usr/bin/env bash
set -euo pipefail

if [[ "$(uname -m)" == "x86_64" ]]; then
    echo "Macasnap is arm64-only and cannot be installed on an Intel Mac." >&2
    exit 1
fi

APP="$HOME/Applications/Macasnap.app"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

curl -fL "https://github.com/classicluna/macasnap/releases/latest/download/Macasnap.zip" -o "$TEMP_DIR/Macasnap.zip"
ditto -x -k "$TEMP_DIR/Macasnap.zip" "$TEMP_DIR"

if pgrep -x Macasnap >/dev/null 2>&1; then
    osascript -e 'tell application "Macasnap" to quit' >/dev/null 2>&1 || true
    for _ in {1..20}; do
        pgrep -x Macasnap >/dev/null 2>&1 || break
        sleep 0.25
    done
    if pgrep -x Macasnap >/dev/null 2>&1; then
        pkill -x Macasnap || true
    fi
fi

mkdir -p "$HOME/Applications"
rm -rf "$APP"
mv "$TEMP_DIR/Macasnap.app" "$APP"
xattr -dr com.apple.quarantine "$APP" >/dev/null 2>&1 || true
open "$APP"
printf '\nMacasnap is installed and opening. Follow the setup window to grant the requested permissions.\n'
