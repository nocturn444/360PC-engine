import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "tools/shaders/xost_windows"))
from licenses import build_notices


class Licenses(unittest.TestCase):
    def test_keeps_texts_and_notice(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            sdk, glslang, tc = root / "sdk", root / "glslang", root / "tc"
            files = [sdk / "LICENSE", sdk / "THIRD_PARTY_NOTICES.md", glslang / "LICENSE.txt",
                     glslang / "External/spirv-tools/LICENSE",
                     glslang / "External/spirv-tools/external/spirv-headers/LICENSE",
                     glslang / "External/spirv-tools/NOTICE", tc / "COPYING.RUNTIME"]
            for i, f in enumerate(files):
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_text("AVISO COMPLETO %d\nNo omitir esta linea.\n" % i, encoding="utf-8")
            result = build_notices(sdk, glslang, tc)
            for f in files:
                self.assertIn(f.read_text(), result)
            files[0].write_text("")
            with self.assertRaisesRegex(ValueError, "empty"):
                build_notices(sdk, glslang, tc)


if __name__ == "__main__":
    unittest.main()
