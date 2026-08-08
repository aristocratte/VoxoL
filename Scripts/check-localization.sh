#!/bin/sh
set -eu

script_directory=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repository_root=$(dirname -- "$script_directory")
derived_data=${1:-"$repository_root/.build/DerivedData"}
objects_directory=$(
    find "$derived_data/Build/Intermediates.noindex" \
        -type d -path '*/VoxoL.build/Debug/VoxoL.build/Objects-normal/arm64' \
        -print -quit
)

if [ -z "$objects_directory" ]; then
    printf '%s\n' "VoxoL localization metadata was not produced by the Debug build." >&2
    exit 1
fi

task_temp_directory=$(mktemp -d -t voxol-localization.XXXXXX)
cleanup() {
    /bin/rm -rf "$task_temp_directory"
}
trap cleanup EXIT HUP INT TERM

source_keys="$task_temp_directory/source-keys.txt"
french_keys="$task_temp_directory/french-keys.txt"
missing_keys="$task_temp_directory/missing-keys.txt"

find "$objects_directory" -type f -name '*.stringsdata' -print | while IFS= read -r file; do
    plutil -convert xml1 -o - "$file" | awk '
        /<key>key<\/key>/ {
            getline
            sub(/^[[:space:]]*<string>/, "")
            sub(/<\/string>[[:space:]]*$/, "")
            print
        }
    '
done | LC_ALL=C sort -u >"$source_keys"

plutil -convert xml1 -o - \
    "$repository_root/App/Resources/fr.lproj/Localizable.strings" \
    | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>[[:space:]]*$/\1/p' \
    | LC_ALL=C sort -u >"$french_keys"

comm -23 "$source_keys" "$french_keys" >"$missing_keys"
if [ -s "$missing_keys" ]; then
    printf '%s\n' "French localization is missing source keys:" >&2
    sed -n '1,120p' "$missing_keys" >&2
    exit 1
fi

printf '%s\n' "French localization covers every extracted UI string."

