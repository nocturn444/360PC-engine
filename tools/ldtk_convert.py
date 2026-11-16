#!/usr/bin/env python3
# 360PC-Engine: LDtk project -> the engine's level file. Reference: docs/LEVELS.md.
#
# Runs on the development PC at build time, like the shader build: the console and LOVE only
# read the converted file (engine/level.lua). The output is the text that engine/save.lua's
# Save.serialize writes and Save.parse reads (plain data, never handed to load()), with keys
# sorted, so the same project always gives the same bytes.
#
#   python tools/ldtk_convert.py <project.ldtk> -o <levels.lvl> [--cell WxH] [--root GAME]
#       [--collision Collision] [--exit Exit] [--item Item]
#
# Python 3, standard library only, Windows and Linux.
import argparse
import json
import math
import os
import posixpath
import sys
from pathlib import Path

FORMAT = "360pc-level"
VERSION = 1

SIDES = ["left", "right", "up", "down"]
SIDE_ALIASES = {"left": "left", "right": "right", "up": "up", "down": "down", "top": "up", "bottom": "down",
                "l": "left", "r": "right", "u": "up", "d": "down", "west": "left", "east": "right",
                "north": "up", "south": "down"}
# IntGrid value identifiers (lower case) -> collision value
SOLID, ONE_WAY = 1, 2
KIND_ALIASES = {
    "solid": SOLID, "wall": SOLID, "walls": SOLID, "ground": SOLID, "block": SOLID,
    "one_way": ONE_WAY, "oneway": ONE_WAY, "one-way": ONE_WAY, "platform": ONE_WAY, "one_way_platform": ONE_WAY,
}


class ConvertError(Exception):
    """Something that stops the conversion; the message is for the user."""


# ---------------------------------------------------------------------------------------------
# The text format of engine/save.lua (Save.serialize): {v,v,["key"]=v,}
# ---------------------------------------------------------------------------------------------
_ESCAPES = {"\\": "\\\\", '"': '\\"', "\n": "\\n", "\r": "\\r", "\t": "\\t"}


def _string(s):
    out = []
    for ch in s:
        code = ord(ch)
        if ch in _ESCAPES:
            out.append(_ESCAPES[ch])
        elif code < 32 or code == 127:
            out.append("\\%03d" % code)
        else:
            out.append(ch)
    return '"' + "".join(out) + '"'


def _number(v):
    if isinstance(v, int):
        return "%d" % v
    if v != v:
        return "nan"
    if v == math.inf:
        return "inf"
    if v == -math.inf:
        return "-inf"
    if v == math.floor(v) and -1e15 < v < 1e15:
        return "%.0f" % v
    return "%.17g" % v


def serialize(value):
    """Python data (dict with string keys, list, str, int, float, bool) -> the text Save.parse reads.
    A None in a dict drops the key (a Lua table cannot hold nil); a None in a list becomes false."""
    out = []

    def write(v, in_list):
        if v is None:
            out.append("false" if in_list else "nil")
        elif v is True:
            out.append("true")
        elif v is False:
            out.append("false")
        elif isinstance(v, (int, float)):
            out.append(_number(v))
        elif isinstance(v, str):
            out.append(_string(v))
        elif isinstance(v, (list, tuple)):
            out.append("{")
            for item in v:
                write(item, True)
                out.append(",")
            out.append("}")
        elif isinstance(v, dict):
            out.append("{")
            # the order Save.serialize sorts string keys in: by their bytes
            for k in sorted((k for k in v if v[k] is not None), key=lambda k: k.encode("utf-8")):
                if not isinstance(k, str):
                    raise ConvertError("internal: a table key is not a string: %r" % (k,))
                out.append("[" + _string(k) + "]=")
                write(v[k], False)
                out.append(",")
            out.append("}")
        else:
            raise ConvertError("internal: cannot write a %s" % type(v).__name__)

    write(value, False)
    return "".join(out)


# ---------------------------------------------------------------------------------------------
# Reading the project
# ---------------------------------------------------------------------------------------------
def _read_json(path, what):
    try:
        with open(path, "r", encoding="utf-8") as f:
            return json.load(f)
    except OSError as e:
        raise ConvertError("%s: cannot read %s (%s)" % (what, path, e.strerror or e))
    except ValueError as e:
        raise ConvertError("%s: %s is not valid JSON (%s)" % (what, path, e))


def _same(a, b):
    return isinstance(a, str) and a.lower() == b.lower()


def _fields(instances):
    """fieldInstances -> (dict by identifier, dict of the identifiers in lower case)"""
    values, lower = {}, {}
    for fi in instances or []:
        name = fi.get("__identifier")
        if isinstance(name, str):
            values[name] = fi.get("__value")
            lower[name.lower()] = name
    return values, lower


def _take(values, lower, name):
    """Removes and returns the field `name` (any case), or None."""
    key = lower.get(name)
    if key is None:
        return None
    return values.pop(key)


def _levels(project, project_path):
    levels = list(project.get("levels") or [])
    for world in project.get("worlds") or []:
        levels += world.get("levels") or []
    out = []
    for level in levels:
        name = level.get("identifier")
        if not isinstance(name, str) or name == "":
            raise ConvertError("a level has no identifier")
        if level.get("layerInstances") is None:
            rel = level.get("externalRelPath")
            if not rel:
                raise ConvertError("level %s: no layers and no externalRelPath (was the project saved?)" % name)
            ext = _read_json(project_path.parent / rel, "level %s" % name)
            if ext.get("layerInstances") is None:
                raise ConvertError("level %s: %s has no layerInstances" % (name, rel))
            merged = dict(level)
            merged.update(ext)
            level = merged
        out.append(level)
    if not out:
        raise ConvertError("%s has no levels" % project_path.name)
    return out


def _parse_cell(text):
    try:
        w, h = text.lower().split("x")
        w, h = int(w), int(h)
    except ValueError:
        raise ConvertError("--cell is WxH in tiles, such as 20x12 (got %s)" % text)
    if w < 1 or h < 1:
        raise ConvertError("--cell needs sizes of at least 1 (got %s)" % text)
    return w, h


def _collision_values(project, layer_name, warn):
    """(tile size, {IntGrid value: 0 / 1 / 2}) from the layer definition, or (default grid size, None)"""
    for ld in (project.get("defs") or {}).get("layers") or []:
        if _same(ld.get("identifier"), layer_name):
            if ld.get("__type", ld.get("type")) != "IntGrid":
                raise ConvertError("layer %s is not an IntGrid layer" % ld.get("identifier"))
            table = {}
            for iv in ld.get("intGridValues") or []:
                value, ident = iv.get("value"), iv.get("identifier")
                if ident is None:
                    kind = {1: SOLID, 2: ONE_WAY}.get(value, 0)
                else:
                    kind = KIND_ALIASES.get(str(ident).lower(), 0)
                if kind == 0:
                    warn("layer %s: IntGrid value %s (%s) is neither solid nor one_way: exported as empty"
                         % (ld.get("identifier"), value, ident))
                table[value] = kind
            return int(ld.get("gridSize") or project.get("defaultGridSize") or 16), table
    warn("the project has no IntGrid layer named %s: every room is exported without collisions" % layer_name)
    return int(project.get("defaultGridSize") or 16), None


def _tileset_path(ts, project_path, root):
    rel = ts.get("relPath")
    if not rel:
        raise ConvertError("tileset %s has no image file (embedded atlases are not supported)" % ts.get("identifier"))
    full = Path(os.path.normpath(str(project_path.parent / rel.replace("\\", "/"))))
    try:
        out = full.relative_to(root).as_posix()
    except ValueError:
        raise ConvertError("tileset %s: %s is outside the game folder %s (see --root)"
                           % (ts.get("identifier"), full, root))
    if not out.lower().endswith(".png"):
        raise ConvertError("tileset %s: %s is not a .png file (the console loads PNG only)"
                           % (ts.get("identifier"), out))
    return posixpath.normpath(out)


def _entity_box(ent, layer):
    """(x, y, w, h) of an entity in level pixels, from its pivot position and size"""
    px = ent.get("px") or [0, 0]
    w, h = ent.get("width") or 0, ent.get("height") or 0
    pivot = ent.get("__pivot") or [0, 0]
    x = px[0] - pivot[0] * w + (layer.get("__pxTotalOffsetX") or 0)
    y = px[1] - pivot[1] * h + (layer.get("__pxTotalOffsetY") or 0)
    return _whole(x), _whole(y), w, h


def _whole(v):
    return int(v) if v == math.floor(v) else v


def _center_tile(box, tile, tiles_w, tiles_h):
    x, y, w, h = box
    tx = int(math.floor((x + w / 2) / tile)) + 1
    ty = int(math.floor((y + h / 2) / tile)) + 1
    return min(max(tx, 1), tiles_w), min(max(ty, 1), tiles_h)


def _tags(value, where):
    if value is None:
        return []
    if isinstance(value, str):
        return [value] if value != "" else []
    if isinstance(value, list) and all(isinstance(t, str) for t in value):
        return list(value)
    raise ConvertError("%s is an array of strings" % where)


def _exit(ent, layer, name, tile, tiles_w, tiles_h, cell):
    where = "level %s: exit at %s" % (name, ent.get("px"))
    box = _entity_box(ent, layer)
    x, y, w, h = box
    tx, ty = _center_tile(box, tile, tiles_w, tiles_h)
    values, lower = _fields(ent.get("fieldInstances"))
    side = _take(values, lower, "side")
    if side is not None:
        if not isinstance(side, str) or side.lower() not in SIDE_ALIASES:
            raise ConvertError("%s: side is left, right, up or down (got %s)" % (where, side))
        side = SIDE_ALIASES[side.lower()]
    else:
        on = []
        if x < tile:
            on.append("left")
        if x + w > (tiles_w - 1) * tile:
            on.append("right")
        if y < tile:
            on.append("up")
        if y + h > (tiles_h - 1) * tile:
            on.append("down")
        if not on:
            raise ConvertError("%s is not on a border of the level: move it, or give it a side field" % where)
        if len(on) > 1:
            raise ConvertError("%s touches the %s borders: give it a side field" % (where, " and ".join(on)))
        side = on[0]
    if side in ("left", "right"):
        offset = (ty - 1) // cell[1]
    else:
        offset = (tx - 1) // cell[0]
    out = {"side": side, "offset": offset, "tx": tx, "ty": ty,
           "requires": _tags(_take(values, lower, "requires"), where + ": requires")}
    if values:
        out["fields"] = values
    return out


def _room(level, project, opts, tile, kinds, cell, tileset_index, warn):
    name = level["identifier"]
    px_w, px_h = level.get("pxWid"), level.get("pxHei")
    if not isinstance(px_w, int) or not isinstance(px_h, int) or px_w <= 0 or px_h <= 0:
        raise ConvertError("level %s: bad size %sx%s" % (name, px_w, px_h))
    cell_w, cell_h = cell[0] * tile, cell[1] * tile
    if px_w % cell_w or px_h % cell_h:
        raise ConvertError("level %s: its size %dx%d px is not a multiple of the map cell, %dx%d px "
                           "(%dx%d tiles of %d px)" % (name, px_w, px_h, cell_w, cell_h, cell[0], cell[1], tile))
    tiles_w, tiles_h = px_w // tile, px_h // tile

    values, lower = _fields(level.get("fieldInstances"))
    rtype = _take(values, lower, "type")
    if rtype is None or rtype == "":
        rtype = "normal"
    if not isinstance(rtype, str):
        raise ConvertError("level %s: the type field is a String or an Enum" % name)
    weight = _take(values, lower, "weight")
    if weight is None:
        weight = 1
    if isinstance(weight, bool) or not isinstance(weight, int) or weight < 0:
        raise ConvertError("level %s: the weight field is an Int >= 0 (got %s)" % (name, weight))
    room = {
        "id": name, "w": px_w // cell_w, "h": px_h // cell_h, "tiles_w": tiles_w, "tiles_h": tiles_h,
        "type": rtype.lower(), "weight": weight,
        "tags": _tags(_take(values, lower, "tags"), "level %s: the tags field" % name),
        "fields": values, "exits": [], "entities": [], "layers": [],
    }

    collision = [0] * (tiles_w * tiles_h)
    # LDtk lists layers from the top one to the bottom one: go bottom to top
    for layer in reversed(level.get("layerInstances") or []):
        lname, ltype = layer.get("__identifier"), layer.get("__type")
        if _same(lname, opts.collision) and ltype == "IntGrid":
            if layer.get("__gridSize") != tile:
                raise ConvertError("level %s: layer %s has a grid of %s px, the project's is %d px"
                                   % (name, lname, layer.get("__gridSize"), tile))
            csv = layer.get("intGridCsv") or []
            if layer.get("__cWid") != tiles_w or layer.get("__cHei") != tiles_h or len(csv) != tiles_w * tiles_h:
                raise ConvertError("level %s: layer %s is %sx%s tiles with %d values, the level is %dx%d tiles"
                                   % (name, lname, layer.get("__cWid"), layer.get("__cHei"), len(csv),
                                      tiles_w, tiles_h))
            for i, v in enumerate(csv):
                if v:
                    if kinds is None or v not in kinds:
                        raise ConvertError("level %s: layer %s uses the IntGrid value %s, which the layer "
                                           "does not define" % (name, lname, v))
                    collision[i] = kinds[v]
        tiles = (layer.get("gridTiles") or []) + (layer.get("autoLayerTiles") or [])
        if tiles:
            uid = layer.get("overrideTilesetUid")
            if uid is None:
                uid = layer.get("__tilesetDefUid")
            if uid not in tileset_index:
                raise ConvertError("level %s: layer %s has tiles but no known tileset (uid %s)" % (name, lname, uid))
            ox, oy = layer.get("__pxTotalOffsetX") or 0, layer.get("__pxTotalOffsetY") or 0
            flat = []
            for t in tiles:
                try:
                    flat += [t["px"][0] + ox, t["px"][1] + oy, t["src"][0], t["src"][1], int(t.get("f") or 0) & 3]
                except (KeyError, IndexError, TypeError):
                    raise ConvertError("level %s: layer %s has a tile without px / src" % (name, lname))
            room["layers"].append({"name": lname, "tileset": uid, "tiles": flat})
        for ent in layer.get("entityInstances") or []:
            ename = ent.get("__identifier")
            if _same(ename, opts.exit):
                room["exits"].append(_exit(ent, layer, name, tile, tiles_w, tiles_h, cell))
                continue
            box = _entity_box(ent, layer)
            tx, ty = _center_tile(box, tile, tiles_w, tiles_h)
            fields, _ = _fields(ent.get("fieldInstances"))
            if _same(ename, opts.item):
                if "item" in room:
                    raise ConvertError("level %s: more than one %s entity (a room holds one ability item)"
                                       % (name, ename))
                room["item"] = {"tx": tx, "ty": ty}
                if fields:
                    room["item"]["fields"] = fields
                continue
            room["entities"].append({"name": ename, "iid": ent.get("iid"), "x": box[0], "y": box[1],
                                     "w": box[2], "h": box[3], "tx": tx, "ty": ty, "fields": fields})
    room["collision"] = collision

    # a stable order whatever the order they were placed in: by side, then along the side
    room["exits"].sort(key=lambda e: (SIDES.index(e["side"]), e["offset"]))
    seen = set()
    for e in room["exits"]:
        span = room["h"] if e["side"] in ("left", "right") else room["w"]
        if not 0 <= e["offset"] < span:
            raise ConvertError("level %s: internal: exit offset out of range" % name)
        key = (e["side"], e["offset"])
        if key in seen:
            raise ConvertError("level %s: two exits on the %s side of the same map cell (offset %d)"
                               % (name, e["side"], e["offset"]))
        seen.add(key)
    return room


def convert(project_path, opts, warn=None):
    """Returns the level data (a dict) for the .ldtk project at project_path."""
    warn = warn or (lambda text: None)
    project_path = Path(project_path)
    project = _read_json(project_path, "project")
    if not isinstance(project, dict) or "defs" not in project:
        raise ConvertError("%s does not look like an LDtk project (no defs)" % project_path)
    root = Path(os.path.normpath(str(Path(opts.root).absolute() if opts.root else project_path.parent.absolute())))
    project_path = Path(os.path.normpath(str(project_path.absolute())))
    levels = _levels(project, project_path)
    tile, kinds = _collision_values(project, opts.collision, warn)

    if opts.cell:
        cell = _parse_cell(opts.cell)
    else:
        min_w = min(l.get("pxWid") or 0 for l in levels)
        min_h = min(l.get("pxHei") or 0 for l in levels)
        if min_w < tile or min_h < tile or min_w % tile or min_h % tile:
            raise ConvertError("the smallest level is %dx%d px, not a whole number of %d px tiles: "
                               "fix the level sizes or pass --cell WxH" % (min_w, min_h, tile))
        cell = (min_w // tile, min_h // tile)

    tileset_defs = {ts.get("uid"): ts for ts in (project.get("defs") or {}).get("tilesets") or []}
    rooms = [_room(level, project, opts, tile, kinds, cell, tileset_defs, warn) for level in levels]
    ids = set()
    for room in rooms:
        if room["id"] in ids:
            raise ConvertError("two levels are named %s" % room["id"])
        ids.add(room["id"])

    # only the tilesets some layer draws with, in the project's order; layers point at them from 1
    used = {layer["tileset"] for room in rooms for layer in room["layers"]}
    tilesets, index = [], {}
    for ts in (project.get("defs") or {}).get("tilesets") or []:
        if ts.get("uid") in used:
            tilesets.append({"path": _tileset_path(ts, project_path, root), "tile_size": ts.get("tileGridSize"),
                             "w": ts.get("pxWid"), "h": ts.get("pxHei")})
            index[ts.get("uid")] = len(tilesets)
    for room in rooms:
        for layer in room["layers"]:
            layer["tileset"] = index[layer["tileset"]]

    return {"format": FORMAT, "version": VERSION, "ldtk_version": str(project.get("jsonVersion") or ""),
            "tile_size": tile, "cell": {"w": cell[0], "h": cell[1]}, "tilesets": tilesets, "rooms": rooms}


def main(argv=None):
    ap = argparse.ArgumentParser(description="Convert an LDtk project into the 360PC-Engine level file.")
    ap.add_argument("project", help="the .ldtk project file")
    ap.add_argument("-o", "--output", help="the level file to write (default: the project's name with .lvl)")
    ap.add_argument("--cell", help="size of a map cell in tiles, WxH (default: the smallest level of the project)")
    ap.add_argument("--root", help="the game folder: tileset paths are written relative to it "
                                   "(default: the project's folder)")
    ap.add_argument("--collision", default="Collision", help="IntGrid layer with the collisions (default Collision)")
    ap.add_argument("--exit", default="Exit", help="entity that marks a room exit (default Exit)")
    ap.add_argument("--item", default="Item", help="entity that marks the ability item place (default Item)")
    ap.add_argument("-q", "--quiet", action="store_true", help="print nothing but errors")
    opts = ap.parse_args(argv)

    def warn(text):
        print("warning: " + text, file=sys.stderr)

    try:
        data = convert(opts.project, opts, warn)
        text = serialize(data)
        out = Path(opts.output) if opts.output else Path(opts.project).with_suffix(".lvl")
        try:
            out.parent.mkdir(parents=True, exist_ok=True)
            with open(out, "wb") as f:
                f.write(text.encode("utf-8"))
        except OSError as e:
            raise ConvertError("cannot write %s (%s)" % (out, e.strerror or e))
    except ConvertError as e:
        print("ldtk_convert: " + str(e), file=sys.stderr)
        return 1
    if not opts.quiet:
        print("%s: %d rooms, %d tilesets, cell %dx%d tiles of %d px, %d bytes"
              % (out, len(data["rooms"]), len(data["tilesets"]), data["cell"]["w"], data["cell"]["h"],
                 data["tile_size"], len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
