#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
workspace_root=$(CDPATH= cd -- "$project_root/../.." && pwd)

if [ "$(basename "$workspace_root")" = "Khronos_AppleICDs" ]; then
    repo_root=$workspace_root
else
    repo_root=${OPENGLKHR_REPO_ROOT:-"$workspace_root/Khronos_AppleICDs"}
fi

if [ ! -d "$repo_root" ]; then
    echo "missing repository root: $repo_root" >&2
    exit 1
fi

repo_branch=${OPENGLKHR_REPO_BRANCH:-$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || printf '%s\n' main)}
repo_url=${OPENGLKHR_REPO_URL:-}
output_dir=${1:-"$repo_root/dist"}
payload_root="$project_root/artifacts/packages/payload"
pkg_scripts_root="$project_root/artifacts/packages/pkg_scripts"
pkg_output="$output_dir/OpenGLKHR_ICD_Installer.pkg"
pkg_identifier=${OPENGLKHR_PKG_IDENTIFIER:-"org.khronos.appleicds.openglkhr-icd-installer"}
pkg_version=${OPENGLKHR_PKG_VERSION:-"0.1.0"}

if [ -z "$repo_url" ]; then
    repo_url=$(git -C "$repo_root" remote get-url origin 2>/dev/null || true)
fi

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
        echo "missing or unsupported repository origin URL; set OPENGLKHR_REPO_URL or configure a GitHub origin" >&2
        exit 1
        ;;
esac

rm -rf "$payload_root" "$pkg_scripts_root"
mkdir -p \
    "$payload_root/usr/local/bin" \
    "$payload_root/usr/local/libexec/OpenGLKHR_ICD" \
    "$payload_root/usr/local/share/OpenGLKHR_ICD" \
    "$pkg_scripts_root" \
    "$output_dir"

install -m 0755 "$project_root/installer/bin/openglkhr-icd-build" "$payload_root/usr/local/bin/openglkhr-icd-build"
install -m 0755 "$project_root/installer/bin/openglkhr-icd-update" "$payload_root/usr/local/bin/openglkhr-icd-update"
install -m 0755 "$project_root/installer/bin/openglkhr-icd-bootstrap" \
    "$payload_root/usr/local/libexec/OpenGLKHR_ICD/openglkhr-icd-bootstrap"
install -m 0755 "$project_root/installer/pkg_scripts/postinstall" "$pkg_scripts_root/postinstall"

cat >"$payload_root/usr/local/share/OpenGLKHR_ICD/repository.conf" <<EOF
OPENGLKHR_REPO_ROOT='/usr/local/src/Khronos_AppleICDs'
OPENGLKHR_REPO_URL='$repo_url'
OPENGLKHR_REPO_BRANCH='$repo_branch'
EOF

pkgbuild \
    --root "$payload_root" \
    --scripts "$pkg_scripts_root" \
    --identifier "$pkg_identifier" \
    --version "$pkg_version" \
    --install-location / \
    "$pkg_output"

echo "built installer package at $pkg_output"
