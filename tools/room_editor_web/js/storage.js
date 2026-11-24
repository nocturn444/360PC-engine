// Storage and device services for the room editor, as Promises.
// Inside the Android app (android/room_editor) everything goes through window.Android; in a
// plain browser projects live in localStorage, export is a download and import a file input.
// Share and GitHub exist only in the app (Storage.hasBridge()).
"use strict";

var Storage = (function () {
  var PREFIX = "roomeditor.project.";
  var SETTINGS_KEY = "roomeditor.settings";
  var pending = {};
  var nextId = 1;

  function bridge() {
    return (typeof window !== "undefined" && window.Android) ? window.Android : null;
  }

  // The app answers every async call with window.onAndroidResult(id, ok, text).
  if (typeof window !== "undefined") {
    window.onAndroidResult = function (id, ok, text) {
      var p = pending[id];
      if (!p) return;
      delete pending[id];
      if (ok === true || ok === "true") p.resolve(text);
      else p.reject(new Error(text || "failed"));
    };
  }

  function call(method) {
    var args = Array.prototype.slice.call(arguments, 1);
    return new Promise(function (resolve, reject) {
      var id = "cb" + (nextId++);
      pending[id] = { resolve: resolve, reject: reject };
      try {
        var b = bridge();
        b[method].apply(b, args.concat([id]));
      } catch (e) {
        delete pending[id];
        reject(e);
      }
    });
  }

  function local(fn) {
    return new Promise(function (resolve, reject) {
      try { resolve(fn()); } catch (e) { reject(e); }
    });
  }

  function validName(name) {
    if (!/^[A-Za-z0-9_.-]+\.lvl$/.test(name)) {
      throw new Error("project names use letters, digits, _ . - and end in .lvl");
    }
  }

  var S = {};

  S.hasBridge = function () { return bridge() !== null; };

  // [{ name, bytes, modified }]
  S.listProjects = function () {
    if (bridge()) return call("listProjects").then(function (t) { return JSON.parse(t || "[]"); });
    return local(function () {
      var out = [];
      for (var i = 0; i < localStorage.length; i++) {
        var key = localStorage.key(i);
        if (key.indexOf(PREFIX) === 0) {
          var text = localStorage.getItem(key) || "";
          out.push({ name: key.slice(PREFIX.length), bytes: text.length, modified: 0 });
        }
      }
      out.sort(function (a, b) { return a.name < b.name ? -1 : 1; });
      return out;
    });
  };

  S.readProject = function (name) {
    if (bridge()) return call("readProject", name);
    return local(function () {
      var text = localStorage.getItem(PREFIX + name);
      if (text === null) throw new Error("no project " + name);
      return text;
    });
  };

  S.writeProject = function (name, text) {
    if (bridge()) return call("writeProject", name, text);
    return local(function () { validName(name); localStorage.setItem(PREFIX + name, text); return ""; });
  };

  S.deleteProject = function (name) {
    if (bridge()) return call("deleteProject", name);
    return local(function () { localStorage.removeItem(PREFIX + name); return ""; });
  };

  // Resolves with the chosen file's name (app) or the downloaded name (browser).
  S.exportFile = function (name, text) {
    if (bridge()) return call("exportFile", name, text);
    return local(function () {
      var a = document.createElement("a");
      a.href = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
      a.download = name;
      document.body.appendChild(a);
      a.click();
      setTimeout(function () { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
      return name;
    });
  };

  // Resolves with { name, text }.
  S.importFile = function () {
    if (bridge()) return call("importFile").then(function (t) { return JSON.parse(t); });
    return new Promise(function (resolve, reject) {
      var input = document.createElement("input");
      input.type = "file";
      input.accept = ".lvl,text/plain";
      input.onchange = function () {
        var file = input.files && input.files[0];
        if (!file) { reject(new Error("no file")); return; }
        var reader = new FileReader();
        reader.onload = function () { resolve({ name: file.name, text: String(reader.result) }); };
        reader.onerror = function () { reject(new Error("could not read " + file.name)); };
        reader.readAsText(file);
      };
      input.click();
    });
  };

  S.shareText = function (name, text) {
    if (!bridge()) return Promise.reject(new Error("sharing needs the Android app"));
    bridge().shareText(name, text);
    return Promise.resolve("");
  };

  // GitHub (app only). The token is handed to the app once and never read back.
  S.setGitHubConfig = function (owner, repo, token) { bridge().setGitHubConfig(owner, repo, token || ""); };
  S.getGitHubConfig = function () {
    if (!bridge()) return { owner: "", repo: "", hasToken: false };
    try { return JSON.parse(bridge().getGitHubConfig()); } catch (e) { return { owner: "", repo: "", hasToken: false }; }
  };
  S.clearGitHubToken = function () { bridge().clearGitHubToken(); };
  S.githubList = function (dir, ref) {
    return call("githubList", dir, ref || "main").then(function (t) { return JSON.parse(t); });
  };
  S.githubRead = function (path, ref) {
    return call("githubRead", path, ref || "main").then(function (t) { return JSON.parse(t); });
  };
  // files: [{ path, text }] -> { branch, prUrl, prNumber }
  S.githubUpload = function (files, title, body) {
    return call("githubUpload", JSON.stringify(files), title, body).then(function (t) { return JSON.parse(t); });
  };

  // Small settings, always in localStorage (kept by the WebView across app updates).
  S.loadSettings = function (defaults) {
    var out = JSON.parse(JSON.stringify(defaults));
    try {
      var saved = JSON.parse(localStorage.getItem(SETTINGS_KEY) || "{}");
      for (var k in saved) if (Object.prototype.hasOwnProperty.call(saved, k)) out[k] = saved[k];
    } catch (e) { /* defaults */ }
    return out;
  };
  S.saveSettings = function (settings) {
    try { localStorage.setItem(SETTINGS_KEY, JSON.stringify(settings)); } catch (e) { /* ignore */ }
  };
  // Small key/value cache (catalog text, repo snapshots of projects).
  S.getItem = function (key) { try { return localStorage.getItem("roomeditor." + key); } catch (e) { return null; } };
  S.setItem = function (key, value) {
    try { localStorage.setItem("roomeditor." + key, value); } catch (e) { /* ignore */ }
  };

  return S;
})();

if (typeof module !== "undefined" && module.exports) module.exports = Storage;
