#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
LABEL="com.thewoolleyweb.claude-collector"
SOURCE="$REPO_ROOT/launchd/$LABEL.plist.example"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

if [[ ! -f "$REPO_ROOT/.env.local" ]]; then
  echo "Missing $REPO_ROOT/.env.local" >&2
  exit 1
fi

mkdir -p "$HOME/Library/LaunchAgents" "$REPO_ROOT/tmp/macos-local-collector"

sed "s#__REPO_ROOT__#$REPO_ROOT#g" "$SOURCE" > "$TARGET"
chmod 600 "$TARGET"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
for _ in {1..20}; do
  if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done

if ! launchctl bootstrap "$DOMAIN" "$TARGET"; then
  sleep 1
  if ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "launchctl bootstrap failed for $TARGET" >&2
    exit 1
  fi
fi

launchctl enable "$DOMAIN/$LABEL"
launchctl kickstart -k "$DOMAIN/$LABEL"

echo "Installed $TARGET"
