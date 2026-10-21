#!/usr/bin/env bash
# Tests for fetch-keysounds.sh against local fixtures (file:// URLs, temp dirs only; nothing is
# downloaded and nothing touches the real keysounds folder). Needs python3 to craft the hostile
# zips (path traversal, absolute path, symlink).
#
#   bash keysounds/test-fetch-keysounds.sh               # with the bash on PATH
#   BASH_UNDER_TEST=/bin/bash bash keysounds/test-fetch-keysounds.sh   # macOS's bash 3.2
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/fetch-keysounds.sh"
RUNNER="${BASH_UNDER_TEST:-bash}"
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
FIX="$W/fixtures"; MAN="$W/manifests"; DEST="$W/dest"
mkdir -p "$FIX/raw" "$MAN" "$DEST"

pass=0; failn=0
ok()   { echo "ok    $1"; pass=$((pass+1)); }
bad()  { echo "FAIL  $1"; failn=$((failn+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }
sha() { shasum -a 256 "$@" | cut -d' ' -f1; }

python3 -I - "$FIX" <<'PY'
import os, stat, sys, zipfile
fix = sys.argv[1]
def z(name, members):
    with zipfile.ZipFile(os.path.join(fix, name), "w") as zf:
        for m in members:
            if m[0] == "link":
                info = zipfile.ZipInfo(m[1]); info.create_system = 3
                info.external_attr = (stat.S_IFLNK | 0o777) << 16
                zf.writestr(info, m[2])
            else:
                zf.writestr(m[1], m[2])
z("good.zip", [("file", "pack/key-a.wav", b"RIFF-a"), ("file", "pack/key-b.wav", b"RIFF-b"), ("file", "pack/notes.txt", b"x")])
z("traversal.zip", [("file", "pack/key-a.wav", b"RIFF"), ("file", "../escaped.wav", b"EVIL")])
z("absolute.zip", [("file", "pack/key-a.wav", b"RIFF"), ("file", "/tmp/navi-absolute-test.wav", b"EVIL")])
z("symlink.zip", [("file", "pack/key-a.wav", b"RIFF"), ("link", "pack/key-z.wav", "/etc/passwd")])
# Zip bombs: too many entries, and a tiny archive that inflates past 50 MB.
z("entries.zip", [("file", "pack/key-%03d.wav" % i, b"R") for i in range(501)])
with zipfile.ZipFile(os.path.join(fix, "inflate.zip"), "w", zipfile.ZIP_DEFLATED) as zf:
    zf.writestr("pack/key-a.wav", b"\0" * (51 * 1024 * 1024))
# A file list whose files are each under the per-file cap but add up to 52 MB.
os.makedirs(os.path.join(fix, "big"))
for n in ("big1.wav", "big2.wav"):
    with open(os.path.join(fix, "big", n), "wb") as f:
        f.write(b"\0" * (26 * 1024 * 1024))
PY
printf 'one' > "$FIX/raw/a.wav"; printf 'two' > "$FIX/raw/b.mp3"; printf 'three' > "$FIX/raw/space.wav"
U="file://$FIX"
RAWSHA="$(cat "$FIX/raw/a.wav" "$FIX/raw/b.mp3" "$FIX/raw/space.wav" | shasum -a 256 | cut -d' ' -f1)"
BIGSHA="$(cat "$FIX/big/big1.wav" "$FIX/big/big2.wav" | shasum -a 256 | cut -d' ' -f1)"
# 501 listed files that do not exist: rejecting the list must happen before any download.
MANY="$(for i in $(seq 0 500); do printf 'k%03d.wav,' "$i"; done)"; MANY="${MANY%,}"
T=$'\t'
row() { printf '%s\n' "$1${T}Name $1${T}CC0${T}-${T}https://example.invalid/$1${T}$2${T}$3${T}$4"; }

# Public: one good zip, one with a wrong checksum, the hostile zips, and a pack with no pin.
{
  row good      "$U/good.zip"      "$(sha "$FIX/good.zip")"      "key:pack/key-*.wav"
  row badsum    "$U/good.zip"      "$(printf '0%.0s' {1..64})"   "key:pack/key-*.wav"
  row traversal "$U/traversal.zip" "$(sha "$FIX/traversal.zip")" "key:pack/key-*.wav"
  row absolute  "$U/absolute.zip"  "$(sha "$FIX/absolute.zip")"  "key:pack/key-*.wav"
  row symlink   "$U/symlink.zip"   "$(sha "$FIX/symlink.zip")"   "key:pack/key-*.wav"
  row nopin     "$U/good.zip"      "-"                           "key:pack/key-*.wav"
  row entries   "$U/entries.zip"   "$(sha "$FIX/entries.zip")"   "key:pack/key-*.wav"
  row inflate   "$U/inflate.zip"   "$(sha "$FIX/inflate.zip")"   "key:pack/key-*.wav"
  row bombsum   "$U/inflate.zip"   "$(printf 'b%.0s' {1..64})"   "key:pack/key-*.wav"
} > "$MAN/packs-public.tsv"
# Local: a file-list pack with the right concatenated checksum, one with a wrong one, and two
# over the shared pack limits (too many files; right checksum but over 50 MB in total).
{
  row rawgood   "$U/raw/"  "$RAWSHA" "key:a.wav,b.mp3;space:space.wav"
  row rawbad    "$U/raw/"  "$(printf 'f%.0s' {1..64})" "key:a.wav,b.mp3;space:space.wav"
  row manyfiles "$U/many/" "$(printf 'c%.0s' {1..64})" "key:$MANY"
  row bigfiles  "$U/big/"  "$BIGSHA" "key:big1.wav;space:big2.wav"
} > "$MAN/packs-local.tsv"

run() { NAVI_KEYSOUNDS_MANIFESTS="$MAN" NAVI_KEYSOUNDS_DIR="$DEST" NAVI_KEYSOUNDS_ALLOW_FILE_URLS=1 "$RUNNER" "$SCRIPT" "$@" 2>&1; }

out="$(run all)"; code=$?
echo "$out" | sed 's/^/      | /'
check "exit status is non-zero when any pack failed" '[[ $code -ne 0 ]]'
check "summary names every failed pack" 'echo "$out" | grep -q "2 ok, 11 failed (badsum traversal absolute symlink nopin entries inflate bombsum rawbad manyfiles bigfiles)"'
check "good zip pack installed" '[[ -f "$DEST/good/key-01.wav" && -f "$DEST/good/key-02.wav" && ! -e "$DEST/good/key-03.wav" ]]'
check "only matched audio copied (no notes.txt)" '[[ $(ls "$DEST/good" | wc -l) -eq 3 ]]'
check "pack.json records the sha256" 'grep -q "\"sha256\":\"$(sha "$FIX/good.zip")\"" "$DEST/good/pack.json"'
check "checksum mismatch: skipped loudly" 'echo "$out" | grep -q "FAILED  badsum: checksum mismatch" && [[ ! -e "$DEST/badsum" ]]'
check "path traversal: rejected before extraction" 'echo "$out" | grep -q "FAILED  traversal: unsafe archive" && [[ ! -e "$W/escaped.wav" && ! -e "$DEST/escaped.wav" && ! -e "$DEST/traversal" ]]'
check "absolute path: rejected" 'echo "$out" | grep -q "FAILED  absolute: unsafe archive" && [[ ! -e /tmp/navi-absolute-test.wav && ! -e "$DEST/absolute" ]]'
check "symlink member: rejected" 'echo "$out" | grep -q "FAILED  symlink: unsafe archive" && [[ ! -e "$DEST/symlink" ]]'
check "over 500 entries: rejected before extraction" 'echo "$out" | grep -q "501 entries (limit 500)" && echo "$out" | grep -q "FAILED  entries: archive too large" && [[ ! -e "$DEST/entries" ]]'
check "over 50 MB uncompressed: rejected before extraction" 'echo "$out" | grep -q "FAILED  inflate: archive too large" && [[ ! -e "$DEST/inflate" ]]'
check "sha256 is checked before any size/member check or extraction" 'echo "$out" | grep -q "FAILED  bombsum: checksum mismatch" && [[ ! -e "$DEST/bombsum" ]]'
check "redirects can only go to https" 'grep -q -- "--proto-redir \"=https\"" "$SCRIPT"'
check "missing pin: rejected" 'echo "$out" | grep -q "FAILED  nopin: no sha256 pinned" && [[ ! -e "$DEST/nopin" ]]'
check "file-list pack verified and installed" '[[ -f "$DEST/rawgood/key-01.wav" && -f "$DEST/rawgood/key-02.mp3" && -f "$DEST/rawgood/space-01.wav" ]]'
check "file-list checksum mismatch: skipped" 'echo "$out" | grep -q "FAILED  rawbad: checksum mismatch" && [[ ! -e "$DEST/rawbad" ]]'
check "file list over 500 entries: rejected before any download" 'echo "$out" | grep -q "FAILED  manyfiles: file list has 501 entries (limit 500), nothing downloaded" && [[ ! -e "$DEST/manyfiles" ]]'
check "file list over 50 MB in total: abandoned, not installed" 'echo "$out" | grep -q "FAILED  bigfiles: file list over 52428800 bytes in total, not installed" && [[ ! -e "$DEST/bigfiles" ]]'
check "no staging leftovers in the packs folder" '[[ -z "$(ls -d "$DEST"/*.part 2>/dev/null)" ]]'

out="$(run public)"
check "second run keeps a verified install" 'echo "$out" | grep -q "keep    good (public)"'

# A pin change (say a pack updated upstream) refetches; a failed refetch keeps the old copy.
printf 'old' > "$DEST/good/marker"
sed -i '' "s/$(sha "$FIX/good.zip")/$(printf 'a%.0s' {1..64})/" "$MAN/packs-public.tsv"
out="$(run public)"
check "failed re-fetch leaves the installed copy untouched" '[[ -f "$DEST/good/marker" && -f "$DEST/good/key-01.wav" ]]'

# A backup that will not delete after a swap is reported, and listed in the summary.
mkdir -p "$DEST/good/locked" && touch "$DEST/good/locked/f" && chmod 555 "$DEST/good/locked"
sed -i "" "s/$(printf 'a%.0s' {1..64})/$(sha "$FIX/good.zip")/" "$MAN/packs-public.tsv"
out="$(run public --force)"
check "undeletable old copy: pack still installs, warning printed" 'echo "$out" | grep -q "WARN    good: could not remove the old copy" && [[ -f "$DEST/good/key-01.wav" && ! -e "$DEST/good/locked" ]]'
check "leftover backup folders are listed" 'echo "$out" | grep -q "leftover backup folders" && echo "$out" | grep -q "good.old.part"'
chmod 755 "$DEST/good.old.part/locked" && rm -rf "$DEST/good.old.part"
sed -i "" "s/$(sha "$FIX/good.zip")/$(printf 'a%.0s' {1..64})/" "$MAN/packs-public.tsv"
printf 'old' > "$DEST/good/marker"

# Only the public manifest present (a fresh clone, no packs-local.tsv): local is skipped, not an error.
rm "$MAN/packs-local.tsv"
sed -i "" -E "/^(badsum|traversal|absolute|symlink|nopin|entries|inflate|bombsum)\t/d" "$MAN/packs-public.tsv"
sed -i '' "s/$(printf 'a%.0s' {1..64})/$(sha "$FIX/good.zip")/" "$MAN/packs-public.tsv"
out="$(run all --force)"; code=$?
check "public-only clone: local list skipped, exit 0" '[[ $code -eq 0 ]] && echo "$out" | grep -q "skip    local tier"'
check "--force swaps in a fresh copy" '[[ ! -e "$DEST/good/marker" && -f "$DEST/good/key-01.wav" ]]'

echo "$pass passed, $failn failed ($RUNNER)"
[[ $failn -eq 0 ]]
