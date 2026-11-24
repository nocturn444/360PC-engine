// The settings screen: GitHub, file paths, the lists the editor offers and the display toggles.
"use strict";

(function () {
  var state = { root: null, scroll: null };

  function save() {
    App.saveSettings();
  }

  function section(title) {
    var card = App.el("div.section");
    card.appendChild(App.el("h2", { text: title }));
    return card;
  }

  function textField(label, value, onChange) {
    var input = App.el("input", { type: "text", value: value === undefined ? "" : value });
    input.addEventListener("change", function () { onChange(input.value); });
    return App.el("label.field", {}, [App.el("span", { text: label }), input]);
  }

  function checkbox(label, checked, onChange) {
    var input = App.el("input", { type: "checkbox" });
    input.checked = !!checked;
    input.addEventListener("change", function () { onChange(input.checked); });
    return App.el("label.check-row", {}, [
      input,
      App.el("div", {}, [App.el("span", { text: label })])
    ]);
  }

  function iconButton(text, label, onclick, disabled) {
    var button = App.el("button.icon", {
      icon: text, "aria-label": label, onclick: onclick
    });
    button.disabled = !!disabled;
    return button;
  }

  function githubSection() {
    var card = section("GitHub");
    card.appendChild(textField("Owner", App.settings.owner, function (value) {
      App.settings.owner = value.trim();
      save();
    }));
    card.appendChild(textField("Repository", App.settings.repo, function (value) {
      App.settings.repo = value.trim();
      save();
    }));

    if (!Storage.hasBridge()) {
      card.appendChild(App.el("p.muted", {
        text: "Saving a GitHub token needs the Android app."
      }));
      return card;
    }

    var config = Storage.getGitHubConfig();
    card.appendChild(App.el("div.kv", {}, [
      App.el("span", { text: "Token" }),
      App.el("span.muted", { text: config.hasToken ? "token saved" : "no token saved" })
    ]));
    card.appendChild(App.el("p.muted", {
      text: "Create a fine-grained token on github.com limited to this repository, Contents and Pull requests read/write, with an expiry date; paste it only here."
    }));
    var token = App.el("input", {
      type: "password", autocomplete: "new-password",
      placeholder: "Paste a new token"
    });
    card.appendChild(App.el("label.field", {}, [
      App.el("span", { text: "New token" }),
      token
    ]));
    card.appendChild(App.el("div.row", {}, [
      App.el("button.primary", {
        text: "Save token", onclick: function () {
          Storage.setGitHubConfig(App.settings.owner, App.settings.repo, token.value);
          token.value = "";
          render();
          App.toast("Token saved");
        }
      }),
      App.el("button", {
        text: "Clear token", onclick: function () {
          Storage.clearGitHubToken();
          render();
          App.toast("Token cleared");
        }
      })
    ]));
    return card;
  }

  function filesSection() {
    var card = section("Files");
    card.appendChild(textField("Levels folder", App.settings.levelsDir, function (value) {
      App.settings.levelsDir = value.trim();
      save();
    }));
    card.appendChild(textField("Catalog path", App.settings.catalogPath, function (value) {
      App.settings.catalogPath = value.trim();
      save();
    }));
    return card;
  }

  function listSection(key, title, placeholder) {
    if (!Array.isArray(App.settings[key])) App.settings[key] = [];
    var values = App.settings[key];
    var card = section(title);

    values.forEach(function (value, index) {
      var input = App.el("input", { type: "text", value: value });
      input.addEventListener("change", function () {
        var name = input.value.trim();
        if (name === "") {
          input.value = values[index];
          App.toast("A name cannot be empty");
          return;
        }
        values[index] = name;
        save();
      });
      card.appendChild(App.el("div.list-row", {}, [
        input,
        iconButton("up", "Move up", function () {
          if (index === 0) return;
          var previous = values[index - 1];
          values[index - 1] = values[index];
          values[index] = previous;
          save();
          render();
        }, index === 0),
        iconButton("down", "Move down", function () {
          if (index === values.length - 1) return;
          var next = values[index + 1];
          values[index + 1] = values[index];
          values[index] = next;
          save();
          render();
        }, index === values.length - 1),
        iconButton("close", "Remove", function () {
          values.splice(index, 1);
          save();
          render();
        })
      ]));
    });

    var addInput = App.el("input", { type: "text", placeholder: placeholder });
    function add() {
      var name = addInput.value.trim();
      if (name === "") return;
      values.push(name);
      addInput.value = "";
      save();
      render();
    }
    addInput.addEventListener("keydown", function (e) {
      if (e.key === "Enter") add();
    });
    card.appendChild(App.el("div.list-row", {}, [
      addInput,
      App.el("button", { text: "Add", onclick: add })
    ]));
    return card;
  }

  function displaySection() {
    var card = section("Display");
    card.appendChild(checkbox("Show the grid", App.settings.grid, function (checked) {
      App.settings.grid = checked;
      save();
    }));
    card.appendChild(checkbox("Left-handed layout", App.settings.leftHanded,
      function (checked) {
        App.settings.leftHanded = checked;
        save();
        document.body.classList.toggle("left-handed", checked);
      }));
    return card;
  }

  function render() {
    if (!state.scroll) return;
    state.scroll.textContent = "";
    state.scroll.appendChild(githubSection());
    state.scroll.appendChild(filesSection());
    state.scroll.appendChild(listSection("biomes", "Biomes", "Add a biome"));
    state.scroll.appendChild(listSection("types", "Room types", "Add a room type"));
    state.scroll.appendChild(listSection("entities", "Entity names", "Add an entity name"));
    state.scroll.appendChild(displaySection());
  }

  App.registerScreen("settings", {
    init: function (root) {
      state.root = root;
      root.appendChild(App.el("div.bar", {}, [
        App.el("button.icon.ghost", {
          icon: "back", "aria-label": "Back",
          onclick: function () { App.show("library"); }
        }),
        App.el("span.grow.bar-title", { text: "Settings" })
      ]));
      state.scroll = App.el("div.scroll");
      root.appendChild(state.scroll);
    },
    show: function () { render(); },
    back: function () { App.show("library"); return true; }
  });
})();
