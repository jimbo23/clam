#!/bin/sh
# Build and package locally. No upload, notarization, or release is performed.
set -eu

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' 'Clam.app packaging requires macOS 13 or later and the Xcode command-line tools.' >&2
    exit 1
fi

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
PLIST="$ROOT/Resources/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")
APP="$ROOT/build/Clam.app"
ARCHIVE="$ROOT/dist/Clam-$VERSION.zip"

# Use identical options for the build and its output-directory query: SwiftPM
# selects a different directory for multi-architecture builds.
swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64
BIN_PATH=$(swift build --package-path "$ROOT" -c release --arch arm64 --arch x86_64 --show-bin-path)

mkdir -p "$ROOT/build" "$ROOT/dist"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_PATH/Clam" "$APP/Contents/MacOS/Clam"
cp "$PLIST" "$APP/Contents/Info.plist"
cp "$ROOT/scripts/install-helper.sh" "$APP/Contents/Resources/install-helper.sh"
cp "$ROOT/scripts/uninstall-helper.sh" "$APP/Contents/Resources/uninstall-helper.sh"
cp "$ROOT/Resources/com.jimbo23.clam.bootreset.plist" "$APP/Contents/Resources/com.jimbo23.clam.bootreset.plist"
chmod 755 "$APP/Contents/MacOS/Clam" \
    "$APP/Contents/Resources/install-helper.sh" \
    "$APP/Contents/Resources/uninstall-helper.sh"

if [ -n "${DEVELOPER_ID:-}" ]; then
    /usr/bin/codesign --force --deep --options runtime --timestamp \
        --sign "$DEVELOPER_ID" "$APP"
else
    /usr/bin/codesign --force --deep --sign - "$APP"
fi

# Remove the old archive so ditto cannot retain entries from a previous build.
rm -f "$ARCHIVE"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ARCHIVE"
/usr/bin/shasum -a 256 "$ARCHIVE"
printf 'Built %s\nPackaged %s\n' "$APP" "$ARCHIVE"
