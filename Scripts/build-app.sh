#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build"
APP_BUNDLE="$BUILD_DIR/Deskland.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

echo "==> Building Deskland (Release, Swift 6 / macOS 27)..."
cd "$ROOT_DIR"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXEC_SRC="$BIN_PATH/Deskland"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "==> Copying stripped native binary..."
cp "$EXEC_SRC" "$MACOS_DIR/Deskland"
strip -x "$MACOS_DIR/Deskland"
chmod +x "$MACOS_DIR/Deskland"

echo "==> Precompiling Metal shaders -> default.metallib..."
AIR_TMP="$(mktemp -t deskland_shaders).air"
xcrun -sdk macosx metal -O2 -c "$ROOT_DIR/Sources/Deskland/Metal/Shaders.metal" -o "$AIR_TMP"
xcrun -sdk macosx metallib "$AIR_TMP" -o "$RESOURCES_DIR/default.metallib"
rm -f "$AIR_TMP"

echo "==> Staging SwiftPM resource bundle..."
if [ -d "$BIN_PATH/Deskland_Deskland.bundle" ]; then
    cp -R "$BIN_PATH/Deskland_Deskland.bundle" "$RESOURCES_DIR/"
    rm -f "$RESOURCES_DIR/Deskland_Deskland.bundle/Shaders.metal"
fi

echo "==> Compiling full-bleed AppIcon asset catalog & AppIcon.icns from Assets/AppIcon-1024.png..."
ICON_MASTER="$ROOT_DIR/Assets/AppIcon-1024.png"
XCASSETS_DIR="$BUILD_DIR/Assets.xcassets"
APPICONSET_DIR="$XCASSETS_DIR/AppIcon.appiconset"
rm -rf "$XCASSETS_DIR"
mkdir -p "$APPICONSET_DIR"

sips -z 16 16     "$ICON_MASTER" --out "$APPICONSET_DIR/icon_16x16.png"      >/dev/null
sips -z 32 32     "$ICON_MASTER" --out "$APPICONSET_DIR/icon_16x16@2x.png"   >/dev/null
sips -z 32 32     "$ICON_MASTER" --out "$APPICONSET_DIR/icon_32x32.png"      >/dev/null
sips -z 64 64     "$ICON_MASTER" --out "$APPICONSET_DIR/icon_32x32@2x.png"   >/dev/null
sips -z 128 128   "$ICON_MASTER" --out "$APPICONSET_DIR/icon_128x128.png"    >/dev/null
sips -z 256 256   "$ICON_MASTER" --out "$APPICONSET_DIR/icon_128x128@2x.png" >/dev/null
sips -z 256 256   "$ICON_MASTER" --out "$APPICONSET_DIR/icon_256x256.png"    >/dev/null
sips -z 512 512   "$ICON_MASTER" --out "$APPICONSET_DIR/icon_256x256@2x.png" >/dev/null
sips -z 512 512   "$ICON_MASTER" --out "$APPICONSET_DIR/icon_512x512.png"    >/dev/null
cp "$ICON_MASTER" "$APPICONSET_DIR/icon_512x512@2x.png"

cat > "$APPICONSET_DIR/Contents.json" <<'JSON'
{
  "images" : [
    { "filename" : "icon_16x16.png",    "idiom" : "mac", "scale" : "1x", "size" : "16x16" },
    { "filename" : "icon_16x16@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "16x16" },
    { "filename" : "icon_32x32.png",    "idiom" : "mac", "scale" : "1x", "size" : "32x32" },
    { "filename" : "icon_32x32@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "32x32" },
    { "filename" : "icon_128x128.png",    "idiom" : "mac", "scale" : "1x", "size" : "128x128" },
    { "filename" : "icon_128x128@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "128x128" },
    { "filename" : "icon_256x256.png",    "idiom" : "mac", "scale" : "1x", "size" : "256x256" },
    { "filename" : "icon_256x256@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "256x256" },
    { "filename" : "icon_512x512.png",    "idiom" : "mac", "scale" : "1x", "size" : "512x512" },
    { "filename" : "icon_512x512@2x.png", "idiom" : "mac", "scale" : "2x", "size" : "512x512" }
  ],
  "info" : { "author" : "xcode", "version" : 1 }
}
JSON

if xcrun --find actool >/dev/null 2>&1; then
    xcrun actool "$XCASSETS_DIR" \
        --compile "$RESOURCES_DIR" \
        --platform macosx \
        --minimum-deployment-target 27.0 \
        --app-icon AppIcon \
        --output-partial-info-plist "$BUILD_DIR/assetcatalog_info.plist" >/dev/null
    rm -f "$BUILD_DIR/assetcatalog_info.plist"
fi

if [ ! -f "$RESOURCES_DIR/AppIcon.icns" ]; then
    ICONSET_DIR="$BUILD_DIR/AppIcon.iconset"
    rm -rf "$ICONSET_DIR"
    mkdir -p "$ICONSET_DIR"
    cp "$APPICONSET_DIR"/icon_*.png "$ICONSET_DIR/"
    iconutil -c icns "$ICONSET_DIR" -o "$RESOURCES_DIR/AppIcon.icns"
    rm -rf "$ICONSET_DIR"
fi
rm -rf "$XCASSETS_DIR"

echo "==> Writing Info.plist..."
cat > "$CONTENTS_DIR/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleDisplayName</key>
    <string>Deskland</string>
    <key>CFBundleExecutable</key>
    <string>Deskland</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.withsundae.deskland</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>Deskland</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>27.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSAppleEventsUsageDescription</key>
    <string>Deskland asks Finder to open Get Info windows for your desktop items.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

echo "==> Ad-hoc signing Deskland.app..."
codesign --force --deep --sign - "$APP_BUNDLE"

echo "==> Built: $APP_BUNDLE"
du -sh "$APP_BUNDLE" "$MACOS_DIR/Deskland"
