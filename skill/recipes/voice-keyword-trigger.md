# Recipe — Kích hoạt bằng lệnh giọng nói

**Mục tiêu:** game phản ứng với keyword tiếng Anh ("jump", "fire", "stop").

**Quan trọng:** Voice = **keyword-spotting**, KHÔNG phải hội thoại/STT tự do. Game khai danh sách keyword; backend match và trả về keyword đã nhận.

**API dùng:** `Voice.set_keywords`, `Voice.start`, hook `on_voice_event`.

```lua
local player

function game_start()
  -- keyword phải là tiếng ANH; check giá trị trả về (fail-loud)
  local ok, reason = Voice.set_keywords({ "jump", "fire", "stop" })
  if not ok then
    print("voice setup failed: " .. tostring(reason))   -- vd too_many_keywords, payload_too_big
    -- game vẫn nên chơi được bằng nút
  else
    Voice.start()   -- BẮT BUỘC — không start thì không nghe
  end
end

function on_tick()
  if not player then
    player = Sprite.solid(24, 24, 0x07E0)
    if player then player:set_pos(140, 180) end
    return
  end
end

function on_voice_event(e)
  -- e có thể là raw JSON string nếu vượt decoder cap → phòng thủ
  if type(e) ~= "table" then return end

  if e.type == "error" then
    -- voice hỏng (e.code / e.message): ẩn UI voice, game vẫn chạy bằng nút
    return
  end

  if e.type == "VOICE_COMMAND" then
    local data = e.data
    if type(data) ~= "table" then return end

    if data.status == "unavailable" then
      -- keyword-spotting không dùng được; game tiếp tục
      return
    end

    local kw = data.keyword
    if kw == "jump" then
      local x, y = player:get_pos(); player:set_pos(x, y - 30)
    elseif kw == "fire" then
      Speaker.play("laser")
    elseif kw == "stop" then
      Engine.exit("voice_stop")
    end
  end
end
```

**Ghi chú / cạm bẫy:**
- **Phải gọi `Voice.start()`** sau `set_keywords`. Quên = im lặng (pitfalls #8).
- Keyword **tiếng Anh**; ≤ 64 keyword; payload JSON ≤ 2048B (fail-loud nếu vượt).
- Luôn **check `set_keywords` trả về** `(nil, reason)`.
- Đường rẽ đúng: `e.type == "VOICE_COMMAND"` → `e.data.keyword`. Đừng đọc `e.keyword` trực tiếp.
- Thiết kế game **luôn chơi được bằng nút** kể cả voice hỏng (`status == "unavailable"` / `type == "error"`).
- Hot-swap vocabulary giữa chừng: gọi lại `Voice.set_keywords(...)`.
