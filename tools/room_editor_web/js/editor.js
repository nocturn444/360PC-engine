// Placeholder: the editor screen. Replaced by its implementation.
"use strict";
App.registerScreen("editor", {
  init: function (root) {
    root.appendChild(App.el("div.bar", {}, [App.el("span.grow", { text: "editor (not built yet)" })]));
  },
  show: function () {},
  back: function () { if (App.current !== "library") { App.show("library"); return true; } return false; }
});
