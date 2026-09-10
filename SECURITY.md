# Security Policy

## Reporting a vulnerability

**Please do not open a public issue.** Use GitHub's private vulnerability reporting on this repository (*Security* → *Report a vulnerability*), or email **code@kingletas.com**.

Include what you did, what happened, and what you expected. This is a personal project maintained by one person, so expect a first response in days rather than hours.

## Supported versions

The latest release on `main` is the supported version. Fixes ship forward.

## What is in the archive

**Everything in the source tree that was not excluded — including your secrets.** `.env` files, private keys checked into a repository, API tokens in a config, the `.git` history that still holds a credential someone deleted in a later commit. This is on purpose: those are the files least able to survive losing the disk.

It is also why **there is no unencrypted mode**. `--compress none` exists; a `--no-encrypt` does not, and a patch adding one will not be merged.

## The failure mode this project treats as most serious

**A snapshot that looks complete and is not.**

`gpg` encrypts a stream. Hand it a `tar` that died at 60% and it produces a perfectly valid encrypted file that decrypts cleanly, decompresses cleanly, and restores most of a tree. Nothing about it looks wrong until the day you need the part that is missing.

Three things exist because of that:

- Every stage's exit status is checked through `PIPESTATUS`, and a non-zero from any of them deletes the output. The archive is written to a `.partial` name and renamed only after the whole pipeline succeeds.
- `tar` exit **1** (a file changed or vanished mid-read) and exit **2** (fatal) are handled separately. Collapsing them would either fail every run on a live tree or accept a broken archive.
- Verification decrypts the archive and walks every member by default, comparing the count against what was written.

**If you find a case where a snapshot is incomplete and the tool said it was fine, that is the report this project most wants.**

## What the encryption does and does not protect

| | |
|---|---|
| **Protects** | The contents of the archive, at rest, on a drive somebody else may pick up. |
| **Does not protect** | The filename. `20260826-src.tar.zst.gpg` says what it is and when. |
| **Does not protect** | The `.sha256` sidecar, which is plaintext metadata: date, source path, member count, sizes, and the recipient key id. |
| **Does not protect** | Anything, if the key is gone. See below. |

**The sidecar deliberately holds no file listing.** A plaintext index of every path sitting next to an encrypted archive gives away most of what the encryption was for. The full listing goes *inside* the archive, and the local run log stays on the machine that already has the files.

## Key custody is the part that actually loses data

**Encrypting to a GPG key means the archive is worth exactly as much as the secret key.** On most machines that key lives in `~/.gnupg` — and `~/.gnupg` is frequently *not* in whatever backup set covers the rest of the home directory. Losing the disk then loses both the tree and the ability to read the snapshot of it.

Before relying on this tool:

- Confirm the secret key is backed up **somewhere other than the machine being snapshotted**, and that you can decrypt with that copy.
- If you use `--symmetric`, the passphrase is the whole thing. **Never store it inside the tree being snapshotted** — that is a passphrase encrypted with itself.
- Test a restore. `dev-snapshot verify` proves the archive reads; only a restore proves you can still get in.

## The tool's own attack surface

| Surface | Handling |
|---|---|
| **The config file** | Parsed as `KEY=VALUE`, never `source`d. Keys are whitelisted and an unknown key is reported. There is no path by which the config runs a command. |
| **The ruleset** | Tab-separated data. A rule contributes a directory name or a `tar` pattern; it cannot contribute a command. |
| **Filenames in the tree** | Passed to `tar` through `--exclude-from` files, one path per line, with `--no-wildcards` so metacharacters in real paths stay literal. No file list is ever interpolated into a command string. |
| **Passphrases** | Read from a file or from the terminal via `gpg-agent`. Never accepted as a command-line argument, so never visible in `ps`. |
| **Symlinks** | Stored, never followed. A symlink out of the tree cannot pull its target in. |
| **The destination** | Written to a dotfile `.partial` and renamed on success. An existing snapshot is never overwritten; a same-day second run takes a distinct name. |
| **`prune`** | Scoped to one label, ordered by mtime, refuses `--keep 0`, and prompts unless `-y`. |

## Known limits

- **A path containing a newline** will not be excluded correctly. The exclusion list is line-oriented, as is `tar --exclude-from`. Such a path is archived rather than dropped, so the failure is toward including too much.
- **`--ignore-failed-read` is on.** A file that vanishes mid-run becomes a warning rather than a fatal error, because a 20-minute archive should not die on one temp file. The warning count is reported and the warnings are kept in the run log.
- **The archive is not signed.** It is encrypted to a key, which tells you nobody else read it; it does not prove who wrote it.
