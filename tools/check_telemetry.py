"""Check tools/smoke_stub.lua's Telemetry.event against contract/telemetry_vectors.json.

The firmware runs the same vectors through core/game_tel.c
(head_esp32/test/host/game_tel/run_tests.py), so the stub cannot drift from
the robot. The stub builds no JSON: only results, reasons and counters are
compared here.

usage: python tools/check_telemetry.py
Needs: pip install lupa (Lua 5.5), and contract/api.json listing Telemetry
(run tools/gen_contract.py first).
"""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)


def load_json(p):
    with open(p, encoding="utf-8") as f:
        return json.load(f)


def lua_value(rt, kind, value):
    if kind == "num":
        if isinstance(value, str):
            return {"nan": float("nan"), "inf": float("inf"), "-inf": float("-inf")}[value]
        return float(value)
    if kind == "bad":
        return rt.eval("function() end")
    return value


def main():
    try:
        from lupa import lua55
    except ImportError:
        print("needs lupa with Lua 5.5: pip install -r tools/requirements.txt")
        return 2
    api = load_json(os.path.join(SDK, "contract", "api.json"))
    if "Telemetry" not in api.get("globals", {}):
        print("contract/api.json has no Telemetry: run tools/gen_contract.py")
        return 2
    lim = load_json(os.path.join(SDK, "contract", "constraints.json"))["limits"]
    vectors = load_json(os.path.join(SDK, "contract", "telemetry_vectors.json"))["vectors"]

    rt = lua55.LuaRuntime(unpack_returned_tuples=True, register_eval=False)
    reports = []
    rt.globals().HOST = rt.table_from({
        "api": api, "lim": lim, "manifest": {}, "file_size": lambda r: None, "png_size": lambda r: None,
        "sound_ms": lambda r: 1000, "anim_ms": lambda r: None, "anim_ok": lambda r: False, "read": lambda r: None,
        "report": lambda k, c, m: reports.append((k, c, m)), "print": lambda s: None,
    }, recursive=True)
    with open(os.path.join(HERE, "smoke_stub.lua"), encoding="utf-8") as f:
        stub = rt.execute(f.read())
    call_event = rt.eval("""function(env, name, fields, opts)
      return env.Telemetry.event(name, fields, opts)
    end""")

    errors, checks = [], 0
    for vec in vectors:
        session = False
        for st in vec["steps"]:
            op = st["op"]
            if st.get("c_only"):
                continue
            where = "%s t=%s %s" % (vec["name"], st.get("t", "-"), st.get("name", op))
            if op == "begin":
                ok, err = stub.new_session("", "main.lua")
                if not ok:
                    errors.append(where + ": new_session failed: " + str(err))
                session = True
                continue
            if not session:
                # No launch yet: the robot has no session, every call is CLOSED.
                stub.new_session("", "main.lua")
                stub.tel_abort()
                session = True
            state = stub.state()
            if op == "start":
                state.now = st["t"]
                pending = stub.tel().pending
                closed = stub.tel().closed
                stub.hook("game_start")
                checks += 1
                want = len(st["flush"])
                got = 0 if closed else pending
                if got != want:
                    errors.append("%s: flushed %d want %d" % (where, got, want))
            elif op == "close":
                stub.hook("game_end")
            elif op == "abort":
                stub.tel_abort()
            elif op == "stats":
                t = stub.tel()
                checks += 1
                got = (t.sent, t.dropped, t.opt_unknown)
                want = (st["sent"], st["dropped"], st["opt_unknown"])
                if got != want:
                    errors.append("%s: stats %s want %s" % (where, got, want))
            elif op == "event":
                state.now = st["t"]
                fields = None
                if "fields" in st or st.get("fail") == "bad_type":
                    if st.get("fail") == "bad_type":
                        fields = 42          # not a table
                    else:
                        # Ordered: a Lua table keeps insertion order for this many keys only
                        # by luck, so the vectors never depend on field order for errors.
                        fields = rt.table()
                        for fld in st["fields"]:
                            fields[fld[0]] = lua_value(rt, fld[1], fld[2] if len(fld) > 2 else None)
                opts = None
                if any(k in st for k in ("key", "level", "opt_unknown")) or st.get("fail") == "opt_value":
                    if st.get("fail") == "opt_value":
                        opts = "x"           # not a table
                    else:
                        opts = rt.table()
                        if "key" in st:
                            opts["key"] = st["key"]
                        if "level" in st:
                            opts["level"] = st["level"]
                        if st.get("opt_unknown"):
                            opts["sample"] = 10
                call_event(state.env, st["name"], fields, opts)
                last = stub.tel().last
                checks += 1
                exp = st["expect"]
                want = {"send": "sent", "held": "held"}.get(exp, st.get("why"))
                if last != want:
                    errors.append("%s: got %s want %s" % (where, last, want))
            else:
                errors.append(where + ": unknown op " + op)
    for e in errors:
        print("FAIL " + e)
    print("%d vectors, %d checks, %d failures" % (len(vectors), checks, len(errors)))
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
