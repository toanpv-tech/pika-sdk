# Recipe — Di chuyển sprite theo nút

**Mục tiêu:** một nhân vật chạy trái/phải theo nút, mượt mà.

**API dùng:** `Sprite.solid`/`Sprite.image`, `spr:get_pos`/`set_pos`, `Input.is_down`.

```lua
local player
local SPEED = 3   -- px mỗi frame

function on_tick()
  -- tạo trễ ở frame đầu (tránh 'unsafe path' — xem pitfalls #1)
  if not player then
    player = Sprite.solid(24, 24, 0x07E0)     -- hoặc Sprite.image("images/hero.png")
    if player then player:set_pos(100, 100) end
    return
  end

  local x, y = player:get_pos()
  if Input.is_down("left")  then x = x - SPEED end
  if Input.is_down("right") then x = x + SPEED end
  -- kẹp trong màn 320x240 (giả sử sprite 24px)
  if x < 0 then x = 0 elseif x > 296 then x = 296 end
  player:set_pos(x, y)
end
```

**Ghi chú:**
- Dùng **`Input.is_down` (poll)** cho chuyển động liên tục — mượt hơn `on_input`.
- **Không có xoay/scale.** Đổi hướng nhìn = `player:set_flip(true, false)`.
- Cần đường dẫn ảnh? Khai không cần trong manifest cho `Sprite.image`, nhưng file phải nằm trong game (`images/hero.png`).
- Nhiều nhân vật đè lớp: `player:to_front()` / `set_z(n)`.

Manifest cần 3 action tối thiểu: xem [../templates/minimal-game/manifest.json](../templates/minimal-game/manifest.json).
