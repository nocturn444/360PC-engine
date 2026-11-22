// The props catalog: the prop types a game defines (docs/PROPS.md), read from the file that
// tools/props_catalog.lua writes (format "360pc-props-catalog", version 1). Everything the UI
// shows about a prop type comes from here, so a new type needs no editor change.
"use strict";

var Catalog = (function () {
  var SaveFmtRef = (typeof SaveFmt !== "undefined") ? SaveFmt
    : (typeof require === "function" ? require("./savefmt.js") : null);

  var FORMAT = "360pc-props-catalog";
  var RESIZE = { none: true, x: true, y: true, xy: true };
  var FIELD_TYPES = { number: true, integer: true, bool: true, string: true, enum: true };

  function arr(v) { return Array.isArray(v) ? v : []; }
  function whole(v, min) { return typeof v === "number" && Math.floor(v) === v && v >= min; }

  // { catalog } or { error } naming the bad field.
  function fromData(data) {
    if (!data || data.format !== FORMAT) return { error: "not a props catalog (format " + FORMAT + ")" };
    if (data.version !== 1) return { error: "catalog version " + data.version + ", this editor reads 1" };
    var types = arr(data.types);
    var out = { types: [], byId: {}, categories: [] };
    for (var i = 0; i < types.length; i++) {
      var t = types[i];
      var where = "types[" + (i + 1) + "]";
      if (!t || typeof t.id !== "string" || !/^[A-Za-z0-9_]+$/.test(t.id)) return { error: where + ".id is missing or bad" };
      where = "type " + t.id;
      if (out.byId[t.id]) return { error: "two types have the id " + t.id };
      if (!whole(t.w, 1) || !whole(t.h, 1)) return { error: where + ": w and h must be whole numbers >= 1" };
      var resize = t.resizable || "none";
      if (!RESIZE[resize]) return { error: where + ": resizable must be none, x, y or xy" };
      var fields = arr(t.fields);
      for (var f = 0; f < fields.length; f++) {
        var fd = fields[f];
        if (!fd || typeof fd.key !== "string") return { error: where + ": fields[" + (f + 1) + "].key is missing" };
        if (!FIELD_TYPES[fd.type]) return { error: where + ": field " + fd.key + " has a bad type" };
        if (fd.default === undefined) return { error: where + ": field " + fd.key + " has no default" };
        if (fd.type === "enum" && arr(fd.options).length === 0) return { error: where + ": enum field " + fd.key + " has no options" };
      }
      var color = arr(t.color);
      var type = {
        id: t.id,
        label: typeof t.label === "string" ? t.label : t.id,
        category: typeof t.category === "string" ? t.category : "prop",
        w: t.w, h: t.h, resizable: resize,
        min: { w: (t.min && t.min.w) || 1, h: (t.min && t.min.h) || 1 },
        max: { w: (t.max && t.max.w) || 999, h: (t.max && t.max.h) || 999 },
        color: color.length >= 3 ? [color[0], color[1], color[2]] : [0.6, 0.6, 0.6],
        glyph: typeof t.glyph === "string" && t.glyph !== "" ? t.glyph.slice(0, 2) : t.id.charAt(0).toUpperCase(),
        collision: t.collision || null,
        flags: arr(t.flags),
        fields: fields
      };
      out.types.push(type);
      out.byId[type.id] = type;
      if (out.categories.indexOf(type.category) < 0) out.categories.push(type.category);
    }
    return { catalog: out };
  }

  var C = {};

  C.parse = function (text) {
    var p = SaveFmtRef.parse(text);
    if (!p.ok) return { error: "catalog: " + p.error };
    return fromData(p.value);
  };

  C.empty = function () { return { types: [], byId: {}, categories: [] }; };

  // The size of a placement: its own w/h, else the type's default, else 1.
  C.size = function (catalog, prop) {
    var t = catalog && catalog.byId[prop.type];
    return {
      w: typeof prop.w === "number" ? prop.w : (t ? t.w : 1),
      h: typeof prop.h === "number" ? prop.h : (t ? t.h : 1)
    };
  };

  // A size clamped to what the type allows: only its resizable axes, within min/max.
  C.clampSize = function (catalog, typeId, w, h) {
    var t = catalog && catalog.byId[typeId];
    if (!t) return { w: Math.max(1, w), h: Math.max(1, h) };
    var cw = t.resizable === "x" || t.resizable === "xy" ? Math.min(t.max.w, Math.max(t.min.w, w)) : t.w;
    var ch = t.resizable === "y" || t.resizable === "xy" ? Math.min(t.max.h, Math.max(t.min.h, h)) : t.h;
    return { w: cw, h: ch };
  };

  // A new placement of a type at a tile, with w/h only when they differ from the default.
  C.newProp = function (catalog, typeId, tx, ty) {
    var t = catalog && catalog.byId[typeId];
    var p = { type: typeId, tx: tx, ty: ty, w: t ? t.w : 1, h: t ? t.h : 1, fields: {} };
    return p;
  };

  C.field = function (catalog, typeId, key) {
    var t = catalog && catalog.byId[typeId];
    if (!t) return null;
    for (var i = 0; i < t.fields.length; i++) if (t.fields[i].key === key) return t.fields[i];
    return null;
  };

  C.cssColor = function (rgb, alpha) {
    var r = Math.round(rgb[0] * 255), g = Math.round(rgb[1] * 255), b = Math.round(rgb[2] * 255);
    return alpha === undefined ? "rgb(" + r + "," + g + "," + b + ")" : "rgba(" + r + "," + g + "," + b + "," + alpha + ")";
  };

  return C;
})();

if (typeof module !== "undefined" && module.exports) module.exports = Catalog;
