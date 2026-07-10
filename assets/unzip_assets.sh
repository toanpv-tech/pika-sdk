#!/usr/bin/env bash
# unzip_assets.sh — extract every .zip in each asset category into per-pack folders.
#
# Each archive kenney_foo.zip is unpacked into a sibling folder kenney_foo/ so
# packs never overwrite each other's License.txt / Preview.png. Re-runnable:
# a pack whose folder already exists is skipped, so adding new .zip files and
# re-running only extracts the new ones. Source .zip files are left in place.
#
# Usage:
#   ./unzip_assets.sh                 # extract ALL categories next to this script
#   ./unzip_assets.sh <dir>           # extract one specific folder of .zips
#   FORCE=1 ./unzip_assets.sh         # re-extract even if the folder exists
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
categories=(2D 3D Audio Pixel Textures UI)

if ! command -v unzip >/dev/null 2>&1; then
  echo "error: 'unzip' not found on PATH" >&2
  exit 1
fi

# Extract every .zip in one folder into per-pack subfolders. Accumulates into
# the global counters. Returns 0 always (per-archive failures are counted).
extracted=0 skipped=0 failed=0 total=0
extract_dir() {
  local target_dir="$1"
  shopt -s nullglob
  local zips=("$target_dir"/*.zip)
  if (( ${#zips[@]} == 0 )); then
    return 0
  fi
  local zip name dest rc
  for zip in "${zips[@]}"; do
    ((total++)) || true
    name="$(basename "$zip" .zip)"
    dest="$target_dir/$name"

    if [[ -d "$dest" && "${FORCE:-0}" != "1" ]]; then
      printf 'skip    %s\n' "$name"
      ((skipped++)) || true
      continue
    fi

    printf 'extract %s ...\n' "$name"
    mkdir -p "$dest"
    # -o overwrite, -q quiet; -d into the per-pack folder. unzip exit 1 is a
    # non-fatal warning (e.g. UTF-8 local/central filename mismatch on packs
    # named "2×"); files still extract, so only >=2 is a real failure.
    rc=0
    unzip -o -q "$zip" -d "$dest" || rc=$?
    if (( rc <= 1 )); then
      ((extracted++)) || true
    else
      echo "  FAILED: $name (unzip rc=$rc)" >&2
      ((failed++)) || true
    fi
  done
}

if (( $# >= 1 )); then
  # Explicit single folder.
  [[ -d "$1" ]] || { echo "error: not a directory: $1" >&2; exit 1; }
  extract_dir "$1"
else
  # All categories next to this script.
  for cat in "${categories[@]}"; do
    dir="$script_dir/$cat"
    [[ -d "$dir" ]] || continue
    printf '########## %s ##########\n' "$cat"
    extract_dir "$dir"
  done
fi

printf '\ndone: %d extracted, %d skipped, %d failed (of %d archives)\n' \
  "$extracted" "$skipped" "$failed" "$total"
(( failed == 0 ))
