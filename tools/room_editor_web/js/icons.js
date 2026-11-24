// Small inline SVG icons (24x24, drawn with currentColor) so buttons read at a glance on a phone.
// Icons.make("undo") returns a <span class="ico"> holding the SVG. The markup is static.
"use strict";

var Icons = (function () {
  var S = 'fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"';
  var PATHS = {
    back: '<path d="M20 12H5M11 5l-7 7 7 7"/>',
    prev: '<path d="M15 5l-7 7 7 7"/>',
    next: '<path d="M9 5l7 7-7 7"/>',
    up: '<path d="M12 19V5M6 11l6-6 6 6"/>',
    down: '<path d="M12 5v14M6 13l6 6 6-6"/>',
    close: '<path d="M6 6l12 12M18 6L6 18"/>',
    menu: '<path d="M4 7h16M4 12h16M4 17h16"/>',
    more: '<circle cx="5" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="12" cy="12" r="1.6" fill="currentColor" stroke="none"/><circle cx="19" cy="12" r="1.6" fill="currentColor" stroke="none"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    minus: '<path d="M5 12h14"/>',
    undo: '<path d="M9 14L4 9l5-5"/><path d="M4 9h10a6 6 0 010 12h-3"/>',
    redo: '<path d="M15 14l5-5-5-5"/><path d="M20 9H10a6 6 0 000 12h3"/>',
    variant: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V6a2 2 0 00-2-2H6a2 2 0 00-2 2v8a2 2 0 002 2h2"/>',
    solid: '<rect x="4" y="4" width="7" height="7" rx="1" fill="currentColor"/><rect x="13" y="4" width="7" height="7" rx="1" fill="currentColor"/><rect x="4" y="13" width="7" height="7" rx="1" fill="currentColor"/><rect x="13" y="13" width="7" height="7" rx="1"/>',
    oneway: '<path d="M3 9h18" stroke-width="3"/><path d="M8 20v-7M16 20v-7M5 16l3-3 3 3M13 16l3-3 3 3"/>',
    erase: '<path d="M20 20H9L4 15a2 2 0 010-3l8-8a2 2 0 013 0l5 5a2 2 0 010 3l-8 8"/><path d="M8 8l8 8"/>',
    door: '<path d="M5 21V5a2 2 0 012-2h10a2 2 0 012 2v16"/><path d="M3 21h18"/><circle cx="15" cy="12" r="1" fill="currentColor"/>',
    item: '<path d="M6 3h12l3 6-9 12L3 9z"/><path d="M3 9h18M12 21L8 9l4-6 4 6z"/>',
    entity: '<circle cx="12" cy="7" r="3.5"/><path d="M5 21v-2a5 5 0 015-5h4a5 5 0 015 5v2"/>',
    prop: '<path d="M12 3l8 4.5v9L12 21l-8-4.5v-9z"/><path d="M12 12l8-4.5M12 12v9M12 12L4 7.5"/>',
    select: '<path d="M5 3l14 8-6 2-2 6z"/>',
    free: '<path d="M4 20l4-1L19 8a2.1 2.1 0 00-3-3L5 16z"/>',
    rect: '<rect x="4" y="6" width="16" height="12" rx="1.5" stroke-dasharray="3 2.5"/>',
    fill: '<path d="M5 11l7-7 7 7-7 7z"/><path d="M20 15s1.5 2 1.5 3a1.5 1.5 0 01-3 0c0-1 1.5-3 1.5-3z" fill="currentColor"/>',
    edit: '<path d="M4 20h4L19 9l-4-4L4 16z"/><path d="M13 7l4 4"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
    search: '<circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4.2-4.2"/>',
    sync: '<path d="M20 11a8 8 0 00-14.5-4.5L4 8"/><path d="M4 4v4h4"/><path d="M4 13a8 8 0 0014.5 4.5L20 16"/><path d="M20 20v-4h-4"/>',
    settings: '<circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.7 1.7 0 00.3 1.8l.1.1a2 2 0 11-2.8 2.8l-.1-.1a1.7 1.7 0 00-1.8-.3 1.7 1.7 0 00-1 1.5V21a2 2 0 11-4 0v-.1a1.7 1.7 0 00-1.1-1.5 1.7 1.7 0 00-1.8.3l-.1.1a2 2 0 11-2.8-2.8l.1-.1a1.7 1.7 0 00.3-1.8 1.7 1.7 0 00-1.5-1H3a2 2 0 110-4h.1a1.7 1.7 0 001.5-1.1 1.7 1.7 0 00-.3-1.8l-.1-.1a2 2 0 112.8-2.8l.1.1a1.7 1.7 0 001.8.3H9a1.7 1.7 0 001-1.5V3a2 2 0 114 0v.1a1.7 1.7 0 001 1.5 1.7 1.7 0 001.8-.3l.1-.1a2 2 0 112.8 2.8l-.1.1a1.7 1.7 0 00-.3 1.8V9a1.7 1.7 0 001.5 1H21a2 2 0 110 4h-.1a1.7 1.7 0 00-1.5 1z"/>',
    check: '<path d="M5 12l5 5L20 7"/>',
    warn: '<path d="M12 3l10 18H2z"/><path d="M12 10v5M12 18h.01"/>',
    folder: '<path d="M3 6a2 2 0 012-2h4l2 2h8a2 2 0 012 2v10a2 2 0 01-2 2H5a2 2 0 01-2-2z"/>',
    chevron: '<path d="M6 9l6 6 6-6"/>'
  };

  function svg(name) {
    return '<svg viewBox="0 0 24 24" width="24" height="24" aria-hidden="true" ' + S + '>' + (PATHS[name] || "") + '</svg>';
  }

  function make(name) {
    var span = document.createElement("span");
    span.className = "ico";
    span.innerHTML = svg(name);
    return span;
  }

  return { make: make, svg: svg, has: function (n) { return !!PATHS[n]; } };
})();
