#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_DIR="$SCRIPT_DIR/Readycode.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
SRC="$MACOS_DIR/main.swift"
BIN="$MACOS_DIR/readycode"

echo "Building Readycode..."
swiftc -o "$BIN" "$SRC" \
    -framework Cocoa \
    -framework SwiftUI \
    -parse-as-library \
    -O

echo "Built: $BIN"
echo "Run: open $APP_DIR"
