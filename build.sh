#!/bin/bash
# Builds Kilodown.app (viewer/editor + Quick Look extension) into ./build.
#   ./build.sh            build only
#   ./build.sh install    build, copy to /Applications and register Quick Look
#   ./build.sh release    build and package dist/Kilodown-<version>.zip
# Needs only Apple's Command Line Tools (xcode-select --install).
set -euo pipefail
cd "$(dirname "$0")"

# Fall back to the standalone Command Line Tools if full Xcode isn't usable.
if ! xcrun --find swiftc >/dev/null 2>&1 && [ -d /Library/Developer/CommandLineTools ]; then
  export DEVELOPER_DIR=/Library/Developer/CommandLineTools
fi

APP_NAME="Kilodown"
BUNDLE_ID="io.github.vladuzh.kilodown"
BUILD=build
APP="$BUILD/$APP_NAME.app"
APPEX="$APP/Contents/PlugIns/KilodownQL.appex"
SDK="$(xcrun --show-sdk-path)"
ARCHS="${ARCHS:-arm64 x86_64}"   # universal by default; e.g. ARCHS=arm64 for a quicker build

rm -rf "$APP" "$BUILD/obj"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" \
         "$APPEX/Contents/MacOS" "$APPEX/Contents/Resources" "$BUILD/obj"

APP_BINS=(); QL_BINS=()
for ARCH in $ARCHS; do
  echo "==> Compiling for $ARCH"
  swiftc -O -target "$ARCH-apple-macos13.0" -sdk "$SDK" -module-name Kilodown \
    Sources/Shared/*.swift Sources/App/*.swift \
    -o "$BUILD/obj/Kilodown-$ARCH"
  swiftc -O -target "$ARCH-apple-macos13.0" -sdk "$SDK" -module-name KilodownQL \
    -parse-as-library -application-extension \
    -Xlinker -e -Xlinker _NSExtensionMain \
    Sources/Shared/*.swift Sources/QuickLook/*.swift \
    -o "$BUILD/obj/KilodownQL-$ARCH"
  APP_BINS+=("$BUILD/obj/Kilodown-$ARCH"); QL_BINS+=("$BUILD/obj/KilodownQL-$ARCH")
done
lipo -create "${APP_BINS[@]}" -output "$APP/Contents/MacOS/Kilodown"
lipo -create "${QL_BINS[@]}" -output "$APPEX/Contents/MacOS/KilodownQL"
rm -rf "$BUILD/obj"

echo "==> Assembling bundle"
cp Support/App-Info.plist "$APP/Contents/Info.plist"
cp Support/QuickLook-Info.plist "$APPEX/Contents/Info.plist"
for dir in "$APP/Contents/Resources" "$APPEX/Contents/Resources"; do
  cp Resources/marked.min.js Resources/style.css Resources/marked-LICENSE.md "$dir/"
done

ICONSET="$BUILD/AppIcon.iconset"
rm -rf "$ICONSET"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

echo "==> Signing (ad hoc)"
codesign --force --sign - --entitlements Support/QuickLook.entitlements "$APPEX"
codesign --force --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

case "${1:-}" in
install)
  DEST="/Applications/$APP_NAME.app"
  [ -w /Applications ] || { DEST="$HOME/Applications/$APP_NAME.app"; mkdir -p "$HOME/Applications"; }
  echo "==> Installing to $DEST"
  if pgrep -x "$APP_NAME" >/dev/null; then
    echo "Kilodown is running. Quit it first (save any edits), then run this again." >&2
    exit 1
  fi
  rm -rf "$DEST"
  ditto "$APP" "$DEST"
  LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREGISTER" -f "$DEST"
  pluginkit -a "$DEST/Contents/PlugIns/KilodownQL.appex"
  pluginkit -e use -i "$BUNDLE_ID.quicklook"
  qlmanage -r >/dev/null 2>&1 || true
  qlmanage -r cache >/dev/null 2>&1 || true
  echo "Installed. Select a .md file in Finder and press Space."
  ;;
release)
  VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Support/App-Info.plist)"
  mkdir -p dist
  ZIP="dist/$APP_NAME-$VERSION.zip"
  rm -f "$ZIP"
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "Packaged $ZIP ($(du -sh "$ZIP" | cut -f1))"
  shasum -a 256 "$ZIP"
  ;;
esac
