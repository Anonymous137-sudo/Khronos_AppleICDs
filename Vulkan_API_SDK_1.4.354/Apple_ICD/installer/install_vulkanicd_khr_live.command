#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pkg=${1:-}
if [ -z "$pkg" ]; then
    pkg=$(find "$script_dir" -maxdepth 1 -type f -name 'VulkanICD-KHR-Installer-*.pkg' -print 2>/dev/null | sort | tail -1 || true)
fi

if [ -z "$pkg" ] || [ ! -f "$pkg" ]; then
    printf '%s\n' 'Place this .command beside VulkanICD-KHR-Installer-*.pkg or pass the package path as its first argument.' >&2
    exit 1
fi

log_file=/var/log/VulkanICD_KHRInstaller.log
printf '%s\n' 'VulkanICD_KHR live installer'
printf '%s\n' "Package: $pkg"
printf '%s\n' "Installer log: $log_file"
printf '%s\n' 'The verbose Installer stream and postinstall output will remain visible in this Terminal.'
printf '%s\n\n' 'Press Ctrl-C only if you intentionally want to cancel the installation.'

exec sudo /usr/sbin/installer -verboseR -pkg "$pkg" -target /
