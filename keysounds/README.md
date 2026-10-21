# Navi typing-sound packs

Typing sounds (a click for every key press, anywhere) play samples from sound packs. **No
audio is ever committed**: this folder holds only the fetch script and its test, the public
manifest, this README and a `.gitignore` that blocks every audio and archive extension (and
your own `packs-local.tsv`).

```bash
bash keysounds/fetch-keysounds.sh                  # public + local, only what is missing
bash keysounds/fetch-keysounds.sh public           # public list only
bash keysounds/fetch-keysounds.sh local --force    # re-download your local list
```

`install.sh` runs it for you (non-fatal if offline). Packs land in
`~/Library/Application Support/Navi/keysounds/<pack id>/` (or `NAVI_KEYSOUNDS_DIR`; dropdown →
*Typing sound ▸* → *Open typing sounds folder*), as `key-01.wav …` plus optional `space-` /
`enter-` / `backspace-NN` files and a `pack.json` with name, license, tier, source and sha256.
With no pack installed, Navi plays a built-in synth click. A folder with no `key-` samples is
not listed; a pack whose files fail to decode plays the synth click; a chosen profile that
disappears falls back to the first pack left.

## Two lists

| list | file | what goes in | committed |
|---|---|---|---|
| public | `packs-public.tsv` | redistributable only: CC0, or CC-BY with the attribution recorded | yes |
| local | `packs-local.tsv` | your own additions; checking the license is up to you | no (git-ignored); a clone without it just fetches the public list |

Manifest columns (tab-separated): `id  name  license  attribution  source page  download url
sha256  map`. `id` is lowercase letters, digits and `-`. `attribution` is `-` when there is
none. `map` is `class:pattern;class:pattern` with class `key` (required), `space`, `enter` or
`backspace`; for a `.zip` url the pattern is a glob inside the archive, for a url ending in `/`
it is a comma-separated file list under that url (pin raw GitHub urls to a commit).

A pack you copy into the keysounds folder by hand needs no manifest at all: `key-NN` files
are enough, and an optional `pack.json` (`{"name":"…","license":"…","attribution":"…"}`)
gives it a name and license in the picker.

## Safety

- **Every download is pinned.** `sha256` is required on every line: the archive's hash for a
  zip, or the hash of all listed files concatenated in map order for a file list
  (`cat f1 f2 … | shasum -a 256`). It is checked before anything is installed; a missing pin or
  a mismatch skips that pack with a `FAILED  <id>: …` line.
- **One size limit for every pack: 500 files, 50 MB in total.** A file list naming more than
  500 files is rejected before anything is downloaded; each of its downloads may only use what
  is left of the 50 MB, and the running total is checked after every file, so a list that adds
  up to more is abandoned mid-way (nothing installed, its downloads deleted).
- **Zips are validated before extraction**, in this order after the checksum: more than 500
  entries or more than 50 MB uncompressed (read from the archive's directory) rejects it; any
  member with an absolute path, a `..` component, a backslash, or a symlink rejects it. During
  extraction `ulimit -f` caps every file at 50 MB in case the directory lies. After extraction
  only regular audio files that resolve inside the temp extraction dir are copied. Downloads
  and any redirects are https only (`--proto =https --proto-redir =https`).
- **Atomic per pack.** A pack is staged in a temp dir, copied next to its final folder as
  `<id>.part` (Navi ignores those), and swapped in by rename only when complete. Any failed step
  abandons that pack and leaves the installed copy as it was; the other packs still run. The
  summary names every failed pack (`done: 1 ok, 1 failed (my-pack)`) and the exit status is
  non-zero if any failed. An installed pack is kept on later runs only while its `pack.json`
  carries the manifest's current sha256, so changing a pin refetches it. If the previous copy
  cannot be deleted after a swap, the run prints `WARN    <id>: …` and lists every leftover
  `*.old.part` folder at the end (Navi ignores them; delete by hand).

Tests (local fixtures, no network, nothing touches the real folder; needs python3 to craft the
hostile zips):

```bash
bash keysounds/test-fetch-keysounds.sh
BASH_UNDER_TEST=/bin/bash bash keysounds/test-fetch-keysounds.sh   # macOS bash 3.2
```

## Packs

| profile | license | source |
|---|---|---|
| Cherry KC 1000 | CC0 | "Keyboard Soundpack #1" by unicaegames, https://opengameart.org/content/keyboard-soundpack-1-typing-and-single-keystrokes (32 single key presses) |
| Old Clicky | CC-BY 3.0 | "Single Key Press Sounds" by eklee, qubodup, https://opengameart.org/content/single-key-press-sounds (attribution required: *Single Key Press Sounds by eklee, qubodup*, https://creativecommons.org/licenses/by/3.0/) |
| Synth click | built-in | Navi's own code: generated at runtime, `SynthClick` in `app/Sources/PetCore/KeySounds.swift` |

Adding a pack to `packs-public.tsv` (in a pull request) means checking first that its license
allows redistribution (CC0, or CC-BY with the attribution in the line).
