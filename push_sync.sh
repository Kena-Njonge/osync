#!/bin/bash
set -euo pipefail

# Usage: push_sync.sh <local_vault_path> [--realrun] [--filetrans]
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
echo "Dir Transfer?: $([[ $do_dir == true ]] && echo True || echo False) "

# If sending the directory itself: no trailing slash
# If sending the contents: ensure trailing slash
if [[ $do_dir == true ]]; then
  [[ $local_vault_path == */ ]] && local_vault_path="${local_vault_path%/}"
else
  [[ $local_vault_path != */ ]] && local_vault_path="${local_vault_path}/"
fi

# Build rsync options
# Only update, do not delete
rsync_opts=(-aivhP --update --exclude=".git/" --exclude=".obsidian/" --exclude="*.gitignore")
[[ $do_dryrun == true ]] && rsync_opts+=(--dry-run)

rsync "${rsync_opts[@]}" \
  "$local_vault_path" \
  "$remote_host:$remote_vault_dir_path"

# Delete only files that Git marks as "tracked & deleted" locally.
# We generate a files-from list relative to $local_vault_path and ask rsync
# to delete those missing paths on the remote.
if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then

  # Collect tracked deletions relative 
  # Proc sub to keep the new lines
  mapfile -t deleted_paths < <(git -C "$local_vault_path" ls-files --deleted)

  if ((${#deleted_paths[@]})); then
    # Build a temp list file with paths; rsync expects POSIX newlines
    tmpfile="$(mktemp)"
    # If we are sending the directory itself (no trailing /), rsync’s source is the directory.
    # If we are sending contents (trailing /), rsync’s source is the inside of the dir.
    # Either way, we want paths relative to $local_vault_path (as printed by git).
    printf '%s\n' "${deleted_paths[@]}" >"$tmpfile"

    # Now run a targeted delete-only rsync:
    #  --files-from: only consider listed paths
    #  --delete-missing-args: if listed source is missing, delete it on the receiver
    #  --ignore-missing-args: don't error if a listed file wasn't ever on the receiver
    #  --prune-empty-dirs: clean up now-empty directories from those deletions
    del_opts=(-aivPh --delete-missing-args --ignore-missing-args --prune-empty-dirs)
    # Apply same excludes for safety (not strictly necessary here)
    del_opts+=(--exclude=".git/" --exclude=".obsidian/" --exclude="*.gitignore")
    [[ $do_dryrun == true ]] && del_opts+=(--dry-run)

    # IMPORTANT: Source arg must be the *root* that paths are relative to.
    # For contents mode, $local_vault_path already ends with /, which is fine.
    rsync "${del_opts[@]}" \
      --files-from="$tmpfile" \
      "$local_vault_path" \
      "$remote_host:$remote_vault_dir_path"

    rm -f "$tmpfile"
  else
    echo "No tracked deletions to propagate."
  fi
else
  echo "Not a git repo at $local_vault_path; skipping git-driven deletions."
fi


# Git bookkeeping (Commit and Push)
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
