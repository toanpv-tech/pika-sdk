# Recipe — Phát tiếng khi va chạm

**Mục tiêu:** hai sprite chạm nhau → phát âm thanh + tăng điểm.

**API dùng:** `spr:intersects`, `Speaker.play` (alias), `Text:set`, `on_sound_end`.

### 1. Khai alias âm thanh trong `manifest.json`

```json
{
  "assets": {
    "audio": {
      "sounds": {
        "hit": "audio/hit.wav",
        "win": "audio/win.wav"
      }
    }
  }
}
```

> `Speaker.play` nhận **alias** (`"hit"`), **không** đường dẫn file. Xem pitfalls #6.

### 2. Code

```lua
local player, coin, hud
local score = 0

function game_start()
  hud = Text.new("Score: 0", 4, 4)
end

function on_tick()
  if not player then                       -- tạo trễ (pitfalls #1)
    player = Sprite.solid(20, 20, 0x001F)  -- xanh dương
    coin   = Sprite.solid(16, 16, 0xFFE0)  -- vàng
    if player then player:set_pos(50, 100) end
    if coin   then coin:set_pos(200, 100) end
    return
  end

  -- di chuyển player theo nút
  local x, y = player:get_pos()
  if Input.is_down("left")  then player:set_pos(x-3, y) end
  if Input.is_down("right") then player:set_pos(x+3, y) end

  -- va chạm AABB
  if coin and player:intersects(coin) then
    Speaker.play("hit")          -- trả false nếu cooldown (80ms) — chấp nhận được
    score = score + 1
    hud:set("Score: " .. score)
    coin:destroy()               -- xoá coin đã ăn
    coin = nil
  end
end

-- (tuỳ chọn) biết khi âm thanh kết thúc / bị chặn
function on_sound_end(alias, reason)
  if reason == Speaker.REASON_COMPLETED and alias == "win" then
    Engine.exit("won")
  end
end
```

**Ghi chú:**
- **Cooldown 80ms:** `Speaker.play` liên tiếp quá nhanh trả `false`. Với hiệu ứng dày (bắn liên thanh) đừng dựa vào mỗi phát đều kêu.
- **Completion thật chỉ có ở Speaker** (`on_sound_end`). Servo/anim không báo "xong" đáng tin.
- So `reason` với hằng `Speaker.REASON_*`, không số literal.
