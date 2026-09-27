#!/usr/bin/env bash
# Collects what is needed to debug a Macasnap install that does not open, prints it, and copies
# it to the clipboard. Run with:
#   curl -fsSL https://raw.githubusercontent.com/classicluna/macasnap/main/diagnose.sh | bash
set -uo pipefail

APP="$HOME/Applications/Macasnap.app"
BIN="$APP/Contents/MacOS/Macasnap"
OUT="$(mktemp)"
trap 'rm -f "$OUT"' EXIT

section() { printf '\n== %s ==\n' "$1"; }
{
    section "System"
    sw_vers
    echo "arch: $(uname -m)"

    section "App bundle"
    if [[ -d "$APP" ]]; then
        echo "version: $(/usr/bin/defaults read "$APP/Contents/Info.plist" CFBundleShortVersionString 2>&1)"
        echo "xattrs: $(xattr "$APP" 2>&1 | tr '\n' ' ')"
        codesign -dv "$APP" 2>&1 | grep -E '^(Identifier|Authority|Signature|TeamIdentifier)'
        echo "codesign verify: $(codesign --verify --strict "$APP" 2>&1 || true)"
        echo "gatekeeper: $(spctl --assess --type execute -vv "$APP" 2>&1 | tr '\n' ' ')"
    else
        echo "MISSING: $APP"
        ls -d /Applications/Macasnap.app 2>&1
    fi

    section "Running"
    pgrep -lf 'Macasnap.app/Contents/MacOS/Macasnap' || echo "not running"
    echo "onboardingComplete: $(defaults read com.evan.macasnap onboardingComplete 2>&1)"

    section "Direct launch (8 s)"
    if [[ -x "$BIN" ]] && ! pgrep -qf 'Macasnap.app/Contents/MacOS/Macasnap'; then
        "$BIN" > "$OUT.launch" 2>&1 &
        PID=$!
        sleep 8
        if kill -0 "$PID" 2>/dev/null; then
            echo "still running after 8 s (pid $PID) - launch works; look for the window / menu bar icon"
        else
            wait "$PID"; echo "exited with status $?"
        fi
        tail -n 30 "$OUT.launch"; rm -f "$OUT.launch"
    else
        echo "skipped (binary missing or already running)"
    fi

    section "Crash reports"
    REPORTS=$(ls -t ~/Library/Logs/DiagnosticReports/Macasnap* 2>/dev/null | head -3)
    if [[ -n "$REPORTS" ]]; then
        echo "$REPORTS"
        head -n 60 "$(echo "$REPORTS" | head -1)"
    else
        echo "none"
    fi

    section "Recent log errors"
    log show --last 15m --style compact --predicate '(process == "Macasnap" AND messageType IN {16, 17}) OR (eventMessage CONTAINS[c] "macasnap" AND process IN {"kernel", "amfid", "syspolicyd", "launchd", "tccd"} AND messageType IN {16, 17})' 2>/dev/null \
        | tail -n 30
} 2>&1 | tee "$OUT"

pbcopy < "$OUT"
printf '\nThe report above has been copied to your clipboard - paste it back to Evan.\n'
