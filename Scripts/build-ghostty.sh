#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$PROJECT_DIR/ghostty"
FRAMEWORK_DIR="$PROJECT_DIR/Frameworks"

echo "Building GhosttyKit.xcframework..."

cd "$GHOSTTY_DIR"

zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=native \
    -Doptimize=ReleaseFast

# Copy the built xcframework to our Frameworks directory
# The xcframework is output to macos/GhosttyKit.xcframework by zig build
XCFW_PATH="macos/GhosttyKit.xcframework"
if [ ! -d "$XCFW_PATH" ]; then
    XCFW_PATH="zig-out/GhosttyKit.xcframework"
fi

mkdir -p "$FRAMEWORK_DIR"
cp -R "$XCFW_PATH" "$FRAMEWORK_DIR/"

echo "GhosttyKit.xcframework built successfully at $FRAMEWORK_DIR/GhosttyKit.xcframework"
