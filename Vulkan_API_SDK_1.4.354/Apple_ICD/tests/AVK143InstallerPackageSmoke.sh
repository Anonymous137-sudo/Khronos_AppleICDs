#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
    printf '%s\n' "usage: $0 <package-builder>" >&2
    exit 2
fi

builder=$1
root=$(mktemp -d "${TMPDIR:-/tmp}/avk143-installer-smoke.XXXXXX")
pkg="$root/VulkanICD_KHRInstaller.pkg"
expanded="$root/expanded"

"$builder" --output "$pkg"
test -f "$pkg"

pkgutil --payload-files "$pkg" > "$root/payload-files.txt"
grep -qx './usr/local/bin/vulkanicd-khr-build' "$root/payload-files.txt"
grep -qx './usr/local/bin/vulkanicd-khr-update' "$root/payload-files.txt"
grep -qx './usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-bootstrap' "$root/payload-files.txt"
grep -qx './usr/local/share/VulkanICD_KHR/repository.conf' "$root/payload-files.txt"

pkgutil --expand "$pkg" "$expanded"
test -x "$expanded/Scripts/preinstall"
test -x "$expanded/Scripts/postinstall"

printf '%s\n' "AVK143 VulkanICD_KHR installer package smoke passed"
