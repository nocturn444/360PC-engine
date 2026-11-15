"""Translator tests, without a game, Windows or the xost compiler:
python3 -m unittest discover -s tests/shaders -v   (from the repository root)"""
import random
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/shaders"))
sys.path.insert(0, str(Path(__file__).resolve().parent))
import glsl2hlsl as g
import hlsl_interp as c

HERE = Path(__file__).resolve().parent
TINT = ROOT / "tests/fixtures/minimal_game/shaders/tint.glsl"

BOTH = """
#pragma language glsl3
#ifdef GL_ES
precision mediump float;
#endif
extern number time;
extern bool flip;
extern vec2 pts[3];
extern mat3 rot;
extern Image mask;
extern vec3 unused;
#ifdef VERTEX
extern number wobble;
vec4 position(mat4 transform_projection, vec4 vertex_position)
{
    vertex_position.x += sin(time * 40.0) * wobble;
    return transform_projection * vertex_position;
}
#endif
#ifdef PIXEL
float wave(vec2 p) { if (p.x < 0.0) return 0.0; return mod(p.x + time, 2.0); }
vec4 effect(vec4 color, Image texture, vec2 uv, vec2 sc)
{
    vec4 c = Texel(texture, uv) * Texel(mask, uv).a;
    if (!flip) { c.rgb = rot * c.rgb; }
    c.r += wave(pts[1] + pts[2].yx) + atan(uv.y, uv.x) + clamp(uv.x, 0.0, time);
    return c * color * vec4(sc / love_ScreenSize.xy, 1.0, 1.0);
}
#endif
"""


class XostRules(unittest.TestCase):
    """The rules applied to HLSL for xost (from Love360's test_reglas.py)."""

    def test_finite_mask(self):
        src = (HERE / "mask_min_ps.hlsl").read_text()
        fixed = g.for_xost(src)
        self.assertNotIn("!shadow", fixed)
        shaders = c.Shader(src), c.Shader(fixed)
        rng = random.Random(360)
        for flag in [0, 1, 0.5, 0.4999, 0.5001]:
            for _ in range(400):
                regs = {0: (rng.random(), rng.random(), flag, 0),
                        1: tuple(rng.random() for _ in range(4))}
                entry = {"TEXCOORD0": (rng.random(), rng.random())}
                self.assertEqual(shaders[0].ejecutar(regs, entry), shaders[1].ejecutar(regs, entry))

    def test_arbitrary_bools_are_left_alone(self):
        src = "bool shadow; float main() { return !shadow ? 1.0 : 0.0; }"
        self.assertIn("!shadow", g.for_xost(src))

    def test_idempotent(self):
        src = (HERE / "mask_min_ps.hlsl").read_text()
        fixed = g.for_xost(src)
        self.assertEqual(fixed, g.for_xost(fixed))

    def test_atan2(self):
        src = "float main(float x) { return atan2(x, 0.5); }"
        fixed = g.for_xost(src)
        self.assertIn("float l360_atan2", fixed)
        self.assertNotIn("return atan2(", fixed)

    def test_reduction_keeps_samples(self):
        src = (HERE / "reduction_min_ps.hlsl").read_text()
        fixed = g.for_xost(src)
        self.assertIn("float cantidad = 0.0;", fixed)
        self.assertIn("l360_zero.x * (suma + cantidad)", fixed)
        self.assertEqual(fixed, g.for_xost(fixed))
        before, after = c.Shader(src), c.Shader(fixed)
        rng = random.Random(81)
        for _ in range(200):
            inputs = {"TEXCOORD0": (rng.random(), rng.random())}
            self.assertEqual(before.ejecutar({7: (0, 0, 0, 0)}, inputs),
                             after.ejecutar({7: (0, 0, 0, 0)}, inputs))

    def test_reduction_rejects_counter_with_other_uses(self):
        src = (HERE / "reduction_min_ps.hlsl").read_text()
        src = src.replace("return float4", "cantidad += 3; return float4")
        self.assertNotIn("float cantidad = 0.0;", g.for_xost(src))

    def test_reduction_without_the_zero_is_not_rewritten(self):
        src = (HERE / "reduction_min_ps.hlsl").read_text()
        self.assertNotIn("float cantidad = 0.0;", g.for_xost(src.replace("l360_zero", "other")))

    def test_engine_shaders_are_stable(self):
        for path in sorted((ROOT / "runtime/shaders").glob("*.hlsl")):
            fixed = g.for_xost(path.read_text())
            self.assertEqual(fixed, g.for_xost(fixed), path.name)
            self.assertIn("main(", fixed)


class Translate(unittest.TestCase):
    """GLSL (LÖVE) -> HLSL and the metadata."""

    def test_tint(self):
        r = g.translate("tint", TINT.read_text())
        self.assertIsNone(r["vs"])
        meta = r["meta"]
        self.assertEqual((meta["ps"], meta["vs"], meta["ps_regs"], meta["vs_regs"]),
                         ("tint.psu", "l360_love.vsu", 2, 0))
        self.assertEqual(meta["uniforms"]["tint"], {"type": "vec4", "comps": 4, "rows": 1, "count": 1, "ps": 8})
        self.assertEqual(meta["uniforms"]["amount"], {"type": "float", "comps": 1, "rows": 1, "count": 1, "ps": 9})
        self.assertEqual(r["ps"], g.for_xost(r["ps"]))
        # the HLSL computes what the GLSL says, with the uniforms at the registers of the metadata
        shader, rng = c.Shader(r["ps"]), random.Random(3)
        for _ in range(200):
            tint = tuple(rng.random() for _ in range(4))
            amount, colour = rng.random(), tuple(rng.random() for _ in range(4))
            uv = (rng.random(), rng.random())
            out = shader.ejecutar({6: (1280, 720, 0, 0), 7: (0, 0, 0, 0), 8: tint, 9: (amount, 0, 0, 0)},
                                  {"TEXCOORD0": uv, "COLOR0": colour, "TEXCOORD1": (10.0, 20.0)})["COLOR"]
            pixel = [t * k for t, k in zip(c.textura(uv), colour)]
            want = [p + (p * t - p) * amount for p, t in zip(pixel[:3], tint)] + [pixel[3]]
            for a, b in zip(out, want):
                self.assertAlmostEqual(a, b, places=9)

    def test_both_stages(self):
        r = g.translate("both", BOTH)
        u = r["meta"]["uniforms"]
        self.assertEqual((u["time"]["ps"], u["time"]["vs"]), (8, 5))
        self.assertEqual(u["flip"]["ps"], 9)
        self.assertEqual((u["pts"]["ps"], u["pts"]["count"]), (10, 3))
        self.assertEqual((u["rot"]["ps"], u["rot"]["rows"]), (13, 3))
        self.assertEqual(u["mask"]["sampler"], 1)
        self.assertEqual(u["wobble"], {"type": "float", "comps": 1, "rows": 1, "count": 1, "vs": 6})
        self.assertNotIn("ps", u["unused"])              # declared, not used: known, without a register
        self.assertNotIn("vs", u["unused"])
        self.assertEqual((r["meta"]["ps_regs"], r["meta"]["vs_regs"]), (8, 2))
        self.assertEqual((r["meta"]["ps"], r["meta"]["vs"]), ("both.psu", "both.vsu"))
        ps, vs = r["ps"], r["vs"]
        self.assertIn("sampler2D mask : register(s1);", ps)
        self.assertIn("float4 l360_a_pts[3] : register(c10);", ps)
        self.assertIn("(l360_a_pts[2].xy).yx", ps)
        self.assertIn("mul(rot, c.rgb)", ps)
        self.assertIn("(l360_p9.x <= 0.5)", ps)           # !flip, without the unordered comparison
        self.assertIn("tex2D(l360_tex0, uv)", ps)
        self.assertIn("l360_atan2(uv.y, uv.x)", ps)
        self.assertIn("min(max(uv.x, 0.0), time)", ps)
        self.assertIn("l360_ret", ps)                     # wave(): a single exit
        self.assertNotIn("position", ps)
        self.assertNotIn("wobble", ps)
        self.assertIn("mul(transform_projection, vertex_position)", vs)
        self.assertIn("sin(l360_angle(time * 40.0))", vs)
        self.assertIn("row_major float4x4 transform_projection : register(c0);", vs)
        self.assertNotIn("effect", vs)
        for text in (ps, vs):
            self.assertEqual(text, g.for_xost(text))
            for word in ("vec2", "vec4", "extern", "Texel", "precision", "#pragma", "GL_ES"):
                self.assertNotIn(word, text)

    def test_vertex_only_and_two_files(self):
        vertex = "vec4 position(mat4 tp, vec4 v) { return tp * v; }"
        r = g.translate("v", vertex)
        self.assertIsNone(r["ps"])
        self.assertEqual((r["meta"]["ps"], r["meta"]["vs"]), ("l360_love.psu", "v.vsu"))
        r = g.translate("two", TINT.read_text(), vertex)
        self.assertEqual((r["meta"]["ps"], r["meta"]["vs"]), ("two.psu", "two.vsu"))
        self.assertIn("mul(tp, v)", r["vs"])

    def test_meta_lua(self):
        text = g.meta_lua(g.translate("both", BOTH)["meta"])
        self.assertIn('time = { type = "float", comps = 1, rows = 1, count = 1, ps = 8, vs = 5 },', text)
        self.assertIn('mask = { type = "Image", comps = 0, rows = 0, count = 1, sampler = 1 },', text)
        with tempfile.TemporaryDirectory() as tmp:        # it is the Lua the runtime loads
            (Path(tmp) / "m.lua").write_text(text)
            (Path(tmp) / "check.lua").write_text(
                "local m = dofile(arg[1]) "
                "assert(m.version == 1 and m.name == 'both' and m.ps == 'both.psu' and m.vs_regs == 2) "
                "assert(m.uniforms.rot.ps == 13 and m.uniforms.unused.ps == nil) print('ok')")
            try:
                out = subprocess.run(["luajit", str(Path(tmp) / "check.lua"), str(Path(tmp) / "m.lua")],
                                     capture_output=True, text=True, stdin=subprocess.DEVNULL)
            except FileNotFoundError:
                self.skipTest("luajit not installed")
            self.assertEqual(out.stdout.strip(), "ok", out.stderr)

    def test_errors(self):
        effect = "vec4 effect(vec4 c, Image t, vec2 uv, vec2 sc) { %s return c; }"
        bad = {
            "no effect or position": "float f(float x) { return x; }",
            "effect signature": "vec4 effect(vec4 c, Image t, vec2 uv) { return c; }",
            "unsupported uniform type": "extern ivec2 n;\n" + effect % "",
            "array of images": "extern Image t2[2];\n" + effect % "",
            "love_PixelCoord": effect % "c.r = love_PixelCoord.x;",
            "VaryingColor": effect % "c = VaryingColor;",
            "too many registers": "extern vec4 big[33];\n" + effect % "c = big[0];",
            "too many images": "extern Image a; extern Image b; extern Image d; extern Image e;\n"
                               + effect % "c = Texel(a, uv) + Texel(b, uv) + Texel(d, uv) + Texel(e, uv);",
            "array not indexed": "extern vec4 arr[2];\n" + effect % "c = f(arr);",
            "vector times matrix": "extern mat4 m;\n" + effect % "c = c * m;",
            "unsupported #if": "#if VERSION > 2\n#endif\n" + effect % "",
            "unbalanced #if": "#ifdef PIXEL\n" + effect % "",
        }
        for what, src in bad.items():
            with self.assertRaises(g.ShaderError, msg=what):
                g.translate("x", src)
        for name in ("l360_x", "1x", "a-b", "", "x" * 25):
            with self.assertRaises(g.ShaderError, msg=name):
                g.translate(name, effect % "")

    def test_build_hlsl_only(self):
        with tempfile.TemporaryDirectory() as tmp:
            r = subprocess.run([sys.executable, str(ROOT / "tools/shaders/build_shaders.py"),
                                "--shader", "tint=shaders/tint.glsl", "--base",
                                str(ROOT / "tests/fixtures/minimal_game"), "--out", tmp, "--hlsl-only"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 0, r.stderr)
            self.assertEqual(sorted(p.name for p in Path(tmp).iterdir()), ["tint.meta.lua", "tint_ps.hlsl"])
            r = subprocess.run([sys.executable, str(ROOT / "tools/shaders/build_shaders.py"),
                                "--shader", "tint=shaders/missing.glsl", "--base",
                                str(ROOT / "tests/fixtures/minimal_game"), "--out", tmp + "/x", "--hlsl-only"],
                               capture_output=True, text=True)
            self.assertEqual(r.returncode, 1)
            self.assertFalse((Path(tmp) / "x").exists())


if __name__ == "__main__":
    unittest.main()
