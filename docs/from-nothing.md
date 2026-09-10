# From nothing to a working dev-snapshot

By the end of this page you'll have taken an encrypted snapshot of a small practice tree, watched it verify itself, and restored it somewhere else. It takes about ten minutes.

## Contents

- [What this is](#what-this-is)
- [What you need](#what-you-need)
- [Step 1: install it](#step-1-install-it)
- [Step 2: make a practice tree](#step-2-make-a-practice-tree)
- [Step 3: tell it what to back up and where](#step-3-tell-it-what-to-back-up-and-where)
- [Step 4: look before you leap](#step-4-look-before-you-leap)
- [Step 5: take the snapshot](#step-5-take-the-snapshot)
- [Step 6: restore it](#step-6-restore-it)
- [Moving to a real backup](#moving-to-a-real-backup)
- [Where to go next](#where-to-go-next)

## What this is

A folder of code projects is mostly things you can download again: `node_modules`, virtualenvs, Composer's `vendor/`, build caches. What you can't download again is your own work: unpushed commits, `.env` files, half-finished branches.

dev-snapshot packs the second kind into one encrypted archive and leaves the first kind out. Then it reads the archive back to prove it can be restored.

## What you need

- `bash`, GNU `tar`, `gpg` and `make`. Most Linux systems already have them.
- `zstd`, the default compressor. On Debian or Ubuntu, run `sudo apt install zstd`. You can use `--compress gzip` instead if you'd rather not install it.
- A `~/bin` directory on your `PATH`. The first step creates the directory. If `make install` prints `note: ... is not on your PATH`, add `export PATH="$HOME/bin:$PATH"` to your shell profile and open a new terminal.

Every command below was run on a clean home directory. In the output, `/home/you` stands for your own home directory, and the date in each file name will be today's date for you.

## Step 1: install it

```bash
cd ~
git clone https://github.com/kingletas/dev-snapshot && cd dev-snapshot
mkdir -p ~/bin
make install
```

The clone was run from a local copy of this repository rather than from GitHub, so that one line is not verified; the rest ran as shown.

```text
installed dev-snapshot -> /home/you/bin
dev-snapshot 1.0.0
ruleset reachable from the installed copy
```

## Step 2: make a practice tree

This builds three tiny projects. Each one shows a different decision the tool makes.

```bash
mkdir -p ~/practice/web-app/node_modules/left-pad ~/practice/web-app/src
echo 'module.exports = 1' > ~/practice/web-app/node_modules/left-pad/index.js
echo 'console.log("hi")' > ~/practice/web-app/src/main.js

mkdir -p ~/practice/shop/vendor/acme/logger
echo '{}' > ~/practice/shop/composer.json
echo '<?php // installed by composer' > ~/practice/shop/vendor/acme/logger/Logger.php

mkdir -p ~/practice/old-tool/vendor/acme/lib
echo '<?php // my own patched copy' > ~/practice/old-tool/vendor/acme/lib/Patch.php
```

- `web-app/node_modules` can always be reinstalled, so it will be left out.
- `shop/vendor` sits next to a `composer.json`, so Composer can rebuild it. It will be left out.
- `old-tool/vendor` has no `composer.json` beside it. Nothing can rebuild it, so it will be kept.

That last one is the point of the tool. A directory's name alone isn't enough to decide it's safe to skip.

## Step 3: tell it what to back up and where

The config file needs two settings: `SOURCE`, the tree to back up, and `DEST`, the folder the archive goes into. Neither has a default, so the tool stops and asks if either is missing.

```bash
mkdir -p ~/.config/dev-snapshot ~/snapshots
printf 'SOURCE = %s\nDEST   = %s\n' ~/practice ~/snapshots > ~/.config/dev-snapshot/config
cat ~/.config/dev-snapshot/config
```

```text
SOURCE = /home/you/practice
DEST   = /home/you/snapshots
```

Every archive is encrypted, and there's no way to turn that off. For this practice run, a passphrase in a file is the simplest option:

```bash
printf 'practice passphrase, not a real one\n' > ~/.snapshot-pass && chmod 600 ~/.snapshot-pass
```

## Step 4: look before you leap

`-n` is a dry run. It shows what would go in and what would be left out, and writes nothing.

```bash
dev-snapshot create -n --symmetric --passphrase-file ~/.snapshot-pass
```

```text
dev-snapshot 1.0.0
  source       /home/you/practice
  destination  /home/you/snapshots
  encryption   symmetric (AES256, passphrase)
  compression  zstd level 12

Scanning /home/you/practice ...

  tree         100.0B
  excluded     50.0B  in 2 directories
  to archive   50.0B

------------------------------------------------------------------
Biggest exclusions:
       31.0B  shop/vendor
       19.0B  web-app/node_modules

By rule:
  node_modules               1 dir(s)   npm/yarn/pnpm install
  vendor                     1 dir(s)   composer install

Would write: /home/you/snapshots/20260910-practice.tar.zst.gpg
```

Check the list of exclusions. `old-tool/vendor` isn't on it, so it will be kept.

## Step 5: take the snapshot

`-y` skips the confirmation prompt.

```bash
dev-snapshot create -y --symmetric --passphrase-file ~/.snapshot-pass
```

```text
Archiving ...
  12 members, 950.0B written
Hashing /home/you/snapshots/20260910-practice.tar.zst.gpg ...

------------------------------------------------------------------
  /home/you/snapshots/20260910-practice.tar.zst.gpg
  sha256  5e4e1baeda611364ee477ae6f975385cd07f493781b674269d9418d9d88ba91a

Verifying checksum ...
  sha256 matches
Reading the archive back ...
  12 members read
  VERIFIED -- this snapshot decrypts and reads end to end.
```

The plan it prints first is the same as in step 4, so it's left out above. Your checksum will be different, because encryption mixes in random data every time. **Only trust a snapshot that ends with `VERIFIED`.** That line means the file on disk was decrypted and read back in full.

To see what's in the destination:

```bash
dev-snapshot list
```

```text
/home/you/snapshots
  20260910-practice.tar.zst.gpg              2026-09-10 12:13     950.0B  sha256 recorded
```

## Step 6: restore it

Restore into a new folder, never on top of the original:

```bash
f=$(ls ~/snapshots/*.gpg)
dev-snapshot restore "$f" ~/restored --passphrase-file ~/.snapshot-pass
find ~/restored -type f | sort
```

```text
Restoring /home/you/snapshots/20260910-practice.tar.zst.gpg into /home/you/restored ...
  restored into /home/you/restored

  Read /home/you/restored/SNAPSHOT-MANIFEST.txt for what was excluded and what could not be read.
/home/you/restored/SNAPSHOT-MANIFEST.txt
/home/you/restored/practice/old-tool/vendor/acme/lib/Patch.php
/home/you/restored/practice/shop/composer.json
/home/you/restored/practice/web-app/src/main.js
```

Your own code came back, including the hand-patched `old-tool/vendor`. The two rebuildable folders didn't. `SNAPSHOT-MANIFEST.txt` lists what was left out, and the command that restores the archive with plain `gpg`, `zstd` and `tar` if this tool is ever gone.

When you're done, clean up with `rm -rf ~/practice ~/restored ~/snapshots ~/.snapshot-pass ~/.config/dev-snapshot`.

## Moving to a real backup

- Point `SOURCE` at your real projects folder and `DEST` at a drive that isn't your main disk.
- Use a GPG key instead of a passphrase file: put `RECIPIENT = <your key id>` in the config and drop the `--symmetric` flags. The README's "Configure it once" section shows the full config.
- Run `make plan` first. On a large tree, a dry run is the cheapest way to spot a folder you didn't mean to include.

## Where to go next

- [README](../README.md): the full ruleset, slim snapshots, and adding your own rules.
- [SECURITY.md](../SECURITY.md): what the encryption protects, and what it doesn't.
- [docs/architecture.md](architecture.md): how the pipeline is put together.
