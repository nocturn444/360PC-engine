// Placeholder: the sync screen. Replaced by its implementation.
"use strict";
App.registerScreen("sync", {
  init: function (root) {
    root.appendChild(App.el("div.bar", {}, [App.el("span.grow", { text: "sync (not built yet)" })]));
  },
  show: function () {},
  back: function () { if (App.current !== "library") { App.show("library"); return true; } return false; }
});
