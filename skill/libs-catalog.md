# Shipped Lua libraries (`libraries/` → `<game>/libs/`)

> **Load when** code calls `require`. Every function below was checked against the files in
> [`../libraries/`](../libraries/) (index: [libs.index.json](../libraries/libs.index.json)).
> **A function not listed here does not exist in the library.** A module not in this table:
> do not guess its API; ask the user.

## Rules

- **LIB-COPY** MUST copy the module **and its dependencies** into `<game>/libs/`, keeping sub-folders (`libs/math/easing.lua`) — `require` loads only `libs/<name>` from the pack ([api.md#sandbox](../docs/reference/api.md#sandbox)). Check: smoke.py reports a `require` whose file is missing.
- **LIB-REUSE** NEVER rewrite what a module already does (menus, tweens, easing) unless the user asks.
- **LIB-HANDLES** Modules that draw keep their handles in module or object fields (HANDLE-GC safe); keep the object they return referenced.

## Modules

| require | Depends on | Functions (exact) | Notes |
| --- | --- | --- | --- |
| `libs/fsm` | – | `fsm.new(initial)` → machine · `m:add(from, event, to)` (chainable) · `m:on(state, enter_fn, exit_fn)` (chainable) · `m:fire(event)` → bool · `m:get()` → state | `fire` returns `false` for an event with no transition; exit runs before enter |
| `libs/animator` | `libs/math/easing` | `animator.tween(target, from, to, duration_ms[, ease])` → tween · `tw:step(elapsed_ms)` · field `tw.done` | **Numeric tween**: writes the eased number to `target.value`; it moves nothing. Apply `target.value` yourself, floored. Pass a `Timer.millis()` difference, not `dt_ms`. `duration_ms` > 0 |
| `libs/ui` | – | `ui.selector(items[, opts])` → sel: `:next()` `:prev()` (clamped) `:index()` `:current()` → item, idx · `:render()` · `ui.confirm(question[, opts])` → c: `:toggle()` `:choice()` → bool · `:render()` | One shared `Text` at (4, 4), created on the first `render`, never destroyed by the module. `opts.format` (selector, default `"< %s (%d/%d) >"`), `opts.yes`/`opts.no` (confirm) |
| `libs/settings` | – | `settings.new(spec)` → menu · `menu:input(action, phase)` → bool (handled) · `menu:render()` · `menu:destroy()` | `spec.on_start(cfg)` required (`new` raises without it). Default actions `left`, `right`, **`fire`**. Labels are **images** under `spec.kit` (default `images/settings`): without them the rows show no text. Recipe: [recipes/settings-menu.md](recipes/settings-menu.md) |
| `libs/testkit` | – | `tk.expect(cond, msg)` · `tk.expect_eq(a, b, msg)` · `tk.reg_sync(name, fn)` · `tk.run_sync()` → passed, failed · `tk.reg_async(name, fn[, timeout_ms])` | `reg_async` only registers: no async runner |
| `libs/math/easing` | – | `linear` `quad_in` `quad_out` `quad_inout` `cubic_in` `cubic_out` `bounce_out` (each `f(t)`, t in 0..1) | |
| `libs/math/lerp` | – | `lerp(a, b, t)` · `clamp(v, lo, hi)` · `map(v, in_lo, in_hi, out_lo, out_hi)` | Results are floats: floor before passing coordinates |
| `libs/math/vec2` | – | `vec2.new(x, y)` → v · `v:add(o)` `v:sub(o)` `v:scale(k)` (each a **new** vector) · `v:len()` · `v:dot(o)` | Allocates per operation: avoid in per-frame loops |
| `libs/util/str` | – | `split(str, sep)` · `starts_with(str, prefix)` · `ends_with(str, suffix)` · `trim(str)` | `sep` goes inside a `[^...]` pattern class; empty pieces are dropped |
| `libs/util/tbl` | – | `size(t)` · `contains(arr, v)` · `copy(t)` (shallow) · `keys(t)` | |

## Example

```lua
local fsm = require("libs/fsm")
local flow = fsm.new("title")
  :add("title", "start", "play")
  :add("play", "lose", "over")
  :add("over", "start", "play")
flow:on("play", function() print("enter play") end)

function on_input(action, phase)
  if action == "confirm" and phase == Input.PRESS then flow:fire("start") end
end
```

```lua
local animator = require("libs/animator")
local easing = require("libs/math/easing")
local box = { value = 0 }
local tw = animator.tween(box, 0, 200, 600, easing.quad_out)
local last_ms

function on_tick()
  local now = Timer.millis()
  tw:step(now - (last_ms or now))
  last_ms = now
  -- spr:set_pos(math.floor(box.value + 0.5), 100)
end
```
