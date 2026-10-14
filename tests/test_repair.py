"""Builds deliberately broken meshes, repairs them, and checks the results.
Run: .venv/bin/python tests/test_repair.py"""
import os
import shutil
import subprocess
import sys

import numpy as np
import trimesh

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
from meshrepair import repair_file, separate_touching  # noqa: E402

OUT = os.path.join(os.path.dirname(__file__), "out")
os.makedirs(OUT, exist_ok=True)


def make_inputs():
    # two cubes sharing an edge (non-manifold) + a duplicate face
    a = trimesh.creation.box((10, 10, 10))
    b = trimesh.creation.box((10, 10, 10))
    b.apply_translation((10, 10, 0))
    m = trimesh.util.concatenate([a, b])
    m.merge_vertices()
    trimesh.Trimesh(m.vertices, np.vstack([m.faces, m.faces[:1]]), process=False).export(f"{OUT}/nonmanifold.stl")
    # sphere with a hole and flipped faces
    s = trimesh.creation.icosphere(3, 20)
    f = s.faces[20:].copy()
    f[:50] = f[:50, ::-1]
    trimesh.Trimesh(s.vertices, f).export(f"{OUT}/holey.stl")
    # 3MF with two objects, one broken
    sc = trimesh.Scene()
    sc.add_geometry(trimesh.Trimesh(s.vertices, s.faces[5:]), "ball")
    sc.add_geometry(trimesh.creation.cylinder(5, 20), "cyl",
                    transform=trimesh.transformations.translation_matrix((40, 0, 0)))
    sc.export(f"{OUT}/multi.3mf")


def check(path, bodies):
    loaded = trimesh.load(path)
    meshes = list(loaded.geometry.values()) if isinstance(loaded, trimesh.Scene) else [loaded]
    total = sum(len(m.split(only_watertight=False)) for m in meshes)
    assert all(m.is_watertight and m.is_winding_consistent for m in meshes), f"{path} not watertight"
    assert total == bodies, f"{path}: expected {bodies} bodies, got {total}"
    print(f"PASS {os.path.basename(path)}")


if __name__ == "__main__":
    make_inputs()
    quiet = lambda *_: None  # noqa: E731
    check(repair_file(f"{OUT}/nonmanifold.stl", log=quiet)[0], 2)
    check(repair_file(f"{OUT}/holey.stl", log=quiet)[0], 1)
    check(repair_file(f"{OUT}/multi.3mf", log=quiet)[0], 2)

    # never overwrite the original, even with an empty suffix or a different case
    orig = open(f"{OUT}/holey.stl", "rb").read()
    try:
        repair_file(f"{OUT}/holey.stl", suffix="", log=quiet)
        raise AssertionError("original was overwritten")
    except ValueError:
        pass
    shutil.copy(f"{OUT}/holey.stl", f"{OUT}/UPPER.STL")
    try:
        repair_file(f"{OUT}/UPPER.STL", suffix="", log=quiet)
        raise AssertionError("UPPER.STL was overwritten")
    except ValueError:
        pass
    assert open(f"{OUT}/holey.stl", "rb").read() == orig
    print("PASS no overwrite")

    # -o into a folder that does not exist yet
    newdir = f"{OUT}/new/sub"
    shutil.rmtree(f"{OUT}/new", ignore_errors=True)
    check(repair_file(f"{OUT}/holey.stl", outdir=newdir, suffix="", log=quiet)[0], 1)

    # exit status: 0 all good, 1 a file failed
    cli = [sys.executable, os.path.join(os.path.dirname(__file__), "..", "meshrepair.py")]
    run = lambda *a: subprocess.run(cli + list(a), capture_output=True).returncode  # noqa: E731
    assert run(f"{OUT}/holey.stl") == 0
    assert run(f"{OUT}/holey.stl", f"{OUT}/missing.stl") == 1
    print("PASS exit status")

    # vectorized separate_touching nudges exactly the vertices shared between bodies
    a = trimesh.creation.box((10, 10, 10))
    b = trimesh.creation.box((10, 10, 10)).apply_translation((10, 10, 0))
    c = trimesh.creation.box((10, 10, 10)).apply_translation((50, 0, 0))
    before = [m.vertices.copy() for m in (a, b, c)]
    separate_touching([a, b, c])
    moved = [np.linalg.norm(m.vertices - v, axis=1) > 0 for m, v in zip((a, b, c), before)]
    assert moved[0].sum() == 2 and moved[1].sum() == 2 and moved[2].sum() == 0, moved
    print("PASS separate_touching")
