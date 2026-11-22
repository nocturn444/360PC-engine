// The sync screen: export and import files, GitHub open/upload, and the props catalog.
// The pure helpers (SyncLogic) are exported for Node; the screen below runs only in a browser.
"use strict";

(function () {
  var hasModule = typeof module !== "undefined" && module.exports;
  var Model = hasModule ? require("./model.js") : globalThis.RoomModel;

  var SyncLogic = (function () {
    // The room's data as a stable string: object keys sorted, the editor-only grid ignored.
    function stable(value) {
      if (typeof value === "function" || value === undefined) return "null";
      if (value === null || typeof value !== "object") return JSON.stringify(value);
      if (Array.isArray(value)) {
        var items = [];
        for (var i = 0; i < value.length; i++) items.push(stable(value[i]));
        return "[" + items.join(",") + "]";
      }
      var keys = Object.keys(value).sort();
      var parts = [];
      for (var k = 0; k < keys.length; k++) {
        if (keys[k] === "grid") continue;
        parts.push(JSON.stringify(keys[k]) + ":" + stable(value[keys[k]]));
      }
      return "{" + parts.join(",") + "}";
    }

    // { id: stable room } for a level's text, or null when the text does not parse.
    function rooms(text) {
      var result = Model.fromText(text || "");
      if (result.error) return null;
      var map = {};
      for (var i = 0; i < result.level.rooms.length; i++) {
        var room = result.level.rooms[i];
        map[room.id] = stable(room);
      }
      return map;
    }

    // How many rooms differ between two files, by id (added and removed rooms count too).
    // An empty text means "no copy": every room on the other side is a change.
    function changedRooms(beforeText, afterText) {
      var a = beforeText ? rooms(beforeText) : {};
      var b = afterText ? rooms(afterText) : {};
      if (!a || !b) return 0;
      var ids = {};
      var id;
      for (id in a) if (Object.prototype.hasOwnProperty.call(a, id)) ids[id] = true;
      for (id in b) if (Object.prototype.hasOwnProperty.call(b, id)) ids[id] = true;
      var count = 0;
      for (id in ids) {
        if (Object.prototype.hasOwnProperty.call(ids, id) && a[id] !== b[id]) count++;
      }
      return count;
    }

    // The projects whose text differs from the repository copy (a missing copy counts).
    function changedProjects(projects, repoTexts) {
      var out = [];
      for (var i = 0; i < projects.length; i++) {
        var project = projects[i];
        var repo = repoTexts &&
          Object.prototype.hasOwnProperty.call(repoTexts, project.name) ? repoTexts[project.name] : null;
        if (repo === null || repo !== project.text) out.push(project);
      }
      return out;
    }

    // The default pull request title for a selection of project names.
    function defaultTitle(names, count) {
      return "Rooms: " + names.join(", ") + " (" + count + " rooms changed)";
    }

    return {
      changedRooms: changedRooms,
      changedProjects: changedProjects,
      defaultTitle: defaultTitle
    };
  })();

  if (hasModule) {
    module.exports = SyncLogic;
    return;
  }
  globalThis.SyncLogic = SyncLogic;

  var state = { root: null, scroll: null, status: "", error: "", result: null };

  function section(title) {
    var card = App.el("div.section");
    card.appendChild(App.el("h2", { text: title }));
    return card;
  }

  function kv(label, value) {
    return App.el("div.kv", {}, [
      App.el("span", { text: label }),
      App.el("span.muted", { text: value })
    ]);
  }

  function button(text, onclick, primary) {
    return App.el(primary ? "button.primary" : "button", { text: text, onclick: onclick });
  }

  function stripExt(name) {
    return String(name).replace(/\.lvl$/i, "");
  }

  function joinPath(dir, name) {
    return String(dir || "").replace(/\/+$/, "") + "/" + String(name || "").replace(/^\/+/, "");
  }

  function fail(e) {
    state.status = "";
    state.error = e && e.message ? e.message : String(e);
    render();
    if (state.scroll) state.scroll.scrollTop = 0;
    App.toast(state.error);
  }

  function info(message) {
    state.error = "";
    state.status = message;
    render();
  }

  function projectText() {
    if (!App.state.level) {
      App.toast("No project is open");
      return null;
    }
    return Model.toText(App.state.level);
  }

  function fileName() {
    return App.state.projectName || "rooms.lvl";
  }

  function exportProject() {
    var text = projectText();
    if (text === null) return;
    Storage.exportFile(fileName(), text).then(function (name) {
      App.toast("Exported " + name);
    }, fail);
  }

  function shareProject() {
    var text = projectText();
    if (text === null) return;
    Storage.shareText(fileName(), text).then(function () {
      App.toast("Shared " + fileName());
    }, fail);
  }

  function importProject() {
    Storage.importFile().then(function (file) {
      var parsed = Model.fromText(file.text || "");
      if (parsed.error) throw new Error(file.name + ": " + parsed.error);
      return App.choose("Import " + file.name, [
        { label: "Add as a new project", value: "new" },
        { label: "Merge into this project", value: "merge" }
      ]).then(function (choice) {
        if (!choice) return;
        if (choice === "new") return addImported(file.name, parsed.level);
        return mergeImported(parsed.level);
      });
    }).catch(fail);
  }

  function addImported(suggested, level) {
    return App.prompt("New project name", suggested || "rooms.lvl").then(function (name) {
      if (name === null) return;
      name = String(name).trim();
      if (name === "") {
        App.toast("A project needs a name");
        return;
      }
      if (!/\.lvl$/i.test(name)) name += ".lvl";
      return Storage.writeProject(name, Model.toText(level)).then(function () {
        info("Imported " + name + " (" + level.rooms.length + " rooms).");
      });
    });
  }

  function mergeImported(level) {
    return App.choose("Rooms that already exist", [
      { label: "Rename the imported rooms", value: "rename" },
      { label: "Replace the rooms here", value: "replace" },
      { label: "Skip the imported rooms", value: "skip" }
    ]).then(function (conflict) {
      if (!conflict) return;
      var current = App.state.level;
      if (!current) {
        App.toast("No project is open");
        return;
      }
      if (level.tile_size !== current.tile_size || !level.cell || !current.cell ||
        level.cell.w !== current.cell.w || level.cell.h !== current.cell.h) {
        App.toast("The files need the same tile size and cell");
        return;
      }
      App.before();
      var result = Model.importRooms(current, level, { onConflict: conflict });
      if (result.error) {
        App.toast(result.error);
        return;
      }
      App.changed(null);
      info("Added " + result.added + ", renamed " + result.renamed + ", replaced " +
        result.replaced + ", skipped " + result.skipped + ".");
    });
  }

  function projectSection() {
    var card = section("This project");
    card.appendChild(kv("Project", App.state.projectName || "(none)"));
    card.appendChild(kv("Rooms", String(App.state.level ? App.state.level.rooms.length : 0)));
    if (state.status) card.appendChild(App.el("p.ok", { text: state.status }));
    if (state.error) card.appendChild(App.el("p.error", { text: state.error }));
    var row = App.el("div.row");
    row.appendChild(button("Export file", exportProject));
    if (Storage.hasBridge()) row.appendChild(button("Share", shareProject));
    row.appendChild(button("Import file", importProject));
    card.appendChild(row);
    return card;
  }

  function copy(text) {
    if (typeof navigator !== "undefined" && navigator.clipboard &&
      navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () {
        App.toast("Copied");
      }, function () {
        App.toast(text);
      });
      return;
    }
    var area = document.createElement("textarea");
    area.value = text;
    document.body.appendChild(area);
    area.select();
    try {
      document.execCommand("copy");
      App.toast("Copied");
    } catch (e) {
      App.toast(text);
    }
    area.remove();
  }

  function githubSection() {
    var card = section("GitHub");
    var config = Storage.getGitHubConfig();
    card.appendChild(kv("Repository",
      config.owner && config.repo ? config.owner + "/" + config.repo : "not set"));
    card.appendChild(kv("Token", config.hasToken ? "saved" : "not saved"));

    if (state.result) {
      card.appendChild(App.el("p.ok", {
        text: "Pull request #" + state.result.prNumber + " created"
      }));
      if (state.result.prUrl) {
        card.appendChild(App.el("p.link", { text: state.result.prUrl }));
        card.appendChild(button("Copy link", function () { copy(state.result.prUrl); }));
      }
    }

    if (!config.hasToken) {
      card.appendChild(App.el("p.muted", {
        text: "Save a GitHub token in Settings to open, upload or reload from the repository."
      }));
      card.appendChild(button("Open Settings", function () {
        App.show("settings");
      }, true));
      return card;
    }

    var row = App.el("div.row");
    row.appendChild(button("Open from repo", openFromRepo));
    row.appendChild(button("Upload", startUpload, true));
    card.appendChild(row);
    card.appendChild(button("Reload catalog", reloadCatalog));
    return card;
  }

  function openFromRepo() {
    Storage.githubList(App.settings.levelsDir).then(function (files) {
      if (!files || files.length === 0) {
        App.toast("No .lvl files in " + App.settings.levelsDir);
        return;
      }
      return App.choose("Open from repo", files.map(function (file) {
        return { label: file.name, value: file.path };
      })).then(function (path) {
        if (!path) return;
        var entry = null;
        for (var i = 0; i < files.length; i++) if (files[i].path === path) entry = files[i];
        if (!entry) return;
        return confirmOverwrite(entry.name).then(function (ok) {
          if (!ok) return;
          return Storage.githubRead(entry.path).then(function (file) {
            return Storage.writeProject(entry.name, file.text).then(function () {
              Storage.setItem("repo." + entry.name, file.text);
              return App.openProject(entry.name).then(function () {
                App.toast("Opened " + entry.name);
                App.show("editor");
              });
            });
          });
        });
      });
    }).catch(fail);
  }

  function confirmOverwrite(name) {
    return Storage.listProjects().then(function (list) {
      var exists = false;
      for (var i = 0; i < list.length; i++) if (list[i].name === name) exists = true;
      if (!exists) return true;
      return App.confirm("Overwrite the local project " + name +
        " with the repository copy?", "Overwrite");
    });
  }

  function startUpload() {
    App.saveNow().then(function () {
      return Storage.listProjects();
    }).then(function (list) {
      return Promise.all(list.map(function (project) {
        return Storage.readProject(project.name).then(function (text) {
          return {
            name: project.name,
            text: text,
            repo: Storage.getItem("repo." + project.name)
          };
        });
      }));
    }).then(function (projects) {
      var repoTexts = {};
      for (var i = 0; i < projects.length; i++) {
        if (projects[i].repo !== null && projects[i].repo !== undefined) {
          repoTexts[projects[i].name] = projects[i].repo;
        }
      }
      var changed = SyncLogic.changedProjects(projects, repoTexts);
      if (changed.length === 0) {
        App.toast("No local changes to upload");
        return;
      }
      openUploadSheet(changed, repoTexts);
    }).catch(fail);
  }

  function openUploadSheet(projects, repoTexts) {
    App.openSheet("Upload to GitHub", function (body, entry) {
      body.appendChild(App.el("p.muted", {
        text: "The files are committed to a new branch and opened as a pull request."
      }));

      var titleEdited = false;
      var rows = [];
      projects.forEach(function (project) {
        var check = App.el("input", { type: "checkbox" });
        check.checked = true;
        var path = App.el("input", { type: "text", value: joinPath(App.settings.levelsDir,
          project.name) });
        var count = SyncLogic.changedRooms(repoTexts[project.name] || "", project.text);
        rows.push({ name: project.name, check: check, path: path, project: project });
        body.appendChild(App.el("div.check-row", {}, [
          check,
          App.el("div", {}, [
            App.el("strong", { text: project.name }),
            App.el("div.muted", {
              text: count + " room" + (count === 1 ? "" : "s") + " changed"
            }),
            App.el("label.field", {}, [
              App.el("span", { text: "Target path" }),
              path
            ])
          ])
        ]));
      });

      var title = App.el("input", { type: "text" });
      function chosenRows() {
        return rows.filter(function (row) { return row.check.checked; });
      }
      function updateTitle() {
        if (titleEdited) return;
        var chosen = chosenRows();
        var total = 0;
        for (var i = 0; i < chosen.length; i++) {
          total += SyncLogic.changedRooms(repoTexts[chosen[i].name] || "",
            chosen[i].project.text);
        }
        title.value = SyncLogic.defaultTitle(chosen.map(function (row) {
          return stripExt(row.name);
        }), total);
      }
      updateTitle();
      rows.forEach(function (row) {
        row.check.addEventListener("change", updateTitle);
      });
      title.addEventListener("input", function () { titleEdited = true; });

      var description = App.el("textarea", { placeholder: "Describe the change" });
      body.appendChild(App.el("label.field", {}, [
        App.el("span", { text: "Title" }),
        title
      ]));
      body.appendChild(App.el("label.field", {}, [
        App.el("span", { text: "Description" }),
        description
      ]));

      var uploadButton = App.el("button.primary", { text: "Upload", onclick: upload });
      body.appendChild(App.el("div.row", {}, [
        App.el("button", { text: "Cancel", onclick: function () { entry.close(); } }),
        uploadButton
      ]));

      function upload() {
        var chosen = chosenRows();
        if (chosen.length === 0) {
          App.toast("Choose at least one project");
          return;
        }
        for (var i = 0; i < chosen.length; i++) {
          if (chosen[i].path.value.trim() === "") {
            App.toast("Every file needs a target path");
            return;
          }
        }
        uploadButton.disabled = true;
        uploadButton.textContent = "Uploading...";
        var message = title.value.trim() || SyncLogic.defaultTitle(chosen.map(function (row) {
          return stripExt(row.name);
        }), 0);
        App.saveNow().then(function () {
          return Promise.all(chosen.map(function (row) {
            return Storage.readProject(row.name).then(function (text) {
              return { name: row.name, path: row.path.value.trim(), text: text };
            });
          }));
        }).then(function (files) {
          return Storage.githubUpload(files, message, description.value).then(function (result) {
            return { files: files, result: result };
          });
        }).then(function (done) {
          for (var i = 0; i < done.files.length; i++) {
            Storage.setItem("repo." + done.files[i].name, done.files[i].text);
          }
          state.result = done.result;
          state.error = "";
          state.status = "";
          entry.close();
          render();
          App.toast("Pull request #" + done.result.prNumber + " created");
        }).catch(function (e) {
          entry.close();
          fail(e);
        });
      }
    });
  }

  function reloadCatalog() {
    Storage.githubRead(App.settings.catalogPath).then(function (file) {
      if (App.setCatalogText(file.text, true)) {
        info("Catalog reloaded from the repository.");
      }
    }).catch(fail);
  }

  function catalogSection() {
    var card = section("Catalog from file");
    card.appendChild(App.el("p.muted", {
      text: "Read the props catalog from a file on this device."
    }));
    card.appendChild(button("Import catalog file", function () {
      Storage.importFile().then(function (file) {
        if (App.setCatalogText(file.text, true)) {
          info("Catalog loaded from " + file.name + ".");
        }
      }).catch(fail);
    }));
    return card;
  }

  function render() {
    if (!state.scroll) return;
    state.scroll.textContent = "";
    state.scroll.appendChild(projectSection());
    if (Storage.hasBridge()) state.scroll.appendChild(githubSection());
    state.scroll.appendChild(catalogSection());
  }

  App.registerScreen("sync", {
    init: function (root) {
      state.root = root;
      root.appendChild(App.el("div.bar", {}, [
        App.el("button.icon", {
          text: "\u2190", "aria-label": "Back",
          onclick: function () { App.show("library"); }
        }),
        App.el("span.grow", { text: "Sync" })
      ]));
      state.scroll = App.el("div.scroll");
      root.appendChild(state.scroll);
    },
    show: function () { render(); },
    back: function () { App.show("library"); return true; }
  });
})();
