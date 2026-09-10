<h1 align="center">📦 dev-snapshot</h1>

<p align="center">
  One encrypted archive of your source tree — <em>minus the 8 GB a package manager can rebuild.</em>
</p>

<p align="center">
  <img alt="Bash" src="https://img.shields.io/badge/bash-4.2%2B-4eaa25">
  <img alt="Dependencies" src="https://img.shields.io/badge/dependencies-tar%20%7C%20gpg-brightgreen">
  <img alt="Encryption" src="https://img.shields.io/badge/encryption-GPG%20required-8957e5">
  <a href="https://github.com/kingletas/dev-snapshot/actions/workflows/ci.yml"><img alt="CI" src="https://github.com/kingletas/dev-snapshot/actions/workflows/ci.yml/badge.svg"></a>
  <img alt="License" src="https://img.shields.io/badge/license-MIT-green">
</p>

---

```bash
make plan       # what it would archive, what it would drop, how big
make regular    # tar → compress → encrypt → verify, in one stream
make slim       # documents only — no history, logs, archives or large files
```

## Why

A development directory is mostly not yours. Ours was 23 GB, and 8 GB of that was `node_modules`, Terraform provider binaries, virtualenvs and `__pycache__` — bytes that come back with one command and that no backup needs to carry. What is left is irreplaceable: the git history of repositories that were never pushed anywhere, the `.env` files, the half-finished branch.

`dev-snapshot` archives the second thing and skips the first, encrypts the result, and then **proves it can read it back** before telling you it worked.

## Install

```bash
git clone https://github.com/kingletas/dev-snapshot && cd dev-snapshot && make install
```

`bash`, GNU `tar`, and `gpg`. `zstd` for the default compressor — `--compress gzip` needs nothing extra. `make install` copies `bin/dev-snapshot` and its rulesets into `~/bin`; `make install PREFIX=/usr/local/bin` for anywhere else, and `make` on its own lists every target.

New to it? [`docs/from-nothing.md`](docs/from-nothing.md) walks through a first snapshot and restore on a practice tree.

## Configure it once

```bash
mkdir -p ~/.config/dev-snapshot
cat > ~/.config/dev-snapshot/config <<'CFG'
SOURCE    = /home/you/src
DEST      = /media/you/backup/Snapshots
RECIPIENT = YOUR_GPG_KEY_ID
CFG
```

Then `dev-snapshot create` needs no arguments. The file is **parsed, never sourced** — a config that gets `source`d is a config that can run commands, and this one names the directory a backup tool is pointed at.

## Look before you leap

```bash
dev-snapshot create -n
```

```text
  tree         23.1GB
  excluded     7.6GB  in 611 directories
  to archive   15.5GB

  !! 191 path(s) could not be read and are NOT in this snapshot.

Biggest exclusions:
       1.2GB  python/weather-bot/infra/terraform/.terraform
     682.6MB  docker/shop/webroot/vendor
     444.0MB  ansible-playbooks/playbooks/php-installer/.venv
```

A dry run writes nothing and takes about as long as the scan — thirteen seconds over 800,000 files.

That 13.3 GB is **what goes in, not what comes out**. On this tree the finished file is **6.4 GB**, a ratio of 2.1x — lower than a source tree suggests, because 2.9 GB of what survives the ruleset is `.git` pack data that is already deflated. The whole run, verification included, takes about three minutes.

Do not extrapolate a ratio from a subtree. A source-heavy 2.4 GB slice of this same tree compressed 5.8x, which would have predicted 2.3 GB.

## The rule the whole tool rests on

> **A directory name is a weak claim, so the interesting rules are guarded.**

`vendor` means *Composer cache, delete freely* next to a `composer.json` and *hand-written source* everywhere else. On the tree this was built for, one `vendor/` held **38 cloned git repositories with uncommitted work in them**. A rule matching on the name alone would have dropped all 38 and reported a clean backup.

So rules carry guards:

| Guard | Fires when | Catches |
|---|---|---|
| `sibling:composer.json` | that file sits **next to** the candidate | the real Composer cache, not a `vendor/` full of repos |
| `has:pyvenv.cfg` | that file sits **inside** the candidate | a real virtualenv, not a directory someone called `env` |
| `-` | always | `node_modules`, `__pycache__`, `.terraform` |

`dev-snapshot rules` prints the whole set with a live count of what each one matches in your tree.

## What it deliberately keeps

`.git`, because on a machine where repositories have no remote it is the only copy of the history. `dist` and `build`, because both are committed source often enough to matter and came to 86 MB here anyway. `.env` files, because they are usually irreplaceable — which is an argument for encrypting the archive, not for thinning it.

Add your own in `~/.config/dev-snapshot/rules`, same tab-separated format, applied after the shipped set. Things specific to your machine — a MySQL data directory, a framework's regenerated cache — belong there rather than in the shipped ruleset.

## Three things it refuses to get wrong

**Symlinks are stored as symlinks and never followed.** There is no flag to turn this on. The tree this was written against holds `docker/tmp -> /tmp` and a symlink pointing at an 11 GB sibling; `tar -h` would have pulled the entire system temp directory into a snapshot of a source tree and stored the sibling twice.

**A partial archive is deleted, never kept.** `gpg` will happily encrypt a truncated `tar` stream and hand you a file that decrypts perfectly and restores half a tree — the worst outcome available, because it looks fine. Every stage's exit status is checked through `PIPESTATUS`, and anything short of a clean run takes the output file with it.

**A file that could not be read is named, not skipped quietly.** 191 paths on this machine are unreadable without `sudo`. They are excluded so `tar` does not die at 90%, reported on the console, and written into the manifest inside the archive. A gap you know about is survivable; a gap you do not is not a backup.

## Verification is the default

```text
Verifying checksum ...
  sha256 matches
Reading the archive back ...
  3086 members read
  VERIFIED -- this snapshot decrypts and reads end to end.
```

The checksum is taken by **reading the file back off the destination**, not by tapping the stream on its way past. Hashing the stream certifies bytes that were computed; on a removable drive the question is what landed on the disk, and those are different questions.

Then it decrypts the whole archive, decompresses it and walks every member, comparing the count against the manifest. `--no-verify` skips it for an unattended run — and says so in the output, rather than letting an unverified snapshot look like a verified one.

## Restoring

```bash
dev-snapshot verify   /media/you/backup/Snapshots/20260826-src.tar.zst.gpg
dev-snapshot restore  /media/you/backup/Snapshots/20260826-src.tar.zst.gpg  ~/restored
```

The archive is an ordinary `tar`, so it restores without this tool too:

```bash
gpg --decrypt 20260826-src.tar.zst.gpg | zstd -d | tar -xf - -C ~/restored
```

That is deliberate. A backup you can only open with one particular script is a backup with a dependency, and `SNAPSHOT-MANIFEST.txt` at the root of every archive spells out this command along with what was excluded and what could not be read.

It reads archives it did not write, too. `verify` and `restore` accept `.tgz.gpg`, `.tar.gz.gpg` and `.tar.xz.gpg` — so the hand-rolled `tar | gzip | gpg` files this tool replaced still open with it.

## Slim snapshots

`make regular` carries everything a package manager cannot rebuild — the git history included, which on this tree is 2.9 GB of already-compressed pack files. That is the snapshot you want when the disk dies, and it is not the one you want to take every day.

```bash
make slim
```

**Documents only.** No repository history, no logs, no archives, no compiled binaries, no video, and **no file over 10 MB** — a size cap, because a rule can name a category of large thing but not every large thing. Measured on the tree this was built for:

| | Goes in | File written | Ratio |
|---|--:|--:|--:|
| `make regular` | 13.3 GB | **6.4 GB** | 2.1x |
| `make slim` | 7.8 GB | **2.0 GB** | 3.9x |

Slim compresses *better* precisely because the incompressible part is what it dropped.

> [!warning]
> A slim snapshot is deliberately lossy and says so everywhere it can: on the console, in the `.sha256` sidecar, and in a banner at the top of the manifest inside the archive. **Every file the size cap dropped is listed there by name.** It carries no history, so it must never be the only copy of a repository that has no remote.

It lands under its own `-slim` label, so it never collides with a regular snapshot and — since `prune` is label-scoped — never consumes their retention either. `--max-file-size 50M` moves the cap.

## Adding your own rules

```bash
make rules-add NAME=.cache WHY="tool cache"
make rules-add NAME=target GUARD=sibling:Cargo.toml WHY="cargo build output"
make rules-add NAME='*.bak' KIND=file WHY="editor backup"
```

It writes to `~/.config/dev-snapshot/rules` — never to the shipped ruleset, which the next install replaces — and then **re-scans and tells you what the rule actually matches**, because a rule that matches nothing and a rule that is spelled wrong look identical in a file.

## Everything else

```bash
make list                    # snapshots at the destination, with dates
make rules                   # the ruleset, and what it matches here
make verify FILE=path        # decrypt one and read it back
make restore FILE=x DIR=y    # unpack it
make prune KEEP=3            # delete all but the newest three of one label
make check                   # the test suite, shellcheck and ruleset validation
```

Every target is a thin wrapper over the command, so `dev-snapshot --help` still works for anything the Makefile does not cover — `--symmetric` for a passphrase instead of a key, `--no-rule vendor` to drop one rule for a run, `--compress gzip`.

`prune` orders by modification time rather than by name — this tool's own collision suffix makes the newer file sort first — and only ever touches snapshots carrying the same label, so two trees can share one destination safely.

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — the pipeline, the discovery pass, and why each is shaped that way
- [`SECURITY.md`](SECURITY.md) — what is in the archive, what the encryption does and does not protect
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — the four rules that outrank style
