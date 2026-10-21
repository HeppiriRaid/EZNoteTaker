#!/bin/bash
# EZNoteTaker — set up free automatic 7-day refresh. Double-click in Finder, or run:
#   bash tools/auto-refresh/install-auto-refresh.command
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$HERE/../.." && pwd)"
SUPPORT="$HOME/.eznotetaker"
PLIST="$HOME/Library/LaunchAgents/com.eznotetaker.refresh.plist"
mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"

echo "EZNoteTaker auto-refresh setup"
echo "Project: $REPO_DIR"
echo
echo "Before continuing, make sure you have installed the app once from Xcode (▶ Run)"
echo "with your Apple ID selected as the Team. That is what this script repeats automatically."
echo
echo "Your devices:"
xcrun devicectl list devices 2>/dev/null || { echo "Xcode command-line tools not found. Open Xcode once, then retry."; exit 1; }
echo
read -r -p "Type your iPhone's name exactly as shown above (Name column): " DEVICE
[ -n "$DEVICE" ] || { echo "No device given."; exit 1; }

cat > "$SUPPORT/refresh.conf" <<CONF
REPO_DIR="$REPO_DIR"
DEVICE="$DEVICE"
CONF
cp "$HERE/refresh-iphone.sh" "$SUPPORT/refresh-iphone.sh"
chmod +x "$SUPPORT/refresh-iphone.sh"

echo
echo "Doing a first refresh now (a few minutes)…"
echo "If macOS asks whether codesign may use your keychain, enter your Mac password and click \"Always Allow\"."
if bash "$SUPPORT/refresh-iphone.sh"; then
  echo "First refresh worked ✔"
else
  echo "The first refresh failed — see $SUPPORT/refresh.log. The daily job is installed anyway and will retry."
fi

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.eznotetaker.refresh</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SUPPORT/refresh-iphone.sh</string></array>
  <key>StartCalendarInterval</key>
  <dict><key>Hour</key><integer>3</integer><key>Minute</key><integer>17</integer></dict>
  <key>StandardOutPath</key><string>$SUPPORT/refresh-launchd.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/refresh-launchd.log</string>
</dict>
</plist>
PL
launchctl bootout "gui/$(id -u)/com.eznotetaker.refresh" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "All set! Every night (or as soon as your Mac wakes up) it rebuilds EZNoteTaker and reinstalls it"
echo "on your iPhone over Wi-Fi, so it never expires. You'll get a Mac notification only if it keeps failing."
echo "Log: $SUPPORT/refresh.log    Remove: launchctl bootout gui/\$(id -u)/com.eznotetaker.refresh"
