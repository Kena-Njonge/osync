#!/bin/bash
set -euo pipefail

# Usage: sync.sh <local_vault_path> [--realrun]
: "${1:?Usage: $(basename "$0") <local_vault_path> [--realrun] [--seed]}"

# Paths
local_vault_path="$1"
remote_host="termux"
remote_vault_dir_path='~/storage/shared/Obsidian/'   # ~ expands on the REMOTE

# Validate local dir
if [[ ! -d "$local_vault_path" ]]; then
  echo "The provided path is not a directory. Please specify a valid path."
  exit 1
fi

# Validate remote dir
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" "[ -d $remote_vault_dir_path ]"; then
  echo "Remote dir exists: $remote_host:$remote_vault_dir_path"
else
  echo "Remote dir NOT found: $remote_host:$remote_vault_dir_path"
  exit 1
fi


# Dry-run toggle (default true; --realrun disables)
do_dryrun=true
[[ ${2:-} == '--realrun' ]] && do_dryrun=false

# Seed toggle (default false) 
seed=false
[[ ${3:-} == '--seed' ]] && seed=true
# Normalize source to send *contents*
local_src="${local_vault_path%/}/"

echo "Local:  $local_src"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"

# Inject dry-run switch
RSYNC_DRY=()
[[ $do_dryrun == true ]] && RSYNC_DRY=(--dry-run)

# ----------------- Deletions discovery -----------------

# Local tracked files
mapfile -t tracked_files < <(git -C "$local_vault_path" ls-files)

# Remote inventory (relative paths, filtered)
mapfile -t remote_files < <(
  ssh "$remote_host" "cd $remote_vault_dir_path && \
    find . -type f ! -path './.git/*' ! -path './.obsidian/*' -printf '%P\n'"
)

# Remote set for membership tests
declare -A remote_set=()
for p in "${remote_files[@]}"; do
  remote_set["$p"]=1
done

# Tracked locally but absent on remote => remote deletion happened
deleted_files_remote=()
for p in "${tracked_files[@]}"; do
  if [[ -z ${remote_set[$p]+_} ]]; then
    deleted_files_remote+=("$p")
  fi
done

# Deleted locally since last commit (git knows) => local deletion happened
mapfile -t deleted_files_local < <(git -C "$local_vault_path" ls-files --deleted)

# ----------------- Deletions propagation -----------------

if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ ! $seed ]]; then
  del_opts=(-a --delete-missing-args --ignore-missing-args)
  [[ $do_dryrun == true ]] && del_opts+=(--dry-run)

  # Delete on remote the files missing locally
  if ((${#deleted_files_local[@]})); then
    tmp="$(mktemp)"; printf '%s\n' "${deleted_files_local[@]}" >"$tmp"
    rsync "${del_opts[@]}" \
      --exclude=".git/" --exclude=".obsidian/" \
      --files-from="$tmp" \
      "$local_src" "$remote_host:$remote_vault_dir_path"
    rm -f "$tmp"
  fi

  # Delete on local the files missing on remote
  if ((${#deleted_files_remote[@]})); then
    tmp="$(mktemp)"; printf '%s\n' "${deleted_files_remote[@]}" >"$tmp"
    rsync "${del_opts[@]}" \
      --exclude=".git/" --exclude=".obsidian/" \
      --files-from="$tmp" \
      "$remote_host:$remote_vault_dir_path" "$local_src"
    rm -f "$tmp"
  fi

elif git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ $seed ]]; then 
	# On seed, we have never transfered files, so we just want to transfer and set our status to 1
	# We also don't worry about deletions.
	# so we won't overwrite anything in the remote, they will be added as new in the next sync assuming they ahdn't been tracked yet
	rsync -ah "${RSYNC_DRY[@]}" --update --itemize-changes \
	  --exclude=".git/" --exclude=".obsidian/" \
	  "$local_src" "$remote_host:$remote_vault_dir_path"
else
  echo "Not a git repo at $local_vault_path; To avoid side effects and mistakes, the operation is aborted."
  exit 1
fi

# ----------------- Updates both ways -----------------

rsync -ah "${RSYNC_DRY[@]}" --update --itemize-changes \
  --exclude=".git/" --exclude=".obsidian/" \
  "$local_src" "$remote_host:$remote_vault_dir_path"

rsync -ah "${RSYNC_DRY[@]}" --update --itemize-changes \
  --exclude=".git/" --exclude=".obsidian/" \
  "$remote_host:$remote_vault_dir_path" "$local_src"

# ----------------- Git bookkeeping -----------------

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

