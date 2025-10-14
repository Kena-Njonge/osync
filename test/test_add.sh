#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
SCRIPT="$PROJECT_ROOT/sync_raw.sh"

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
  "$SCRIPT" "$tmp_local" "$remote_host" "$tmp_remote" --realrun "$@" > /dev/null
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

log 'All tests passed'
