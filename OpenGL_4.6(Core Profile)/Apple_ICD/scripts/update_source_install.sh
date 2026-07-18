#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
repo_root=${OPENGLKHR_REPO_ROOT:-$(CDPATH= cd -- "$project_root/../.." && pwd)}

PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [ -d "$repo_root/.git" ]; then
    if git -C "$repo_root" rev-parse --abbrev-ref --symbolic-full-name "@{upstream}" >/dev/null 2>&1; then
        git -C "$repo_root" pull --ff-only
    else
        echo "no upstream tracking branch configured for $repo_root; skipping git pull"
    fi
else
    echo "no git metadata found at $repo_root; rebuilding local source only"
fi

exec "$script_dir/build_source_install.sh" "$@"
