#!/bin/bash
#
# demo.sh — record the animated GIF the README shows.
#
# Hosts the app's own OverlayRootView in a small window, drives it through its
# states with the same calls the app makes, captures that window with
# ScreenCaptureKit and writes Docs/screenshots/demo.gif.
#
# The window is briefly visible while recording — the window server does not
# composite, and so cannot capture, a window that is not on screen. It does not
# take focus, and only that window is in frame, so nothing else on the display
# is recorded. macOS will ask for Screen Recording permission the first time.
#
# Pass --contact-sheet to also write a column of sampled frames, for checking the
# motion without a GIF viewer. It lands in .build, not Docs, so a diagnostic is
# never committed as if it were a screenshot.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="${BUILD_DIR:-$ROOT/.build}"
TOOL="$BUILD_DIR/demo"
DEPLOYMENT_TARGET="15.0"

OUT="$ROOT/Docs/screenshots"
EXTRA=()
for argument in "$@"; do
  case "$argument" in
    --*) EXTRA+=("$argument") ;;
    *) OUT="$argument" ;;
  esac
done

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
ARCH="$(uname -m)"

mkdir -p "$BUILD_DIR" "$OUT"

# Collected into an array so a project path containing spaces still works.
SOURCES=()
while IFS= read -r file; do SOURCES+=("$file"); done < <(find "$ROOT/Aperture" -name '*.swift' ! -name 'main.swift' | sort)

echo "==> Building the recorder (${#SOURCES[@]} app sources)"
xcrun swiftc \
  -swift-version 6 \
  -target "$ARCH-apple-macos$DEPLOYMENT_TARGET" \
  -sdk "$SDK" \
  -Onone -g \
  -module-name Aperture \
  -o "$TOOL" \
  "$ROOT/Scripts/demo.swift" \
  "${SOURCES[@]}"

echo "==> Recording into $OUT (about ten seconds; a small window will appear)"
ARGS=("$OUT")
for argument in ${EXTRA+"${EXTRA[@]}"}; do
  case "$argument" in
    --contact-sheet) ARGS+=("--contact-sheet=$BUILD_DIR/demo-contactsheet.png") ;;
    *) ARGS+=("$argument") ;;
  esac
done

exec "$TOOL" "${ARGS[@]}"
