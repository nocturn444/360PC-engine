// The editor screen: one room on a canvas, painting and placing tools, touch gestures
// (one finger edits, two fingers pan and zoom), prev/next through the library filter,
// variants, and sheets for the selection and the room.
// EditorMath holds the pure helpers and is exported for Node tests.
"use strict";

var EditorMath = {
  // The tile (from 1) under a canvas point for a view { scale, ox, oy }.
  tileAt: function (view, x, y) {
    return { tx: Math.floor((x - view.ox) / view.scale) + 1, ty: Math.floor((y - view.oy) / view.scale) + 1 };
  },
  // Every tile on the line from a to b (Bresenham), both ends included.
  line: function (a, b) {
    var out = [], x = a.tx, y = a.ty;
    var dx = Math.abs(b.tx - x), dy = -Math.abs(b.ty - y);
    var sx = x < b.tx ? 1 : -1, sy = y < b.ty ? 1 : -1, err = dx + dy;
    for (;;) {
      out.push({ tx: x, ty: y });
      if (x === b.tx && y === b.ty) break;
      var e2 = 2 * err;
      if (e2 >= dy) { err += dy; x += sx; }
      if (e2 <= dx) { err += dx; y += sy; }
    }
    return out;
  },
  rect: function (a, b) {
    return { x1: Math.min(a.tx, b.tx), y1: Math.min(a.ty, b.ty), x2: Math.max(a.tx, b.tx), y2: Math.max(a.ty, b.ty) };
  },
  // What Select picks at a tile: a prop (last placed first), an entity, a door, the item.
  pick: function (room, catalog, tileSize, tx, ty) {
    var props = room.props || [];
    for (var i = props.length - 1; i >= 0; i--) {
      var p = props[i];
      var s = Catalog.size(catalog, p);
      if (tx >= p.tx && ty >= p.ty && tx < p.tx + s.w && ty < p.ty + s.h) return { kind: "prop", obj: p };
    }
    var px = (tx - 0.5) * tileSize, py = (ty - 0.5) * tileSize;
    var ent = RoomModel.entityAt(room, px, py);
    if (ent) return { kind: "entity", obj: ent };
    var door = RoomModel.exitAt(room, tx, ty);
    if (door) return { kind: "door", obj: door };
    if (room.item && room.item.tx === tx && room.item.ty === ty) return { kind: "item", obj: room.item };
    return null;
  },
  // A view that fits a room of tw x th tiles in a w x h canvas.
  fit: function (tw, th, w, h) {
    var scale = Math.max(2, Math.min(w / tw, h / th) * 0.94);
    return { scale: scale, ox: (w - tw * scale) / 2, oy: (h - th * scale) / 2 };
  },
  // Zoom around a point: the world point under (x, y) stays there.
  zoomAt: function (view, x, y, factor) {
    var scale = Math.max(2, Math.min(120, view.scale * factor));
    var k = scale / view.scale;
    return { scale: scale, ox: x - (x - view.ox) * k, oy: y - (y - view.oy) * k };
  }
};

if (typeof module !== "undefined" && module.exports) {
  module.exports = EditorMath;
} else (function () {
  var TOOLS = [
    { id: "solid", label: "Solid" }, { id: "oneway", label: "Way" }, { id: "erase", label: "Erase" },
    { id: "door", label: "Door" }, { id: "item", label: "Item" }, { id: "entity", label: "Ent" },
    { id: "prop", label: "Prop" }, { id: "select", label: "Sel" }
  ];
  var PAINT = { solid: RoomModel.SOLID, oneway: RoomModel.ONE_WAY, erase: RoomModel.EMPTY };
  var MODES = ["free", "rect", "fill"];

  var root, canvas, ctx, idBtn, badge, toolBtns = {}, modeBtn, currentBtn, editBtn, delBtn;
  var view = { scale: 16, ox: 0, oy: 0 };
  var tool = "solid", mode = "free", selection = null;
  var entityName = null, propType = null, recent = [];
  var pointers = new Map(), action = null, pinch = null, cursor = null, lastTwoTap = 0;
  var dirty = true, needFit = true, cw = 0, ch = 0;

  function level() { return App.state.level; }
  function room() { return App.room(); }
  function tileSize() { return level().tile_size; }

  function redraw() {
    if (dirty) return;
    dirty = true;
    requestAnimationFrame(draw);
  }

  function resize() {
    var r = canvas.parentNode.getBoundingClientRect();
    var dpr = window.devicePixelRatio || 1;
    cw = r.width; ch = r.height;
    canvas.width = Math.round(cw * dpr);
    canvas.height = Math.round(ch * dpr);
    canvas.style.width = cw + "px";
    canvas.style.height = ch + "px";
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    if (needFit) fitView();
    dirty = false;
    redraw();
  }

  function fitView() {
    var rm = room();
    if (!rm || !cw) return;
    view = EditorMath.fit(rm.tiles_w, rm.tiles_h, cw, ch);
    needFit = false;
  }

  function draw() {
    dirty = false;
    var rm = room();
    ctx.fillStyle = Render.COLORS.bg;
    ctx.fillRect(0, 0, cw, ch);
    if (!rm) return;
    Render.drawRoom(ctx, rm, {
      scale: view.scale, ox: view.ox, oy: view.oy, grid: App.settings.grid,
      selection: selection && selection.obj, catalog: App.state.catalog, tileSize: tileSize()
    });
    if (selection && selection.kind === "prop" && resizable(selection.obj)) {
      var h = handleRect(selection.obj);
      ctx.fillStyle = "#fff";
      ctx.fillRect(h.x, h.y, h.w, h.h);
    }
    if (action && action.kind === "rect" && action.cur) {
      var r = EditorMath.rect(action.start, action.cur);
      ctx.strokeStyle = "#f2c14e";
      ctx.lineWidth = 2;
      ctx.strokeRect(view.ox + (r.x1 - 1) * view.scale, view.oy + (r.y1 - 1) * view.scale,
        (r.x2 - r.x1 + 1) * view.scale, (r.y2 - r.y1 + 1) * view.scale);
    }
    if (cursor) drawCursor();
  }

  // The tile under the finger, and a magnified copy above the finger.
  function drawCursor() {
    var t = cursor.tile, s = view.scale;
    var x = view.ox + (t.tx - 1) * s, y = view.oy + (t.ty - 1) * s;
    ctx.strokeStyle = "#fff";
    ctx.lineWidth = 2;
    ctx.strokeRect(x, y, s, s);
    var dpr = window.devicePixelRatio || 1;
    var size = 84, half = 2.5 * s;
    var cx = x + s / 2, cy = y + s / 2;
    var dx = Math.min(cw - size - 4, Math.max(4, cursor.x - size / 2));
    var dy = Math.max(4, cursor.y - 70 - size);
    ctx.save();
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.drawImage(canvas, (cx - half) * dpr, (cy - half) * dpr, half * 2 * dpr, half * 2 * dpr,
      dx * dpr, dy * dpr, size * dpr, size * dpr);
    ctx.restore();
    ctx.strokeStyle = "#f2c14e";
    ctx.strokeRect(dx, dy, size, size);
    ctx.strokeStyle = "#fff";
    ctx.strokeRect(dx + size / 2 - size / 10, dy + size / 2 - size / 10, size / 5, size / 5);
  }

  function resizable(p) {
    var t = App.state.catalog.byId[p.type];
    return t && t.resizable !== "none";
  }

  function handleRect(p) {
    var s = Catalog.size(App.state.catalog, p);
    var hs = Math.max(14, view.scale * 0.5);
    return { x: view.ox + (p.tx - 1 + s.w) * view.scale - hs / 2, y: view.oy + (p.ty - 1 + s.h) * view.scale - hs / 2, w: hs, h: hs };
  }

  function inHandle(p, x, y) {
    var h = handleRect(p), pad = 12;
    return x >= h.x - pad && y >= h.y - pad && x <= h.x + h.w + pad && y <= h.y + h.h + pad;
  }

  // --- editing helpers ---------------------------------------------------------------------

  function begin() { App.before(App.state.roomIndex); }
  function done() { App.changed(room()); updateBadge(); redraw(); }

  // Drops the last history step without keeping it for redo (a cancelled gesture).
  function revert() {
    App.state.history.undoStep(level());
    App.state.history.redo.pop();
    App.changed(room());
    redraw();
  }

  function inside(t) { var rm = room(); return t.tx >= 1 && t.ty >= 1 && t.tx <= rm.tiles_w && t.ty <= rm.tiles_h; }

  function point(e) {
    var r = canvas.getBoundingClientRect();
    return { x: e.clientX - r.left, y: e.clientY - r.top };
  }

  function startAction(p) {
    var t = EditorMath.tileAt(view, p.x, p.y);
    var rm = room();
    action = { start: t, last: t, cur: t, x0: p.x, y0: p.y, moved: false, changed: false };
    if (PAINT[tool] !== undefined) {
      if (mode === "free") {
        action.kind = "paint";
        if (inside(t)) { begin(); action.changed = true; RoomModel.set(rm, t.tx, t.ty, PAINT[tool]); App.changed(rm); }
      } else action.kind = mode;
    } else if (tool === "select") {
      if (selection && selection.kind === "prop" && resizable(selection.obj) && inHandle(selection.obj, p.x, p.y)) {
        action.kind = "resize";
        action.orig = Catalog.size(App.state.catalog, selection.obj);
      } else {
        var hit = inside(t) ? EditorMath.pick(rm, App.state.catalog, tileSize(), t.tx, t.ty) : null;
        selection = hit;
        updateSelectionButtons();
        action.kind = hit ? "drag" : "none";
        if (hit) action.orig = { tx: hit.obj.tx, ty: hit.obj.ty };
      }
    } else action.kind = "tap";
    cursor = { tile: t, x: p.x, y: p.y };
    redraw();
  }

  function moveAction(p) {
    if (!action) return;
    var t = EditorMath.tileAt(view, p.x, p.y);
    if (Math.abs(p.x - action.x0) + Math.abs(p.y - action.y0) > 8) action.moved = true;
    cursor = { tile: t, x: p.x, y: p.y };
    var rm = room();
    if (action.kind === "paint" && (t.tx !== action.last.tx || t.ty !== action.last.ty)) {
      EditorMath.line(action.last, t).forEach(function (q) {
        if (!inside(q)) return;
        if (!action.changed) { begin(); action.changed = true; }
        RoomModel.set(rm, q.tx, q.ty, PAINT[tool]);
      });
      App.changed(rm);
    } else if (action.kind === "drag" && selection) {
      var dx = t.tx - action.start.tx, dy = t.ty - action.start.ty;
      var nx = action.orig.tx + dx, ny = action.orig.ty + dy;
      if (nx !== selection.obj.tx || ny !== selection.obj.ty) {
        if (!action.changed) { begin(); action.changed = true; }
        moveSelection(nx, ny);
        App.changed(rm);
      }
    } else if (action.kind === "resize" && selection) {
      var p0 = selection.obj;
      var want = Catalog.clampSize(App.state.catalog, p0.type, t.tx - p0.tx + 1, t.ty - p0.ty + 1);
      var cur = Catalog.size(App.state.catalog, p0);
      if (want.w !== cur.w || want.h !== cur.h) {
        if (!action.changed) { begin(); action.changed = true; }
        RoomModel.resizeProp(rm, p0, want.w, want.h);
        App.changed(rm);
      }
    }
    action.last = t;
    action.cur = t;
    redraw();
  }

  function moveSelection(tx, ty) {
    var rm = room(), s = selection;
    tx = Math.max(1, Math.min(rm.tiles_w, tx));
    ty = Math.max(1, Math.min(rm.tiles_h, ty));
    if (s.kind === "prop") RoomModel.moveProp(rm, s.obj, tx, ty);
    else if (s.kind === "entity") RoomModel.moveEntity(level(), rm, s.obj, tx, ty);
    else if (s.kind === "item") { s.obj.tx = tx; s.obj.ty = ty; }
    else if (s.kind === "door") {
      // a door moves along the border only: re-create it at the new tile
      var side = RoomModel.exitSide(level(), rm, tx, ty, s.obj.side === "up" || s.obj.side === "down");
      if (!side) return;
      var req = s.obj.requires;
      rm.exits.splice(rm.exits.indexOf(s.obj), 1);
      RoomModel.toggleExit(level(), rm, tx, ty, side === "up" || side === "down");
      var nd = RoomModel.exitAt(rm, tx, ty);
      if (nd) { RoomModel.setRequires(nd, req); selection = { kind: "door", obj: nd }; }
    }
  }

  function endAction() {
    if (!action) return;
    var a = action, rm = room(), t = a.cur;
    action = null;
    cursor = null;
    if (a.kind === "paint") { if (a.changed) done(); }
    else if (a.kind === "rect") {
      var r = EditorMath.rect(a.start, t);
      r.x1 = Math.max(1, r.x1); r.y1 = Math.max(1, r.y1);
      r.x2 = Math.min(rm.tiles_w, r.x2); r.y2 = Math.min(rm.tiles_h, r.y2);
      if (r.x1 <= r.x2 && r.y1 <= r.y2) { begin(); RoomModel.fillRect(rm, r.x1, r.y1, r.x2, r.y2, PAINT[tool]); done(); }
    } else if (a.kind === "fill") {
      if (!a.moved && inside(t)) { begin(); RoomModel.flood(rm, t.tx, t.ty, PAINT[tool]); done(); }
    } else if (a.kind === "drag" || a.kind === "resize") {
      if (a.changed) done();
    } else if (a.kind === "tap" && !a.moved && inside(t)) {
      place(t);
    }
    redraw();
  }

  function place(t) {
    var rm = room();
    if (tool === "door") {
      var existing = RoomModel.exitAt(rm, t.tx, t.ty);
      begin();
      var r = RoomModel.toggleExit(level(), rm, t.tx, t.ty, t.ty === 1 || t.ty === rm.tiles_h);
      if (!r) { revert(); App.toast("Doors go on the border"); return; }
      // a new door opens its tile, so it is never inside a wall
      if (!existing && RoomModel.get(rm, t.tx, t.ty) === RoomModel.SOLID) RoomModel.set(rm, t.tx, t.ty, RoomModel.EMPTY);
      selection = existing ? null : { kind: "door", obj: RoomModel.exitAt(rm, t.tx, t.ty) };
      done();
    } else if (tool === "item") {
      begin(); RoomModel.toggleItem(rm, t.tx, t.ty); done();
    } else if (tool === "entity") {
      var name = entityName || App.settings.entities[0] || "Entity";
      begin();
      var ent = RoomModel.addEntity(level(), rm, name, t.tx, t.ty);
      selection = { kind: "entity", obj: ent };
      done();
    } else if (tool === "prop") {
      if (!propType || !App.state.catalog.byId[propType]) { palette(); return; }
      begin();
      var p = RoomModel.addProp(rm, Catalog.newProp(App.state.catalog, propType, t.tx, t.ty));
      selection = { kind: "prop", obj: p };
      done();
    }
    updateSelectionButtons();
  }

  // --- pointer events: one finger edits, two fingers pan and zoom -------------------------

  function onDown(e) {
    canvas.setPointerCapture(e.pointerId);
    pointers.set(e.pointerId, point(e));
    if (pointers.size === 1) startAction(point(e));
    else if (pointers.size === 2) {
      if (action) { if (action.changed) revert(); action = null; cursor = null; }
      var pts = Array.from(pointers.values());
      pinch = { d: dist(pts[0], pts[1]), c: mid(pts[0], pts[1]), t: Date.now(), moved: false };
    }
  }

  function onMove(e) {
    if (!pointers.has(e.pointerId)) return;
    pointers.set(e.pointerId, point(e));
    if (pinch && pointers.size >= 2) {
      var pts = Array.from(pointers.values());
      var d = dist(pts[0], pts[1]), c = mid(pts[0], pts[1]);
      if (Math.abs(d - pinch.d) > 4 || Math.abs(c.x - pinch.c.x) + Math.abs(c.y - pinch.c.y) > 4) pinch.moved = true;
      view = EditorMath.zoomAt(view, c.x, c.y, d / pinch.d);
      view.ox += c.x - pinch.c.x;
      view.oy += c.y - pinch.c.y;
      pinch.d = d; pinch.c = c;
      redraw();
    } else if (!pinch) moveAction(point(e));
  }

  function onUp(e) {
    if (!pointers.has(e.pointerId)) return;
    pointers.delete(e.pointerId);
    if (pinch) {
      if (pointers.size === 0) {
        // a quick two-finger tap that did not move fits the room
        if (!pinch.moved && Date.now() - pinch.t < 300) {
          if (Date.now() - lastTwoTap < 500) { needFit = true; fitView(); redraw(); }
          lastTwoTap = Date.now();
        }
        pinch = null;
      }
      return;
    }
    if (e.type === "pointercancel") { if (action && action.changed) revert(); action = null; cursor = null; redraw(); return; }
    endAction();
  }

  function dist(a, b) { return Math.hypot(a.x - b.x, a.y - b.y); }
  function mid(a, b) { return { x: (a.x + b.x) / 2, y: (a.y + b.y) / 2 }; }

  function onWheel(e) {
    e.preventDefault();
    var p = point(e);
    view = EditorMath.zoomAt(view, p.x, p.y, e.deltaY < 0 ? 1.15 : 1 / 1.15);
    redraw();
  }

  // --- toolbar ------------------------------------------------------------------------------

  function setTool(id) {
    tool = id;
    for (var k in toolBtns) toolBtns[k].classList.toggle("active", k === id);
    modeBtn.hidden = PAINT[id] === undefined;
    currentBtn.hidden = id !== "entity" && id !== "prop";
    if (id === "entity") currentBtn.textContent = entityName || App.settings.entities[0] || "Entity";
    if (id === "prop") {
      var t = propType && App.state.catalog.byId[propType];
      currentBtn.textContent = t ? t.glyph + " " + t.label : "Pick prop";
      if (!t) palette();
    }
    if (id !== "select") { selection = null; updateSelectionButtons(); }
    redraw();
  }

  function updateSelectionButtons() {
    editBtn.hidden = !selection;
    delBtn.hidden = !selection;
  }

  function palette() {
    var cat = App.state.catalog;
    if (!cat.types.length) { App.toast("No props catalog: load one in Sync"); return; }
    App.openSheet("Props", function (body, entry) {
      function pickBtn(t) {
        return App.el("button.prop-pick", { onclick: function () {
          propType = t.id;
          recent = [t.id].concat(recent.filter(function (x) { return x !== t.id; })).slice(0, 6);
          entry.close();
          setTool("prop");
        } }, [
          App.el("span.swatch", { text: t.glyph, style: "background:" + Catalog.cssColor(t.color) }),
          App.el("span", { text: t.label })
        ]);
      }
      if (recent.length) {
        body.appendChild(App.el("div.muted", { text: "Recent" }));
        var row = App.el("div.prop-grid");
        recent.forEach(function (id) { if (cat.byId[id]) row.appendChild(pickBtn(cat.byId[id])); });
        body.appendChild(row);
      }
      cat.categories.forEach(function (c) {
        body.appendChild(App.el("div.muted", { text: c }));
        var grid = App.el("div.prop-grid");
        cat.types.forEach(function (t) { if (t.category === c) grid.appendChild(pickBtn(t)); });
        body.appendChild(grid);
      });
    });
  }

  function chooseCurrent() {
    if (tool === "prop") { palette(); return; }
    App.choose("Entity", App.settings.entities).then(function (n) {
      if (!n) return;
      entityName = n;
      setTool("entity");
    });
  }

  // --- sheets -------------------------------------------------------------------------------

  function field(label, input) { return App.el("label.field", {}, [App.el("span", { text: label }), input]); }

  function editSelection() {
    if (!selection) return;
    var s = selection, rm = room();
    if (s.kind === "prop") return propSheet(s.obj);
    if (s.kind === "door") {
      return App.prompt("Abilities this door requires (comma separated)", (s.obj.requires || []).join(", ")).then(function (v) {
        if (v === null) return;
        begin(); RoomModel.setRequires(s.obj, v); done();
      });
    }
    if (s.kind === "entity") {
      App.openSheet("Entity", function (body) {
        var name = App.el("input", { type: "text", value: s.obj.name });
        var fields = App.el("input", { type: "text", value: RoomModel.fieldsText(s.obj.fields) });
        body.appendChild(field("Name", name));
        body.appendChild(field("Fields (key=value, ...)", fields));
        body.appendChild(App.el("button.primary.wide", { text: "Apply", onclick: function () {
          var parsed = RoomModel.parseFields(fields.value);
          if (parsed === null) { App.toast("Fields must be key=value, ..."); return; }
          begin();
          s.obj.name = name.value.trim() || s.obj.name;
          // keep table fields the text form cannot show
          for (var k in s.obj.fields) if (typeof s.obj.fields[k] === "object") parsed[k] = s.obj.fields[k];
          s.obj.fields = parsed;
          done();
          App.toast("Saved");
        } }));
      });
      return;
    }
    if (s.kind === "item") App.toast("The item has no settings here");
    void rm;
  }

  function propSheet(p) {
    var cat = App.state.catalog, t = cat.byId[p.type];
    App.openSheet(t ? t.label : p.type, function (body) {
      if (!t) { body.appendChild(App.el("p.muted", { text: "Unknown prop type " + p.type + ": not in the catalog." })); return; }
      var size = Catalog.size(cat, p);
      body.appendChild(App.el("p.muted", { text: "Tile " + p.tx + ", " + p.ty + "  size " + size.w + " x " + size.h }));
      if (!t.fields.length) body.appendChild(App.el("p.muted", { text: "No fields." }));
      t.fields.forEach(function (fd) {
        var has = p.fields && Object.prototype.hasOwnProperty.call(p.fields, fd.key);
        var value = has ? p.fields[fd.key] : fd.default;
        var label = fd.key + "  (default " + String(fd.default) + ")";
        function set(v) { begin(); RoomModel.setPropField(p, fd.key, v, fd.default); done(); }
        if (fd.type === "bool") {
          var box = App.el("input", { type: "checkbox" });
          box.checked = !!value;
          box.addEventListener("change", function () { set(box.checked); });
          body.appendChild(field(label, box));
        } else if (fd.type === "enum") {
          var sel = App.el("select");
          fd.options.forEach(function (o) { var op = App.el("option", { text: o, value: o }); if (o === value) op.selected = true; sel.appendChild(op); });
          sel.addEventListener("change", function () { set(sel.value); });
          body.appendChild(field(label, sel));
        } else if (fd.type === "string") {
          var txt = App.el("input", { type: "text", value: String(value) });
          txt.addEventListener("change", function () { set(txt.value); });
          body.appendChild(field(label, txt));
        } else {
          var step = fd.type === "integer" ? 1 : (Math.abs(fd.default) < 2 && fd.default !== Math.floor(fd.default) ? 0.05 : 1);
          var num = App.el("input", { type: "number", value: String(value), step: String(step) });
          var clamp = function (v) {
            if (fd.type === "integer") v = Math.round(v);
            if (typeof fd.min === "number") v = Math.max(fd.min, v);
            if (typeof fd.max === "number") v = Math.min(fd.max, v);
            return Math.round(v * 1e6) / 1e6;
          };
          var apply = function (v) { v = clamp(v); num.value = String(v); set(v); };
          num.addEventListener("change", function () { var v = Number(num.value); if (!isNaN(v)) apply(v); });
          body.appendChild(field(label, App.el("div.row", {}, [
            App.el("button", { text: "-", onclick: function () { apply(Number(num.value) - step); } }),
            num,
            App.el("button", { text: "+", onclick: function () { apply(Number(num.value) + step); } })
          ])));
        }
      });
    });
  }

  function roomSheet() {
    var rm = room(), index = App.state.roomIndex;
    App.openSheet("Room " + rm.id, function (body, entry) {
      var id = App.el("input", { type: "text", value: rm.id });
      var biome = App.el("select");
      [""].concat(App.biomes()).forEach(function (b) {
        var op = App.el("option", { text: b || "(no biome)", value: b });
        if (b === RoomModel.getBiome(rm)) op.selected = true;
        biome.appendChild(op);
      });
      var type = App.el("select");
      App.types().forEach(function (t) {
        var op = App.el("option", { text: t, value: t });
        if (t === rm.type) op.selected = true;
        type.appendChild(op);
      });
      var weight = App.el("input", { type: "number", value: String(rm.weight), min: "0", step: "1" });
      var tags = App.el("input", { type: "text", value: (rm.tags || []).join(", ") });
      var w = App.el("input", { type: "number", value: String(rm.w), min: "1", max: "8" });
      var h = App.el("input", { type: "number", value: String(rm.h), min: "1", max: "8" });
      body.appendChild(field("Id", id));
      body.appendChild(App.el("div.row", {}, [field("Biome", biome), field("Type", type)]));
      body.appendChild(App.el("div.row", {}, [field("Weight", weight), field("Width (cells)", w), field("Height (cells)", h)]));
      body.appendChild(field("Tags (comma separated)", tags));
      body.appendChild(App.el("button.primary.wide", { text: "Apply", onclick: function () {
        var nw = Math.max(1, Math.floor(Number(w.value) || 1)), nh = Math.max(1, Math.floor(Number(h.value) || 1));
        var shrink = nw < rm.w || nh < rm.h;
        var go = shrink ? App.confirm("Making the room smaller drops what is outside. Continue?", "Resize") : Promise.resolve(true);
        go.then(function (ok) {
          if (!ok) return;
          begin();
          if (id.value.trim() !== rm.id && !RoomModel.renameRoom(level(), rm, id.value)) App.toast("That id is empty or taken");
          RoomModel.setBiome(rm, biome.value);
          RoomModel.setType(rm, type.value);
          RoomModel.setWeight(rm, Math.max(0, Math.floor(Number(weight.value) || 0)));
          RoomModel.setTags(rm, tags.value);
          if (nw !== rm.w || nh !== rm.h) { RoomModel.resizeRoom(level(), rm, nw, nh); needFit = true; fitView(); }
          done();
          updateTitle();
          entry.close();
        });
      } }));
      var checks = RoomModel.checkRoomFull(level(), rm);
      body.appendChild(App.el("div.muted", { text: checks.length ? "Checks" : "No problems found" }));
      checks.forEach(function (c) {
        body.appendChild(App.el("button.wide", { text: c.message, onclick: function () {
          entry.close();
          if (c.tx) centerOn(c.tx, c.ty);
        } }));
      });
      void index;
    });
  }

  function centerOn(tx, ty) {
    view.ox = cw / 2 - (tx - 0.5) * view.scale;
    view.oy = ch / 2 - (ty - 0.5) * view.scale;
    redraw();
  }

  function deleteSelection() {
    if (!selection) return;
    var s = selection, rm = room();
    begin();
    if (s.kind === "prop") RoomModel.removeProp(rm, s.obj);
    else if (s.kind === "entity") RoomModel.removeEntity(rm, s.obj);
    else if (s.kind === "door") rm.exits.splice(rm.exits.indexOf(s.obj), 1);
    else if (s.kind === "item") delete rm.item;
    selection = null;
    updateSelectionButtons();
    done();
  }

  // --- room navigation ----------------------------------------------------------------------

  function updateTitle() {
    var rm = room();
    idBtn.firstChild.textContent = rm ? rm.id : "";
    updateBadge();
  }

  function updateBadge() {
    var rm = room();
    var n = rm ? RoomModel.checkRoomFull(level(), rm).length : 0;
    badge.textContent = n ? String(n) : "";
    badge.hidden = !n;
  }

  function openRoom() {
    selection = null;
    updateSelectionButtons();
    needFit = true;
    fitView();
    updateTitle();
    redraw();
  }

  function step(delta) {
    if (!App.step(delta)) { App.toast("No rooms in this filter"); return; }
    openRoom();
  }

  function variant() {
    App.before();
    var v = RoomModel.duplicateRoom(level(), room());
    App.changed(v);
    App.selectRoom(v);
    openRoom();
    App.toast("Made " + v.id);
  }

  function undoRedo(isUndo) {
    var ok = isUndo ? App.undo() : App.redo();
    if (!ok) { App.toast(isUndo ? "Nothing to undo" : "Nothing to redo"); return; }
    selection = null;
    updateSelectionButtons();
    updateTitle();
    redraw();
  }

  App.registerScreen("editor", {
    init: function (r) {
      root = r;
      badge = App.el("span.badge", { hidden: "" });
      idBtn = App.el("button.grow.title", { onclick: function () { roomSheet(); } }, [App.el("span", { text: "" }), badge]);
      root.appendChild(App.el("div.bar", {}, [
        App.el("button.icon", { text: "←", "aria-label": "Library", onclick: function () { App.show("library"); } }),
        App.el("button.nav", { text: "◀", "aria-label": "Previous room", onclick: function () { step(-1); } }),
        idBtn,
        App.el("button.nav", { text: "▶", "aria-label": "Next room", onclick: function () { step(1); } }),
        App.el("button", { text: "Variant", onclick: variant })
      ]));
      var holder = App.el("div.canvas-holder");
      canvas = App.el("canvas.room");
      holder.appendChild(canvas);
      root.appendChild(holder);
      ctx = canvas.getContext("2d");
      canvas.addEventListener("pointerdown", onDown);
      canvas.addEventListener("pointermove", onMove);
      canvas.addEventListener("pointerup", onUp);
      canvas.addEventListener("pointercancel", onUp);
      canvas.addEventListener("wheel", onWheel, { passive: false });

      modeBtn = App.el("button", { text: "Free", onclick: function () {
        mode = MODES[(MODES.indexOf(mode) + 1) % MODES.length];
        modeBtn.textContent = mode.charAt(0).toUpperCase() + mode.slice(1);
      } });
      currentBtn = App.el("button.grow", { text: "", hidden: "", onclick: chooseCurrent });
      editBtn = App.el("button", { text: "Edit", hidden: "", onclick: editSelection });
      delBtn = App.el("button.danger", { text: "Del", hidden: "", onclick: deleteSelection });
      var row1 = App.el("div.bar.bottom.tools");
      TOOLS.forEach(function (t) {
        toolBtns[t.id] = App.el("button.tool", { text: t.label, onclick: function () { setTool(t.id); } });
        row1.appendChild(toolBtns[t.id]);
      });
      var row2 = App.el("div.bar.bottom", {}, [modeBtn, currentBtn, editBtn, delBtn, App.el("span.grow"),
        App.el("button", { text: "Undo", onclick: function () { undoRedo(true); } }),
        App.el("button", { text: "Redo", onclick: function () { undoRedo(false); } })]);
      root.appendChild(row2);
      root.appendChild(row1);
      window.addEventListener("resize", function () { if (App.current === "editor") resize(); });
      setTool("solid");
    },
    show: function (opts) {
      openRoom();
      requestAnimationFrame(function () {
        resize();
        if (opts && opts.focus && opts.focus.tx) centerOn(opts.focus.tx, opts.focus.ty);
      });
    },
    hide: function () { if (App.state.dirty) App.saveNow(); },
    back: function () { App.show("library"); return true; }
  });
})();
