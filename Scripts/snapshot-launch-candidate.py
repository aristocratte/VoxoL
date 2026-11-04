#!/usr/bin/env python3
"""Freeze native build inputs without changing the original working tree."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import shutil

ROOT = Path(__file__).resolve().parents[1]
TREES = ["App", "Packages", "Tools", "Tests", "VoxoL.xcodeproj", "Models/manifests",
         "Docs/ui-redesign/signal-editorial-prototype/assets"]
FILES = ["Package.swift", "Package.resolved", ".swift-format", "CONTRIBUTING.md"]
SKIP = {".build", "__pycache__", "node_modules", ".DS_Store", ".git", "xcuserdata"}
EXTENSIONS = {".swift", ".metal", ".m", ".h", ".c", ".cpp", ".json", ".md", ".strings",
              ".plist", ".entitlements", ".pbxproj", ".xcworkspacedata", ".xcscheme",
              ".resolved", ".xcconfig", ".ttf", ".png", ".jpeg", ".jpg", ".svg", ".webp"}


def sha(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        parser.error("Use a new destination")
    candidates = [ROOT / p for p in FILES if (ROOT / p).is_file()]
    for tree in TREES:
        candidates += [p for p in (ROOT / tree).rglob("*") if p.is_file() and not p.is_symlink()
                       and not SKIP.intersection(p.relative_to(ROOT / tree).parts)
                       and p.suffix in EXTENSIONS and p.stat().st_size < 20_000_000]
    before = {str(p.relative_to(ROOT)): sha(p) for p in candidates}
    args.output.mkdir(parents=True, exist_ok=False)
    for relative in before:
        destination = args.output / relative
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(ROOT / relative, destination)
    for relative, expected in before.items():
        if sha(ROOT / relative) != expected or sha(args.output / relative) != expected:
            raise ValueError("Source changed while snapshotting: " + relative)
    project = args.output / "VoxoL.xcodeproj/project.pbxproj"
    original = project.read_text()
    if (args.output / "Packages/ParakeetCore/Sources/TokenSeamAlignment.swift").is_file() and "/* TokenSeamAlignment.swift */" not in original:
        build_id, file_id = "A10910000000000000000001", "A10910000000000000000002"
        text = original.replace("/* Begin PBXBuildFile section */", "/* Begin PBXBuildFile section */\n\t\t" + build_id + " /* TokenSeamAlignment.swift in Sources */ = {isa = PBXBuildFile; fileRef = " + file_id + " /* TokenSeamAlignment.swift */; settings = {COMPILER_FLAGS = \"-O\"; }; };")
        text = text.replace("/* Begin PBXFileReference section */", "/* Begin PBXFileReference section */\n\t\t" + file_id + " /* TokenSeamAlignment.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = Packages/ParakeetCore/Sources/TokenSeamAlignment.swift; sourceTree = SOURCE_ROOT; };")
        text = text.replace("000000000000000000000073 /* Pipeline.swift */,", "000000000000000000000073 /* Pipeline.swift */,\n\t\t\t\t" + file_id + " /* TokenSeamAlignment.swift */,")
        text = text.replace("000000000000000000000072 /* Pipeline.swift in Sources */,", "000000000000000000000072 /* Pipeline.swift in Sources */,\n\t\t\t\t" + build_id + " /* TokenSeamAlignment.swift in Sources */,")
        if text.count(build_id) != 2 or text.count(file_id) != 3:
            raise ValueError("Unexpected Xcode project structure")
        project.write_text(text)
    record = {"schemaVersion": 1, "createdUTC": datetime.now(timezone.utc).isoformat(),
              "sourceFiles": before, "frozenFiles": {relative: sha(args.output / relative) for relative in before},
              "projectAdjustment": "TokenSeamAlignment build membership, only in frozen copy when required"}
    (args.output / "source-snapshot.json").write_text(json.dumps(record, indent=2) + "\n")
    print(json.dumps({"files": len(before), "snapshot": str(args.output), "manifestSHA256": sha(args.output / "source-snapshot.json")}))


if __name__ == "__main__":
    main()
