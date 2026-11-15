"""Builds a single notices file, without summarising or replacing the licenses."""
from pathlib import Path


def build_notices(sdk, glslang, toolchain=None):
    sdk, glslang = Path(sdk), Path(glslang)
    files = [
        ("xsdk / xost: MIT", sdk / "LICENSE"),
        ("xsdk: third-party notices (includes Xenia, xost's encoder)", sdk / "THIRD_PARTY_NOTICES.md"),
        ("glslang-xenon: the project's complete licenses", glslang / "LICENSE.txt"),
        ("SPIRV-Tools: Apache-2.0", glslang / "External/spirv-tools/LICENSE"),
        ("SPIRV-Headers: complete licenses", glslang / "External/spirv-tools/external/spirv-headers/LICENSE"),
    ]
    # Las revisiones fijadas no tienen NOTICE, pero no omitirlo si se actualizan.
    for project in [glslang, glslang / "External/spirv-tools", glslang / "External/spirv-tools/external/spirv-headers"]:
        if (project / "NOTICE").is_file():
            files.append((project.name + " / NOTICE", project / "NOTICE"))
    if toolchain:
        toolchain = Path(toolchain)
        if not toolchain.is_dir():
            raise ValueError("--toolchain-notices must be a folder with the notices of the MinGW/GCC runtime")
        notices = sorted(p for p in toolchain.iterdir() if p.is_file())
        if not notices:
            raise ValueError("The toolchain notices folder is empty")
        files += [("Toolchain runtime / " + p.name, p) for p in notices]
    index = Path(__file__).with_name("NOTICES.md").read_text(encoding="utf-8")
    parts = [index]
    for title, path in files:
        text = path.read_text(encoding="utf-8")
        if not text.strip():
            raise ValueError("License notice is empty: " + str(path))
        parts.append("\n\n" + "=" * 78 + "\n" + title + "\n" + "=" * 78 + "\n\n" + text)
    return "".join(parts) + "\n"
