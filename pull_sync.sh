#!/bin/bash
set -euo pipefail

: "${1?Usage: $(basename "$0") <local_vault_path> [--realrun] [--filetrans]}"

local_vault_path="$1"
remote_host="termux"
remote_vault_dir_path='~/storage/shared/Obsidian/'

# Does local vault path exist?
[[ $local_vault_path ]]



do_dryrun=true
[[ ${2:-} == '--realrun' ]] && do_dryrun=false


do_dir=true
[[ ${3:-} == '--filetrans' ]] && do_dir=false

echo "Local:  $local_vault_path"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"
echo "Dir Transfer?: $([[ $do_dir==true ]] && echo True || echo False) "

# Adjust the **remote source** path for rsync semantics
if [[ $do_dir == true ]]; then
  # send the directory itself (no trailing slash)
  [[ $remote_vault_dir_path == */ ]] && remote_vault_dir_path="${remote_vault_dir_path%/}"
else
  # send the contents (ensure trailing slash)
  [[ $remote_vault_dir_path != */ ]] && remote_vault_dir_path="${remote_vault_dir_path}/"
fi

# Build rsync options
rsync_opts=(-aivhP --update --exclude=".git/" --exclude=".obsidian/" --exclude="*.gitignore")
[[ $do_dryrun == true ]] && rsync_opts+=(--dry-run)

# remote (source) -> local (dest)
rsync "${rsync_opts[@]}" \
  "$remote_host:$remote_vault_dir_path" \
  "$local_vault_path"


# Git bookkeeping (stage first, then check)
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

