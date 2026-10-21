#!/bin/bash
# EZNoteTaker — one-time Mac setup. Double-click this file in Finder (or run: bash install-relay.command).
# It installs a small background helper that runs Claude Code on your Claude subscription
# whenever your iPhone drops a new lecture into this folder.

set -e
RELAY_DIR="$(cd "$(dirname "$0")" && pwd)"
SUPPORT="$HOME/.eznotetaker"
PLIST="$HOME/Library/LaunchAgents/com.eznotetaker.relay.plist"
mkdir -p "$SUPPORT" "$HOME/Library/LaunchAgents"

echo "EZNoteTaker relay setup"
echo "Shared folder: $RELAY_DIR"
echo

CLAUDE_BIN="$(command -v claude || true)"
for candidate in "$HOME/.local/bin/claude" "$HOME/.claude/local/claude" /opt/homebrew/bin/claude /usr/local/bin/claude; do
  [ -z "$CLAUDE_BIN" ] && [ -x "$candidate" ] && CLAUDE_BIN="$candidate"
done
if [ -z "$CLAUDE_BIN" ]; then
  echo "Claude Code isn't installed yet. Installing it now…"
  curl -fsSL https://claude.ai/install.sh | bash
  CLAUDE_BIN="$HOME/.local/bin/claude"
fi
echo "Claude Code: $CLAUDE_BIN"

echo
echo "Checking that Claude Code is signed in with your Claude subscription…"
if ! "$CLAUDE_BIN" -p "Reply with the single word: ready" >/dev/null 2>&1; then
  echo
  echo "Please sign in: Claude Code will open now. Choose \"Claude account with subscription\","
  echo "finish the login in your browser, then type /exit and run this installer again."
  read -r -p "Press Return to open Claude Code… "
  "$CLAUDE_BIN"
  exit 0
fi
echo "Signed in ✔"

cp "$RELAY_DIR/ez-relay.sh" "$SUPPORT/ez-relay.sh"
chmod +x "$SUPPORT/ez-relay.sh"
cat > "$SUPPORT/config" <<CONF
RELAY_DIR="$RELAY_DIR"
CLAUDE_BIN="$CLAUDE_BIN"
MODEL="claude-opus-5-5"
CONF

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.eznotetaker.relay</string>
  <key>ProgramArguments</key>
  <array><string>/bin/bash</string><string>$SUPPORT/ez-relay.sh</string></array>
  <key>StartInterval</key><integer>90</integer>
  <key>WatchPaths</key><array><string>$RELAY_DIR/jobs</string></array>
  <key>RunAtLoad</key><true/>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>$(dirname "$CLAUDE_BIN"):/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
  </dict>
  <key>StandardOutPath</key><string>$SUPPORT/launchd.log</string>
  <key>StandardErrorPath</key><string>$SUPPORT/launchd.log</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)/com.eznotetaker.relay" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "All set! Your Mac will now turn every recorded lecture into study notes with Claude Opus 5.5"
echo "(using your Claude subscription) and send them back to your iPhone automatically."
echo "Keep this Mac on and signed in to iCloud. Log: $SUPPORT/relay.log"
echo
echo "If the log ever shows \"Operation not permitted\", open System Settings › Privacy & Security ›"
echo "Full Disk Access and add /bin/bash — or simply run in Terminal:  bash \"$SUPPORT/ez-relay.sh\" --watch"
