# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **`--source` has no default and must be set.** It used to default to a directory on the author's machine. Set `SOURCE` in `~/.config/dev-snapshot/config`, set `SNAPSHOT_SOURCE`, or pass `--source`; with none of them, every command that reads the settings exits 2 and says `no source`.
- **CI runs `make check`** on ubuntu-latest, where it used to restate the same steps on two Ubuntu versions.

### Added

- **A release workflow.** Pushing a tag such as `v1.2.0` checks that the tag matches `dev-snapshot --version`, runs `make check`, proves `make install` works, and publishes a GitHub Release whose body is that version's section of this file.

## [1.1.0]

### Added

- **A `Makefile`, and it is the interface.** `make install`, `make regular`, `make slim`, `make check` — bare `make` lists every target out of the file's own `##` comments, so there is nothing to keep in step with a README. `scripts/install` still exists and the Makefile calls it; nobody is told to type it.
- **`make slim` — documents only.** No repository history, no logs, no archives, no compiled binaries, no video, and no file over 10 MB. On the tree this was built for: regular is 13.3 GB in and 6.4 GB written, slim is 7.8 GB in and **2.0 GB** written. Slim compresses *better* — 3.9x against 2.1x — precisely because the incompressible part is what it dropped.
- **`--max-file-size`**, because a rule can name a category of large thing but not every large thing. **Every file the cap drops is listed by name in the manifest inside the archive**, and the count is net of files already inside an excluded directory, so two honest numbers do not add up to more than the tree.
- **A slim snapshot announces itself everywhere it can** — on the console, in the `.sha256` sidecar, and in a banner at the top of the manifest. It also takes its own `-slim` label, so it never collides with a regular snapshot and, because `prune` is label-scoped, never consumes their retention either.
- **`rules add`**, and `make rules-add NAME=… GUARD=… WHY=…`. It writes to the **user** ruleset rather than the shipped one — a rule written into the shipped file would be replaced by the next install without a word — then re-scans and reports what the rule actually matches. A rule that matches nothing and a rule that is spelled wrong look identical in a file, so it says which one this is.
- **The manifest now carries the exact command that restores the archive without this tool**, per compressor.

## [1.0.0]

### Added

- **`create`** — one stream from `tar` through a compressor through `gpg` to the destination. Nothing unencrypted is ever written to disk, including no intermediate tarball, so the tool needs no scratch space the size of the tree.
- **Guarded exclusion rules.** A directory name is a weak claim: `sibling:composer.json` distinguishes a Composer cache from a `vendor/` holding 38 cloned repositories, and `has:pyvenv.cfg` distinguishes a virtualenv from a directory somebody called `env`. On the tree this was built for, the unguarded version of those two rules would have deleted work that exists nowhere else.
- **A two-phase discovery pass.** The walk is deliberately not pruned at a candidate, because a candidate whose guard *fails* stays in the archive and a `node_modules` nested inside it still has to be found. Nested exclusions are collapsed afterwards so nothing is counted twice.
- **`-n`** — the plan, the sizes, the biggest exclusions and the per-rule tally, writing nothing. Thirteen seconds over 800,000 files.
- **`verify`, and it is the default after every create.** The checksum is taken by reading the file back off the destination rather than by tapping the stream, then the archive is decrypted, decompressed and walked member by member, with the count compared against what was written.
- **`restore`, `list`, `rules`, `prune`, `self-test`.**
- **A manifest inside every archive** carrying the source, the ruleset applied, every excluded directory, every path that could not be read, and the plain `gpg | zstd | tar` command that restores it without this tool.
- **Symmetric encryption** via `--symmetric`, with the passphrase read from a file or from `gpg-agent` — never from a command-line argument, so never visible in `ps`.
- **Eighty-five tests** over real temporary trees, needing no key generation and no network.

### Security

- **Symlinks are stored, never followed, and there is no flag to change that.** The tree this was written against holds `docker/tmp -> /tmp` and a symlink to an 11 GB sibling.
- **The config file is parsed, never sourced.** A whitelisted `KEY=VALUE` reader with an unknown-key warning, because a config that gets `source`d is a config that can run commands.
- **Filenames reach `tar` only through `--exclude-from` files under `--no-wildcards`**, so a `[` in a real path stays literal and no file list is ever interpolated into a command string.
- **There is no unencrypted mode.** The archive holds `.env` files, private keys and git history by design, since those are the files least able to survive losing the disk.
- **A GPG preflight runs before the archive starts** — a missing, expired or untrusted key fails in under a second rather than after an hour of compression.

### Fixed

Found while building, each with a test:

- **`PIPESTATUS` read from inside a command substitution** described the assignment rather than the pipeline, so `verify` lost every stage's exit status and a truncated archive passed verification.
- **An `EXIT` trap written against `local` variables** expanded to empty strings once the function frame was gone, so a failed run left its half-written `.partial` archive at the destination — precisely the file the trap existed to remove.
- **`set -e` ended the run at the first unreadable directory**, because `du` exits 1 there and the call sat inside an assignment. Every real tree has one, and the run died after the whole scan with nothing printed.
- **Argument parsing stopped at the first positional**, so `restore FILE DIR --passphrase-file P` silently dropped the passphrase and reported a decryptable archive as damaged.
- **`prune` ordered snapshots lexically**, and this tool's own same-day collision suffix makes the newer name sort first — so it offered to delete the newest snapshot and keep the oldest. It now orders by modification time and is scoped to a single label, so two trees can share a destination.
- **The per-rule tally counted candidates rather than final exclusions**, reporting 5,232 `__pycache__` directories against a total of 611 — two true numbers that read as a bug.
- **`sed file | head -5` killed the run before a single byte was archived.** Once `head` has its lines it exits, `sed` takes `SIGPIPE`, and under `set -e` with `pipefail` the pipeline returns 141. It is a race on the pipe buffer, so it hid through every test: measured, 20 lines never trigger it, 200 lines trigger it about one run in five, and 1,000 lines trigger it every time. The first full-scale run — 191 unreadable paths — died at that line. Every truncating pipeline now reads with `head` and formats afterwards, the one place an early exit is wanted is marked and has its status deliberately unchecked, and a shape check in the test suite refuses any new `| head` in the tool.
- **The free-space check reserved half the uncompressed size**, on the strength of a 2.4 GB subtree that compressed 5.8x. The real 13.3 GB tree compresses **2.1x**, because 2.9 GB of it is already-deflated `.git` pack data — so half left 4% of headroom on a check whose entire job is to refuse before spending an hour. It now reserves the full uncompressed size, which is the only floor that is always true.
- **The confirmation prompt stated the input size as though it were the output size** — *"Write 13.3GB to <file>"* for a file that turned out to be 6.4 GB. It now says what the number measures and does not invent a prediction for the one it does not.
