"""Brand-neutral vacuum map metadata.

Adapters that can render a map return ``(png_bytes, metadata)`` where
metadata follows this shape (all coordinates are floats):

    {
      "image": {"width": W, "height": H, "format": "png"},
      "coordinateSpace": "map",             # units used by zone/goTo commands
      "transform": {                        # affine, row-major 2x3
        "mapToImage": [[a, b, c], [d, e, f]],   # px = a*x + b*y + c ; py = d*x + e*y + f
        "imageToMap": [[...], [...]],
      },
      "calibrationPoints": [{"map": {x, y}, "image": {x, y}}, ...3],
      "rooms": [{"id", "name", "bbox": {"map": {x0,y0,x1,y1}, "image": {x0,y0,x1,y1}}}],
      "robot": {"map": {x, y, angle}, "image": {x, y}} | null,
      "dock":  {"map": {x, y}, "image": {x, y}} | null,
      "mapName": str | null,
    }

The transform is derived from three calibration point pairs (like Roborock's
own "calibration points"), so it stays correct under image scale, trim and
90°-multiple rotations without the app knowing the vendor's conventions.
"""
from __future__ import annotations

import struct
from typing import Any, Iterable

Affine = list[list[float]]


def affine_from_points(pairs: Iterable[tuple[tuple[float, float], tuple[float, float]]]) -> Affine:
    """Solve the 2x3 affine A with A·[x, y, 1] = [u, v] from 3 point pairs."""
    pts = list(pairs)
    if len(pts) != 3:
        raise ValueError("need exactly 3 calibration pairs")
    (x1, y1), (x2, y2), (x3, y3) = (p[0] for p in pts)
    det = x1 * (y2 - y3) - y1 * (x2 - x3) + (x2 * y3 - x3 * y2)
    if abs(det) < 1e-12:
        raise ValueError("calibration points are collinear")

    def solve(t1: float, t2: float, t3: float) -> list[float]:
        a = (t1 * (y2 - y3) - y1 * (t2 - t3) + (t2 * y3 - t3 * y2)) / det
        b = (x1 * (t2 - t3) - t1 * (x2 - x3) + (x2 * t3 - x3 * t2)) / det
        c = (x1 * (y2 * t3 - y3 * t2) - y1 * (x2 * t3 - x3 * t2) + t1 * (x2 * y3 - x3 * y2)) / det
        return [a, b, c]

    return [solve(*(p[1][0] for p in pts)), solve(*(p[1][1] for p in pts))]


def invert(m: Affine) -> Affine:
    (a, b, c), (d, e, f) = m
    det = a * e - b * d
    if abs(det) < 1e-12:
        raise ValueError("non-invertible transform")
    ia, ib, id_, ie = e / det, -b / det, -d / det, a / det
    return [[ia, ib, -(ia * c + ib * f)], [id_, ie, -(id_ * c + ie * f)]]


def apply(m: Affine, x: float, y: float) -> tuple[float, float]:
    return (m[0][0] * x + m[0][1] * y + m[0][2], m[1][0] * x + m[1][1] * y + m[1][2])


def png_size(png: bytes | None) -> tuple[int, int] | None:
    if png and png[:8] == b"\x89PNG\r\n\x1a\n" and len(png) >= 24:
        w, h = struct.unpack(">II", png[16:24])
        return int(w), int(h)
    return None


def _xy(m: Affine, x: float, y: float) -> dict[str, float]:
    u, v = apply(m, x, y)
    return {"x": round(u, 2), "y": round(v, 2)}


def _bbox(m: Affine, x0: float, y0: float, x1: float, y1: float) -> dict[str, float]:
    corners = [apply(m, x, y) for x, y in ((x0, y0), (x0, y1), (x1, y0), (x1, y1))]
    us, vs = [c[0] for c in corners], [c[1] for c in corners]
    return {"x0": round(min(us), 2), "y0": round(min(vs), 2), "x1": round(max(us), 2), "y1": round(max(vs), 2)}


def build_metadata(
    calibration: list[dict[str, Any]],
    rooms: list[dict[str, Any]],
    robot: dict[str, float] | None,
    dock: dict[str, float] | None,
    png: bytes | None,
    map_name: str | None = None,
) -> dict[str, Any]:
    """``calibration``: [{"map": {x, y}, "image": {x, y}}] x3 ;
    ``rooms``: [{"id", "name", "x0", "y0", "x1", "y1"}] in map coordinates."""
    pairs = [((c["map"]["x"], c["map"]["y"]), (c["image"]["x"], c["image"]["y"])) for c in calibration]
    m2i = affine_from_points(pairs)
    i2m = invert(m2i)
    size = png_size(png)
    out_rooms = []
    for r in rooms:
        box = {k: float(r[k]) for k in ("x0", "y0", "x1", "y1")}
        out_rooms.append({
            "id": str(r["id"]),
            "name": r.get("name"),
            "bbox": {"map": box, "image": _bbox(m2i, box["x0"], box["y0"], box["x1"], box["y1"])},
        })
    return {
        "image": {"width": size[0] if size else None, "height": size[1] if size else None, "format": "png"},
        "coordinateSpace": "map",
        "transform": {"mapToImage": m2i, "imageToMap": i2m},
        "calibrationPoints": calibration,
        "rooms": out_rooms,
        "robot": None if robot is None else {"map": robot, "image": _xy(m2i, robot["x"], robot["y"])},
        "dock": None if dock is None else {"map": dock, "image": _xy(m2i, dock["x"], dock["y"])},
        "mapName": map_name,
    }
