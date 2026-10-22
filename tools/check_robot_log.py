"""Score a robot (or Pika Studio) serial log against the release checklist's telemetry gates.

Reads the engine's own lines (docs/reference/telemetry.md): game.start, game.running,
game.error, game.stalled, game.stop and the engine warnings, splits them into sessions
and applies the gates of docs/guides/release-checklist.md "Telemetry gates". A gate the
log cannot decide (no game.stop, no game.running) is INCONCLUSIVE, never PASS.

FAIL  a gate the checklist states as a hard rule: game.error, game.stalled, end= other
      than norm/home, err=, api_fail > 0, drop=.
WARN  a heuristic (🧪 in the checklist): tick_hz well below tick_hz_max, a high slow_pm,
      arena or psram drifting between rounds or launches, engine warning lines.

usage: python tools/check_robot_log.py <log file> [--game <id>] [--json out.json]
exit 0 = PASS (warnings allowed), 1 = FAIL, 2 = usage, 3 = INCONCLUSIVE.
"""
import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.dirname(HERE)

KINDS = ("game.start", "game.running", "game.error", "game.stalled", "game.stop")
LINE = re.compile(r"\b(" + "|".join(re.escape(k) for k in KINDS) + r")\b(.*)$")
FIELD = re.compile(r'(\w+)=("(?:[^"\\]|\\.)*"|\S+)')
# Engine warning lines worth a look (telemetry.md "Other engine lines").
ENGINE_WARN = [
    ("font cache full", "font faces exhausted"),
    ("play throttled", "Speaker.play within the cooldown"),
    ("inflight saturated", "sounds issued too fast"),
    ("ring overflow", "button events lost"),
    ("on stale handle", "method on a destroyed handle"),
    ("sprite_xform refused", "transform over the limit"),
    ("line pool budget", "Shape line budget exceeded"),
    ("alloc near_budget", "Lua heap near its budget"),
    ("telemetry reject", "Telemetry.event rejected"),
]
TICK_HZ_SLACK = 3      # 🧪 "close to tick_hz_max"
SLOW_PM_WARN = 50      # 🧪 slow frames per mille in steady play
DRIFT_WARN = 0.10      # 🧪 arena / psram drift between rounds or launches


def fields(rest):
    out = {}
    for k, v in FIELD.findall(rest):
        out[k] = v[1:-1] if v.startswith('"') else v
    return out


def num(d, k):
    try:
        return float(d[k].split("/")[0])
    except (KeyError, ValueError):
        return None


def parse(path, game):
    sessions, cur, warns = [], None, {}
    with open(path, encoding="utf-8", errors="replace") as f:
        for n, raw in enumerate(f, 1):
            line = raw.rstrip("\n")
            for needle, label in ENGINE_WARN:
                if needle in line:
                    warns.setdefault(label, []).append(n)
            m = LINE.search(line)
            if not m:
                continue
            kind, d = m.group(1), fields(m.group(2))
            if game and d.get("game", game) != game:
                continue
            if kind == "game.start" or cur is None:
                cur = {"game": d.get("game"), "start": None, "running": [], "errors": [],
                       "stalled": [], "stop": None, "first_line": n}
                sessions.append(cur)
            rec = dict(d, _line=n)
            if kind == "game.start":
                cur["start"] = rec
            elif kind == "game.running":
                cur["running"].append(rec)
            elif kind == "game.error":
                cur["errors"].append(rec)
            elif kind == "game.stalled":
                cur["stalled"].append(rec)
            elif kind == "game.stop":
                cur["stop"] = rec
                cur = None
    return sessions, warns


def score(sessions, warns, tick_hz_max):
    gates = []   # (gate, verdict, evidence)

    def add(gate, verdict, evidence):
        gates.append({"gate": gate, "verdict": verdict, "evidence": evidence})

    if not sessions:
        add("log has game lines", "INCONCLUSIVE", "no game.start/running/stop/error line found")
        return gates

    for i, s in enumerate(sessions, 1):
        tag = "session %d (%s, line %d)" % (i, s["game"] or "?", s["first_line"])
        load_err = [e for e in s["errors"] if e.get("phase") in ("load", "render")]
        add(tag + ": the pack opens", "FAIL" if load_err else "PASS",
            ["line %d code=%s phase=%s" % (e["_line"], e.get("code"), e.get("phase")) for e in load_err])
        run_err = [e for e in s["errors"] if e not in load_err]
        if run_err:
            add(tag + ": no runtime error", "FAIL",
                ["line %d code=%s phase=%s msg=%s" % (e["_line"], e.get("code"), e.get("phase"), e.get("msg"))
                 for e in run_err])
        if s["stalled"]:
            add(tag + ": nothing stalled", "FAIL", ["line %d" % r["_line"] for r in s["stalled"]])
        st = s["stop"]
        if st is None:
            if not load_err:
                add(tag + ": ended cleanly", "INCONCLUSIVE", "no game.stop (log cut, or the robot rebooted)")
            continue
        end_ok = st.get("end") in ("norm", "home") and "err" not in st
        add(tag + ": ended cleanly", "PASS" if end_ok else "FAIL",
            "line %d end=%s%s" % (st["_line"], st.get("end"), " err=" + st["err"] if "err" in st else ""))
        calls_ok = num(st, "api_fail") == 0 and "drop" not in st
        add(tag + ": no call failed silently", "PASS" if calls_ok else "FAIL",
            "line %d api_fail=%s%s" % (st["_line"], st.get("api_fail"), " drop=" + st["drop"] if "drop" in st else ""))
        steady = s["running"][1:]   # the first game.running covers one frame
        hz = [num(r, "tick_hz") for r in steady + [st] if num(r, "tick_hz") is not None]
        slow = num(st, "slow_pm")
        if hz:
            low = min(hz) < tick_hz_max - TICK_HZ_SLACK
            high_slow = slow is not None and slow > SLOW_PM_WARN
            add(tag + ": frames keep time", "WARN" if (low or high_slow) else "PASS",
                "tick_hz min=%g (tick_hz_max = %d), slow_pm=%s" % (min(hz), tick_hz_max, st.get("slow_pm")))
        arena = [num(r, "arena") for r in steady if num(r, "arena")]
        if len(arena) >= 2 and arena[-1] > arena[0] * (1 + DRIFT_WARN):
            add(tag + ": no leak between rounds", "WARN",
                "arena %d -> %d over %d game.running lines" % (arena[0], arena[-1], len(arena)))

    psram = [(s["start"]["_line"], num(s["start"], "psram")) for s in sessions
             if s["start"] and num(s["start"], "psram")]
    if len(psram) >= 2:
        fell = psram[-1][1] < psram[0][1] * (1 - DRIFT_WARN)
        add("launch to launch: psram in game.start", "WARN" if fell else "PASS",
            "psram %d (line %d) -> %d (line %d)" % (psram[0][1], psram[0][0], psram[-1][1], psram[-1][0]))
    for label, lines in sorted(warns.items()):
        add("engine warning: " + label, "WARN", "%d line(s), first at line %d" % (len(lines), lines[0]))
    return gates


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("log")
    ap.add_argument("--game")
    ap.add_argument("--json")
    a = ap.parse_args()
    if not os.path.isfile(a.log):
        print("no such file: " + a.log)
        return 2
    with open(os.path.join(SDK, "contract", "constraints.json"), encoding="utf-8") as f:
        tick_hz_max = json.load(f)["derived"]["tick_hz_max"]
    sessions, warns = parse(a.log, a.game)
    gates = score(sessions, warns, tick_hz_max)
    for g in gates:
        ev = g["evidence"]
        ev = "; ".join(ev) if isinstance(ev, list) else ev
        print("%-12s %s%s" % (g["verdict"], g["gate"], ("  [" + ev + "]") if ev else ""))
    verdicts = {g["verdict"] for g in gates}
    final = "FAIL" if "FAIL" in verdicts else "INCONCLUSIVE" if "INCONCLUSIVE" in verdicts else "PASS"
    n_warn = sum(g["verdict"] == "WARN" for g in gates)
    print("Verdict: %s (%d session(s), %d warning(s))" % (final, len(sessions), n_warn))
    if a.json:
        with open(a.json, "w", encoding="utf-8") as f:
            json.dump({"verdict": final, "sessions": len(sessions), "gates": gates}, f, ensure_ascii=False, indent=2)
    return {"PASS": 0, "FAIL": 1, "INCONCLUSIVE": 3}[final]


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
