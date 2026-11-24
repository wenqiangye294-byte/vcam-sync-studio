#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
BUILD_DIR="$ROOT_DIR/build_ios"

rm -rf "$DIST_DIR" "$BUILD_DIR"
mkdir -p "$DIST_DIR" "$BUILD_DIR/dylib" "$BUILD_DIR/app/Payload/VCamSync.app" "$BUILD_DIR/deb/DEBIAN" "$BUILD_DIR/deb/var/jb/Library/MobileSubstrate/DynamicLibraries"

SDK_PATH="$(xcrun --sdk iphoneos --show-sdk-path)"
echo "Using iPhoneOS SDK: $SDK_PATH"

HOOK_SRCS=(
  "$ROOT_DIR/ios/VCamHook/VCamHookEntry.m"
  "$ROOT_DIR/ios/VCamHook/VCamAVFoundationHook.m"
  "$ROOT_DIR/ios/VCamHook/VCamMediaRenderer.m"
  "$ROOT_DIR/ios/VCamHook/VCamQueueStore.m"
  "$ROOT_DIR/ios/VCamHook/VCamFloatingHUD.m"
)

COMMON_FLAGS=(
  -isysroot "$SDK_PATH"
  -miphoneos-version-min=15.0
  -fobjc-arc
  -O2
  -Wall
  -Werror=implicit-function-declaration
  -I"$ROOT_DIR/ios/shared"
)

FRAMEWORKS=(
  -framework Foundation
  -framework UIKit
  -framework AVFoundation
  -framework CoreMedia
  -framework CoreVideo
  -framework CoreImage
  -framework ImageIO
  -framework QuartzCore
)

echo ">>> Compiling VCamHook.dylib (arm64)..."
xcrun --sdk iphoneos clang \
  -arch arm64 \
  -dynamiclib \
  -install_name @rpath/VCamHook.dylib \
  "${COMMON_FLAGS[@]}" \
  "${FRAMEWORKS[@]}" \
  "${HOOK_SRCS[@]}" \
  -o "$BUILD_DIR/dylib/VCamHook-arm64.dylib"

if xcrun --sdk iphoneos clang \
  -arch arm64e \
  -dynamiclib \
  -install_name @rpath/VCamHook.dylib \
  "${COMMON_FLAGS[@]}" \
  "${FRAMEWORKS[@]}" \
  "${HOOK_SRCS[@]}" \
  -o "$BUILD_DIR/dylib/VCamHook-arm64e.dylib" 2>/dev/null; then
  echo ">>> Creating universal arm64 + arm64e dylib..."
  lipo -create \
    "$BUILD_DIR/dylib/VCamHook-arm64.dylib" \
    "$BUILD_DIR/dylib/VCamHook-arm64e.dylib" \
    -output "$DIST_DIR/VCamHook.dylib"
else
  echo ">>> arm64e skipped by toolchain, using arm64 dylib..."
  cp "$BUILD_DIR/dylib/VCamHook-arm64.dylib" "$DIST_DIR/VCamHook.dylib"
fi

ldid -S "$DIST_DIR/VCamHook.dylib"

echo ">>> Compiling VCamSync companion app..."
APP_DIR="$BUILD_DIR/app/Payload/VCamSync.app"
APP_SRCS=(
  "$ROOT_DIR/ios/VCamSyncApp/main.m"
  "$ROOT_DIR/ios/VCamSyncApp/AppDelegate.m"
  "$ROOT_DIR/ios/VCamSyncApp/MainViewController.m"
  "$ROOT_DIR/ios/VCamSyncApp/QRScannerViewController.m"
  "$ROOT_DIR/ios/VCamSyncApp/TargetAppsViewController.m"
  "$ROOT_DIR/ios/VCamSyncApp/SyncManager.m"
  "$ROOT_DIR/ios/VCamSyncApp/AppContainerMirror.m"
  "$ROOT_DIR/ios/VCamSyncApp/LocalBridgeServer.m"
)

xcrun --sdk iphoneos clang \
  -arch arm64 \
  "${COMMON_FLAGS[@]}" \
  "${FRAMEWORKS[@]}" \
  "${APP_SRCS[@]}" \
  -o "$APP_DIR/VCamSync"

cp "$ROOT_DIR/ios/VCamSyncApp/Info.plist" "$APP_DIR/Info.plist"

# Generate minimal clean 180x180 PNG AppIcon without external deps
python3 - "$APP_DIR/AppIcon.png" <<'PYEOF'
import struct, sys, zlib

w, h = 180, 180
raw = bytearray()
for y in range(h):
    raw.append(0)
    for x in range(w):
        cx, cy = x - w / 2.0, y - h / 2.0
        dist = (cx * cx + cy * cy) ** 0.5
        if 34 <= dist <= 46 or dist <= 16:
            r, g, b = 255, 255, 255
        else:
            r = int(28 + (x / w) * 16)
            g = int(95 + (y / h) * 60)
            b = 235
        raw.extend((r, g, b))

def chunk(tag, data):
    return struct.pack(">I", len(data)) + tag + data + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF)

png = (
    b"\x89PNG\r\n\x1a\n"
    + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
    + chunk(b"IDAT", zlib.compress(bytes(raw), 9))
    + chunk(b"IEND", b"")
)
with open(sys.argv[1], "wb") as fp:
    fp.write(png)
PYEOF

ldid -S"$ROOT_DIR/ios/VCamSyncApp/entitlements.plist" "$APP_DIR/VCamSync"

(cd "$BUILD_DIR/app" && zip -qry "$DIST_DIR/VCamSync.tipa" Payload)
cp "$DIST_DIR/VCamSync.tipa" "$DIST_DIR/VCamSync.ipa"

echo ">>> Packaging Dopamine rootless .deb..."
DEB_DIR="$BUILD_DIR/deb"
cp "$ROOT_DIR/ios/VCamHook/theos/control" "$DEB_DIR/DEBIAN/control"
cp "$DIST_DIR/VCamHook.dylib" "$DEB_DIR/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamHook.dylib"
cp "$ROOT_DIR/ios/VCamHook/theos/VCamTweak.plist" "$DEB_DIR/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamHook.plist"
chmod 0755 "$DEB_DIR/DEBIAN" "$DEB_DIR/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamHook.dylib"
chmod 0644 "$DEB_DIR/DEBIAN/control" "$DEB_DIR/var/jb/Library/MobileSubstrate/DynamicLibraries/VCamHook.plist"

dpkg-deb -Zgzip -b "$DEB_DIR" "$DIST_DIR/VCamTweak-rootless.deb"

echo ">>> Build complete! Artifacts:"
ls -lh "$DIST_DIR"
file "$DIST_DIR/VCamHook.dylib"
otool -L "$DIST_DIR/VCamHook.dylib"
ldid -e "$APP_DIR/VCamSync"
