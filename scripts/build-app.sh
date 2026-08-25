#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PROJECT_DIR="${SCRIPT_DIR:h}"
APP_BUNDLE="$PROJECT_DIR/dist/바탕화면뿌시기.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"

cd "$PROJECT_DIR"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

if [[ "$APP_BUNDLE" != "$PROJECT_DIR/dist/바탕화면뿌시기.app" ]]; then
    print -u2 "Unexpected bundle path; refusing to replace it."
    exit 1
fi

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR"
cp "$PROJECT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BIN_DIR/BatangBbusigi" "$MACOS_DIR/BatangBbusigi"
chmod +x "$MACOS_DIR/BatangBbusigi"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null

print "$APP_BUNDLE"
