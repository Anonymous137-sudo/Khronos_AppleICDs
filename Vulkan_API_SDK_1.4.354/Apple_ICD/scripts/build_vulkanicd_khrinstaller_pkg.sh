#!/bin/sh
set -eu

export COPYFILE_DISABLE=1

usage() {
    printf '%s\n' "usage: $0 [--output <VulkanICD-KHR-Installer.pkg>]"
    exit 2
}

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=$(git -C "$project_root" rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
    printf '%s\n' "unable to locate the Git root for VulkanICD-KHR-Installer.pkg" >&2
    exit 1
fi

case "$project_root" in
    "$repo_root"/*)
        project_dir=${project_root#"$repo_root"/}
        ;;
    *)
        printf '%s\n' "Vulkan ICD project is outside its Git root: $project_root" >&2
        exit 1
        ;;
esac

pkg_output=${VULKANICD_KHR_PKG_OUTPUT:-"$repo_root/dist/VulkanICD-KHR-Installer.pkg"}
pkg_identifier=${VULKANICD_KHR_PKG_IDENTIFIER:-"org.khronos.appleicds.vulkanicd-khrinstaller"}
pkg_version=${VULKANICD_KHR_PKG_VERSION:-"1.4.354.10"}
release_label=${VULKANICD_KHR_RELEASE_LABEL:-"vkcube-bundle-r10-20260822"}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            [ "$#" -ge 2 ] || usage
            pkg_output=$2
            shift 2
            ;;
        *)
            usage
            ;;
    esac
done

if ! command -v pkgbuild >/dev/null 2>&1; then
    printf '%s\n' "pkgbuild is required to create VulkanICD-KHR-Installer.pkg" >&2
    exit 1
fi

repo_branch=${VULKANICD_KHR_REPO_BRANCH:-$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s\n' main)}
repo_url=${VULKANICD_KHR_REPO_URL:-$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)}

case "$repo_url" in
    git@github.com:*)
        repo_url=$(printf '%s\n' "$repo_url" | sed 's#^git@github.com:#https://github.com/#')
        ;;
    ssh://git@github.com/*)
        repo_url=$(printf '%s\n' "$repo_url" | sed 's#^ssh://git@github.com/#https://github.com/#')
        ;;
esac

case "$repo_url" in
    https://github.com/*)
        ;;
    *)
        printf '%s\n' "missing or unsupported repository origin URL; set VULKANICD_KHR_REPO_URL or configure a GitHub origin" >&2
        exit 1
        ;;
esac

if [ -e "$pkg_output" ]; then
    printf '%s\n' "refusing to overwrite existing package: $pkg_output" >&2
    exit 1
fi

package_root=$(mktemp -d "${TMPDIR:-/tmp}/vulkanicd-khr-pkg.XXXXXX")
payload_root="$package_root/payload"
pkg_scripts_root="$package_root/scripts"
mkdir -p \
    "$payload_root/usr/local/bin" \
    "$payload_root/usr/local/libexec/VulkanICD_KHR" \
    "$payload_root/usr/local/share/VulkanICD_KHR" \
    "$pkg_scripts_root" \
    "$(dirname -- "$pkg_output")"

install -m 0755 "$project_root/installer/bin/vulkanicd-khr-build" \
    "$payload_root/usr/local/bin/vulkanicd-khr-build"
install -m 0755 "$project_root/installer/bin/vulkanicd-khr-update" \
    "$payload_root/usr/local/bin/vulkanicd-khr-update"
install -m 0755 "$project_root/installer/bin/vulkanicd-khr-log" \
    "$payload_root/usr/local/bin/vulkanicd-khr-log"
install -m 0755 "$project_root/installer/bin/vulkanicd-khr-build-local" \
    "$payload_root/usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-build-local"
install -m 0755 "$project_root/scripts/build-avk143-icd.sh" \
    "$payload_root/usr/local/libexec/VulkanICD_KHR/build-avk143-icd.sh"
install -m 0755 "$project_root/scripts/build-avk143-vulkan-tools.sh" \
    "$payload_root/usr/local/libexec/VulkanICD_KHR/build-avk143-vulkan-tools.sh"
install -m 0755 "$project_root/installer/bin/vulkanicd-khr-bootstrap" \
    "$payload_root/usr/local/libexec/VulkanICD_KHR/vulkanicd-khr-bootstrap"
install -m 0755 "$project_root/installer/pkg_scripts/preinstall" "$pkg_scripts_root/preinstall"
install -m 0755 "$project_root/installer/pkg_scripts/postinstall" "$pkg_scripts_root/postinstall"

cat >"$payload_root/usr/local/share/VulkanICD_KHR/repository.conf" <<EOF
VULKANICD_KHR_REPO_ROOT='/usr/local/src/Khronos_AppleICDs'
VULKANICD_KHR_REPO_URL='$repo_url'
VULKANICD_KHR_REPO_BRANCH='$repo_branch'
VULKANICD_KHR_PROJECT_DIR='$project_dir'
VULKANICD_KHR_RUNTIME_PREFIX='/usr/local'
VULKANICD_KHR_API_VERSION='1.4.354'
VULKANICD_KHR_RELEASE_LABEL='$release_label'
EOF

# Finder metadata must never enter a distributable package payload.
find "$payload_root" -name '._*' -type f -delete
find "$payload_root" -name '.DS_Store' -type f -delete
if command -v xattr >/dev/null 2>&1; then
    xattr -rc "$payload_root" 2>/dev/null || true
fi

pkgbuild \
    --root "$payload_root" \
    --scripts "$pkg_scripts_root" \
    --identifier "$pkg_identifier" \
    --version "$pkg_version" \
    --install-location / \
    "$pkg_output"

printf '%s\n' "built VulkanICD-KHR-Installer package at $pkg_output"
