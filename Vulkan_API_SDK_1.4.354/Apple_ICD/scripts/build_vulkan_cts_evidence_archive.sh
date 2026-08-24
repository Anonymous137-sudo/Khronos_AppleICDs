#!/bin/sh
set -eu

export COPYFILE_DISABLE=1

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
vulkan_root="$repo_root/Vulkan_API_SDK_1.4.354"
output=${AVK143_EVIDENCE_OUTPUT:-"$repo_root/dist/Vulkan-CTS-1.4.6.2-Evidence.zip"}
work=$(mktemp -d "${TMPDIR:-/tmp}/avk143-cts-evidence.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
stage="$work/Vulkan-CTS-1.4.6.2-Evidence"

mkdir -p "$stage/upstream" "$stage/final-capabilities" \
    "$stage/maintenance" "$stage/restored-extensions" "$stage/release-records"

copy_file() {
    source=$1
    destination=$2
    [ -f "$source" ] || {
        printf '%s\n' "missing CTS evidence: $source" >&2
        exit 1
    }
    cp "$source" "$destination"
}

for name in info.stdout info.qpa memory_model.stdout memory_model.qpa; do
    copy_file "$vulkan_root/build/AVK143-upstream-main/cts/vulkan-1.4.6.2/$name" \
        "$stage/upstream/$name"
done
for name in info.stdout info.qpa; do
    copy_file "$vulkan_root/build/AVK143/cts/vulkan-1.4.6.2-v2-final-capabilities/$name" \
        "$stage/final-capabilities/$name"
done
cp -R "$vulkan_root/build/AVK143/cts/maintenance-next-pass/." "$stage/maintenance/"
cp -R "$vulkan_root/build/AVK143/cts/vulkan-1.4.6.2-v2-restored-extension-features/." \
    "$stage/restored-extensions/"
cp "$vulkan_root/RELEASES/V2_CTS_1.4.6.2_DRAFT_20260822.md" \
    "$vulkan_root/RELEASES/SEMANTIC_DELTA.md" "$stage/release-records/"

# QPA and stdout files include invocation provenance. Preserve test content
# while redacting host-specific roots from the distributable evidence copy.
find "$stage" -type f -print | while IFS= read -r file; do
    perl -0pi -e 's#/Users/[^\x00\r\n <"]+#<BUILD_ROOT>#g; s#/private/var/folders/[^\x00\r\n <"]+#<TEMP_ROOT>#g' "$file"
done

cat >"$stage/README.txt" <<'EOF'
Vulkan CTS 1.4.6.2 focused engineering evidence

This archive contains the admission-gate and focused extension evidence named
by PRE_RELEASE_CTS_1.4.6.2_20260824.md. Absolute host paths are replaced with
<BUILD_ROOT> or <TEMP_ROOT>; test names, outcomes, and messages are unchanged.

It is not a complete CTS mustpass result and is not a Khronos conformance or
certification artifact. Six memory-model failures block the full campaign.
EOF

if grep -R -a -E '/Users/|gitanshchakravarty|/private/var/folders/' "$stage" >/dev/null 2>&1; then
    printf '%s\n' 'refusing evidence archive: host metadata remains' >&2
    exit 1
fi

find "$stage" -exec touch -t 202608240000 {} +
mkdir -p "$(dirname -- "$output")"
(cd "$work" && zip -X -q -r archive.zip "$(basename -- "$stage")")
mv -f "$work/archive.zip" "$output"
printf '%s\n' "built CTS evidence archive: $output"
