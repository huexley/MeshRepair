#!/bin/sh
# Installs Mesh Repair: Python environment, ~/Applications/Mesh Repair.app
# and the `meshrepair` command in ~/.local/bin.
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

echo "→ Creating Python environment…"
if command -v uv >/dev/null 2>&1; then
  [ -d .venv ] || uv venv -q -p 3.12 .venv
  uv pip install -q -p .venv/bin/python -r requirements.txt
else
  [ -d .venv ] || python3 -m venv .venv
  .venv/bin/pip install -q --upgrade pip
  .venv/bin/pip install -q -r requirements.txt
fi

echo "→ Building ~/Applications/Mesh Repair.app…"
mkdir -p "$HOME/Applications"
APP="$HOME/Applications/Mesh Repair.app"
if command -v swiftc >/dev/null 2>&1; then
  # native app with a progress window (needs Xcode or the Command Line Tools)
  app/MeshRepair/build.sh "$APP" "$DIR/.venv/bin/python" "$DIR/meshrepair.py"
else
  echo "   (swiftc not found: building the simple AppleScript droplet instead)"
  ENGINE="$(printf '%s' "'$DIR/.venv/bin/python' '$DIR/meshrepair.py'" | sed 's/[&|]/\\&/g')"
  TMP="$(mktemp -d)"
  sed "s|__ENGINE__|$ENGINE|" app/MeshRepair.applescript > "$TMP/MeshRepair.applescript"
  rm -rf "$APP"
  osacompile -o "$APP" "$TMP/MeshRepair.applescript"
  rm -rf "$TMP"
fi
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" 2>/dev/null || true

echo "→ Installing the meshrepair command…"
chmod +x meshrepair.sh
mkdir -p "$HOME/.local/bin"
ln -sf "$DIR/meshrepair.sh" "$HOME/.local/bin/meshrepair"

echo "✅ Done. Drop STL/3MF/OBJ files on ~/Applications/Mesh Repair.app"
case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) echo "   (add ~/.local/bin to your PATH to use the meshrepair command)";; esac
