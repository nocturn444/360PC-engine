// Placeholder: the library screen. Replaced by its implementation.
"use strict";
App.registerScreen("library", {
  init: function (root) {
    root.appendChild(App.el("div.bar", {}, [App.el("span.grow", { text: "library (not built yet)" })]));
  },
  show: function () {},
  back: function () { if (App.current !== "library") { App.show("library"); return true; } return false; }
});
