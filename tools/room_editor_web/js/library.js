// The library screen: projects, rooms grouped by biome and type, filters, lazy thumbnails and
// room actions (variant, rename, biome, type, move, delete, new room).
"use strict";

(function () {
  var root, listEl, chipsBiome, chipsType, search, titleEl, titleName, titleCount;
  var collapsed = {};
  var observer = null;

  function level() { return App.state.level; }

  function renderChips() {
    var f = App.state.filter;
    chipsBiome.textContent = "";
    chipsType.textContent = "";
    var biomes = [{ label: "All biomes", value: null }].concat(
      App.biomes().map(function (b) { return { label: b, value: b }; }),
      [{ label: "(no biome)", value: "" }]);
    biomes.forEach(function (b) {
      var chip = App.el("button.chip" + (f.biome === b.value ? ".active" : ""), {
        text: b.label, onclick: function () { f.biome = b.value; render(); }
      });
      if (b.value !== null) chip.insertBefore(dot(b.value), chip.firstChild);
      chipsBiome.appendChild(chip);
    });
    var types = [{ label: "All types", value: null }].concat(
      App.types().map(function (t) { return { label: t, value: t }; }));
    types.forEach(function (t) {
      chipsType.appendChild(App.el("button.chip" + (f.type === t.value ? ".active" : ""), {
        text: t.label, onclick: function () { f.type = t.value; render(); }
      }));
    });
  }

  function dot(biome) {
    return App.el("span.dot", { style: "background:" + App.biomeColor(biome) });
  }

  function drawThumb(card) {
    var room = card._room;
    var holder = card.querySelector(".thumb");
    holder.textContent = "";
    holder.appendChild(Render.thumbnail(room, App.state.catalog, 200, 112, App.version(room)));
  }

  function card(room) {
    var checks = RoomModel.checkRoomFull(level(), room);
    var meta = room.w + "\u00d7" + room.h + (room.tags && room.tags.length ? "  \u00b7  " + room.tags.join(", ") : "");
    var c = App.el("div.card", { style: "--biome:" + App.biomeColor(RoomModel.getBiome(room)) }, [
      App.el("div.thumb"),
      App.el("div.card-foot", {}, [
        App.el("div.card-text", {}, [
          App.el("div.card-id", { text: room.id }),
          App.el("div.card-meta", { text: meta })
        ]),
        App.el("button.icon.ghost.small", { icon: "more", "aria-label": "Room actions", onclick: function (e) {
          e.stopPropagation(); actions(room);
        } })
      ]),
      checks.length ? App.el("span.warn", { icon: "warn", text: String(checks.length), title: checks[0].message }) : null
    ]);
    c._room = room;
    var timer = null, long = false;
    c.addEventListener("pointerdown", function () {
      long = false;
      timer = setTimeout(function () { long = true; actions(room); }, 500);
    });
    function cancel() { if (timer) { clearTimeout(timer); timer = null; } }
    c.addEventListener("pointerup", cancel);
    c.addEventListener("pointercancel", cancel);
    c.addEventListener("pointerleave", cancel);
    c.addEventListener("click", function () {
      if (long) return;
      App.selectRoom(room);
      App.show("editor");
    });
    if (observer) observer.observe(c); else drawThumb(c);
    return c;
  }

  function render() {
    if (!root || !level()) return;
    titleName.textContent = App.state.projectName;
    titleCount.textContent = level().rooms.length + (level().rooms.length === 1 ? " room" : " rooms");
    renderChips();
    if (observer) observer.disconnect();
    listEl.textContent = "";
    var rooms = App.filteredRooms();
    if (rooms.length === 0) {
      listEl.appendChild(App.el("div.empty", {}, [
        App.el("div.empty-title", { text: "No rooms here" }),
        App.el("div.muted", { text: "Change the filters or tap + to make a room." })
      ]));
      return;
    }
    // biome -> type -> rooms, in file order of first appearance
    var groups = [], byKey = {};
    rooms.forEach(function (room) {
      var b = RoomModel.getBiome(room) || "";
      var t = room.type || "normal";
      if (!byKey[b]) { byKey[b] = { biome: b, types: [], byType: {}, count: 0 }; groups.push(byKey[b]); }
      var g = byKey[b];
      if (!g.byType[t]) { g.byType[t] = []; g.types.push(t); }
      g.byType[t].push(room);
      g.count++;
    });
    groups.forEach(function (g) {
      var bKey = "b:" + g.biome;
      listEl.appendChild(header(g.biome || "(no biome)", g.count, bKey, "biome", g.biome));
      if (collapsed[bKey]) return;
      g.types.forEach(function (t) {
        var tKey = bKey + "/" + t;
        listEl.appendChild(header(t, g.byType[t].length, tKey, "type"));
        if (collapsed[tKey]) return;
        var grid = App.el("div.cards");
        g.byType[t].forEach(function (room) { grid.appendChild(card(room)); });
        listEl.appendChild(grid);
      });
    });
  }

  function header(text, count, key, kind, biome) {
    var open = !collapsed[key];
    return App.el("button.group." + kind + (open ? ".open" : ""), {
      onclick: function () { collapsed[key] = !collapsed[key]; render(); }
    }, [
      kind === "biome" ? dot(biome) : null,
      App.el("span.group-name", { text: text }),
      App.el("span.count", { text: String(count) }),
      Icons.make("chevron")
    ]);
  }

  function freeId(base) { return RoomModel.freeId(level(), base); }

  function actions(room) {
    var index = level().rooms.indexOf(room);
    App.choose(room.id, [
      { label: "Duplicate as variant", value: "variant" },
      { label: "Rename", value: "rename" },
      { label: "Biome", value: "biome" },
      { label: "Type", value: "type" },
      { label: "Move up", value: "up" },
      { label: "Move down", value: "down" },
      { label: "Delete", value: "delete" }
    ]).then(function (what) {
      if (!what) return;
      if (what === "variant") {
        App.before();
        var v = RoomModel.duplicateRoom(level(), room);
        App.changed(v);
        render();
        App.toast("Made " + v.id);
      } else if (what === "rename") {
        App.prompt("New id", room.id).then(function (id) {
          if (id === null || id === room.id) return;
          App.before(index);
          if (!RoomModel.renameRoom(level(), room, id)) {
            App.state.history.undoStep(level());
            App.toast("That id is empty or taken");
            return;
          }
          App.changed(room);
          render();
        });
      } else if (what === "biome") {
        App.choose("Biome", ["(no biome)"].concat(App.biomes())).then(function (b) {
          if (b === null) return;
          App.before(index);
          RoomModel.setBiome(room, b === "(no biome)" ? "" : b);
          App.changed(room);
          render();
        });
      } else if (what === "type") {
        App.choose("Type", App.types()).then(function (t) {
          if (t === null) return;
          App.before(index);
          RoomModel.setType(room, t);
          App.changed(room);
          render();
        });
      } else if (what === "up" || what === "down") {
        App.before();
        if (RoomModel.moveRoom(level(), room, what === "up" ? -1 : 1)) { App.changed(null); render(); }
        else App.state.history.undoStep(level());
      } else if (what === "delete") {
        App.confirm("Delete " + room.id + "?", "Delete").then(function (ok) {
          if (!ok) return;
          App.before();
          RoomModel.removeRoom(level(), room);
          App.state.roomIndex = 0;
          App.changed(null);
          render();
        });
      }
    });
  }

  function newRoom() {
    var f = App.state.filter;
    var base = (f.biome || "room") + "_" + (f.type && f.type !== "normal" ? f.type : "1");
    App.prompt("New room id", freeId(base)).then(function (id) {
      if (id === null) return;
      id = id.trim() || freeId(base);
      if (RoomModel.findRoom(level(), id)) { App.toast("That id is taken"); return; }
      App.before();
      var room = RoomModel.addRoom(level(), id, 1, 1);
      if (f.biome) RoomModel.setBiome(room, f.biome);
      if (f.type) RoomModel.setType(room, f.type);
      App.changed(room);
      App.selectRoom(room);
      App.show("editor");
    });
  }

  function projects() {
    Storage.listProjects().then(function (list) {
      var options = list.map(function (p) { return { label: p.name, value: p.name }; });
      options.push({ label: "+ New project", value: "\u0000new" });
      return App.choose("Projects", options);
    }).then(function (name) {
      if (!name) return;
      var save = App.state.dirty ? App.saveNow() : Promise.resolve();
      if (name === "\u0000new") {
        return App.prompt("Project name (ends in .lvl)", "rooms_" + (Date.now() % 10000) + ".lvl").then(function (n) {
          if (!n) return;
          if (!/\.lvl$/.test(n)) n += ".lvl";
          return save.then(function () { return App.newProject(n); }).then(render);
        });
      }
      return save.then(function () { return App.openProject(name); }).then(render);
    }).catch(function (e) { App.toast(e.message); });
  }

  function menu() {
    App.choose("Menu", [
      { label: "Sync: export, import, GitHub", value: "sync" },
      { label: "Settings", value: "settings" },
      { label: "Check all rooms", value: "check" }
    ]).then(function (v) {
      if (v === "sync" || v === "settings") App.show(v);
      if (v === "check") {
        var problems = RoomModel.check(level());
        App.openSheet(problems.length + " problems", function (body, entry) {
          if (!problems.length) body.appendChild(App.el("p", { text: "Everything looks fine." }));
          problems.forEach(function (p) {
            body.appendChild(App.el("button.wide", { text: (p.roomId ? p.roomId + ": " : "") + p.message, onclick: function () {
              var room = p.roomId && RoomModel.findRoom(level(), p.roomId);
              entry.close();
              if (room) { App.selectRoom(room); App.show("editor", { focus: p }); }
            } }));
          });
        });
      }
    });
  }

  App.registerScreen("library", {
    init: function (r) {
      root = r;
      titleName = App.el("span.title-main");
      titleCount = App.el("span.title-sub");
      titleEl = App.el("button.grow.title.project", { onclick: projects }, [
        App.el("span.title-stack", {}, [titleName, titleCount]), Icons.make("chevron")]);
      search = App.el("input.search", { type: "search", placeholder: "Search id, biome, type, tag" });
      search.addEventListener("input", function () { App.state.filter.search = search.value; render(); });
      chipsBiome = App.el("div.chips");
      chipsType = App.el("div.chips");
      listEl = App.el("div.scroll.library-list");
      root.appendChild(App.el("div.bar", {}, [App.el("span.logo"), titleEl,
        App.el("button.icon.ghost", { icon: "menu", "aria-label": "Menu", onclick: menu })]));
      root.appendChild(App.el("div.search-wrap", {}, [Icons.make("search"), search]));
      root.appendChild(chipsBiome);
      root.appendChild(chipsType);
      root.appendChild(listEl);
      root.appendChild(App.el("button.fab", { icon: "plus", "aria-label": "New room", onclick: newRoom }));
      if (typeof IntersectionObserver !== "undefined") {
        observer = new IntersectionObserver(function (entries) {
          entries.forEach(function (e) {
            if (e.isIntersecting) { drawThumb(e.target); observer.unobserve(e.target); }
          });
        }, { root: listEl, rootMargin: "200px" });
      }
    },
    show: function () { search.value = App.state.filter.search || ""; render(); },
    back: function () {
      if (document.activeElement === search) { search.blur(); return true; }
      return false;
    }
  });
})();
