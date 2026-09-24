#!/bin/bash

# Droid House Release Script
# Automates building and packaging the app into a DMG.

APP_NAME="droid house"
SCHEME="droid house"
BUILD_DIR="./build"
DMG_NAME="DroidHouse_v1.6.dmg"

echo "🚀 Starting Release Process for $APP_NAME v1.6..."

# 1. Clean build directory
echo "🧹 Cleaning build directory..."
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# 2. Build the app
echo "🏗 Building $APP_NAME in Release mode..."
xcodebuild -project "$APP_NAME.xcodeproj" \
           -scheme "$SCHEME" \
           -configuration Release \
           -derivedDataPath "$BUILD_DIR" \
           CODE_SIGNING_ALLOWED=NO \
           build

if [ $? -ne 0 ]; then
    echo "❌ Build failed! Please check the errors above."
    exit 1
fi

APP_PATH="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"

# 3. Create DMG
echo "📦 Packaging into $DMG_NAME..."
hdiutil create -volname "$APP_NAME" -srcfolder "$APP_PATH" -ov -format UDZO "$DMG_NAME"

if [ $? -eq 0 ]; then
    echo "✅ Success! $DMG_NAME has been created."
    echo "🔗 You can now release this file to the public."
else
    echo "❌ Failed to create DMG."
    exit 1
fi
