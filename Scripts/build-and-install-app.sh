#!/usr/bin/env bash
#
# build-and-install-app.sh — build VoxoL, sign it correctly, install it.
#
# Signing this app by hand is a trap that cost real debugging time twice. The
# app enables the hardened runtime and needs one entitlement,
# com.apple.security.device.audio-input, or macOS blocks the microphone
# *before any prompt appears* — no popup, no log, nothing. A plain
# `codesign --force` replaces Xcode's signature and drops the entitlement
# silently, which is exactly how the microphone stopped working.
#
# So the two rules this script exists to enforce:
#   1. always sign with the real Apple Development identity, never ad hoc, or
#      TCC grants stop matching the binary across rebuilds;
#   2. always pass --entitlements, or the microphone dies quietly.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO"

IDENTITY="${VOXOL_SIGN_IDENTITY:-A8CD9BE6843D097F0682CADF69ACE6F5704343C1}"
ENTITLEMENTS="$REPO/App/VoxoL.entitlements"
DERIVED="$REPO/.build/ReleaseBuild"
APP="$DERIVED/Build/Products/Release/VoxoL.app"

security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY" || {
  echo "Signing identity $IDENTITY not in the keychain." >&2
  echo "List them with: security find-identity -v -p codesigning" >&2
  exit 1
}

echo "Building Release…"
# Build unsigned: Xcode's automatic signing looks for a "Mac Development"
# certificate the keychain does not have, and fails. Signing is done below,
# explicitly, where the entitlements are guaranteed to be applied.
xcodebuild -project VoxoL.xcodeproj -scheme VoxoL -configuration Release \
  -derivedDataPath "$DERIVED" \
  -skipPackagePluginValidation -skipMacroValidation \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  build >/dev/null

echo "Signing nested code…"
# Inside out: anything embedded must be signed before the app that contains it.
while IFS= read -r nested; do
  codesign --force --sign "$IDENTITY" --options runtime --timestamp=none "$nested"
done < <(find "$APP/Contents/Frameworks" \( -name "*.dylib" -o -name "*.framework" \) 2>/dev/null)

echo "Signing app with entitlements…"
codesign --force --sign "$IDENTITY" --options runtime --timestamp=none \
  --entitlements "$ENTITLEMENTS" "$APP"

# The check that actually matters: hardened runtime on, audio entitlement
# present. Everything else can be right and the microphone still dead without
# this line passing.
codesign -d --entitlements - --xml "$APP" 2>/dev/null \
  | grep -q "device.audio-input" || {
    echo "Microphone entitlement missing after signing — refusing to install." >&2
    exit 1
  }
codesign -v --verify --deep "$APP" >/dev/null 2>&1 || {
  echo "Signature does not verify." >&2
  exit 1
}

echo "Installing to /Applications…"
osascript -e 'tell application "VoxoL" to quit' 2>/dev/null || true
pkill -x VoxoL 2>/dev/null || true
sleep 1
rm -rf /Applications/VoxoL.app
cp -R "$APP" /Applications/VoxoL.app
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
  -f /Applications/VoxoL.app 2>/dev/null || true

echo "Done. Signed by:"
codesign -dv --verbose=2 /Applications/VoxoL.app 2>&1 | grep "Authority=Apple Development" | head -1
echo
echo "If a permission is not detected, the grant is pinned to a previous"
echo "signature — reset it and relaunch:"
echo "  tccutil reset Microphone com.voxol.VoxoL"
echo "  tccutil reset Accessibility com.voxol.VoxoL"
echo "  tccutil reset ListenEvent com.voxol.VoxoL"
