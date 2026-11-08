#!/bin/zsh
# Builds BudsControl.app into ./build (no Xcode project needed).
set -euo pipefail
cd "${0:A:h}"

APP=build/BudsControl.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Universal binary: Apple silicon and Intel.
for arch in arm64 x86_64; do
    swiftc -O -swift-version 5 \
        -target "$arch-apple-macos14.0" \
        -framework IOBluetooth -framework SwiftUI -framework Carbon -framework ServiceManagement \
        Sources/*.swift -o "build/BudsControl-$arch" 2>&1 | grep -v "^$" || true
    [[ -x "build/BudsControl-$arch" ]] || { echo "build failed ($arch)"; exit 1; }
done
lipo -create build/BudsControl-arm64 build/BudsControl-x86_64 -output "$APP/Contents/MacOS/BudsControl"
rm build/BudsControl-arm64 build/BudsControl-x86_64

# App icon, drawn once by tools/MakeIcon.swift.
if [[ ! -f build/AppIcon.icns ]]; then
    rm -rf build/AppIcon.iconset
    swift tools/MakeIcon.swift build/AppIcon.iconset
    iconutil -c icns build/AppIcon.iconset -o build/AppIcon.icns
fi
cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>BudsControl</string>
    <key>CFBundleDisplayName</key><string>Buds Control</string>
    <key>CFBundleIdentifier</key><string>io.github.amarsakore.budscontrol</string>
    <key>CFBundleExecutable</key><string>BudsControl</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.0</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
    <key>NSBluetoothAlwaysUsageDescription</key>
    <string>Buds Control talks to your OnePlus Buds to switch noise cancellation and transparency.</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$APP"
echo "Built $APP"
