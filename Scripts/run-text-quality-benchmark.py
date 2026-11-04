#!/usr/bin/env python3
"""Run the frozen text-only corpus through the app's production processing path.

Uses existing local weights; never trains, installs an app, or downloads a model.
Results, timings and provenance are recorded together. Existing runs are not overwritten.
"""
import argparse
import datetime
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess

SPEC = importlib.util.spec_from_file_location(
    "quality_score", Path(__file__).with_name("score-text-quality-suite.py")
)
SCORE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(SCORE)


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def model_manifest(root):
    return {str(path.relative_to(root)): digest(path) for path in sorted(root.rglob("*"))
            if path.is_file() and path.suffix in (".json", ".safetensors", ".jinja", ".model")}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=Path, required=True, help="App bundle or executable")
    parser.add_argument("--model", type=Path, required=True)
    adapter = parser.add_mutually_exclusive_group()
    adapter.add_argument("--adapter", type=Path)
    adapter.add_argument("--without-adapter", action="store_true")
    parser.add_argument("--split", choices=("development", "holdout"), default="development")
    parser.add_argument("--prompt-style", choices=("production", "grammar-v1"), default="production")
    parser.add_argument("--output", type=Path, required=True, help="New directory for this run")
    args = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    corpus = repository / "Data/corpus/text-quality-synthetic-v1"
    SCORE.validate_frozen_corpus(corpus)
    executable = args.app / "Contents/MacOS/VoxoL" if args.app.suffix == ".app" else args.app
    executable = executable.resolve(strict=True)
    model = args.model.resolve(strict=True)
    adapter_path = None if args.without_adapter else (
        args.adapter or model.parent / "voxol-adapter"
    ).resolve(strict=True)
    suite = corpus / (args.split + ".json")
    command = [str(executable), "--polisher-smoke", "--model", str(model), "--suite", str(suite),
               "--through-processor", "--prompt-style", args.prompt_style]
    command += ["--adapter", str(adapter_path)] if adapter_path else ["--without-adapter"]
    provenance = {
        "createdUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "executable": str(executable), "executableSHA256": digest(executable),
        "suiteSHA256": digest(suite), "split": args.split, "promptStyle": args.prompt_style,
        "model": str(model), "modelFiles": model_manifest(model),
        "adapter": str(adapter_path) if adapter_path else None,
        "adapterFiles": model_manifest(adapter_path) if adapter_path else {},
        "command": command, "source": "synthetic", "humanReviewed": False,
    }
    args.output.mkdir(parents=True, exist_ok=False)
    (args.output / "provenance.json").write_text(json.dumps(provenance, indent=2) + "\n")
    report = args.output / "report.json"
    with report.open("w") as out, (args.output / "stderr.log").open("w") as err:
        subprocess.run(command, cwd=repository, stdout=out, stderr=err, timeout=300, check=True)
    result = SCORE.score(json.loads(suite.read_text()), json.loads(report.read_text()))
    result.update(suiteSHA256=digest(suite), reportSHA256=digest(report))
    (args.output / "score.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k not in ("rows", "byCategory")},
                     ensure_ascii=False))


if __name__ == "__main__":
    main()
