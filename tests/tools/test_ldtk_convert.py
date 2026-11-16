# tools/ldtk_convert.py: the mapping of the LDtk fixture (tests/fixtures/ldtk), the inferred
# values, the errors (with the level's name) and the output text.
# python3 -m unittest discover -s tests/tools
import contextlib
import copy
import io
import json
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools"))
import ldtk_convert  # noqa: E402

FIXTURES = ROOT / "tests" / "fixtures" / "ldtk"


def options(*args):
    values = dict(cell=None, root=None, collision="Collision", exit="Exit", item="Item")
    values.update(dict(args))
    return ldtk_convert.argparse.Namespace(**values)


class LdtkConvertTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.project = json.loads((FIXTURES / "world.ldtk").read_text(encoding="utf-8"))
        self.warnings = []

    def convert(self, project=None, **opts):
        """Converts the fixture, or a changed copy of it written to the temporary folder."""
        path = FIXTURES / "world.ldtk"
        if project is not None:
            path = self.tmp / "world.ldtk"
            path.write_text(json.dumps(project), encoding="utf-8")
        return ldtk_convert.convert(path, options(*opts.items()), self.warnings.append)

    def level(self, name):
        return next(l for l in self.project["levels"] if l["identifier"] == name)

    def layer(self, level, name):
        return next(l for l in self.level(level)["layerInstances"] if l["__identifier"] == name)

    def fails(self, pattern, **opts):
        with self.assertRaises(ldtk_convert.ConvertError) as cm:
            self.convert(self.project, **opts)
        self.assertIn(pattern, str(cm.exception))
        return str(cm.exception)

    # -----------------------------------------------------------------------------------------
    def test_top_level(self):
        data = self.convert()
        self.assertEqual(data["format"], "360pc-level")
        self.assertEqual(data["version"], 1)
        self.assertEqual(data["ldtk_version"], "1.5.3")
        self.assertEqual(data["tile_size"], 16)
        self.assertEqual(data["cell"], {"w": 10, "h": 6})      # the smallest level
        self.assertEqual([r["id"] for r in data["rooms"]], ["Start", "Hall", "Well", "Treasure", "Boss"])
        # only the tileset some layer uses, with its path from the game folder
        self.assertEqual(data["tilesets"], [{"path": "assets/tiles.png", "tile_size": 16, "w": 64, "h": 32}])
        self.assertTrue(any("water" in w for w in self.warnings))

    def test_rooms(self):
        rooms = {r["id"]: r for r in self.convert()["rooms"]}
        hall, boss, start = rooms["Hall"], rooms["Boss"], rooms["Start"]
        self.assertEqual((hall["w"], hall["h"], hall["tiles_w"], hall["tiles_h"]), (2, 1, 20, 6))
        self.assertEqual((boss["w"], boss["h"]), (2, 2))
        self.assertEqual((start["type"], boss["type"], hall["type"]), ("start", "boss", "normal"))
        self.assertEqual((hall["weight"], start["weight"]), (3, 1))
        self.assertEqual(hall["tags"], ["wide", "crossroad"])
        self.assertEqual(hall["fields"], {"music": "cave", "dark": False})     # type / weight / tags are not repeated
        self.assertEqual(start["fields"], {})

    def test_collision(self):
        rooms = {r["id"]: r for r in self.convert()["rooms"]}
        c = rooms["Hall"]["collision"]
        self.assertEqual(len(c), 120)
        self.assertEqual(c[:20], [1] * 14 + [0] + [1] * 5)
        self.assertEqual(c[3 * 20:4 * 20], [1] + [0] * 11 + [2] * 5 + [0, 0, 1])
        self.assertEqual(set(rooms["Well"]["collision"]), {0, 1})              # "water" is not a collision

    def test_collision_aliases(self):
        values = self.project["defs"]["layers"][1]["intGridValues"]
        values[0]["identifier"], values[1]["identifier"], values[2]["identifier"] = "Walls", "PLATFORM", None
        rooms = {r["id"]: r for r in self.convert(self.project)["rooms"]}
        self.assertEqual(rooms["Hall"]["collision"][3 * 20 + 12], 2)
        self.assertEqual(rooms["Hall"]["collision"][0], 1)
        # without identifiers: 1 is solid, 2 is one-way
        values[0]["identifier"] = values[1]["identifier"] = None
        again = {r["id"]: r for r in self.convert(self.project)["rooms"]}
        self.assertEqual(again["Hall"]["collision"], rooms["Hall"]["collision"])

    def test_exits(self):
        rooms = {r["id"]: r for r in self.convert()["rooms"]}

        def exits(name):
            return [(e["side"], e["offset"], e["tx"], e["ty"], e["requires"]) for e in rooms[name]["exits"]]
        self.assertEqual(exits("Start"), [("left", 0, 1, 5, []), ("right", 0, 10, 5, [])])
        # sorted by side then offset, whatever the order in the project; a two-tile door; requires
        self.assertEqual(exits("Hall"), [("left", 0, 1, 5, []), ("right", 0, 20, 5, []),
                                         ("up", 1, 15, 1, ["double_jump"])])
        self.assertEqual(exits("Well"), [("right", 0, 10, 5, []), ("down", 0, 5, 6, [])])
        self.assertEqual(exits("Boss"), [("left", 1, 1, 11, [])])              # an explicit side field

    def test_exit_side_field_wins(self):
        ent = self.layer("Start", "Entities")["entityInstances"][0]
        ent["fieldInstances"] = [{"__identifier": "side", "__type": "String", "__value": "Top"},
                                 {"__identifier": "requires", "__type": "String", "__value": "dash"},
                                 {"__identifier": "locked", "__type": "Bool", "__value": True}]
        start = self.convert(self.project)["rooms"][0]
        up = [e for e in start["exits"] if e["side"] == "up"][0]
        self.assertEqual((up["offset"], up["requires"], up["fields"]), (0, ["dash"], {"locked": True}))

    def test_items_and_entities(self):
        rooms = {r["id"]: r for r in self.convert()["rooms"]}
        self.assertEqual(rooms["Treasure"]["item"], {"tx": 6, "ty": 2, "fields": {"pedestal": True}})
        self.assertNotIn("item", rooms["Start"])
        self.assertEqual(rooms["Treasure"]["entities"], [])
        enemy = rooms["Start"]["entities"][0]
        self.assertEqual({k: enemy[k] for k in ("name", "iid", "x", "y", "w", "h", "tx", "ty")},
                         {"name": "Enemy", "iid": "enemy-start-1", "x": 80, "y": 64, "w": 16, "h": 16, "tx": 6, "ty": 5})
        self.assertEqual(enemy["fields"]["hp"], 3)
        self.assertEqual(enemy["fields"]["patrol"], [{"cx": 3, "cy": 4}, {"cx": 7, "cy": 4}])
        big = rooms["Boss"]["entities"][0]                                     # pivot at the bottom centre
        self.assertEqual((big["x"], big["y"], big["w"], big["h"]), (152, 144, 32, 32))

    def test_layers(self):
        rooms = {r["id"]: r for r in self.convert()["rooms"]}
        layers = rooms["Start"]["layers"]
        self.assertEqual([l["name"] for l in layers], ["Background", "Collision"])       # bottom to top
        self.assertEqual(layers[0]["tileset"], 1)
        self.assertEqual(layers[0]["tiles"], [16, 16, 0, 16, 0, 32, 16, 16, 16, 1, 48, 16, 32, 16, 2, 64, 16, 48, 16, 3])
        self.assertEqual(layers[1]["tiles"][10:], [32, 80, 16, 0, 1])                    # auto-layer tiles
        self.assertEqual([l["name"] for l in rooms["Well"]["layers"]], ["Collision"])    # empty layers are left out

    def test_layer_offset(self):
        layer = self.layer("Start", "Background")
        layer["__pxTotalOffsetX"], layer["__pxTotalOffsetY"] = 4, -2
        tiles = self.convert(self.project)["rooms"][0]["layers"][0]["tiles"]
        self.assertEqual(tiles[:5], [20, 14, 0, 16, 0])

    def test_cell_option(self):
        data = self.convert(cell="10x3")
        self.assertEqual(data["cell"], {"w": 10, "h": 3})
        rooms = {r["id"]: r for r in data["rooms"]}
        self.assertEqual((rooms["Start"]["h"], rooms["Boss"]["h"]), (2, 4))
        self.assertEqual([(e["side"], e["offset"]) for e in rooms["Start"]["exits"]], [("left", 1), ("right", 1)])

    def test_other_names(self):
        for level in self.project["levels"]:
            for layer in level["layerInstances"]:
                if layer["__identifier"] == "Collision":
                    layer["__identifier"] = "Walls"
                for ent in layer["entityInstances"]:
                    ent["__identifier"] = {"Exit": "Door", "Item": "Relic"}.get(ent["__identifier"], ent["__identifier"])
        self.project["defs"]["layers"][1]["identifier"] = "Walls"
        rooms = {r["id"]: r for r in self.convert(self.project, collision="walls", exit="Door", item="Relic")["rooms"]}
        self.assertEqual(len(rooms["Hall"]["exits"]), 3)
        self.assertIn("item", rooms["Treasure"])
        self.assertEqual(rooms["Hall"]["collision"][0], 1)
        # with the default names nothing matches: doors and relics are plain entities, no collisions
        plain = {r["id"]: r for r in self.convert(self.project)["rooms"]}
        self.assertEqual(plain["Hall"]["exits"], [])
        self.assertEqual(set(plain["Hall"]["collision"]), {0})
        self.assertTrue(any("no IntGrid layer named Collision" in w for w in self.warnings))

    def test_tileset_paths(self):
        game = self.tmp / "game"
        (game / "levels").mkdir(parents=True)
        self.project["defs"]["tilesets"][1]["relPath"] = "../assets\\tiles.png"
        path = game / "levels" / "world.ldtk"
        path.write_text(json.dumps(self.project), encoding="utf-8")
        data = ldtk_convert.convert(path, options(("root", str(game))))
        self.assertEqual(data["tilesets"][0]["path"], "assets/tiles.png")
        with self.assertRaises(ldtk_convert.ConvertError) as cm:      # default root: the project's folder
            ldtk_convert.convert(path, options())
        self.assertIn("outside the game folder", str(cm.exception))
        self.project["defs"]["tilesets"][1]["relPath"] = "tiles.gif"
        self.fails("not a .png file")

    def test_external_levels(self):
        data = ldtk_convert.convert(FIXTURES / "external.ldtk", options())
        self.assertEqual([r["id"] for r in data["rooms"]], ["Vault"])
        room = data["rooms"][0]
        self.assertEqual((room["type"], len(room["exits"]), sum(room["collision"])), ("shop", 2, 26))
        shutil.copy(FIXTURES / "external.ldtk", self.tmp / "external.ldtk")
        with self.assertRaises(ldtk_convert.ConvertError) as cm:
            ldtk_convert.convert(self.tmp / "external.ldtk", options())
        self.assertIn("level Vault", str(cm.exception))
        self.assertIn("Vault.ldtkl", str(cm.exception))

    # -----------------------------------------------------------------------------------------
    def test_errors_name_the_level(self):
        self.level("Hall")["pxWid"] = 304
        self.assertIn("not a multiple of the map cell", self.fails("level Hall"))

    def test_error_cell(self):
        self.fails("level Start", cell="20x6")
        self.fails("--cell is WxH", cell="big")

    def test_error_exit_not_on_border(self):
        ent = self.layer("Start", "Entities")["entityInstances"][0]
        ent["px"] = [64, 48]
        self.assertIn("not on a border", self.fails("level Start"))

    def test_error_exit_in_a_corner(self):
        ent = self.layer("Start", "Entities")["entityInstances"][0]
        ent["px"] = [0, 0]
        self.assertIn("give it a side field", self.fails("level Start"))

    def test_error_two_exits_in_one_cell_side(self):
        ents = self.layer("Start", "Entities")["entityInstances"]
        extra = copy.deepcopy(ents[0])
        extra["px"] = [0, 32]
        ents.append(extra)
        self.assertIn("two exits on the left side", self.fails("level Start"))

    def test_error_bad_side(self):
        self.layer("Boss", "Entities")["entityInstances"][0]["fieldInstances"][0]["__value"] = "sideways"
        self.assertIn("side is left, right, up or down", self.fails("level Boss"))

    def test_error_two_items(self):
        ents = self.layer("Treasure", "Entities")["entityInstances"]
        ents.append(copy.deepcopy(ents[1]))
        self.assertIn("more than one Item", self.fails("level Treasure"))

    def test_error_fields(self):
        self.level("Hall")["fieldInstances"][0]["__value"] = -1
        self.assertIn("weight", self.fails("level Hall"))
        self.level("Hall")["fieldInstances"][0]["__value"] = 1
        self.level("Hall")["fieldInstances"][1]["__value"] = [1, 2]
        self.assertIn("tags", self.fails("level Hall"))

    def test_error_collision_layer(self):
        self.layer("Well", "Collision")["intGridCsv"][5] = 9
        self.assertIn("IntGrid value 9", self.fails("level Well"))
        self.layer("Well", "Collision")["intGridCsv"].pop()
        self.assertIn("59 values", self.fails("level Well"))

    def test_error_not_a_project(self):
        path = self.tmp / "broken.ldtk"
        path.write_text("{ not json", encoding="utf-8")
        with self.assertRaises(ldtk_convert.ConvertError) as cm:
            ldtk_convert.convert(path, options())
        self.assertIn("not valid JSON", str(cm.exception))
        path.write_text("{}", encoding="utf-8")
        with self.assertRaises(ldtk_convert.ConvertError) as cm:
            ldtk_convert.convert(path, options())
        self.assertIn("does not look like an LDtk project", str(cm.exception))
        with self.assertRaises(ldtk_convert.ConvertError) as cm:
            ldtk_convert.convert(self.tmp / "none.ldtk", options())
        self.assertIn("cannot read", str(cm.exception))

    # -----------------------------------------------------------------------------------------
    def test_serialize(self):
        s = ldtk_convert.serialize
        self.assertEqual(s({"b": 1, "a": [1, 2.5, -3, True, None], "c": None, "B": "x"}),
                         '{["B"]="x",["a"]={1,2.5,-3,true,false,},["b"]=1,}')
        self.assertEqual(s('a"b\\c\n\t\x01\x7fé'), '"a\\"b\\\\c\\n\\t\\001\\127é"')
        self.assertEqual(s([2.0, 0.1, 1e20, []]), "{2,0.10000000000000001,1e+20,{},}")

    def test_main_writes_the_same_bytes(self):
        a, b = self.tmp / "a.lvl", self.tmp / "sub" / "b.lvl"
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            self.assertEqual(ldtk_convert.main([str(FIXTURES / "world.ldtk"), "-o", str(a)]), 0)
            self.assertEqual(ldtk_convert.main([str(FIXTURES / "world.ldtk"), "-o", str(b), "-q"]), 0)
        self.assertIn("5 rooms", out.getvalue())
        self.assertIn("warning:", err.getvalue())
        text = a.read_bytes()
        self.assertEqual(text, b.read_bytes())
        self.assertTrue(text.startswith(b'{["cell"]={["h"]=6,["w"]=10,},["format"]="360pc-level",'))
        self.assertNotIn(b"\n", text)
        # key order in the JSON does not matter
        shuffled = json.loads(json.dumps(self.project, sort_keys=True))
        self.assertEqual(ldtk_convert.serialize(self.convert(shuffled)).encode("utf-8"), text)

    def test_main_reports_errors(self):
        self.level("Boss")["pxHei"] = 100
        path = self.tmp / "world.ldtk"
        path.write_text(json.dumps(self.project), encoding="utf-8")
        err = io.StringIO()
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            code = ldtk_convert.main([str(path), "-o", str(self.tmp / "out.lvl")])
        self.assertEqual(code, 1)
        self.assertIn("ldtk_convert: level Boss", err.getvalue())
        self.assertFalse((self.tmp / "out.lvl").exists())


if __name__ == "__main__":
    unittest.main()
