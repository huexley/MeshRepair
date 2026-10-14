#!/bin/sh
# Builds a self-contained installer: dist/MeshRepair-VERSION.pkg
# The app embeds its own Python (python-build-standalone via uv) and dependencies,
# so it needs nothing else on the target Mac. Apple Silicon, macOS 14+.
# Usage: packaging/build_pkg.sh [VERSION]
set -e
VERSION="${1:-1.1.0}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PY_VERSION=3.12
PY_REQUEST="cpython-$PY_VERSION-macos-aarch64-none"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/root/Mesh Repair.app"
ENGINE="$APP/Contents/Resources/engine"

echo "→ Building the app…"
mkdir -p "$WORK/root"
"$ROOT/app/MeshRepair/build.sh" "$APP" "" "" "$VERSION" >/dev/null 2>&1

echo "→ Embedding Python $PY_VERSION (arm64)…"
uv python install -q "$PY_REQUEST"
PY_HOME="$(uv python dir)/$PY_REQUEST"
# refuse to copy anything that is not a standalone Python install
if [ ! -x "$PY_HOME/bin/python3" ] || [ ! -d "$PY_HOME/lib/python$PY_VERSION" ]; then
  echo "Python $PY_VERSION (arm64) not found at $PY_HOME"; exit 1
fi
PY_HOME="$(cd "$PY_HOME/" && pwd -P)"
mkdir -p "$ENGINE/python"
cp -R "$PY_HOME/." "$ENGINE/python/"
PY="$ENGINE/python/bin/python3"
[ "$(file -b "$PY" | grep -c arm64)" = 1 ] || { echo "bundled Python is not arm64"; exit 1; }
rm -f "$ENGINE/python/lib/python$PY_VERSION/EXTERNALLY-MANAGED"
uv pip install -q --python "$PY" --link-mode copy -r "$ROOT/requirements.txt"
cp "$ROOT/meshrepair.py" "$ENGINE/"
cp "$ROOT/packaging/meshrepair-cli.sh" "$ENGINE/meshrepair"
chmod +x "$ENGINE/meshrepair"

echo "→ Trimming…"
LIB="$ENGINE/python/lib/python$PY_VERSION"
rm -rf "$ENGINE/python/include" "$ENGINE/python/share" "$ENGINE/python/lib/pkgconfig" \
       "$ENGINE/python/lib/"tcl* "$ENGINE/python/lib/"tk* "$ENGINE/python/lib/"itcl* "$ENGINE/python/lib/"thread* \
       "$LIB/test" "$LIB/idlelib" "$LIB/tkinter" "$LIB/turtledemo" "$LIB/ensurepip" \
       "$LIB/lib-dynload/_tkinter"* "$LIB/site-packages/pip"*
find "$LIB/site-packages" -type d -name tests -prune -exec rm -rf {} +
find "$ENGINE" -name __pycache__ -prune -exec rm -rf {} +
"$PY" -m compileall -q -j 0 "$LIB" "$ENGINE/meshrepair.py" >/dev/null || true

echo "→ Checking the bundled engine…"
# a real repair, with warnings as errors so a silent fallback also fails the build
env PYTHONNOUSERSITE=1 PYTHONDONTWRITEBYTECODE=1 "$PY" -W error -c "
import sys; sys.path.insert(0, '$ENGINE')
import numpy as np, trimesh, scipy.sparse, networkx, lxml
from meshrepair import repair_mesh
s = trimesh.creation.icosphere(3)
r = repair_mesh(trimesh.Trimesh(s.vertices, s.faces[10:]))
assert r.is_watertight
trimesh.geometry.index_sparse(3, np.array([[0, 1, 2]]))
" 2>&1 | grep -v '^$' && { echo "bundled engine is broken"; exit 1; } || true

echo "→ Signing (ad hoc)…"
find "$ENGINE" -type f \( -name '*.so' -o -name '*.dylib' \) -exec codesign --force -s - {} + 2>/dev/null
find "$ENGINE/python/bin" -type f -perm +111 -exec sh -c 'file -b "$1" | grep -q Mach-O && codesign --force -s - "$1"' _ {} \;
codesign --force -s - "$APP"
codesign --verify --strict "$APP"

echo "→ Building the installer…"
pkgbuild --analyze --root "$WORK/root" "$WORK/component.plist" >/dev/null
# always install into /Applications, even if another copy exists elsewhere
plutil -replace 0.BundleIsRelocatable -bool NO "$WORK/component.plist"
pkgbuild --root "$WORK/root" --component-plist "$WORK/component.plist" \
  --install-location /Applications --scripts "$ROOT/packaging/scripts" \
  --identifier io.github.huexley.meshrepair --version "$VERSION" "$WORK/MeshRepair.pkg" >/dev/null
sed "s/__VERSION__/$VERSION/g" "$ROOT/packaging/distribution.xml" > "$WORK/distribution.xml"
mkdir -p "$ROOT/dist"
productbuild --distribution "$WORK/distribution.xml" --package-path "$WORK" \
  --resources "$ROOT/packaging/resources" "$ROOT/dist/MeshRepair-$VERSION.pkg" >/dev/null
echo "✅ dist/MeshRepair-$VERSION.pkg ($(du -h "$ROOT/dist/MeshRepair-$VERSION.pkg" | cut -f1))"
