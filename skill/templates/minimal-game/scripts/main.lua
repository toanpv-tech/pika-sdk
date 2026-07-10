-- Minimal Pika game — chạy được ngay, dùng làm điểm xuất phát.
--
-- Cấu trúc: game = tập hàm global engine tự gọi (hook). KHÔNG có game loop
-- của bạn; on_tick là frame (~30 FPS). Chỉ dùng API trong ../../api-contract.md.

-- ── Trạng thái game (upvalue module) ─────────────────────────────────
local player          -- sprite; tạo TRỄ ở on_tick đầu (tránh 'unsafe path')
local hud             -- Text handle
local score = 0
local SPEED = 3       -- px/frame

-- ── game_start(level_json): 1 lần khi vào game ───────────────────────
-- Text.new tạo được ở đây. Sprite/Anim thì KHÔNG (xem pitfalls #1) — tạo trễ.
function game_start(level_json)
  hud = Text.new("Score: 0", 4, 4)   -- nhớ: pool Text tối đa 8
end

-- ── on_tick(dt_ms): mỗi frame ────────────────────────────────────────
function on_tick(dt_ms)
  -- Tạo sprite ở frame đầu tiên (an toàn path), rồi return.
  if not player then
    player = Sprite.solid(24, 24, 0x07E0)   -- khối xanh 24x24 (màu RGB565)
    if player then player:set_pos(140, 180) end  -- set_pos NGAY để không nháy (0,0)
    return
  end

  -- Poll nút cho chuyển động mượt.
  local x, y = player:get_pos()
  if Input.is_down("left")  then x = x - SPEED end
  if Input.is_down("right") then x = x + SPEED end
  if x < 0 then x = 0 elseif x > 296 then x = 296 end   -- kẹp trong màn (320 - 24)
  player:set_pos(x, y)
end

-- ── on_input(action, phase, hold_ms): sự kiện nút rời rạc ─────────────
-- Dùng cho hành động 1-lần (chọn, bắn), không phải chuyển động liên tục.
function on_input(action, phase, hold_ms)
  if action == "enter" and phase == Input.PRESS then
    score = score + 1
    if hud then hud:set("Score: " .. score) end
  end
end

-- ── on_home(): nút HOME — thoát game ─────────────────────────────────
function on_home()
  Engine.exit("home")
end

-- ── game_end(): dọn dẹp trước khi thoát (tuỳ chọn) ───────────────────
function game_end()
  -- Sprite/Text tự huỷ khi game thoát; chỉ dọn thủ công nếu cần sớm.
end
