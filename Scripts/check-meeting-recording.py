#!/usr/bin/env python3
"""Exercise the production meeting audio writer with synthetic PCM, no capture permissions."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix="voxol-recording-probe-") as work:
    work = Path(work)
    source = work / "Probe.swift"
    source.write_text((root / "App/Services/MeetingRecorder.swift").read_text() + "\n" +
                      (root / "Tests/Integration/MeetingRecordingProbe.swift").read_text())
    executable = work / "probe"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "6", "-parse-as-library",
                    "-target", "arm64-apple-macos15.0", str(source), "-o", str(executable)], check=True)
    subprocess.run([str(executable), str(work)], check=True, timeout=30)
