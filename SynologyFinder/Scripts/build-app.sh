#!/bin/zsh
# Builds an arm64 "Synology Finder.app" into build/ (or $OUT_DIR) and signs it.
#   SIGN_IDENTITY="Developer ID Application: Name (TEAMID)"  signs for distribution (hardened runtime,
#                                                             secure timestamp, ready to notarise).
#                                                             Default is ad-hoc signing.
#   OUT_DIR=/some/folder                                      use a folder outside iCloud, which adds
#                                                             xattrs that invalidate signatures.
#   BUNDLE_ID=<other id>, VERSION=<x.y>                       see below.
set -euo pipefail
cd "${0:A:h}/.."

# Build outside ~/Documents: iCloud-synced folders add xattrs that make codesign fail.
SCRATCH="$HOME/Library/Caches/SynologyFinder-build"
swift build -c release --arch arm64 --scratch-path "$SCRATCH"
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/SynologyFinder"

APP="${OUT_DIR:-build}/Synology Finder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/SynologyFinder"

# Build AppIcon.icns from Resources/AppIcon.png (square, 1024 px or larger works best).
mkdir -p "$APP/Contents/Resources"
ICONSET="$SCRATCH/AppIcon.iconset"
rm -rf "$ICONSET" && mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
    sips -z $size $size Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) Resources/AppIcon.png --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>SynologyFinder</string>
	<key>CFBundleIconFile</key><string>AppIcon</string>
	<key>CFBundleIdentifier</key><string>au.com.automatica.SynologyFinder</string>
	<key>CFBundleName</key><string>Synology Finder</string>
	<key>CFBundlePackageType</key><string>APPL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
	<key>LSMinimumSystemVersion</key><string>14.0</string>
	<key>NSHighResolutionCapable</key><true/>
	<key>NSPrincipalClass</key><string>NSApplication</string>
	<key>NSLocalNetworkUsageDescription</key>
	<string>Synology Finder searches your local network for Synology servers.</string>
</dict>
</plist>
PLIST

# BUNDLE_ID=<other id> builds a copy macOS treats as a new app, to exercise the first-run Local Network prompt.
if [[ -n "${BUNDLE_ID:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$APP/Contents/Info.plist"
fi

# VERSION=1.2 sets the version shown in the app (default is the one in the plist above).
if [[ -n "${VERSION:-}" ]]; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
fi

xattr -cr "$APP"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
    codesign --force --sign - "$APP"
fi
codesign --verify --strict "$APP"
echo "Built $APP"
