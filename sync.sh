#!/bin/bash
set -euo pipefail

# Usage: script.sh <local_vault_path> [--realrun]
: "${1?Usage: $(basename "$0") <local_vault_path> [--realrun]}"

# local_vault_path can also be the supervault path
local_vault_path="$1"
remote_host="termux"
remote_vault_dir_path='~/storage/shared/Obsidian/'i

do_dryrun=true
[[ ${2-} == '--realrun' ]] && do_dryrun=false

echo "Local:  $local_vault_path"
echo "Remote: $remote_host:$remote_vault_dir_path"
echo "Mode:   $([[ $do_dryrun == true ]] && echo DRY-RUN || echo REAL RUN)"


# Whether to transfer the contents of the dir or the dir itself
do_dir=true
[[ ${3-} == '--filetrans' ]] && do_dir=false 

# Is there a trailing /
if [[local_vault_path ~= .*\\ & do_dir]]; then
	$local_vault_path=$local_vault_path
else
	# Add trailing /
	$local_vault_path="$local_vault_path/"



# Build rsync options
rsync_opts=(-aivhP --delete)
[[ $do_dryrun == true ]] && rsync_opts+=(--dry-run)

rsync "${rsync_opts[@]}" \
  "$local_vault_path" \
  "$remote_host:$remote_vault_dir_path"

