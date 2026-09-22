#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h:h}"
APP_DIR="$PROJECT_DIR/.build/SpeechProbe/MeetTracker.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
EXECUTABLE="$MACOS_DIR/MeetTrackerSpeechProbe"

mkdir -p "$MACOS_DIR"
xcrun swiftc \
    "$PROJECT_DIR/Tools/SpeechProbe/main.swift" \
    -framework AppKit \
    -framework Speech \
    -o "$EXECUTABLE"

cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleExecutable \
    -string "MeetTrackerSpeechProbe" \
    "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleName \
    -string "MeetTracker Speech Test" \
    "$CONTENTS_DIR/Info.plist"
plutil -replace CFBundleIdentifier \
    -string "com.santiagomujica.meettracker.speechprobe" \
    "$CONTENTS_DIR/Info.plist"

codesign --force --deep --sign - \
    --requirements \
    '=designated => identifier "com.santiagomujica.meettracker.speechprobe"' \
    "$APP_DIR"

print -r -- "$APP_DIR"
