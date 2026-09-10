# How dev-snapshot is put together

Four stages, and the interesting decisions are all about what happens when one of them goes wrong.

```
  discovery          archiving                            verification
  ─────────          ─────────                            ────────────
  find ──┐
         ├─▶ guards ──▶ exclude-paths.txt ──┐
  rules ─┘                                  │
                                            ▼
                              tar ─▶ zstd ─▶ gpg ─▶ .partial ──▶ rename
                               │      │       │                     │
                               └──────┴───────┴─▶ PIPESTATUS        ▼
                                                       │        sha256 read back
                                                  any failure         │
                                                       │              ▼
                                                       ▼      gpg ─▶ zstd ─▶ tar -t
                                                 delete .partial       │
                                                                       ▼
                                                                 member count
```

## Discovery is two phases, on purpose

The obvious implementation prunes the walk at every candidate directory: find a `node_modules`, stop descending, move on. It is faster and it is wrong here.

A candidate whose guard **fails** stays in the archive — and things worth excluding live inside it. `docker/shop/vendor` has no `composer.json` beside it, so it is kept; it also contains 38 repositories, some with their own `node_modules`. A pruning walk would never look inside a directory it decided to keep.

So phase one walks everything and collects candidates by name. Phase two evaluates each candidate's guard. Phase three collapses nested results, because a `__pycache__` inside an excluded `.venv` should not be counted twice or handed to `tar` twice.

The full walk costs about half a second over 800,000 files. The pruned version would save nothing worth having.

## Guards

```
kind    name       guard                  why
dir     vendor     sibling:composer.json  composer install
dir     .venv      has:pyvenv.cfg         python virtualenv
dir     target     sibling:Cargo.toml|sibling:pom.xml   cargo/maven build output
```

`sibling:` tests the candidate's parent, `has:` tests the candidate itself, `|` is an OR, `-` is unconditional. Both forms are globs, expanded with `compgen` so that no match is an ordinary false rather than a literal pattern leaking through.

`file` rules take no guard. They become `tar` patterns rather than enumerated paths, so there is no candidate directory to test — which is why they are restricted to things that are junk under all circumstances, like `*.pyc`.

## Exclusion paths have to be rewritten, and getting it wrong is silent

`tar` matches exclusion patterns against the **member name**, and members are prefixed with the source's basename. Discovery produces `docker/shop/webroot/vendor`; `tar` sees `src/docker/shop/webroot/vendor`. Without the rewrite nothing matches, every exclusion is ignored, and the run reports success while archiving the 8 GB it was supposed to skip.

The two exclusion files are handed over with different flags, and the order matters because these options are positional in GNU `tar`:

```
--no-wildcards --anchored    --exclude-from=paths.txt   # literal full paths
--wildcards    --no-anchored --exclude-from=globs.txt   # *.pyc, .DS_Store
```

`--no-wildcards` is what keeps a real directory called `weird [1]` from being read as a character class.

## Unreadable files are excluded rather than met

`tar` exits **2** on a permission-denied read. On this machine 191 paths are unreadable without `sudo`, so a naive run fails — at whatever percent it had reached, after however long.

`--ignore-failed-read` downgrades that to a warning, but warnings scroll past. Instead, discovery finds unreadable paths with `find ! -readable` and adds them to the exclusion list, so `tar` never meets them. They are then reported on the console, counted in the summary, and written into the manifest inside the archive.

`--ignore-failed-read` is still on, for the file that vanishes *between* the scan and the read.

## The pipeline, and why the partial file is a dotfile

```bash
tar ... | zstd -T0 -12 | gpg --encrypt --compress-algo none > "$DEST/.name.partial"
```

`--compress-algo none` because the stream is already compressed; letting `gpg` run zlib over `zstd` output costs real time and gains nothing.

Nothing unencrypted is written to disk at any point — not even a temporary tarball — so the tool needs no scratch space and never leaves plaintext behind on a shared machine.

Then:

```bash
st=("${PIPESTATUS[@]}")
```

`tar` exit 1 is warnings (a file changed or vanished mid-read) and the archive is sound. Exit 2 is fatal. Anything non-zero from `zstd` or `gpg` is fatal. A fatal status deletes the `.partial` and exits non-zero; only a clean run renames it into place.

The rename is what makes a snapshot's existence mean something. A file at the destination without the `.partial` prefix went through the whole pipeline successfully.

## Trap state is script-scope

```bash
SNAP_OK=0; SNAP_PARTIAL=""; SNAP_WORK=""
trap 'snapshot_cleanup' EXIT INT TERM
```

An `EXIT` trap fires after the function frame has been unwound. A trap written against `local` variables expands to empty strings and removes nothing — leaving behind exactly the half-written archive it was installed to delete — and under `set -u` it also makes a command that printed a perfect result exit non-zero.

This was written wrong twice during development, in two different functions. It has a test.

## Verification asks the only question that matters

The checksum is computed by reading the finished file back off the destination. Tapping the stream with `tee` would be free and would certify the bytes that were *computed*; on a removable drive the question is what is on the disk.

Then the archive is decrypted, decompressed and walked member by member, and the count compared against the number `tar` reported writing. That pipeline must not run inside a command substitution — `count="$(gpg | zstd | tar -t | wc -l)"` is one command to the shell, so `PIPESTATUS` has one element and a truncated archive verifies clean.

## What the manifest is for, and where it is not

Inside every archive, at the root, `SNAPSHOT-MANIFEST.txt` carries the source path, the ruleset applied, every excluded directory, every unreadable path, tool versions, and the plain command that restores the archive without this tool.

The `.sha256` sidecar beside the archive carries **metadata only** — no file listing. A plaintext index of every path next to an encrypted archive gives away most of what the encryption was protecting. The full listing is written to `~/.local/state/dev-snapshot/runs/`, on the machine that already has the files.
