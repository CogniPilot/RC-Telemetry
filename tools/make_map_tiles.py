#!/usr/bin/env python3
"""Build Yaapu map tiles for an area around a point.

Downloads satellite tiles from the Esri World Imagery service, resizes them
to the 100x100 pixel tiles the Yaapu widget draws, and writes them in the
widget's Google layout:

    <out>/GoogleSatelliteMap/<zoom>/<tile_y>/s_<tile_x>.jpg

On the radio select map provider "Google" and map type "GoogleSatelliteMap"
in Yaapu Config. The default zoom range 12 to 18 matches the widget defaults
(zoom 16, min 12, max 18).

Usage:
    make_map_tiles.py LAT LON RADIUS_KM [--out DIR] [--zooms 12-18]

Requires python3 with Pillow.
"""

import argparse
import concurrent.futures
import io
import math
import pathlib
import sys
import urllib.request

from PIL import Image

SOURCE = "https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}"
TILE_PX = 100
EARTH_M = 6378137.0


def tile_of(lat, lon, zoom):
    n = 2 ** zoom
    x = int((lon + 180.0) / 360.0 * n)
    lat_r = math.radians(lat)
    y = int((1.0 - math.log(math.tan(lat_r) + 1.0 / math.cos(lat_r)) / math.pi) / 2.0 * n)
    return x, y


def tiles_in_radius(lat, lon, radius_km, zoom):
    """Tile indices covering a square of the given radius around the point."""
    meters_per_tile = 2 * math.pi * EARTH_M * math.cos(math.radians(lat)) / (2 ** zoom)
    span = max(1, math.ceil(radius_km * 1000.0 / meters_per_tile))
    cx, cy = tile_of(lat, lon, zoom)
    n = 2 ** zoom
    for y in range(max(0, cy - span), min(n - 1, cy + span) + 1):
        for x in range(cx - span, cx + span + 1):
            yield x % n, y


def fetch(zoom, x, y, out):
    path = out / "GoogleSatelliteMap" / str(zoom) / str(y) / f"s_{x}.jpg"
    if path.exists():
        return "kept"
    req = urllib.request.Request(SOURCE.format(z=zoom, x=x, y=y),
                                 headers={"User-Agent": "yaapu-map-tiles/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        data = resp.read()
    image = Image.open(io.BytesIO(data)).convert("RGB")
    image = image.resize((TILE_PX, TILE_PX), Image.LANCZOS)
    path.parent.mkdir(parents=True, exist_ok=True)
    image.save(path, "JPEG", quality=85, optimize=True)
    return "new"


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("lat", type=float)
    parser.add_argument("lon", type=float)
    parser.add_argument("radius_km", type=float)
    parser.add_argument("--out", type=pathlib.Path,
                        default=pathlib.Path(__file__).resolve().parents[1]
                        / "OTX_ETX/color_common/SD/IMAGES/yaapu/maps")
    parser.add_argument("--zooms", default="12-18", help="inclusive range, default 12-18")
    parser.add_argument("--workers", type=int, default=8)
    args = parser.parse_args()

    lo, hi = (int(v) for v in args.zooms.split("-"))
    jobs = [(z, x, y) for z in range(lo, hi + 1)
            for x, y in tiles_in_radius(args.lat, args.lon, args.radius_km, z)]
    print(f"{len(jobs)} tiles for {args.lat}, {args.lon} radius {args.radius_km} km, "
          f"zoom {lo}-{hi}, into {args.out}")

    done = {"new": 0, "kept": 0, "failed": 0}
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.workers) as pool:
        futures = {pool.submit(fetch, z, x, y, args.out): (z, x, y) for z, x, y in jobs}
        for future in concurrent.futures.as_completed(futures):
            try:
                done[future.result()] += 1
            except Exception as exc:  # network or decode error on one tile
                done["failed"] += 1
                print(f"failed {futures[future]}: {exc}", file=sys.stderr)
    print(f"new {done['new']}, kept {done['kept']}, failed {done['failed']}")
    return 1 if done["failed"] else 0


if __name__ == "__main__":
    sys.exit(main())
