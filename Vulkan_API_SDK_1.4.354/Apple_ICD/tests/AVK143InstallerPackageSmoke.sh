#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 <package-builder>" >&2
    exit 2
fi

builder=$1
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/../../.." && pwd)
root=$(mktemp -d "${TMPDIR:-/tmp}/avk143-installer-smoke.XXXXXX")
pkg="$root/VulkanICD-KHR-Installer.pkg"
expanded="$root/expanded"

# Installer scripts run as root without the developer's SSH configuration.
# Keep recursive source bootstrap reachable with anonymous HTTPS.
if git -C "$repo_root" config -f "$repo_root/.gitmodules" --get-regexp '\.url$' |
    grep -Eq '(^|[[:space:]])(git@|ssh://)'; then
    printf '%s\n' 'installer smoke failed: a submodule still uses an SSH URL' >&2
    exit 1
fi

"$builder" --output "$pkg"
test -f "$pkg"

pkgutil --payload-files "$pkg" > "$root/payload-files.txt"
grep -qx './usr/local/bin/vulkanicd-khr-build' "$root/payload-files.txt"
grep -qx './usr/local/bin/vulkanicd-khr-update' "$root/payload-files.txt"
grep -qx './usr/local/bin/vulkanicd-khr-log' "$root/payload-files.txt"
grep -qx './usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-bootstrap' "$root/payload-files.txt"
grep -qx './usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-build-local' "$root/payload-files.txt"
grep -qx './usr/local/libexec/VulkanICD_KHR/build-avk143-icd.sh' "$root/payload-files.txt"
grep -qx './usr/local/libexec/VulkanICD_KHR/build-avk143-vulkan-tools.sh' "$root/payload-files.txt"
grep -qx './usr/local/share/VulkanICD_KHR/repository.conf' "$root/payload-files.txt"

pkgutil --expand "$pkg" "$expanded"
test -x "$expanded/Scripts/preinstall"
test -x "$expanded/Scripts/postinstall"

payload="$root/payload"
mkdir -p "$payload"
gzip -dc "$expanded/Payload" | (cd "$payload" && cpio -idm --quiet)
grep -q 'vulkanicd-khr-build-local' \
    "$payload/usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-bootstrap"
sh -n "$payload/usr/local/libexec/VulkanICD_KHR/build-avk143-icd.sh"
sh -n "$payload/usr/local/libexec/VulkanICD_KHR/build-avk143-vulkan-tools.sh"
grep -q 'AVK143_TOOLS_BUILD_ROOT=' "$payload/usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-build-local"
sh -n "$payload/usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-build-local"

printf '%s\n' "AVK143 VulkanICD_KHR installer package smoke passed"
