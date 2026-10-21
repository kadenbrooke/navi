#!/usr/bin/env bash
# Fetch Navi's typing-sound packs into the app's keysounds folder:
#   ~/Library/Application Support/Navi/keysounds/<pack id>/   (or NAVI_KEYSOUNDS_DIR)
#
# Two manifests, next to this script (the audio is never committed):
#   packs-public.tsv   redistributable packs (CC0 / CC-BY, attribution recorded). Committed.
#   packs-local.tsv    optional, your own additions, same columns. Git-ignored; a clone
#                      without it just fetches the public list.
#
#   bash keysounds/fetch-keysounds.sh                  # public + local, only what is missing
#   bash keysounds/fetch-keysounds.sh public           # public list only
#   bash keysounds/fetch-keysounds.sh local --force    # re-download your local list
#
# Safety, per pack:
#   - every download is checked against the sha256 pinned in the manifest BEFORE anything is
#     installed (zip: the archive; file list: all files concatenated in map order). No pin, or a
#     mismatch, = that pack is skipped loudly.
#   - one limit for every pack, zip or file list: at most 500 files and 50 MB in total. A zip
#     over either is rejected before extraction (from its directory); a file list naming more
#     than 500 files is rejected before anything is downloaded, and one whose downloads add up
#     to more than 50 MB is abandoned mid-way (nothing installed).
#   - zip members are validated before extraction (no absolute paths, no `..`, no symlinks), and
#     only regular audio files that resolve inside the extraction dir are copied.
#   - a pack is staged in a temp dir and swapped into place only when complete; any failed step
#     abandons that pack (the installed copy, if any, is left as it was) and the next pack runs.
#   - the summary names every failed pack, and the exit status is non-zero if any failed.
#
# Navi works without any of it: with no pack fetched she plays a built-in synth click.
# Each pack lands as its press samples plus a pack.json with its name, license, tier, source
# and sha256 (plus a hash of its map line), which her profile picker shows. Map classes and the files they become:
#   key / space / enter / backspace   -> key-01.wav …, space-01.wav …   (generic + special keys)
#   up-key / up-space / up-enter / up-backspace -> up-key-01.mp3 …   (key-up recordings)
#   row0 … row4                       -> row0-01.mp3 …                  (per keyboard row)
#   sc<N>                             -> sc<N>.wav       (one key's own press, Mechvibes scancode N)
#   sc                                -> sc<N>.wav for every matched file named <N>.<ext>
# A pack needs at least one press class (key, row* or sc*); Navi derives releases it lacks.
#
# Test hooks: NAVI_KEYSOUNDS_MANIFESTS=<dir> reads the .tsv files from another folder;
# NAVI_KEYSOUNDS_ALLOW_FILE_URLS=1 allows file:// downloads (https only otherwise; redirects
# are https only either way).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
MANIFESTS="${NAVI_KEYSOUNDS_MANIFESTS:-$HERE}"
DEST="${NAVI_KEYSOUNDS_DIR:-$HOME/Library/Application Support/Navi/keysounds}"
PROTO="=https"
[[ "${NAVI_KEYSOUNDS_ALLOW_FILE_URLS:-}" == "1" ]] && PROTO="=https,file"
TIER="${1:-all}"
FORCE="${2:-}"
if [[ "$TIER" == "--force" ]]; then TIER="all"; FORCE="--force"; fi

case "$TIER" in
  public)  TIERS="public" ;;
  local)   TIERS="local" ;;
  all)     TIERS="public local" ;;
  *) echo "usage: $0 [public|local|all] [--force]"; exit 2 ;;
esac

mkdir -p "$DEST" || { echo "cannot create $DEST"; exit 1; }
TMP="$(mktemp -d)" || { echo "cannot create a temp dir"; exit 1; }
trap 'rm -rf "$TMP"' EXIT

json() { local s=${1//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
sha256() { shasum -a 256 | cut -d' ' -f1; }
# A pack id becomes part of every path the pack touches (temp, stage, install, backups), so it
# must be one plain name: lowercase letters, digits and `-`, at most 64 characters. No `/`,
# no `.`, no leading `-`.
valid_id() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; }
is_audio() { [[ "$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')" =~ ^(wav|mp3|flac|aif|aiff|caf|m4a)$ ]]; }
# Map classes (see the header) and the folder each file lands under.
CLASS_RE='^(key|space|enter|backspace|up-key|up-space|up-enter|up-backspace|row[0-4]|sc|sc[0-9]{1,5})$'
# File-list names: at most one subfolder (some packs keep press/ and release/ side by side), no dot
# segments (so no `..`), no backslashes; `[` `]` and spaces are allowed and URL-encoded.
NAME_RE='^[][A-Za-z0-9_ .-]+(/[][A-Za-z0-9_ .-]+)?$'
safe_name() {
  [[ "$1" =~ $NAME_RE ]] || return 1
  case "/$1" in */.*) return 1 ;; esac
  return 0
}
url_name() { local u=${1// /%20}; u=${u//\[/%5B}; u=${u//\]/%5D}; printf '%s' "$u"; }
# The installed name of the n-th file of a class. `sc` keeps the scancode from the source name.
out_name() {
  local cls=$1 n=$2 src=$3 ext=${3##*.} base stem
  case "$cls" in
    sc)
      base="${src##*/}"; stem="${base%.*}"
      [[ "$stem" =~ ^[0-9]{1,5}$ ]] || return 1
      printf 'sc%d.%s' "$((10#$stem))" "$ext" ;;
    sc[0-9]*)
      (( n == 1 )) || return 1
      printf '%s.%s' "$cls" "$ext" ;;
    *) printf '%s-%02d.%s' "$cls" "$n" "$ext" ;;
  esac
}

# Per-pack limits, shared by both pack kinds. Zip: checked from the archive's directory before
# extraction, and enforced again per file during extraction (ulimit) in case the directory lies.
# File list: the entry count is checked before any download, the byte total during the downloads.
MAX_PACK_BYTES=$((50 * 1024 * 1024))
MAX_PACK_ENTRIES=500

# download <url> <out> [max bytes]: curl exits 63 when the file is larger than the max.
# Redirects are https only, always (even when the test hook allows file:// for the first hop).
# --globoff: file names like `[.wav` are names, not curl URL ranges.
download() { curl -fsSL -g --proto "$PROTO" --proto-redir "=https" --max-filesize "${3:-$MAX_PACK_BYTES}" -m 120 -A "Mozilla/5.0" "$1" -o "$2"; }

# Rejects archives over MAX_PACK_ENTRIES entries or MAX_PACK_BYTES uncompressed.
zip_within_limits() {
  local zip=$1 totals entries bytes
  # `zipinfo -t`: "<n> file(s), <bytes> bytes uncompressed, <bytes> bytes compressed: <ratio>"
  totals="$(zipinfo -t "$zip" 2>/dev/null)" || { echo "  cannot read the zip directory"; return 1; }
  entries="$(printf '%s' "$totals" | awk '{print $1}')"
  bytes="$(printf '%s' "$totals" | awk '{print $3}')"
  [[ "$entries" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ ]] || { echo "  unreadable zip totals: $totals"; return 1; }
  (( entries <= MAX_PACK_ENTRIES )) || { echo "  $entries entries (limit $MAX_PACK_ENTRIES)"; return 1; }
  (( bytes <= MAX_PACK_BYTES )) || { echo "  $bytes bytes uncompressed (limit $MAX_PACK_BYTES)"; return 1; }
  return 0
}

# Rejects archives with absolute paths, `..` components, backslashes or symlink members.
zip_is_safe() {
  local zip=$1 names name
  names="$(zipinfo -1 "$zip" 2>/dev/null)" || return 1
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    case "$name" in /*|*\\*) echo "  unsafe zip member: $name"; return 1 ;; esac
    case "/$name/" in */../*) echo "  unsafe zip member: $name"; return 1 ;; esac
  done <<<"$names"
  # Long listing: a member whose mode starts with `l` is a symlink.
  if zipinfo "$zip" 2>/dev/null | grep -Eq '^l[rwxsStT-]{9}'; then echo "  zip contains a symlink"; return 1; fi
  return 0
}

# The path, symlinks resolved, of an existing file.
real_path() { local d; d="$(cd "$(dirname "$1")" && pwd -P)" || return 1; printf '%s/%s' "$d" "$(basename "$1")"; }

# fetch_pack <tier> <id> <name> <license> <attribution> <source> <url> <sha256> <map>
# Runs in a subshell per pack: any failure returns non-zero and leaves the installed copy alone.
fetch_pack() {
  local tier=$1 id=$2 name=$3 license=$4 attribution=$5 source=$6 url=$7 sha=$8 map=$9
  # First, before any path is built from it: a bad id fails the pack with no file touched.
  if ! valid_id "$id"; then
    printf 'FAILED  %q: invalid pack id (lowercase letters, digits and -, max 64), nothing done\n' "$id"
    return 1
  fi
  local final="$DEST/$id" stage="$TMP/stage-$id" root="" got entry cls spec n f ext out
  # A failed pack's temp files go at once (not only at exit), so an abandoned pack never keeps
  # its downloads around while the next pack runs. Belt and braces: never rm for a bad id.
  fail() {
    echo "FAILED  $id: $*"
    valid_id "$id" && rm -rf "$stage" "$TMP/unzip-$id" "$TMP/$id.zip"
    return 1
  }
  [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { fail "no sha256 pinned in the manifest"; return 1; }
  # Kept only while both the download pin and the map match: a map change on the same download
  # (say a new `sc:` class added to a zip already installed) must refetch, or the new files
  # never land.
  local mapsum; mapsum="$(printf '%s' "$map" | sha256)" || { fail "cannot hash the map"; return 1; }
  if [[ "$FORCE" != "--force" && -s "$final/pack.json" ]] && grep -q "\"sha256\":\"$sha\"" "$final/pack.json" \
     && grep -q "\"map_sha256\":\"$mapsum\"" "$final/pack.json"; then
    echo "keep    $id ($tier)"; return 0
  fi
  mkdir -p "$stage" || { fail "cannot create $stage"; return 1; }

  if [[ "$url" == *.zip ]]; then
    local zip="$TMP/$id.zip"
    download "$url" "$zip" || { fail "download failed ($url)"; return 1; }
    got="$(sha256 <"$zip")" || { fail "cannot hash the download"; return 1; }
    [[ "$got" == "$sha" ]] || { fail "checksum mismatch (expected $sha, got $got)"; return 1; }
    # Order matters: the checksum above, then the limits and member checks, and only then unzip.
    zip_within_limits "$zip" || { fail "archive too large, not extracted"; return 1; }
    zip_is_safe "$zip" || { fail "unsafe archive, not extracted"; return 1; }
    root="$TMP/unzip-$id"
    mkdir -p "$root" || { fail "cannot create $root"; return 1; }
    # ulimit -f (512-byte blocks) caps every extracted file even if the zip directory lied.
    ( ulimit -f $((MAX_PACK_BYTES / 512)); unzip -qq "$zip" -d "$root" ) || { fail "unzip failed"; return 1; }
    root="$(cd "$root" && pwd -P)" || { fail "cannot resolve $root"; return 1; }
  fi

  local downloaded=() total=0 budget rc size listed=0
  IFS=';' read -ra entries <<<"$map"
  if [[ -z "$root" ]]; then
    # A file list is held to the zip limits too: count every listed file before downloading any.
    for entry in "${entries[@]}"; do
      IFS=',' read -ra files <<<"${entry#*:}"
      listed=$((listed + ${#files[@]}))
    done
    (( listed <= MAX_PACK_ENTRIES )) || { fail "file list has $listed entries (limit $MAX_PACK_ENTRIES), nothing downloaded"; return 1; }
  fi
  for entry in "${entries[@]}"; do
    cls="${entry%%:*}"; spec="${entry#*:}"; n=0
    [[ "$cls" =~ $CLASS_RE ]] || { fail "unknown class '$cls' in map"; return 1; }
    if [[ -n "$root" ]]; then
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        # Only regular files (not symlinks) that really live inside the extraction dir.
        [[ -f "$f" && ! -L "$f" ]] || { fail "not a regular file: ${f#"$root"/}"; return 1; }
        local real; real="$(real_path "$f")" || { fail "cannot resolve ${f#"$root"/}"; return 1; }
        [[ "$real" == "$root"/* ]] || { fail "outside the archive: ${f#"$root"/}"; return 1; }
        is_audio "$f" || { fail "not an audio file: ${f#"$root"/}"; return 1; }
        n=$((n+1))
        out="$(out_name "$cls" "$n" "$f")" || { fail "$cls: cannot name ${f#"$root"/} (sc needs <number>.<ext>; sc<N> takes one file)"; return 1; }
        [[ ! -e "$stage/$out" ]] || { fail "$cls: two files map to $out"; return 1; }
        cp "$real" "$stage/$out" || { fail "copy failed"; return 1; }
      done < <(compgen -G "$root/$spec" | LC_ALL=C sort)
    else
      IFS=',' read -ra files <<<"$spec"
      for f in "${files[@]}"; do
        is_audio "$f" || { fail "not an audio file: $f"; return 1; }
        safe_name "$f" || { fail "unsafe file name: $f (one subfolder at most, no dot segments)"; return 1; }
        n=$((n+1))
        out="$(out_name "$cls" "$n" "$f")" || { fail "$cls: cannot name $f (sc needs <number>.<ext>; sc<N> takes one file)"; return 1; }
        [[ ! -e "$stage/$out" ]] || { fail "$cls: two files map to $out"; return 1; }
        out="$stage/$out"
        # Each download may use only what is left of the pack's byte budget (curl stops at it
        # when the size is known), and the running total is checked after every file.
        budget=$((MAX_PACK_BYTES - total))
        (( budget > 0 )) || { fail "file list over $MAX_PACK_BYTES bytes in total, not installed"; return 1; }
        download "$url$(url_name "$f")" "$out" "$budget"; rc=$?
        (( rc != 63 )) || { fail "file list over $MAX_PACK_BYTES bytes in total, not installed"; return 1; }
        (( rc == 0 )) || { fail "download failed ($url$f)"; return 1; }
        size="$(wc -c <"$out" | tr -d ' ')" || { fail "cannot size $f"; return 1; }
        total=$((total + size))
        (( total <= MAX_PACK_BYTES )) || { fail "file list over $MAX_PACK_BYTES bytes in total, not installed"; return 1; }
        downloaded+=("$out")
      done
    fi
    [[ $n -gt 0 ]] || { fail "no files match $cls:$spec"; return 1; }
  done

  if [[ -z "$root" ]]; then
    got="$(cat "${downloaded[@]}" | sha256)" || { fail "cannot hash the downloads"; return 1; }
    [[ "$got" == "$sha" ]] || { fail "checksum mismatch (expected $sha, got $got)"; return 1; }
  fi

  [[ "$attribution" == "-" ]] && attribution=""
  printf '{"id":%s,"name":%s,"license":%s,"tier":%s,"attribution":%s,"source":%s,"sha256":%s,"map_sha256":%s}\n' \
    "$(json "$id")" "$(json "$name")" "$(json "$license")" "$(json "$tier")" "$(json "$attribution")" "$(json "$source")" "$(json "$sha")" "$(json "$mapsum")" \
    > "$stage/pack.json" || { fail "cannot write pack.json"; return 1; }

  # Install: copy next to the final folder as <id>.part (Navi ignores *.part), then swap by
  # rename. On any failure the previous copy stays (or is put back).
  local part="$DEST/$id.part" old="$DEST/$id.old.part"
  rm -rf "$part" "$old" || { fail "cannot clear $part"; return 1; }
  cp -R "$stage" "$part" || { rm -rf "$part"; fail "cannot stage into $DEST"; return 1; }
  if [[ -e "$final" ]]; then mv "$final" "$old" || { rm -rf "$part"; fail "cannot move the old copy aside"; return 1; }; fi
  if ! mv "$part" "$final"; then
    [[ -e "$old" ]] && mv "$old" "$final"
    rm -rf "$part"; fail "cannot install"; return 1
  fi
  echo "fetch   $id ($tier, $license, sha256 ok) <- $source"
  # The pack is installed; a backup that will not delete is reported (and listed at the end),
  # never silently left. Navi ignores *.part folders, so it is harmless until removed.
  if ! rm -rf "$old" 2>/dev/null || [[ -e "$old" ]]; then echo "WARN    $id: could not remove the old copy $old"; fi
}

ok=0; failed=()
for tier in $TIERS; do
  list="$MANIFESTS/packs-$tier.tsv"
  if [[ ! -f "$list" ]]; then echo "skip    $tier tier (no $(basename "$list"))"; continue; fi
  while IFS=$'\t' read -r id name license attribution source url sha map; do
    [[ -z "$id" || "$id" == \#* ]] && continue
    if ( fetch_pack "$tier" "$id" "$name" "$license" "$attribution" "$source" "$url" "$sha" "$map" ); then
      ok=$((ok+1))
    else
      failed+=("$(printf '%q' "$id")")
    fi
  done < "$list"
done
leftovers="$(ls -d "$DEST"/*.old.part 2>/dev/null)"
if [[ -n "$leftovers" ]]; then
  echo "leftover backup folders (Navi ignores them; delete by hand):"
  printf '%s\n' "$leftovers" | sed 's/^/  /'
fi
if [[ ${#failed[@]} -eq 0 ]]; then
  echo "done: $ok ok, 0 failed -> $DEST"
  exit 0
fi
echo "done: $ok ok, ${#failed[@]} failed (${failed[*]}) -> $DEST"
exit 1
