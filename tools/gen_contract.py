"""Generate the SDK contract from the Pika Engine firmware sources.

Writes:
  contract/constraints.json      limits (C macros, effective sdkconfig, Lua build), derived values, facts
  contract/api.json              every Lua global, function, method, constant and hook the engine registers
  kit/pika-constraints.js        constraints for the browser kit (file:// cannot fetch JSON)
  docs/reference/api.md          full API reference    | rendered by tools/render_docs.py from
  docs/reference/known-issues.md known issues, PC gaps | contract/semantics.json (hand-written
  skill/api-contract.md          AI cheat sheet        | behaviour), every {{key}} filled from
  skill/constraints.md           AI limits page        | constraints.json

  docs/reference/manifest.md     } rendered from contract/pages/*.md
  docs/reference/telemetry.md    }
  lua-5.5.0/CMakeLists.txt, luaconf.h   copied from the firmware's Lua build

semantics.json must describe exactly the names in api.json: a missing or extra
entry, or an unknown {{key}}, fails the run.

Numbers are read from code, never copied from docs: hand-copied limits drifted
between doc sets before (sound cooldown 80 vs 150 ms, a "32 sprite" cap that
does not exist, alias overflow "truncated" vs "rejected").

usage: python tools/gen_contract.py [--firmware <pika-firmware-idf>] [--check]
  --firmware  firmware checkout (default: the folder above this SDK, if it has head_esp32/)
  --check     exit 1 if any generated file is stale
"""
import argparse
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import render_docs  # noqa: E402

SDK = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))

# (key, header under game_engine/src, macro)
MACROS = [
    ("text_slots", "core/engine_internal.h", "GAME_TEXT_SLOTS"),
    ("line_slots", "core/engine_internal.h", "GAME_LINE_SLOTS"),
    ("line_width_max", "core/engine_internal.h", "GAME_LINE_WIDTH_MAX"),
    ("transform_max_px", "core/engine_internal.h", "GAME_TRANSFORM_MAX_PX"),
    ("img_max_w", "core/engine_internal.h", "GAME_IMG_MAX_W"),
    ("img_max_h", "core/engine_internal.h", "GAME_IMG_MAX_H"),
    ("png_max_file_bytes", "core/engine_internal.h", "GAME_PNG_MAX_FILE_BYTES"),
    ("anim_max_file_bytes", "core/engine_internal.h", "GAME_ANIM_MAX_FILE_BYTES"),
    ("anim_min_frame_ms", "core/engine_internal.h", "GAME_ANIM_MIN_FRAME_MS"),
    ("font_max_file_bytes", "core/engine_internal.h", "GAME_FONT_MAX_FILE_BYTES"),
    ("font_slots", "core/engine_internal.h", "GAME_FONT_SLOTS"),
    ("font_px_min", "core/engine_internal.h", "GAME_FONT_PX_MIN"),
    ("font_px_max", "core/engine_internal.h", "GAME_FONT_PX_MAX"),
    ("font_px_default", "core/engine_internal.h", "GAME_FONT_PX_DEFAULT"),
    ("manifest_max_bytes", "core/engine_internal.h", "GAME_MANIFEST_MAX_BYTES"),
    ("sandbox_path_max", "bindings/bindings_util.h", "GAME_SANDBOX_PATH_MAX"),
    ("input_actions_max", "subsystems/input/input_internal.h", "GAME_MAX_ACTIONS"),
    ("input_action_name_max", "subsystems/input/input_internal.h", "GAME_ACTION_NAME_MAX"),
    ("input_ring_slots", "subsystems/input/input_internal.h", "GAME_INPUT_RING_SZ"),
    ("sound_aliases_max", "subsystems/sound/sound_internal.h", "GAME_MAX_SOUNDS"),
    ("sound_alias_len_max", "subsystems/sound/sound_internal.h", "GAME_SOUND_ALIAS_MAX"),
    ("sound_path_len_max", "subsystems/sound/sound_internal.h", "GAME_SOUND_PATH_MAX"),
    ("sound_url_len_max", "subsystems/sound/sound_internal.h", "GAME_SOUND_URL_MAX"),
    ("sound_abs_path_max", "subsystems/sound/sound.c", "GAME_SOUND_ABS_PATH_MAX"),
    ("servo_aliases_max", "subsystems/servo/servo_internal.h", "GAME_MAX_SERVO_ALIASES"),
    ("pose_aliases_max", "subsystems/servo/servo_internal.h", "GAME_MAX_POSE_ALIASES"),
    ("led_blink_min_ms", "subsystems/led/led_internal.h", "GAME_LED_BLINK_PERIOD_MIN_MS"),
    ("led_blink_max_ms", "subsystems/led/led_internal.h", "GAME_LED_BLINK_PERIOD_MAX_MS"),
    ("led_pulse_min_ms", "subsystems/led/led_internal.h", "GAME_LED_PULSE_DURATION_MIN_MS"),
    ("led_pulse_max_ms", "subsystems/led/led_internal.h", "GAME_LED_PULSE_DURATION_MAX_MS"),
    ("voice_keywords_max", "bindings/bind_voice.c", "VOICE_MAX_KEYWORDS"),
    ("voice_start_json_max_bytes", "bindings/bind_voice.c", "VOICE_START_JSON_MAX_BYTES"),
    ("voice_table_max_depth", "bindings/bind_voice.c", "VOICE_TABLE_MAX_DEPTH"),
    ("voice_table_max_keys", "bindings/bind_voice.c", "VOICE_TABLE_MAX_KEYS"),
    ("voice_event_max_depth", "bindings/bindings.h", "GAME_VOICE_EVENT_MAX_DEPTH"),
    ("voice_event_max_nodes", "bindings/bindings.h", "GAME_VOICE_EVENT_MAX_NODES"),
    ("start_params_max_len", "core/engine_internal.h", "GAME_PARAMS_JSON_FIELD_LEN"),
    ("start_params_max_nodes", "bindings/bindings.h", "GAME_START_PARAMS_MAX_NODES"),
    ("report_event_max_len", "bindings/bind_engine.c", "REPORT_EVENT_MAX_LEN"),
    ("line_pool_max_bytes", "render/lvgl_renderer.c", "GAME_LINE_POOL_MAX_BYTES"),
    ("game_id_max_len", "core/engine_internal.h", "GAME_ID_FIELD_LEN"),
    ("manifest_name_max_len", "core/engine_internal.h", "GAME_DISPLAY_NAME_FIELD_LEN"),
    ("manifest_main_max_len", "core/engine_internal.h", "GAME_ENTRY_SCRIPT_FIELD_LEN"),
]

# (key, file under the firmware root, macro): limits enforced outside the engine.
FW_MACROS = [
    ("icon_max_file_bytes", "head_esp32/main/src/middleware/ui_custom/ui_menu.cpp", "GAME_COVER_MAX_FILE"),
    ("icon_max_px", "head_esp32/main/src/middleware/ui_custom/ui_menu.cpp", "GRID_ICON_MAX"),
    ("icon_cell_px", "head_esp32/main/src/middleware/ui_custom/ui_menu.cpp", "GRID_ICON_PX"),
]

# Button auto-repeat is timed by the body board and forwarded as Input.REPEAT events.
BUTTON_H = os.path.join("back_esp32", "main", "src", "driver", "button", "button.h")
BUTTON_CONSTS = [("button_repeat_delay_ms", "GAME_REPEAT_DELAY_MS"),
                 ("button_repeat_rate_ms", "GAME_REPEAT_RATE_MS")]
# Telemetry cadence and thresholds: (key, file under game_engine/src, regex with one number, multiplier).
TELEMETRY = [
    ("telemetry_running_s", "core/engine_core.c", r"#define\s+GAME_RUNNING_LOG_US\s+GAME_S_TO_US\((\d+)\)", 1),
    ("telemetry_running_fps_mult", "core/engine_core.c", r"#define\s+GAME_RUNNING_LOG_FRAMES\s+.*\*\s*(\d+)u", 1),
    ("telemetry_warn_s", "core/engine_core.c", r"#define\s+ENGINE_WARN_WINDOW_US\s+GAME_S_TO_US\((\d+)\)", 1),
    ("telemetry_slow_frame_us", "core/engine_core.c", r"slow_frame_us\s*=\s*(\d+)", 1),
    ("telemetry_heap_low_kib", "core/engine_core.c", r"#define\s+GAME_HEAP_INT_LOW_BYTES\s+\((\d+)u\s*\*\s*1024u\)", 1),
    ("telemetry_load_stall_s", "core/engine_core.c", r"#define\s+ENGINE_START_PENDING_MAX_US\s+(\d+)000000LL", 1),
    ("lua_near_budget_pct", "core/lua_vm.c", r"#define\s+LUA_VM_NEAR_BUDGET_BYTES\s+\(\(LUA_VM_MEM_BUDGET_BYTES\s*/\s*10u\)\s*\*\s*(\d+)u\)", 10),
]

# HOME long-press force-exits a running game (body board driver).
BUTTON_CPP = os.path.join("back_esp32", "main", "src", "driver", "button", "button.cpp")
# Build flags of the vendored Lua interpreter.
LUA_CMAKE = os.path.join("head_esp32", "components", "lua-5.5.0", "CMakeLists.txt")
LUA_MIRROR = ["CMakeLists.txt", "luaconf.h"]

# (key, sdkconfig symbol, converter)
KCONFIG = [
    ("target_fps", "CONFIG_GAME_ENGINE_TARGET_FPS", int),
    ("lua_heap_kb", "CONFIG_GAME_ENGINE_LUA_HEAP_KB", int),
    ("hook_watchdog_ms", "CONFIG_GAME_ENGINE_LUA_WATCHDOG_US", lambda v: int(v) // 1000),
    ("sound_cooldown_ms", "CONFIG_GAME_SOUND_PLAY_COOLDOWN_MS", int),
    ("watchdog_hook_count", "CONFIG_GAME_ENGINE_LUA_WATCHDOG_HOOK_COUNT", int),
    ("stall_detect_sec", "CONFIG_GAME_ENGINE_STALL_DETECT_SEC", int),
    ("sound_finish_ring", "CONFIG_GAME_SOUND_FINISH_RING_SIZE", int),
    ("freertos_hz", "CONFIG_FREERTOS_HZ", int),
    ("games_root", "CONFIG_GAME_ENGINE_GAMES_ROOT", str),
]

# Behaviour that is not a single macro. Each value names what proves it.
FACTS = {
    "screen": [480, 320],
    "input_buttons": ["button:left", "button:enter", "button:right"],
    "string_limits_include_nul": "alias/path/action caps count the terminating NUL: usable length is cap - 1",
    "sound_alias_overflow": "reject_pack (sound.c install_entry -> goto bad)",
    "sound_path_missing": "reject_pack (sound.c preload stat at load)",
    "sound_channels": "one; a new play preempts the current sound (on_sound_end REASON_PREEMPTED)",
    "anim_concurrent": 1,
    "sprite_cap": "none; bounded by free PSRAM: PNG with alpha w*h*3 bytes (RGB565 + A8), PNG without alpha and raw .rgb565 w*h*2",
    "transform_rule": "set_scale/set_rotation need BOTH w and h <= transform_max_px, else refused; set_pivot is not gated",
    "sprite_initially_hidden": "a new sprite stays hidden until its first set_pos or set_visible (lvgl_renderer.c sprite_apply_hidden)",
    "font_face": "a face is a (path, size) pair; faces referenced by a live Text cannot be evicted",
    "z_order": "creation order; set_z is a child index shared with Text",
    "text_wrap": "none; no text width query",
    "tick_dt_ms": "on_tick receives the nominal frame time; use Timer.millis() for real elapsed time",
    "persistence": "none; Lua cannot write files. Use Ranking.report to keep scores",
    "tts": "none; every spoken line is a recorded audio file",
    "blend_filter_gradient": "none at runtime; bake into the image",
    "home_hook": "on_home() returning a truthy value keeps the game running; nil, false, an error or no hook exits",
    "frame_hooks_bound_once": "on_tick and on_input are resolved once after the entry script's top level (lua_vm_bind_frame_hooks); reassigning them later has no effect",
    "voice_after_game_start": "the body board activates the voice session on GAME_STARTED, sent after game_start returns, and drops voice commands queued before it (game_voice_activate)",
}

# Registered for firmware-internal hosts; documented but not for game code.
INTERNAL = {"on_pack_cmd": "host command channel of built-in packs",
            "Engine.stack_hwm": "firmware stack sizing probe"}
A2A_ONLY = {"Engine.report_result": "talk-flow (A2A) sessions: reports the outcome string to the server"}

# Global -> factories; everything else in the same table is a method of the object.
FACTORIES = {"Sprite": {"new", "image", "solid"}, "Anim": {"new"}}
HOOK_RE = re.compile(r'"(game_start|game_end|on_[a-z_]+)"')
_NUM = re.compile(r"^\(?\s*(\d+)u?\s*(?:\*\s*(\d+)u?\s*)?(?:\*\s*(\d+)u?\s*)?\)?")


def eval_macro(expr):
    m = _NUM.match(expr.strip())
    if not m:
        raise ValueError("unsupported macro expression: " + expr)
    val = 1
    for g in m.groups():
        if g:
            val *= int(g)
    return val


def read_macro(src, rel, name):
    with open(os.path.join(src, rel), encoding="utf-8", errors="replace") as f:
        for line in f:
            m = re.match(r"\s*#define\s+" + name + r"\s+(.+?)(/\*.*)?$", line)
            if m:
                return eval_macro(m.group(1))
    raise KeyError(name + " not found in " + rel)


def read_sdkconfig(path):
    vals = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            m = re.match(r"(CONFIG_[A-Z0-9_]+)=(.*)$", line.strip())
            if m:
                vals[m.group(1)] = m.group(2).strip('"')
    return vals


def parse_bindings(src):
    """luaL_Reg tables -> {global: {functions, methods, constants}}."""
    bdir = os.path.join(src, "bindings")
    api = {}
    for fn in sorted(os.listdir(bdir)):
        if not fn.endswith(".c"):
            continue
        text = open(os.path.join(bdir, fn), encoding="utf-8", errors="replace").read()
        tables = {m.group(1): re.findall(r'\{\s*"([a-z_]+)"\s*,\s*l_\w+\s*\}', m.group(2))
                  for m in re.finditer(r"luaL_Reg\s+(\w+)\s*\[\]\s*=\s*\{(.*?)\n\};", text, re.S)}
        consts = re.findall(r'\{\s*"([A-Z][A-Z0-9_]+)"\s*,\s*[A-Z][A-Z0-9_]+\s*\}', text)
        # newlib(table) ... setglobal("X") pairs, in file order.
        for m in re.finditer(r'luaL_newlib\(L,\s*(\w+)\);(?:(?!luaL_newlib).)*?lua_setglobal\(L,\s*"(\w+)"\)', text, re.S):
            table, glob = m.group(1), m.group(2)
            g = api.setdefault(glob, {"functions": [], "methods": [], "constants": []})
            names = tables.get(table, [])
            fac = FACTORIES.get(glob)
            if fac:
                g["functions"] += [n for n in names if n in fac]
                g["methods"] += [n for n in names if n not in fac]
            else:
                g["functions"] += names
            method_table = table.replace("_funcs", "_methods")
            if method_table in tables and method_table != table:
                g["methods"] += tables[method_table]
            g["constants"] += consts
            consts = []
        if 'lua_setglobal(L, "print")' in text:
            api.setdefault("print", {"functions": [], "methods": [], "constants": []})
    for g in api.values():
        for k in g:
            g[k] = sorted(set(g[k]))
    return api


def parse_hooks(src):
    hooks = set()
    core = os.path.join(src, "core")
    for fn in os.listdir(core):
        if fn.endswith(".c"):
            hooks |= set(HOOK_RE.findall(open(os.path.join(core, fn), encoding="utf-8", errors="replace").read()))
    return sorted(hooks)


def read_text(fw, rel):
    with open(os.path.join(fw, rel), encoding="utf-8", errors="replace") as f:
        return f.read()


def derive(lim):
    """Values computed from the raw limits, each with the formula that produces it."""
    dt = 1000 // lim["target_fps"]
    period = (dt * lim["freertos_hz"] // 1000) * 1000 // lim["freertos_hz"]
    d = {
        "dt_ms": (dt, "1000 // target_fps: the value on_tick receives"),
        "freertos_tick_ms": (1000 // lim["freertos_hz"], "1000 // freertos_hz"),
        "tick_period_ms": (period, "pdMS_TO_TICKS(dt_ms): dt_ms rounded down to whole RTOS ticks"),
        "tick_hz_max": (1000 // period, "1000 // tick_period_ms"),
        "screen_w": (FACTS["screen"][0], "facts.screen"),
        "screen_h": (FACTS["screen"][1], "facts.screen"),
        "x2_max": (2 * lim["img_max_w"], "Shape x range is -img_max_w..2*img_max_w"),
        "y2_max": (2 * lim["img_max_h"], "Shape y range is -img_max_h..2*img_max_h"),
        "png_max_file_mib": (lim["png_max_file_bytes"] // 1048576, "png_max_file_bytes in MiB"),
        "anim_max_file_mib": (lim["anim_max_file_bytes"] // 1048576, "anim_max_file_bytes in MiB"),
        "font_max_file_kib": (lim["font_max_file_bytes"] // 1024, "font_max_file_bytes in KiB"),
        "manifest_max_kib": (lim["manifest_max_bytes"] // 1024, "manifest_max_bytes in KiB"),
        "line_pool_kib": (lim["line_pool_max_bytes"] // 1024, "line_pool_max_bytes in KiB"),
        "sandbox_rel_path_budget": (lim["sandbox_path_max"] - 1 - len(lim["games_root"]) - 2,
                                    "sandbox_path_max - NUL - len(games_root) - 2 slashes; a relative path "
                                    "may use this many bytes minus len(game_id)"),
        "sound_alias_chars": (lim["sound_alias_len_max"] - 1, "cap minus NUL"),
        "sound_path_chars": (lim["sound_path_len_max"] - 1, "cap minus NUL"),
        "sound_url_chars": (lim["sound_url_len_max"] - 1, "cap minus NUL"),
        "pc_games_root_chars": (lim["sound_abs_path_max"] - 1 - (lim["game_id_max_len"] - 1)
                                - (lim["sound_path_len_max"] - 1) - 2,
                                "sound_abs_path_max - NUL - longest game id - longest sound path - 2 slashes: "
                                "the longest games folder path that fits every pack on a PC"),
        "input_action_name_chars": (lim["input_action_name_max"] - 1, "cap minus NUL"),
        "report_event_max_bytes": (lim["report_event_max_len"] - 1, "cap minus NUL"),
        "start_params_max_bytes": (lim["start_params_max_len"] - 1, "cap minus NUL"),
        "voice_body_max_bytes": (lim["voice_start_json_max_bytes"] - 1, "cap minus NUL"),
        "game_id_chars": (lim["game_id_max_len"] - 1, "cap minus NUL"),
        "manifest_name_chars": (lim["manifest_name_max_len"] - 1, "cap minus NUL; longer is cut"),
        "manifest_main_chars": (lim["manifest_main_max_len"] - 1, "cap minus NUL; longer is cut, then fails to load"),
        "icon_max_file_mib": (lim["icon_max_file_bytes"] // 1048576, "icon_max_file_bytes in MiB"),
        "telemetry_running_frames": (lim["target_fps"] * lim["telemetry_running_fps_mult"],
                                     "target_fps * telemetry_running_fps_mult"),
        "telemetry_slow_frame_ms": (lim["telemetry_slow_frame_us"] // 1000, "telemetry_slow_frame_us in ms"),
        "lua_heap_bytes": (lim["lua_heap_kb"] * 1024, "lua_heap_kb * 1024"),
    }
    return {k: v for k, (v, _) in d.items()}, {k: f for k, (_, f) in d.items()}


def build(fw):
    src = os.path.join(fw, "head_esp32", "components", "game_engine", "src")
    limits = {k: read_macro(src, rel, name) for k, rel, name in MACROS}
    limits.update({k: read_macro(fw, rel, name) for k, rel, name in FW_MACROS})
    for key, rel, rx, mult in TELEMETRY:
        m = re.search(rx, read_text(src, rel))
        if not m:
            raise KeyError(key + ": pattern not found in " + rel)
        limits[key] = int(m.group(1)) * mult
    btn = read_text(fw, BUTTON_H)
    for key, name in BUTTON_CONSTS:
        m = re.search(r"constexpr\s+\w+\s+" + name + r"\s*=\s*(\d+)", btn)
        if not m:
            raise KeyError(name + " not found in " + BUTTON_H)
        limits[key] = int(m.group(1))
    m = re.search(r"#define\s+BUTTON_LONG_PRESS_TIME\s+(\d+)", read_text(fw, BUTTON_CPP))
    if not m:
        raise KeyError("BUTTON_LONG_PRESS_TIME not found in " + BUTTON_CPP)
    limits["home_force_exit_ms"] = int(m.group(1))
    lua = read_text(fw, LUA_CMAKE)
    m = re.search(r"LUAI_MAXCCALLS=(\d+)", lua)
    if not m or "LUA_USE_C89" not in lua:
        raise KeyError("LUAI_MAXCCALLS / LUA_USE_C89 not found in " + LUA_CMAKE)
    limits["lua_maxccalls"] = int(m.group(1))
    limits["lua_int_bits"] = 32  # LUA_USE_C89: lua_Integer is C 'long', 32-bit on Xtensa
    cfg = read_sdkconfig(os.path.join(fw, "head_esp32", "sdkconfig"))
    for k, sym, conv in KCONFIG:
        if sym not in cfg:
            raise KeyError(sym + " missing from head_esp32/sdkconfig")
        limits[k] = conv(cfg[sym])
    derived, formulas = derive(limits)
    slash = lambda p: p.replace(os.sep, "/")  # noqa: E731
    button_src = {k: slash(BUTTON_H) + ":" + n for k, n in BUTTON_CONSTS}
    button_src["home_force_exit_ms"] = slash(BUTTON_CPP) + ":BUTTON_LONG_PRESS_TIME"
    constraints = {"schema": "pika-contract-constraints/1", "limits": limits, "derived": derived, "facts": FACTS,
                   "source": {"macros": dict({k: "game_engine/src/" + rel + ":" + n for k, rel, n in MACROS},
                                             **{k: rel + ":" + n for k, rel, n in FW_MACROS}),
                              "telemetry": {k: "game_engine/src/" + rel for k, rel, _, _ in TELEMETRY},
                              "sdkconfig": {k: s for k, s, _ in KCONFIG},
                              "button": button_src,
                              "lua_build": {"lua_maxccalls": slash(LUA_CMAKE) + ":LUAI_MAXCCALLS",
                                            "lua_int_bits": slash(LUA_CMAKE) + ":LUA_USE_C89"},
                              "derived": formulas}}
    api = {"schema": "pika-contract-api/1",
           "note": "Generated from the engine's luaL_Reg tables. A name missing here does not exist on the robot.",
           "globals": parse_bindings(src), "hooks": parse_hooks(src),
           "internal": INTERNAL, "a2a_only": A2A_ONLY}
    return constraints, api


def outputs(fw):
    constraints, api = build(fw)
    cj = json.dumps(constraints, indent=1, ensure_ascii=False) + "\n"
    aj = json.dumps(api, indent=1, ensure_ascii=False) + "\n"
    js = ("/* GENERATED by tools/gen_contract.py from the Pika Engine firmware. Do not edit. */\n"
          "window.PIKA_CONSTRAINTS = " + cj.rstrip("\n") + ";\n"
          "window.PIKA_API = " + aj.rstrip("\n") + ";\n")
    out = {os.path.join(SDK, "contract", "constraints.json"): cj,
           os.path.join(SDK, "contract", "api.json"): aj,
           os.path.join(SDK, "kit", "pika-constraints.js"): js}
    # The SDK's Lua copy must build exactly like the robot's (LUA_USE_C89, LUAI_MAXCCALLS).
    for name in LUA_MIRROR:
        out[os.path.join(SDK, "lua-5.5.0", name)] = read_text(fw, os.path.join(os.path.dirname(LUA_CMAKE), name))
    with open(os.path.join(SDK, "contract", "semantics.json"), encoding="utf-8") as f:
        sem = json.load(f)
    for rel, text in render_docs.render_all(sem, api, constraints).items():
        out[os.path.join(SDK, rel)] = text
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--firmware", default=os.path.abspath(os.path.join(SDK, "..")))
    ap.add_argument("--check", action="store_true")
    a = ap.parse_args()
    if not os.path.isdir(os.path.join(a.firmware, "head_esp32")):
        print("firmware checkout not found at " + a.firmware + " (pass --firmware)")
        return 2
    files = outputs(a.firmware)
    if a.check:
        stale = []
        for path, text in files.items():
            try:
                cur = open(path, encoding="utf-8").read()
            except FileNotFoundError:
                cur = ""
            if cur != text:
                stale.append(os.path.relpath(path, SDK))
        print(("stale: " + ", ".join(stale) + " (run tools/gen_contract.py)") if stale else "contract up to date")
        return 1 if stale else 0
    for path, text in files.items():
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
        print("wrote " + os.path.relpath(path, SDK))
    return 0


if __name__ == "__main__":
    sys.exit(main())
