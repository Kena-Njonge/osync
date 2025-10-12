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


# Maybe we need a different seeding script, so on the first run, we run the
# seed script to just copy stuff over 
# So after that we would be correct in assuming that if something is tracked
# But not in remote, then it is wrong. 

# I forgot why I needed this, but I will need it in a moment
# Also could be called local files 
mapfile -t tracked_files < <(git -C "$local_vault_path" ls-files)

# Remote files, full list
mapfile -t remote_files  < <(rsync -ah --dry-run --delete --itemize-changes "$local_vault_path" "$remote_host:$remote_vault_dir_path)" --exclude=".git/" --exclude='.obsidian/' --out-format='%n'


declare -A set

for path in $remote_files;do
	set["$path"]=1
done;

deleted_files_remote=()
for path in tracked_files; do
	# If it is true that it is unset or null in the remote
	if [[ ${set[$path]:-0} ]];then
		$deleted_files_remote=("${deleted_files_remote[@]}" "$path") 
	fi
done

# Send update, so now all files that should be deleted (deleted on local)
# Will be deleted

mapfile -t remote_files  < <(rsync -ah --dry-run --delete --itemize-changes "$local_vault_path" "$remote_host:$remote_vault_dir_path)" --exclude=".git/" --exclude='.obsidian/' --out-format='%n'


