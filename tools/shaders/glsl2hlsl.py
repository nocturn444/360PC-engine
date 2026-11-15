#!/usr/bin/env python3
"""
360PC-Engine - GLSL (LÖVE 11 shader syntax) -> HLSL for xost, the Xbox 360 shader compiler of
xsdk. Adapted from Love360's glsl2hlsl.py. Flow and limits: docs/SHADERS.md.

    translate(name, pixel_src, vertex_src) -> {"ps": hlsl or None, "vs": hlsl or None, "meta": {...}}
    meta_lua(meta)                         -> text of shaders/<name>.meta.lua (read by the runtime)
    for_xost(hlsl)                         -> the same HLSL with the xost rules (idempotent)

Command line (to look at the result; the build is build_shaders.py):
    glsl2hlsl.py <name> <shader.glsl> <output folder>

Registers (they must match runtime/l360_gfx.c):
    pixel:  c6 = love_ScreenSize, c7 = l360_zero (always 0), c8... = the shader's uniforms,
            s0 = the texture being drawn, s1-s3 = Image uniforms
    vertex: c0-c3 = projection (one row per register), c4 = love_ScreenSize, c5... = uniforms
Every uniform starts at its own register; a matN takes N, an array one per element (N per matN).
Every generated pixel shader takes the same input (uv, colour, screen) and adds an expression
multiplied by l360_zero, so that the compiler keeps every input and the interpolators stay
aligned with the vertex shader.
"""
import os
import re
import sys

PS_SCREEN_REG, PS_ZERO_REG, PS_BASE, PS_MAX = 6, 7, 8, 32
VS_SCREEN_REG, VS_BASE, VS_MAX = 4, 5, 16
SAMPLER_MAX = 3                       # Image uniforms: s1-s3
DEFAULT_VS, DEFAULT_PS = "l360_love.vsu", "l360_love.psu"
NAME_RE = re.compile(r"^[A-Za-z][A-Za-z0-9_]{0,23}$")

# uniform type -> (components, registers per element)
TYPES = {"float": (1, 1), "number": (1, 1), "int": (1, 1), "bool": (1, 1),
         "vec2": (2, 1), "vec3": (3, 1), "vec4": (4, 1),
         "mat2": (2, 2), "mat3": (3, 3), "mat4": (4, 4), "Image": (0, 0), "sampler2D": (0, 0)}
# LÖVE names that have no equivalent here: an error, instead of a shader that compiles to
# something else
UNSUPPORTED = ["VaryingTexCoord", "VaryingColor", "VertexPosition", "VertexTexCoord", "VertexColor",
               "TransformMatrix", "ProjectionMatrix", "TransformProjectionMatrix", "love_PixelCoord",
               "love_Canvases", "love_PixelColor", "gl_FragCoord", "gl_FragColor", "gl_Position",
               "ArrayImage", "CubeImage", "VolumeImage", "DepthImage", "effects"]


class ShaderError(Exception):
    """The shader uses something the translator (or xost) does not support."""

def split_args(s):
    """splits arguments at the top level"""
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch in "([":
            depth += 1
        elif ch in ")]":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    out.append(cur)
    return out

def find_call(src, start):
    """src[start] is '(' -> index of the ')' that closes it"""
    depth = 0
    for i in range(start, len(src)):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("unclosed parenthesis")

def rewrite_calls(src, fname, fn, inner=None):
    """replaces each call fname(args) with fn(arg_list); the arguments before it are
    passed through inner (rewrite_all unless said otherwise)"""
    pat = re.compile(r"\b" + fname + r"\s*\(")
    pos = 0
    while True:
        m = pat.search(src, pos)
        if not m:
            return src
        open_i = m.end() - 1
        close_i = find_call(src, open_i)
        args = split_args(src[open_i + 1:close_i])
        args = [(inner or rewrite_all)(a) for a in args]
        rep = fn(args)
        src = src[:m.start()] + rep + src[close_i + 1:]
        pos = m.start() + len(rep)

def find_close(src, start, op="(", cl=")"):
    """src[start] is op -> index of the cl that closes it"""
    depth = 0
    for i in range(start, len(src)):
        if src[i] == op:
            depth += 1
        elif src[i] == cl:
            depth -= 1
            if depth == 0:
                return i
    raise ValueError("unclosed %s" % op)

def strip_comments(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    return re.sub(r"//[^\n]*", "", src)

def functions(src):
    """list of (start, end, header, body) for each top-level function"""
    out, pos = [], 0
    pat = re.compile(r"\b\w+\s+(\w+)\s*\(")
    while True:
        m = pat.search(src, pos)
        if not m:
            return out
        close_i = find_close(src, m.end() - 1)
        rest = src[close_i + 1:]
        sem = re.match(r"\s*:\s*\w+", rest)  # float4 main(...) : COLOR
        if sem:
            close_i += sem.end()
            rest = rest[sem.end():]
        if not rest.lstrip().startswith("{"):
            pos = close_i + 1
            continue
        open_b = close_i + 1 + (len(rest) - len(rest.lstrip()))
        close_b = find_close(src, open_b, "{", "}")
        out.append((m.start(), close_b + 1, src[m.start():open_b], src[open_b + 1:close_b]))
        pos = close_b + 1

def function(src, name):
    for f in functions(src):
        if re.search(r"\b%s\s*\(" % name, f[2]):
            return f
    raise ShaderError("function not found: " + name)

def skip_ws(s, i):
    while i < len(s) and s[i].isspace():
        i += 1
    return i

def stmt_span(s, i):
    """(start, end) of the statement that starts at s[i] (an if with its else counts as one)"""
    i = skip_ws(s, i)
    start = i
    if s.startswith("{", i):
        return start, find_close(s, i, "{", "}") + 1
    kw = re.match(r"(if|for|while)\s*\(", s[i:])
    if kw:
        _, i = stmt_span(s, find_close(s, i + kw.end() - 1) + 1)
        if kw.group(1) == "if":
            j = skip_ws(s, i)
            if re.match(r"else\b", s[j:]):
                _, i = stmt_span(s, j + 4)
        return start, i
    depth = 0
    while i < len(s):
        if s[i] in "([{":
            depth += 1
        elif s[i] in ")]}":
            depth -= 1
        elif s[i] == ";" and depth == 0:
            return start, i + 1
        i += 1
    raise ValueError("statement missing ';'")

def statements(body):
    """splits a block into top-level statements"""
    out, i = [], 0
    while True:
        i = skip_ws(body, i)
        if i >= len(body):
            return out
        s, i = stmt_span(body, i)
        out.append(body[s:i])

def split_if(stmt):
    """'if (c) A else B' -> (c, A, B or None), with A and B without outer braces"""
    m = re.match(r"if\s*\(", stmt)
    close_i = find_close(stmt, m.end() - 1)
    cond = stmt[m.end():close_i]
    s, e = stmt_span(stmt, close_i + 1)
    then = stmt[s:e]
    other = None
    j = skip_ws(stmt, e)
    if re.match(r"else\b", stmt[j:]):
        other = stmt[j + 4:].strip()
    unbrace = lambda t: t.strip()[1:-1] if t.strip().startswith("{") else t
    return cond, unbrace(then), (unbrace(other) if other is not None else None)

def rewrite_all(s):
    s = rewrite_calls(s, "atan", lambda a: ("atan2(%s,%s)" % (a[0], a[1])) if len(a) == 2 else "atan(%s)" % a[0])
    for n in (2, 3, 4):
        s = rewrite_calls(s, "float%d" % n,
                          lambda a, n=n: ("((float%d)(%s))" % (n, a[0])) if len(a) == 1 else "float%d(%s)" % (n, ",".join(a)))
    return s

# ---------------------------------------------------------------------------------------------
# GLSL (LÖVE) -> HLSL
# ---------------------------------------------------------------------------------------------

def preprocess(src, stage):
    """Resolves #ifdef / #ifndef / #if defined(...) / #else / #elif / #endif with only `stage`
    (PIXEL or VERTEX) and the file's own #defines defined. Drops #pragma, #version, #extension."""
    defined, out, state = {stage}, [], []     # state: [active, taken, parent_active]
    active = lambda: all(s[0] for s in state)
    def cond(expr):
        e = re.sub(r"defined\s*\(\s*(\w+)\s*\)|defined\s+(\w+)",
                   lambda m: " True " if (m.group(1) or m.group(2)) in defined else " False ", expr)
        e = e.replace("||", " or ").replace("&&", " and ").replace("!", " not ")
        if not re.fullmatch(r"[\s()]*((True|False|or|and|not)[\s()]*)+", e):
            raise ShaderError("unsupported preprocessor condition: #if " + expr.strip())
        return bool(eval(e))
    for line in src.split("\n"):
        m = re.match(r"\s*#\s*(\w+)\s*(.*)", line)
        if not m:
            if active():
                out.append(line)
            continue
        d, rest = m.group(1), m.group(2).strip()
        if d in ("ifdef", "ifndef", "if"):
            v = cond(rest) if d == "if" else ((rest.split() or [""])[0] in defined) == (d == "ifdef")
            state.append([v, v])
        elif d in ("else", "elif"):
            if not state:
                raise ShaderError("#%s without #if" % d)
            v = not state[-1][1] and (d == "else" or cond(rest))
            state[-1][0] = v
            state[-1][1] = state[-1][1] or v
        elif d == "endif":
            if not state:
                raise ShaderError("#endif without #if")
            state.pop()
        elif not active() or d in ("pragma", "version", "extension"):
            continue
        else:
            name = re.match(r"\w+", rest)
            if d == "define" and name:
                defined.add(name.group(0))
            elif d == "undef" and name:
                defined.discard(name.group(0))
            out.append(line)
    if state:
        raise ShaderError("#if without #endif")
    return "\n".join(out)

def parse_uniforms(src):
    """-> (source without the declarations, [(name, type, array size or 0)])"""
    found = []
    def take(m):
        typ = m.group(1)
        if typ not in TYPES:
            raise ShaderError("unsupported uniform type: " + typ)
        for item in m.group(2).split(","):
            d = re.fullmatch(r"\s*(\w+)\s*(?:\[\s*(\d+)\s*\])?\s*", item)
            if not d:
                raise ShaderError("unsupported uniform declaration: " + m.group(0).strip())
            if TYPES[typ][0] == 0 and d.group(2):
                raise ShaderError("arrays of Image are not supported: " + d.group(1))
            found.append((d.group(1), "float" if typ == "number" else "Image" if typ == "sampler2D" else typ,
                          int(d.group(2) or 0)))
        return ""
    src = re.sub(r"\b(?:extern|uniform)\s+(\w+)\s+([^;{}]+);[ \t]*\n?", take, src)
    names = [n for n, _, _ in found]
    if len(set(names)) != len(names):
        raise ShaderError("uniform declared twice")
    return src, found

def glsl_to_hlsl(src):
    """types and functions with another name; the same in both stages"""
    src = re.sub(r"\bprecision\s+\w+\s+\w+\s*;", "", src)
    src = re.sub(r"\b(lowp|mediump|highp)\b\s*", "", src)
    for word in UNSUPPORTED:
        if re.search(r"\b%s\b" % word, src):
            raise ShaderError("not supported on the console: " + word)
    src = re.sub(r"\bvec([234])\b", r"float\1", src)
    src = re.sub(r"\bmat([234])\b", r"float\1x\1", src)
    src = re.sub(r"\bnumber\b", "float", src)
    src = re.sub(r"\bImage\b", "sampler2D", src)
    src = re.sub(r"\b(Texel|texture2D|texture)\s*\(", "tex2D(", src)
    src = re.sub(r"\bmix\s*\(", "lerp(", src)
    src = re.sub(r"\bfract\s*\(", "frac(", src)
    src = re.sub(r"\bmod\s*\(", "glsl_mod(", src)
    src = re.sub(r"\binversesqrt\s*\(", "rsqrt(", src)
    src = re.sub(r"\bdFdx\s*\(", "ddx(", src)
    src = re.sub(r"\bdFdy\s*\(", "ddy(", src)
    return rewrite_all(src)

def primary_end(src, i):
    """end of the operand that starts at src[i]: (...) or a name, with its call, [index] and .xyz"""
    i = skip_ws(src, i)
    if i < len(src) and src[i] == "(":
        i = find_close(src, i) + 1
    else:
        m = re.match(r"[A-Za-z_]\w*", src[i:])
        if not m:
            raise ShaderError("unsupported matrix product near: " + src[i:i + 40].strip())
        i += m.end()
        if i < len(src) and src[i] == "(":
            i = find_close(src, i) + 1
    while i < len(src) and src[i] in ".[":
        i = find_close(src, i, "[", "]") + 1 if src[i] == "[" else i + 1 + len(re.match(r"\w*", src[i + 1:]).group(0))
    return i

def matrix_products(src, matrices):
    """M * operand -> mul(M, operand), for each matrix name (GLSL's * is HLSL's mul)"""
    for name in matrices:
        pat, pos = re.compile(r"\b%s\s*\*(?!=)" % re.escape(name)), 0
        while True:
            m = pat.search(src, pos)
            if not m:
                break
            end = primary_end(src, m.end())
            rep = "mul(%s, %s)" % (name, src[m.end():end].strip())
            src = src[:m.start()] + rep + src[end:]
            pos = m.start() + len(name) + 5
        if re.search(r"\*\s*%s\b" % re.escape(name), src):
            raise ShaderError("only 'matrix * operand' is supported: " + name)
    return src

def remove_function(src, name):
    for s, e, h, _ in functions(src):
        if re.search(r"\b%s\s*\($" % name, h[:h.index("(") + 1]):
            return src[:s] + src[e:], True
    return src, False

def has_function(src, name):
    return remove_function(src, name)[1]

def allocate(uniforms, src, base, limit, stage, meta):
    """registers for the uniforms that `src` uses -> (declarations and #defines, registers used)"""
    out, reg, slot = [], base, 0
    for name, typ, count in uniforms:
        entry = meta["uniforms"].setdefault(name, {"type": typ, "comps": TYPES[typ][0], "rows": TYPES[typ][1],
                                                   "count": max(count, 1)})
        if not re.search(r"\b%s\b" % re.escape(name), src):
            continue                   # declared and not used: send() accepts it and does nothing
        if typ == "Image":
            if stage != "ps":
                raise ShaderError("Image uniforms cannot be used in the vertex stage: " + name)
            slot += 1
            if slot > SAMPLER_MAX:
                raise ShaderError("more than %d Image uniforms" % SAMPLER_MAX)
            entry["sampler"] = slot
            out.append("sampler2D %s : register(s%d);" % (name, slot))
            continue
        comps, rows = TYPES[typ]
        first, total = reg, rows * max(count, 1)
        reg += total
        if reg - base > limit:
            raise ShaderError("too many uniforms in the %s stage: more than %d registers"
                              % ("pixel" if stage == "ps" else "vertex", limit))
        entry[stage] = first
        p = "l360_%s%%d" % ("p" if stage == "ps" else "v")
        sw = "" if comps == 4 else "." + "xyzw"[:comps]
        if count:                      # an array: name[i] -> (l360_a_name[i].xyz), elements of N rows
            if rows > 1:
                raise ShaderError("arrays of matrices are not supported: " + name)
            out.append("float4 l360_a_%s[%d] : register(c%d);" % (name, count, first))
            continue
        for k in range(total):
            out.append("float4 %s : register(c%d);" % (p % (first + k), first + k))
        if rows > 1:
            value = "float%dx%d(%s)" % (rows, rows, ", ".join((p % (first + k)) + sw for k in range(rows)))
        elif typ == "bool":
            value = "(%s.x > 0.5)" % (p % first)      # this exact form: see for_xost
        else:
            value = (p % first) + sw
        out.append("#define %s (%s)" % (name, value))
    return out, reg - base

def index_arrays(src, uniforms):
    for name, typ, count in uniforms:
        if not count or typ == "Image":
            continue
        sw = "" if TYPES[typ][0] == 4 else "." + "xyzw"[:TYPES[typ][0]]
        pat, pos = re.compile(r"\b%s\s*\[" % re.escape(name)), 0
        while True:
            m = pat.search(src, pos)
            if not m:
                break
            end = find_close(src, m.end() - 1, "[", "]")
            rep = "(l360_a_%s[%s]%s)" % (name, src[m.end():end], sw)
            src = src[:m.start()] + rep + src[end + 1:]
            pos = m.start() + len(rep)
        if re.search(r"(?<!l360_a_)\b%s\b" % re.escape(name), src):
            raise ShaderError("array uniforms can only be indexed: " + name)
    return src

GLSL_MOD = "\n".join(
    ["float glsl_mod(float x, float y) { return x - y * floor(x / y); }"] +
    ["float%d glsl_mod(float%d x, float y) { return x - y * floor(x / y); }" % (n, n) for n in (2, 3, 4)] +
    ["float%d glsl_mod(float%d x, float%d y) { return x - y * floor(x / y); }" % (n, n, n) for n in (2, 3, 4)])

PS_TAIL = """
struct PSInput
{
    float2 uv     : TEXCOORD0;
    float4 colour : COLOR0;
    float2 screen : TEXCOORD1;
};

float4 main(PSInput input) : COLOR
{
    float4 r = effect(input.colour, input.uv, input.screen);
    return r + l360_zero.x * (input.colour + float4(input.screen, input.uv));
}
"""

VS_TAIL = """
struct VSInput
{
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float4 colour   : COLOR0;
};

struct VSOutput
{
    float4 position : POSITION;
    float2 uv       : TEXCOORD0;
    float4 colour   : COLOR0;
    float2 screen   : TEXCOORD1;
};

VSOutput main(VSInput input)
{
    VSOutput output;
    float4 p = l360_position(input.position);
    output.position = p;
    output.uv = input.uv;
    output.colour = input.colour;
    output.screen = (p.xy / p.w * float2(0.5, -0.5) + 0.5) * love_ScreenSize.xy;
    return output;
}
"""

def stage_source(src, stage):
    src = preprocess(strip_comments(src.replace("\r\n", "\n")), stage)
    src, uniforms = parse_uniforms(src)
    return src, uniforms

def tidy(src):
    return re.sub(r"\n\s*\n+", "\n", src).strip() + "\n"

def pixel_stage(name, src, meta):
    src, uniforms = stage_source(src, "PIXEL")
    src, _ = remove_function(src, "position")
    if not has_function(src, "effect"):
        return None
    s, e, head, body = function(src, "effect")
    m = re.fullmatch(r"\s*vec4\s+effect\s*\(\s*vec4\s+(\w+)\s*,\s*(?:Image|sampler2D)\s+(\w+)\s*,"
                     r"\s*vec2\s+(\w+)\s*,\s*vec2\s+(\w+)\s*\)\s*",
                     re.sub(r"\b(lowp|mediump|highp)\b", "", head))
    if not m:
        raise ShaderError("effect must be: vec4 effect(vec4 color, Image tex, vec2 texture_coords, "
                          "vec2 screen_coords)")
    body = re.sub(r"\b%s\b" % re.escape(m.group(2)), "l360_tex0", body)
    src = (src[:s] + "vec4 effect(vec4 %s, vec2 %s, vec2 %s)\n{" % (m.group(1), m.group(3), m.group(4))
           + body + "}" + src[e:])
    src = glsl_to_hlsl(src)
    decl, used = allocate(uniforms, src, PS_BASE, PS_MAX, "ps", meta)
    meta["ps_regs"] = used
    src = index_arrays(src, uniforms)
    src = matrix_products(src, sorted(set(re.findall(r"\bfloat[234]x[234]\s+(\w+)", src))
                                      | {n for n, t, _ in uniforms if t.startswith("mat")}))
    head = ["// %s: pixel stage, generated by glsl2hlsl.py (360PC-Engine). Do not edit." % name,
            "sampler2D l360_tex0 : register(s0);",
            "float4 love_ScreenSize : register(c%d);" % PS_SCREEN_REG,
            "float4 l360_zero : register(c%d);" % PS_ZERO_REG] + decl
    if "glsl_mod(" in src:
        head.append(GLSL_MOD)
    return "\n".join(head) + "\n" + tidy(src) + PS_TAIL

def vertex_stage(name, src, meta):
    src, uniforms = stage_source(src, "VERTEX")
    src, _ = remove_function(src, "effect")
    if not has_function(src, "position"):
        return None
    s, e, head, body = function(src, "position")
    m = re.fullmatch(r"\s*vec4\s+position\s*\(\s*mat4\s+(\w+)\s*,\s*vec4\s+(\w+)\s*\)\s*",
                     re.sub(r"\b(lowp|mediump|highp)\b", "", head))
    if not m:
        raise ShaderError("position must be: vec4 position(mat4 transform_projection, vec4 vertex_position)")
    proj = m.group(1)
    src = src[:s] + "vec4 l360_position(vec4 %s)\n{" % m.group(2) + body + "}" + src[e:]
    src = glsl_to_hlsl(src)
    decl, used = allocate(uniforms, src, VS_BASE, VS_MAX, "vs", meta)
    meta["vs_regs"] = used
    src = index_arrays(src, uniforms)
    src = matrix_products(src, sorted(set(re.findall(r"\bfloat[234]x[234]\s+(\w+)", src)) | {proj}
                                      | {n for n, t, _ in uniforms if t.startswith("mat")}))
    head = ["// %s: vertex stage, generated by glsl2hlsl.py (360PC-Engine). Do not edit." % name,
            "row_major float4x4 %s : register(c0);" % proj,
            "float4 love_ScreenSize : register(c%d);" % VS_SCREEN_REG] + decl
    if "glsl_mod(" in src:
        head.append(GLSL_MOD)
    return "\n".join(head) + "\n" + tidy(src) + VS_TAIL

def translate(name, pixel_src, vertex_src=None):
    """pixel_src / vertex_src: the GLSL of each stage, or the same text (or one None) for a single
    file; in a single file, #ifdef PIXEL and #ifdef VERTEX separate the stages as in LÖVE.
    -> {"ps": HLSL or None, "vs": HLSL or None, "meta": dict}. The HLSL already has the xost rules."""
    if not NAME_RE.match(name) or name.lower().startswith("l360_"):
        raise ShaderError("shader name must be 1 to 24 letters, digits or _, starting with a letter "
                          "and not with l360_: " + name)
    if pixel_src is None and vertex_src is None:
        raise ShaderError(name + ": no source")
    meta = {"version": 1, "name": name, "uniforms": {}, "ps_regs": 0, "vs_regs": 0}
    try:
        ps = pixel_stage(name, pixel_src if pixel_src is not None else vertex_src, meta)
        vs = vertex_stage(name, vertex_src if vertex_src is not None else pixel_src, meta)
        if ps is None and vs is None:
            raise ShaderError("no effect() and no position() function")
        ps, vs = ps and for_xost(ps), vs and for_xost(vs)
    except ValueError as e:              # unbalanced parentheses and the like
        raise ShaderError("%s: %s" % (name, e)) from None
    except ShaderError as e:
        raise ShaderError("%s: %s" % (name, e)) from None
    meta["ps"] = (name + ".psu") if ps else DEFAULT_PS
    meta["vs"] = (name + ".vsu") if vs else DEFAULT_VS
    return {"ps": ps, "vs": vs, "meta": meta}

def meta_lua(meta):
    """the metadata as a data-only Lua file (shaders/<name>.meta.lua)"""
    out = ["-- Generated by tools/shaders (360PC-Engine) from the game's GLSL. Do not edit.",
           "return {",
           "  version = %d," % meta["version"],
           '  name = "%s",' % meta["name"],
           '  ps = "%s",' % meta["ps"],
           '  vs = "%s",' % meta["vs"],
           "  ps_regs = %d," % meta["ps_regs"],
           "  vs_regs = %d," % meta["vs_regs"],
           "  uniforms = {"]
    for name in sorted(meta["uniforms"]):
        u = meta["uniforms"][name]
        fields = ['type = "%s"' % u["type"]] + ["%s = %d" % (k, u[k]) for k in
                                                ("comps", "rows", "count", "ps", "vs", "sampler") if k in u]
        out.append("    %s = { %s }," % (name, ", ".join(fields)))
    out += ["  },", "}", ""]
    return "\n".join(out)

# ---------------------------------------------------------------------------------------------
# Rules for xost (xsdk's compiler): applied to HLSL that is already generated, and to the
# engine's own shaders in runtime/shaders/. xost compiles HLSL through glslang -> SPIR-V.
#   atan2: GLSL.std.450 Atan2 is not implemented -> l360_atan2, with atan and comparisons.
#   clamp with a limit that is not a constant ("not a constant scalar") -> min(max(x, lo), hi).
#   return in the middle of a function -> a single exit, with a variable and if/else.
#   !flag (bool uniform) -> ordered comparison of the 0/1 flag (no OpFUnordLessThanEqual).
#   sin/cos outside [-pi, pi] and atan outside [-1, 1] -> range reduction (l360_angle, l360_atan).
#   stencil with a reduction -> each sample is consumed before the next (limit of 64 registers).
# ---------------------------------------------------------------------------------------------

L360_ATAN2 = ("float l360_atan2(float y, float x) { float ax = abs(x), ay = abs(y); "
              "float a = atan(min(ax, ay) / max(max(ax, ay), 1e-20)); a = ay > ax ? 1.57079632679 - a : a; "
              "a = x < 0.0 ? 3.14159265359 - a : a; return y < 0.0 ? -a : a; }")

def xost_math(src):
    """Reduce before the approximate instructions; also in nested calls.

    The overloads keep the argument's width. clamp only protects the last
    float32 rounding; it does not replace the periodic reduction. Idempotent: the
    installer generates xost HLSL and the compiler passes it through for_xost() again.
    """
    def fix(t):
        for name in ("sin", "cos"):
            t = rewrite_calls(t, name, lambda a, name=name:
                "%s(%s)" % (name, a[0] if re.fullmatch(r"\s*l360_angle\(.*\)\s*", a[0], re.S)
                             else "l360_angle(%s)" % a[0]), fix)
        t = rewrite_calls(t, "atan", lambda a: "l360_atan(%s)" % a[0], fix)
        return t
    for s, e, h, body in reversed(functions(src)):
        if re.search(r"\bl360_(angle|atan|atan2)\s*\(", h):
            continue
        src = src[:s] + h + "{" + fix(body) + "}" + src[e:]
    helpers = []
    if "l360_angle(" in src and not re.search(r"float\s+l360_angle\s*\(", src):
        for n in range(1, 5):
            t = "float" + (str(n) if n > 1 else "")
            helpers.append("%s l360_angle(%s x) { return clamp(x - 6.283185307179586 * "
                           "floor((x + 3.141592653589793) / 6.283185307179586), "
                           "-3.141592653589793, 3.141592653589793); }" % (t, t))
    if "l360_atan(" in src and not re.search(r"float\s+l360_atan\s*\(", src):
        helpers.append("float l360_atan(float x) { float a = abs(x); "
                       "float r = atan(min(a, 1.0) / max(a, 1.0)); "
                       "r = a > 1.0 ? 1.570796326794897 - r : r; return x < 0.0 ? -r : r; }")
        for n in range(2, 5):
            helpers.append("float%d l360_atan(float%d x) { return float%d(%s); }" %
                           (n, n, n, ", ".join("l360_atan(x.%s)" % c for c in "xyzw"[:n])))
    # translate/glsl_pixel already convert mod to glsl_mod = x-y*floor(x/y).
    # Do not emit OpFMod (approximate reciprocal on exact multiples), nor change it
    # to fmod (it truncates and gives another result for negatives).
    if re.search(r"\b(mod|fmod)\s*\(", strip_comments(src)):
        raise ValueError("xost: mod/fmod sin traducir; usar x-y*floor(x/y) para GLSL mod")
    if helpers:
        first = functions(src)[0][0]
        src = src[:first] + "\n".join(helpers) + "\n" + src[first:]
    return src

NUM = re.compile(r"^\s*[-+]?(\d+\.?\d*|\.\d+)([eE][-+]?\d+)?f?\s*$")

def xost_clamp(a):
    if NUM.match(a[1]) and NUM.match(a[2]):
        return "clamp(%s,%s,%s)" % tuple(a)
    return "min(max(%s,%s),%s)" % tuple(a)

def single_exit(sts, rv):
    """statements of a function -> the same, with each 'return X;' changed to 'rv = X;' and what
    follows an 'if (c) return ...;' put into its else (returns the text)"""
    out = []
    for k, st in enumerate(sts):
        br = ""
        if st.startswith("[branch]"):
            br, st = "[branch] ", st[len("[branch]"):].lstrip()
        if st.startswith("return"):
            out.append("%s = %s;" % (rv, st[len("return"):].rstrip(";").strip()))
            return "\n".join(out)
        if st.startswith("if") and re.search(r"\breturn\b", st):
            cond, then, other = split_if(st)
            then_sts = statements(then)
            if not then_sts[-1].startswith("return"):
                raise ShaderError("xost: if containing return does not end in return: " + st[:60])
            rest = sts[k + 1:]
            if other is not None:
                other_sts = statements(other)
                if not other_sts[-1].startswith("return"):
                    other_sts = other_sts + rest
            else:
                other_sts = rest
            out.append("%sif (%s)\n{\n%s\n}\nelse\n{\n%s\n}" % (
                br, cond, single_exit(then_sts, rv), single_exit(other_sts, rv)))
            return "\n".join(out)
        if re.search(r"\breturn\b", st):
            raise ShaderError("xost: cannot flatten return in this block: " + st[:60])
        out.append(br + st)
    return "\n".join(out)

def xost_sample_reduction(src):
    """Serialize a reduction of samples without reducing their number or changing their order.

    xost collects ALL the tex2D calls before lowering the color expression. In an
    unrolled stencil this keeps one temporary per sample until the end.
    A dependency of the coordinates on both accumulators, multiplied by
    the runtime's zero, forces each sample to be consumed before asking for the other.
    It only recognizes two small symmetric loops and finite accumulators; it is not
    a general transformation of loops or of arbitrary integer counters.
    """
    if not re.search(r"float4\s+l360_zero\s*:\s*register\(c\d+\)", src):
        return src
    bounds = dict(re.findall(r"\bint\s+(\w+)\s*=\s*(\d+)\s*;", src))
    loops = re.findall(r"\bfor\s*\(\s*int\s+(\w+)\s*=\s*-\s*(\w+)\s*;"
                       r"\s*\1\s*<=\s*\2\s*;\s*\+\+\1\s*\)", src)
    if len(loops) != 2 or len(re.findall(r"\bfor\s*\(", src)) != 2:
        return src
    if any(bound not in bounds or not 1 <= int(bounds[bound]) <= 32 for _, bound in loops):
        return src
    sample = re.compile(r"\b(\w+)\s*=\s*tex2D\s*\(")
    for m in sample.finditer(src):
        end = find_call(src, m.end() - 1)
        tail = re.match(r"\.a\s*;\s*if\s*\(", src[end + 1:])
        if not tail:
            continue
        start_if = src.index("if", end + 1)
        _, end_if = stmt_span(src, start_if)
        cond, then, other = split_if(src[start_if:end_if])
        if other is not None or not re.fullmatch(r"\s*" + m[1] + r"\s*<\s*[^;{}]+", cond):
            continue
        sts = statements(then)
        if len(sts) != 2:
            continue
        counter = re.fullmatch(r"(\w+)\s*\+=\s*1\s*;", sts[0])
        total = re.fullmatch(r"(\w+)\s*=\s*\1\s*\+\s*" + m[1] + r"\s*;", sts[1])
        if not counter or not total:
            continue
        count, accum = counter[1], total[1]
        declaration = re.compile(r"\bint\s+" + count + r"\s*=\s*0\s*;")
        # Only the declaration, increment and final conversion to float: no other integer uses.
        if not declaration.search(src) or len(re.findall(r"\b" + count + r"\b", src)) != 3:
            continue
        if not re.search(r"\bfloat\s*\(\s*" + count + r"\s*\)", src):
            continue
        if not re.search(r"\bfloat\s+" + accum + r"\s*=\s*0(?:\.0*)?\s*;", src):
            continue
        args = split_args(src[m.end():end])
        if len(args) != 2:
            continue
        # The loop bound guarantees a counter that is exactly representable as a float.
        replacement = ("%s = tex2D(%s, (%s) + l360_zero.x * (%s + %s)).a;\n"
                       "%s += (%s) ? 1.0 : 0.0;\n%s += (%s) ? %s : 0.0;" % (
                           m[1], args[0], args[1], accum, count,
                           count, cond, accum, cond, m[1]))
        src = src[:m.start()] + replacement + src[end_if:]
        return declaration.sub("float %s = 0.0;" % count, src, count=1)
    return src

def for_xost(src):
    """HLSL (generated, or the engine's own) -> the same, compilable with xost. Idempotent. The
    header comments stay and the others go (a parenthesis in a comment confuses functions())."""
    head = re.match(r"(\s*//[^\n]*\n)*", src).group(0)
    src = head + strip_comments(src[len(head):])
    # A bool uniform is a finite flag that the runtime sends as 0 or 1, and the translator
    # defines it as '#define NAME ((REG.x > 0.5))'. Negating that macro makes glslang emit
    # OpFUnordLessThanEqual (189), which xost 2c4599b does not list as producing a value and
    # then fails with "malformed: <SSA id>". Comparing directly avoids the opcode for 0/1.
    # Not applied to arbitrary bools: with NaN, !(x > y) is NOT x <= y.
    for flag, reg in re.findall(r"^\s*#define\s+(\w+)\s+\(\((\w+\.\w+)\s*>\s*0\.5\)\)\s*$", src, re.M):
        src = re.sub(r"!\s*%s\b" % re.escape(flag), "(%s <= 0.5)" % reg, src)
    if re.search(r"\batan2\s*\(", src):
        src = rewrite_calls(src, "atan2", lambda a: "l360_atan2(%s)" % ",".join(a), lambda a: a)
        first = functions(src)[0][0]
        src = src[:first] + L360_ATAN2 + "\n" + src[first:]
    fix_clamps = lambda t: rewrite_calls(t, "clamp", xost_clamp, fix_clamps)
    src = fix_clamps(src)
    for s, e, head, body in reversed(functions(src)):
        sts = statements(body)
        if not any(re.search(r"\breturn\b", st) for st in sts[:-1]):
            continue
        rtype = head.split()[0]
        rv = "l360_ret"
        body = "%s %s;\n%s\nreturn %s;" % (rtype, rv, single_exit(sts, rv), rv)
        src = src[:s] + head + "{\n" + body + "\n}" + src[e:]
    return xost_math(xost_sample_reduction(src))


def main():
    if len(sys.argv) != 4:
        raise SystemExit("usage: glsl2hlsl.py <name> <shader.glsl> <output folder>")
    name, path, out = sys.argv[1:]
    with open(path, encoding="utf-8-sig") as f:
        try:
            r = translate(name, f.read())
        except ShaderError as e:
            raise SystemExit("ERROR: %s" % e)
    os.makedirs(out, exist_ok=True)
    for stage in ("ps", "vs"):
        if r[stage]:
            with open(os.path.join(out, "%s_%s.hlsl" % (name, stage)), "w", encoding="utf-8", newline="\n") as f:
                f.write(r[stage])
    with open(os.path.join(out, name + ".meta.lua"), "w", encoding="utf-8", newline="\n") as f:
        f.write(meta_lua(r["meta"]))

if __name__ == "__main__":
    main()
