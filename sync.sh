#!/bin/bash
set -euo pipefail

# Usage: sync.sh <local_vault_path> [--realrun] 
# Exit if unset or null
: "${1:?Usage: $(basename "$0") <local_vault_path> [--realrun] }"

# local_vault_path should be the supervault path
local_vault_path="$1"
# does the local_vault_path exist?
(! [[ $local_vault_path ]]) && echo "The provided path is not valid, pelase specify a valid paht"
remote_host="termux"
# let ~ not expand
remote_vault_dir_path='~/storage/shared/Obsidian/'

do_dryrun=true
[[ ${2:-} == '--realrun' ]] && do_dryrun=false

# Whether to transfer the contents of the dir or the dir itself

echo "Local:  $local_vault_path"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"

# Assume that local_vault-path has an endign forward slash, will be corrected
# Directly following if not 
local_vault_slash=$local_vault_path
local_vault_no_slash=${local_vault_path%/}

# Only support the sending of directory
# Correct for above assumption if needed
[[ $local_vault_path != */ ]] && $local_vault_slash="${local_vault_path}/" && $local_vault_no_slash = $local_vault_path


# I thought I would need the slashing above for the enxt step, but I don't 

mapfile -t tracked_files < <(git -C $local_vault_path ls-files)

# Build rsync options
# Only update, do not delete
rsync_opts=(-aivhP --update --exclude=".git/" --exclude=".obsidian/" --exclude="*.gitignore")
[[ $do_dryrun == true ]] && rsync_opts+=(--dry-run)
