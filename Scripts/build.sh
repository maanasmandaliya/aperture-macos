#!/bin/bash
#
# build.sh — build Aperture.app without Xcode's build system.
#
# Normally you would just use Xcode (or `xcodebuild -scheme Aperture build`).
# This script exists because `xcodebuild` refuses to run until Xcode's one-time
# system components are installed (`sudo xcodebuild -runFirstLaunch`), and it is
# useful on machines where only the compiler is available. It produces the same
# app bundle, ad-hoc signed with the project's entitlements.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
APP="$BUILD_DIR/Aperture.app"
DEPLOYMENT_TARGET="15.0"
CONFIG="${1:-debug}"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

case "$CONFIG" in
  release) OPT_FLAGS=(-O -whole-module-optimization) ;;
  *)       OPT_FLAGS=(-Onone -g) ;;
esac

echo "==> Building Aperture ($CONFIG) for $ARCH-apple-macos$DEPLOYMENT_TARGET"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# Collected into an array so a project path containing spaces still works.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Aperture" -name '*.swift' | sort)

xcrun swiftc \
  -swift-version 6 \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  -sdk "$SDK" \
  "${OPT_FLAGS[@]}" \
  -module-name Aperture \
  -o "$APP/Contents/MacOS/Aperture" \
  "${SOURCES[@]}"

cp "$ROOT/Config/Info.plist" "$APP/Contents/Info.plist"

# An Xcode build compiles Assets.xcassets with actool. Outside Xcode, the same
# PNGs are packed into a classic .icns with iconutil, which has no dependency on
# Xcode's installed components.
ICONSET="$ROOT/Aperture/Resources/Assets.xcassets/AppIcon.appiconset"
if [ -d "$ICONSET" ]; then
  STAGE="$BUILD_DIR/AppIcon.iconset"
  rm -rf "$STAGE"; mkdir -p "$STAGE"
  cp "$ICONSET"/icon_*.png "$STAGE/"
  iconutil --convert icns "$STAGE" --output "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" >/dev/null
fi

# Sign with a real identity when one exists, ad-hoc otherwise.
#
# This matters beyond tidiness: macOS keys Accessibility and Input Monitoring to
# the signing identity, and an ad-hoc signature is only a hash of the binary — so
# every rebuild looks like a different app and silently loses those grants. A
# stable identity makes them persist. If this script signed ad-hoc while Xcode
# signed properly, the two builds would be different apps to macOS and only one
# of them would ever be permitted.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | awk -F'"' '/Apple Development|Developer ID Application/ {print $2; exit}')"
fi

if [ -n "$IDENTITY" ]; then
  echo "==> Signing as $IDENTITY"
  codesign --force --sign "$IDENTITY" --options runtime \
    --entitlements "$ROOT/Config/Aperture.entitlements" "$APP"
else
  echo "==> No signing identity found; signing ad-hoc (permissions will not persist across rebuilds)"
  codesign --force --sign - --entitlements "$ROOT/Config/Aperture.entitlements" "$APP"
fi

echo "==> Built $APP"
