#!/bin/zsh

set -euo pipefail

if [[ $# -ne 1 ]]; then
    print -u2 "Usage: VOXOL_NOTARY_PROFILE=<profile> $0 <VoxoL.app|package.dmg|package.pkg>"
    exit 64
fi

artifact="${1:A}"
profile="${VOXOL_NOTARY_PROFILE:-}"

if [[ ! -e "$artifact" ]]; then
    print -u2 "Release artifact does not exist: $artifact"
    exit 66
fi
if [[ -z "$profile" ]]; then
    print -u2 "VOXOL_NOTARY_PROFILE must name a notarytool Keychain profile."
    exit 64
fi

codesign --verify --deep --strict --verbose=2 "$artifact"

submission="$artifact"
temporary_directory=""
cleanup() {
    if [[ -n "$temporary_directory" && -d "$temporary_directory" ]]; then
        /bin/rm -rf -- "$temporary_directory"
    fi
}
trap cleanup EXIT HUP INT TERM

if [[ "$artifact" == *.app ]]; then
    temporary_directory="$(mktemp -d -t voxol-notary)"
    submission="$temporary_directory/VoxoL.zip"
    ditto -c -k --keepParent "$artifact" "$submission"
fi

xcrun notarytool submit "$submission" --keychain-profile "$profile" --wait
xcrun stapler staple "$artifact"
xcrun stapler validate "$artifact"

print "Notarization and stapling succeeded: $artifact"
