#!/bin/zsh
# Stops Model Shelf and removes the app and its login item. Your settings file is left in place.
set -uo pipefail
LABEL=io.github.maxketamine-spec.ModelShelf
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null
rm -f "$HOME/Library/LaunchAgents/$LABEL.plist"
rm -rf "$HOME/Applications/Model Shelf.app"
echo "Removed. Settings, if any, are in ~/Library/Application Support/Model Shelf/."
