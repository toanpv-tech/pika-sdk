#!/usr/bin/env bash
# gen_assets_index.sh — build assets.index.json from the extracted Kenney packs.
#
# Walks each category (2D/3D/Audio/Pixel/Textures/UI), and for every extracted
# pack folder records: id, category, whether a Preview/Sample cover exists, the
# license line (from License.txt), and asset file counts by kind. This is the
# machine-readable catalog the Pika Studio asset browser filters on.
#
# Run AFTER unzip_assets.sh (needs the extracted folders, not the .zip).
# Usage: ./gen_assets_index.sh   (writes assets.index.json next to this script)
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/assets.index.json"
categories=(2D 3D Audio Pixel Textures UI)

# JSON string escape (backslash, quote, control -> space).
esc() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\n\r\t' '   '; }

{
  printf '{\n'
  printf '  "schema": "pika-sdk-assets/1",\n'
  printf '  "source": "Kenney (kenney.nl) — CC0 unless a pack License.txt says otherwise",\n'
  printf '  "packs": [\n'

  first=1
  for cat in "${categories[@]}"; do
    catdir="$here/$cat"
    [[ -d "$catdir" ]] || continue
    for pack in "$catdir"/*/; do
      [[ -d "$pack" ]] || continue
      id="$(basename "$pack")"

      # cover: first of Preview / Sample / cover (png then jpg, case-insensitive)
      cover=""
      for c in Preview.png Sample.png cover.png preview.png sample.png \
               Preview.jpg preview.jpg Sample.jpg sample.jpg; do
        if [[ -f "$pack/$c" ]]; then cover="$c"; break; fi
      done

      # name + license from License.txt: the pack title is the first line that
      # contains a letter or digit (e.g. "1-Bit Pack (1.2)" / "Animal pack").
      # Some packs open with a separator rule (#######…) or blank lines — skip
      # any line that has no alphanumeric character. The "License:" line carries
      # the real terms (Kenney packs are CC0). Strip surrounding whitespace/CR.
      # Prefer License.txt; fall back to readme.txt for packs that ship without
      # a license file (still CC0 — that is the store-wide default above).
      name_txt="" lic="CC0"
      meta_txt=""
      if   [[ -f "$pack/License.txt" ]]; then meta_txt="$pack/License.txt"
      elif [[ -f "$pack/readme.txt"  ]]; then meta_txt="$pack/readme.txt"
      elif [[ -f "$pack/README.txt"  ]]; then meta_txt="$pack/README.txt"
      fi
      if [[ -n "$meta_txt" ]]; then
        name_txt="$(grep -m1 -E '[[:alnum:]]' "$meta_txt" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' || true)"
        l="$(grep -m1 -iE '^\s*License:' "$meta_txt" 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*[Ll]icense:[[:space:]]*//; s/[[:space:]]*$//' || true)"
        [[ -n "$l" ]] && lic="$l"
      fi
      # Last resort: derive a readable name from the folder id.
      if [[ -z "$name_txt" ]]; then
        name_txt="$(printf '%s' "$id" | sed 's/^kenney_//; s/[-_]/ /g')"
      fi

      png=$(find "$pack" -type f -iname '*.png' | wc -l | tr -d ' ')
      gif=$(find "$pack" -type f \( -iname '*.gif' -o -iname '*.mjpeg' \) | wc -l | tr -d ' ')
      aud=$(find "$pack" -type f \( -iname '*.mp3' -o -iname '*.wav' -o -iname '*.ogg' \) | wc -l | tr -d ' ')

      # infer kinds from content
      kinds=""
      (( png > 0 )) && kinds='"sprite"'
      (( gif > 0 )) && kinds="${kinds:+$kinds, }\"anim\""
      (( aud > 0 )) && kinds="${kinds:+$kinds, }\"audio\""

      (( first )) || printf ',\n'
      first=0
      printf '    { "id": "%s", "name": "%s", "category": "%s", "kinds": [%s], "cover": "%s", "license": "%s", "counts": { "png": %s, "anim": %s, "audio": %s } }' \
        "$(esc "$id")" "$(esc "$name_txt")" "$cat" "$kinds" "$(esc "$cover")" "$(esc "$lic")" "$png" "$gif" "$aud"
    done
  done

  printf '\n  ]\n}\n'
} > "$out"

n=$(grep -c '"id":' "$out" || true)
echo "wrote $out ($n packs)"
