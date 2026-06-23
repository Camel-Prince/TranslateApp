#!/bin/bash
# Build script for TranslateApp
# Works on both Apple Silicon (M1/M2/M3/M4) and Intel Macs
# Usage: ./build.sh

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$PROJECT_DIR/TranslateApp"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
BUILD_DIR="$PROJECT_DIR/build"
APP_NAME="TranslateApp"
APP_BUNDLE="$BUILD_DIR/$APP_NAME.app"

echo "🔨 Building TranslateApp..."

# Clean
rm -rf "$BUILD_DIR"
mkdir -p "$BUILD_DIR"

# Collect source files
SOURCES=(
    "$SRC_DIR/main.swift"
    "$SRC_DIR/AppDelegate.swift"
    "$SRC_DIR/HotkeyManager.swift"
    "$SRC_DIR/TextGrabber.swift"
    "$SRC_DIR/TranslateService.swift"
    "$SRC_DIR/PopupPanel.swift"
    "$SRC_DIR/VocabularyDB.swift"
    "$SRC_DIR/ConfigManager.swift"
    "$SRC_DIR/SettingsPanel.swift"
)

# Detect architecture
ARCH=$(uname -m)
echo "📦 Architecture: $ARCH"
echo "📦 Compiling Swift sources..."

swiftc \
    -o "$BUILD_DIR/$APP_NAME" \
    -target "${ARCH}-apple-macosx13.0" \
    -sdk "$(xcrun --show-sdk-path)" \
    -framework Cocoa \
    -framework Carbon \
    -lsqlite3 \
    "${SOURCES[@]}"

echo "✅ Compilation successful"

# Create .app bundle structure
echo "📁 Creating app bundle..."
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"

# Copy executable
cp "$BUILD_DIR/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# Copy Info.plist
cp "$SRC_DIR/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Copy app icon
if [ -f "$SRC_DIR/AppIcon.icns" ]; then
    cp "$SRC_DIR/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
    echo "🎨 App icon included"
fi

# Bundle Python script into Resources
cp "$SCRIPTS_DIR/paper_translate.py" "$APP_BUNDLE/Contents/Resources/paper_translate.py"
echo "📜 Python script bundled"

# Create PkgInfo
echo -n "APPL????" > "$APP_BUNDLE/Contents/PkgInfo"

# Ad-hoc codesign (required on macOS 13+)
echo "🔏 Code signing..."
codesign --force --deep --sign - "$APP_BUNDLE"

# Reset TCC entry (rebuild changes cdhash, old permission becomes stale)
echo "🔑 Resetting accessibility permission (rebuild invalidates old entry)..."
tccutil reset Accessibility com.local.TranslateApp 2>/dev/null || true

echo ""
echo "============================================"
echo "✅ App bundle created at:"
echo "   $APP_BUNDLE"
echo ""
echo "📌 To run:"
echo "   open $APP_BUNDLE"
echo ""
echo "⚠️  First launch: Grant accessibility permission in"
echo "   System Settings → Privacy & Security → Accessibility"
echo ""
echo "🔧 Requires Python 3 with pymupdf for paper import:"
echo "   pip3 install pymupdf"
echo "============================================"
echo ""

# Auto-copy to /Applications
echo "📦 Copying to /Applications/..."
cp -rf "$APP_BUNDLE" /Applications/
echo "✅ /Applications/TranslateApp.app updated"