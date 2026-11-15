"""Small HLSL interpreter for the shader tests (from Love360's comparar_shaders.py, MIT): runs the
subset of HLSL that tools/shaders/glsl2hlsl.py generates, with given constant registers and
inputs. Shader(text).ejecutar({register: float4}, {semantic: value}) -> {semantic: value}.
It does not simulate Xenos microcode or float32 precision."""
import math
import re

# ---------------------------------------------------------------------------------------------
# Interprete de HLSL (el subconjunto que usan estos shaders)
# ---------------------------------------------------------------------------------------------

def preprocesar(src):
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.S)
    src = re.sub(r"//[^\n]*", "", src)
    defs, out, activo = {}, [], [True]
    for linea in src.split("\n"):
        s = linea.strip()
        m = re.match(r"#\s*(\w+)\s*(.*)", s)
        if m:
            d, resto = m.group(1), m.group(2).strip()
            if d in ("ifdef", "ifndef"):
                esta = resto in defs
                activo.append(activo[-1] and (esta if d == "ifdef" else not esta))
            elif d == "else":
                activo[-1] = activo[-2] and not activo[-1]
            elif d == "endif":
                activo.pop()
            elif d == "define" and activo[-1]:
                nombre, _, valor = resto.partition(" ")
                defs[nombre] = valor.strip()
            continue
        if activo[-1]:
            out.append(linea)
    texto = "\n".join(out)
    for _ in range(10):
        nuevo = re.sub(r"\b[A-Za-z_]\w*\b", lambda m: defs.get(m.group(0), m.group(0)), texto)
        if nuevo == texto:
            break
        texto = nuevo
    return texto

TOKEN = re.compile(r"\s*(?:(\d+\.\d*(?:[eE][-+]?\d+)?f?|\.\d+(?:[eE][-+]?\d+)?f?|\d+(?:[eE][-+]?\d+)?f?)"
                   r"|([A-Za-z_]\w*)|(\+\+|--|\+=|-=|\*=|/=|==|!=|<=|>=|&&|\|\||[-+*/<>=!?:;,.(){}\[\]]))")

def tokens(src):
    out, pos = [], 0
    src = src.rstrip()
    while pos < len(src):
        m = TOKEN.match(src, pos)
        if not m:
            raise SyntaxError("caracter inesperado: %r" % src[pos:pos + 20])
        if m.group(1):
            out.append(("num", float(m.group(1).rstrip("f"))))
        elif m.group(2):
            out.append(("id", m.group(2)))
        else:
            out.append(("op", m.group(3)))
        pos = m.end()
    out.append(("fin", None))
    return out

TIPOS = {"float": 1, "float2": 2, "float3": 3, "float4": 4, "int": 1, "bool": 1, "half": 1,
         "half2": 2, "half3": 3, "half4": 4, "float4x4": 16, "void": 0, "sampler2D": 0}

class Parser:
    def __init__(self, src):
        self.t, self.i = tokens(src), 0
        self.structs, self.funcs, self.globales = {}, {}, []

    def ver(self, k=0):
        return self.t[self.i + k]

    def es(self, v, k=0):
        return self.t[self.i + k][1] == v and self.t[self.i + k][0] != "num"

    def tomar(self, v=None):
        tok = self.t[self.i]
        if v is not None and tok[1] != v:
            raise SyntaxError("se esperaba %r y vino %r" % (v, tok[1]))
        self.i += 1
        return tok[1]

    def es_tipo(self, k=0):
        tok = self.ver(k)
        return tok[0] == "id" and (tok[1] in TIPOS or tok[1] in self.structs)

    def programa(self):
        while self.ver()[0] != "fin":
            if self.es("struct"):
                self.tomar(); nombre = self.tomar(); self.tomar("{")
                campos = []
                while not self.es("}"):
                    tipo = self.tomar(); campo = self.tomar(); sem = None
                    if self.es(":"):
                        self.tomar(); sem = self.tomar()
                    self.tomar(";")
                    campos.append((tipo, campo, sem))
                self.tomar("}"); self.tomar(";")
                self.structs[nombre] = campos
                continue
            mods = []
            while self.es("row_major") or self.es("uniform") or self.es("static") or self.es("const"):
                mods.append(self.tomar())
            tipo = self.tomar(); nombre = self.tomar()
            if self.es("("):
                self.tomar("(")
                params = []
                while not self.es(")"):
                    if self.es("in"):
                        self.tomar()
                    ptipo = self.tomar(); pnombre = self.tomar()
                    if self.es(":"):
                        self.tomar(); self.tomar()
                    params.append((ptipo, pnombre))
                    if self.es(","):
                        self.tomar()
                self.tomar(")")
                if self.es(":"):
                    self.tomar(); self.tomar()
                cuerpo = self.bloque()
                self.funcs.setdefault(nombre, (tipo, params, cuerpo))
                self.funcs[(nombre, tuple(p[0] for p in params))] = (tipo, params, cuerpo)
                continue
            reg = None
            if self.es(":"):
                self.tomar(); self.tomar("register"); self.tomar("("); reg = self.tomar(); self.tomar(")")
            init = None
            if self.es("="):
                self.tomar(); init = self.expr()
            self.tomar(";")
            self.globales.append((tipo, nombre, reg, init))
        return self

    def bloque(self):
        self.tomar("{")
        sts = []
        while not self.es("}"):
            sts.append(self.sentencia())
        self.tomar("}")
        return ("bloque", sts)

    def sentencia(self):
        while self.es("["):            # [branch], [flatten], [unroll], [loop]
            while not self.es("]"):
                self.tomar()
            self.tomar("]")
        if self.es("{"):
            return self.bloque()
        if self.es("if"):
            self.tomar(); self.tomar("("); c = self.expr(); self.tomar(")")
            a = self.sentencia(); b = None
            if self.es("else"):
                self.tomar(); b = self.sentencia()
            return ("if", c, a, b)
        if self.es("for"):
            self.tomar(); self.tomar("(")
            ini = self.sentencia()
            c = self.expr(); self.tomar(";")
            paso = self.expr(); self.tomar(")")
            return ("for", ini, c, paso, self.sentencia())
        if self.es("return"):
            self.tomar()
            e = None if self.es(";") else self.expr()
            self.tomar(";")
            return ("return", e)
        if self.es_tipo() and self.ver(1)[0] == "id":
            tipo = self.tomar()
            decls = []
            while True:
                nombre = self.tomar(); init = None
                if self.es("="):
                    self.tomar(); init = self.asignacion()
                decls.append((nombre, init))
                if not self.es(","):
                    break
                self.tomar()
            self.tomar(";")
            return ("decl", tipo, decls)
        e = self.expr(); self.tomar(";")
        return ("expr", e)

    def expr(self):
        e = self.asignacion()
        while self.es(","):
            self.tomar(); e = ("coma", e, self.asignacion())
        return e

    def asignacion(self):
        izq = self.ternario()
        if self.ver()[0] == "op" and self.ver()[1] in ("=", "+=", "-=", "*=", "/="):
            op = self.tomar()
            return ("asig", op, izq, self.asignacion())
        return izq

    def ternario(self):
        c = self.binario(0)
        if self.es("?"):
            self.tomar(); a = self.asignacion(); self.tomar(":"); b = self.asignacion()
            return ("tern", c, a, b)
        return c

    NIVELES = [("||",), ("&&",), ("==", "!="), ("<", ">", "<=", ">="), ("+", "-"), ("*", "/")]

    def binario(self, n):
        if n == len(self.NIVELES):
            return self.unario()
        e = self.binario(n + 1)
        while self.ver()[0] == "op" and self.ver()[1] in self.NIVELES[n]:
            op = self.tomar()
            e = ("bin", op, e, self.binario(n + 1))
        return e

    def unario(self):
        if self.ver()[0] == "op" and self.ver()[1] in ("-", "+", "!"):
            op = self.tomar()
            return ("un", op, self.unario())
        if self.ver()[0] == "op" and self.ver()[1] in ("++", "--"):
            op = self.tomar()
            return ("pre", op, self.unario())
        if self.es("(") and self.es_tipo(1) and self.es(")", 2):
            self.tomar(); tipo = self.tomar(); self.tomar(")")
            return ("cast", tipo, self.unario())
        return self.postfijo()

    def postfijo(self):
        e = self.primario()
        while True:
            if self.es("."):
                self.tomar(); e = ("campo", e, self.tomar())
            elif self.es("["):
                self.tomar(); i = self.expr(); self.tomar("]"); e = ("indice", e, i)
            elif self.ver()[0] == "op" and self.ver()[1] in ("++", "--"):
                e = ("post", self.tomar(), e)
            else:
                return e

    def primario(self):
        tok = self.ver()
        if tok[0] == "num":
            self.tomar(); return ("num", tok[1])
        if self.es("("):
            self.tomar(); e = self.expr(); self.tomar(")")
            return e
        if tok[0] == "id":
            nombre = self.tomar()
            if nombre in ("true", "false"):
                return ("num", nombre == "true")
            if self.es("("):
                self.tomar()
                args = []
                while not self.es(")"):
                    args.append(self.asignacion())
                    if self.es(","):
                        self.tomar()
                self.tomar(")")
                return ("llamada", nombre, args)
            return ("var", nombre)
        raise SyntaxError("expresion inesperada: %r" % (tok,))

class Retorno(Exception):
    def __init__(self, valor):
        self.valor = valor

def comps(v):
    return v if isinstance(v, tuple) else (v,)

def vmap(f, *args):
    n = max(len(a) if isinstance(a, tuple) else 1 for a in args)
    if n == 1 and not any(isinstance(a, tuple) for a in args):
        return f(*args)
    cols = [a if isinstance(a, tuple) else (a,) * n for a in args]
    if any(len(c) != n for c in cols):
        n = min(len(c) for c in cols)      # HLSL trunca al vector mas corto
        cols = [c[:n] for c in cols]
    return tuple(f(*x) for x in zip(*cols))

def div(a, b):
    try:
        return a / b
    except ZeroDivisionError:
        return math.copysign(math.inf, a) if a else math.nan

def construir(n, args):
    plano = []
    for a in args:
        plano.extend(comps(a))
    plano = [float(x) for x in plano]
    if len(plano) == 1 and n > 1:
        plano = plano * n
    return plano[0] if n == 1 else tuple(plano[:n])

SWZ = {"x": 0, "y": 1, "z": 2, "w": 3, "r": 0, "g": 1, "b": 2, "a": 3}

def textura(uv):
    """textura falsa: suave, con valores en todo [0, 1] (alpha tambien cerca de 0)"""
    u, v = uv[0], uv[1]
    return (0.5 + 0.5 * math.sin(12.9 * u + 3.1 * v), 0.5 + 0.5 * math.cos(7.3 * u - 5.7 * v),
            (u * 3.7 + v * 1.3) % 1.0, 0.5 + 0.5 * math.sin(4.0 * u + 9.0 * v))

def smoothstep(a, b, x):
    t = min(1.0, max(0.0, div(x - a, b - a)))
    return t * t * (3.0 - 2.0 * t)

def glsl_mod(x, y):
    return x - y * math.floor(div(x, y))

def fmod_c(x, y):
    return math.fmod(x, y) if y else math.nan

def longitud(v):
    return math.sqrt(sum(x * x for x in comps(v)))

INTRINSECOS = {
    "sin": lambda a: vmap(math.sin, a), "cos": lambda a: vmap(math.cos, a),
    "tan": lambda a: vmap(math.tan, a), "abs": lambda a: vmap(abs, a),
    "floor": lambda a: vmap(math.floor, a), "ceil": lambda a: vmap(math.ceil, a),
    "frac": lambda a: vmap(lambda x: x - math.floor(x), a),
    "sqrt": lambda a: vmap(lambda x: math.sqrt(x) if x >= 0 else math.nan, a),
    "rsqrt": lambda a: vmap(lambda x: div(1.0, math.sqrt(x)) if x >= 0 else math.nan, a),
    "exp": lambda a: vmap(math.exp, a),
    "atan": lambda a: vmap(math.atan, a), "atan2": lambda a, b: vmap(math.atan2, a, b),
    "min": lambda a, b: vmap(min, a, b), "max": lambda a, b: vmap(max, a, b),
    "clamp": lambda x, a, b: vmap(lambda x, a, b: min(max(x, a), b), x, a, b),
    "saturate": lambda x: vmap(lambda x: min(max(x, 0.0), 1.0), x),
    "lerp": lambda a, b, t: vmap(lambda a, b, t: a + (b - a) * t, a, b, t),
    "smoothstep": lambda a, b, x: vmap(smoothstep, a, b, x),
    "step": lambda a, x: vmap(lambda a, x: 1.0 if x >= a else 0.0, a, x),
    "pow": lambda a, b: vmap(lambda a, b: math.pow(a, b) if a > 0 else (0.0 if a == 0 else math.nan), a, b),
    "fmod": lambda a, b: vmap(fmod_c, a, b),
    "length": longitud,
    "dot": lambda a, b: sum(x * y for x, y in zip(comps(a), comps(b))),
    "normalize": lambda a: vmap(lambda x: div(x, longitud(a)), a),
    "tex2D": lambda s, uv: textura(uv),
    "mul": lambda m, v: tuple(sum(m[f][c] * v[c] for c in range(4)) for f in range(4)),
}

class Shader:
    def __init__(self, texto, xost=False):
        self.p = Parser(preprocesar(texto)).programa()
        self.xost = xost

    def defecto(self, tipo):
        if tipo in self.p.structs:
            return {campo: self.defecto(t) for t, campo, _ in self.p.structs[tipo]}
        n = TIPOS.get(tipo, 1)
        return 0.0 if n == 1 else tuple([0.0] * n)

    def ejecutar(self, regs, entradas):
        """regs: {indice: float4}; entradas: {semantica: valor} -> salida como {semantica: valor}"""
        self.glob = {}
        for tipo, nombre, reg, init in self.p.globales:
            if reg and reg[0] == "c":
                n = int(reg[1:])
                if tipo == "float4x4":
                    self.glob[nombre] = tuple(tuple(regs.get(n + k, (0.0,) * 4)) for k in range(4))
                else:
                    v = tuple(regs.get(n, (0.0,) * 4))
                    self.glob[nombre] = construir(TIPOS[tipo], [v])
            elif tipo == "sampler2D":
                self.glob[nombre] = nombre
            elif init is not None:
                self.glob[nombre] = self.ev(init, [self.glob])
        tipo, params, _ = self.p.funcs["main"]
        st = params[0][0]
        arg = {campo: construir(TIPOS[t], [entradas[sem]]) for t, campo, sem in self.p.structs[st]}
        r = self.llamar("main", [arg])
        if isinstance(r, dict):
            sems = {campo: sem for _, campo, sem in self.p.structs[tipo]}
            return {sems[c]: v for c, v in r.items()}
        return {"COLOR": r}

    def llamar(self, nombre, args):
        tipos = tuple("float%d" % len(a) if isinstance(a, tuple) else "float" for a in args)
        tipo, params, cuerpo = self.p.funcs.get((nombre, tipos), self.p.funcs[nombre])
        env = {}
        for (pt, pn), a in zip(params, args):
            env[pn] = construir(TIPOS[pt], [a]) if pt in TIPOS and TIPOS[pt] else a
        try:
            self.ej(cuerpo, [self.glob, env])
        except Retorno as r:
            v = r.valor
            return construir(TIPOS[tipo], [v]) if tipo in TIPOS and TIPOS[tipo] in (1, 2, 3, 4) else v
        return None

    def ej(self, s, scopes):
        k = s[0]
        if k == "bloque":
            scopes = scopes + [{}]
            for x in s[1]:
                self.ej(x, scopes)
        elif k == "decl":
            for nombre, init in s[2]:
                v = self.defecto(s[1]) if init is None else self.ev(init, scopes)
                if s[1] in TIPOS and TIPOS[s[1]] in (1, 2, 3, 4):
                    v = construir(TIPOS[s[1]], [v]) if s[1] != "bool" else v
                scopes[-1][nombre] = v
        elif k == "expr":
            self.ev(s[1], scopes)
        elif k == "if":
            if self.ev(s[1], scopes):
                self.ej(s[2], scopes + [{}])
            elif s[3] is not None:
                self.ej(s[3], scopes + [{}])
        elif k == "for":
            scopes = scopes + [{}]
            self.ej(s[1], scopes)
            while self.ev(s[2], scopes):
                self.ej(s[4], scopes + [{}])
                self.ev(s[3], scopes)
        elif k == "return":
            raise Retorno(None if s[1] is None else self.ev(s[1], scopes))

    def buscar(self, nombre, scopes):
        for sc in reversed(scopes):
            if nombre in sc:
                return sc
        raise NameError(nombre)

    def guardar(self, nodo, v, scopes):
        if nodo[0] == "var":
            self.buscar(nodo[1], scopes)[nodo[1]] = v
        elif nodo[0] == "indice":
            base = list(self.ev(nodo[1], scopes))
            base[int(self.ev(nodo[2], scopes))] = v
            self.guardar(nodo[1], tuple(base), scopes)
        elif nodo[0] == "campo":
            base = self.ev(nodo[1], scopes)
            if isinstance(base, dict):
                base = dict(base); base[nodo[2]] = v
            else:
                lista = list(comps(base))
                for c, x in zip(nodo[2], comps(v) * (len(nodo[2]) if not isinstance(v, tuple) else 1)):
                    lista[SWZ[c]] = x
                base = tuple(lista) if isinstance(base, tuple) else lista[0]
            self.guardar(nodo[1], base, scopes)
        else:
            raise SyntaxError("no se puede asignar a %r" % (nodo,))

    BIN = {"+": lambda a, b: a + b, "-": lambda a, b: a - b, "*": lambda a, b: a * b, "/": div,
           "<": lambda a, b: a < b, ">": lambda a, b: a > b, "<=": lambda a, b: a <= b,
           ">=": lambda a, b: a >= b, "==": lambda a, b: a == b, "!=": lambda a, b: a != b}

    def ev(self, e, scopes):
        k = e[0]
        if k == "num":
            return e[1]
        if k == "var":
            return self.buscar(e[1], scopes)[e[1]]
        if k == "indice":
            return self.ev(e[1], scopes)[int(self.ev(e[2], scopes))]
        if k == "campo":
            base = self.ev(e[1], scopes)
            if isinstance(base, dict):
                return base[e[2]]
            c = comps(base)
            r = tuple(float(c[SWZ[ch]]) for ch in e[2])
            return r[0] if len(r) == 1 else r
        if k == "bin":
            if e[1] == "&&":
                return bool(self.ev(e[2], scopes)) and bool(self.ev(e[3], scopes))
            if e[1] == "||":
                return bool(self.ev(e[2], scopes)) or bool(self.ev(e[3], scopes))
            return vmap(self.BIN[e[1]], self.ev(e[2], scopes), self.ev(e[3], scopes))
        if k == "un":
            v = self.ev(e[2], scopes)
            if e[1] == "!":
                return not v
            return vmap(lambda x: -x, v) if e[1] == "-" else v
        if k == "tern":
            return self.ev(e[2], scopes) if self.ev(e[1], scopes) else self.ev(e[3], scopes)
        if k == "cast":
            v = self.ev(e[2], scopes)
            if e[1] == "bool":
                return bool(v)
            return construir(TIPOS[e[1]], [v])
        if k == "asig":
            v = self.ev(e[3], scopes)
            if e[1] != "=":
                v = vmap(self.BIN[e[1][0]], self.ev(e[2], scopes), v)
            self.guardar(e[2], v, scopes)
            return v
        if k in ("pre", "post"):
            viejo = self.ev(e[2] if k == "pre" else e[2], scopes)
            nodo = e[2]
            nuevo = viejo + (1 if e[1] == "++" else -1)
            self.guardar(nodo, nuevo, scopes)
            return nuevo if k == "pre" else viejo
        if k == "coma":
            self.ev(e[1], scopes)
            return self.ev(e[2], scopes)
        if k == "llamada":
            nombre, args = e[1], [self.ev(a, scopes) for a in e[2]]
            if nombre in TIPOS and TIPOS[nombre] in (1, 2, 3, 4):
                return construir(TIPOS[nombre], args)
            if nombre in self.p.funcs:
                return self.llamar(nombre, args)
            if nombre == "glsl_mod":
                return vmap(glsl_mod, *args)
            if self.xost and nombre in ("sin", "cos", "atan"):
                limite = 1.0 if nombre == "atan" else math.pi + 1e-7
                if any(not math.isfinite(x) or abs(x) > limite for x in comps(args[0])):
                    raise ValueError("xost: %s recibe argumento fuera de rango: %r" % (nombre, args[0]))
            return INTRINSECOS[nombre](*args)
        raise SyntaxError("nodo desconocido %r" % (k,))

