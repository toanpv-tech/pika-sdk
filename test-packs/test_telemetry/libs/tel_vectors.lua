-- libs/tel_vectors - GENERATED from contract/telemetry_vectors.json
-- (pika-telemetry-vectors/1). Do not edit by hand: python tools/gen_tel_vectors.py.
-- Resolve: require("libs/tel_vectors")
--
-- One entry per vector the running game can replay: the leading begin/start
-- ops are this launch, `at` is ms after the vector starts (event t minus
-- start t, modulo 2^32). Steps the contract marks c_only are left out.
-- fields is an array of {name, value} so the call order is fixed; a
-- non-table `fields`/`opts` is the contract's 'fail' case. expect/why are
-- the contract's; the pack re-derives rate outcomes from real call times
-- (a 33 ms tick cannot land on t=4999 exactly).
-- Integer literals past int32 (2147483648) become floats on the robot's
-- 32-bit Lua: still rejected, same outcome.

local M = {}

M.list = {
  {
    name = "basic_send",
    steps = {
      { at = 500, name = "answer", fields = {{"q", 3}, {"correct", true}, {"choice", "b"}}, expect = "send" },
    },
  },
  {
    name = "no_fields_no_pv",
    steps = {
      { at = 7, name = "egg.open", expect = "send" },
    },
  },
  {
    name = "rate_cold_start_at_t0",
    steps = {
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "reject", why = "rate" },
    },
  },
  {
    name = "rate_window_edge",
    steps = {
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "send" },
      { at = 4999, name = "a", expect = "reject", why = "rate" },
      { at = 5000, name = "a", expect = "send" },
      { at = 5000, name = "a", expect = "send" },
      { at = 5000, name = "a", expect = "send" },
      { at = 5000, name = "a", expect = "reject", why = "rate" },
    },
  },
  {
    name = "rate_spread_calls",
    steps = {
      { at = 0, name = "a", expect = "send" },
      { at = 1900, name = "a", expect = "send" },
      { at = 3900, name = "a", expect = "send" },
      { at = 4900, name = "a", expect = "reject", why = "rate" },
      { at = 5000, name = "a", expect = "send" },
      { at = 6899, name = "a", expect = "reject", why = "rate" },
      { at = 6900, name = "a", expect = "send" },
    },
  },
  {
    name = "rate_clock_wrap",
    steps = {
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "send" },
      { at = 0, name = "a", expect = "send" },
      { at = 4999, name = "a", expect = "reject", why = "rate" },
      { at = 5000, name = "a", expect = "send" },
    },
  },
  {
    name = "event_name_rules",
    steps = {
      { at = 0, name = "Answer", expect = "reject", why = "name" },
      { at = 0, name = "", expect = "reject", why = "name" },
      { at = 0, name = "abcdefghijklmnopqrstuvwxy", expect = "reject", why = "name" },
      { at = 0, name = "engine.load", expect = "reject", why = "name" },
      { at = 0, name = "sys.x", expect = "reject", why = "name" },
      { at = 0, name = "a b", expect = "reject", why = "name" },
      { at = 0, name = "a\000b", expect = "reject", why = "name" },
      { at = 0, name = "abcdefghijklmnopqrstuvwx", expect = "send" },
      { at = 0, name = "stage.end_2", expect = "send" },
    },
  },
  {
    name = "opts_key_and_level",
    steps = {
      { at = 10, name = "content.bad", fields = {{"q", 5}}, opts = {key = "quiz", level = "error"}, expect = "send" },
      { at = 20, name = "slow", opts = {level = "warn"}, expect = "send" },
      { at = 5000, name = "x", opts = {key = "quiz.v2", level = "info"}, expect = "send" },
    },
  },
  {
    name = "opts_bad_values",
    steps = {
      { at = 0, name = "a", opts = {key = ".quiz"}, expect = "reject", why = "key" },
      { at = 0, name = "a", opts = {key = "quiz."}, expect = "reject", why = "key" },
      { at = 0, name = "a", opts = {key = "Quiz"}, expect = "reject", why = "key" },
      { at = 0, name = "a", opts = {key = ""}, expect = "reject", why = "key" },
      { at = 0, name = "a", opts = {key = "abcdefghijklmnopqrstuvwxy"}, expect = "reject", why = "key" },
      { at = 0, name = "a", opts = {level = "fatal"}, expect = "reject", why = "opt_value" },
      { at = 0, name = "a", opts = {level = "INFO"}, expect = "reject", why = "opt_value" },
      { at = 0, name = "a", opts = "x", expect = "reject", why = "opt_value" },
    },
  },
  {
    name = "opts_unknown_key_still_sends",
    steps = {
      { at = 0, name = "a", opts = {sample = 10}, expect = "send" },
      { at = 1, name = "a", opts = {sample = 10}, expect = "send" },
    },
  },
  {
    name = "field_name_rules",
    c_only = 1,   -- steps only C can build (left out)
    steps = {
      { at = 0, name = "a", fields = {{"level", 1}}, expect = "reject", why = "field_name" },
      { at = 0, name = "a", fields = {{"key", "todo.exit"}}, expect = "reject", why = "field_name" },
      { at = 0, name = "a", fields = {{"Q", 1}}, expect = "reject", why = "field_name" },
      { at = 0, name = "a", fields = {{"a.b", 1}}, expect = "reject", why = "field_name" },
      { at = 0, name = "a", fields = {{"abcdefghijklmnopq", 1}}, expect = "reject", why = "field_name" },
      { at = 0, name = "a", fields = {{"", 1}}, expect = "reject", why = "field_name" },
      { at = 0, name = "a", fields = {{"abcdefghijklmnop", 1}}, expect = "send" },
    },
  },
  {
    name = "field_values",
    steps = {
      { at = 0, name = "v", fields = {{"lo", -2147483648}, {"hi", 2147483647}, {"up", 2.5}, {"dn", -2.5}, {"f", false}}, expect = "send" },
      { at = 0, name = "v", fields = {{"s", "a\"b\\c\010d"}}, expect = "send" },
      { at = 0, name = "v", fields = {{"s", "\"key\":\"todo.exit\""}}, expect = "send" },
    },
  },
  {
    name = "field_value_rejects",
    steps = {
      { at = 0, name = "v", fields = {{"n", 2147483648}}, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = {{"n", -2147483649}}, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = {{"n", 10000000000.0}}, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = {{"n", (0/0)}}, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = {{"n", math.huge}}, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = {{"t", print}}, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = 42, expect = "reject", why = "bad_type" },
      { at = 0, name = "v", fields = {{"s", "abcdefghijklmnopqrstuvwxyzabcdefghijklmno"}}, expect = "reject", why = "str_long" },
      { at = 0, name = "v", fields = {{"s", "abcdefghijklmnopqrstuvwxyzabcdefghijklmn"}}, expect = "send" },
    },
  },
  {
    name = "too_many_and_too_big",
    steps = {
      { at = 0, name = "v", fields = {{"a", 1}, {"b", 1}, {"c", 1}, {"d", 1}, {"e", 1}, {"f", 1}, {"g", 1}, {"h", 1}, {"i", 1}}, expect = "reject", why = "too_many" },
      { at = 0, name = "v", fields = {{"aaaaaaaaaaaaaaa1", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa2", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa3", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa4", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa5", "0123456789012345678901234567890123456789"}}, expect = "reject", why = "too_big" },
      { at = 0, name = "v", fields = {{"aaaaaaaaaaaaaaa1", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa2", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa3", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa4", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa5", "012345678901234567890123456789"}}, expect = "send" },
      { at = 0, name = "v", fields = {{"a", 1}, {"b", 1}, {"c", 1}, {"d", 1}, {"e", 1}, {"f", 1}, {"g", 1}, {"h", 1}}, expect = "send" },
    },
  },
  {
    name = "first_error_wins",
    steps = {
      { at = 0, name = "Bad", fields = {{"level", 1}}, opts = {key = ".x"}, expect = "reject", why = "name" },
      { at = 0, name = "ok", fields = {{"level", 1}}, opts = {key = ".x"}, expect = "reject", why = "key" },
    },
  },
  {
    name = "worst_case_fits",
    steps = {
      { at = 0, name = "abcdefghijklmnopqrstuvwx", fields = {{"aaaaaaaaaaaaaaa1", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa2", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa3", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa4", "0123456789012345678901234567890123456789"}, {"aaaaaaaaaaaaaaa5", "012345678901234567890123456789"}}, opts = {key = "abcdefghijklmnopqrstuvwx", level = "error"}, expect = "send" },
    },
  },
  {
    name = "session_identity_cleaned",
    steps = {
      { at = 0, name = "a", expect = "send" },
    },
  },
  {
    name = "utf8_kept_and_cleaned",
    c_only = 1,   -- steps only C can build (left out)
    steps = {
      { at = 0, name = "v", fields = {{"h", "h\195\169llo"}, {"e", "\240\159\152\128"}}, expect = "send" },
    },
  },
  {
    name = "tv_is_a_plain_field",
    steps = {
      { at = 0, name = "v", fields = {{"tv", 2}}, expect = "send" },
    },
  },
}

-- Vectors that need a launch to fail, an abort or no session at all.
M.skipped = {
  { name = "held_during_game_start", why = "start group (calls made in game_start)" },
  { name = "aborted_launch_drops_held", why = "not replayable: needs a pack whose game_start raises" },
  { name = "closed_after_close_not_counted", why = "game_end calls (summary line) and the exit manual row" },
  { name = "no_session_is_closed", why = "not replayable: a running game always has a session" },
}

return M
