# Vendored Lua 5.5.0 — bare-metal ESP32-S3 build.
# Excludes standalone tools: lua.c (REPL main), onelua.c (amalgam), ltests.c (test harness).
# LUA_USE_C89 is PUBLIC so every consumer (game_engine et al.) picks it up
# without re-declaring it, which suppresses POSIX/dlopen/readline automatically.

file(GLOB LUA_SRCS "*.c")
list(FILTER LUA_SRCS EXCLUDE REGEX ".*(lua|onelua|ltests)\\.c$")

idf_component_register(
    SRCS        ${LUA_SRCS}
    INCLUDE_DIRS "."
    REQUIRES
        esp_common
        freertos
        log
        esp_psram
)

# ANSI C89 mode: disables POSIX, dlopen, readline, popen/system.
#
# LUAI_MAXCCALLS caps nested C calls. Upstream's 200 assumes a desktop's
# multi-megabyte C stack; ldo.h warns the value "must be compatible with the size
# of the C stack", and on this target it is not. Measured (SD/games/test_stack):
# ~486 B of engine_task stack per nested level. The physical stack ran out near
# level 60 and a probe at 180 PANICKED the board instead of raising the catchable
# "C stack overflow" the limit exists to produce.
#
# 30 = CONFIG_GAME_ENGINE_TASK_STACK (24576) * 0.6 / 486, i.e. 30 levels ~14.6 KB
# + ~6.3 KB baseline = 85% of the stack. The 40% headroom covers what the linear
# model misses: the deepest LVGL invalidate path, luaL_traceback at the error
# site, and cJSON recursing over a server-sent voice payload. This keeps the
# invariant that a runaway pack ends the GAME, not the robot.
#
# Re-derive if TASK_STACK changes - the two are one budget (Kconfig says so too).
# Defined here rather than in ldo.h to keep the vendored tree pristine; ldo.h
# guards it with #if !defined.
target_compile_definitions(${COMPONENT_LIB} PUBLIC
    LUA_USE_C89
    LUAI_MAXCCALLS=30
)

# Suppress warnings from upstream vendored source (project policy: logged in
# docs/standards/misra-deviations.md).
set_source_files_properties(${LUA_SRCS} PROPERTIES
    COMPILE_FLAGS
    "-Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
-Wno-sign-compare -Wno-string-plus-int -Wno-implicit-fallthrough \
-Wno-type-limits -Wno-maybe-uninitialized -Wno-empty-body"
)
