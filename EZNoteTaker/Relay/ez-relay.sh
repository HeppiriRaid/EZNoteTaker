#!/bin/bash
# EZNoteTaker relay — runs Claude Code (on your Claude subscription) for lectures recorded on the iPhone.
#
# The iPhone writes jobs to   <relay folder>/jobs/<lecture-id>/{prompt.md,P1.jpg…,READY}
# This script writes results  <relay folder>/results/<lecture-id>.json
#
# Usage:
#   ez-relay.sh            process waiting jobs once (what the background LaunchAgent does)
#   ez-relay.sh --watch    keep running and check every 60 seconds (run it in a Terminal window)
#
# Config (written by install-relay.command): ~/.eznotetaker/config
#   RELAY_DIR=…   folder shared with the iPhone (iCloud Drive)
#   CLAUDE_BIN=…  absolute path to the `claude` command
#   MODEL=…       Claude model (default claude-opus-5-5)

set -u
CONFIG="$HOME/.eznotetaker/config"
[ -f "$CONFIG" ] && . "$CONFIG"
RELAY_DIR="${RELAY_DIR:-$HOME/Library/Mobile Documents/com~apple~CloudDocs/EZNoteTaker}"
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude)}"
MODEL="${MODEL:-claude-opus-5-5}"
LOG="$HOME/.eznotetaker/relay.log"
LOCK="$HOME/.eznotetaker/relay.lock"
mkdir -p "$HOME/.eznotetaker"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*" >> "$LOG"; }

process_once() {
  # One relay at a time.
  if ! mkdir "$LOCK" 2>/dev/null; then
    # Stale lock from a crashed run (older than 2 hours)?
    if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +120 2>/dev/null)" ]; then rm -rf "$LOCK"; mkdir "$LOCK" || return; else return; fi
  fi
  run_jobs
  rm -rf "$LOCK"
}

run_jobs() {
  if [ ! -d "$RELAY_DIR" ]; then
    log "Relay folder not found: $RELAY_DIR"
    return
  fi
  mkdir -p "$RELAY_DIR/jobs" "$RELAY_DIR/results"
  date > "$RELAY_DIR/relay-heartbeat.txt"

  if [ -z "$CLAUDE_BIN" ] || [ ! -x "$CLAUDE_BIN" ]; then
    log "Claude Code not found. Install it (https://claude.com/claude-code) and re-run install-relay.command."
    return
  fi

  # Make sure iCloud has downloaded the job folders.
  command -v brctl >/dev/null && brctl download "$RELAY_DIR/jobs" >/dev/null 2>&1

  for job in "$RELAY_DIR"/jobs/*/; do
    [ -d "$job" ] || continue
    id="$(basename "$job")"
    [ -f "$job/READY" ] || continue
    [ -f "$job/prompt.md" ] || { brctl download "$job" >/dev/null 2>&1; continue; }
    # Skip until every photo has finished syncing from the phone.
    if ls "$job"/.*.icloud >/dev/null 2>&1; then brctl download "$job" >/dev/null 2>&1; continue; fi

    log "Processing lecture $id with $MODEL"
    out="$RELAY_DIR/results/$id.json.partial"
    err="$HOME/.eznotetaker/$id.stderr"
    (
      cd "$job" || exit 1
      "$CLAUDE_BIN" -p "Read prompt.md in the current folder and follow its instructions exactly. Your final reply must be only the JSON object it asks for." \
        --model "$MODEL" \
        --allowedTools "Read" \
        --output-format text
    ) > "$out" 2> "$err"
    status=$?

    if [ $status -eq 0 ] && grep -q '"buildings"' "$out"; then
      mv "$out" "$RELAY_DIR/results/$id.json"
      rm -rf "$job"
      log "Done: $id"
    else
      { echo "Claude Code exited with status $status."; tail -c 1500 "$err"; tail -c 500 "$out"; } > "$RELAY_DIR/results/$id.error.txt"
      rm -f "$out"
      rm -f "$job/READY"   # don't retry automatically; the phone can resend
      log "Failed: $id (status $status) — see results/$id.error.txt"
    fi
    rm -f "$err"
  done
}

if [ "${1:-}" = "--watch" ]; then
  echo "EZNoteTaker relay watching $RELAY_DIR (Ctrl-C to stop)…"
  while true; do process_once; sleep 60; done
else
  process_once
fi
