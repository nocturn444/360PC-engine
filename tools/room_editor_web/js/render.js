// Drawing a room on a 2D canvas: collision, doors, item, entities and props. Used by the
// editor (big, with a view transform) and the library (small cached thumbnails).
"use strict";

var Render = (function () {
  var COLORS = {
    bg: "#10131b", empty: "#1a1e2b", solid: "#9aa2b8", oneWay: "#5fb4e6", other: "#b98aff",
    grid: "rgba(255,255,255,0.06)", door: "#fae685", doorLocked: "#ff6b5b", item: "#7bd389",
    entity: "#ff7eb6", select: "#ffffff", unknown: "#777777"
  };

  // Draws the room so that tile (1,1) is at (ox, oy) and a tile is `scale` px.
  // opts: { scale, ox, oy, grid, selection, catalog, tileSize }
  function drawRoom(ctx, room, opts) {
    var s = opts.scale, ox = opts.ox || 0, oy = opts.oy || 0;
    var tw = room.tiles_w, th = room.tiles_h, col = room.collision;
    var ts = opts.tileSize || 16;
    ctx.fillStyle = COLORS.empty;
    ctx.fillRect(ox, oy, tw * s, th * s);
    for (var ty = 0; ty < th; ty++) {
      for (var tx = 0; tx < tw; tx++) {
        var v = col[ty * tw + tx];
        if (!v) continue;
        var x = ox + tx * s, y = oy + ty * s;
        if (v === 1) { ctx.fillStyle = COLORS.solid; ctx.fillRect(x, y, s, s); }
        else if (v === 2) { ctx.fillStyle = COLORS.oneWay; ctx.fillRect(x, y, s, Math.max(1, s * 0.3)); }
        else { ctx.fillStyle = COLORS.other; ctx.fillRect(x, y, s, s); }
      }
    }
    if (opts.grid && s >= 6) {
      ctx.strokeStyle = COLORS.grid;
      ctx.lineWidth = 1;
      ctx.beginPath();
      for (var gx = 0; gx <= tw; gx++) { ctx.moveTo(ox + gx * s + 0.5, oy); ctx.lineTo(ox + gx * s + 0.5, oy + th * s); }
      for (var gy = 0; gy <= th; gy++) { ctx.moveTo(ox, oy + gy * s + 0.5); ctx.lineTo(ox + tw * s, oy + gy * s + 0.5); }
      ctx.stroke();
    }
    var props = room.props || [];
    for (var i = 0; i < props.length; i++) drawProp(ctx, props[i], opts, props[i] === opts.selection);
    var ents = room.entities || [];
    for (var e = 0; e < ents.length; e++) {
      var en = ents[e];
      var ex = ox + (en.x / ts) * s, ey = oy + (en.y / ts) * s;
      var ew = Math.max(s, (en.w / ts) * s), eh = Math.max(s, (en.h / ts) * s);
      ctx.fillStyle = COLORS.entity;
      ctx.globalAlpha = 0.75;
      ctx.fillRect(ex, ey, ew, eh);
      ctx.globalAlpha = 1;
      if (s >= 12) label(ctx, (en.name || "?").charAt(0), ex + ew / 2, ey + eh / 2, s);
      if (en === opts.selection) outline(ctx, ex, ey, ew, eh);
    }
    if (room.item) {
      var ix = ox + (room.item.tx - 1) * s, iy = oy + (room.item.ty - 1) * s;
      ctx.fillStyle = COLORS.item;
      ctx.beginPath();
      ctx.arc(ix + s / 2, iy + s / 2, s * 0.4, 0, Math.PI * 2);
      ctx.fill();
      if (room.item === opts.selection) outline(ctx, ix, iy, s, s);
    }
    var exits = room.exits || [];
    for (var d = 0; d < exits.length; d++) {
      var ex2 = exits[d];
      var dx = ox + (ex2.tx - 1) * s, dy = oy + (ex2.ty - 1) * s;
      ctx.fillStyle = (ex2.requires && ex2.requires.length) ? COLORS.doorLocked : COLORS.door;
      ctx.fillRect(dx + s * 0.15, dy + s * 0.15, s * 0.7, s * 0.7);
      if (ex2 === opts.selection) outline(ctx, dx, dy, s, s);
    }
  }

  function drawProp(ctx, p, opts, selected) {
    var s = opts.scale, ox = opts.ox || 0, oy = opts.oy || 0;
    var cat = opts.catalog;
    var t = cat && cat.byId[p.type];
    var size = Catalog.size(cat, p);
    var x = ox + (p.tx - 1) * s, y = oy + (p.ty - 1) * s, w = size.w * s, h = size.h * s;
    ctx.fillStyle = t ? Catalog.cssColor(t.color, 0.85) : COLORS.unknown;
    ctx.fillRect(x, y, w, h);
    ctx.strokeStyle = "rgba(0,0,0,0.5)";
    ctx.lineWidth = 1;
    ctx.strokeRect(x + 0.5, y + 0.5, w - 1, h - 1);
    if (s >= 10) label(ctx, t ? t.glyph : "?", x + w / 2, y + h / 2, s);
    if (selected) outline(ctx, x, y, w, h);
  }

  function label(ctx, text, cx, cy, s) {
    ctx.fillStyle = "#000";
    ctx.font = "bold " + Math.floor(s * 0.7) + "px monospace";
    ctx.textAlign = "center";
    ctx.textBaseline = "middle";
    ctx.fillText(text, cx, cy);
  }

  function outline(ctx, x, y, w, h) {
    ctx.strokeStyle = COLORS.select;
    ctx.lineWidth = 2;
    ctx.setLineDash([4, 3]);
    ctx.strokeRect(x - 1, y - 1, w + 2, h + 2);
    ctx.setLineDash([]);
  }

  // Thumbnails, cached by room object and its version (App bumps it on every change).
  var cache = new WeakMap();
  function thumbnail(room, catalog, maxW, maxH, version) {
    var hit = cache.get(room);
    if (hit && hit.version === version && hit.maxW === maxW) return hit.canvas;
    var scale = Math.max(1, Math.floor(Math.min(maxW / room.tiles_w, maxH / room.tiles_h)));
    var c = document.createElement("canvas");
    c.width = room.tiles_w * scale;
    c.height = room.tiles_h * scale;
    drawRoom(c.getContext("2d"), room, { scale: scale, catalog: catalog, grid: false });
    cache.set(room, { canvas: c, version: version, maxW: maxW });
    return c;
  }

  return { COLORS: COLORS, drawRoom: drawRoom, drawProp: drawProp, thumbnail: thumbnail };
})();
