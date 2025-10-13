#!/bin/bash
set -euo pipefail


echo "Arguments: $@"


# Usage: sync.sh <local_vault_path> [--realrun] [--seed]
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


# ------- DEBUGGIGN -------
echo "Local:  $local_src"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"
# ----------------


# Inject dry-run switch
RSYNC_DRY=()
[[ $do_dryrun == true ]] && RSYNC_DRY=(--dry-run)

# ----------------- Deletions discovery -----------------

# Local tracked files
mapfile -t tracked_files < <(git -C "$local_vault_path" ls-files)

# Remote inventory (relative paths, filtered)
mapfile -t remote_files < <(
  ssh "$remote_host" "cd $remote_vault_dir_path && \
    find . -type f ! -path '*/.git/*' ! -path '*/.obsidian/*' ! -path '*/.trash/*' -printf '%P\n' 2>/dev/null"
)

# DEBUG: Check if find command works
echo "Testing remote find command..."
ssh "$remote_host" "cd $remote_vault_dir_path && pwd && ls -la | head -5"

# Normalize path encoding
# Doesn't quite work
normalize_array_nfc() {
  command -v python3 >/dev/null 2>&1 || return 0  # no-op if python missing
  local -n _arr="$1"
  
  # If array is empty, nothing to do
  [[ ${#_arr[@]} -eq 0 ]] && return 0
  
  local temp_result=()
  mapfile -d '' temp_result < <(
    printf '%s\0' "${_arr[@]}" |
    python3 -c '
import sys, unicodedata
data = sys.stdin.buffer.read().split(b"\0")
for b in data:
    if not b: continue
    s = b.decode("utf-8","surrogatepass")
    print(unicodedata.normalize("NFC", s), end="\0")
'
  )
  
  # Only update array if we got results
  if [[ ${#temp_result[@]} -gt 0 ]]; then
    _arr=("${temp_result[@]}")
  fi
}

normalize_array_nfc tracked_files
normalize_array_nfc remote_files


# Remote set for membership tests (using raw paths for comparison)
declare -A remote_set=()
for p in "${remote_files[@]}"; do
  remote_set["$p"]=1
done

# Tracked locally but absent on remote => remote deletion happened
deleted_files_remote=()
for p in "${tracked_files[@]}"; do
  # Check both the path as-is and check if file actually exists locally
	  if [[ -z ${remote_set["$p"]+_} ]] && [[ -f "$local_vault_path/$p" ]]; then
    deleted_files_remote+=("$p")
  fi
done

# Deleted locally since last commit (git knows) => local deletion happened
mapfile -t deleted_files_local < <(git -C "$local_vault_path" ls-files --deleted)

#--------DEBUGGGING
echo "remote_files count: ${#remote_files[@]}"
echo "tracked_files count: ${#tracked_files[@]}"
echo "deleted_files_remote count: ${#deleted_files_remote[@]}"
echo "deleted_files_local count: ${#deleted_files_remote[@]}"
#----------------------------


echo "Seed: $seed"
if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ $seed == false ]]; then
  del_opts=(-a --delete-missing-args --ignore-missing-args)
  [[ $do_dryrun == true ]] && del_opts+=(--dry-run)

  echo "Starting Rsync deletions"
  if [[ $do_dryrun == true ]]; then
    echo "NOTE: running in DRY-RUN mode; rsync will include --dry-run"
  fi


# Delete on remote the files missing locally
  if (( ${#deleted_files_local[@]} > 0 )); then
    echo ">>> Executing rsync to delete on remote <<<"
    tmp="$(mktemp)"
    printf '%s\n' "${deleted_files_local[@]}" \
      | sed -E 's#^\./##' \
      | grep -Ev '(^|/)\.(git|obsidian|trash)(/|$)' > "$tmp"
    echo "Files-to-delete list: $tmp (showing first 10 entries)"
    head -n 10 "$tmp" || true
    # show command for clarity (safe to run since del_opts contains --dry-run when appropriate)
    echo "Running: rsync ${del_opts[*]} --files-from='$tmp' '$local_src' '$remote_host:$remote_vault_dir_path'"
    rsync "${del_opts[@]}" \
      --files-from="$tmp" \
      "$local_src" "$remote_host:$remote_vault_dir_path"
    rm -f "$tmp"
  else
    echo ">>> No files to delete on remote <<<"
  fi

# Delete on local the files missing on remote
  if (( ${#deleted_files_remote[@]} > 0 )); then
    echo ">>> Executing rsync to delete locally <<<"
    tmp="$(mktemp)"
    printf '%s\n' "${deleted_files_remote[@]}" \
      | sed -E 's#^\./##' \
      | grep -Ev '(^|/)\.(git|obsidian|trash)(/|$)' > "$tmp"
    echo "Files-to-delete list: $tmp (showing first 10 entries)"
    head -n 10 "$tmp" || true
    # show command for clarity
    echo "Running: rsync ${del_opts[*]} --files-from='$tmp' '$remote_host:./storage/shared/Obsidian/' '$local_src'"
    rsync "${del_opts[@]}" \
      --files-from="$tmp" \
      "$remote_host:./storage/shared/Obsidian/" "$local_src"
    rm -f "$tmp"
  else
    echo ">>> No files to delete locally <<<"
  fi


elif git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ $seed ]]; then 
	# On seed, we have never transfered files, so we just want to transfer and set our status to 1
	# We also don't worry about deletions.
	# so we won't overwrite anything in the remote, they will be added as new in the next sync assuming they ahdn't been tracked yet
	# We just continue, the script, do nothing here
  echo "We are in seed mode"
	:
else
  echo "Not a git repo at $local_vault_path; To avoid side effects and mistakes, the operation is aborted."
  exit 1
fi

# ----------------- Updates both ways -----------------

rsync -ah "${RSYNC_DRY[@]}" --update --itemize-changes \
  --exclude=".git/" --exclude=".obsidian/" --exclude=".trash/"\
  "$local_src" "$remote_host:$remote_vault_dir_path"

rsync -ah "${RSYNC_DRY[@]}" --update --itemize-changes \
  --exclude=".git/" --exclude=".obsidian/" --exclude=".trash/" \
  "$remote_host:$remote_vault_dir_path" "$local_src"

# ----------------- Git bookkeeping -----------------

if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ $do_dryrun == false ]]; then
    git -C "$local_vault_path" add -A
    if ! git -C "$local_vault_path" diff --cached --quiet; then
      git -C "$local_vault_path" commit -m "Update at $(date +'%Y-%m-%d %H:%M:%S %z')"
      git -C "$local_vault_path" push
    else
      echo "No changes to commit."
    fi
  else
    echo "DRY-RUN: skipping git add/commit/push. Local status (what would change):"
    git -C "$local_vault_path" status --porcelain || true
  fi
else
  echo "Not a git repo at $local_vault_path; skipping git steps."
fi

