"""Gate a demo's pika-spec.json before it goes to porting.

The browser can only guess at glyph coverage and never sees file sizes, so
this re-checks the exported spec against the shipped files and the engine
limits in contract/constraints.json.

usage: python tools/check_spec.py <pika-spec.json> [--root <demo dir>]
exit 0 = ready to port, 1 = blockers found.
"""
import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
CONSTRAINTS = os.path.join(HERE, "..", "contract", "constraints.json")

# Lint codes meaning the robot would refuse or break. Must match BLOCKING in kit/pika-frame.js.
BLOCKING_LINTS = {"L-FRAME-FMT", "L-TEXT", "L-TEXT-OVF", "L-TEXT-OVL", "L-XFORM", "L-SIZE", "L-WDOG", "L-ERROR",
                  "L-ASYNC", "L-INT", "L-LED", "L-INPUT", "L-SOUND", "L-API", "L-VOICE-EARLY", "L-HOOK-REBIND"}
HEADROOM = 0.8


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("spec")
    ap.add_argument("--root", help="demo folder (default: folder of the spec)")
    a = ap.parse_args()
    root = a.root or os.path.dirname(os.path.abspath(a.spec))
    with open(a.spec, encoding="utf-8") as f:
        spec = json.load(f)
    with open(CONSTRAINTS, encoding="utf-8") as f:
        lim = json.load(f)["limits"]

    block, warn = [], []

    for e in spec.get("lint", []):
        (block if e["code"] in BLOCKING_LINTS else warn).append(e["code"] + ": " + e["msg"])

    peak = spec.get("peak", {})
    if peak.get("texts", 0) > lim["text_slots"] * HEADROOM:
        warn.append("Text peak %d > %d%% of %d slots" % (peak["texts"], HEADROOM * 100, lim["text_slots"]))
    if peak.get("fonts", 0) > lim["font_slots"]:
        block.append("font face peak %d > %d" % (peak["fonts"], lim["font_slots"]))

    for path, s in spec.get("sprites", {}).items():
        if s["w"] > lim["img_max_w"] or s["h"] > lim["img_max_h"]:
            block.append("sprite %s %dx%d is larger than the screen" % (path, s["w"], s["h"]))

    manifest_fonts = spec.get("manifest", {}).get("fonts", {})
    try:
        from fontTools.ttLib import TTFont
    except ImportError:
        TTFont = None
        warn.append("fontTools not installed: glyph check skipped (pip install fonttools)")
    for fpath, chars in spec.get("glyphs", {}).items():
        if fpath == "(default)":
            warn.append("a Text uses the default font: %r" % chars[:40])
            continue
        full = os.path.join(root, fpath)
        if fpath not in manifest_fonts or not os.path.isfile(full):
            block.append("font %s: file not found next to the demo" % fpath)
            continue
        size = os.path.getsize(full)
        if size > lim["font_max_file_bytes"]:
            block.append("font %s is %d KB > %d KB" % (fpath, size // 1024, lim["font_max_file_bytes"] // 1024))
        if TTFont:
            cmap = TTFont(full).getBestCmap()
            miss = "".join(ch for ch in chars if ord(ch) not in cmap)
            if miss:
                block.append("font %s lacks glyphs %s (%s)" % (fpath, miss, " ".join("U+%04X" % ord(c) for c in miss)))

    sounds = spec.get("sounds", {})
    if len(sounds) > lim["sound_aliases_max"]:
        block.append("%d sound aliases > %d: the robot rejects the whole pack" % (len(sounds), lim["sound_aliases_max"]))
    to_record = []
    for alias, s in sounds.items():
        if len(alias) > lim["sound_alias_len_max"] - 1:
            block.append("alias %s is longer than %d chars" % (alias, lim["sound_alias_len_max"] - 1))
        if not s.get("path"):
            block.append("alias %s has no path" % alias)
            continue
        if len(s["path"]) > lim["sound_path_len_max"] - 1:
            block.append("path %s is longer than %d chars" % (s["path"], lim["sound_path_len_max"] - 1))
        if not os.path.isfile(os.path.join(root, s["path"])):
            to_record.append((alias, s["path"], s.get("say", "")))
        if not s.get("played"):
            warn.append("alias %s is declared but never played in the playtest" % alias)

    print("pika-spec: %s" % spec.get("game"))
    print("  sprites %d · Text peak %d/%d · font faces %d/%d · sprite PSRAM peak %d KB · aliases %d/%d" % (
        len(spec.get("sprites", {})), peak.get("texts", 0), lim["text_slots"], peak.get("fonts", 0),
        lim["font_slots"], peak.get("psram_bytes", 0) // 1024, len(sounds), lim["sound_aliases_max"]))
    if to_record:
        print("\nTo record (%d):" % len(to_record))
        for alias, path, say in to_record:
            print("  %-16s %-36s %s" % (alias, path, say))
    for title, items in (("\nBLOCKERS", block), ("\nWarnings", warn)):
        if items:
            print(title + " (%d):" % len(items))
            for i in items:
                print("  - " + i)
    print("\nVerdict: %s" % ("READY TO PORT" if not block else "NOT READY - fix blockers first"))
    return 1 if block else 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
