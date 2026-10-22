"""Generate test-packs/test_telemetry/libs/tel_vectors.lua from contract/telemetry_vectors.json.

usage: python tools/gen_tel_vectors.py           write the file
       python tools/gen_tel_vectors.py --check   exit 1 if the file is out of date
"""
import json
import math
import os
import sys

SDK = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(SDK, "contract", "telemetry_vectors.json")
OUT = os.path.join(SDK, "test-packs", "test_telemetry", "libs", "tel_vectors.lua")

# Vectors that need lifecycle ops a running game cannot replay, and the pack test
# that covers the same rule instead.
COVERED_BY = {
    "held_during_game_start": "start group (calls made in game_start)",
    "aborted_launch_drops_held": "not replayable: needs a pack whose game_start raises",
    "closed_after_close_not_counted": "game_end calls (summary line) and the exit manual row",
    "no_session_is_closed": "not replayable: a running game always has a session",
}
FAR_MS = 600000   # an event time this far from start only sizes t_ms in the JSON


def lua_str(s):
    b = s.encode("utf-8")
    out = []
    for c in b:
        if c == 0x22:
            out.append('\\"')
        elif c == 0x5C:
            out.append("\\\\")
        elif 0x20 <= c < 0x7F:
            out.append(chr(c))
        else:
            out.append("\\%03d" % c)
    return '"' + "".join(out) + '"'


def lua_val(kind, value):
    if kind == "int":
        return str(int(value))
    if kind == "bool":
        return "true" if value else "false"
    if kind == "num":
        if isinstance(value, str):
            return {"nan": "(0/0)", "inf": "math.huge", "-inf": "-math.huge"}[value]
        v = float(value)
        r = repr(v)
        if "e" in r or "E" in r:
            r = "%.1f" % v
        return r
    if kind == "str":
        return lua_str(value)
    if kind == "bad":
        return "print"
    raise ValueError(kind)


def main():
    with open(SRC, encoding="utf-8") as f:
        data = json.load(f)
    lines = []
    w = lines.append
    w("-- libs/tel_vectors - GENERATED from contract/telemetry_vectors.json")
    w("-- (%s). Do not edit by hand: python tools/gen_tel_vectors.py." % data["schema"])
    w("-- Resolve: require(\"libs/tel_vectors\")")
    w("--")
    w("-- One entry per vector the running game can replay: the leading begin/start")
    w("-- ops are this launch, `at` is ms after the vector starts (event t minus")
    w("-- start t, modulo 2^32). Steps the contract marks c_only are left out.")
    w("-- fields is an array of {name, value} so the call order is fixed; a")
    w("-- non-table `fields`/`opts` is the contract's 'fail' case. expect/why are")
    w("-- the contract's; the pack re-derives rate outcomes from real call times")
    w("-- (a 33 ms tick cannot land on t=4999 exactly).")
    w("-- Integer literals past int32 (2147483648) become floats on the robot's")
    w("-- 32-bit Lua: still rejected, same outcome.")
    w("")
    w("local M = {}")
    w("")
    w("M.list = {")
    skipped = []
    for vec in data["vectors"]:
        steps = vec["steps"]
        name = vec["name"]
        if name in COVERED_BY:
            skipped.append((name, COVERED_BY[name]))
            continue
        ops = [s["op"] for s in steps]
        if ops[:2] != ["begin", "start"] or any(o not in ("event", "stats") for o in ops[2:]):
            print("unexpected ops in", name, ops, file=sys.stderr)
            return 1
        t_start = steps[1]["t"]
        out = []
        c_only = 0
        for st in steps[2:]:
            if st["op"] != "event":
                continue
            if st.get("c_only"):
                c_only += 1
                continue
            at = (st["t"] - t_start) & 0xFFFFFFFF
            if at > FAR_MS:
                at = 0
            parts = ["at = %d" % at, "name = %s" % lua_str(st["name"])]
            fail = st.get("fail")
            if fail == "bad_type":
                parts.append("fields = 42")
            elif "fields" in st:
                fs = []
                for fld in st["fields"]:
                    if fld[1] == "bad":
                        fs.append("{%s, print}" % lua_str(fld[0]))
                    else:
                        fs.append("{%s, %s}" % (lua_str(fld[0]), lua_val(fld[1], fld[2])))
                parts.append("fields = {%s}" % ", ".join(fs))
            if fail == "opt_value":
                parts.append('opts = "x"')
            else:
                o = []
                if "key" in st:
                    o.append("key = %s" % lua_str(st["key"]))
                if "level" in st:
                    o.append("level = %s" % lua_str(st["level"]))
                if st.get("opt_unknown"):
                    o.append("sample = 10")
                if o:
                    parts.append("opts = {%s}" % ", ".join(o))
            if fail not in (None, "bad_type", "opt_value"):
                print("unknown fail", fail, file=sys.stderr)
                return 1
            parts.append("expect = %s" % lua_str(st["expect"]))
            if "why" in st:
                parts.append("why = %s" % lua_str(st["why"]))
            out.append("      { " + ", ".join(parts) + " },")
        w("  {")
        w("    name = %s," % lua_str(name))
        if c_only:
            w("    c_only = %d,   -- steps only C can build (left out)" % c_only)
        w("    steps = {")
        lines.extend(out)
        w("    },")
        w("  },")
    w("}")
    w("")
    w("-- Vectors that need a launch to fail, an abort or no session at all.")
    w("M.skipped = {")
    for n, why in skipped:
        w("  { name = %s, why = %s }," % (lua_str(n), lua_str(why)))
    w("}")
    w("")
    w("return M")
    text = "\n".join(lines) + "\n"
    if "--check" in sys.argv[1:]:
        try:
            with open(OUT, encoding="utf-8") as f:
                same = f.read() == text
        except OSError:
            same = False
        print("tel_vectors up to date" if same else "tel_vectors OUT OF DATE: run python tools/gen_tel_vectors.py")
        return 0 if same else 1
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    tmp = OUT + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        f.write(text)
    os.replace(tmp, OUT)
    print("wrote", os.path.relpath(OUT, SDK), len(text.encode("utf-8")), "bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())
