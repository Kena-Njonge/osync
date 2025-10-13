#!/bin/bash
set -euo pipefail

# Usage: sync.sh <local_vault_path> [--realrun]
# Exit if unset or null
: "${1:?Usage: $(basename "$0") <local_vault_path> [--realrun]}"

# local_vault_path should be the supervault path
local_vault_path="$1"

# does the local_vault_path exist?
if [[ ! -d "$local_vault_path" ]]; then
  echo "The provided path is not a directory. Please specify a valid path."
  exit 1
fi

remote_host="termux"
# let ~ not expand
remote_vault_dir_path='~/storage/shared/Obsidian/'

# dry-run toggle (default true; --realrun disables)
do_dryrun=true
[[ ${2:-} == '--realrun' ]] && do_dryrun=false

# Whether to transfer the contents of the dir or the dir itself
# Normalize to have a trailing slash so we send the *contents*
$local_vault_path="${local_vault_path%/}/"

echo "Local:  $local_src"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"

# The dry-run switch is injected via this array
RSYNC_DRY=()
if [[ $do_dryrun == true ]]; then
  RSYNC_DRY=(--dry-run)
fi


# Local tracked files 
mapfile -t tracked_files < <(git -C "$local_vault_path" ls-files)

# Remote files, full list
mapfile -t remote_files < <(
  ssh "$remote_host" "cd $remote_vault_dir_path && \
    find . -type f ! -path './.git/*' ! -path './.obsidian/*' -printf '%P\n'"
)

# make a remote set
declare -A remote_set=()
for p in "${remote_files[@]}"; do
  remote_set["$p"]=1
done

# what local tracks but remote doesn’t have → deleted on remote
deleted_files_remote=()
for p in "${tracked_files[@]}"; do
# If wasn't on remote, string will be empty
  if [[ -z ${remote_set[$p]+_} ]]; then
    deleted_files_remote+=("$p")
  fi
done

# what local deleted since last commit → deleted on local
mapfile -t deleted_files_local < <(git -C "$local_vault_path" ls-files --deleted)



if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then

	del_opts=(-a --delete-missing-args --ignore-missing-args)
	[[ $do_dryrun == true ]] && del_opts+=(--dry-run)

	if ((${#deleted_files_local[@]})); then
	  tmp="$(mktemp)"; printf '%s\n' "${deleted_files_local[@]}" >"$tmp"
	  # delete on remote (local is missing them)
	  rsync "${del_opts[@]}" --files-from="$tmp" \
	    "$local_vault_path" "$remote_host:$remote_vault_dir_path"
	  rm -f "$tmp"
	fi

	if ((${#deleted_files_remote[@]})); then
	  tmp="$(mktemp)"; printf '%s\n' "${deleted_files_remote[@]}" >"$tmp"
	  # delete on local (remote is missing them)
	  rsync "${del_opts[@]}" --files-from="$tmp" \
	    "$remote_host:$remote_vault_dir_path" "$local_vault_path"
	  rm -f "$tmp"
	fi



	# Send update both ways, new files are created now

	rsync -ah ${RSYNC_DRY[@]} --update --itemize-changes "$local_vault_path" "$remote_host":"$remote_vault_dir_path" --exclude=".git/" --exclude='.obsidian/' --out-format='%n'

	rsync -ah ${RSYNC_DRY[@]} --update --itemize-changes  "$remote_host":"$remote_vault_dir_path" "$local_vault_path" --exclude=".git/" --exclude='.obsidian/' --out-format='%n'

else
	echo "Not a git repo at $local_vault_path; To avoid sideffects and mistakes, the operation is aborted."
	exit 1
fi

# If we are here, all changes have been propagated, now we only need to update the git.
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
