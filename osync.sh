#!/bin/bash
# osync - Git-aware vault synchronization script
# Copyright (c) 2025 Kena Njonge
# Licensed under the MIT License. See LICENSE for details.
set -euo pipefail

current_timestamp() {
  date +"%Y-%m-%d %H:%M:%S %z"
}

log_message() {
  local level="$1"
  shift || true
  local ts message
  ts="$(current_timestamp)"
  message="$*"
  case "$level" in
    ERROR|WARN)
    # Pritn to fd 2 i.e. stderr
      printf '[%s] [%s] %s\n' "$ts" "$level" "$message" >&2
      ;;
    *)
      printf '[%s] [%s] %s\n' "$ts" "$level" "$message"
      ;;
  esac
}

log_info() {
  log_message INFO "$@"
}

log_warn() {
  log_message WARN "$@"
}

log_error() {
  log_message ERROR "$@"
}

# Capture the repo status ahead of the run so we know which paths were
# already modified/added/deleted when the sync started.
collect_status_paths() {
  local -n _dest="$1"
  local raw_entries=()
  exec {git_status_fd}< <(git -C "$local_vault_path" status --porcelain -z)
  local git_status_pid=$!
  if ! mapfile -d '' -u "$git_status_fd" raw_entries; then
    exec {git_status_fd}<&-
    wait "$git_status_pid" || true
    log_error "Failed to read git status for $local_vault_path"
    return 75
  fi
  exec {git_status_fd}<&-
  if ! wait "$git_status_pid"; then
    local rc=$?
    log_error "Failed to read git status for $local_vault_path (exit $rc)"
    return 75
  fi

  _dest=()
  local -A seen=()
  local idx=0
  local total=${#raw_entries[@]}

  while (( idx < total )); do
    entry="${raw_entries[idx]}"
    # Not += because 0 would cause fail 
    (( idx+=1 ))
    [[ -z "$entry" ]] && continue


    # -z prints the paths on seperate lise if they are renamed, so we have to do that
    local path="$entry"

    if (( ${#entry} >= 3 )) && [[ "${entry:2:1}" == ' ' ]]; then
      path="${entry:3}"
    fi

    if should_skip_path "$path"; then
      continue
    fi
    [[ -n "$path" ]] && seen["$path"]=1
  done
  
  # Iterate over keys of associative array
  for path in "${!seen[@]}"; do
    _dest+=("$path")
  done
}

declare -A paths_to_stage=()
declare -a tracked_files=()
declare -a remote_files=()
declare -a remote_dirs=()
declare -a local_files=()
declare -a local_dirs=()
declare -a deleted_files_local=()
declare -a deleted_files_remote=()
declare -a ignore_dirs=()
declare -a RSYNC_EXCLUDES=()
declare -A remote_dir_set=()
declare -A local_dir_set=()
declare -A remote_set=()
declare -A remote_dir_has_files=()
declare -A local_dir_has_files=()
declare -A ignore_dir_set=()

debug_enabled=${SYNC_DEBUG:-false}

debug_log() {
  [[ "$debug_enabled" != true ]] && return 0
  log_message DEBUG "$@"
}

debug_dump_array() {
  [[ "$debug_enabled" != true ]] && return 0
  local -n _arr="$1"
  local label="$2"
  debug_log "$label (${#_arr[@]})"
  for item in "${_arr[@]}"; do
    debug_log "         $item"
  done
}

debug_dump_bytes() {
  [[ "$debug_enabled" != true ]] && return 0
  local label="$1"
  local value="$2"
  local hex
  hex=$(printf '%s' "$value" | python3 - <<'PY'
import sys, binascii
data = sys.stdin.buffer.read()
sys.stdout.write(binascii.hexlify(data).decode('ascii'))
PY
)
  debug_log "$label bytes: $hex"
}

# Quote path correctly so that we don't expand ~ locally
quote_remote_path() {
  local path="$1"
  if [[ "$path" == ~* ]]; then
    local prefix rest
    prefix="${path%%/*}"
    rest="${path#"$prefix"}"
    if [[ "$rest" == "$path" ]]; then
      printf '%s' "$prefix"
      return
    fi
    printf '%s%s' "$prefix" "$(printf '%q' "$rest")"
  else
    printf '%q' "$path"
  fi
}

# Add a Directory to the ignore set
add_ignore_dir() {
  local dir="$1"

  if [[ -z "$dir" ]]; then
    log_error "Ignore directory cannot be empty."
    exit 1
  fi

  # Normalize: remove leading ./, trailing /, enforce relative path
  while [[ "$dir" == ./* ]]; do
    dir="${dir#./}"
  done
  dir="${dir%/}"

  if [[ -z "$dir" || "$dir" == "." ]]; then
    log_error "Ignore directory cannot reference the repository root."
    exit 1
  fi
  if [[ "$dir" == /* ]]; then
    log_error "Ignore directories must be relative to the directory of the script (no leading /): $dir"
    exit 1
  fi
  if [[ "$dir" == *"../"* || "$dir" == ".." || "$dir" == "../" ]]; then
    log_error "Ignore directories cannot traverse upward: $dir"
    exit 1
  fi

  # No need for globs, excluding a dir excludes everything underneath it also
  if [[ "$dir" == *"*"* || "$dir" == *"?"* || "$dir" == *"["* ]]; then
    log_error "Ignore directories cannot include glob characters: $dir"
    exit 1
  fi

  if [[ -v ignore_dir_set["$dir"] ]]; then
    return
  fi

  ignore_dirs+=("$dir")
  ignore_dir_set["$dir"]=1
}

# Essentially build the prune command and or'd expression that will be used to ignore
# the directories when they match, thus the find won't return/process them further
build_find_prune_components() {
  local -n _dest="$1"
  _dest=()
  (( ${#ignore_dirs[@]} == 0 )) && return

  _dest+=("(")
  local first=true
  local dir normalized path
  for dir in "${ignore_dirs[@]}"; do

    normalized="${dir%/}"
    [[ -z "$normalized" ]] && continue
    path="./$normalized"
    if [[ $first == false ]]; then
      _dest+=("-o")
    fi
    _dest+=("-path" "$path")
    _dest+=("-o" "-path" "$path/*")
    first=false
  done
  # Short-circuit the prune
  _dest+=(")" "-prune" "-o")
}

# Assemble full find args (start dir, optional prune block, type filter, print0).
# print0 (NUL-separated output) only fires when the prune condition is not met.
make_find_args() {
  local type="$1"
  local -n _dest="$2"
  _dest=(".")
  local -a prune_parts=()
  build_find_prune_components prune_parts
  if (( ${#prune_parts[@]} > 0 )); then
    _dest+=("${prune_parts[@]}")
  fi
  _dest+=("-type" "$type" "-print0")
}

# Just convenience function to bundle in the creation of the find command, calls the above 2 functions
make_remote_find_command() {
  local type="$1"
  local -a args=()
  make_find_args "$type" args
  local cmd="LC_ALL=C find"
  local arg
  for arg in "${args[@]}"; do
    cmd+=" $(printf '%q' "$arg")"
  done
  cmd+=" 2>/dev/null"
  printf '%s' "$cmd"
}

ledger_filename=".vault-directories"
ledger_local_path=""
declare -A ledger_prev_set=()

log_info "Arguments: $*"


usage="Usage: $(basename "$0") <local_path> <remote_host> <remote_dir> [--realrun] [--seed] [--ignore DIR]..."
if (( $# < 3 )); then
  log_error "$usage"
  exit 1
fi

local_vault_path="$1"
remote_host="$2"
remote_vault_dir_path="$3"
shift 3

# Allow flags in either order
do_dryrun=true
seed=false
add_ignore_dir ".git"
while (($#)); do
  case "$1" in
    --realrun)
      do_dryrun=false
      shift
      ;;
    --seed)
      seed=true
      shift
      ;;
    --ignore)
      if (( $# < 2 )); then
        log_error "--ignore requires a directory argument."
        log_error "$usage"
        exit 1
      fi
      add_ignore_dir "$2"
      shift 2
      ;;
    --ignore=*)
      add_ignore_dir "${1#*=}"
      shift
      ;;
    *)
      log_error "Unknown argument: $1"
      log_error "$usage"
      exit 1
      ;;
  esac
done

local_src="${local_vault_path%/}/"
remote_vault_dir_path="${remote_vault_dir_path%/}/"

# Validate local dir
if [[ ! -d "$local_vault_path" ]]; then
  log_error "The provided path is not a directory. Please specify a valid path."
  exit 1
fi

remote_dir_shell="$(quote_remote_path "$remote_vault_dir_path")"
remote_rsync_dir="$remote_host:$(quote_remote_path "$remote_vault_dir_path")"

# Validate remote dir
if ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" "test -d $remote_dir_shell"; then
  log_info "Remote dir exists: $remote_host:$remote_vault_dir_path"
else
  log_error "Remote dir NOT found: $remote_host:$remote_vault_dir_path"
  exit 1
fi

# Validate local dir is repository
if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  log_info "We are in a git repository, continuing"
else
  log_error "Please run this code in a git repository, see the tutorial"
  exit 1
fi
# ------- DEBUGGIGN -------
log_info "Local:  $local_src"
log_info "Remote: $remote_host:$remote_vault_dir_path"
current_mode="REAL RUN"
if [[ $do_dryrun == true ]]; then
  current_mode="DRY-RUN"
fi
log_info "Mode:   $current_mode"
# ----------------


# Inject dry-run switch
RSYNC_DRY=()
[[ $do_dryrun == true ]] && RSYNC_DRY=(--dry-run)
RSYNC_EXCLUDES=()
for dir in "${ignore_dirs[@]}"; do
  RSYNC_EXCLUDES+=("--exclude=$dir/")
done

# Ensure UTF-8 locale so non-ASCII filenames are handled predictably
export LANG=${LANG:-en_US.UTF-8}

# Build a sorted union of currently existing local/remote directories
# so the ledger stays authoritative.
build_directory_snapshot() {
  local -n _out="$1"
  declare -A seen=()

  # Don't include cwd . or empty string dirrs
  for dir in "${local_dirs[@]}"; do
    [[ -z "$dir" || "$dir" == "." ]] && continue
    seen["$dir"]=1
  done
  for dir in "${remote_dirs[@]}"; do
    [[ -z "$dir" || "$dir" == "." ]] && continue
    seen["$dir"]=1
  done

  if (( ${#seen[@]} == 0 )); then
    _out=()
    return
  fi

  # Map to array and remove trailing delim
  local snapshot_tmp
  snapshot_tmp="$(mktemp)"
  if ! printf '%s\n' "${!seen[@]}" | LC_ALL=C sort > "$snapshot_tmp"; then
    rm -f "$snapshot_tmp"
    log_error "Failed to build directory snapshot"
    return 75
  fi
  mapfile -t _out < "$snapshot_tmp"
  rm -f "$snapshot_tmp"
}

# Load the existing ledger into memory for fast membership checks during pruning.
load_ledger_into_memory() {
  ledger_prev_set=()
  if [[ -z "$ledger_local_path" || ! -f "$ledger_local_path" ]]; then
    return
  fi

  # Read each line verbatim, ignoring spaces (IFS) and slashes 
  # Or so we don't skip last line
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    ledger_prev_set["$line"]=1
  done < "$ledger_local_path"
}

# Push the ledger to the remote, using --dry-run when requested to surface rsync output.
push_ledger_to_remote() {
  local src="${1:-$ledger_local_path}"
  if [[ -z "$src" || ! -f "$src" ]]; then
    return
  fi
  local -a rsync_flags=(-aivPh)
  if [[ $do_dryrun == true ]]; then
    rsync_flags+=(--dry-run)
  fi

  local target="$remote_host:$(quote_remote_path "${remote_vault_dir_path}${ledger_filename}")"
  rsync "${rsync_flags[@]}" -- "$src" "$target"
}

# Ensure the ledger exists (or seed it) before any pruning logic runs.
ensure_ledger_ready() {
  ledger_local_path="$local_vault_path/$ledger_filename"

  if [[ $seed == true ]]; then
    local -a snapshot=()
    build_directory_snapshot snapshot
    if [[ $do_dryrun == true ]]; then
      log_info "DRY-RUN: ledger initialization skipped (${#snapshot[@]} directories detected)"
      ledger_prev_set=()
      for dir in "${snapshot[@]}"; do
        ledger_prev_set["$dir"]=1
      done
      return
    fi

    # Write directories, both local and remote into the shared ledger
    # Thus this unifies the two "histories" on seed. 
    # Same happens to files i.e. we jsut propagate the files that exist later on
    {
      for dir in "${snapshot[@]}"; do
        printf '%s\n' "$dir"
      done
    } > "$ledger_local_path"
    load_ledger_into_memory
    push_ledger_to_remote
    return
  fi

  if [[ ! -f "$ledger_local_path" ]]; then
    log_error "Ledger file missing locally at $ledger_local_path. Run with --seed to initialize."
    exit 1
  fi

  local tmp
  tmp="$(mktemp)"
  if ! ssh "$remote_host" "cd $remote_dir_shell && cat '$ledger_filename'" > "$tmp"; then
    log_error "Ledger file missing remotely at ${remote_vault_dir_path}${ledger_filename}. Run with --seed to initialize."
    rm -f "$tmp"
    exit 1
  fi

  if ! cmp -s "$ledger_local_path" "$tmp"; then
    log_error "Ledger mismatch between local and remote .vault-directories; aborting to avoid divergence."
    rm -f "$tmp"
    exit 1
  fi
  rm -f "$tmp"

  load_ledger_into_memory
}

# Refresh the ledger after sync; in dry-run we report what would change without touching disk.
finalize_ledger_state() {
  local -a snapshot=()
  build_directory_snapshot snapshot
  local tmp
  tmp="$(mktemp)"
  # Append to end of file
  {
    for dir in "${snapshot[@]}"; do
      printf '%s\n' "$dir"
    done
  } > "$tmp"

  ledger_prev_set=()
  for dir in "${snapshot[@]}"; do
    ledger_prev_set["$dir"]=1
  done

  if [[ $do_dryrun == true ]]; then
    log_info "DRY-RUN: ledger would record ${#snapshot[@]} directories"
    push_ledger_to_remote "$tmp"
    rm -f "$tmp"
    return
  fi

  ledger_local_path="${ledger_local_path:-$local_vault_path/$ledger_filename}"

  # Write vault-directories
  mv "$tmp" "$ledger_local_path"
  paths_to_stage["$ledger_filename"]=1

  push_ledger_to_remote
  load_ledger_into_memory
}


refresh_inventory() {
  # Collect tracked paths relative to repo root (NUL-delimited to preserve bytes)
  # -z sets the delimiter to \0 because it can't be contained in a file name
  exec {tracked_fd}< <(git -C "$local_vault_path" ls-files -z)
  local tracked_pid=$!
  if ! mapfile -d '' -u "$tracked_fd" tracked_files; then
    exec {tracked_fd}<&-
    wait "$tracked_pid" || true
    log_error "Failed to list tracked files for $local_vault_path"
    return 75
  fi
  exec {tracked_fd}<&-
  if ! wait "$tracked_pid"; then
    local rc=$?
    log_error "Failed to list tracked files for $local_vault_path (exit $rc)"
    return 75
  fi

  local remote_find_files_cmd
  remote_find_files_cmd=$(make_remote_find_command "f")
  exec {remote_fd}< <(ssh "$remote_host" "cd $remote_dir_shell && $remote_find_files_cmd")
  remote_pid=$!  # PID of the ssh/find process that’s feeding the FD
  # Remote inventories gathered with C locale to avoid locale-specific comparisons
  if ! mapfile -d '' -u "$remote_fd" remote_files; then
    exec {remote_fd}<&-
    wait "$remote_pid" || true  # swallow to avoid “no child” errors
    log_error "Failed to read remote file list from $remote_host"
    return 75
  fi

  exec {remote_fd}<&-
  if ! wait "$remote_pid"; then
    local rc=$?
    log_error "Failed to list remote files from $remote_host (exit $rc)"
    return 75
  fi

  # Trim leading ./ added by find
  for idx in "${!remote_files[@]}"; do
    remote_files[$idx]="${remote_files[$idx]#./}"
  done

  remote_find_dirs_cmd=$(make_remote_find_command "d")
  exec {remote_fd}< <(ssh "$remote_host" "cd $remote_dir_shell && $remote_find_dirs_cmd")
  remote_pid=$!  
  if ! mapfile -d '' -u "$remote_fd" remote_dirs; then
    exec {remote_fd}<&-
    wait "$remote_pid" || true  # swallow to avoid “no child” errors
    log_error "Failed to read remote directory list from $remote_host"
    return 75
  fi

  exec {remote_fd}<&-
  if ! wait "$remote_pid"; then
    local rc=$?
    log_error "Failed to list remote directories from $remote_host (exit $rc)"
    return 75
  fi

  

  for idx in "${!remote_dirs[@]}"; do
    remote_dirs[$idx]="${remote_dirs[$idx]#./}"
  done

  local -a local_find_dir_args
  make_find_args "d" local_find_dir_args
  # Same survey locally; using C locale keeps byte-order stable prior to normalization
  exec {local_dirs_fd}< <(
    cd "$local_vault_path" && \
    LC_ALL=C find "${local_find_dir_args[@]}" 2>/dev/null
  )
  local local_dirs_pid=$!
  if ! mapfile -d '' -u "$local_dirs_fd" local_dirs; then
    exec {local_dirs_fd}<&-
    wait "$local_dirs_pid" || true
    log_error "Failed to enumerate local directories under $local_vault_path"
    return 75
  fi
  exec {local_dirs_fd}<&-
  if ! wait "$local_dirs_pid"; then
    local rc=$?
    log_error "Failed to enumerate local directories under $local_vault_path (exit $rc)"
    return 75
  fi

  local -a local_find_file_args
  make_find_args "f" local_find_file_args
  # Capture local files directly (not just tracked ones) so pruning honours attachments, etc.
  exec {local_files_fd}< <(
    cd "$local_vault_path" && \
    LC_ALL=C find "${local_find_file_args[@]}" 2>/dev/null
  )
  local local_files_pid=$!
  if ! mapfile -d '' -u "$local_files_fd" local_files; then
    exec {local_files_fd}<&-
    wait "$local_files_pid" || true
    log_error "Failed to enumerate local files under $local_vault_path"
    return 75
  fi
  exec {local_files_fd}<&-
  if ! wait "$local_files_pid"; then
    local rc=$?
    log_error "Failed to enumerate local files under $local_vault_path (exit $rc)"
    return 75
  fi

  for idx in "${!local_dirs[@]}"; do
    local_dirs[$idx]="${local_dirs[$idx]#./}"
  done
  for idx in "${!local_files[@]}"; do
    local_files[$idx]="${local_files[$idx]#./}"
  done

  # Helper to run the list through Python's NFC normalizer if python3 is present
  normalize_array_nfc() {
  command -v python3 >/dev/null 2>&1 || return 0  # no-op if python missing
  local -n _arr="$1"
  
  # If array is empty, nothing to do
  [[ ${#_arr[@]} -eq 0 ]] && return 0
  
  local temp_result=()
  local norm_tmp
  norm_tmp="$(mktemp)"
  if ! printf '%s\0' "${_arr[@]}" | python3 -c '
import sys, unicodedata
data = sys.stdin.buffer.read().split(b"\0")
for b in data:
    if not b: continue
    s = b.decode("utf-8","surrogatepass")
    print(unicodedata.normalize("NFC", s), end="\0")
' > "$norm_tmp"; then
    rm -f "$norm_tmp"
    log_error "Failed to normalize filenames (python3 exited non-zero)"
    return 75
  fi
  if ! mapfile -d '' temp_result < "$norm_tmp"; then
    rm -f "$norm_tmp"
    log_error "Failed to read normalized filenames"
    return 75
  fi
  rm -f "$norm_tmp"
  
  # Only update array if we got results
  if [[ ${#temp_result[@]} -gt 0 ]]; then
    _arr=("${temp_result[@]}")
  fi
}

  normalize_array_nfc tracked_files
  normalize_array_nfc remote_files
  normalize_array_nfc remote_dirs
  normalize_array_nfc local_files
  normalize_array_nfc local_dirs


  remote_dir_has_files=()
  for path in "${remote_files[@]}"; do
    cur="${path%/*}"
    if [[ "$cur" == "$path" ]]; then
      cur=""
    fi
    while [[ -n "$cur" ]]; do
      remote_dir_has_files["$cur"]=1
      if [[ "$cur" == */* ]]; then
        cur="${cur%/*}"
      else
        break
      fi
    done
  done


  local_dir_has_files=()

  for path in "${local_files[@]}"; do
    cur="${path%/*}"
    # If path is . or a file remove it, so that we don't fail trying to walk up
    if [[ "$cur" == "$path" ]]; then
      cur=""
    fi
    while [[ -n "$cur" ]]; do
      local_dir_has_files["$cur"]=1
      if [[ "$cur" == */* ]]; then
        cur="${cur%/*}"
      else
        break
      fi
    done
  done


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

  # No need for local set, we just query the fs to see if it is there later on


  exec {deleted_fd}< <(git -C "$local_vault_path" ls-files --deleted -z)
  local deleted_pid=$!
  if ! mapfile -d '' -u "$deleted_fd" deleted_files_local; then
    exec {deleted_fd}<&-
    wait "$deleted_pid" || true
    log_error "Failed to enumerate locally deleted files for $local_vault_path"
    return 75
  fi
  exec {deleted_fd}<&-
  if ! wait "$deleted_pid"; then
    local rc=$?
    log_error "Failed to enumerate locally deleted files for $local_vault_path (exit $rc)"
    return 75
  fi
  normalize_array_nfc deleted_files_local

  deleted_files_remote=()
  for p in "${tracked_files[@]}"; do
    if [[ ! -v remote_set["$p"] ]] && [[ -f "$local_vault_path/$p" ]]; then
      deleted_files_remote+=("$p")
    fi
  done

  debug_log "refresh_inventory: local_files=${#local_files[@]} remote_files=${#remote_files[@]}"
  debug_dump_array deleted_files_local "deleted_files_local"
  debug_dump_array deleted_files_remote "deleted_files_remote"
}

should_skip_path() {
  local path="${1#./}"
  local ignore
  for ignore in "${ignore_dirs[@]}"; do
    local normalized="${ignore%/}"
    [[ -z "$normalized" ]] && continue
    if [[ "/$path/" == *"/$normalized/"* ]]; then
      return 0
    fi
  done
  return 1
}

# Ensure remote/local deletions settle before we run the bidirectional sync
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

    # For every locally deleted path still present remotely, mark files for deletion
    for f in "${deleted_files_local[@]}"; do
      f=${f#./}
      if should_skip_path "$f"; then
        continue
      fi
      debug_log "checking remote delete candidate: $(printf '%q' "$f")"
      debug_dump_bytes "candidate_bytes" "$f"
      if [[ -v remote_set["$f"] ]]; then
        remote_delete_files+=("$f")
        debug_log "queue remote delete: $(printf '%q' "$f") (remote_has=yes)"
      else
        debug_log "skip remote delete: $(printf '%q' "$f") (remote_has=no)"
      fi
    done

    # Use the ledger snapshot to decide which remote directories no longer have a local peer.
    for (( idx=${#remote_dirs[@]}-1; idx>=0; idx-- )); do
      dir="${remote_dirs[idx]}"
      if should_skip_path "$dir"; then
        continue
      fi
      [[ -z "$dir" || "$dir" == "." ]] && continue
      if [[ ! -v ledger_prev_set["$dir"] ]]; then
        continue
      fi
      if [[ -v local_dir_set["$dir"] ]]; then
        continue
      fi
      if [[ -v remote_dir_has_files["$dir"] ]]; then
        continue
      fi
      remote_dirs_to_prune+=("$dir")
    done

    local_delete_files=()
    local_dirs_to_prune=()

    # Mirror the same logic for deletions that happened on the remote side
    for f in "${deleted_files_remote[@]}"; do
      f=${f#./}
      if should_skip_path "$f"; then
        continue
      fi
      if [[ -f "$local_vault_path/$f" ]]; then
        local_delete_files+=("$f")
      fi
    done

    # Walk local directories deepest-first, removing those that disappeared remotely
    for (( idx=${#local_dirs[@]}-1; idx>=0; idx-- )); do
      dir="${local_dirs[idx]}"
      if should_skip_path "$dir"; then
        continue
      fi
      [[ -z "$dir" || "$dir" == "." ]] && continue
      if [[ ! -v ledger_prev_set["$dir"] ]]; then
        continue
      fi
      if [[ -v remote_dir_set["$dir"] ]]; then
        continue
      fi
      if [[ -v local_dir_has_files["$dir"] ]]; then
        continue
      fi
      local_dirs_to_prune+=("$dir")
    done

    debug_dump_array remote_delete_files "remote_delete_files"
    debug_dump_array remote_dirs_to_prune "remote_dirs_to_prune"
    debug_dump_array local_delete_files "local_delete_files"
    debug_dump_array local_dirs_to_prune "local_dirs_to_prune"

    if (( ${#remote_delete_files[@]} == 0 && ${#remote_dirs_to_prune[@]} == 0 && ${#local_delete_files[@]} == 0 && ${#local_dirs_to_prune[@]} == 0 )); then
      if (( iteration == 1 )); then
        log_info ">>> No files to delete on remote <<<"
        log_info ">>> No directories to prune on remote <<<"
        log_info ">>> No files to delete locally <<<"
        log_info ">>> No directories to prune locally <<<"
        summary_printed=true
      fi
      break
    fi

    log_info "Deletion pass #$iteration"

    if (( ${#remote_delete_files[@]} > 0 )); then
      log_info ">>> Remote deletions queued (${#remote_delete_files[@]}) <<<"
      remote_file_actions=$((remote_file_actions + ${#remote_delete_files[@]}))
      printf '%s\n' "${remote_delete_files[@]}" | head -n 10
      for path in "${remote_delete_files[@]}"; do
        if ! should_skip_path "$path"; then
          paths_to_stage["$path"]=1
        fi
      done
      if [[ $do_dryrun == true ]]; then
        log_info "DRY-RUN: skipping remote deletions"
      else
        log_info "[remote] deleting files:"
        printf '%s\n' "${remote_delete_files[@]}"
        printf '%s\0' "${remote_delete_files[@]}" | \
          ssh "$remote_host" "cd $remote_dir_shell && xargs -0 rm -f --"
      fi
    fi

    if (( ${#remote_dirs_to_prune[@]} > 0 )); then
      log_info "Remote directories to prune (${#remote_dirs_to_prune[@]}):"
      remote_dir_actions=$((remote_dir_actions + ${#remote_dirs_to_prune[@]}))
      printf '%s\n' "${remote_dirs_to_prune[@]}" | head -n 10
      if [[ $do_dryrun == true ]]; then
        log_info "DRY-RUN: skipping remote directory pruning"
      else
        log_info "[remote] pruning directories:"
        printf '%s\n' "${remote_dirs_to_prune[@]}"
        printf '%s\0' "${remote_dirs_to_prune[@]}" | \
          ssh "$remote_host" "cd $remote_dir_shell && while IFS= read -r -d '' dir; do [ -z \"\$dir\" ] && continue; rmdir -- \"\$dir\" 2>/dev/null || true; done"
      fi
    fi

    if (( ${#local_delete_files[@]} > 0 )); then
      log_info ">>> Local deletions queued (${#local_delete_files[@]}) <<<"
      local_file_actions=$((local_file_actions + ${#local_delete_files[@]}))
      printf '%s\n' "${local_delete_files[@]}" | head -n 10
      for path in "${local_delete_files[@]}"; do
        if ! should_skip_path "$path"; then
          paths_to_stage["$path"]=1
        fi
      done
      if [[ $do_dryrun == true ]]; then
        log_info "DRY-RUN: skipping local deletions"
      else
        log_info "[local] deleting files:"
        printf '%s\n' "${local_delete_files[@]}"
        for f in "${local_delete_files[@]}"; do
          rm -f -- "$local_vault_path/$f" || log_warn "failed to delete $f"
        done
      fi
    fi

    if (( ${#local_dirs_to_prune[@]} > 0 )); then
      log_info "Local directories to prune (${#local_dirs_to_prune[@]}):"
      local_dir_actions=$((local_dir_actions + ${#local_dirs_to_prune[@]}))
      printf '%s\n' "${local_dirs_to_prune[@]}" | head -n 10
      if [[ $do_dryrun == true ]]; then
        log_info "DRY-RUN: skipping local directory pruning"
      else
        log_info "[local] pruning directories:"
        printf '%s\n' "${local_dirs_to_prune[@]}"
        for dir in "${local_dirs_to_prune[@]}"; do
          [[ -z "$dir" ]] && continue
          rmdir -- "$local_vault_path/$dir" 2>/dev/null || log_warn "failed to prune directory $dir"
        done
      fi
    fi

    if [[ $do_dryrun == true ]]; then
      log_info "DRY-RUN: stopping deletion reconciliation after simulated pass (tree unchanged)."
      break
    fi

    (( iteration += 1 ))
  done

  if [[ $summary_printed == false ]]; then
    if (( remote_file_actions == 0 )); then
      log_info ">>> No files to delete on remote <<<"
    fi
    if (( remote_dir_actions == 0 )); then
      log_info ">>> No directories to prune on remote <<<"
    fi
    if (( local_file_actions == 0 )); then
      log_info ">>> No files to delete locally <<<"
    fi
    if (( local_dir_actions == 0 )); then
      log_info ">>> No directories to prune locally <<<"
    fi
  fi
}

process_rsync_log() {
  local logfile="$1"
  [[ $do_dryrun == true ]] && return 0

  # The rsync log contains one path per line (thanks to log-file-format), so capture them directly.
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line//$'\r'/}"
    [[ -z "$line" ]] && continue
    # Strip rsync daemon timestamps like YYYY/MM/DD HH:MM:SS [PID] before the filename.
    if [[ "$line" =~ ^[0-9]{4}/[0-9]{2}/[0-9]{2}[[:space:]][0-9]{2}:[0-9]{2}:[0-9]{2}[[:space:]] ]]; then
      line="${line#*[[:space:]]}"
      line="${line#*[[:space:]]}"
      # Literally a space in the regex, lol 
      line="${line#*] }"
    
    # Incase there is not time information at the start
    elif [[ "$line" == *"] "* ]]; then
      line="${line#*] }"
    fi
    # Escaping spaces caues regex patterns are unquoted
    [[ "$line" =~ ^(sent[[:space:]]|sending\ incremental\ file\ list|receiving\ file\ list|building\ file\ list|created\ directory|total\ size\ is|total\ transferred\ file\ size) ]] && continue
    local path="${line%% -> *}"
    path="${path#./}"
    path="${path%/}"
    [[ -z "$path" ]] && continue
    if should_skip_path "$path"; then
      continue
    fi
    paths_to_stage["$path"]=1
  done < "$logfile"
}

# Wrapper around rsync to capture just the transfer list for staging while still printing verbose output.
run_tracked_rsync() {
  local tmp_log
  tmp_log="$(mktemp)"

  # So that rsync doesn't bail out, another bashism
  set +e
  
  rsync --itemize-changes --out-format='%i %n%L' --log-file="$tmp_log" --log-file-format='%n%L' "$@"
  local rsync_exit=$?
  set -e
  process_rsync_log "$tmp_log"
  rm -f "$tmp_log"
  return $rsync_exit
}

log_info "Testing remote find command..."
ssh "$remote_host" "cd $remote_dir_shell && pwd && ls -la | head -5"

refresh_inventory

ensure_ledger_ready

log_info "remote_files count: ${#remote_files[@]}"
log_info "tracked_files count: ${#tracked_files[@]}"
log_info "deleted_files_remote count: ${#deleted_files_remote[@]}"
log_info "deleted_files_remote: ${deleted_files_remote[@]}"
log_info "deleted_files_local count: ${#deleted_files_local[@]}"
log_info "deleted_files_local: ${deleted_files_local[@]}"


log_info "Seed: $seed"
if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1 && [[ $seed == false ]]; then
  log_info "Starting deletion reconciliation"
  if [[ $do_dryrun == true ]]; then
    log_info "NOTE: running in DRY-RUN mode; destructive operations are skipped"
  fi

  # Remember which paths were dirty before we touched anything, so staging stays scoped
  # Dirty meaning M, A, D, ?? in git status--porcelain
  # We remember them before we do anything to prevent race conditions due to changes while working
  # If we were just to stage dirs some chagnes would be lost
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
  # We also create the original dir list, otherwise we wouldn't be able to create or delete dirs lol
  log_info "We are in seed mode"
	:
else
  log_error "Not a git repo at $local_vault_path; To avoid side effects and mistakes, the operation is aborted."
  exit 1
fi

# ----------------- Updates both ways -----------------

run_tracked_rsync -rltivPh "${RSYNC_DRY[@]}" --update \
  "${RSYNC_EXCLUDES[@]}" \
  "$local_src" "$remote_rsync_dir"

run_tracked_rsync -rltivPh "${RSYNC_DRY[@]}" --update \
  "${RSYNC_EXCLUDES[@]}" \
  "$remote_rsync_dir" "$local_src"

# Update inventories post-sync so the ledger reflects the settled state
refresh_inventory
finalize_ledger_state

# ----------------- Git bookkeeping -----------------

if git -C "$local_vault_path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  if [[ $do_dryrun == false ]]; then
    if (( ${#paths_to_stage[@]} > 0 )); then
      # Only stage what the run touched (initial status + deletions + rsync diffs)
      while IFS= read -r -d '' path; do
        [[ -z "$path" ]] && continue
        # Check if the path is ignored
        if git -C "$local_vault_path" check-ignore -q -- "$path"; then
          # If the file is still tracked, untrack it 
          if git -C "$local_vault_path" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
            git -C "$local_vault_path" rm --cached -- "$path" >/dev/null 2>&1 || true
          fi
          log_info "Skipping gitignored path: $path"
          continue
        fi
        # Only stage paths that exist on disk or are still tracked; this avoids
        # spurious pathspec errors once Git has already recorded the removal.
        if [[ -e "$local_vault_path/$path" ]] || git -C "$local_vault_path" ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
          # -A handles renames/deletions where the old path no longer exists locally.
          git -C "$local_vault_path" add -A -- "$path"
        else
          debug_log "skip staging for vanished path: $(printf '%q' "$path")"
        fi
      done < <(printf '%s\0' "${!paths_to_stage[@]}")
    fi

    # Remove files that were ignored but not changed
    # Also include global ignore config and exclude ignores
    exec {ignored_fd}< <(git -C "$local_vault_path" ls-files -ci --exclude-standard -z)
    ignored_pid=$!
    if ! mapfile -d '' -u "$ignored_fd" tracked_gitignored; then
      exec {ignored_fd}<&-
      wait "$ignored_pid" || true
      log_error "Failed to enumerate tracked gitignored files for $local_vault_path"
      return 75
    fi
    exec {ignored_fd}<&-
    if ! wait "$ignored_pid"; then
      local rc=$?
      log_error "Failed to enumerate tracked gitignored files for $local_vault_path (exit $rc)"
      return 75
    fi
    if (( ${#tracked_gitignored[@]} > 0 )); then
      log_info "Cleaning tracked gitignored paths (${#tracked_gitignored[@]})"
      for ignored_path in "${tracked_gitignored[@]}"; do
        [[ -z "$ignored_path" ]] && continue
        git -C "$local_vault_path" rm --cached -- "$ignored_path" >/dev/null 2>&1 || true
      done
    fi

    exec {status_fd}< <(git -C "$local_vault_path" status --porcelain -z)
    status_pid=$!
    if ! mapfile -d '' -u "$status_fd" remaining_status; then
      exec {status_fd}<&-
      wait "$status_pid" || true
      log_error "Failed to refresh git status for $local_vault_path"
      return 75
    fi
    exec {status_fd}<&-
    if ! wait "$status_pid"; then
      local rc=$?
      log_error "Failed to refresh git status for $local_vault_path (exit $rc)"
      return 75
    fi
    leftover=false
    # Warn if new worktree changes popped up mid-run; we still commit the staged subset.
    # If someone is editing while we are running, it is not horrible, but that edit
    # Will be commited in the next batch, not in this batch, we jsut silently warn it is 
    # A minor inconsistency for thsi case
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
      log_warn "Warning: additional unstaged changes detected; committing staged paths only."
    fi

    if ! git -C "$local_vault_path" diff --cached --quiet; then
      git -C "$local_vault_path" commit -m "Update at $(date +'%Y-%m-%d %H:%M:%S %z')"
      git -C "$local_vault_path" push
    else
      log_info "No changes to commit."
    fi
  else
    log_info "DRY-RUN: skipping git add/commit/push. Local status (what would change):"
    git -C "$local_vault_path" status --porcelain || true
  fi
else
  log_warn "Not a git repo at $local_vault_path; skipping git steps."
fi
