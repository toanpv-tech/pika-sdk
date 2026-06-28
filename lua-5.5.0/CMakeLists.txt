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
target_compile_definitions(${COMPONENT_LIB} PUBLIC
    LUA_USE_C89
)

# Suppress warnings from upstream vendored source (project policy: logged in
# docs/standards/misra-deviations.md).
set_source_files_properties(${LUA_SRCS} PROPERTIES
    COMPILE_FLAGS
    "-Wno-unused-function -Wno-unused-variable -Wno-unused-parameter \
-Wno-sign-compare -Wno-string-plus-int -Wno-implicit-fallthrough \
-Wno-type-limits -Wno-maybe-uninitialized -Wno-empty-body"
)
