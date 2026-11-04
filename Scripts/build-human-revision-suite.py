#!/usr/bin/env python3
"""Build a polisher suite from the corrections the owner typed in VoxoL's history.

A history record is an owner correction when its current text differs from the pipeline's final
text (its `revisions` are an undo stack of earlier values, raw ASR first). It is linked to the
personal-benchmark session that kept the raw ASR transcript; the raw transcript becomes the
processor input and the owner's current text the reference. Cases are `source: "human"` but stay `approved: false` until the owner
confirms with `--owner-confirmed` that the revisions are theirs. Splits are fixed per session, so
the same session never lands in two splits across runs. The suite holds private dictations: it is
written only under `outputs/` (ignored by Git) and nothing dictated is printed.
"""
import argparse
import collections
import dataclasses
import datetime
import difflib
import hashlib
import json
import re
import unicodedata
from pathlib import Path

REPOSITORY = Path(__file__).resolve().parents[1]
SUPPORT = Path.home() / "Library/Application Support/VoxoL"
SPLITS = ("train", "validation", "test")
REWRITE_THRESHOLD = 0.5
FRENCH = set("le la les de des du un une et est je tu il elle on nous vous ils elles que qui pas "
             "ne sur dans pour avec ce ça c'est en au aux mais ou donc y se sa son mon ma mes ton "
             "ta faut fait plus très bien comme si alors vais va".split())
ENGLISH = set("the a an and is are i you he she it we they that this to of in on for with not do "
              "does but or so be was have has can will just my your what".split())


@dataclasses.dataclass(frozen=True)
class Link:
    session_id: str
    raw_text: str
    final_text: str
    revision_text: str


def normalize(text: str) -> str:
    return " ".join(unicodedata.normalize("NFC", text).split())


def words(text: str) -> list[str]:
    return re.findall(r"\w+(?:'\w+)*", normalize(text).replace("’", "'").casefold())


def link_revisions(history: list[dict], sessions: dict[str, dict]):
    """Find owner corrections: records whose current text differs from the pipeline's output.

    `revisions` is an undo stack of earlier values, raw ASR at the bottom; it is not a list of
    edits. A record is linked to its session through any of its texts, and it is an owner
    correction only when its current text no longer equals the session's final text.
    """
    by_final = collections.defaultdict(list)
    for session_id, meta in sessions.items():
        if isinstance(meta.get("finalText"), str) and isinstance(meta.get("rawText"), str):
            by_final[normalize(meta["finalText"])].append(session_id)
    links, exclusions, used = [], [], set()
    for record in history:
        if record.get("isExample") or not record.get("revisions"):
            continue  # an edit always pushes the previous text onto the stack
        texts = [record["text"]] + [revision["text"] for revision in record["revisions"]]
        matches = sorted({session for text in texts for session in by_final.get(normalize(text), [])})
        if not matches:
            exclusions.append((record["id"], "unlinked"))
        elif len(matches) > 1:
            exclusions.append((record["id"], "ambiguous-session"))
        elif normalize(record["text"]) == normalize(sessions[matches[0]]["finalText"]):
            exclusions.append((record["id"], "no-owner-edit"))
        elif matches[0] in used:
            exclusions.append((record["id"], "duplicate-session"))
        else:
            used.add(matches[0])
            meta = sessions[matches[0]]
            links.append(Link(matches[0], meta["rawText"], meta["finalText"], record["text"]))
    return links, exclusions


def split_for(session_id: str) -> str:
    bucket = int(hashlib.sha256(session_id.encode()).hexdigest()[:8], 16) % 100
    return "train" if bucket < 70 else "validation" if bucket < 85 else "test"


def guess_language(text: str):
    tokens = words(text)
    french = sum(token in FRENCH for token in tokens)
    english = sum(token in ENGLISH for token in tokens)
    if french > english:
        return "fr"
    if english > french:
        return "en"
    return None


def build_cases(links: list[Link], owner_confirmed: bool):
    cases, exclusions = [], []
    for link in links:
        if not normalize(link.raw_text) or not normalize(link.revision_text):
            exclusions.append((link.session_id, "empty-text"))
            continue
        if normalize(link.revision_text) == normalize(link.final_text):
            exclusions.append((link.session_id, "identical-revision"))
            continue
        similarity = difflib.SequenceMatcher(
            a=words(link.final_text), b=words(link.revision_text), autojunk=False).ratio()
        if 1 - similarity > REWRITE_THRESHOLD:
            exclusions.append((link.session_id, "probable-rewrite"))
            continue
        language = guess_language(link.revision_text)
        if language is None:
            exclusions.append((link.session_id, "language-ambiguous"))
            continue
        cases.append({
            "id": "revision-" + link.session_id, "language": language,
            "transcript": link.raw_text, "expected": link.revision_text,
            "mode": "faithful", "profile": "document", "source": "human",
            "approved": owner_confirmed, "split": split_for(link.session_id),
            "sessionID": link.session_id,
        })
    return cases, exclusions


def checked_output(path: Path) -> Path:
    resolved = path.resolve()
    allowed = (REPOSITORY / "outputs").resolve()
    if allowed not in resolved.parents:
        raise ValueError("Private suites are written only under outputs/: " + str(resolved))
    return resolved


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def write_suite(output: Path, cases: list[dict], exclusions: list, inputs: dict,
                owner_confirmed: bool) -> dict:
    output = checked_output(output)
    output.mkdir(parents=True, exist_ok=True)
    files = {}
    for split in SPLITS:
        selected = [case for case in cases if case["split"] == split]
        path = output / f"{split}.json"
        path.write_text(json.dumps({"purpose": f"Owner revision suite, {split} split",
                                    "cases": selected}, ensure_ascii=False, indent=1) + "\n")
        files[path.name] = digest(path)
    manifest = {
        "createdUTC": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "ownerConfirmed": owner_confirmed,
        "inputs": inputs,
        "files": files,
        "countsBySplit": dict(collections.Counter(case["split"] for case in cases)),
        "countsByLanguage": dict(collections.Counter(case["language"] for case in cases)),
        "exclusionsByReason": dict(collections.Counter(reason for _, reason in exclusions)),
        "exclusions": [{"id": identifier, "reason": reason} for identifier, reason in exclusions],
    }
    (output / "manifest.json").write_text(json.dumps(manifest, indent=1, sort_keys=True) + "\n")
    return manifest


def main(arguments=None) -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--history", type=Path, default=SUPPORT / "transcripts.json")
    parser.add_argument("--sessions", type=Path, default=SUPPORT / "PersonalBenchmark/sessions")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--owner-confirmed", action="store_true")
    options = parser.parse_args(arguments)
    output = checked_output(options.output)
    history = json.loads(options.history.read_text())["records"]
    sessions = {path.parent.name: json.loads(path.read_text())
                for path in sorted(options.sessions.glob("*/meta.json"))}
    links, link_exclusions = link_revisions(history, sessions)
    cases, case_exclusions = build_cases(links, options.owner_confirmed)
    manifest = write_suite(output, cases, link_exclusions + case_exclusions,
                           {"history": digest(options.history), "sessionCount": len(sessions)},
                           options.owner_confirmed)
    print(f"linked={len(links)} cases={len(cases)} splits={manifest['countsBySplit']} "
          f"languages={manifest['countsByLanguage']} excluded={manifest['exclusionsByReason']}")


if __name__ == "__main__":
    main()
