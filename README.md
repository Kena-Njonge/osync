# osync

`osync` is a small personal project that keeps two directories in sync across machines. It wraps `rsync` and `git` so that your files (and the history around them) stay aligned with as little ceremony as possible.

## Why osync?

- Works over plain SSH, so any reachable host can participate without extra services.
- Leverages `rsync` under the hood for efficient, resumable transfers and archive-friendly behavior.
- Tracks directories through a `.vault-directories` ledger and git integration, making version control straightforward.
- Resolves conflicts in favor of the newest change to keep day-to-day usage friction free.
- Supports UTF-8 filenames, allowing for emojis and non ASCII characters to be transferred without issue

If you have used tools like Unison, this project will feel familiar, but the git-native mindset and reliance on ubiquitous tooling make it easy to tweak for your own workflow.

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

- Inclusion of ignore-file logic like .gitignore, possible unification to keep file and dir ignoring under .gitignore, this does not affect the .vault-directories, which serves a different purpose.
- Full refactor to streamline the code structure and configuration story.
- Potential support for non-SSH transports (open to feedback).
- Friendlier surface area around the `.vault-directories` ledger and automation hooks.

## Contributing

Contributions are welcome! Please be aware:

- This is a solo-maintained project and code reviews can take time—thanks in advance for your patience.
- A sweeping refactor is on the horizon, so major changes might be held until that lands.
- Prefer readable, self-describing code and include context in your pull requests about the problem you are solving.
- Add tests or usage notes if you touch the sync behavior so it is easy to verify the change.

If you have questions or ideas, feel free to open an issue or draft PR so we can discuss the best path forward.

## License

osync is released under the MIT License. See `LICENSE` for the full text.
