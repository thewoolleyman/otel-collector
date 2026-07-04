#!/usr/bin/env bash
set -euo pipefail

LABEL="com.thewoolleyweb.claude-collector"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$(id -u)"

launchctl bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
rm -f "$TARGET"

echo "Removed $TARGET"
