// Reader and writer of the text format of engine/save.lua.
//
// Lua tables map to JavaScript as follows: a table whose keys are exactly 1..n becomes an
// Array; any other table becomes a plain object (integer keys as canonical integer strings,
// treated back as numbers when writing). An empty table parses as an empty plain object, and
// both [] and {} serialize as {}. This keeps parse/serialize byte-identical with Lua.
"use strict";

var SaveFmt = {};

var MAX_DEPTH = 100;

function encodeUtf8(text) {
  var out = [];
  for (var i = 0; i < text.length; i++) {
    var code = text.codePointAt(i);
    if (code > 0xffff) i++;
    if (code < 0x80) {
      out.push(code);
    } else if (code < 0x800) {
      out.push(0xc0 | (code >> 6), 0x80 | (code & 0x3f));
    } else if (code < 0x10000) {
      out.push(0xe0 | (code >> 12), 0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    } else {
      out.push(0xf0 | (code >> 18), 0x80 | ((code >> 12) & 0x3f),
        0x80 | ((code >> 6) & 0x3f), 0x80 | (code & 0x3f));
    }
  }
  return out;
}

function decodeUtf8(bytes) {
  var out = "";
  for (var i = 0; i < bytes.length;) {
    var b = bytes[i++];
    if (b < 0x80) {
      out += String.fromCharCode(b);
    } else if ((b & 0xe0) === 0xc0) {
      out += String.fromCharCode(((b & 0x1f) << 6) | (bytes[i++] & 0x3f));
    } else if ((b & 0xf0) === 0xe0) {
      out += String.fromCharCode(((b & 0x0f) << 12) | ((bytes[i++] & 0x3f) << 6) |
        (bytes[i++] & 0x3f));
    } else {
      var cp = ((b & 0x07) << 18) | ((bytes[i++] & 0x3f) << 12) |
        ((bytes[i++] & 0x3f) << 6) | (bytes[i++] & 0x3f);
      out += String.fromCodePoint(cp);
    }
  }
  return out;
}

function setOwn(obj, key, value) {
  Object.defineProperty(obj, key, {
    value: value, enumerable: true, writable: true, configurable: true
  });
}

function isSpace(b) {
  return b === 32 || b === 9 || b === 13 || b === 10;
}

function skip(bytes, i) {
  while (i < bytes.length && isSpace(bytes[i])) i++;
  return i;
}

function isDigit(b) {
  return b !== undefined && b >= 48 && b <= 57;
}

function isWordByte(b) {
  return b !== undefined && ((b >= 48 && b <= 57) || (b >= 65 && b <= 90) ||
    (b >= 97 && b <= 122) || b === 95);
}

function fail(i, what) {
  throw new Error(what + " at byte " + (i + 1));
}

function startsWith(bytes, i, text) {
  for (var j = 0; j < text.length; j++) {
    if (bytes[i + j] !== text.charCodeAt(j)) return false;
  }
  return true;
}

function parseString(bytes, i) {
  var start = i;
  var parts = [];
  i++;
  var from = i;
  for (;;) {
    var j = from;
    while (j < bytes.length && bytes[j] !== 34 && bytes[j] !== 92) j++;
    for (var k = from; k < j; k++) parts.push(bytes[k]);
    if (j >= bytes.length) fail(start, "unfinished string");
    if (bytes[j] === 34) return [decodeUtf8(parts), j + 1];
    var c = bytes[j + 1];
    if (c === 92) {
      parts.push(92);
      from = j + 2;
    } else if (c === 34) {
      parts.push(34);
      from = j + 2;
    } else if (c === 110) {
      parts.push(10);
      from = j + 2;
    } else if (c === 114) {
      parts.push(13);
      from = j + 2;
    } else if (c === 116) {
      parts.push(9);
      from = j + 2;
    } else if (isDigit(bytes[j + 1]) && isDigit(bytes[j + 2]) && isDigit(bytes[j + 3])) {
      var code = (bytes[j + 1] - 48) * 100 + (bytes[j + 2] - 48) * 10 + (bytes[j + 3] - 48);
      if (code > 255) fail(j, "bad escape in a string");
      parts.push(code);
      from = j + 4;
    } else {
      fail(j, "bad escape in a string");
    }
  }
}

// The two patterns of save.lua's parse_number, in order.
function matchNumber(bytes, i) {
  var j = i;
  if (bytes[j] === 45) j++;
  if (!isDigit(bytes[j])) return null;
  while (isDigit(bytes[j])) j++;
  if (bytes[j] === 46) {
    j++;
    while (isDigit(bytes[j])) j++;
  }
  var base = j;
  if (bytes[j] === 101 || bytes[j] === 69) {
    var e = j + 1;
    if (bytes[e] === 43 || bytes[e] === 45) e++;
    if (isDigit(bytes[e])) {
      while (isDigit(bytes[e])) e++;
      return bytes.slice(i, e);
    }
  }
  var text = bytes.slice(i, base);
  return text.length ? text : null;
}

function parseNumber(bytes, i) {
  var raw = matchNumber(bytes, i);
  if (!raw) fail(i, "unexpected text");
  var text = "";
  for (var j = 0; j < raw.length; j++) text += String.fromCharCode(raw[j]);
  var n = Number(text);
  if (Number.isNaN(n)) fail(i, "unexpected text");
  return [n, i + raw.length];
}

function keyName(key) {
  return typeof key === "number" ? String(key) : key;
}

function parseTable(bytes, i, depth) {
  if (depth >= MAX_DEPTH) fail(i, "tables nested too deep");
  var positions = new Map();
  var keyed = [];
  var n = 0;
  i = skip(bytes, i + 1);
  for (;;) {
    if (bytes[i] === 125) { i++; break; }
    if (bytes[i] === 91) {
      var kp = parseValue(bytes, skip(bytes, i + 1), depth + 1);
      var key = kp[0];
      i = kp[1];
      var tk = typeof key;
      if ((tk !== "number" && tk !== "string") || (tk === "number" && Number.isNaN(key))) {
        fail(i, "bad table key");
      }
      i = skip(bytes, i);
      if (bytes[i] !== 93) fail(i, "expected ]");
      i = skip(bytes, i + 1);
      if (bytes[i] !== 61) fail(i, "expected =");
      var vp = parseValue(bytes, skip(bytes, i + 1), depth + 1);
      if (vp[0] !== null) keyed.push({ key: key, value: vp[0] });
      i = vp[1];
    } else {
      n++;
      var p = parseValue(bytes, i, depth + 1);
      if (p[0] !== null) positions.set(n, p[0]);
      i = p[1];
    }
    i = skip(bytes, i);
    if (bytes[i] === 44) {
      i = skip(bytes, i + 1);
    } else if (bytes[i] !== 125) {
      fail(i, "expected , or }");
    }
  }
  if (keyed.length === 0) {
    if (n === 0) return [{}, i];
    if (positions.size === n) {
      var arr = [];
      for (var a = 1; a <= n; a++) arr.push(positions.get(a));
      return [arr, i];
    }
    var holes = {};
    positions.forEach(function (v, keyN) { setOwn(holes, String(keyN), v); });
    return [holes, i];
  }
  var obj = {};
  positions.forEach(function (v, keyN) { setOwn(obj, String(keyN), v); });
  for (var q = 0; q < keyed.length; q++) {
    setOwn(obj, keyName(keyed[q].key), keyed[q].value);
  }
  return [obj, i];
}

var WORDS = [
  ["true", true], ["false", false], ["nil", null],
  ["nan", NaN], ["inf", Infinity], ["-inf", -Infinity]
];

function parseValue(bytes, i, depth) {
  var c = bytes[i];
  if (c === 123) return parseTable(bytes, i, depth);
  if (c === 34) return parseString(bytes, i);
  if (c !== undefined && ((c >= 48 && c <= 57) || (c === 45 && !startsWith(bytes, i, "-inf")))) {
    return parseNumber(bytes, i);
  }
  for (var w = 0; w < WORDS.length; w++) {
    var word = WORDS[w][0];
    if (startsWith(bytes, i, word) && !isWordByte(bytes[i + word.length])) {
      return [WORDS[w][1], i + word.length];
    }
  }
  fail(i, c === undefined ? "unexpected end" : "unexpected text");
}

// text -> { ok: true, value } or { ok: false, error } ("... at byte N", like save.lua).
SaveFmt.parse = function (text) {
  if (typeof text !== "string") return { ok: false, error: "not a string" };
  var bytes = encodeUtf8(text);
  try {
    var i = skip(bytes, 0);
    var parsed = parseValue(bytes, i, 0);
    i = skip(bytes, parsed[1]);
    if (i < bytes.length) fail(i, "unexpected text");
    return { ok: true, value: parsed[0] };
  } catch (e) {
    return { ok: false, error: e.message };
  }
};

// C printf("%.17g"), built from the correctly rounded 17-digit form of the double.
function formatG17(v) {
  var exp = v.toExponential(16);
  var sign = "";
  if (exp.charAt(0) === "-") {
    sign = "-";
    exp = exp.slice(1);
  }
  var split = exp.split("e");
  var digits = split[0].replace(".", "");
  var e = parseInt(split[1], 10);
  var out;
  if (e < -4 || e >= 17) {
    var frac = digits.slice(1).replace(/0+$/, "");
    out = digits.charAt(0) + (frac ? "." + frac : "") + "e" +
      (e < 0 ? "-" : "+") + (Math.abs(e) < 10 ? "0" : "") + Math.abs(e);
  } else {
    var intPart, fracPart;
    if (e >= 0) {
      intPart = digits.slice(0, e + 1);
      fracPart = digits.slice(e + 1);
    } else {
      intPart = "0";
      fracPart = "0".repeat(-e - 1) + digits;
    }
    fracPart = fracPart.replace(/0+$/, "");
    out = intPart + (fracPart ? "." + fracPart : "");
  }
  return sign + out;
}

// Same as save.lua's number_text.
function numberText(v) {
  if (Number.isNaN(v)) return "nan";
  if (v === Infinity) return "inf";
  if (v === -Infinity) return "-inf";
  if (Number.isInteger(v) && v > -1e15 && v < 1e15) {
    if (v === 0 && 1 / v === -Infinity) return "-0";
    return v.toFixed(0);
  }
  return formatG17(v);
}

var ESCAPE_BYTES = { 92: "\\\\", 34: '\\"', 10: "\\n", 13: "\\r", 9: "\\t" };

function writeString(text, out) {
  var bytes = encodeUtf8(text);
  out.push(34);
  for (var i = 0; i < bytes.length; i++) {
    var b = bytes[i];
    if (Object.prototype.hasOwnProperty.call(ESCAPE_BYTES, b)) {
      var esc = ESCAPE_BYTES[b];
      for (var j = 0; j < esc.length; j++) out.push(esc.charCodeAt(j));
    } else if (b < 32 || b === 127) {
      var code = "\\" + String(b).padStart(3, "0");
      for (var k = 0; k < code.length; k++) out.push(code.charCodeAt(k));
    } else {
      out.push(b);
    }
  }
  out.push(34);
}

function compareBytes(a, b) {
  var n = Math.min(a.length, b.length);
  for (var i = 0; i < n; i++) {
    if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
  }
  return a.length === b.length ? 0 : (a.length < b.length ? -1 : 1);
}

var INTEGER_KEY = /^(?:0|-?[1-9][0-9]*)$/;

function numericKey(name) {
  return INTEGER_KEY.test(name) ? Number(name) : null;
}

function writeKeyed(key, value, out, path, depth, where) {
  out.push(91);
  if (typeof key === "number") {
    var num = numberText(key);
    for (var i = 0; i < num.length; i++) out.push(num.charCodeAt(i));
  } else {
    writeString(key, out);
  }
  out.push(93, 61);
  writeValue(value, out, path, depth + 1, where);
  out.push(44);
}

function writeTable(v, out, path, depth, where) {
  if (path.has(v)) throw new Error("cannot save a table that contains itself (at " + where + ")");
  if (depth >= MAX_DEPTH) throw new Error("tables nested too deeply (at " + where + ")");
  path.add(v);
  out.push(123);

  var isArray = Array.isArray(v);
  var n = 0;
  for (;;) {
    var name = String(n + 1);
    var has = isArray ? Object.prototype.hasOwnProperty.call(v, n) &&
      v[n] !== undefined && v[n] !== null
      : Object.prototype.hasOwnProperty.call(v, name) &&
        v[name] !== undefined && v[name] !== null;
    if (!has) break;
    n++;
    writeValue(isArray ? v[n - 1] : v[name], out, path, depth + 1,
      where + "[" + n + "]");
    out.push(44);
  }

  var numeric = [];
  var strings = [];
  var names = Object.keys(v);
  for (var i = 0; i < names.length; i++) {
    var keyNameString = names[i];
    var value = v[keyNameString];
    if (value === undefined || value === null) continue;
    var num = numericKey(keyNameString);
    if (isArray) {
      if (num !== null && num >= 0 && num < n) continue;
      if (num !== null) numeric.push({ key: num + 1, value: value });
      else strings.push({ key: keyNameString, value: value });
    } else {
      if (num !== null && num >= 1 && num <= n) continue;
      if (num !== null) numeric.push({ key: num, value: value });
      else strings.push({ key: keyNameString, value: value });
    }
  }
  numeric.sort(function (a, b) { return a.key - b.key; });
  strings.sort(function (a, b) {
    return compareBytes(encodeUtf8(a.key), encodeUtf8(b.key));
  });
  for (var a = 0; a < numeric.length; a++) {
    writeKeyed(numeric[a].key, numeric[a].value, out, path, depth, where);
  }
  for (var s = 0; s < strings.length; s++) {
    writeKeyed(strings[s].key, strings[s].value, out, path, depth, where);
  }
  out.push(125);
  path.delete(v);
}

function writeValue(v, out, path, depth, where) {
  if (v === null || v === undefined) {
    out.push(110, 105, 108);
  } else if (typeof v === "boolean") {
    var word = v ? "true" : "false";
    for (var i = 0; i < word.length; i++) out.push(word.charCodeAt(i));
  } else if (typeof v === "number") {
    var num = numberText(v);
    for (var j = 0; j < num.length; j++) out.push(num.charCodeAt(j));
  } else if (typeof v === "string") {
    writeString(v, out);
  } else if (Array.isArray(v) || typeof v === "object") {
    writeTable(v, out, path, depth, where);
  } else {
    throw new Error("cannot save a " + typeof v + " (at " + where + ")");
  }
}

// value -> text, byte-identical to save.lua's Save.serialize.
SaveFmt.serialize = function (value) {
  var out = [];
  writeValue(value, out, new Set(), 0, "root");
  return decodeUtf8(out);
};

if (typeof module !== "undefined" && module.exports) module.exports = SaveFmt;
if (typeof globalThis !== "undefined") globalThis.SaveFmt = SaveFmt;
