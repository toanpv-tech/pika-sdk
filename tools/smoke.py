"""Lint and smoke-run a Lua game pack on a PC, against a closed stub of the Pika Engine.

Runs the pack in real Lua 5.5 (the version the engine embeds) inside the same
sandbox the robot builds: base/table/string/math/utf8 only, no load/loadfile/
dofile/io/os/debug/coroutine, `require` limited to libs/<name>. Every engine
global is built from contract/api.json: reading a name the robot does not have
is reported and gives nil, and calling it fails, exactly as on the robot. Pools,
font faces, the transform gate, hidden-until-placed sprites, PNG cost from the
header, frame strips, the flip bug, one playing Anim, the sound channel and
cooldown, the body board's voice session, hooks bound once and handle garbage
collection follow the engine's rules (tools/smoke_stub.lua).

It proves logic and contract use. It does not draw, play sound or measure time:
look at the result in Pika Studio, and prove performance on a robot.

Codes (ERROR: the robot refuses or breaks it; WARN: likely wrong):
  ERROR MANIFEST SYNTAX SOUND ACTION REQUIRE SANDBOX LOAD HOOK LED
  ERROR API           a call to a name the engine does not register
  ERROR TEXT          Text.new past the pool: pool_full
  ERROR XFORM         set_scale/set_rotation on a sprite over the transform limit
  ERROR FRAME-FMT     set_frame given a PNG (strips are raw)
  ERROR VOICE-EARLY   Voice.set_keywords/start in the top level or game_start (dropped)
  ERROR HOOK-REBIND   on_tick/on_input reassigned after load (the robot keeps the first)
  WARN  API, MISSING-API  reading a name the engine does not register (nil)
  WARN  KI-FLIP-FRAME set_frame on a flipped sprite, or set_flip no-op after set_frame
  WARN  HANDLE-GC     a live Sprite/Text/Shape/Anim was collected: keep a reference
  WARN  PC-CCALLS     a long `..` chain may not load (nested C calls)
  WARN  INT32         an integer argument outside the robot's 32-bit range
  WARN  PC-ROOT-LEN   the pack folder path is too long for Pika Studio's sound paths (PC only)
  WARN  FRAME COOLDOWN SOUND VOICE INPUT ACTION SERVO HIDDEN NOT-SIMULATED MANIFEST

usage: python tools/smoke.py <pack dir> [steps] [--language <code>] [--json out.json]
  steps: comma list, same words as tools/playtest.js
         left|right|enter|home   press (button:<name>) and release after 80 ms
         hold:<button>:<ms>      hold a button (REPEAT events on the robot's timing)
         wait:<ms>               let time pass
         voice:<keyword>         deliver a VOICE_COMMAND event
         restart                 end the session and start a fresh VM
  default: a short run that presses every button, restarts and exits with HOME.
  --language: params.language passed to game_start (default en); run once per UI language.
exit 0 = no errors, 1 = errors, 2 = usage.

Needs: pip install lupa  (see tools/requirements.txt)
"""
import argparse
import json
import os
import re
import struct
import sys
import wave

HERE = os.path.dirname(os.path.abspath(__file__))
SDK = os.path.abspath(os.path.join(HERE, ".."))
DEFAULT_STEPS = ("wait:1500,enter,wait:800,right,wait:800,left,wait:800,enter,wait:2500,"
                 "restart,wait:800,enter,wait:1500,home")
HOOK_INSTR_LIMIT = 50_000_000   # endless-loop detector, not a timing model
BUTTONS = ("left", "right", "enter")


def load_json(path):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


class Report:
    def __init__(self):
        self.items = []

    def add(self, kind, code, msg):
        self.items.append((kind, code, msg))

    def errors(self):
        return [i for i in self.items if i[0] == "error"]


def png_size(path):
    """(w, h, has_alpha) by the engine's rule (asset_loader.c png_has_alpha): colour
    type 4/6, a tRNS chunk before the first IDAT, or anything malformed."""
    with open(path, "rb") as f:
        d = f.read()
    if d[:8] != b"\x89PNG\r\n\x1a\n" or len(d) < 29 or d[12:16] != b"IHDR":
        return None
    w, h = struct.unpack(">II", d[16:24])
    if d[25] in (4, 6):
        return w, h, True
    pos = 8
    while len(d) - pos >= 12:
        ln = struct.unpack(">I", d[pos:pos + 4])[0]
        typ = d[pos + 4:pos + 8]
        if typ == b"tRNS":
            return w, h, True
        if typ in (b"IDAT", b"IEND"):
            return w, h, False
        pos += 12 + ln
    return w, h, True


def gif_ms(path, min_frame_ms, tick_ms):
    """One pass of a GIF: each frame lasts its delay, at least min_frame_ms and one engine frame."""
    with open(path, "rb") as f:
        d = f.read()
    if d[:3] != b"GIF" or len(d) < 13:
        return None
    pos, total, delay = 13, 0, 0
    if d[10] & 0x80:
        pos += 3 << ((d[10] & 7) + 1)

    def skip_blocks(i):
        while i < len(d) and d[i]:
            i += d[i] + 1
        return i + 1

    while pos < len(d) and d[pos] != 0x3B:
        if d[pos] == 0x21:
            if pos + 6 < len(d) and d[pos + 1] == 0xF9:
                delay = struct.unpack("<H", d[pos + 4:pos + 6])[0] * 10
            pos = skip_blocks(pos + 2)
        elif d[pos] == 0x2C and pos + 9 < len(d):
            flags = d[pos + 9]
            pos += 10 + ((3 << ((flags & 7) + 1)) if flags & 0x80 else 0)
            pos = skip_blocks(pos + 1)
            total += max(delay, min_frame_ms, tick_ms)
            delay = 0
        else:
            return None
    return total or None


def sound_ms(path):
    try:
        with wave.open(path, "rb") as w:
            return int(w.getnframes() * 1000 / w.getframerate())
    except (wave.Error, EOFError):
        return int(os.path.getsize(path) * 8 / 128000 * 1000)   # mp3 at ~128 kbps


def lint(pack, man, api, lim, rt, rep):
    main = man.get("main")
    if not isinstance(main, str):
        rep.add("error", "MANIFEST", "manifest: 'main' missing")
    elif not os.path.isfile(os.path.join(pack, main)):
        rep.add("error", "MANIFEST", "manifest: main '%s' not found" % main)

    acts = (man.get("input") or {}).get("actions") or {}
    if len(acts) > lim["input_actions_max"]:
        rep.add("error", "MANIFEST", "%d input actions > %d" % (len(acts), lim["input_actions_max"]))
    for a, srcs in acts.items():
        if len(a) > lim["input_action_name_max"] - 1:
            rep.add("error", "MANIFEST", "action name '%s' too long" % a)
        for s in srcs if isinstance(srcs, list) else []:
            if s not in ("button:" + b for b in BUTTONS):
                rep.add("warn", "MANIFEST", "action '%s' source '%s' is not a robot button" % (a, s))

    sounds = ((man.get("audio") or {}).get("sounds")) or {}
    if len(sounds) > lim["sound_aliases_max"]:
        rep.add("error", "MANIFEST", "%d sound aliases > %d: the robot rejects the whole pack" % (len(sounds), lim["sound_aliases_max"]))
    for alias, d in sounds.items():
        if len(alias) > lim["sound_alias_len_max"] - 1:
            rep.add("error", "MANIFEST", "sound alias '%s' too long" % alias)
        srcs = [k for k in ("path", "url") if isinstance(d.get(k), str)] + (["remote"] if d.get("remote") is True else [])
        if len(srcs) != 1:
            rep.add("error", "MANIFEST", "sound '%s' needs exactly one of path/url/remote" % alias)
        p = d.get("path")
        if isinstance(p, str) and not os.path.isfile(os.path.join(pack, p)):
            rep.add("error", "MANIFEST", "sound '%s': %s not found (the robot rejects the whole pack)" % (alias, p))
        # PC-ROOT-LEN: Pika Studio joins <games folder>/<game_id>/<path> into a fixed buffer.
        if isinstance(p, str) and len((pack + "/" + p).encode("utf-8")) >= lim["sound_abs_path_max"]:
            rep.add("warn", "PC-ROOT-LEN", "sound '%s': %s/%s is %d bytes, over %d: Pika Studio fails this pack "
                    "from this folder (fine on the robot); move the games folder to a shorter path"
                    % (alias, pack, p, len((pack + "/" + p).encode("utf-8")), lim["sound_abs_path_max"] - 1))
    old = ((man.get("assets") or {}).get("audio") or {})
    if old and not sounds:
        rep.add("error", "MANIFEST", "sounds are read from audio.sounds; assets.audio is ignored, so no sound is declared")
    elif "assets" in man:
        rep.add("warn", "MANIFEST", "'assets' is not a manifest key the engine reads (ignored)")

    g = api["globals"]
    call = re.compile(r"\b(" + "|".join(sorted(g, key=len, reverse=True)) + r")\.([A-Za-z_]\w*)(\s*[(\"'{])?")
    strings = re.compile(r"\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'")
    # Heuristic (PC-CCALLS): the parser spends a C level per chained `..` and about 20
    # fail to load with lua_maxccalls = 30, so warn at half the budget plus one.
    concat_warn = lim["lua_maxccalls"] // 2 + 1
    lit = lambda fn: re.compile(fn + r"""\(\s*["']([^"']+)["']""")
    re_play, re_req = lit(r"Speaker\.play"), lit(r"\brequire")
    re_inp = re.compile(r"""Input\.(?:is_down|just_pressed|just_released|hold_ms)\(\s*["']([^"']+)["']""")
    compile_ = rt.eval("function(src, name) local f, e = load(src, '@' .. name, 't', {}); return e end")

    for d, _, fs in os.walk(pack):
        for fn in fs:
            if not fn.endswith(".lua"):
                continue
            full = os.path.join(d, fn)
            rel = os.path.relpath(full, pack).replace("\\", "/")
            src = open(full, encoding="utf-8").read()
            err = compile_(src, rel)
            if err:
                rep.add("error", "SYNTAX", str(err))
                continue
            chain, chain_at = 0, 0
            for n, line in enumerate(src.splitlines(), 1):
                code = line.split("--", 1)[0]
                for glob, name, called in call.findall(code):
                    v = g[glob]
                    if name not in v["functions"] + v["constants"] + v["methods"]:
                        if called:
                            rep.add("error", "API", "%s:%d  %s.%s(...) is not an engine API: calling it raises on the robot "
                                    "(see docs/reference/api.md#calls-that-do-not-exist)" % (rel, n, glob, name))
                        else:
                            rep.add("warn", "API", "%s:%d  %s.%s is not an engine API (reads nil on the robot)" % (rel, n, glob, name))
                # A `..` chain may continue on the next line: count until a line does not end in `..`.
                bare = strings.sub('""', code)
                chain_at = chain_at or n
                chain += len(re.findall(r"(?<!\.)\.\.(?!\.)", bare))
                if not bare.rstrip().endswith(".."):
                    if chain >= concat_warn:
                        rep.add("warn", "PC-CCALLS", "%s:%d  %d chained '..' in one expression may fail to load on the robot: "
                                "nested C calls limited to lua_maxccalls = %d; use table.concat or split the expression"
                                % (rel, chain_at, chain, lim["lua_maxccalls"]))
                    chain, chain_at = 0, 0
                for a in re_play.findall(code):
                    if a not in sounds:
                        rep.add("error", "SOUND", "%s:%d  Speaker.play('%s'): alias not in manifest" % (rel, n, a))
                for a in re_inp.findall(code):
                    if a not in acts:
                        rep.add("error", "ACTION", "%s:%d  action '%s' not in manifest.input.actions" % (rel, n, a))
                for m in re_req.findall(code):
                    if not m.startswith("libs/") or not os.path.isfile(os.path.join(pack, m + ".lua")):
                        rep.add("error", "REQUIRE", "%s:%d  require('%s'): only existing libs/<name> modules load" % (rel, n, m))
                for name in ("load", "loadfile", "dofile", "io", "os", "debug", "coroutine", "package"):
                    if re.search(r"(?<![\w.:])" + name + r"\s*[.(]", code):
                        rep.add("error", "SANDBOX", "%s:%d  '%s' is not available in the engine sandbox" % (rel, n, name))


def schedule(steps):
    """Steps -> sorted [(t_ms, kind, arg)]."""
    t, out = 800, []
    for s in [x.strip() for x in steps.split(",") if x.strip()]:
        parts = s.split(":")
        k = parts[0]
        if k == "wait":
            t += int(parts[1])
        elif k in BUTTONS:
            out += [(t, "down", k), (t + 80, "up", k)]
            t += 200
        elif k == "hold":
            ms = int(parts[2])
            out += [(t, "down", parts[1]), (t + ms, "up", parts[1])]
            t += ms + 100
        elif k == "voice":
            out.append((t, "voice", parts[1]))
            t += 100
        elif k in ("home", "restart"):
            out.append((t, k, None))
            t += 300
        else:
            raise SystemExit("unknown step: " + s)
    return sorted(out, key=lambda e: e[0]), t + 800


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("pack")
    ap.add_argument("steps", nargs="?", default=DEFAULT_STEPS)
    ap.add_argument("--language", default="en",
                    help="params.language for game_start, an ISO 639-1 code (default: en)")
    ap.add_argument("--json")
    a = ap.parse_args()
    if not re.fullmatch(r"[a-z]{2}", a.language):
        print("--language takes a two-letter ISO 639-1 code, e.g. vi or en")
        return 2
    try:
        from lupa import lua55
    except ImportError:
        print("needs lupa with Lua 5.5: pip install -r tools/requirements.txt")
        return 2

    pack = os.path.abspath(a.pack)
    mpath = os.path.join(pack, "manifest.json")
    if not os.path.isfile(mpath):
        print("no manifest.json in " + pack)
        return 2
    man = load_json(mpath)
    api = load_json(os.path.join(SDK, "contract", "api.json"))
    cons = load_json(os.path.join(SDK, "contract", "constraints.json"))
    lim, der = cons["limits"], cons["derived"]
    # The robot passes dt_ms (nominal) but frames are tick_period_ms apart (KI-DT-NOMINAL).
    dt_ms, period_ms = der["dt_ms"], der["tick_period_ms"]
    rep_delay, rep_rate = lim["button_repeat_delay_ms"], lim["button_repeat_rate_ms"]
    rep = Report()
    logs = []

    rt = lua55.LuaRuntime(unpack_returned_tuples=True, register_eval=False)
    lint(pack, man, api, lim, rt, rep)

    def rel_ok(rel):
        full = os.path.normpath(os.path.join(pack, rel))
        return full if full.startswith(pack) else None

    def file_size(rel):
        p = rel_ok(rel)
        return os.path.getsize(p) if p and os.path.isfile(p) else None

    def png(rel):
        p = rel_ok(rel)
        return png_size(p) if p and os.path.isfile(p) else None

    def anim_ms(rel):
        p = rel_ok(rel)
        if not (p and os.path.isfile(p) and p.lower().endswith(".gif")):
            return None
        return gif_ms(p, lim["anim_min_frame_ms"], der["tick_period_ms"])

    def read(rel):
        p = rel_ok(rel)
        return open(p, encoding="utf-8").read() if p and os.path.isfile(p) else None

    def sms(rel):
        p = rel_ok(rel)
        return sound_ms(p) if p and os.path.isfile(p) else 1000

    host = rt.table_from({
        "api": api, "lim": lim, "manifest": man, "file_size": file_size, "png_size": png,
        "sound_ms": sms, "anim_ms": anim_ms, "read": read, "report": lambda k, c, m: rep.add(k, c, m),
        "print": lambda s: logs.append(s),
    }, recursive=True)
    rt.globals().HOST = host
    stub = rt.execute(open(os.path.join(HERE, "smoke_stub.lua"), encoding="utf-8").read())
    watchdog = rt.eval("""function(stub, limit)
      return function(name, ...)
        local used = 0
        debug.sethook(function()
          used = used + 1000
          if used > limit then debug.sethook(); error("watchdog: hook ran over the instruction budget (endless loop?)", 0) end
        end, "", 1000)
        local ok, r, had = stub.hook(name, ...)
        debug.sethook()
        return ok, r, had, used
      end
    end""")(stub, HOOK_INSTR_LIMIT)
    peak_instr = {}

    def call(name, *args):
        ok, r, had, used = watchdog(name, *args)
        if had:
            peak_instr[name] = max(peak_instr.get(name, 0), used)
        return ok, r, had

    if rep.errors():
        return finish(rep, stub, logs, peak_instr, a.json, ran=False)

    entry = open(os.path.join(pack, man["main"]), encoding="utf-8").read()
    events, t_end = schedule(a.steps)
    sessions = 0

    def start():
        nonlocal sessions
        sessions += 1
        ok, err = stub.new_session(entry, man["main"])
        if not ok:
            rep.add("error", "LOAD", "entry script failed: %s" % err)
            return False
        ok, r, _ = call("game_start", rt.table_from({"is_a2a": False, "language": a.language}))
        if not ok:
            rep.add("error", "HOOK", "game_start raised (the robot ends the game): %s" % r)
            return False
        return True

    def end_session(reason):
        ok, r, _ = call("game_end")
        if not ok:
            rep.add("error", "HOOK", "game_end raised: %s" % r)
        stub.finish_report()
        rep.add("info", "SESSION", "session %d ended: %s" % (sessions, reason))

    running = start()
    now, i = 0, 0
    held = {}   # action -> [press time, next REPEAT time]: the body board repeats a held button
    while now <= t_end:
        while i < len(events) and events[i][0] <= now:
            _, kind, arg = events[i]
            i += 1
            if kind == "restart":
                if running:
                    end_session("restart")
                running = start()
                continue
            if not running:
                continue
            if kind in ("down", "up"):
                action = stub.button_action("button:" + arg)
                if action is None:
                    rep.add("warn", "INPUT", "no manifest action is bound to button:%s" % arg)
                    continue
                if kind == "down":
                    held[action] = [now, now + rep_delay]
                    hold = 0
                else:
                    hold = now - held.pop(action, [now])[0]
                stub.press(action, kind == "down", hold)
                ok, r, _ = call("on_input", action, 0 if kind == "down" else 1, hold)
                if not ok:
                    rep.add("error", "HOOK", "on_input raised (the robot ends the game): %s" % r)
                    running = False
                    end_session("error")
            elif kind == "voice":
                if not stub.voice_listening():
                    rep.add("warn", "VOICE", "voice:%s at %d ms but no voice session is listening: the robot hears nothing; "
                            "call Voice.set_keywords from on_tick first" % (arg, now))
                    continue
                ev = rt.table_from({"type": "VOICE_COMMAND", "data": {"keyword": arg}}, recursive=True)
                ok, r, had = call("on_voice_event", ev)
                if not had:
                    rep.add("warn", "VOICE", "voice step but the game defines no on_voice_event")
                elif not ok:
                    rep.add("error", "HOOK", "on_voice_event raised (session still ends end=err): %s" % r)
            elif kind == "home":
                ok, r, had = call("on_home")
                if not ok:
                    rep.add("error", "HOOK", "on_home raised: %s" % r)
                # Any truthy return keeps the game running (Lua truthiness: only nil and false are falsy).
                if not (had and ok and r is not None and r is not False):
                    running = False
                    end_session("home")
        if running:
            for action, h in list(held.items()):
                while running and now >= h[1]:
                    hold = h[1] - h[0]
                    h[1] += rep_rate
                    stub.repeat_event(action, hold)
                    ok, r, _ = call("on_input", action, 2, hold)
                    if not ok:
                        rep.add("error", "HOOK", "on_input raised (the robot ends the game): %s" % r)
                        running = False
                        end_session("error")
        if running:
            for ev in stub.pop_voice().values():
                ok, r, _ = call("on_voice_event", ev)
                if not ok:
                    rep.add("error", "HOOK", "on_voice_event raised (session still ends end=err): %s" % r)
        if running:
            for ev in stub.pop_events().values():
                ok, r, _ = call("on_sound_end", ev[2], ev[3])
                if not ok:
                    rep.add("error", "HOOK", "on_sound_end raised (the robot ends the game): %s" % r)
                    running = False
                    end_session("error")
                    break
        if running:
            ok, r, _ = call("on_tick", dt_ms)
            if not ok:
                rep.add("error", "HOOK", "on_tick raised at %d ms (the robot ends the game): %s" % (now, r))
                running = False
                end_session("error")
            elif stub.state().exit is not None:
                running = False
                end_session("Engine.exit(%s)" % stub.state().exit)
            stub.clear_just()
        stub.advance(period_ms)
        now += period_ms
    if running:
        end_session("end of script")
    return finish(rep, stub, logs, peak_instr, a.json, ran=True)


def finish(rep, stub, logs, peak_instr, json_out, ran):
    st = stub.state() if ran else None
    if ran:
        pk = st.peak
        played = dict(st.played.items())
        fonts = sorted(st.font_seen.keys())
        print("peak: sprites %d · Text %d · font faces %d · sprite PSRAM %d KB · sounds played %s"
              % (pk.sprites, pk.texts, pk.fonts, pk.psram // 1024, played or "{}"))
        print("instructions per hook (peak, a cost hint, not time): " +
              ", ".join("%s %d" % kv for kv in sorted(peak_instr.items(), key=lambda kv: -kv[1])))
    for line in logs[-10:]:
        print("[lua] " + line)
    order = {"error": 0, "warn": 1, "info": 2}
    for kind, code, msg in sorted(rep.items, key=lambda i: order[i[0]]):
        print("%-5s %-13s %s" % (kind.upper(), code, msg))
    errs = rep.errors()
    print("\n%d error(s), %d warning(s)" % (len(errs), sum(1 for i in rep.items if i[0] == "warn")))
    if json_out:
        with open(json_out, "w", encoding="utf-8") as f:
            json.dump({"schema": "pika-smoke/1", "items": [{"kind": k, "code": c, "msg": m} for k, c, m in rep.items],
                       "peak_instructions": peak_instr, "log": logs}, f, indent=1)
    return 1 if errs else 0


if __name__ == "__main__":
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    sys.exit(main())
