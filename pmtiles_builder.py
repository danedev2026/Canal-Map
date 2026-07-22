"""
Pure-Python GeoJSON -> PMTiles builder.

A cross-platform fallback for tippecanoe (which is Unix-only and won't build
on Windows). No external binary; keeps the pipeline £0 and self-contained.

Not as clever as tippecanoe (no fancy feature-dropping heuristics), but for a
clipped canal/river network + point features it produces a valid vector-tile
PMTiles archive MapLibre can render offline.

Deps: shapely, mapbox-vector-tile, pmtiles  (all pip-installable, pure-ish).
"""

import gzip
import json
import math

import mapbox_vector_tile
from shapely.geometry import shape, box
from shapely.ops import transform as shp_transform
from pmtiles.writer import Writer
from pmtiles.tile import (
    Compression,
    TileType,
    zxy_to_tileid,
)

TILE_EXTENT = 4096  # MVT local coordinate space per tile


# --- Web-Mercator tiling maths ----------------------------------------

def lon_lat_to_tile(lon, lat, z):
    """Fractional tile coordinates (x, y) at zoom z (Web Mercator / XYZ)."""
    n = 2 ** z
    x = (lon + 180.0) / 360.0 * n
    lat_rad = math.radians(lat)
    y = (1.0 - math.asinh(math.tan(lat_rad)) / math.pi) / 2.0 * n
    return x, y


def tile_bounds(z, x, y):
    """WGS84 (west, south, east, north) bounds of tile z/x/y."""
    n = 2 ** z

    def _lon(xt):
        return xt / n * 360.0 - 180.0

    def _lat(yt):
        return math.degrees(math.atan(math.sinh(math.pi * (1 - 2 * yt / n))))

    return _lon(x), _lat(y + 1), _lon(x + 1), _lat(y)


def covering_tiles(geom, z):
    """Yield (x, y) tiles at zoom z whose extent intersects geom's bbox."""
    minx, miny, maxx, maxy = geom.bounds
    x0, y0 = lon_lat_to_tile(minx, maxy, z)  # NW corner
    x1, y1 = lon_lat_to_tile(maxx, miny, z)  # SE corner
    n = 2 ** z
    for x in range(max(0, int(math.floor(x0))), min(n, int(math.floor(x1)) + 1)):
        for y in range(max(0, int(math.floor(y0))), min(n, int(math.floor(y1)) + 1)):
            yield x, y


# --- GeoJSON -> per-tile local coordinates ----------------------------

def _to_tile_local(geom, z, x, y):
    """Reproject a WGS84 geometry into this tile's 0..TILE_EXTENT space."""
    n = 2 ** z

    def _fn(lon, lat, zc=None):
        tx, ty = lon_lat_to_tile(lon, lat, z)
        px = (tx - x) * TILE_EXTENT
        py = (ty - y) * TILE_EXTENT
        return px, py

    return shp_transform(_fn, geom)


def _load_layer(path):
    with open(path, "r", encoding="utf-8") as fh:
        fc = json.load(fh)
    feats = []
    for f in fc.get("features", []):
        if not f.get("geometry"):
            continue
        feats.append((shape(f["geometry"]), f.get("properties", {}) or {}))
    return feats


# --- Build ------------------------------------------------------------

def build(layer_paths, out_path, minzoom=6, maxzoom=16):
    """Build a PMTiles archive from {layer_name: geojson_path}.

    Every feature is written at every zoom in [minzoom, maxzoom] (clipped to
    each tile with a small buffer). Fine for a compact clipped network; widen
    with care if you ever feed it very dense data.
    """
    layers = {name: _load_layer(path) for name, path in layer_paths.items()}
    total_feats = sum(len(v) for v in layers.values())
    print(f"  pmtiles: {total_feats} features across {len(layers)} layers, z{minzoom}-{maxzoom}")

    # Group features into tiles: tile_id -> {layer_name: [ (geom, props) ]}
    written = 0
    all_minx = all_miny = math.inf
    all_maxx = all_maxy = -math.inf

    writer_file = open(out_path, "wb")
    writer = Writer(writer_file)

    for z in range(minzoom, maxzoom + 1):
        # Simplify lines to ~1.5px at this zoom before tiling: fewer vertices →
        # smaller tiles and far less intersection work at low zoom. Points are
        # left untouched. This is what keeps a nationwide build tractable.
        tol = 360.0 / (2 ** z) / TILE_EXTENT * 1.5  # degrees ≈ 1.5px
        zlayers = {}
        for lname, feats in layers.items():
            simplified = []
            for geom, props in feats:
                g = geom
                if geom.geom_type in ("LineString", "MultiLineString"):
                    g = geom.simplify(tol, preserve_topology=False)
                    if g.is_empty:
                        continue
                simplified.append((g, props))
            zlayers[lname] = simplified

        tiles = {}  # (x, y) -> {layer: [features]}
        for lname, feats in zlayers.items():
            for geom, props in feats:
                for (tx, ty) in covering_tiles(geom, z):
                    clip = box(*tile_bounds(z, tx, ty)).buffer(0.0005)
                    if not geom.intersects(clip):
                        continue
                    piece = geom.intersection(clip)
                    if piece.is_empty:
                        continue
                    tiles.setdefault((tx, ty), {}).setdefault(lname, []).append((piece, props))
                    mnx, mny, mxx, mxy = geom.bounds
                    all_minx, all_miny = min(all_minx, mnx), min(all_miny, mny)
                    all_maxx, all_maxy = max(all_maxx, mxx), max(all_maxy, mxy)

        for (tx, ty), layer_feats in tiles.items():
            mvt_layers = []
            for lname, feats in layer_feats.items():
                mvt_feats = []
                for geom, props in feats:
                    local = _to_tile_local(geom, z, tx, ty)
                    if local.is_empty:
                        continue
                    mvt_feats.append({"geometry": local, "properties": props})
                if mvt_feats:
                    mvt_layers.append({"name": lname, "features": mvt_feats})
            if not mvt_layers:
                continue
            # Our _to_tile_local already puts y increasing downward (MVT spec
            # orientation), so tell the encoder not to flip. mtime=0 keeps the
            # gzip output reproducible.
            encoded = mapbox_vector_tile.encode(
                mvt_layers,
                default_options={"extents": TILE_EXTENT, "y_coord_down": True},
            )
            writer.write_tile(zxy_to_tileid(z, tx, ty), gzip.compress(encoded, mtime=0))
            written += 1

    if all_minx is math.inf:  # no data at all
        all_minx, all_miny, all_maxx, all_maxy = -0.6, 51.3, 0.1, 51.75

    header = {
        "tile_type": TileType.MVT,
        "tile_compression": Compression.GZIP,
        "min_zoom": minzoom,
        "max_zoom": maxzoom,
        "min_lon_e7": int(all_minx * 1e7),
        "min_lat_e7": int(all_miny * 1e7),
        "max_lon_e7": int(all_maxx * 1e7),
        "max_lat_e7": int(all_maxy * 1e7),
        "center_zoom": minzoom,
        "center_lon_e7": int((all_minx + all_maxx) / 2 * 1e7),
        "center_lat_e7": int((all_miny + all_maxy) / 2 * 1e7),
    }
    metadata = {
        "attribution": "© OpenStreetMap contributors (ODbL); Canal & River Trust",
        "vector_layers": [{"id": name, "minzoom": minzoom, "maxzoom": maxzoom}
                          for name in layer_paths],
    }
    writer.finalize(header, metadata)
    writer_file.close()
    print(f"  pmtiles: wrote {written} tiles -> {out_path}")
    return written
