#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
fork_url=${MESA_FORK_URL:-https://github.com/Anonymous137-sudo/AO46Mesa.git}
output=${MESA_POINTER_REPORT:-"$repo_root/artifacts/mesa-sync/pointer-report.md"}

mkdir -p "$(dirname -- "$output")"
cat > "$output" <<'EOF'
# Mesa parent-pointer refresh

| Product | Branch | Previous pointer | Stable branch head | Action |
| --- | --- | --- | --- | --- |
EOF

changed=false
refresh_pointer()
{
    product=$1
    path=$2
    branch=$3
    current=$(git -C "$repo_root" ls-tree HEAD "$path" | awk '{print $3}')
    target=$(git ls-remote "$fork_url" "refs/heads/$branch" | awk '{print $1}')

    if [ -z "$target" ]; then
        printf '%s\n' "Mesa branch is missing: $branch" >&2
        exit 1
    fi

    if [ "$current" = "$target" ]; then
        action=current
    else
        git -C "$repo_root" update-index --add --cacheinfo "160000,$target,$path"
        action=updated
        changed=true
    fi

    printf '| `%s` | `%s` | `%s` | `%s` | %s |\n' \
        "$product" "$branch" "$current" "$target" "$action" >> "$output"
}

refresh_pointer opengl 'OpenGL_4.6(Core Profile)/mesa' ao46-opengl
refresh_pointer vulkan 'Vulkan_API_SDK_1.4.354/mesa' avk143-vulkan-mainline

if $changed; then
    printf '%s\n' 'mesa_pointers_changed=true'
else
    printf '%s\n' 'mesa_pointers_changed=false'
fi

cat "$output"
