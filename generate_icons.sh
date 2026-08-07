#!/bin/bash

SOURCE="/Users/festomanolo/.gemini/antigravity/brain/b8faceb8-0013-4482-bb2a-717c4a8fc8f7/droid_house_icon_raw_1769622555561.png"
ICONSET_DIR="/Users/festomanolo/Desktop/projects/droidhouse/droid house/droid house/Assets.xcassets/AppIcon.appiconset"

echo "🎨 Generating app icon resolutions..."

# Generate resolutions
sips -z 16 16     "$SOURCE" --out "$ICONSET_DIR/icon_16x16.png"
sips -z 32 32     "$SOURCE" --out "$ICONSET_DIR/icon_16x16@2x.png"
sips -z 32 32     "$SOURCE" --out "$ICONSET_DIR/icon_32x32.png"
sips -z 64 64     "$SOURCE" --out "$ICONSET_DIR/icon_32x32@2x.png"
sips -z 128 128   "$SOURCE" --out "$ICONSET_DIR/icon_128x128.png"
sips -z 256 256   "$SOURCE" --out "$ICONSET_DIR/icon_128x128@2x.png"
sips -z 256 256   "$SOURCE" --out "$ICONSET_DIR/icon_256x256.png"
sips -z 512 512   "$SOURCE" --out "$ICONSET_DIR/icon_256x256@2x.png"
sips -z 512 512   "$SOURCE" --out "$ICONSET_DIR/icon_512x512.png"
sips -z 1024 1024 "$SOURCE" --out "$ICONSET_DIR/icon_512x512@2x.png"

echo "✅ Icons generated in $ICONSET_DIR"
