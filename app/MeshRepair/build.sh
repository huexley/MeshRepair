#!/bin/sh
# Builds the native Mesh Repair.app: build.sh OUT.app PYTHON SCRIPT
set -e
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$1"; PYTHON="$2"; SCRIPT="$3"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/Mesh Repair.app/Contents/MacOS" "$TMP/Mesh Repair.app/Contents/Resources"
B="$TMP/Mesh Repair.app/Contents"
swiftc -O -parse-as-library -target "$(uname -m)-apple-macos14.0" \
  "$HERE/MeshRepairApp.swift" -o "$B/MacOS/MeshRepair"
cp "$HERE/Info.plist" "$B/Info.plist"
plutil -replace MRPython -string "$PYTHON" "$B/Info.plist"
plutil -replace MRScript -string "$SCRIPT" "$B/Info.plist"
swift "$HERE/make_icon.swift" "$TMP/AppIcon.iconset"
iconutil -c icns "$TMP/AppIcon.iconset" -o "$B/Resources/AppIcon.icns"
codesign --force -s - "$TMP/Mesh Repair.app"

rm -rf "$APP"
mv "$TMP/Mesh Repair.app" "$APP"
