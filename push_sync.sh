#!/bin/bash
set -euo pipefail

# Usage: script.sh <local_vault_path> [--realrun] [--filetrans]
: "${1?Usage: $(basename "$0") <local_vault_path> [--realrun] [--filetrans]}"

# local_vault_path should be the supervault path
local_vault_path="$1"
remote_host="termux"
# let ~ not expand
remote_vault_dir_path='~/storage/shared/Obsidian/'

do_dryrun=true
[[ ${2:-} == '--realrun' ]] && do_dryrun=false

# Whether to transfer the contents of the dir or the dir itself
do_dir=true
[[ ${3:-} == '--filetrans' ]] && do_dir=false

echo "Local:  $local_vault_path"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"
echo "Dir Transfer?: $([[ $do_dir==true ]] && echo True || echo False) "

# If sending the directory itself: no trailing slash
# If sending the contents: ensure trailing slash
if [[ $do_dir == true ]]; then
  [[ $local_vault_path == */ ]] && local_vault_path="${local_vault_path%/}"
else
  [[ $local_vault_path != */ ]] && local_vault_path="${local_vault_path}/"
fi

# Build rsync options
rsync_opts=(-aivhP --delete --exclude=".git/" --exclude=".obsidian/" --exclude="*.gitignore")
[[ $do_dryrun == true ]] && rsync_opts+=(--dry-run)

rsync "${rsync_opts[@]}" \
  "$local_vault_path" \
  "$remote_host:$remote_vault_dir_path"

# Git bookkeeping (stage first, then check) ----
if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git -C "$local_vault_path" add -A
  if ! git -C "$local_vault_path" diff --cached --quiet; then
    git -C "$local_vault_path" commit -m "Update at $(date +'%Y-%m-%d %H:%M:%S %z')"
    git -C "$local_vault_path" push
  else
    echo "No changes to commit."
  fi
else
  echo "Not a git repo at $local_vault_path; skipping git steps."
fi
