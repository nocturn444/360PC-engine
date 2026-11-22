// Placeholder: the settings screen. Replaced by its implementation.
"use strict";
App.registerScreen("settings", {
  init: function (root) {
    root.appendChild(App.el("div.bar", {}, [App.el("span.grow", { text: "settings (not built yet)" })]));
  },
  show: function () {},
  back: function () { if (App.current !== "library") { App.show("library"); return true; } return false; }
});
