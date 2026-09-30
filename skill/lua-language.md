# Lua on the Pika Engine

> **Load always** when writing or reviewing Lua for a pack. The engine embeds Lua 5.5.0 with a
> robot-specific build; AI assistants tend to write Lua 5.1 / LuaJIT / Luau habits. This page
> lists what differs. Engine API: [api-contract.md](api-contract.md). Sandbox:
> [api.md#sandbox](../docs/reference/api.md#sandbox).

## Rules

- **LUA-HOOKS** MUST define `on_tick` and `on_input` at the top level of the entry script — they are bound once, right after the top level runs. Check: `grep -n "^function on_tick\|^function on_input" scripts/main.lua` finds both at column 0.
- **LUA-REBIND** NEVER assign a hook after the top level (`on_tick = play_tick` in `game_start` or a scene change) — silently ignored ([api.md#hooks](../docs/reference/api.md#hooks)). Check: `grep -n "on_tick *=\|on_input *=" scripts/*.lua` is empty.
- **LUA-HANDLES** MUST keep every `Sprite`/`Text`/`Shape`/`Anim` handle referenced for as long as it should exist — an unreferenced handle is destroyed at the next garbage collection ([api.md#conventions](../docs/reference/api.md#conventions)). Check: no factory result is discarded or kept only in a local that goes out of scope.
- **LUA-INT32** MUST keep integers below 2^31 — integers are 32-bit on the robot and wrap; smoke.py (lupa) and Pika Studio use 64-bit (PC-INT). Check: no products of millisecond values; compare `Timer.millis()` differences.
- **LUA-CCALLS** NEVER nest more than (`lua_maxccalls` = 30) C calls, or chain about 20 `..` in one expression — both raise `C stack overflow`, the second at load time (PC-CCALLS). smoke.py runs with desktop limits. Check: smoke.py's long-`..` warning; use `table.concat`.
- **LUA-COORD** MUST pass integer coordinates — a fractional number raises `number has no integer representation` ([api.md#conventions](../docs/reference/api.md#conventions)). Check: every computed `x`, `y` goes through `math.floor(v + 0.5)` or `//`.
- **LUA-VOICE** NEVER call `Voice.*` from the top level or `game_start` — dropped ([api.md#voice](../docs/reference/api.md#voice)). Check: smoke.py flags it.
- **LUA-LOCALS** MUST declare state `local`; only hooks are globals. Check: `grep -n "^[a-z_]* *=" scripts/*.lua` is empty.

## Lua 5.5 rules that break old habits

**Loop control variables are read-only.** Assigning one is a compile error: the file does not
load (`attempt to assign to const variable 'i'`) [fw: head_esp32/components/lua-5.5.0/lparser.c:320].

| Loop | Read-only | Assignable |
| --- | --- | --- |
| `for i = 1, n do` | `i` | – |
| `for k, v in pairs(t) do` | `k` (the **first** variable only) | `v` and later variables |

```lua
-- WRONG: does not compile
-- for i = 1, #list do if list[i] == "skip" then i = i + 1 end end

-- RIGHT: a while loop owns its counter
local i = 1
while i <= #list do
  if list[i] == "skip" then i = i + 1 end
  i = i + 1
end
```

**`global` is not a reserved word** in the robot build (`LUA_COMPAT_GLOBAL`
[fw: head_esp32/components/lua-5.5.0/luaconf.h:342]), but a statement that starts with
`global <name>`, `global function` or `global *` is still parsed as a Lua 5.5 global declaration
[fw: head_esp32/components/lua-5.5.0/lparser.c:2114-2125]. Do not name anything `global`.

## What the sandbox provides

Base (without `load`, `loadfile`, `dofile`), `string`, `table`, `math`, `utf8`; no `io`, `os`,
`package`, `debug`, `coroutine` ([api.md#sandbox](../docs/reference/api.md#sandbox)). `require`
takes only `libs/<name>`; `print` writes to the robot log. `pika` is an empty table.

Reading an unknown field of an engine global gives `nil`; calling it raises. Guard optional
features with `if Led.set then ... end`, never with `pcall` around a call that does not exist.

## Numbers

- `/` always returns a float; `//` floors (integer when both operands are integers);
  `math.floor` returns an integer when it fits.
- `math.random(m, n)` works. Seed once in `game_start` with `math.randomseed(Timer.millis())`; for
  testable rules pass a seed in ([templates/structured-game/](templates/structured-game/)).

## Strings and UTF-8

`#str` counts **bytes**; accented letters take 2–3 bytes, CJK 3. `str:upper()`/`str:lower()`
change ASCII only: store display strings in final case.

```lua
local word = "ĐIỂM"
print(#word, utf8.len(word))   -- 7  4: use utf8.len for centring and line length
```

Build strings when data changes, not every frame (each `..` allocates). More:
[recipes/localized-text.md](recipes/localized-text.md).

## Modules

`require("libs/<name>")` loads `<game>/libs/<name>.lua` once per session; nested names such as
`libs/math/easing` work. A module returns a table:

```lua
-- libs/rules.lua
local M = {}
function M.add(a, b) return a + b end
return M
```

Shipped modules: [libs-catalog.md](libs-catalog.md).

## Scope and file order

- A local function must be declared before code that calls it. For mutual references declare
  the name first (`local refresh` … `refresh = function() ... end`).
- Hooks go at the **bottom** of `main.lua`, after the helpers they call, and at the top level.

## PC tools vs the robot build

| Topic | Robot | `tools/smoke.py` (lupa) and Pika Studio |
| --- | --- | --- |
| Integer width | 32-bit | 64-bit (PC-INT) |
| Nested C calls | (`lua_maxccalls` = 30) | desktop default (PC-CCALLS) |
| Speed | robot CPU, SD card | desktop (PC-SPEED) |

The source copy in [`../lua-5.5.0/`](../lua-5.5.0/) builds like the robot: `tools/gen_contract.py`
keeps its `CMakeLists.txt` and `luaconf.h` identical to the firmware's (`LUA_USE_C89`,
`LUAI_MAXCCALLS`) [fw: head_esp32/components/lua-5.5.0/CMakeLists.txt:39]. smoke.py does not
build it: it runs lupa, which keeps the desktop limits.
