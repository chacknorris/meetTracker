#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
CONFIGURATION="${1:-debug}"
APP_DIR="$PROJECT_DIR/.build/MeetTracker.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

cd "$PROJECT_DIR"
mkdir -p "$PROJECT_DIR/.build/module-cache"
CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache" \
SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache" \
swift build --disable-sandbox -c "$CONFIGURATION"

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$PROJECT_DIR/.build/$CONFIGURATION/MeetTracker" "$MACOS_DIR/MeetTracker"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
MEETTRACKER_BUILD_NUMBER="${MEETTRACKER_BUILD_NUMBER:-$(date +%s)}"
plutil -replace CFBundleVersion \
    -string "$MEETTRACKER_BUILD_NUMBER" \
    "$CONTENTS_DIR/Info.plist"
cp "$PROJECT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
RESOURCE_BUNDLE="$PROJECT_DIR/.build/$CONFIGURATION/MeetTracker_MeetTracker.bundle"
if [[ -d "$RESOURCE_BUNDLE" ]]; then
    ditto "$RESOURCE_BUNDLE" "$RESOURCES_DIR/MeetTracker_MeetTracker.bundle"
fi

MCP_SOURCE_DIR="$PROJECT_DIR/Tools/MeetTrackerMCP"
MCP_RESOURCES_DIR="$RESOURCES_DIR/MeetTrackerMCP"
if [[ ! -d "$MCP_SOURCE_DIR/node_modules/@modelcontextprotocol/sdk" ]]; then
    print -u2 "Faltan las dependencias de MeetTracker MCP."
    print -u2 "Ejecuta: cd Tools/MeetTrackerMCP && npm install"
    exit 1
fi
rm -rf "$MCP_RESOURCES_DIR"
mkdir -p "$MCP_RESOURCES_DIR"
ditto "$MCP_SOURCE_DIR/src" "$MCP_RESOURCES_DIR/src"
ditto "$MCP_SOURCE_DIR/node_modules" "$MCP_RESOURCES_DIR/node_modules"
cp "$MCP_SOURCE_DIR/package.json" "$MCP_RESOURCES_DIR/package.json"
cp "$MCP_SOURCE_DIR/package-lock.json" "$MCP_RESOURCES_DIR/package-lock.json"

# Ad-hoc signatures normally use the changing binary hash as their designated
# requirement. TCC would then treat every local rebuild as a different app.
# Keep a stable local identity so screen/audio permissions survive rebuilds.
codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.santiagomujica.meettracker"' \
    "$APP_DIR"

touch "$APP_DIR"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
if [[ -x "$LSREGISTER" ]]; then
    "$LSREGISTER" -f "$APP_DIR"
fi
echo "$APP_DIR"
