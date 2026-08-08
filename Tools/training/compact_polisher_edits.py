#!/usr/bin/env python3
"""Lossless, fail-closed compact edits for VoxoL's local polisher."""

from __future__ import annotations

from dataclasses import dataclass
from difflib import SequenceMatcher
import json


MERGE_GAP_CHARACTERS = 4


@dataclass(frozen=True)
class Change:
    source_start: int
    source_end: int
    target_start: int
    target_end: int


def _changes(source: str, target: str) -> list[Change]:
    opcodes = SequenceMatcher(None, source, target, autojunk=False).get_opcodes()
    changes = [
        Change(source_start, source_end, target_start, target_end)
        for tag, source_start, source_end, target_start, target_end in opcodes
        if tag != "equal"
    ]
    if not changes:
        return []

    merged = [changes[0]]
    for change in changes[1:]:
        previous = merged[-1]
        if change.source_start - previous.source_end <= MERGE_GAP_CHARACTERS:
            merged[-1] = Change(
                previous.source_start,
                change.source_end,
                previous.target_start,
                change.target_end,
            )
        else:
            merged.append(change)
    return merged


def _anchored_change(source: str, target: str, change: Change) -> tuple[str, str]:
    left_available = min(change.source_start, change.target_start)
    right_available = min(
        len(source) - change.source_end,
        len(target) - change.target_end,
    )
    left = 0
    right = 0

    while True:
        old = source[change.source_start - left : change.source_end + right]
        new = target[change.target_start - left : change.target_end + right]
        if old and source.count(old) == 1:
            return old, new
        if left == left_available and right == right_available:
            return source, target
        left = min(left_available, max(left + 1, left * 2))
        right = min(right_available, max(right + 1, right * 2))


def encode_compact_edits(source: str, target: str) -> str:
    """Returns deterministic JSON edits that reconstruct target from source."""

    edits = [
        [old, new]
        for old, new in (
            _anchored_change(source, target, change)
            for change in reversed(_changes(source, target))
        )
    ]
    payload = _encode(edits)
    try:
        reconstructed = apply_compact_edits(source, payload)
    except ValueError:
        reconstructed = None
    if reconstructed != target:
        payload = _encode([[source, target]])
        reconstructed = apply_compact_edits(source, payload)
    if reconstructed != target:
        raise ValueError("Generated compact edits do not reconstruct the target")
    return payload


def _encode(edits: list[list[str]]) -> str:
    return json.dumps(
        edits,
        ensure_ascii=False,
        separators=(",", ":"),
    )


def apply_compact_edits(source: str, payload: str) -> str:
    """Applies exact unique replacements or fails without returning partial text."""

    decoded = json.loads(payload)
    if not isinstance(decoded, list) or len(decoded) > 32:
        raise ValueError("Compact edits must be a bounded list")

    result = source
    for edit in decoded:
        if not isinstance(edit, list) or len(edit) != 2:
            raise ValueError("Each compact edit requires exactly [old, new]")
        old, new = edit
        if not isinstance(old, str) or not isinstance(new, str) or not old:
            raise ValueError("Compact edit values must be strings and old cannot be empty")
        if result.count(old) != 1:
            raise ValueError("Compact edit anchor must occur exactly once")
        result = result.replace(old, new, 1)
    return result
