# `libraries/`: standard Lua modules

Original copies of the shared Lua modules for Pika games. A game ships its own copy in
`<game>/libs/` (Pika Studio's game tooling copies a module with its dependencies), so every pack
is self-contained. Inside a game, load them with the `libs/` prefix. Exact function lists:
[../skill/libs-catalog.md](../skill/libs-catalog.md). Machine-readable list: [libs.index.json](libs.index.json).

```text
libs/
├── fsm.lua            # require("libs/fsm")        finite state machine
├── animator.lua       # require("libs/animator")   numeric tween: writes the eased value to target.value
├── ui.lua             # require("libs/ui")         one-line selector + yes/no confirm (one Text)
├── settings.lua       # require("libs/settings")   pre-game settings screen, labels are images, on_start(cfg)
├── testkit.lua        # require("libs/testkit")    in-game test harness (sync tests)
├── math/              # require("libs/math/<mod>") easing, lerp (lerp, clamp, map), vec2
└── util/              # require("libs/util/<mod>") str, tbl
```

## Conventions

- Each module returns a table `M`; no global side effects.
- Modules use only the sandbox and engine globals ([api.md#sandbox](../docs/reference/api.md#sandbox)).
- Nested names work: `require("libs/math/vec2")` loads `libs/math/vec2.lua`.
- UI modules use as few `Text` handles as possible; `ui.lua` keeps one shared line.
