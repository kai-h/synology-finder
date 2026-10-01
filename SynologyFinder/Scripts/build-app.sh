#!/bin/zsh
# Builds an arm64 "Synology Finder.app" into build/ and ad-hoc signs it.
set -euo pipefail
cd "${0:A:h}/.."

# Build outside ~/Documents: iCloud-synced folders add xattrs that make codesign fail.
SCRATCH="$HOME/Library/Caches/SynologyFinder-build"
swift build -c release --arch arm64 --scratch-path "$SCRATCH"
BIN="$(swift build -c release --arch arm64 --scratch-path "$SCRATCH" --show-bin-path)/SynologyFinder"

APP="build/Synology Finder.app"
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

xattr -cr "$APP"
codesign --force --sign - "$APP"
echo "Built $APP"
