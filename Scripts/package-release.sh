#!/bin/zsh

# Turns a built VoxoL.app into the disk image a stranger can open.
#
# The disk images published so far came from a script kept outside the repository. It accepted
# an Apple Development signature and never looked for the debugging entitlement, so every one of
# them was refused by Gatekeeper on any Mac but the one that built it. This is that script, in
# the repository, with the checks that would have stopped those releases.

set -euo pipefail

if [[ $# -ne 2 ]]; then
    print -u2 "Usage: [VOXOL_NOTARY_PROFILE=<profile>] $0 <VoxoL.app> <output-directory>"
    print -u2 "       VOXOL_ALLOW_DEVELOPMENT_SIGNING=1 packages a build for this Mac only."
    exit 64
fi

app="${1:A}"
output="${2:A}"
script_directory="${0:A:h}"

if [[ ! -d "$app" ]]; then
    print -u2 "Application does not exist: $app"
    exit 66
fi

codesign --verify --deep --strict --verbose=2 "$app"

entitlements="$(codesign -d --entitlements - --xml "$app" 2>/dev/null)"
if [[ "$entitlements" == *"com.apple.security.get-task-allow"* ]]; then
    print -u2 "Refusing to package: the app carries get-task-allow, the debugging entitlement."
    print -u2 "Any process could attach to an app that holds the microphone and Accessibility."
    print -u2 "Build Release with CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO."
    exit 65
fi
if [[ "$entitlements" != *"com.apple.security.device.audio-input"* ]]; then
    print -u2 "Refusing to package: the microphone entitlement is missing."
    exit 65
fi

signature="$(codesign -dv --verbose=4 "$app" 2>&1)"
identity=""
if [[ "$signature" == *"Authority=Developer ID Application"* ]]; then
    identity="$(print -r -- "$signature" | sed -n 's/^Authority=\(Developer ID Application.*\)$/\1/p' | head -1)"
elif [[ "${VOXOL_ALLOW_DEVELOPMENT_SIGNING:-}" == "1" ]]; then
    print -u2 "Warning: not signed with Developer ID. This image opens on this Mac only."
else
    print -u2 "Refusing to package: the app is not signed with a Developer ID Application certificate."
    print -u2 "Gatekeeper rejects anything else on another Mac."
    exit 65
fi

architectures="$(lipo -archs "$app/Contents/MacOS/VoxoL")"
if [[ "$architectures" != "arm64" ]]; then
    print -u2 "Unexpected architectures: $architectures"
    exit 65
fi

version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
if [[ -n "${VOXOL_EXPECTED_VERSION:-}" && "$version" != "$VOXOL_EXPECTED_VERSION" ]]; then
    print -u2 "The app is version $version, but $VOXOL_EXPECTED_VERSION was expected."
    exit 65
fi

mkdir -p "$output"
image="$output/VoxoL-$version-arm64.dmg"
staging="$(mktemp -d -t voxol-package)"
cleanup() {
    /bin/rm -rf -- "$staging"
}
trap cleanup EXIT HUP INT TERM

ditto "$app" "$staging/VoxoL.app"
ln -s /Applications "$staging/Applications"
/bin/rm -f -- "$image"
hdiutil create -volname VoxoL -srcfolder "$staging" -format UDZO "$image" >/dev/null
hdiutil verify "$image" >/dev/null

if [[ -n "$identity" ]]; then
    codesign --sign "$identity" --timestamp "$image"
    if [[ -n "${VOXOL_NOTARY_PROFILE:-}" ]]; then
        "$script_directory/notarize-release.sh" "$image"
        # Gatekeeper's verdict on the download itself, which is what a user's Mac checks first.
        spctl --assess --type open --context context:primary-signature --verbose=4 "$image"
    else
        print -u2 "Warning: VOXOL_NOTARY_PROFILE is not set, so the image is signed but not notarised."
    fi
fi

(cd "$output" && shasum -a 256 "${image:t}" > SHA256SUMS)
print -r -- "$image"
