# Mesh Repair for macOS

Fix broken 3D-printing models on a Mac: **non-manifold edges, holes, flipped normals,
duplicate/degenerate triangles and self-intersections** in STL, 3MF, OBJ and PLY files.

It does the same job as the *Fix model* repair in Bambu Studio on Windows (which relies on a
Windows-only service) or online repair sites, but it runs **entirely offline**, so your files never get uploaded.

## Install

### Installer (easiest)

Download `MeshRepair-<version>.pkg` from the [latest release](https://github.com/huexley/MeshRepair/releases/latest)
and open it. It installs *Mesh Repair.app* in Applications and the `meshrepair` command in
`/usr/local/bin`. Everything it needs, Python included, is inside the app. Requires a Mac with
Apple Silicon and macOS 14 or later.

The installer is not signed with an Apple Developer ID, so macOS blocks it the first time:
open **System Settings → Privacy & Security**, scroll down and click **Open Anyway** next to the
message about *MeshRepair….pkg*. Alternatively, run
`xattr -d com.apple.quarantine ~/Downloads/MeshRepair-*.pkg` before opening it.

To uninstall: delete *Mesh Repair.app* and `/usr/local/bin/meshrepair`.

### From source

Requirements: macOS 14+, Python 3.10+ (or [uv](https://docs.astral.sh/uv/)), and Xcode or the
Command Line Tools (`xcode-select --install`) to build the native app. Without them,
`install.sh` builds a simpler AppleScript droplet instead.

```sh
git clone https://github.com/huexley/MeshRepair.git
cd MeshRepair
./install.sh
```

This creates `~/Applications/Mesh Repair.app` and a `meshrepair` command in `~/.local/bin`.
Keep the cloned folder where it is, because the app runs the code from there.

## Usage

**App:** drag one or more model files onto the *Mesh Repair* window, its app icon or its Dock
icon, or click *Choose Files…*. A progress ring shows how far the repair has got (the
percentage also appears on the Dock icon). A repaired copy, `name_fixed.stl` (or `.3mf`…), is
saved next to each original. Then a report lists what was fixed in each file, with a
*Show in Finder* button.

**Terminal:** prints the same report:

```
part.stl  →  part_fixed.stl
  non-manifold edges: 37 → 0
  open (hole) edges:  12 → 0
  bodies:             3 → 3
  triangles:          18234 → 18260
  ✅ watertight, ready to print
```

```sh
meshrepair model.stl other.3mf            # writes model_fixed.stl, other_fixed.3mf
meshrepair *.stl -o repaired/ --suffix ""  # into another folder, same names
```

The original files are never modified: a run that would overwrite one (for example
`--suffix ""` without `-o`) is refused. The `-o` folder is created if needed.

`--progress` prints JSON events (progress, per-file results) instead of the report; the app uses it.

Exit status: `0` every file is watertight, `2` some issues remain, `1` a file could not be repaired.

## How it works

1. Merges duplicate vertices and removes degenerate and duplicate triangles.
2. Splits the model into separate bodies, so multi-part models stay separate.
3. Repairs each broken body with [MeshFix](https://github.com/pyvista/pymeshfix): it resolves
   non-manifold edges and self-intersections and fills holes.
4. Makes all normals point outward.
5. Bodies that touch along an edge or at a corner get their shared points moved 0.001 mm apart.
   Otherwise they would turn non-manifold again when a slicer merges them.

In a 3MF with several objects, each object is repaired separately.

## Limitations

- In repaired 3MF files the object names are not preserved.
- If MeshFix would throw away most of a heavily damaged body, a lighter repair is used instead
  (fill holes + fix normals). The report then says "⚠️ improved, but some issues remain".

## Building the installer

```sh
packaging/build_pkg.sh 1.1.0   # → dist/MeshRepair-1.1.0.pkg
```

Needs [uv](https://docs.astral.sh/uv/) (it downloads a standalone arm64 Python to embed) and Xcode.

## Tests

```sh
.venv/bin/python tests/test_repair.py
```

## License

GPL-3.0, the same license as MeshFix / pymeshfix, which this tool uses.
