#!/bin/bash
#
# Build WA Reader for Muse.app and sign it with the local identity
# (~/OpenCode/signing.md §9 shape): prefer the certificate in the dedicated
# keychain; fall back to an explicit identifier-only ad hoc designated
# requirement, and ALWAYS print which signature was applied.
#
#   Scripts/build.sh             build + sign (into ./build/)
#   Scripts/build.sh --install   also ditto into /Applications and re-register
#
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="WA Reader for Muse"
BUNDLE_ID="com.ericng.wareaderformuse"
BIN_NAME="WAReaderForMuse"
IDENTITY="WA Reader for Muse Local Signing"
KEYCHAIN="$HOME/Library/Keychains/wareader-signing.keychain-db"
PASSWORD_FILE="$HOME/Library/Application Support/WAReaderForMuse/signing/keychain-password"

BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

fail() { echo "build.sh: $*" >&2; exit 1; }

echo "Compiling…"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -target arm64-apple-macosx26.0 \
    -o "$APP/Contents/MacOS/$BIN_NAME" \
    Sources/*.swift -lsqlite3 || fail "swiftc failed"
cp Info.plist "$APP/Contents/Info.plist"

# App icon: build AppIcon.icns from the 1024px source (iconutil is Mac-only).
if [[ -f icon-src/icon-1024.png ]] && command -v iconutil >/dev/null; then
    ICONSET="build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET" "$APP/Contents/Resources"
    for spec in "16:icon_16x16" "32:icon_16x16@2x" "32:icon_32x32" "64:icon_32x32@2x" \
                "128:icon_128x128" "256:icon_128x128@2x" "256:icon_256x256" \
                "512:icon_256x256@2x" "512:icon_512x512" "1024:icon_512x512@2x"; do
        size="${spec%%:*}"; name="${spec##*:}"
        sips -z "$size" "$size" icon-src/icon-1024.png --out "$ICONSET/$name.png" >/dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" \
        && echo "icon        AppIcon.icns built" || echo "icon        FAILED (continuing without)"
fi

# --- sign (after build, before install; never --deep for signing) ---
if [[ -f "$KEYCHAIN" && -f "$PASSWORD_FILE" ]]; then
    security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN" >/dev/null 2>&1 \
        || fail "could not unlock $KEYCHAIN; re-run Scripts/create-signing-identity.sh"
    codesign --force \
        --sign "$IDENTITY" \
        --keychain "$KEYCHAIN" \
        --identifier "$BUNDLE_ID" \
        "$APP" || fail "signing with \"$IDENTITY\" failed"
else
    echo "WARNING: no local signing identity — using ad hoc with identifier-only DR (stopgap)"
    codesign --force -s - \
        --identifier "$BUNDLE_ID" \
        --requirements "=designated => identifier \"$BUNDLE_ID\"" \
        "$APP" || fail "ad hoc signing failed"
fi

codesign --verify --deep --strict "$APP" || fail "signature verification failed"

SIGNATURE="$(codesign -dv --verbose=4 "$APP" 2>&1 \
    | awk -F= '/^Authority=/{a=$2} END{if (a != "") print a}')"
echo "signature   ${SIGNATURE:-ad hoc}"
echo "requirement $(codesign -d -r- "$APP" 2>&1 | grep designated || true)"
echo "built       $APP"

if [[ "${1:-}" == "--install" ]]; then
    DEST="/Applications/$APP_NAME.app"
    echo "Installing to $DEST"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
    /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister -f "$DEST" || true
    echo "installed   $DEST"
fi
