#!/usr/bin/env python3
"""Validate meeting link extraction without reading any calendar events."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="voxol-calendar-probe-") as work:
    work = Path(work)
    source = work / "Probe.swift"
    source.write_text((root / "App/Services/MeetingCalendarStore.swift").read_text() + "\n" +
                      (root / "Tests/Integration/MeetingCalendarProbe.swift").read_text())
    executable = work / "probe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-target", "arm64-apple-macos15.0", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True, timeout=30)
