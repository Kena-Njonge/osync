#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$PROJECT_ROOT/osync.sh"

# remote_host should be a profile that you have saved to your config, for the purporses of testing
remote_host=${REMOTE_HOST:?Set REMOTE_HOST to an SSH profile}


log() { printf '[test] %s\n' "$*"; }

if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "$remote_host" true >/dev/null 2>&1; then
  log "Skipping tests: unable to reach SSH host '$remote_host'"
  exit 0
fi

tmp_bare_repo=$(mktemp -d /tmp/sync-bare.XXXX)
tmp_local=$(mktemp -d /tmp/sync-local.XXXX)
tmp_remote=$(ssh "$remote_host" "mktemp -d /tmp/sync-remote.XXXX")

# Prepare bare repository so pushes succeed.
git init --bare -q "$tmp_bare_repo"

cleanup() {
  rm -rf "$tmp_bare_repo" "$tmp_local"
  ssh "$remote_host" "rm -rf '$tmp_remote'"
}
trap cleanup EXIT

git -C "$tmp_local" init -q
# Just hygiene, so git doesn't complain
git -C "$tmp_local" config user.name 'Sync Test'
git -C "$tmp_local" config user.email 'sync@test.local'
git -C "$tmp_local" remote add origin "$tmp_bare_repo"
touch "$tmp_local/.gitignore"
git -C "$tmp_local" add .
git -C "$tmp_local" commit -q -m 'Initial'
git -C "$tmp_local" push -q -u origin HEAD

run_sync() {
  "$SCRIPT" "$tmp_local" "$remote_host" "$tmp_remote" --realrun "$@" 
}

# Run sync with a hard timeout to simulate interruption
run_sync_timeout() {
  log "In timeout Function"
  local seconds="$1"; shift
  if command -v timeout >/dev/null 2>&1; then
    # Send TERM after timeout, then KILL if it doesn't exit shortly.
    # Prevent set -e from triggering 
    timeout --preserve-status --signal=TERM --kill-after=2 "$seconds" \
      "$SCRIPT" "$tmp_local" "$remote_host" "$tmp_remote" --realrun "$@" \
   || true
  else
    log "timeout(1) not available; skipping interrupted-transfer simulation"
    return 0
  fi
  log "Timed out"
}

remote_find_any() {
  local pattern="$1"
  ssh "$remote_host" "sh -c 'find '\''$tmp_remote'\'' -type f -path '\''$tmp_remote/$pattern'\'' -print -quit | grep -q .'"
}

assert_file_exists_remote() {
  ssh "$remote_host" "test -f '$tmp_remote/$1'"
}

assert_file_missing_remote() {
  ssh "$remote_host" "test ! -e '$tmp_remote/$1'"
}

assert_file_exists_local() {
  [[ -f "$tmp_local/$1" ]]
}

assert_file_missing_local() {
  [[ ! -e "$tmp_local/$1" ]]
}

file_size_local() {
  stat -c %s "$tmp_local/$1"
}

file_size_remote() {
  ssh "$remote_host" "stat -c %s '$tmp_remote/$1'"
}

# Seed 
run_sync --seed

log 'Test: local addition propagates to remote'
printf 'local content\n' > "$tmp_local/local.txt"
run_sync
assert_file_exists_remote "local.txt"

log 'Test: remote addition propagates to local'
ssh "$remote_host" "printf 'remote content\n' > '$tmp_remote/remote.txt'"
run_sync
assert_file_exists_local "remote.txt"

log 'Test: local deletion propagates to remote'
rm "$tmp_local/local.txt"
run_sync
assert_file_missing_remote "local.txt"

log 'Test: ignored directory stays local'
mkdir -p "$tmp_local/ignored_dir/sub"
printf 'ignored' > "$tmp_local/ignored_dir/sub/file.txt"
run_sync --ignore ignored_dir
assert_file_missing_remote "ignored_dir/sub/file.txt"
rm -rf "$tmp_local/ignored_dir"

log 'Test: ignored directory stays remote'
ssh "$remote_host" "mkdir -p '$tmp_remote/ignored_remote/sub'"
ssh "$remote_host" "printf ignored > '$tmp_remote/ignored_remote/sub/file.txt'"
run_sync --ignore ignored_remote
assert_file_missing_local "ignored_remote/sub/file.txt"
ssh "$remote_host" "rm -rf '$tmp_remote/ignored_remote'"

log 'Test: remote deletion propagates to local'
ssh "$remote_host" "rm '$tmp_remote/remote.txt'"
run_sync
assert_file_missing_local "remote.txt"

log 'Test: directory creation and deletion propagate to remote'
mkdir -p "$tmp_local/nested/inner"
printf 'nested' > "$tmp_local/nested/inner/file.txt"
run_sync
assert_file_exists_remote "nested/inner/file.txt"
ssh "$remote_host" "rm -rf '$tmp_remote/nested'"
run_sync
assert_file_missing_local "nested"

log 'Test: directory creation and deletion propagate to local'
ssh "$remote_host" "mkdir -p '$tmp_remote/nested_2/inner'"
ssh "$remote_host" "printf 'nested' > '$tmp_remote/nested_2/inner/file.txt'"
run_sync
assert_file_exists_local "nested_2/inner/file.txt"
ssh "$remote_host" "rm -rf '$tmp_remote/nested_2'"
run_sync
assert_file_missing_remote "nested_2"

git -C "$tmp_local" status --porcelain >/dev/null

#
# Interrupted transfer behavior with partial-dir + delay-updates
#
if command -v timeout >/dev/null 2>&1; then
  log 'Test: interrupted local->remote transfer keeps partial only'
  # Create a sufficiently large file to ensure transfer runs long enough
  # 200MB
  dd if=/dev/zero of="$tmp_local/big_local.bin" bs=1M count=200 status=none
  expected_local_size=$(file_size_local big_local.bin)
  # Start sync and interrupt quickly
  run_sync_timeout 7
  # After interruption, canonical file should not be in place remotely yet
  if assert_file_missing_remote "big_local.bin"; then
    # A partial may exist under .rsync-partial (but not guaranteed if we aborted very early)
    if remote_find_any ".rsync-partial/big_local.bin*"; then
      log 'Remote partial exists (expected)'
    else
      log 'No remote partial found (early abort); continuing'
    fi
  else
    log 'Note: big_local.bin finished before timeout; skipping partial assertion'
  fi
  # Complete the sync and verify sizes match
  run_sync
  assert_file_exists_remote "big_local.bin"
  actual_remote_size=$(file_size_remote big_local.bin)
  if [[ "$actual_remote_size" != "$expected_local_size" ]]; then
    log "Error: size mismatch after resumed sync (remote=$actual_remote_size local=$expected_local_size)"
    exit 1
  else
    log "Size agreement after resumed rsync"  
  fi

  log 'Test: interrupted remote->local transfer keeps partial only'
  ssh "$remote_host" "dd if=/dev/zero of='$tmp_remote/big_remote.bin' bs=1M count=200 status=none"
  expected_remote_size=$(file_size_remote big_remote.bin)
  run_sync_timeout 7
  if assert_file_missing_local "big_remote.bin"; then
    if [[ -d "$tmp_local/.rsync-partial" ]] && \
       find "$tmp_local/.rsync-partial" -type f -name 'big_remote.bin*' -print -quit | grep -q .; then
      log 'Local partial exists (expected)'
    else
      log 'No local partial found (early abort); continuing'
    fi
  else
    log 'Note: big_remote.bin finished before timeout; skipping partial assertion'
  fi
  run_sync
  assert_file_exists_local "big_remote.bin"
  actual_local_size=$(file_size_local big_remote.bin)
  if [[ "$actual_local_size" != "$expected_remote_size" ]]; then
    log "Error: size mismatch after resumed sync (local=$actual_local_size remote=$expected_remote_size)"
    exit 1
  else
    log "Size agreement after resumed rsync"  
  fi
fi

log 'All tests passed'
