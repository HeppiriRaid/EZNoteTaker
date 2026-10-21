#!/bin/bash
# EZNoteTaker auto-refresh — rebuilds the app with your free Apple ID and reinstalls it on your
# iPhone over Wi-Fi, so the 7-day free signature never runs out. Your recordings and notes are kept.
#
# Installed by install-auto-refresh.command; runs daily from launchd. Manual run:
#   bash tools/auto-refresh/refresh-iphone.sh

set -u
SUPPORT="$HOME/.eznotetaker"
CONFIG="$SUPPORT/refresh.conf"
LOG="$SUPPORT/refresh.log"
STAMP="$SUPPORT/last-refresh"
mkdir -p "$SUPPORT"
[ -f "$CONFIG" ] && . "$CONFIG"

REPO_DIR="${REPO_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
DEVICE="${DEVICE:-}"
BUILD_DIR="$SUPPORT/build"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

notify() {
  osascript -e "display notification \"$1\" with title \"EZNoteTaker\"" >/dev/null 2>&1 || true
}

fail() {
  log "FAILED: $1"
  # Only bother you when the app is getting close to expiring.
  if [ -f "$STAMP" ]; then
    age_days=$(( ( $(date +%s) - $(stat -f %m "$STAMP") ) / 86400 ))
  else
    age_days=99
  fi
  if [ "$age_days" -ge 4 ]; then
    notify "Couldn't refresh the app on your iPhone ($1). Last refresh: $age_days days ago — connect the iPhone and run the refresh."
  fi
  exit 1
}

[ -n "$DEVICE" ] || fail "no iPhone configured; run install-auto-refresh.command"
cd "$REPO_DIR" || fail "project folder not found: $REPO_DIR"
log "Refreshing EZNoteTaker on '$DEVICE'"

# 1. Build and re-sign with the Apple ID signed in to Xcode (renews the free provisioning profile).
if ! xcodebuild \
      -project EZNoteTaker.xcodeproj \
      -scheme EZNoteTaker \
      -configuration Debug \
      -destination 'generic/platform=iOS' \
      -derivedDataPath "$BUILD_DIR" \
      -allowProvisioningUpdates \
      build >> "$LOG" 2>&1; then
  fail "build failed — see $LOG"
fi

APP="$BUILD_DIR/Build/Products/Debug-iphoneos/EZNoteTaker.app"
[ -d "$APP" ] || fail "built app not found at $APP"

# 2. Install over the existing app (data is preserved). The iPhone must be on the same Wi-Fi (or plugged in).
if ! xcrun devicectl device install app --device "$DEVICE" "$APP" >> "$LOG" 2>&1; then
  fail "iPhone not reachable — is it on the same Wi-Fi and unlocked?"
fi

touch "$STAMP"
log "Done — valid for another 7 days"
