#!/bin/zsh
set -euo pipefail

PROJECT_DIR="${0:A:h:h}"
SOURCE="$PROJECT_DIR/Resources/AppIcon-master.png"
NORMALIZED="$PROJECT_DIR/Resources/AppIcon-1024.png"
ICONSET="$PROJECT_DIR/.build/AppIcon.iconset"
OUTPUT="$PROJECT_DIR/Resources/AppIcon.icns"

mkdir -p "$ICONSET"

sips -z 1024 1024 "$SOURCE" --out "$NORMALIZED" >/dev/null
sips -z 16 16 "$NORMALIZED" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$NORMALIZED" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$NORMALIZED" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$NORMALIZED" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$NORMALIZED" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$NORMALIZED" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$NORMALIZED" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$NORMALIZED" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$NORMALIZED" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$NORMALIZED" "$ICONSET/icon_512x512@2x.png"

# iconutil on macOS 26 currently rejects even iconsets that it extracted
# itself. Pillow writes the modern PNG-backed ICNS representations directly.
python3 -c \
    'import sys; from PIL import Image; Image.open(sys.argv[1]).save(sys.argv[2], "ICNS")' \
    "$NORMALIZED" \
    "$OUTPUT"
print -r -- "$OUTPUT"
