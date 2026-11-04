#!/bin/zsh
cd "$(dirname "$0")/.." || exit 1
export PATH="/opt/homebrew/bin:/Library/Frameworks/Python.framework/Versions/3.13/bin:$PATH"
exec python3 Scripts/youtube_mp3_ui.py
