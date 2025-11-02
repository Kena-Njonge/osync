# osync

`osync` is a small personal project that keeps two directories in sync across machines. It wraps `rsync` and `git` so that your files (and the history around them) stay aligned with as little ceremony as possible.

## Why osync?

- Works over plain SSH, so any reachable host can participate without extra services.
- Leverages `rsync` under the hood for efficient, resumable transfers and archive-friendly behavior.
- Tracks directories through a `.vault-directories` ledger and git integration, making version control straightforward.
- Resolves conflicts in favor of the newest change to keep day-to-day usage friction free.
- Supports UTF-8 filenames, allowing for emojis and non ASCII characters to be transferred without issue

If you have used tools like Unison, this project will feel familiar, but the git-native mindset and reliance on ubiquitous tooling make it easy to tweak for your own workflow.

Osync is an independent project; it is neither affiliated with nor endorsed by Obsidian.

## How it works

The primary entry point is `osync.sh`. Given a local directory path, a remote host, and a remote directory, it will:

1. Validate that the local directory exists, the remote directory is reachable over SSH, and the local tree is a git repository.
2. Load `.vault-directories`, which keeps the authoritative list of directories that should exist on both sides (or create it during seeding).
3. Run `rsync` in both directions (dry-run by default) while keeping the directory ledger in sync.
4. During a real run, clean up stale directories, stage the touched paths, and commit/push the result so the directory history follows the file transfers.

## Requirements

- Bash 5.x (uses associative arrays and `local -n` name references).
- `rsync` 3.x or newer.
- `ssh` with key-based access to the remote host.
- `git`; the local directory must be a git repository so the script can stage, commit, and push updates.
- `python3` is only needed when `SYNC_DEBUG=true` to pretty-print raw byte diagnostics.

## Usage

```
./osync.sh <local_dir_path> <remote_host> <remote_directory> [--realrun] [--seed]
```

- `--realrun` applies the rsync changes, prunes directories, and commits/pushes. Without it, the script performs a dry run and prints what would happen.
- `--seed` bootstraps the `.vault-directories` ledger from the union of existing directories. Pair it with `--realrun` the first time you connect two directories.
- Flags can appear in any order after the three required positional arguments.
- `remote_host` should normally be an alias defined in your `~/.ssh/config` so authentication details stay out of the command line; a raw `user@hostname` string works too, but the alias keeps repeat runs tidy.

Notes on ignores:
- `--ignore DIR` accepts directory paths only. Anything under that directory stays out of rsync, the deletion passes, and git staging.
- `.gitignore` affects git status as usual but does not stop osync from transferring files; ignored files continue to sync unless their parent directories are excluded with `--ignore`.

### Safety options (env vars)

- `SYNC_HOT_WINDOW` (seconds, default `3`): skips files whose mtime is within the last N seconds to avoid racing with editors that truncate-then-write. Set to `0` to disable if you prefer immediate syncing during active edits.
- `SYNC_BACKUP` (`true`/`false`, default `false`): when `true`, keeps a local backup of any file that would be overwritten during the remote→local pass under `.osync-backups/<timestamp>/remote-to-local/`. The backup directory is excluded from sync.

Example with systemd user service:
```
[Service]
Environment=SYNC_HOT_WINDOW=5
Environment=SYNC_BACKUP=true
```

## Getting started

1. Clone or copy this repository on the machine that hosts your target local directory.
2. Ensure the target directory is a git repository (`git init` + initial commit if you are starting from scratch).
3. Add the remote host to your SSH config (e.g., `~/.ssh/config`) and verify you can connect without prompts; make sure the target remote directory already exists.
4. Perform the first synchronization and seed the directory ledger:
During this sync the history will be unified, meaning the resulting synced directory will include files and dirs from both dirs.
   ```bash
   ./osync.sh /path/to/local/dir <host> /path/to/remote/dir --seed --realrun --ignore ... --ignore ...
   ```
   Adjust the host and remote path to match your environment.
5. For day-to-day syncs, run a quick dry run to confirm the pending changes:
   ```bash
   ./osync.sh /path/to/local/dir  <host> /path/to/remote/dir --ignore ... --ignore ...
   ```
   Follow it with a real run when everything looks good:
   ```bash
   ./osync.sh /path/to/local/dir  <host> /path/to/remote/dir --realrun  --ignore ... --ignore ...
   ```

## Roadmap

- **Single ignore spec**  
    Consolidate exclusion rules into one file (e.g., `.syncignore`) with three scopes:
    
    - `ignore = all` (default; skip for **backup and transfer**)
        
    - `ignore = transfer` (skip **only** on transfer)
        
    - `ignore = backup` (skip **only** on backup)  
        CLI override: `--ignore-scope all|transfer|backup`. Back-compat: import from existing `.gitignore` and `--ignore` flags.
        
- **Simple versioning & conflict handling**  
    When a **true conflict** is detected (both sides changed since common ancestor), don’t clobber:
    
    - Keep mainline with the chosen winner (configurable: `newest-wins` or `source-wins`).
        
    - Create a side branch at `conflict/<relpath>/<timestamp>` with the other version.
        
- **Automated LAN discovery for SSH**  
    Automatically find peers on the same LAN and reconnect without prompts.
    
- **Additional transports (non-SSH)**  
    Add pluggable transports behind a simple interface.


## Contributing

Contributions are welcome! Please be aware:

- This is a solo-maintained project and code reviews can take time—thanks in advance for your patience.
- Prefer readable, self-describing code and include context in your pull requests about the problem you are solving.
- Add tests or usage notes if you touch the sync behavior so it is easy to verify the change.

If you have questions or ideas, feel free to open an issue or draft PR so we can discuss the best path forward.

## License

osync is released under the MIT License. See `LICENSE` for the full text.
