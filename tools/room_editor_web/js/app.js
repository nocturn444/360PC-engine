// The room editor's shell: shared state, screens, sheets, dialogs, autosave and the Android
// back button. Screens (library.js, editor.js, sync.js, settings.js) register themselves with
// App.registerScreen(name, { init(root), show(opts), hide(), back() }) and use App.* below.
"use strict";

var App = (function () {
  var DEFAULT_SETTINGS = {
    biomes: ["forest", "deep_jungle", "grotto", "fungal_cave", "catacombs", "labs", "catastrophe"],
    types: ["normal", "start", "boss", "shop", "treasure", "super_treasure", "miniboss", "casino",
      "pact", "trap", "obstacle"],
    entities: ["Spawn", "Enemy"],
    owner: "nocturn444", repo: "360PC-engine",
    levelsDir: "examples/rooms/levels", catalogPath: "examples/rooms/props_catalog.lvl",
    grid: true, leftHanded: false, lastProject: ""
  };

  var A = {
    screens: {}, current: null,
    state: {
      projectName: "", level: null, history: null, catalog: Catalog.empty(),
      filter: { biome: null, type: null, tag: null, search: "" },
      roomIndex: 0, dirty: false, versions: new WeakMap()
    },
    settings: null
  };

  // --- screens ------------------------------------------------------------------------

  A.registerScreen = function (name, screen) { A.screens[name] = screen; };

  A.show = function (name, opts) {
    if (A.current && A.screens[A.current].hide) A.screens[A.current].hide();
    var roots = document.querySelectorAll(".screen");
    for (var i = 0; i < roots.length; i++) roots[i].hidden = roots[i].id !== "screen-" + name;
    A.current = name;
    if (A.screens[name].show) A.screens[name].show(opts || {});
  };

  // --- project and rooms ----------------------------------------------------------------

  A.setLevel = function (name, level) {
    A.state.projectName = name;
    A.state.level = level;
    A.state.history = RoomModel.history(200);
    A.state.roomIndex = 0;
    A.state.dirty = false;
    A.settings.lastProject = name;
    A.saveSettings();
  };

  A.openProject = function (name) {
    return Storage.readProject(name).then(function (text) {
      var r = RoomModel.fromText(text);
      if (r.error) throw new Error(name + ": " + r.error);
      A.setLevel(name, r.level);
      return r.level;
    });
  };

  A.newProject = function (name) {
    var level = RoomModel.newLevel({ tileSize: 16, cellW: 20, cellH: 12 });
    var room = RoomModel.addRoom(level, "start", 1, 1);
    room.type = "start";
    A.setLevel(name, level);
    return A.saveNow();
  };

  A.room = function () { return A.state.level ? A.state.level.rooms[A.state.roomIndex] || null : null; };

  // The rooms of the current filter, in file order (what prev/next walks through).
  A.filteredRooms = function () {
    if (!A.state.level) return [];
    var f = A.state.filter;
    return RoomModel.listRooms(A.state.level, {
      biome: f.biome, type: f.type, tag: f.tag, search: f.search
    });
  };

  // Moves roomIndex to the previous/next room inside the filter. Returns the room or null.
  A.step = function (delta) {
    var list = A.filteredRooms();
    if (list.length === 0) return null;
    var room = A.room();
    var i = list.indexOf(room);
    var j = i < 0 ? 0 : (i + delta + list.length) % list.length;
    A.state.roomIndex = A.state.level.rooms.indexOf(list[j]);
    return list[j];
  };

  A.selectRoom = function (room) {
    var i = A.state.level.rooms.indexOf(room);
    if (i >= 0) A.state.roomIndex = i;
  };

  // A room's version number, bumped on every change (thumbnail cache key).
  A.version = function (room) { return A.state.versions.get(room) || 0; };

  // Before a change: push(roomIndex) for an in-place edit of one room, push() for list edits.
  A.before = function (roomIndex) { A.state.history.push(A.state.level, roomIndex); };

  // After any change: bump versions, schedule the autosave, tell the screen.
  A.changed = function (room) {
    if (room) A.state.versions.set(room, A.version(room) + 1);
    else A.state.level.rooms.forEach(function (r) { A.state.versions.set(r, A.version(r) + 1); });
    A.state.dirty = true;
    scheduleSave();
  };

  A.undo = function () {
    var at = A.state.history.undoStep(A.state.level);
    if (at === null) return false;
    A.state.roomIndex = Math.min(at, A.state.level.rooms.length - 1);
    A.changed(null);
    return true;
  };

  A.redo = function () {
    var at = A.state.history.redoStep(A.state.level);
    if (at === null) return false;
    A.state.roomIndex = Math.min(at, A.state.level.rooms.length - 1);
    A.changed(null);
    return true;
  };

  var saveTimer = null;
  function scheduleSave() {
    if (saveTimer) clearTimeout(saveTimer);
    saveTimer = setTimeout(function () { saveTimer = null; A.saveNow(); }, 1000);
  }

  A.saveNow = function () {
    if (!A.state.level) return Promise.resolve();
    var text = RoomModel.toText(A.state.level);
    return Storage.writeProject(A.state.projectName, text).then(function () {
      A.state.dirty = false;
    }, function (e) { A.toast("Save failed: " + e.message); });
  };

  // Biomes, types and entity names to offer: the settings lists plus whatever the file has.
  A.biomes = function () {
    var out = A.settings.biomes.slice();
    if (A.state.level) A.state.level.rooms.forEach(function (r) {
      var b = RoomModel.getBiome(r);
      if (b && out.indexOf(b) < 0) out.push(b);
    });
    return out;
  };
  A.types = function () {
    var out = A.settings.types.slice();
    if (A.state.level) A.state.level.rooms.forEach(function (r) {
      if (r.type && out.indexOf(r.type) < 0) out.push(r.type);
    });
    return out;
  };

  // --- catalog ----------------------------------------------------------------------------

  A.setCatalogText = function (text, cache) {
    var r = Catalog.parse(text);
    if (r.error) { A.toast(r.error); return false; }
    A.state.catalog = r.catalog;
    if (cache) Storage.setItem("catalog", text);
    return true;
  };

  function loadCatalog() {
    var cached = Storage.getItem("catalog");
    if (cached && A.setCatalogText(cached, false)) return Promise.resolve();
    return fetch("default_catalog.lvl").then(function (r) { return r.ok ? r.text() : ""; })
      .then(function (t) { if (t) A.setCatalogText(t, false); })
      .catch(function () { /* no catalog: props palette is empty */ });
  }

  // --- settings ---------------------------------------------------------------------------

  A.saveSettings = function () { Storage.saveSettings(A.settings); };

  // --- UI helpers -------------------------------------------------------------------------

  // el("button.big", { onclick: fn, text: "Save" }, [children])
  A.el = function (spec, props, children) {
    var parts = spec.split(".");
    var node = document.createElement(parts[0] || "div");
    if (parts.length > 1) node.className = parts.slice(1).join(" ");
    props = props || {};
    for (var k in props) {
      if (!Object.prototype.hasOwnProperty.call(props, k)) continue;
      if (k === "icon") continue;
      if (k === "text") node.textContent = props[k];
      else if (k.indexOf("on") === 0) node.addEventListener(k.slice(2), props[k]);
      else if (k === "style") node.style.cssText = props[k];
      else node.setAttribute(k, props[k]);
    }
    (children || []).forEach(function (c) { if (c) node.appendChild(typeof c === "string" ? document.createTextNode(c) : c); });
    if (props.icon && typeof Icons !== "undefined") {
      node.insertBefore(Icons.make(props.icon), node.firstChild);
      node.classList.add("has-ico");
    }
    return node;
  };

  // A stable color per biome: the standard biomes have hand-picked ones, others get a hue
  // from their name, and rooms with no biome are grey.
  var BIOME_COLORS = {
    forest: "#7ccf6a", deep_jungle: "#35b58a", grotto: "#6b9cf5", fungal_cave: "#c98bff",
    catacombs: "#c9b48f", labs: "#55d6e0", catastrophe: "#ff7354"
  };
  A.biomeColor = function (b) {
    if (!b) return "#7d8497";
    if (BIOME_COLORS[b]) return BIOME_COLORS[b];
    var h = 0;
    for (var i = 0; i < b.length; i++) h = (h * 31 + b.charCodeAt(i)) % 360;
    return "hsl(" + h + ", 65%, 65%)";
  };

  var toastTimer = null;
  A.toast = function (msg) {
    var t = document.getElementById("toast");
    t.textContent = msg;
    t.hidden = false;
    if (toastTimer) clearTimeout(toastTimer);
    toastTimer = setTimeout(function () { t.hidden = true; }, 2500);
  };

  // A bottom sheet: build(body) fills it. Returns a close function.
  var sheetStack = [];
  A.openSheet = function (title, build) {
    var layer = document.getElementById("sheets");
    var backdrop = A.el("div.backdrop");
    var sheet = A.el("div.sheet", {}, [A.el("div.grabber"), A.el("div.sheet-head", {}, [
      A.el("span.sheet-title", { text: title }),
      A.el("button.icon.ghost", { icon: "close", "aria-label": "Close", onclick: function () { close(); } })
    ])]);
    var body = A.el("div.sheet-body");
    sheet.appendChild(body);
    backdrop.addEventListener("click", function (e) { if (e.target === backdrop) close(); });
    backdrop.appendChild(sheet);
    layer.appendChild(backdrop);
    var entry = { close: close, onClose: null };
    sheetStack.push(entry);
    function close() {
      var i = sheetStack.indexOf(entry);
      if (i < 0) return;
      sheetStack.splice(i, 1);
      backdrop.remove();
      if (entry.onClose) entry.onClose();
    }
    build(body, entry);
    return close;
  };
  A.sheetOpen = function () { return sheetStack.length > 0; };

  A.confirm = function (msg, okText) {
    return new Promise(function (resolve) {
      A.openSheet(msg, function (body, entry) {
        entry.onClose = function () { resolve(false); };
        body.appendChild(A.el("div.row", {}, [
          A.el("button", { text: "Cancel", onclick: function () { entry.close(); } }),
          A.el("button.primary", { text: okText || "OK", onclick: function () {
            entry.onClose = null; entry.close(); resolve(true);
          } })
        ]));
      });
    });
  };

  A.prompt = function (msg, value) {
    return new Promise(function (resolve) {
      A.openSheet(msg, function (body, entry) {
        var input = A.el("input", { type: "text", value: value || "" });
        entry.onClose = function () { resolve(null); };
        function ok() { entry.onClose = null; entry.close(); resolve(input.value); }
        input.addEventListener("keydown", function (e) { if (e.key === "Enter") ok(); });
        body.appendChild(input);
        body.appendChild(A.el("div.row", {}, [
          A.el("button", { text: "Cancel", onclick: function () { entry.close(); } }),
          A.el("button.primary", { text: "OK", onclick: ok })
        ]));
        setTimeout(function () { input.focus(); input.select(); }, 50);
      });
    });
  };

  // A list of choices in a sheet; resolves with the chosen value or null.
  A.choose = function (title, options) {
    return new Promise(function (resolve) {
      A.openSheet(title, function (body, entry) {
        entry.onClose = function () { resolve(null); };
        options.forEach(function (o) {
          var label = typeof o === "string" ? o : o.label;
          var value = typeof o === "string" ? o : o.value;
          body.appendChild(A.el("button.wide", { text: label, onclick: function () {
            entry.onClose = null; entry.close(); resolve(value);
          } }));
        });
      });
    });
  };

  // --- back button and start --------------------------------------------------------------

  // Android back: close a sheet, else let the screen handle it; false lets the app exit.
  window.onAndroidBack = function () {
    if (sheetStack.length) { sheetStack[sheetStack.length - 1].close(); return true; }
    var s = A.current && A.screens[A.current];
    return !!(s && s.back && s.back());
  };

  A.start = function () {
    A.settings = Storage.loadSettings(DEFAULT_SETTINGS);
    document.body.classList.toggle("left-handed", !!A.settings.leftHanded);
    for (var name in A.screens) {
      var root = document.getElementById("screen-" + name);
      if (root && A.screens[name].init) A.screens[name].init(root);
    }
    loadCatalog().then(function () {
      var name = A.settings.lastProject;
      var open = name ? A.openProject(name).catch(function () { return null; }) : Promise.resolve(null);
      return open;
    }).then(function (level) {
      if (level) return;
      return Storage.listProjects().then(function (list) {
        if (list.length) return A.openProject(list[0].name);
        return A.newProject("rooms.lvl");
      });
    }).catch(function (e) { A.toast(e.message); })
      .then(function () { A.show("library"); });
  };

  document.addEventListener("visibilitychange", function () {
    if (document.hidden && A.state.dirty) A.saveNow();
  });

  return A;
})();

window.addEventListener("load", function () { App.start(); });
