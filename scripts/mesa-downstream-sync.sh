#!/bin/sh
set -eu

usage()
{
    cat <<'EOF'
usage: mesa-downstream-sync.sh <check|prepare> <opengl|vulkan> [--push]

Environment:
  MESA_UPSTREAM_URL       Mesa upstream remote URL
  MESA_FORK_URL           AO46Mesa fork URL
  MESA_SYNC_OUTPUT_DIR    persistent report/patch output directory
EOF
}

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    usage >&2
    exit 64
fi

command_name=$1
product=$2
push_candidate=false
if [ "${3:-}" = "--push" ]; then
    push_candidate=true
elif [ "$#" -eq 3 ]; then
    usage >&2
    exit 64
fi

case "$product" in
    opengl)
        downstream_branch=ao46-opengl
        parent_path='OpenGL_4.6(Core Profile)/mesa'
        ;;
    vulkan)
        downstream_branch=avk143-vulkan-mainline
        parent_path='Vulkan_API_SDK_1.4.354/mesa'
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
upstream_url=${MESA_UPSTREAM_URL:-https://gitlab.freedesktop.org/mesa/mesa.git}
fork_url=${MESA_FORK_URL:-https://github.com/Anonymous137-sudo/AO46Mesa.git}
output_root=${MESA_SYNC_OUTPUT_DIR:-"$repo_root/artifacts/mesa-sync"}
output_dir="$output_root/$product"
report="$output_dir/report.md"
metadata="$output_dir/metadata.env"

mkdir -p "$output_dir"
rm -f "$report" "$metadata"

work_root=$(mktemp -d "${TMPDIR:-/tmp}/mesa-downstream-sync.XXXXXX")
cleanup()
{
    rm -rf "$work_root"
}
trap cleanup EXIT HUP INT TERM

checkout="$work_root/mesa"
git clone --quiet --no-checkout "$fork_url" "$checkout"
git -C "$checkout" remote add upstream "$upstream_url"
git -C "$checkout" fetch --quiet origin \
    "refs/heads/$downstream_branch:refs/remotes/origin/$downstream_branch"
git -C "$checkout" fetch --quiet upstream \
    'refs/heads/main:refs/remotes/upstream/main'

downstream_head=$(git -C "$checkout" rev-parse "origin/$downstream_branch")
upstream_head=$(git -C "$checkout" rev-parse upstream/main)
merge_base=$(git -C "$checkout" merge-base "$downstream_head" "$upstream_head")
downstream_short=$(git -C "$checkout" rev-parse --short=12 "$downstream_head")
upstream_short=$(git -C "$checkout" rev-parse --short=12 "$upstream_head")
behind_count=$(git -C "$checkout" rev-list --count "$downstream_head..$upstream_head")
downstream_count=$(git -C "$checkout" rev-list --count "$merge_base..$downstream_head")

write_common_report()
{
    cat > "$report" <<EOF
# Mesa downstream synchronization: $product

| Field | Value |
| --- | --- |
| Product | \`$product\` |
| Parent gitlink | \`$parent_path\` |
| Protected downstream branch | \`$downstream_branch\` |
| Previous downstream head | \`$downstream_head\` |
| Mesa upstream head | \`$upstream_head\` |
| Merge base | \`$merge_base\` |
| Upstream commits not in downstream | $behind_count |
| Downstream commits after merge base | $downstream_count |
EOF
}

write_common_report

if git -C "$checkout" merge-base --is-ancestor "$upstream_head" "$downstream_head"; then
    cat >> "$report" <<'EOF'

## Result

The downstream already contains the selected upstream head. No candidate was
created and no remote reference was changed.
EOF
    cat > "$metadata" <<EOF
status=current
product=$product
downstream_branch=$downstream_branch
downstream_head=$downstream_head
upstream_head=$upstream_head
candidate_branch=
candidate_head=
EOF
    cat "$report"
    exit 0
fi

if [ "$command_name" = "check" ]; then
    cat >> "$report" <<EOF

## Result

The downstream is behind the selected upstream by $behind_count commits. Run
\`mesa-downstream-sync.sh prepare $product\` to construct a protected merge
candidate in a temporary checkout.
EOF
    cat > "$metadata" <<EOF
status=behind
product=$product
downstream_branch=$downstream_branch
downstream_head=$downstream_head
upstream_head=$upstream_head
candidate_branch=
candidate_head=
EOF
    cat "$report"
    exit 0
fi

if [ "$command_name" != "prepare" ]; then
    usage >&2
    exit 64
fi

patch_dir="$output_dir/downstream-patches-$downstream_short"
rm -rf "$patch_dir"
mkdir -p "$patch_dir"
if [ "$downstream_count" -gt 0 ]; then
    git -C "$checkout" format-patch --quiet --binary --full-index \
        --output-directory "$patch_dir" "$merge_base..$downstream_head"
fi

candidate_branch="automation/mesa-sync-$product-$upstream_short-$downstream_short"
git -C "$checkout" checkout --quiet -b "$candidate_branch" "$downstream_head"

if ! git -C "$checkout" merge --no-ff --no-edit upstream/main; then
    conflict_list=$(git -C "$checkout" diff --name-only --diff-filter=U || true)
    git -C "$checkout" merge --abort
    cat >> "$report" <<EOF

## Result: blocked by merge conflicts

No candidate was pushed and no parent gitlink was changed. The preserved
downstream patch series is attached to the workflow artifact.

\`\`\`text
$conflict_list
\`\`\`
EOF
    cat > "$metadata" <<EOF
status=conflict
product=$product
downstream_branch=$downstream_branch
downstream_head=$downstream_head
upstream_head=$upstream_head
candidate_branch=$candidate_branch
candidate_head=
EOF
    cat "$report"
    exit 2
fi

candidate_head=$(git -C "$checkout" rev-parse HEAD)

# These ancestry checks are the non-loss contract. A candidate that drops
# either side is never eligible for push or a parent gitlink update.
git -C "$checkout" merge-base --is-ancestor "$downstream_head" "$candidate_head"
git -C "$checkout" merge-base --is-ancestor "$upstream_head" "$candidate_head"
# Validate the downstream delta rather than blaming the candidate for an
# already-present upstream whitespace defect.
git -C "$checkout" diff --check "$upstream_head..$candidate_head"

cat >> "$report" <<EOF

## Result: candidate prepared

| Field | Value |
| --- | --- |
| Candidate branch | \`$candidate_branch\` |
| Candidate head | \`$candidate_head\` |
| Downstream head retained as ancestor | yes |
| Upstream head retained as ancestor | yes |
| Downstream patch backup | \`$(basename "$patch_dir")/\` |
| Whitespace validation | passed |

The candidate still requires the product build and regression suite before the
protected downstream branch or parent submodule pointer may be updated.
EOF

cat > "$metadata" <<EOF
status=prepared
product=$product
downstream_branch=$downstream_branch
downstream_head=$downstream_head
upstream_head=$upstream_head
candidate_branch=$candidate_branch
candidate_head=$candidate_head
EOF

if $push_candidate; then
    git -C "$checkout" push --quiet origin \
        "HEAD:refs/heads/$candidate_branch"
    cat >> "$report" <<EOF

The candidate branch was pushed to the downstream fork. The protected
\`$downstream_branch\` branch was not modified.
EOF
fi

cat "$report"
