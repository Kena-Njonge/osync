#!/bin/bash
set -euo pipefail

# Capture the repo status ahead of the run so we know which paths were
# already modified/added/deleted when the sync started.
collect_status_paths() {
  local -n _dest="$1"
  local raw_entries=()
  mapfile -d '' raw_entries < <(git -C "$local_vault_path" status --porcelain -z || printf '')

  _dest=()
  local -A seen=()
  local idx=0
  local total=${#raw_entries[@]}

  while (( idx < total )); do
    entry="${raw_entries[idx]}"
    ((idx++))
    [[ -z "$entry" ]] && continue

    local status="${entry:0:2}"
    local path="${entry:3}"

    [[ -n "$path" ]] && seen["$path"]=1
  done

  for path in "${!seen[@]}"; do
    _dest+=("$path")
  done
}

declare -A paths_to_stage=()
declare -a tracked_files=()
declare -a remote_files=()
declare -a remote_dirs=()
declare -a local_dirs=()
declare -a deleted_files_local=()
declare -a deleted_files_remote=()
declare -A remote_dir_set=()
declare -A local_dir_set=()
declare -A remote_set=()

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

# Ensure UTF-8 locale so non-ASCII filenames are handled predictably
export LANG=${LANG:-en_US.UTF-8}



refresh_inventory() {
  # Collect tracked paths relative to repo root (NUL-delimited to preserve bytes)
  mapfile -d '' tracked_files < <(git -C "$local_vault_path" ls-files -z)

  # Remote inventories gathered with C locale to avoid locale-specific comparisons
  mapfile -d '' remote_files < <(
    ssh "$remote_host" "cd $remote_vault_dir_path && \
      LC_ALL=C find . -type f ! -path '*/.git/*' ! -path '*/.obsidian/*' ! -path '*/.trash/*' -print0 2>/dev/null"
  )

  # Trim leading ./ added by find
  for idx in "${!remote_files[@]}"; do
    remote_files[$idx]="${remote_files[$idx]#./}"
  done

  # Mirror remote directory inventory so we can prune empty folders later
  mapfile -d '' remote_dirs < <(
    ssh "$remote_host" "cd $remote_vault_dir_path && \
      LC_ALL=C find . -type d ! -path '*/.git*' ! -path '*/.obsidian*' ! -path '*/.trash*' -print0 2>/dev/null"
  )

  for idx in "${!remote_dirs[@]}"; do
    remote_dirs[$idx]="${remote_dirs[$idx]#./}"
  done

  # Same survey locally; using C locale keeps byte-order stable prior to normalization
  mapfile -d '' local_dirs < <(
    cd "$local_vault_path" && \
    LC_ALL=C find . -type d ! -path '*/.git*' ! -path '*/.obsidian*' ! -path '*/.trash*' -print0 2>/dev/null
  )

  for idx in "${!local_dirs[@]}"; do
    local_dirs[$idx]="${local_dirs[$idx]#./}"
  done

  # Helper to run the list through Python's NFC normalizer if python3 is present
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
  normalize_array_nfc remote_dirs
  normalize_array_nfc local_dirs

  remote_dir_set=()
  # Skip empty strings and the literal "." entry that find can emit
  for dir in "${remote_dirs[@]}"; do
    [[ -z "$dir" || "$dir" == "." ]] && continue
    remote_dir_set["$dir"]=1
  done

  local_dir_set=()
  for dir in "${local_dirs[@]}"; do
    [[ -z "$dir" || "$dir" == "." ]] && continue
    local_dir_set["$dir"]=1
  done

  remote_set=()
  for p in "${remote_files[@]}"; do
    remote_set["$p"]=1
  done

  mapfile -d '' deleted_files_local < <(git -C "$local_vault_path" ls-files --deleted -z)
  normalize_array_nfc deleted_files_local

  deleted_files_remote=()
  for p in "${tracked_files[@]}"; do
    if [[ -z ${remote_set["$p"]+_} ]] && [[ -f "$local_vault_path/$p" ]]; then
      deleted_files_remote+=("$p")
    fi
  done
}

should_skip_path() {
  local path="$1"
  [[ "$path" =~ (^|/)\.(git|obsidian|trash)(/|$) ]]
}

# Ensure remote/local deletions settle before we run the bidirectional sync
# Ensure remote/local deletions settle before we run the bidirectional sync.
# The routine loops until both sides agree, handling files first and then
# pruning now-empty directories so the later rsync passes don’t resurrect them.
reconcile_deletions() {
  local iteration=1
  local remote_file_actions=0
  local remote_dir_actions=0
  local local_file_actions=0
  local local_dir_actions=0
  local summary_printed=false

  while true; do
    # Refresh listings so every pass works with the on-disk state from the
    # previous one (otherwise we risk re-creating folders we just removed).
    refresh_inventory

    remote_delete_files=()
    remote_dirs_to_prune=()
    declare -A remote_dir_seen=()

    # For every locally deleted path still present remotely, mark files and prune empty dirs
    for f in "${deleted_files_local[@]}"; do
      f=${f#./}
      if should_skip_path "$f"; then
        continue
      fi
      if [[ -n ${remote_set["$f"]+} ]]; then
        remote_delete_files+=("$f")
      fi

      cur="$f"  # walk up the path to see if parent directories became empty
      while [[ "$cur" == */* ]]; do
        cur="${cur%/*}"
        [[ -z "$cur" || "$cur" == "." ]] && break

        # If directory does not exist locally, exists remotely and hasn't been queued for deletion
        if [[ -z ${local_dir_set["$cur"]+} && -n ${remote_dir_set["$cur"]+} && -z ${remote_dir_seen["$cur"]+} ]]; then
          remote_dir_seen["$cur"]=1
          remote_dirs_to_prune+=("$cur")
        elif [[ -n ${local_dir_set["$cur"]+} ]]; then
          break
        fi
      done
    done

    # Sweep remaining remote directories deepest-first to catch empty folders
    for (( idx=${#remote_dirs[@]}-1; idx>=0; idx-- )); do
      dir="${remote_dirs[idx]}"
      if should_skip_path "$dir"; then
        continue
      fi
      [[ -z "$dir" || "$dir" == "." ]] && continue
      # If dir has been deleted locally, and hasn't been queued for deletion
      if [[ -z ${local_dir_set["$dir"]+} && -z ${remote_dir_seen["$dir"]+} ]]; then
        remote_dir_seen["$dir"]=1
        remote_dirs_to_prune+=("$dir")
      fi
    done

    local_delete_files=()
    local_dirs_to_prune=()
    declare -A local_dir_seen=()

    # Mirror the same logic for deletions that happened on the remote side
    for f in "${deleted_files_remote[@]}"; do
      f=${f#./}
      if should_skip_path "$f"; then
        continue
      fi
      if [[ -f "$local_vault_path/$f" ]]; then
        local_delete_files+=("$f")
      fi

      cur="$f"
      while [[ "$cur" == */* ]]; do
        cur="${cur%/*}"
        [[ -z "$cur" || "$cur" == "." ]] && break

        if [[ -z ${remote_dir_set["$cur"]+} && -n ${local_dir_set["$cur"]+} && -z ${local_dir_seen["$cur"]+} ]]; then
          local_dir_seen["$cur"]=1
          local_dirs_to_prune+=("$cur")
        elif [[ -n ${remote_dir_set["$cur"]+} ]]; then
          break
        fi
      done
    done

    # Deepest-first local directory sweep, removing folders orphaned remotely
    for (( idx=${#local_dirs[@]}-1; idx>=0; idx-- )); do
      dir="${local_dirs[idx]}"
      if should_skip_path "$dir"; then
        continue
      fi
      [[ -z "$dir" || "$dir" == "." ]] && continue
      if [[ -z ${remote_dir_set["$dir"]+} && -z ${local_dir_seen["$dir"]+} ]]; then
        local_dir_seen["$dir"]=1
        local_dirs_to_prune+=("$dir")
      fi
    done

    if (( ${#remote_delete_files[@]} == 0 && ${#remote_dirs_to_prune[@]} == 0 && ${#local_delete_files[@]} == 0 && ${#local_dirs_to_prune[@]} == 0 )); then
      if (( iteration == 1 )); then
        echo ">>> No files to delete on remote <<<"
        echo ">>> No directories to prune on remote <<<"
        echo ">>> No files to delete locally <<<"
        echo ">>> No directories to prune locally <<<"
        summary_printed=true
      fi
      break
    fi

    echo "Deletion pass #$iteration"

    if (( ${#remote_delete_files[@]} > 0 )); then
      echo ">>> Remote deletions queued (${#remote_delete_files[@]}) <<<"
      remote_file_actions=$((remote_file_actions + ${#remote_delete_files[@]}))
      printf '%s\n' "${remote_delete_files[@]}" | head -n 10
      for path in "${remote_delete_files[@]}"; do
        paths_to_stage["$path"]=1
      done
      if [[ $do_dryrun == true ]]; then
        echo "DRY-RUN: skipping remote deletions"
      else
        printf '%s\0' "${remote_delete_files[@]}" | \
          ssh "$remote_host" "cd $remote_vault_dir_path && xargs -0 rm -f --"
      fi
    fi

    if (( ${#remote_dirs_to_prune[@]} > 0 )); then
      echo "Remote directories to prune (${#remote_dirs_to_prune[@]}):"
      remote_dir_actions=$((remote_dir_actions + ${#remote_dirs_to_prune[@]}))
      printf '%s\n' "${remote_dirs_to_prune[@]}" | head -n 10
      if [[ $do_dryrun == true ]]; then
        echo "DRY-RUN: skipping remote directory pruning"
      else
        printf '%s\0' "${remote_dirs_to_prune[@]}" | \
          ssh "$remote_host" "cd $remote_vault_dir_path && while IFS= read -r -d '' dir; do rmdir -- \"\$dir\" 2>/dev/null || true; done"
      fi
    fi

    if (( ${#local_delete_files[@]} > 0 )); then
      echo ">>> Local deletions queued (${#local_delete_files[@]}) <<<"
      local_file_actions=$((local_file_actions + ${#local_delete_files[@]}))
      printf '%s\n' "${local_delete_files[@]}" | head -n 10
      for path in "${local_delete_files[@]}"; do
        paths_to_stage["$path"]=1
      done
      if [[ $do_dryrun == true ]]; then
        echo "DRY-RUN: skipping local deletions"
      else
        for f in "${local_delete_files[@]}"; do
          rm -f -- "$local_vault_path/$f"
        done
      fi
    fi

    if (( ${#local_dirs_to_prune[@]} > 0 )); then
      echo "Local directories to prune (${#local_dirs_to_prune[@]}):"
      local_dir_actions=$((local_dir_actions + ${#local_dirs_to_prune[@]}))
      printf '%s\n' "${local_dirs_to_prune[@]}" | head -n 10
      if [[ $do_dryrun == true ]]; then
        echo "DRY-RUN: skipping local directory pruning"
      else
        for dir in "${local_dirs_to_prune[@]}"; do
          if [[ -d "$local_vault_path/$dir" ]]; then
            rmdir -- "$local_vault_path/$dir" 2>/dev/null || true
          fi
        done
      fi
    fi

    ((iteration++))
  done

  if [[ $summary_printed == false ]]; then
    if (( remote_file_actions == 0 )); then
      echo ">>> No files to delete on remote <<<"
    fi
    if (( remote_dir_actions == 0 )); then
      echo ">>> No directories to prune on remote <<<"
    fi
    if (( local_file_actions == 0 )); then
      echo ">>> No files to delete locally <<<"
    fi
    if (( local_dir_actions == 0 )); then
      echo ">>> No directories to prune locally <<<"
    fi
  fi
}

process_rsync_log() {
  local logfile="$1"
  [[ $do_dryrun == true ]] && return 0

  # Each rsync run drops its itemized output into a temp file; harvest paths for staging
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    # Ignore rsync summary lines
    [[ "$line" == *"sent "* && "$line" == *"bytes"* ]] && continue
    [[ "$line" == "sending incremental file list" ]] && continue
    [[ "$line" == "building file list"* ]] && continue
    [[ "$line" == "created directory"* ]] && continue
    [[ "$line" == "total size is"* ]] && continue
    [[ "$line" == "total transferred file size"* ]] && continue

    # rsync out-format starts with the change flag, so drop that and record the path
    local path="${line#* }"
    [[ -z "$path" ]] && continue
    path="${path%% -> *}"
    path="${path#./}"
    path="${path%/}"
    [[ -z "$path" ]] && continue
    paths_to_stage["$path"]=1
  done < "$logfile"
}

# Wrapper around rsync to capture --itemize-changes output and feed staging list
run_tracked_rsync() {
  local tmp
  tmp="$(mktemp)"
  set +e
  rsync "$@" --itemize-changes --out-format='%i %n%L' | tee "$tmp"
  local rsync_exit=${PIPESTATUS[0]}
  set -e
  process_rsync_log "$tmp"
  rm -f "$tmp"
  return $rsync_exit
}

echo "Testing remote find command..."
ssh "$remote_host" "cd $remote_vault_dir_path && pwd && ls -la | head -5"

refresh_inventory

echo "remote_files count: ${#remote_files[@]}"
echo "tracked_files count: ${#tracked_files[@]}"
echo "deleted_files_remote count: ${#deleted_files_remote[@]}"
echo "deleted_files_local count: ${#deleted_files_local[@]}"


echo "Seed: $seed"
if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ $seed == false ]]; then
  echo "Starting deletion reconciliation"
  if [[ $do_dryrun == true ]]; then
    echo "NOTE: running in DRY-RUN mode; destructive operations are skipped"
  fi

  # Remember which paths were dirty before we touched anything, so staging stays scoped
  initial_status_paths=()
  collect_status_paths initial_status_paths
  for path in "${initial_status_paths[@]}"; do
    paths_to_stage["$path"]=1
  done

  reconcile_deletions

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

run_tracked_rsync -ah "${RSYNC_DRY[@]}" --update \
  --exclude=".git/" --exclude=".obsidian/" --exclude=".trash/" \
  "$local_src" "$remote_host:$remote_vault_dir_path"

run_tracked_rsync -ah "${RSYNC_DRY[@]}" --update \
  --exclude=".git/" --exclude=".obsidian/" --exclude=".trash/" \
  "$remote_host:$remote_vault_dir_path" "$local_src"

# ----------------- Git bookkeeping -----------------

if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ $do_dryrun == false ]]; then
    if (( ${#paths_to_stage[@]} > 0 )); then
      # Only stage what the run touched (initial status + deletions + rsync diffs)
      while IFS= read -r -d '' path; do
        [[ -z "$path" ]] && continue
        git -C "$local_vault_path" add -- "$path"
      done < <(printf '%s\0' "${!paths_to_stage[@]}")
    fi

    mapfile -d '' remaining_status < <(git -C "$local_vault_path" status --porcelain -z)
    leftover=false
    # Warn if new worktree changes popped up mid-run; we still commit the staged subset.
    for entry in "${remaining_status[@]}"; do
      [[ -z "$entry" ]] && continue
      if (( ${#entry} < 3 )) || [[ "${entry:2:1}" != ' ' ]]; then
        continue
      fi
      stage_char="${entry:0:1}"
      work_char="${entry:1:1}"
      if [[ "$stage_char$work_char" == "??" || "$work_char" != ' ' ]]; then
        leftover=true
        break
      fi
    done

    if [[ $leftover == true ]]; then
      echo "Warning: additional unstaged changes detected; committing staged paths only."
    fi

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
