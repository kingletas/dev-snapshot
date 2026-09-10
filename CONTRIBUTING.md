# Contributing to dev-snapshot

Thanks for taking an interest. This is MIT-licensed and reuse is the point — fork it, strip it for parts, or send a patch back.

This file covers the mechanics. [`README.md`](README.md) explains what it does, [`docs/architecture.md`](docs/architecture.md) explains how the pieces fit, and [`SECURITY.md`](SECURITY.md) covers vulnerability reports — **please do not open a public issue for a security problem.**

## Getting set up

```bash
git clone https://github.com/kingletas/dev-snapshot && cd dev-snapshot
make check
```

Nothing to install beyond `bash`, GNU `tar`, `gpg` and `zstd`, plus `shellcheck` if you are touching the shell — which you are. `make check` is the same gate CI runs: shellcheck, the ruleset validation and the test suite.

## Four rules that outrank everything else

**Never follow a symlink.** No `-h`, no `--dereference`, no "just for this one case". A source tree contains symlinks to `/`, to `/tmp`, and to its own siblings, and following any of them turns a bounded archive into an unbounded one. There is a test for this and it is not negotiable.

**A gap must never look like a success.** An unreadable file, a skipped rule, an unverified archive and a `tar` warning are four different states, and each one is printed. The moment any of them can be mistaken for a clean run, this tool starts manufacturing confidence — which is worse than not existing, because someone will delete the original.

**Check every stage of the pipeline.** `tar | zstd | gpg > file` succeeds as far as the shell is concerned when `tar` dies halfway. Every pipeline in this tool captures `PIPESTATUS` and inspects each element. If a change makes you want to drop that, the change is wrong.

> And `PIPESTATUS` must be read from a real pipeline, never from inside a command substitution. `x="$(a | b | c)"` is one command to the shell, so `PIPESTATUS` has a single element and every stage's status is lost. That mistake shipped once here and made a truncated archive pass its own verification.

**Filenames go to `tar` in a file, never on a command line.** Paths carry spaces, brackets, ampersands and quotes. The exclusion lists are written one path per line and handed over with `--exclude-from` under `--no-wildcards`, so a `[` in a directory name stays a `[`. Any change that builds a command string out of paths reintroduces both a correctness bug and an injection.

## Testing

```bash
tests/run.sh
```

85 tests over real temporary trees, using symmetric encryption with a passphrase file — so they need no key generation and run in a couple of seconds on a cold CI runner.

Add a case for anything touching guard evaluation, the exclusion-path rewriting, exit status, or the trap that removes a partial archive. Those four are where a regression is silent rather than loud.

**Two bug classes have already recurred here, and both have dedicated tests:**

- **An `EXIT` trap written against a `local` variable.** The trap fires after the frame is gone, so it expands to empty strings, cleans up nothing, and — under `set -u` — makes a command that printed a perfect result exit non-zero. Trap state is script-scope (`SNAP_OK`, `SNAP_PARTIAL`, `SNAP_WORK`) for exactly this reason.
- **A truncating pipeline under `set -e`.** `sed file | head -5` returns 141 when `head` exits first, ending the run. It is a race on the 64 KB pipe buffer, so a small fixture proves nothing — 20 lines never trigger it and 1,000 lines trigger it every time. Read with `head` and format afterwards; if an early exit is genuinely wanted, mark it and do not check the status.
- **`set -e` and a command substitution that fails.** `x="$(du -s "$tree")"` ends the run when `du` meets one unreadable directory, after the entire scan has been paid for and before anything has been printed. Every real tree has one.

## Adding a rule

A rule belongs in the shipped `default.rules` when **a stranger would recognise the directory and agree it is regenerable**. `node_modules` qualifies. A framework's cache directory that only your employer uses does not — that goes in `~/.config/dev-snapshot/rules`, which is applied after the shipped set and is the file users are pointed at.

**If the name alone is not proof, the rule needs a guard.** `sibling:F` for a marker file next to the candidate, `has:F` for one inside it. Before adding an unguarded rule, ask what the directory name means in a project that is not yours: `target`, `env`, `dist` and `vendor` all mean something different somewhere, and one of them holds source that nothing can rebuild.

Guards are validated in CI, because a typo makes a rule silently never fire — which looks exactly like a rule that had nothing to match.

## Style

Match what is there. `#!/usr/bin/env bash`, `set -euo pipefail`, a header comment carrying purpose and usage that `-h` reprints by extracting itself rather than by a hardcoded line range.

**Comments explain why, and what a previous version got wrong.** Most of the comments in this codebase name a specific failure — a directory that was nearly deleted, an archive that verified while truncated. Those are the ones worth keeping, and a patch that tidies them into descriptions of what the code does is a patch that removes the useful half.
