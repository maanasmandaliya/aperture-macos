#!/bin/bash
#
# screenshots.sh — regenerate the images the README shows.
#
# Renders the overlay's states offscreen from the app's own SwiftUI views, with
# `PreviewData` fixtures standing in for media and calendar content. Deliberately
# not a screen capture: capturing the real overlay would also publish whatever
# happened to be on the display behind it, and the fixtures make the output
# identical from one run to the next.
#
# Compiles the app sources the way test.sh does — everything except main.swift,
# whose top-level entry point would collide with the renderer's own `@main`.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/Docs/screenshots}"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
TOOL="$BUILD_DIR/screenshots"
DEPLOYMENT_TARGET="15.0"

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR" "$OUT"

# Collected into an array so a project path containing spaces still works.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Aperture" -name '*.swift' ! -name 'main.swift' | sort)

echo "==> Building the renderer (${#SOURCES[@]} app sources)"
xcrun swiftc \
  -swift-version 6 \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  -sdk "$SDK" \
  -Onone -g \
  -module-name Aperture \
  -o "$TOOL" \
  "$ROOT/Scripts/screenshots.swift" \
  "${SOURCES[@]}"

echo "==> Rendering into $OUT"
exec "$TOOL" "$OUT"
