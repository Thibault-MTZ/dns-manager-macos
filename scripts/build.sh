#!/bin/bash
set -euo pipefail
PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"
RELEASE_VERSION="$(cat VERSION)"
BUNDLE_VERSION="${RELEASE_VERSION%%-*}"
export CLANG_MODULE_CACHE_PATH="$PROJECT_DIR/.build/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PROJECT_DIR/.build/module-cache"
SWIFT_FLAGS=(--disable-sandbox --build-system native --cache-path .build/cache -Xswiftc -module-cache-path -Xswiftc .build/module-cache)
swift build -c release "${SWIFT_FLAGS[@]}"
BUILD_DIR="$(swift build -c release "${SWIFT_FLAGS[@]}" --show-bin-path)"
APP_DIR="$PROJECT_DIR/dist/DNS Manager.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
copy_binary() {
    # Replace the inode rather than overwriting a signed executable in use.
    cp "$1" "$2.new.$$"
    mv -f "$2.new.$$" "$2"
}
copy_binary "$BUILD_DIR/DNSManagerMenu" "$APP_DIR/Contents/MacOS/DNSManagerMenu"
copy_binary "$BUILD_DIR/dns-manager" "$APP_DIR/Contents/Resources/dns-manager"
copy_binary "$BUILD_DIR/dns-manager" "$PROJECT_DIR/dist/dns-manager"
copy_binary "$BUILD_DIR/dns-manager-admin" "$PROJECT_DIR/dist/dns-manager-admin"
codesign --force --sign - "$PROJECT_DIR/dist/dns-manager-admin"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>DNSManagerMenu</string>
<key>CFBundleIdentifier</key><string>org.dnsmanager.app</string>
<key>CFBundleName</key><string>DNS Manager</string>
<key>CFBundleDisplayName</key><string>DNS Manager</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>LSUIElement</key><true/>
<key>NSAppleEventsUsageDescription</key><string>Ouvrir le TUI DNS Manager dans Terminal.</string>
</dict></plist>
PLIST
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $BUNDLE_VERSION" "$APP_DIR/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion ${RELEASE_VERSION##*.}" "$APP_DIR/Contents/Info.plist"
cat > "$PROJECT_DIR/dist/Lancer TUI.command" <<'LAUNCH'
#!/bin/bash
cd "$(dirname "$0")"
exec ./dns-manager --tui
LAUNCH
chmod +x "$PROJECT_DIR/dist/Lancer TUI.command"
cp "$PROJECT_DIR/scripts/launch-ghostty.sh" "$PROJECT_DIR/dist/Lancer TUI Ghostty.command"
chmod +x "$PROJECT_DIR/dist/Lancer TUI Ghostty.command"
cp "$PROJECT_DIR/scripts/install-admin.sh" "$PROJECT_DIR/dist/Installer autorisation DNS.command"
chmod +x "$PROJECT_DIR/dist/Installer autorisation DNS.command"
codesign --force --sign - "$APP_DIR/Contents/Resources/dns-manager"
codesign --force --sign - "$APP_DIR"
printf '\nPrêt : %s\nTUI : %s\n' "$APP_DIR" "$PROJECT_DIR/dist/Lancer TUI.command"
