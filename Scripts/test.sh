#!/bin/bash
#
# test.sh — run the unit tests without Xcode's build system.
#
# Compiles the app sources and the test sources into one XCTest bundle (minus
# the `@main` entry point, which cannot live in a bundle) and runs it through
# `xcrun xctest`. Equivalent to `xcodebuild test -scheme Aperture` once Xcode's
# system components are installed.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
BUNDLE="$BUILD_DIR/ApertureTests.xctest"
DEPLOYMENT_TARGET="15.0"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"
XCTEST_FRAMEWORKS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/Library/Frameworks"
# XCTest's Swift assertion functions (XCTAssertEqual and friends) live in the
# Swift overlay, not in the Objective-C framework, so both have to be on the
# search path.
XCTEST_SWIFT_LIBS="$DEVELOPER_DIR/Platforms/MacOSX.platform/Developer/usr/lib"

rm -rf "$BUNDLE" "$BUILD_DIR/tests-src"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUILD_DIR/tests-src"

# App and test sources compile into one module here, so `@testable import` is
# both unnecessary and invalid; strip it from the copies we compile.
for file in "$ROOT"/ApertureTests/*.swift; do
  sed 's/^@testable import Aperture$//' "$file" > "$BUILD_DIR/tests-src/$(basename "$file")"
done

# `main.swift` holds the app's top-level entry point, which cannot appear inside
# a loadable test bundle. Collected into an array so a project path containing
# spaces still works.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Aperture" -name '*.swift' ! -name 'main.swift' | sort)
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$BUILD_DIR/tests-src" -name '*.swift' | sort)

xcrun swiftc \
  -swift-version 6 \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  -sdk "$SDK" \
  -Onone -g \
  -module-name ApertureTests \
  -F "$XCTEST_FRAMEWORKS" \
  -framework XCTest \
  -I "$XCTEST_SWIFT_LIBS" \
  -L "$XCTEST_SWIFT_LIBS" \
  -lXCTestSwiftSupport \
  -Xlinker -bundle \
  -Xlinker -rpath -Xlinker "$XCTEST_FRAMEWORKS" \
  -Xlinker -rpath -Xlinker "$XCTEST_SWIFT_LIBS" \
  -o "$BUNDLE/Contents/MacOS/ApertureTests" \
  "${SOURCES[@]}"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>ApertureTests</string>
	<key>CFBundleIdentifier</key><string>com.aperture.ApertureTests</string>
	<key>CFBundleName</key><string>ApertureTests</string>
	<key>CFBundlePackageType</key><string>BNDL</string>
	<key>CFBundleShortVersionString</key><string>1.0</string>
	<key>CFBundleVersion</key><string>1</string>
</dict>
</plist>
PLIST

codesign --force --sign - "$BUNDLE" 2>/dev/null || true

echo "==> Running ApertureTests"
exec xcrun xctest "$BUNDLE"
