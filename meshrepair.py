#!/usr/bin/env python3
"""Mesh Repair: fix non-manifold edges, holes, flipped normals and degenerate
faces in STL / 3MF / OBJ / PLY files. Works like the "Fix model" repair in
Bambu Studio on Windows, and runs entirely offline.

Usage: meshrepair.py FILE [FILE ...] [-o OUTDIR] [--suffix _fixed]
Exit status: 0 all files watertight, 2 some issues remain, 1 a file failed.
"""
import argparse
import json
import os
import sys

import numpy as np
import pymeshfix
import trimesh

SUPPORTED = {".stl", ".3mf", ".obj", ".ply", ".off", ".glb"}


def edge_stats(mesh):
    """Return (non_manifold_edges, boundary_edges) counts."""
    if len(mesh.faces) == 0:
        return 0, 0
    _, counts = np.unique(mesh.edges_sorted, axis=0, return_counts=True)
    return int((counts > 2).sum()), int((counts == 1).sum())


def analyze(mesh):
    nm, bd = edge_stats(mesh)
    return {
        "faces": len(mesh.faces),
        "non_manifold_edges": nm,
        "open_edges": bd,
        "bodies": len(mesh.split(only_watertight=False)) if len(mesh.faces) else 0,
        "watertight": bool(mesh.is_watertight),
    }


def basic_clean(mesh):
    mesh.merge_vertices(digits_vertex=6)
    mesh.update_faces(mesh.nondegenerate_faces())
    mesh.update_faces(mesh.unique_faces())
    mesh.remove_unreferenced_vertices()
    return mesh


def repair_component(comp):
    nm, bd = edge_stats(comp)
    if nm == 0 and bd == 0 and comp.is_winding_consistent:
        trimesh.repair.fix_normals(comp)
        return comp
    fixer = pymeshfix.MeshFix(np.asarray(comp.vertices, dtype=float),
                              np.asarray(comp.faces, dtype=np.int32))
    fixer.repair(joincomp=False, remove_smallest_components=False)
    v, f = np.asarray(fixer.points), np.asarray(fixer.faces)
    if len(f) < 0.5 * len(comp.faces):
        # MeshFix threw away most of the part: fall back to a lighter repair
        trimesh.repair.fill_holes(comp)
        trimesh.repair.fix_normals(comp)
        return comp
    out = trimesh.Trimesh(v, f, process=True)
    trimesh.repair.fix_normals(out)
    return out


def repair_mesh(mesh, min_faces=4, progress=None):
    """`progress(fraction)` is called as bodies get repaired (by triangle count)."""
    mesh = basic_clean(mesh.copy())
    parts = [p for p in mesh.split(only_watertight=False) if len(p.faces) >= min_faces]
    total, done, fixed = sum(len(p.faces) for p in parts) or 1, 0, []
    for p in parts:
        fixed.append(repair_component(p))
        done += len(p.faces)
        if progress:
            progress(done / total)
    if not fixed:
        return mesh
    separate_touching(fixed)
    return trimesh.util.concatenate(fixed)


def separate_touching(parts, gap=1e-3):
    """Bodies that share a vertex/edge are non-manifold once re-merged on save.
    Nudge the shared vertices of each body inward by `gap` mm."""
    if len(parts) < 2:
        return
    # distinct positions of each body, and which of them belong to 2+ bodies
    rounded = [np.round(p.vertices, 6) for p in parts]
    uniq = [trimesh.grouping.unique_rows(r) for r in rounded]
    _, inv = trimesh.grouping.unique_rows(np.vstack([r[i] for r, (i, _) in zip(rounded, uniq)]))
    shared_rows = np.bincount(inv)[inv] > 1
    start = 0
    for p, (idx, vinv) in zip(parts, uniq):
        shared = shared_rows[start:start + len(idx)][vinv]
        start += len(idx)
        if shared.any():
            v = p.vertices.copy()
            v[shared] -= p.vertex_normals[shared] * gap
            p.vertices = v


def load(path):
    obj = trimesh.load(path, process=False)
    if isinstance(obj, trimesh.Trimesh):
        return {"mesh": obj}, None
    # Scene (3MF with several objects, GLB...): repair each geometry separately
    return dict(obj.geometry), obj


def repair_file(path, outdir=None, suffix="_fixed", log=print, progress=None):
    """Returns (out_path, ok, stats). `progress(fraction, message)` reports 0 → 1."""
    progress = progress or (lambda *_: None)
    base, ext = os.path.splitext(os.path.basename(path))
    ext = ext.lower()
    if ext not in SUPPORTED:
        raise ValueError(f"unsupported format {ext}")
    outdir = outdir or os.path.dirname(os.path.abspath(path))
    out_path = os.path.join(outdir, f"{base}{suffix}{ext}")
    if os.path.exists(out_path) and os.path.samefile(out_path, path):
        raise ValueError("output would overwrite the original; use --suffix or -o")
    progress(0.0, "Loading")
    geoms, scene = load(path)
    progress(0.1, "Repairing")
    before = {"faces": 0, "non_manifold_edges": 0, "open_edges": 0, "bodies": 0}
    after = dict(before)
    repaired = {}
    meshes = {n: g for n, g in geoms.items() if isinstance(g, trimesh.Trimesh)}
    total, done = sum(len(g.faces) for g in meshes.values()) or 1, 0
    for name, g in meshes.items():
        a = analyze(basic_clean(g.copy()))
        share = len(g.faces) / total
        r = repair_mesh(g, progress=lambda f, d=done, s=share: progress(0.1 + 0.8 * (d + f * s), "Repairing"))
        done += share
        b = analyze(r)
        for k in before:
            before[k] += a[k]
            after[k] += b[k]
        repaired[name] = r
    if not repaired:
        raise ValueError("no triangle mesh found in file")

    if scene is not None:
        for name, r in repaired.items():
            scene.geometry[name] = r
        result = scene
    else:
        result = repaired["mesh"]

    progress(0.9, "Saving")
    os.makedirs(outdir, exist_ok=True)
    result.export(out_path)
    progress(1.0, "Done")

    log(f"{os.path.basename(path)}  →  {os.path.basename(out_path)}")
    log(f"  non-manifold edges: {before['non_manifold_edges']} → {after['non_manifold_edges']}")
    log(f"  open (hole) edges:  {before['open_edges']} → {after['open_edges']}")
    log(f"  bodies:             {before['bodies']} → {after['bodies']}")
    log(f"  triangles:          {before['faces']} → {after['faces']}")
    ok = after["non_manifold_edges"] == 0 and after["open_edges"] == 0
    log("  ✅ watertight, ready to print" if ok else "  ⚠️  improved, but some issues remain")
    return out_path, ok, {"before": before, "after": after}


def emit(**event):
    print(json.dumps(event), flush=True)


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("-o", "--outdir")
    ap.add_argument("--suffix", default="_fixed")
    ap.add_argument("--progress", action="store_true",
                    help="print JSON events (progress, results) instead of a report")
    args = ap.parse_args()
    failures = incomplete = 0
    n = len(args.files)
    for i, f in enumerate(args.files):
        kw = {}
        if args.progress:
            kw["log"] = lambda *_: None
            kw["progress"] = lambda frac, msg, i=i, f=f: emit(
                event="progress", value=round((i + frac) / n, 4), file=f, stage=msg)
        try:
            out, ok, stats = repair_file(f, args.outdir, args.suffix, **kw)
            incomplete += not ok
            if args.progress:
                emit(event="result", file=f, output=out, ok=ok, **stats)
        except Exception as e:  # keep going with the other files
            failures += 1
            if args.progress:
                emit(event="error", file=f, message=str(e))
            else:
                print(f"{os.path.basename(f)}: ❌ {e}")
        if not args.progress:
            print()
    sys.exit(1 if failures else 2 if incomplete else 0)


if __name__ == "__main__":
    main()
