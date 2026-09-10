#!/usr/bin/env bash
#
# Tests for the parts of dev-snapshot that decide something: which directories
# a guard accepts, whether symlinks are followed, what survives a round trip,
# and what happens when a stage of the pipeline fails.
#
# Usage:
#   tests/run.sh
#
# Encryption is symmetric with a passphrase file throughout. Generating an RSA
# key takes seconds of entropy on a CI runner and proves nothing these tests
# are about -- the asymmetric path differs only in the gpg arguments, and the
# argument builders are exercised by the preflight tests below.

set -uo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
DS="$HERE/bin/dev-snapshot"
passed=0
failed=0

ok()  { passed=$((passed + 1)); echo "  ok   $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL $1"; }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (got '$2', wanted '$3')"; fi; }
want_grep()    { if grep -q -- "$1" <<< "$2"; then ok "$3"; else bad "$3 -- output was: $2"; fi; }
want_no_grep() { if grep -q -- "$1" <<< "$2"; then bad "$3 -- output was: $2"; else ok "$3"; fi; }
has()    { if [[ -e "$1" ]]; then ok "$2"; else bad "$2 (missing: $1)"; fi; }
has_not(){ if [[ -e "$1" ]]; then bad "$2 (present but should not be: $1)"; else ok "$2"; fi; }

command -v gpg  >/dev/null || { echo "tests need gpg";  exit 1; }
command -v zstd >/dev/null || { echo "tests need zstd"; exit 1; }

work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

export SNAPSHOT_STATE="$work/state"
export SNAPSHOT_CONFIG="$work/no-such-config"
export SNAPSHOT_RULES="$work/no-such-rules"
export GNUPGHOME="$work/gnupg"
mkdir -p "$GNUPGHOME"; chmod 700 "$GNUPGHOME"

PASS="$work/pass.txt"
echo "correct-horse-battery-staple" > "$PASS"
chmod 600 "$PASS"

SRC="$work/src/tree"
DEST="$work/dest"
mkdir -p "$DEST"

snap() { "$DS" "$@" --source "$SRC" --dest "$DEST" --symmetric --passphrase-file "$PASS"; }

# --------------------------------------------------------------- fixtures --
build_fixture() {
  rm -rf -- "$work/src"; mkdir -p "$SRC"
  # vendor next to a composer.json: a package manager can rebuild it
  mkdir -p "$SRC/php-app/vendor/pkg"; echo '{}' > "$SRC/php-app/composer.json"
  echo lib > "$SRC/php-app/vendor/pkg/a.php"
  # vendor with no composer.json holding repositories: nothing can rebuild it
  mkdir -p "$SRC/clones/vendor/repo/.git"
  echo hist > "$SRC/clones/vendor/repo/.git/HEAD"
  echo real > "$SRC/clones/vendor/repo/main.c"
  # a real virtualenv, and a directory that is merely called env
  mkdir -p "$SRC/py/.venv/lib" "$SRC/py/env/models" "$SRC/py/__pycache__"
  echo cfg   > "$SRC/py/.venv/pyvenv.cfg"
  echo junk  > "$SRC/py/.venv/lib/x.py"
  echo model > "$SRC/py/env/models/m.py"
  echo pyc   > "$SRC/py/__pycache__/x.pyc"
  echo main  > "$SRC/py/main.py"
  echo stray > "$SRC/py/stray.pyc"
  # node_modules, and a build output that is NOT excluded by default
  mkdir -p "$SRC/js/node_modules/dep" "$SRC/js/dist"
  echo d > "$SRC/js/node_modules/dep/i.js"
  echo b > "$SRC/js/dist/bundle.js"
  mkdir -p "$SRC/tf/.terraform"; echo p > "$SRC/tf/.terraform/prov"; echo t > "$SRC/tf/main.tf"
  echo ds > "$SRC/.DS_Store"
  # a path holding glob metacharacters
  mkdir -p "$SRC/weird [1]/node_modules"
  echo w    > "$SRC/weird [1]/node_modules/x"
  echo keep > "$SRC/weird [1]/keep.txt"
  # the two symlink shapes that matter: one out of the tree, one inside it
  ln -sf /etc "$SRC/escape-link"
  ln -sf php-app "$SRC/sibling-link"
}
build_fixture

echo "dev-snapshot tests"
echo

# ------------------------------------------------------- guards and rules --
echo "guards"
out="$(snap create -n 2>&1)"
check "a dry run exits 0" "$?" "0"
want_grep "node_modules" "$out" "node_modules is excluded"
want_grep "php-app/vendor" "$out" "a vendor beside a composer.json is excluded"
want_no_grep "clones/vendor" "$out" "a vendor with no composer.json is NOT excluded"
want_grep "py/.venv" "$out" "a directory holding pyvenv.cfg is excluded"
want_no_grep "py/env" "$out" "a directory merely called env is NOT excluded"
want_grep "weird \[1\]/node_modules" "$out" "a path with glob metacharacters is excluded"
has_not "$DEST/$(date +%Y%m%d)-tree.tar.zst.gpg" "a dry run writes no archive"

out="$(snap create -n --no-rule node_modules 2>&1)"
want_no_grep "js/node_modules" "$out" "--no-rule drops a rule for the run"

# ----------------------------------------------------------- a round trip --
echo
echo "round trip"
out="$(snap create -y 2>&1)"; status=$?
check "create exits 0" "$status" "0"
want_grep "VERIFIED" "$out" "and verifies itself end to end"
ARCHIVE="$DEST/$(date +%Y%m%d)-tree.tar.zst.gpg"
has "$ARCHIVE" "the archive is written"
has "$ARCHIVE.sha256" "with a checksum sidecar beside it"
want_no_grep "^/" "$(cut -c1-200 "$ARCHIVE.sha256" | grep -c / || true)" "the sidecar carries no file listing"

R="$work/restored"
out=$("$DS" restore "$ARCHIVE" "$R" --symmetric --passphrase-file "$PASS" 2>&1); status=$?
check "restore exits 0" "$status" "0"
has     "$R/tree/php-app/composer.json"          "source survives the round trip"
has_not "$R/tree/php-app/vendor"                 "the rebuildable vendor did not"
has     "$R/tree/clones/vendor/repo/.git/HEAD"   "git history in an unguarded vendor survives"
has     "$R/tree/clones/vendor/repo/main.c"      "and so does its source"
has     "$R/tree/py/env/models/m.py"             "a directory called env survives"
has_not "$R/tree/py/.venv"                       "a real virtualenv does not"
has_not "$R/tree/py/__pycache__"                 "__pycache__ does not"
has_not "$R/tree/py/stray.pyc"                   "a loose .pyc does not"
has     "$R/tree/py/main.py"                     "but the source beside it does"
has     "$R/tree/js/dist/bundle.js"              "dist is kept -- it is not in the ruleset"
has_not "$R/tree/js/node_modules"                "node_modules is not"
has_not "$R/tree/tf/.terraform"                  ".terraform is not"
has     "$R/tree/tf/main.tf"                     "but the terraform source is"
has_not "$R/tree/.DS_Store"                      ".DS_Store is not"
has     "$R/tree/weird [1]/keep.txt"             "a file in a bracketed path survives"
has_not "$R/tree/weird [1]/node_modules"         "its node_modules does not"
has     "$R/SNAPSHOT-MANIFEST.txt"               "the manifest rides inside the archive"

# The reason there is no --dereference flag anywhere in this tool. Following
# `escape-link` would pull all of /etc into a snapshot of a source tree.
if [[ -L "$R/tree/escape-link" ]]; then ok "a symlink out of the tree is stored as a symlink"
else bad "a symlink out of the tree was FOLLOWED -- $(ls -ld "$R/tree/escape-link" 2>&1)"; fi
if [[ -L "$R/tree/sibling-link" ]]; then ok "a symlink inside the tree is stored as a symlink"
else bad "a symlink inside the tree was followed, duplicating its target"; fi
# Not `[[ -e $R/tree/escape-link/passwd ]]`: that test resolves THROUGH the
# restored symlink and finds the real /etc/passwd, so it fails on a tool that
# behaved perfectly. Ask instead whether anything was stored under the link --
# find does not traverse symlinks, so this only sees real archive members.
under="$(find "$R/tree" -path '*/escape-link/*' -print 2>/dev/null | wc -l | tr -d ' ')"
check "and nothing from outside the tree was stored under it" "$under" "0"

# --------------------------------------------------------- damaged inputs --
echo
echo "damaged archives"
cp "$ARCHIVE" "$work/t.tar.zst.gpg"; cp "$ARCHIVE.sha256" "$work/t.tar.zst.gpg.sha256"
printf 'XXXX' | dd of="$work/t.tar.zst.gpg" bs=1 seek=600 conv=notrunc status=none
out=$("$DS" verify "$work/t.tar.zst.gpg" --symmetric --passphrase-file "$PASS" 2>&1); status=$?
check "a flipped byte fails verify" "$status" "2"
want_grep "MISMATCH" "$out" "and says the checksum did not match"

sz=$(stat -c %s "$ARCHIVE" 2>/dev/null || stat -f %z "$ARCHIVE")
head -c $(( sz * 6 / 10 )) "$ARCHIVE" > "$work/short.tar.zst.gpg"
out=$("$DS" verify "$work/short.tar.zst.gpg" --symmetric --passphrase-file "$PASS" 2>&1); status=$?
check "a truncated archive fails verify even with no checksum" "$status" "2"

# ------------------------------------------------- a failure mid-pipeline --
echo
echo "a failing stage"
mkdir -p "$work/fakebin"
printf '#!/bin/sh\ncat >/dev/null\nexit 9\n' > "$work/fakebin/zstd"
chmod +x "$work/fakebin/zstd"
rm -f "$DEST"/*.gpg "$DEST"/*.sha256
out=$(PATH="$work/fakebin:$PATH" snap create -y 2>&1); status=$?
check "a failing compressor fails the run" "$status" "2"
# gpg will happily encrypt a truncated stream. A file left behind here would
# decrypt perfectly and restore half a tree.
leftover="$(find "$DEST" -mindepth 1 | wc -l | tr -d ' ')"
check "and leaves nothing behind at the destination" "$leftover" "0"

# --------------------------------------------------------------- naming ----
echo
echo "naming and pruning"
snap create -y --no-verify >/dev/null 2>&1
first="$(find "$DEST" -name '*.gpg' | wc -l | tr -d ' ')"
sleep 1
snap create -y --no-verify >/dev/null 2>&1
second="$(find "$DEST" -name '*.gpg' | wc -l | tr -d ' ')"
check "a second run on the same day does not overwrite the first" "$second" "$(( first + 1 ))"

# A snapshot of a different tree, sharing the destination.
OTHER="$work/src/other"; mkdir -p "$OTHER"; echo x > "$OTHER/f"
"$DS" create -y --no-verify --source "$OTHER" --dest "$DEST" \
      --symmetric --passphrase-file "$PASS" >/dev/null 2>&1
has "$(find "$DEST" -name "*-other.tar.zst.gpg" | head -1)" "a second label writes its own file"

out=$(snap prune --keep 1 -n 2>&1)
want_grep "labelled 'tree'" "$out" "prune scopes itself to one label"
want_no_grep "other" "$out" "and does not offer to delete another tree's snapshots"

# mtime order, not lexical: the collision suffix makes the newer name sort first
oldest="$(find "$DEST" -name '*-tree.tar.zst.gpg' -printf '%T@\t%f\n' | sort -n | head -1 | cut -f2)"
want_grep "$oldest" "$out" "and removes the oldest by modification time"

out=$(snap prune --keep 0 -n 2>&1); status=$?
check "prune --keep 0 is refused" "$status" "2"

# ---------------------------------------------------------------- config ---
echo
echo "config file"
cfg="$work/cfg"
export SNAPSHOT_CONFIG="$cfg"
cat > "$cfg" <<CFG
# a comment
LABEL = configured
NONSENSE = 1
SOURCE=\$(touch $work/PWNED)
CFG
out=$("$DS" create -n --source "$SRC" --dest "$DEST" --symmetric --passphrase-file "$PASS" 2>&1)
want_grep "unknown key 'NONSENSE'" "$out" "an unknown key is reported, not ignored"
has_not "$work/PWNED" "the config file is parsed as data and never sourced"
want_grep "configured" "$out" "a known key takes effect"
out=$("$DS" create -n --label fromflag --source "$SRC" --dest "$DEST" --symmetric --passphrase-file "$PASS" 2>&1)
want_grep "fromflag" "$out" "and a flag beats the config file"
printf 'SOURCE = %s\nDEST = %s\n' "$SRC" "$DEST" > "$cfg"
out=$("$DS" create -n --symmetric --passphrase-file "$PASS" 2>&1); status=$?
check "SOURCE and DEST from the config are enough to plan a run" "$status" "0"
want_grep "source  *$SRC" "$out" "and the configured source is the one scanned"
export SNAPSHOT_CONFIG="$work/no-such-config"

# ------------------------------------------------------------ bad inputs ---
echo
echo "refusals"
out=$("$DS" create -n --source / --dest "$DEST" 2>&1); check "refuses to snapshot /" "$?" "2"
out=$("$DS" create -n --source "$SRC" --dest "$DEST" --label 'a/b' 2>&1)
check "refuses a label holding a slash" "$?" "2"
out=$("$DS" create -n --source "$SRC" --dest "$work/nope" 2>&1)
check "refuses a destination that does not exist" "$?" "2"
out=$("$DS" create -n --source "$work/nope" --dest "$DEST" 2>&1)
check "refuses a source that does not exist" "$?" "2"
out=$(SNAPSHOT_SOURCE="" "$DS" create -n --dest "$DEST" 2>&1); status=$?
check "refuses to run with no source at all" "$status" "2"
want_grep "no source" "$out" "and says which setting is missing"
out=$("$DS" create -n --source "$SRC" --dest "$DEST" --compress lzma 2>&1)
check "refuses an unknown compressor" "$?" "2"
out=$("$DS" frobnicate 2>&1); check "refuses an unknown command" "$?" "2"
out=$("$DS" create --wat 2>&1);  check "refuses an unknown option" "$?" "2"
out=$(SNAPSHOT_RECIPIENT="" "$DS" create -n --source "$SRC" --dest "$DEST" 2>&1); status=$?
check "refuses to run with no recipient and no --symmetric" "$status" "2"
want_grep "Keys available here" "$out" "and shows which keys it could use"

# ------------------------------------------------------------------ slim ---
#
# A slim snapshot is deliberately lossy, so the tests are mostly about it
# SAYING so -- in the output, in the sidecar and in the manifest inside the
# archive. A lossy backup that does not announce itself is the failure this
# whole tool is arranged against.
echo
echo "slim"
slimsrc="$work/src/slim"; mkdir -p "$slimsrc/repo/.git" "$slimsrc/sub"
echo hist  > "$slimsrc/repo/.git/HEAD"
echo code  > "$slimsrc/repo/main.py"
echo entry > "$slimsrc/app.log"
echo doc   > "$slimsrc/notes.md"
tar -cf "$slimsrc/bundle.tar" -C "$slimsrc" repo 2>/dev/null
head -c 200000 /dev/urandom > "$slimsrc/big.bin"
head -c 1000   /dev/urandom > "$slimsrc/small.bin"
mkdir -p "$work/dest-slim"
slimsnap() { "$DS" "$@" --source "$slimsrc" --dest "$work/dest-slim" --symmetric --passphrase-file "$PASS"; }

out=$(slimsnap create -y --slim --max-file-size 100K 2>&1); status=$?
check "a slim snapshot completes" "$status" "0"
want_grep "VERIFIED" "$out" "and verifies"
want_grep "not a substitute for a regular snapshot" "$out" "and says it is not a full backup"

SL="$(find "$work/dest-slim" -name '*-slim.tar.zst.gpg' | sed -n 1p)"
has "$SL" "the file carries a distinct -slim label"
want_grep "SLIM" "$(cat "$SL.sha256")" "the sidecar records that it is slim"

R3="$work/restored-slim"
"$DS" restore "$SL" "$R3" --symmetric --passphrase-file "$PASS" >/dev/null 2>&1
has     "$R3/slim/notes.md"        "a document survives a slim snapshot"
has     "$R3/slim/repo/main.py"    "and so does source"
has     "$R3/slim/small.bin"       "and a small binary under the cap"
has_not "$R3/slim/repo/.git"       "history does not"
has_not "$R3/slim/app.log"         "a log does not"
has_not "$R3/slim/bundle.tar"      "an archive does not"
has_not "$R3/slim/big.bin"         "and neither does a file over the cap"
want_grep "THIS IS A SLIM SNAPSHOT" "$(cat "$R3/SNAPSHOT-MANIFEST.txt")" "the manifest inside says so too"
want_grep "big.bin" "$(cat "$R3/SNAPSHOT-MANIFEST.txt")" "and names every file the cap dropped"

# The regular mode must be completely unaffected by the slim ruleset existing.
out=$(slimsnap create -n 2>&1)
want_no_grep "repo/.git" "$out" "a regular snapshot still keeps history"
want_no_grep "size cap"  "$out" "and applies no size cap"

# Slim and regular must not prune each other -- that is what the label is for.
slimsnap create -y --no-verify >/dev/null 2>&1
out=$(slimsnap prune --keep 1 -n --slim 2>&1)
want_grep "slim" "$out" "prune on slim is scoped to the slim label"

out=$(slimsnap create -n --max-file-size wat 2>&1); status=$?
check "a size that is not a size is refused" "$status" "2"
out=$(slimsnap create -n --max-file-size 1K 2>&1)
want_grep "over the cap" "$out" "and a valid one reports what it caught"

# ------------------------------------------------------------- rules add ---
echo
echo "rules add"
ur="$work/user.rules"
radd() { SNAPSHOT_RULES="$ur" "$DS" rules add "$@" --source "$SRC" --dest "$DEST" \
         --symmetric --passphrase-file "$PASS"; }

out=$(radd dist --why "js build output" 2>&1); status=$?
check "adding a rule exits 0" "$status" "0"
want_grep "It matches 1 directory" "$out" "and reports what it now matches"
has "$ur" "the user ruleset is created if absent"
check "the row is tab separated" "$(awk -F'\t' '$2=="dist"{print NF}' "$ur")" "4"

out=$(radd dist 2>&1); status=$?
check "adding the same rule twice is refused" "$status" "2"
out=$(radd node_modules 2>&1)
want_grep "already in the shipped ruleset" "$out" "adding a shipped name warns rather than refusing"
out=$(radd nothing-here 2>&1)
want_grep "matches nothing" "$out" "a rule that matches nothing says so plainly"
out=$(radd bogus --guard "wat:x" 2>&1); status=$?
check "an unknown guard is refused" "$status" "2"
out=$(radd '*.bak' --kind file --guard sibling:x 2>&1); status=$?
check "a guard on a file rule is refused" "$status" "2"
out=$(radd '*.bak' --kind file --why "editor backup" 2>&1); status=$?
check "a file rule without a guard is accepted" "$status" "0"
out=$(radd thing --kind directory 2>&1); status=$?
check "an unknown kind is refused" "$status" "2"

# The added rule has to actually take effect on the next run.
out=$(SNAPSHOT_RULES="$ur" "$DS" create -n --source "$SRC" --dest "$DEST" \
      --symmetric --passphrase-file "$PASS" 2>&1)
want_grep "js/dist" "$out" "a rule added this way excludes on the next run"

# --------------------------------------------------------------- SIGPIPE ---
#
# `sed file | head -5` returns 141 when head leaves first, and under `set -e`
# with pipefail that ends the run before anything is archived. The real tree
# has 191 unreadable paths and the first full-scale run died there, having
# archived nothing.
#
# It is a race on the 64 KB pipe buffer, so the scale matters and a small
# fixture proves nothing: measured here, 20 lines never triggers it, 200 lines
# triggers it about one run in five, and 1,000 lines triggers it every time.
# The behavioural test therefore uses 1,000 -- and because a race can still
# hide, the shape check below is the one that cannot.
echo
echo "output truncation does not kill the run"

# The deterministic half: no pipeline may feed `head` except the one place
# where stopping early is the point, which is marked.
offenders="$(grep -n '| *head -' "$HERE/bin/dev-snapshot" \
             | grep -v 'tar -tf -' | grep -v '^ *[0-9]*: *#' || true)"
check "no unmarked pipeline feeds head" "$(printf '%s' "$offenders" | wc -c | tr -d ' ')" "0"
[[ -n "$offenders" ]] && printf '       %s\n' "$offenders"

if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip the behavioural half (running as root, which can read anything)"
else
  many="$work/src/many"
  mkdir -p "$many/a/deeper/path/than/usual/so/the/lines/are/long/enough"
  deep="$many/a/deeper/path/than/usual/so/the/lines/are/long/enough"
  # 1,000 unreadable paths: past the pipe buffer, so the old code dies every run.
  for i in $(seq 1 1000); do
    printf 'x\n' > "$deep/secret-%06d.txt" 2>/dev/null || true
  done
  for i in $(seq 1 1000); do
    f="$(printf '%s/secret-%06d.txt' "$deep" "$i")"
    : > "$f"; chmod 000 "$f"
  done
  # and more than twelve exclusions, so the size-ranked list truncates too
  for i in $(seq 1 15); do
    mkdir -p "$many/proj-$i/node_modules/dep"; echo dep > "$many/proj-$i/node_modules/dep/index.js"
    echo src > "$many/proj-$i/app.js"
  done
  mkdir -p "$work/dest-many"

  out=$("$DS" create -n --source "$many" --dest "$work/dest-many" \
        --symmetric --passphrase-file "$PASS" 2>&1); status=$?
  check "a dry run over 1,000 unreadable paths exits 0" "$status" "0"
  want_grep "and 995 more" "$out" "the unreadable list truncates and says how many it hid"
  want_grep "Would write" "$out" "and the run reaches the end rather than dying at the truncation"

  out=$("$DS" create -y --source "$many" --dest "$work/dest-many" \
        --symmetric --passphrase-file "$PASS" 2>&1); status=$?
  check "and a real run over the same tree completes" "$status" "0"
  want_grep "VERIFIED" "$out" "and verifies"

  chmod 644 "$deep"/secret-*.txt 2>/dev/null || true
fi

# ------------------------------------------------------------- the prompt --
#
# The confirmation once read "Write 13.3GB to <file>", which states the size of
# the input as though it were the size of the output. The archive is
# compressed, so that number was wrong by several times in the direction that
# makes someone cancel a backup they had enough room for.
echo
echo "the confirmation prompt"
if command -v script >/dev/null 2>&1; then
  mkdir -p "$work/dest-prompt"
  out=$(printf 'n\n' | script -qec \
    "$DS create --source $SRC --dest $work/dest-prompt --symmetric --passphrase-file $PASS" \
    /dev/null 2>&1)
  want_grep "of files will be archived into" "$out" "the prompt says what the number measures"
  want_grep "the file itself will be smaller" "$out" "and that the written file is not that size"
  want_no_grep "Write .* to /" "$out" "and never states the input size as the output size"
  leftover="$(find "$work/dest-prompt" -mindepth 1 | wc -l | tr -d ' ')"
  check "answering no writes nothing" "$leftover" "0"
else
  echo "  skip prompt tests (no 'script' to allocate a pty)"
fi

# --------------------------------------------------------- older archives --
#
# The archives this tool replaced were plain `tar | gzip | gpg` written by
# hand, named `.tgz.gpg`. Being able to read them is the difference between a
# new tool and a new format nobody can open the old backups with.
echo
echo "archives this tool did not write"
mkdir -p "$work/legacy/tree"; echo old > "$work/legacy/tree/f.txt"
tar -cf - -C "$work/legacy" tree | gzip -6 \
  | gpg --batch --yes --quiet --pinentry-mode loopback --passphrase-file "$PASS" \
        --symmetric --cipher-algo AES256 --compress-algo none \
        -o "$work/legacy/20200101-old.tgz.gpg"
out=$("$DS" verify "$work/legacy/20200101-old.tgz.gpg" --symmetric --passphrase-file "$PASS" 2>&1); status=$?
check "a hand-made .tgz.gpg verifies" "$status" "0"
"$DS" restore "$work/legacy/20200101-old.tgz.gpg" "$work/legacy/out" \
      --symmetric --passphrase-file "$PASS" >/dev/null 2>&1
has "$work/legacy/out/tree/f.txt" "and restores"
out=$("$DS" restore "$work/legacy/20200101-old.tgz.gpg" "$work/legacy/out2" \
      --symmetric --passphrase-file "$PASS" 2>&1)
want_no_grep "SNAPSHOT-MANIFEST" "$out" "without pointing at a manifest it does not have"

# ----------------------------------------------------- clean exit paths ----
#
# Every command installs an EXIT trap. A trap written against a `local`
# variable expands to nothing once the function frame is gone, which both
# leaves temporary state behind AND makes the command exit non-zero under
# `set -u` with a bare "unbound variable" -- after printing a perfect result.
# This has been written wrong twice. It gets a test.
echo
echo "clean exits"
for c in "rules" "list" "create -n"; do
  # shellcheck disable=SC2086
  err=$(snap $c 2>&1 >/dev/null); status=$?
  check "'$c' exits 0" "$status" "0"
  want_no_grep "unbound variable" "$err" "'$c' leaves no unbound-variable noise on stderr"
done
before=$(find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
snap create -n >/dev/null 2>&1
after=$(find /tmp -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
check "a dry run cleans up its temporary directory" "$after" "$before"

# ------------------------------------------------------------ unreadable ---
echo
echo "unreadable files"
if [[ "$(id -u)" -eq 0 ]]; then
  echo "  skip unreadable-file tests (running as root, which can read anything)"
else
  echo secret > "$SRC/secret.txt"; chmod 000 "$SRC/secret.txt"
  rm -f "$DEST"/*.gpg "$DEST"/*.sha256
  out=$(snap create -y 2>&1); status=$?
  check "an unreadable file does not fail the run" "$status" "0"
  want_grep "could not be read" "$out" "but it is reported"
  want_grep "secret.txt" "$out" "by name"
  want_no_grep "Permission denied" "$out" "and never reaches tar as a warning"
  R2="$work/restored2"
  "$DS" restore "$(find "$DEST" -name '*-tree.tar.zst.gpg' | head -1)" "$R2" \
        --symmetric --passphrase-file "$PASS" >/dev/null 2>&1
  has_not "$R2/tree/secret.txt" "and it is genuinely absent from the archive"
  want_grep "secret.txt" "$(cat "$R2/SNAPSHOT-MANIFEST.txt")" "the manifest records it as a gap"
  chmod 644 "$SRC/secret.txt"
fi

echo
echo "------------------------------------------------------------------"
echo "  $passed passed, $failed failed"
[[ "$failed" -eq 0 ]]
