# Game Engine Monitor — Log theo vòng đời

Log của `game_engine` (head_esp32), chia theo pha vòng đời game. Grep một tag = đọc trọn một pha.

| Tag | Nhịp phát | Trả lời câu hỏi |
| --- | --- | --- |
| `game.start` | 1 dòng / phiên | Vào game có sạch không? Tốn bao nhiêu RAM, load mất bao lâu? |
| `game.running` | 30 s hoặc 45× FPS frame | Đang chơi có mượt không? Có trôi dần không? |
| `game.stop` | 1 dòng / phiên | Cả phiên tổng kết ra sao? Thoát vì lý do gì? |
| `game.error` | on-event | Hỏng ở đâu, subcode nào, dòng script nào? |
| `game.warn` | gộp / 10 s (im nếu không có gì) | Sắp hỏng — dấu hiệu sớm gì? |

> **`game.stop end=norm` KHÔNG chứng minh game chạy đúng.** Bộ log này bao lỗi hạ tầng engine, mù với logic gameplay — §8. Bảng chẩn đoán triệu chứng → kết luận: §7.

---

## 0. Ngân sách UART

Console **115200 baud**, `CONFIG_ESP_CONSOLE_UART_DEFAULT` → ESP-IDF ghi console **blocking, busy-wait trên TX FIFO**: mỗi ký tự log là thời gian `engine_task` đứng im.

**≈ 86 µs/ký tự**, prefix `ESP_LOGx` tốn sẵn ~27 ký tự. Dòng 200 ký tự chặn **17 ms — hơn nửa frame 33,3 ms**.

| Loại tag | Ràng buộc |
| --- | --- |
| 1 dòng/phiên (`game.start`, `game.stop`) | Độ dài không quan trọng — tối ưu cho **mắt đọc**, không cho ký tự |
| Định kỳ (`game.running`) | **Mỗi ký tự là chi phí frame** → tên khoá ngắn, giãn nhịp |
| Gộp 10 s (`game.warn`) | Nguy cơ là **tần suất** → gộp cả cửa sổ vào 1 dòng |

**Chọn trường:** hằng số in một lần ở `game.start`. Dẫn xuất máy móc thì bỏ (`budget = 1000000/fps_target`); dẫn xuất mà mắt cần ngay thì giữ (`fps = frames/dur`) — tiêu chí là *chi phí nhẩm tại chỗ*. Trường cần mẫu số phải in kèm mẫu số hoặc tự chuẩn hoá.

**Đặt tên:** ngắn nhất còn phân biệt được; đơn vị nằm trong doc, không nhồi vào tên khoá (`heap_int_lgst_kb` → `heap`).

**Bẫy khi đọc:** `tick_us` chốt **trước** `ESP_LOGI` nên không tự bóp méo, nhưng thời gian ghi UART rơi vào `gap_us` của frame kế tiếp → spike giả đều đặn theo nhịp log. `gap_us` vọt tuần hoàn mà `tick_us` bình thường thì **nghi log trước, nghi game sau**.

---

## 1. `game.start`

Phát khi game vào chạy được, ngay sau `renderer_enter_game_screen()` thành công.

```text
game.start game=<id> trigger=<menu|a2a> load=<ms> arena=<bytes> psram=<bytes> heap=<bytes> fps_target=<n>
```

| Key | Đơn vị | Ý nghĩa |
| --- | --- | --- |
| `game` | string | Game pack id |
| `trigger` | enum | `a2a` = trong A2A talk-flow (`IPC_CMD_GAME_START_A2A`) · `menu` = từ menu (đường này drop **kết quả gameplay** qua A2A, §6 — telemetry `game.*` thì vẫn lên MQTT cho cả hai) |
| `load` | ms | Thời gian `game_pack_load()` — đo **riêng** hàm này, chốt trước cửa sổ peek-STOP; tính cả chờ mailbox thì mất nghĩa |
| `arena` | byte | Lua arena lúc start — baseline của `arena_pk` |
| `psram` | byte | PSRAM largest-free sau khi commit arena + asset |
| `heap` | byte | Internal largest-free — baseline của `heap_min` |
| `fps_target` | fps | Target FPS (hằng số) — mẫu số để đọc `tick_hz` |

**Ba trường bộ nhớ là baseline, không tự mang tin** — chỉ đọc được khi ghép với `game.stop`:

| Cặp | Đọc ra gì |
| --- | --- |
| `arena` ↔ `arena_pk` | Lua cấp thêm bao nhiêu lúc chơi. Bằng nhau = pack cấp hết ở init (lành) |
| `heap` ↔ `heap_min` | **Độ sâu bậc thang.** `74752→62464` bình thường; `74752→3072` sắp crash dù phiên vẫn `end=norm` |
| `psram` giữa các phiên | PSRAM hồi đủ sau teardown hay rò dần |

Hai đầu phải dùng **cùng metric** (largest-free, không phải total-free) — lệch metric thì cặp mất nghĩa mà không ai phát hiện.

## 2. `game.running`

```text
game.running t=<s> tick_hz=<n> tick_us=<us> gap_us=<us> p95=<us> slow_n=<n> heap=<bytes> arena=<bytes> hwm_engine=<n> ccalls=<n>
```

| Key | Đơn vị | Ý nghĩa |
| --- | --- | --- |
| `t` | s | Giây thứ mấy của phiên — trục thời gian để thấy xu hướng |
| `tick_hz` | Hz | Nhịp **tick của engine**, KHÔNG phải FPS màn hình (xem cảnh báo dưới) |
| `tick_us` | µs | Tick nặng nhất cửa sổ — CPU **trong thân tick**, KHÔNG gồm vẽ |
| `gap_us` | µs | **Frame time thật** người chơi cảm nhận — gồm cả `vTaskDelayUntil` lẫn preemption |
| `p95` | µs | p95 của `tick_us`, xấp xỉ theo bucket |
| `slow_n` | count | Frame **giao chậm** (`gap_us` > 34 ms), cộng dồn cả phiên — số đếm thô; `game.stop` dùng ‰ |
| `heap` | KB | Internal largest-free — bắt bậc thang **trong lúc chơi** |
| `arena` | KB | Arena đang giữ — bò lên đều = Lua leak |
| `hwm_engine` | bytes | Stack high-water mark của **`engine_task`** (không phải của pack) |
| `ccalls` | count | Đỉnh độ sâu C-stack của Lua |

### ⚠️ Kiến trúc đo — đọc trước khi kết luận bất cứ điều gì

**`engine_task` không vẽ.** `renderer_frame_end()` chỉ gọi `lv_unlock()`. Việc rasterize + flush SPI ra LCD xảy ra ở task **`lvgl_timer`** (core 0, prio 8, chu kỳ 20 ms), trong khi `engine_task` chạy **core 1, prio 5**.

| | Task | Core | Prio |
| --- | --- | --- | --- |
| Tick game (Lua, drain, anim) | `engine_task` | 1 | 5 |
| **Vẽ thật + flush LCD** | `lvgl_timer` | 0 | 8 |
| UI khác | `lvgl` | 1 | 6 |
| Audio | audio | — | 10 |

Hệ quả trực tiếp:

- **`tick_us` KHÔNG gồm thời gian vẽ.** Game có thể báo `tick_us=5000` rất đẹp trong khi màn hình giật.
- **`tick_hz` KHÔNG phải FPS màn hình.** Nó đếm vòng lặp `engine_task`. Frame màn hình thật nằm ở `draw_pm` của `game.stop` (§3).
- Vì vậy `slow_n` tính theo **`gap_us`** (frame time giao thật), không theo `tick_us` — nếu tính theo `tick_us` thì frame trễ do LVGL/audio giành CPU **không được đếm**, đúng cái mà người chơi thấy giật còn log báo sạch.

Ngưỡng frame chậm là **34 ms** (không phải đúng 33,333 ms) — theo mốc Android Vitals cho tựa game 30 FPS; 0,7 ms dư ra để jitter scheduler của một frame đúng hạn không bị tính là trượt.

⚠️ **Đổi tên so với bản cũ:** `work`→`logic`→`tick_us`, `gap`→`gap_us`, `fps`→`tick_hz`, `over`→`slow_n`, `hwm`→`hwm_engine`. Lý do khác nhau: `work`/`fps`/`over` **nói sai** thứ đang đo; `hwm` không rõ đo task nào; `tick_us`/`gap_us` thêm hậu tố đơn vị vì `1495318` đọc nhầm thành mili giây là sai 1000 lần. Đổi được vì **không có parser nào đọc dòng UART** (đã kiểm toàn repo).

**Ba cặp phải đọc cùng nhau**, tách ra là mất chẩn đoán:

- `tick_us` + `gap_us` — `tick_us` nhỏ mà `gap_us` lớn = **bị preempt**, không phải game chậm. Hai hướng sửa ngược nhau.
- `tick_us` + `p95` — chỉ `tick_us` thì không phân biệt "một cú vấp" với "chậm đều".
- `hwm_engine` + `ccalls` — pack còn cách trần C-stack bao xa (~486 B/level).

⚠️ **`gap_us` là max trong cửa sổ** — một spike trong 900 frame trông y hệt 900 spike. Dùng `slow_n` để biết **tần suất**, `gap_us` chỉ cho biết **biên độ**.

**Nhịp 30 s** (~89 ký tự ≈ 10 ms UART + 1 slot ring SYSMON): **không mất dữ liệu** — accumulator ăn mọi frame, `game.stop` vẫn chốt đủ `p95`/`slow_pm`/`arena_pk`/`heap_min`; nới cửa sổ chỉ giảm độ phân giải lúc soi realtime. Mốc 5 s cũ chọn khi UART là consumer duy nhất; từ khi có uplink MQTT (§6) thì chi phí mỗi dòng đáng cân nhắc hơn độ mịn realtime.

Giữ van an toàn `|| >= GAME_RUNNING_LOG_FRAMES` để game tụt FPS thảm hại vẫn log kịp trước khi chết. Van đặt ở **45× FPS target** (= `FPS * 45`, tức 1350 frame ở 30 FPS).

⚠️ **Hai hằng số này ràng buộc nhau, đổi một phải chỉnh cái kia.** Điều kiện là `OR`, nên van **phải lớn hơn** số tick của cửa sổ thời gian ở FPS bình thường (30 s × 30 = 900); nếu không van chốt trước và nhịp thời gian **không bao giờ có tác dụng** — cadence âm thầm thành `FRAMES/FPS` giây thay vì con số ghi trong `GAME_RUNNING_LOG_US`. Tỷ lệ 1,5× (900 → 1350) giữ nguyên biên như cặp 5 s/7,5× trước đây. Đổi `TARGET_FPS` thì cả hai tự co giãn theo.

**`p95` là xấp xỉ theo bucket**, không phải phân vị chính xác (histogram bucket cố định, không alloc/sort trong hot path). Đọc như một dải, đừng so hai giá trị lệch nhau vài µs.

## 3. `game.stop`

Tổng kết cả phiên, phát lúc teardown.

```text
game.stop game=<id> end=<norm|home|err|stall> err=<SUBCODE> dur=<s> frames=<n> tick_hz=<n>
          draw_pm=<permil>
          p95=<us> slow_pm=<permil> arena_pk=<bytes> heap_min=<bytes> psram=<bytes>
          drop=<in>/<snd>/<nohook>/<svo>/<led> api_fail=<n>
```

| Key | Nguồn | Ý nghĩa |
| --- | --- | --- |
| `end` | `stall_reported` → `last_error` → `stop_reason` | `norm` sạch · `home` nút HOME · `err` lỗi · `stall` watchdog cắt. **Ưu tiên theo đúng thứ tự đó** — xem dưới |
| `err` | `game_engine_last_error()` | Subcode đầy đủ (không phải 1 byte reason của wire IPC). **Bỏ hẳn khi `end=norm`** |
| `dur` | `game_started_us` | Độ dài phiên |
| `frames` | accumulator | Tổng **tick** — mẫu số cho `slow_pm`; nhỏ bất thường so với `dur × fps_target` = game **treo giữa phiên** |
| `tick_hz` | dẫn xuất | `frames`/`dur` — nhịp tick, **không phải** FPS màn hình |
| **`draw_pm`** | `LV_EVENT_RENDER_READY` / `frames` | **‰ frame game yêu cầu mà màn hình vẽ thật.** 1000 = hoàn hảo. Đây là trường duy nhất tách "game chậm" khỏi "màn hình chậm" |
| `p95` | accumulator | Tick p95 cả phiên |
| `slow_pm` | accumulator | Frame vượt budget, **‰ của `frames`** |
| `arena_pk` | accumulator | **Đỉnh** arena — chỉ đo start/teardown là bỏ lỡ đỉnh giữa phiên |
| `heap_min` | accumulator | Đáy internal largest-free cả phiên |
| `psram` | `heap_caps_*` tại chỗ | PSRAM largest-free **lúc teardown, TRƯỚC khi unload** — ghép với `psram` ở `game.start` để thấy phiên này giữ bao nhiêu. Con số sau khi đã giải phóng cố tình không in (không đáng thêm một dòng log) |
| `drop` | 5 counter gộp | Xem dưới |
| `api_fail` | counter | Binding trả `(nil,msg)`/`false` về Lua — chỉ số chống "phiên sạch giả" (§8.1) |

### `draw_pm` — trường quan trọng nhất của dòng này

```text
draw_pm = (số frame LVGL vẽ thật × 1000) / frames
```

Tử số đếm ở `LV_EVENT_RENDER_READY` — **task khác, core khác** với engine (§2). Mẫu số là tick game. Đọc thẳng: *"cứ 1000 lần game muốn vẽ, màn hình vẽ thật được bao nhiêu"*.

| `draw_pm` | `tick_hz` | Kết luận |
| --- | --- | --- |
| ~1000 | ~30 | Lành |
| **< 800** | ~30 | **Game tick ổn, MÀN HÌNH mới là nghẽn** — dirty-rect quá rộng hoặc bus quá tải. **Không sửa pack** |
| ~1000 | ~15 | Game tự nó chậm — tối ưu `on_tick` |
| **0** | ~30 | Không frame nào ra LCD — nghi `lvgl_timer` bị chặn (nó tự ngủ 1000 ms khi AnimationPlayer chạy GIF) |

Trước đây chỉ có `tick_hz`, nên **hàng thứ hai và thứ tư hoàn toàn vô hình** — đúng kịch bản "chơi thấy giật mà log báo sạch".

**Vì sao mẫu số là tick chứ không phải số lần `lv_obj_invalidate()`:** LVGL gộp nhiều vùng invalidate thành một refresh, nên tỷ lệ theo invalidate sẽ **luôn dưới 1000‰ kể cả khi hoàn toàn khỏe** — báo động giả liên tục. Một tick = một frame game muốn có, đó mới là câu đáng hỏi.

**Chặn trên ở 1000:** LVGL cũng vẽ vì lý do game không yêu cầu (menu overlay, toast), giá trị vượt "hoàn hảo" đọc như lỗi.

⚠️ **`draw_pm` cao KHÔNG chứng minh màn hình khỏe — luôn đọc kèm `tick_hz`.** Nó là tỷ lệ, nên **mẫu số tụt cũng làm nó đẹp lên**. Đo thật trên `word_racer`: cùng một pack cho `draw_pm=105` (`tick_hz=30`) ở phiên này và `draw_pm=910` (`tick_hz=22`) ở phiên khác — chênh 8,7 lần mà trải nghiệm người chơi **không hề tốt hơn**. Engine chỉ hạ nhịp tick xuống ngang tốc độ panel vẽ nổi, nên tỷ lệ render/tick vọt lên gần hoàn hảo.

Số tuyệt đối duy nhất không nói dối được là `display.fps` (mục dưới): cùng phiên `draw_pm=910` đó, `mean` chỉ 20–23 và `p5` 16–17. **Khi `draw_pm` ~1000 mà `tick_hz` thấp, đọc hàng 3 của bảng trên, không phải hàng 1.**

⚠️ **Trần vật lý 26 FPS toàn màn.** Bus Parallel8 @ 8 MHz = 8 MB/s; một khung 480×320 RGB565 là 300 KB → **38,4 ms**, vượt budget frame 33,3 ms. Game **buộc** phải giữ vùng bẩn nhỏ; không cấu hình LVGL nào sửa được. Vùng bẩn 25% màn → 9,6 ms, thoải mái trong budget.

### `display.fps` — FPS toàn hệ thống, lấy mẫu từng giây

`draw_pm` chỉ sống trong phiên game. `display.fps` chạy liên tục (GIF, UI, game) và là **metric SYSMON**, không thuộc nhóm `game.*`.

```json
{"key":"display.fps","level":"INFO","data":{"src":"lvgl","mean":9,"p5":2,"peak":26,"samples":24,"req":9009}}
{"key":"display.fps","level":"INFO","data":{"src":"anim","mean":13,"p5":9,"peak":15,"samples":27}}
```

| Trường | Nguồn | Ý nghĩa |
| --- | --- | --- |
| `src` | phân loại mẫu | `lvgl` (UI/game) · `anim` (GIF/MJPEG) · `mix` (cửa sổ bắc qua lúc chuyển) |
| `mean` | trung bình các mẫu | FPS trung bình **trên các giây có việc** |
| `p5` | phân vị 5 | **FPS ở 5% giây tệ nhất** — con số mô tả trải nghiệm xấu nhất người dùng thật sự chịu |
| `peak` | max | Trần thực tế đạt được; đối chiếu với trần vật lý 26 |
| `samples` | đếm mẫu | Số **giây có nội dung động** — mẫu số của 3 trường trên |
| `req` | `LV_EVENT_REFR_REQUEST` | Tổng yêu cầu vẽ. **Bỏ khi `src=anim`** — đường GIF không sinh request, để lại sẽ đọc thành "yêu cầu vẽ 0 lần mà vẽ được 15 frame" |

#### ⚠️ Hai đường vẽ song song — `src` cho biết đang đo đường nào

| Đường | Vẽ bởi | `src` |
| --- | --- | --- |
| UI + game | LVGL → `flush_cb` | `lvgl` |
| GIF/MJPEG (Learn, A2A, emotion) | **LovyanGFX thẳng xuống panel**, không qua LVGL | `anim` |

`AnimationPlayer` không gọi `lv_obj_invalidate()` bao giờ, nên **không sinh `REFR_REQUEST` lẫn `RENDER_READY`**. Tệ hơn: `lvgl_timer` **chủ động ngủ 1000 ms** khi animation chạy (`ui_menu.cpp:300`) để nhường bus.

Hệ quả nếu chỉ đo LVGL: **toàn bộ thời gian Learn / A2A / emotion không có metric nào lên MQTT** — màn hình đang bận mà số liệu im lặng, đọc thành "màn tĩnh". Đó là lý do đường animation nạp mẫu vào **cùng một ring**, qua `display_fps_record_anim_frame()` gọi mỗi frame thật sự đẩy lên panel.

Hai đường **loại trừ nhau theo thời gian**, nên một cửa sổ hầu như luôn thuần một loại; `mix` chỉ xuất hiện khi cửa sổ 30 s bắc ngang lúc chuyển chế độ.

#### Quan hệ với `ui.image.fps_count` — hai key, hai câu hỏi khác nhau

Cả hai đều giữ, **cố ý**, vì chúng trả lời hai câu khác nhau:

| | `display.fps` `src=anim` | `ui.image.fps_count` |
| --- | --- | --- |
| Đơn vị đo | **cửa sổ 30 s** | **một lần phát GIF** |
| Trả lời | "màn hình mượt cỡ nào" | "**file nào** chạy chậm" |
| Hình dạng | `mean`/`p5`/`peak` từ mẫu 1 s | 1 số trung bình toàn GIF |
| Có `path` | ❌ | ✅ |

**Vì sao `display.fps` KHÔNG mang `path`:** một cửa sổ 30 s thường bắc qua **nhiều GIF khác nhau** — đo thật trên máy cho 17 GIF trong ~5 phút, tức 2–4 GIF mỗi cửa sổ. Gắn một tên file vào bộ số tính trên 4 GIF sẽ khiến người đọc quy toàn bộ số liệu cho file đó. **Quy kết sai còn tệ hơn không có tên.** Muốn biết file nào nặng thì đọc `ui.image.fps_count` — nó per-GIF theo bản chất.

⚠️ Hạn chế của `ui.image.fps_count` cần nhớ khi đọc: chỉ ghi **khi GIF kết thúc** (loop vô hạn có thể không bao giờ báo), là **trung bình toàn GIF** nên che mất khựng, và giữa hai lần `PeriodicCheck` chỉ **giữ GIF cuối cùng** — các GIF khác trong cùng 30 s mất im lặng. Dùng nó để định danh thủ phạm, dùng `display.fps` để đánh giá mức độ.

**Vì sao lấy mẫu 1 s rồi mới gộp, không lấy trung bình thẳng 30 s:** trung bình 30 s **không phân biệt** "30 giây chậm đều 9 FPS" với "10 giây mượt 26 FPS rồi 20 giây đứng hình" — hai tình huống khác hẳn về bản chất, một cái hơi chậm, một cái treo. Cùng ra số 9. FPS chỉ có nghĩa trên cửa sổ đủ ngắn để tốc độ coi như không đổi, nên chốt mỗi giây và **gộp các giây**, không gộp các frame.

**`p5` chứ không phải `p95`:** với latency, phân vị cao = xấu. Với FPS thì ngược — `p95` sẽ cho ra *giây tốt nhất*, vô dụng. Cái cần là đuôi **thấp**.

**Không có `min`:** mọi chuyển cảnh (load font, mở SD, decode ảnh) đều tạo một giây 0 render, nên `min` sẽ bằng 0 ở **mọi phiên kể cả hoàn hảo** — một hằng số ngụy trang thành số đo.

**`p5`/`peak` bị bỏ khi `samples` < 5.** Phân vị trên 2-3 mẫu là nhiễu; một phiên game 2 giây sẽ báo động vì đúng một frame lúc nạp font. Thiếu mẫu thì WARN xét theo `mean`.

#### Ảnh tĩnh thì FPS bằng bao nhiêu?

**Câu hỏi không áp dụng.** FPS là *tốc độ*; ảnh tĩnh không có chuyển động để đo, như hỏi xe đang đỗ chạy bao nhiêu km/h. Trả lời `0` đúng số học nhưng sai ngữ nghĩa: `0` trong ngữ cảnh FPS đọc là "treo", trong khi thực tế là "không có gì cần vẽ, hệ thống hoàn toàn khỏe".

Nên: **màn tĩnh không sinh mẫu nào**, và khi cả cửa sổ không có mẫu (`samples` = 0) thì **không gửi telemetry**. Im lặng, không phải `0`.

Cạm bẫy: màn tĩnh vẫn rỉ ra ~2 yêu cầu vẽ mỗi giây (đo thật). Nếu gate bằng "khác 0" thì những giây đó lọt vào tập mẫu và **kéo `p5` xuống 0 ở mọi phiên**. Vì vậy ngưỡng là `LVGL_FPS_ACTIVE_MIN_REQ` = 5 req/s, tức "có việc thật sự", không phải "khác 0".

Đường `anim` **không cần gate**: nó chỉ được gọi khi một frame đã thật sự đẩy lên panel, nên mọi giây chốt được đều mang việc thật. GIF dừng thì đơn giản là ngừng sinh mẫu — cùng một hợp đồng "không mẫu = không có gì động".

Giây dở dang lúc GIF kết thúc bị **bỏ, không quy đổi**: một GIF dừng ngay sau mốc giây mà đem chia thì cho ra tốc độ tính từ một phần nhỏ bằng chứng, và animation ngắn sẽ chi phối phân vị. Chốt ở `End()` — điểm hội tụ của mọi đường dừng, chạy cùng task với sampler nên không race.

| Trạng thái | `samples` | Hành vi |
| --- | --- | --- |
| Màn tĩnh | 0 | **Không gửi** — không phải lỗi |
| Có động, vẽ được | > 0 | INFO/WARN theo `p5` |
| Có yêu cầu, không vẽ nổi | > 0, `p5`=0 | **WARN** — treo thật |

**WARN xét theo `p5` < 20, không theo `mean`** — cửa sổ mượt tổng thể nhưng đứng hình 2 giây là cửa sổ người dùng đã nhận ra.

⚠️ `DISPLAY_FPS_SAMPLE_INTERVAL_MS` là **sàn, không phải nhịp thật**. Caller duy nhất là `PeriodicCheck()`, chạy sau `vTaskDelay(30000)` trong `main.cpp` — mọi giá trị dưới 30000 vô tác dụng. Trước đây hằng số ghi 5000, tức **nói dối**; nay để đúng 30000. Việc lấy mẫu 1 s nằm ở driver và không phụ thuộc hằng số này.

⚠️ Ring giữ **30 giây gần nhất**. Nếu consumer gọi thưa hơn, các giây cũ bị ghi đè im lặng — `samples` vẫn đúng với những gì còn giữ.

**`slow_pm` là ‰ vì số đếm thô không đọc được mà không biết mẫu số.** Cùng `slow_pm=41`: phiên 3683 frame = 11‰ (bình thường), phiên 232 frame = 177‰ (thảm hoạ). Dùng ‰ chứ không phải % để giữ độ phân giải dưới 1 % bằng số nguyên.

⚠️ **`slow_pm` nay đếm theo `gap_us` (frame giao chậm > 34 ms), không theo `tick_us`.** Bản cũ so `tick_us > budget` nên bỏ sót mọi frame trễ vì bị preempt. Nghĩa là con số này **tăng lên** so với firmware cũ trên cùng một pack — không phải game xấu đi, mà là trước đây đếm thiếu.

⚠️ **`game.running` dùng `slow_n`, số đếm thô** — cố ý, vì giữa phiên chưa biết `frames` cuối, chuẩn hoá lúc đó cho một con số trôi liên tục. Hậu tố mang đơn vị (`_n` đếm, `_pm` phần nghìn) nên hai dòng không thể so nhầm bằng mắt; trước đây cả hai đều tên `over`, chỉ khác nhau ở chỗ nó nằm dòng nào.

**Bỏ trường khi không mang tin** — dòng này đọc bằng mắt, nhiễu tốn hơn ký tự:

- `err=` bỏ khi `end=norm` — vắng `err=` **chính là** thông tin "phiên sạch".
- `drop=` bỏ khi cả 5 vị trí bằng 0.
- **Không bỏ `api_fail=0`**: nó là bằng chứng tích cực đã kiểm và không có binding fail. Vắng mặt sẽ lẫn với "chưa nối counter" — đúng tình trạng 6/9 file bind hiện nay (§9).

```text
game.stop game=bubble end=norm dur=127 frames=3683 tick_hz=29 draw_pm=968 p95=16000 slow_pm=11 arena_pk=207872 heap_min=62464 psram=2983936 api_fail=0
game.stop game=bubble end=err err=OOM dur=8 frames=232 tick_hz=29 draw_pm=413 p95=41000 slow_pm=177 arena_pk=411648 heap_min=3072 psram=120832 drop=0/14/3/0/0 api_fail=7
```

### `drop=<in>/<snd>/<nohook>/<svo>/<led>`

| Vị trí | Nguồn | Ý nghĩa |
| --- | --- | --- |
| `in` | `dropped_total` (input) | Input rớt do SPSC ring đầy |
| `snd` | `finish_dropped` | Finish event rớt do ring đầy |
| `nohook` | `no_hookup` | Audio pipeline nghẽn (hay kèm treo GIF) |
| `svo` | tổng 4 `back_reject_*` | Back từ chối servo |
| `led` | `dropped_total` (led ring) | LED ring đầy |

**Vị trí là hợp đồng** — thêm counter phải nối vào cuối; chèn giữa làm mọi log cũ bị đọc sai âm thầm. Vượt ~6 vị trí thì bỏ dạng gộp, quay lại trường có tên.

**Thứ tự ưu tiên của `end=` là một chuỗi if-else, không phải bảng tra:** `stall` thắng tất cả, rồi `err` (bất kỳ subcode ≠ `NONE`), cuối cùng mới xét `stop_reason`. Lý do: một phiên bị watchdog cắt **cũng** có `last_error = LUA_WATCHDOG`, nếu xét `err` trước thì `stall` không bao giờ xuất hiện. `home` là *mọi* `stop_reason` khác `CLEAN_END`, nên nhãn `home` thực chất nghĩa là "thoát hợp tác nhưng không phải game tự kết thúc" — chưa phân biệt được nút HOME với các đường thoát khác (§8.3).

### Ràng buộc khi implement

1. In **trước** `game_*_reset_session()` trong `engine_teardown_in_task()`. In sau ra toàn số 0, trông y hệt phiên sạch.
2. `frames`/`p95`/`slow_pm`/`arena_pk`/`heap_min` cần **accumulator vòng đời** (reset ở START, chốt ở teardown) vì cửa sổ `game.running` reset liên tục. Hiện là `game_session_stats_t session` **trong `engine_state_t`**, không phải function static — để `engine_session_stats_reset()` ở START không thể bỏ sót peak của phiên trước.
3. `slow_pm = (over_count * 1000 + frames/2) / frames`, guard `frames == 0` → `0`. Số nguyên, không float.
4. `heap_int_min_bytes` khởi tạo `UINT32_MAX` để mẫu đầu tiên luôn thắng; lúc in phải map `UINT32_MAX` → `0` (nghĩa là "chưa lấy được mẫu nào"), nếu không dòng log hiện ra 4194303 KB.
5. Lấy mẫu heap/arena **mỗi `GAME_MEM_SAMPLE_FRAMES` frame (~4 Hz)**, không phải mỗi frame: `heap_caps_*` lấy heap lock, và đáy internal tụt theo giây chứ không theo frame.

## 4. `game.error`

```text
game.error code=<SUBCODE> phase=<launch|load|render|on_tick|on_input|on_sound_end|stall> game=<id> msg="<...>"
```

| `phase` | Điểm phát | Subcode thường gặp |
| --- | --- | --- |
| **`launch`** | **Bị từ chối TRƯỚC khi phiên tồn tại** — `game_engine_init`/`game_engine_start` không nhận | `LAUNCH_REJECTED` |
| `load` | `game_pack_load` fail (gồm cả script load, validator, VM create) | `PACK_NOT_FOUND` · `PACK_MANIFEST` · `LUA_LOAD` · `VALIDATOR` · `LUA_VM_CREATE` |
| `render` | `renderer_enter_game_screen` fail | `RENDER_INIT` |
| `on_tick` · `on_input` · `on_sound_end` | tick-loop fatal — **tên callback Lua đã fail**, không gộp thành `runtime` | `LUA_RUNTIME` · `OOM` |
| `stall` | watchdog `stall_requested` trong `engine_task` | `LUA_WATCHDOG` |

### `phase=launch` — "game không mở được"

Trước đây đây là **lớp lỗi DUY NHẤT không có telemetry nào**. Cả 5 điểm phát `game.*` đều nằm trong `engine_task`, tức chỉ chạy sau khi phiên đã bắt đầu; một launch bị từ chối thì task chưa hề nhận được START. Back ghi `GAME_STOP reason=engine_busy` vào log cục bộ nhưng **không đẩy metric nào lên MQTT** — robot ngoài hiện trường im lặng hoàn toàn, đúng lúc người dùng phàn nàn "bấm vào game không lên".

```json
{"key":"game.error","level":"ERROR","data":{"game":"word_racer","code":"LAUNCH_REJECTED","phase":"launch","msg":"start_pending"}}
```

`msg=` mang **lý do chặn**, đây mới là thông tin chẩn đoán:

| `msg` | Nghĩa |
| --- | --- |
| `running` | Đang có game chạy thật — back gửi START chồng |
| `start_pending` | Cờ kẹt: START trước chưa được task tiêu thụ. **Nếu lặp lại thì là bug** — xem §8.5 |
| `deinit_in_flight` | `game_engine_init` từ chối vì `lifecycle=DEINITING` — engine kẹt tới khi reboot |
| `mailbox_full` | `post_msg` timeout — engine_task không tiêu thụ kịp |
| `nomem` · `init_failed` | Hết heap |

⚠️ **Dòng này KHÔNG có `frames`/`dur`.** Cố ý: chưa có phiên nào, mà `s_engine.session` lúc đó còn giữ số liệu của **phiên trước** — in ra sẽ đọc như thể launch này đã chạy được ngần ấy frame. Đây là lý do nó không dùng lại `engine_log_error()`.

Gửi `immediate` như `game.error` thường: không có `game.stop` nào theo sau để mang tin.

**`phase` ở nhánh tick-loop là tên callback, không phải `runtime`.** Ba callback hỏng vì ba lý do khác nhau, gộp lại thì mất thông tin đắt nhất của dòng log. `game.error` ở nhánh này in **sau** khi đã xác định callback nào trả lỗi, và thay hẳn dòng `teardown_fatal` cũ.

`phase=stall` phát tại nhánh `stall_requested` trong vòng lặp `engine_task` (không phải trong `stall_detector_cb` — callback timer chỉ set cờ), nên **không có tên binding treo trong `msg=`**; message là hằng chuỗi `"engine_task stalled - native binding deadlock"`. Muốn biết binding nào thì đọc `last_binding_name` qua đường khác.

**`msg=` bắt buộc với `phase=load` và ba phase callback (`on_tick`/`on_input`/`on_sound_end`).** `docall()` chạy dưới message handler đính traceback (`lua_vm.c:446-455`) — message đã có sẵn. Bỏ `msg` là mất dòng script chết; `code=LUA_RUNTIME` một mình gần như vô dụng.

In **tên** subcode chứ không phải số (`code=VALIDATOR`, không phải `code=8`); bỏ prefix `GAME_ENGINE_ERR_`.

`msg=` là trường **duy nhất không giới hạn độ dài** — traceback vài trăm ký tự = hàng chục ms UART, chấp nhận được vì lúc này game đã hỏng. Đừng áp logic này cho tag định kỳ.

## 5. `game.warn`

**Không phải luồng sự kiện — là bản GỘP theo cửa sổ 10 giây.** Mọi warn nổ ra trong cửa sổ được dồn lại, cuối cửa sổ phát **một dòng duy nhất** chở đúng những gì đã xảy ra. Cửa sổ im lặng thì **không phát gì cả**.

```json
{"key":"game.warn","level":"WARN","data":{"overrun":37,"Speaker.play":2,"heap":11840}}
```

Hai lý do gộp:

- **Warn đi theo cụm.** Audio pipeline nghẽn sinh ra `api_fail` VÀ `overrun` cùng lúc, cùng một gốc; tách thành hai bản tin bắt người đọc ghép lại thứ mà firmware vốn đã biết là đồng thời.
- **Trần chi phí cứng.** Một dòng / 10 s bất kể bao nhiêu loại lỗi nổ ra. Throttle cũ khoá theo từng kind nên trần thật ra **nhân với số kind**.

### Khoá động: mỗi loại lỗi là một khoá riêng

| Khoá | Kiểu | Nghĩa |
| --- | --- | --- |
| `overrun` | delta | Số frame giao chậm >34 ms **trong cửa sổ** |
| `animerr` | delta | Số lỗi decode anim trong cửa sổ |
| `heap` | **mức** | **Byte** internal largest-free — giữ **mẫu TỆ NHẤT** của cửa sổ |
| `<tên binding>` | delta | Số lần binding đó fail. Tên lấy nguyên từ code: `Speaker.play`, `Sprite.new`, `Text.new`… |
| `api_other` | delta | Gộp các binding vượt quá 4 slot |

**Khoá bằng 0 bị bỏ hẳn.** Dòng chỉ nói cái đã xảy ra — người đọc không phải lọc nhiễu, và cửa sổ khoẻ tốn 0 byte.

⚠️ **`heap` là MỨC, không phải delta.** Delta của một mức là vô nghĩa (và âm một nửa số lần). Giữ mẫu tệ nhất chứ không phải mẫu cuối: tụt xuống 2 KB vẫn đáng báo động dù mẫu sau đã hồi lên 40.

**Đơn vị là byte**, không phải KB: mọi trường bộ nhớ trong họ `game.*` (`arena`, `psram`, `heap_min`, `arena_pk`) đều ship byte thô trên **cả UART lẫn JSON**. Ship KB ở đây sẽ là trường duy nhất consumer phải tự nhân.

⚠️ **Tối đa 4 tên binding mỗi cửa sổ** (`ENGINE_WARN_API_SLOTS`). Vượt thì dồn vào `api_other` — một lỗi bị quy kết thô còn hơn một lỗi biến mất. Trong repo hiện có 7 tên binding gọi `game_stats_api_fail`, nhưng bốn tên khác nhau **trong cùng 10 giây** là tình huống rất hiếm.

### Vì sao delta chứ không phải tổng dồn

Số dồn không đọc được nếu thiếu mẫu số: `173` là 7‰ của phiên 24 000 frame nhưng 173‰ của phiên 1 000 frame — mà mẫu số chỉ tồn tại lúc teardown.

**Tổng phiên nằm ở `game.stop`** (`slow_pm` ‰, `api_fail` tổng); `game.warn` trả lời "**đang** tệ cỡ nào".

### Nhịp và vòng đời

Flush gọi **mỗi tick** nhưng chỉ tốn một phép so sánh cho tới khi cửa sổ đến hạn. Đặt **trước** cổng `game.running` để cửa sổ 10 s chạy theo đồng hồ riêng, không bị nhịp 30 s của `game.running` giữ lại.

Teardown gọi `engine_warn_flush(true)` **trước** `game.stop` — mấy giây cuối phiên không mất theo counter, và thứ tự stream đúng nhân quả: warn mô tả cái *dẫn tới* kết thúc, không phải cái theo sau nó.

`engine_session_stats_reset()` ở START xoá sạch cửa sổ, nên warn của game N không rò sang game N+1.

⚠️ **Tên binding là con trỏ mượn**, không copy. Mọi caller `game_stats_api_fail()` truyền literal tĩnh nên an toàn — **giữ ràng buộc đó**. Truyền chuỗi động vào là con trỏ treo khi cửa sổ đóng.

⚠️ **JSON không mang id game** — khác 4 tag `game.*` còn lại. Warn chỉ nằm giữa một `game.start` và `game.stop` của nó, cả hai đều chở `id`.

`s_decode_err_count` của `animerr` là static trong `anim.c` và **được reset trong `game_anim_reset_session()`**.

---

## 6. Đường lên từ xa

| Kênh | Nội dung | Đích thực tế | Trạng thái |
| --- | --- | --- | --- |
| **SYSMON telemetry** (`game.*`) | cả 5 tag, JSON envelope | MQTT `v1/device/<id>/metrics` | ✅ **đã nối** — xem §6.1 |
| `IPC_CMD_GAME_HEARTBEAT` (1 Hz) | rỗng | back — chỉ local, watchdog 5 s → neutral servo | không đẩy ra ngoài |
| `GAME_STARTED` / `GAME_STOP` | STARTED có `game_id`; STOP **chỉ 1 byte reason** | back state machine | subcode không serialize được — nay **không còn là nút thắt** (SYSMON chở subcode đầy đủ) |
| `IPC_CMD_GAME_RESULT` | JSON `{event}` | WebSocket A2A, **chỉ khi talk-flow** | game mở từ menu **vẫn drop kết quả** |
| Counters input/sound/servo/led/arena | đầy đủ | on-device qua Lua `*.stats()`; phần dùng cho `drop_*` đi kèm `game.stop` | — |

Head tự đẩy qua SYSMON nên **không đụng IPC, không đụng back, không topic mới** — đúng hướng khuyến nghị ban đầu thay vì nới payload IPC (vốn đụng cả hai board + version check).

### 6.1 Contract JSON trên MQTT

Envelope chuẩn SYSMON `{"key","level","data"}`, `key` = tên tag. Đường đi:

```text
engine_task → game_telemetry_bridge_send (telemetry_bridge.cpp)
            → SystemMonitor::send / sendImmediate
            → IPC_CMD_SYSTEM_MONITOR → ring 50KB PSRAM (back)
            → PublishMetrics() → v1/device/<robot_id>/metrics
```

Cả 5 tag dựng payload bằng **`snprintf` vào buffer stack** qua `engine_telemetry_emit()` — không tag nào dùng cJSON (§6.2 điều 1).

| Tag | API | Payload | `level` |
| --- | --- | --- | --- |
| `game.start` | `sendImmediate()` | 6 field số/chuỗi | `INFO` |
| `game.running` | `sendImmediate()` | 11 field, 1 dòng / 30 s | `INFO` |
| `game.stop` | `sendImmediate()` | 14 field, `err` chỉ khi có lỗi | `INFO` (norm/home) · `ERROR` (err/stall) |
| `game.error` | `sendImmediate()` | `msg` escape + cắt 160 B, kèm `frames`/`dur` | `ERROR` |
| `game.warn` | `sendImmediate()` | khoá động, bỏ khoá = 0 | `WARN` |

**Năm chỗ payload MQTT cố tình khác dòng UART** — đọc kỹ trước khi viết parser:

- **`game.stop` chở `drop_in` / `drop_snd` / `drop_nohook` / `drop_svo` / `drop_led` là field có tên**, không phải digest vị trí `drop=a/b/c/d/e`. Vị-trí-là-hợp-đồng (§3) là mẹo tiết kiệm ký tự cho UART; trên JSON nó chỉ tạo rủi ro đọc sai âm thầm. Cũng vì thế các field này **luôn có mặt**, không bỏ khi bằng 0.
- **`game.running` có thêm `id`** dù dòng UART bỏ (§2): trên UART có `game.start`/`game.stop` bao quanh làm ngữ cảnh, còn mỗi bản tin MQTT đứng độc lập. `game.start`/`game.stop` cũng dùng khoá `id` (UART là `game=`) để cả ba join được trên cùng một tên.
- **`game.stop` bỏ `tick_hz` và `psram`** — `tick_hz` = `frames`/`dur`, consumer tự chia. `psram` lấy mẫu **sau** khi teardown trả arena nên nó phản ánh baseline của `game.start` chứ không phải phiên; đường cong thật nằm ở `game.running`. UART giữ cả hai cho mắt đọc.
- **`game.warn` không ship id game** (§5) — nó nằm giữa cặp start/stop vốn đã chở `id`, và là tag tần suất cao nhất. `detail` vì thế luôn ship khi có: với `overrun`/`heaplow` đó là id game, với `api_fail` là tên binding, với `animerr` là `"decode"`. UART luôn in `detail=` (in `-` khi NULL).
- **`game.warn` dùng khoá ĐỘNG** — xem §5. Mỗi loại lỗi một khoá (`overrun`, `animerr`, `heap`, và một khoá cho mỗi **tên binding** đã fail). Khoá bằng 0 bị bỏ hẳn, nên schema không cố định: consumer phải duyệt khoá, không được giả định danh sách. `heap` là **mức tính bằng byte**, các khoá còn lại là **delta trong cửa sổ 10 s**.

`slow_pm` giữ nguyên tên đầy đủ trên JSON (UART `game.stop` là `slow_pm`) để không ai nhầm với `slow_n` thô của `game.running`.

⚠️ **Cả 5 tag `game.*` đều gửi `sendImmediate()`** — toàn bộ họ này bỏ qua ring gom-lô của head (flush mỗi 5 s, batch ≤10, `SYSMON_FLUSH_INTERVAL_MS`).

| Tag | Vì sao immediate |
| --- | --- |
| `game.start` · `game.stop` | **Một dòng mỗi phiên** — batching không mua được gì, mà ring gom-lô giữ mất bản ghi mở/đóng phiên. Crash trong vài giây đầu (loại hay gặp nhất) sẽ mang luôn `game.start` đi |
| `game.error` | Game đã hỏng, crash có thể tới ngay sau |
| `game.warn` | Dấu hiệu *sớm* của sự cố mà bước sau thường là crash (`heap` → "No mem" → `xTaskCreate` fail). Cửa sổ gộp đã chặn ở **1 dòng / 10 s** nên bỏ qua lô không thể làm ngập link |
| `game.running` | Là tag "định kỳ" **chỉ trên danh nghĩa**: 1 dòng / 30 s (hoặc 45×FPS frame), KHÔNG phải mỗi frame. Nhét một tag 30 s vào ring gom-lô chỉ cộng thêm độ trễ mà không giảm được số message, và để một cú reboot nuốt mất đúng cửa sổ sắp giải thích crash |

**Hệ quả:** toàn bộ bản ghi của một phiên đi cùng một đường, nên chúng **không còn xen kẽ với lô metric hệ thống**. Thứ tự đến trong họ `game.*` giờ khớp thứ tự phát.

### ⚠️ Mất mạng thì MẤT DỮ LIỆU — đường offline không hoạt động

`SystemMonitor::send` có nhánh rơi về `OfflineLogManager::WriteLog`, nhưng nhánh đó **không bao giờ chạy**:

```c
bool SystemMonitor::s_networkConnected = true;   // khoi tao true
```

Cửa duy nhất đổi cờ này là `SystemMonitor::SetNetworkStatus()`, và hàm đó **không có caller nào trong repo** — chỉ có định nghĩa và khai báo. Head cũng không tự biết trạng thái mạng (WiFi/MQTT nằm ở back, head chỉ nhận IPC), nên không có nguồn tự nhiên nào gọi nó.

Hệ quả: `WriteLog` chưa từng chạy, `/sd/system/offline_log.bin` luôn rỗng, và **telemetry của phiên chơi ngoài vùng phủ bị mất hẳn** — không được đồng bộ lại sau.

Muốn bật đường này thì cần **hai** việc, không phải một:

1. Nối `SetNetworkStatus()` vào tín hiệu mạng từ back qua IPC.
2. Nâng `MAX_LOG_MSG_LEN` — hiện là **128 B**, trong khi payload thật: `game.warn` 91 B (lọt), `game.start` 134 B, `game.error` 185 B, `game.running` 203 B, `game.stop` 308 B. Tức **4/5 tag bị `strncpy` cắt cụt thành JSON vỡ**. Đổi hằng số này là đổi `sizeof(OfflineLogEntry_t)`, mà `Init()` suy số bản ghi bằng `file_size / sizeof(entry)` → phải versioning layout, nếu không file cũ trên SD đọc ở stride mới sẽ phát lại rác.

Ngoài ra `SyncToServer` bọc `entry.message` vào `"msg":"..."` — nhưng `entry.message` **vốn đã là JSON hoàn chỉnh**, nên mọi dấu `"` bên trong sẽ phá JSON lồng. Cần sửa cùng lúc.

`game.error` tự chở `frames`/`dur` để **đứng một mình được**: khi crash không bao giờ tới teardown thì không có `game.stop` nào cả, và dòng này là bản ghi duy nhất còn lại của phiên.

### 6.2 Ràng buộc khi sửa đường này

1. **Không tag nào được dùng cJSON.** Mọi producer SYSMON khác trong firmware này đều tự format JSON, và một cặp `malloc`/`free` trên con head vốn phân mảnh internal heap chính là thứ mà `game.running`/`heaplow` sinh ra để phát hiện — `game.error` còn chạy đúng lúc heap có thể đã cạn, nên đường báo lỗi không được phụ thuộc allocator. Kiểm bằng `nm -u engine_core.c.obj`: chỉ được thấy `snprintf`/`vsnprintf`.
   Đổi lại `snprintf` không tự escape: chuỗi tự do phải qua `engine_json_escape()` (hiện chỉ `msg` của `game.error`). `detail` của `game.warn` ship thô vì mọi caller truyền tên binding / game id / literal — giữ nguyên ràng buộc đó hoặc escape.
2. **Gọi uplink SAU `ESP_LOGx`**, để chi phí rơi vào đúng chỗ §0 đã quy cho việc log (`gap_us` của frame kế), giữ `tick_us` trung thực.
3. **`telemetry_bridge.cpp` là Tier 2 — KHÔNG được thêm weak twin** vào `host_seams.c`. Weak def sẽ thoả mãn `-Wl,-u,game_telemetry_bridge_send` và để `--gc-sections` bỏ strong def: telemetry lặng lẽ quay về UART-only, không lỗi link. Kiểm bằng map file (`game_telemetry_bridge_send` phải có địa chỉ `.text`), không tin build pass.
4. **Arduino `String` chỉ được dựng và tiêu thụ trong cùng một lời gọi**, tuyệt đối không nhét vào struct đi qua queue — repo này đã ship một lần lỗi `String` copy bytewise qua `xQueueSend` gây double-free khi vượt SSO.
5. Payload quá cỡ bị **drop** kèm `ESP_LOGW`, không cắt cụt (JSON hỏng tệ hơn mất dòng). Bốn mốc, **cỡ phải theo đúng thứ tự này**:

   | Mốc | Giá trị | Ở đâu | Vai trò |
   | --- | --- | --- | --- |
   | `SYSMON_LARGE_JSON_WARN_BYTES` | 480 B | `systemmonitor.h` | Chỉ cảnh báo |
   | `GAME_TELEMETRY_JSON_MAX` | 512 B | `engine_core.c` | Buffer dựng payload |
   | `SYSMON_JSON_MAX_BYTES` | 640 B | `systemmonitor.h` | Trần cứng ở bridge |

   Cỡ lấy theo **worst case**, không phải typical: `game.stop` bình thường ~308 B nhưng lên **454 B** khi game id chạm `GAME_ID_FIELD_LEN` (31 ký tự) và counter bão hoà. Buffer undersize **drop im lặng** trong khi dòng UART vẫn in — nay `engine_telemetry_emit` log `telemetry drop key=... need=... cap=...` mỗi lần tràn.

   ⚠️ **Thêm trường vào `game.stop` thì phải đo lại worst case và chỉnh cả 3 mốc.** Đợt thêm `panel_*` đẩy worst case 371 → 454 B, vượt buffer 448 cũ; nếu không đo lại thì mọi phiên có game id dài sẽ mất `game.stop` mà không ai biết.

   `MAX_LOG_MSG_LEN` (128 B, `offline_log.h`) **không nằm trong danh sách này** vì đường offline hiện không chạy (§6.1). Nếu bật nó lên thì đó là mốc thứ tư và phải nâng theo.
6. **`engine_task` chạy trên stack + TCB tĩnh** (`xTaskCreateStaticPinnedToCore`, `.bss` internal). Lý do: launch game từng fail `ESP_ERR_NO_MEM` khi internal heap phân mảnh dù tổng free còn dư. Hai ràng buộc đi kèm:
   - Stack **phải internal, không PSRAM** — `game_pack_load` → `game_audio_get_volume_db` chạm NVS, tức có lúc cache tắt. TCB thì `portVALID_TCB_MEM` bắt buộc.
   - Buffer chỉ được tái dùng khi task cũ đã **rời hẳn stack**. `game_engine_deinit()` trả về ngay khi task give `deinit_done`, mà lệnh đó chạy *trên chính stack đó* và còn trước `vTaskDelete(NULL)` — nên "deinit xong" **không** đồng nghĩa "stack rảnh". Guard là cờ `s_engine_task_exited` do task tự set sát `vTaskDelete` (đặt **trước** `xSemaphoreGive` để init trên core kia thấy được; clear **trước** `xTaskCreateStatic` để không đè mất cờ của task đã kịp chạy). Đừng thay bằng `eTaskGetState`: `eDeleted` xuất hiện lúc TCB vào delete-list, sớm hơn thời điểm task rời stack.

---

## 7. Bảng chẩn đoán — triệu chứng → kết luận

Đọc theo thứ tự: **§7.1 phân loại nhanh** (một dòng `game.stop` là đủ) → **§7.2 bảng đầy đủ** → **§7.3 cây quyết định** cho ba ca hay nhầm nhất.

Giá trị mốc dùng trong bảng, lấy từ `sdkconfig` thật:

| Hằng số | Giá trị | Suy ra |
| --- | --- | --- |
| `CONFIG_GAME_ENGINE_TARGET_FPS` | 30 | budget frame = **33 333 µs** |
| `CONFIG_GAME_ENGINE_LUA_WATCHDOG_US` | 1 500 000 | trần **1,5 s** mỗi pcall |
| `CONFIG_GAME_ENGINE_STALL_DETECT_SEC` | 5 | `engine_task` lỡ tick **5 s** → `stall` |
| `CONFIG_GAME_ENGINE_TASK_PRIO` | 5 | LVGL 6 và audio 10 **đều cao hơn** → preempt được |
| `GAME_HEAP_INT_LOW_BYTES` | 12 KB | ngưỡng `heaplow` |

### 7.1 Phân loại nhanh theo `end=`

| `end=` | Nghĩa | Việc cần làm |
| --- | --- | --- |
| `norm` | Game tự gọi kết thúc | ⚠️ **Không chứng minh chạy đúng** — §8.1. Kiểm `api_fail` và `dur` trước khi yên tâm |
| `home` | Thoát hợp tác nhưng không phải game tự kết thúc | Bình thường nếu `dur` đủ dài. `dur` ngắn hàng loạt = game bị bỏ (§8.3) |
| `err` | Có subcode lỗi | Đọc `err=` + `game.error` cùng phiên → §7.2 nhóm C |
| `stall` | `engine_task` lỡ tick 5 s | **Nặng nhất** — deadlock C-binding, Lua watchdog không thấy → §7.2 hàng C6 |

### 7.2 Bảng đầy đủ

Cột "Dấu hiệu" là điều kiện **cùng xuất hiện**; chỉ một dấu hiệu lẻ thường chưa đủ kết luận.

#### Nhóm A — Hiệu năng (game chạy nhưng không mượt)

| # | Dấu hiệu | Kết luận | Phân biệt với | Hành động |
| --- | --- | --- | --- | --- |
| A1 | `tick_us` > 33 000 · `gap_us` ≈ `tick_us` · `slow_pm` cao · `p95` cao | **Game tự nó nặng** — thân tick vượt budget | A2: ở đây `tick_us` mới là thủ phạm | Tối ưu `on_tick` của pack: giảm sprite, giảm vòng lặp Lua |
| A2 | `tick_us` **nhỏ** (< 15 000) · `gap_us` **lớn** (> 40 000) · `slow_pm` cao | **Bị task khác giành CPU** — engine prio 5 thua LVGL 6 và audio 10 | A1: `tick_us` nhỏ chứng minh game không nặng | Không sửa pack. Soi audio/LVGL đang làm gì cùng lúc |
| **A2b** | `tick_hz` ~30 nhưng **`draw_pm` < 800** | **Màn hình mới là nghẽn, không phải game** — engine tick đủ, LCD không theo kịp | A1/A2: cả hai ca kia `tick_hz` cũng tụt | Giảm diện tích vùng bẩn mỗi frame. **Đừng tối ưu `on_tick`** |
| **A2c** | `draw_pm` = 0 mà `tick_hz` bình thường | **Không frame nào ra LCD** | A2b: A2c la tat han, khong phai cham | `lvgl_timer` tự ngủ 1000 ms khi AnimationPlayer chạy GIF — kiểm có anim nào đang chiếm màn hình |
| A3 | `gap_us` vọt **đều đặn theo nhịp log** · `tick_us` bình thường | **Chính dòng log gây spike** — UART blocking rơi vào `gap_us` frame kế (§0) | A2: A3 có chu kỳ khớp nhịp `game.running` | Bỏ qua, hoặc nâng baud (§12) |
| A4 | `slow_pm` cao nhưng `p95` **thấp** | **Chậm đều sát ngưỡng** — nhiều frame vượt nhẹ | A5: p95 phân biệt hai ca | Cắt bớt việc mỗi frame; game đang chạy sát trần |
| A5 | `slow_pm` thấp nhưng `p95` **rất cao** | **Thi thoảng vấp nặng** — phần lớn frame ổn | A4 | Tìm sự kiện hiếm: load asset giữa chừng, GC Lua |
| A6 | `tick_hz` ổn ~30 nhưng `frames` << `dur × 30` | **Game treo từng đoạn** — nhịp trung bình che mất | A1–A5: các ca kia `frames` khớp `dur` | So `frames` từng cửa sổ `game.running` để khoanh vùng đoạn treo |

#### Nhóm B — Bộ nhớ

| # | Dấu hiệu | Kết luận | Phân biệt với | Hành động |
| --- | --- | --- | --- | --- |
| B1 | `game.warn` có khoá `heap` · `heap` tụt bậc thang qua các `game.running` | **Internal heap sắp cạn** — dấu hiệu mạnh nhất theo bug pattern dự án | B2: B1 là internal, B2 là arena Lua | Xem `heap_min` cuối phiên. < 8192 byte thì `xTaskCreate` sắp fail "No mem" |
| B2 | `arena` bò lên đều qua các cửa sổ · `arena_pk` >> `arena` lúc start | **Lua leak trong pack** — cấp mà không thả | B1: arena là PSRAM của Lua, không phải internal | Soi pack: bảng Lua giữ tham chiếu, sprite không giải phóng |
| B3 | `arena` ≈ `arena_pk` ≈ `arena` lúc start | **Lành** — pack cấp hết ở init rồi giữ nguyên | B2 | Không cần làm gì |
| B4 | `psram` tụt dần **giữa các phiên** (so `game.start` liên tiếp) | **PSRAM không hồi sau teardown** — rò qua nhiều lượt chơi | B2: B2 trong một phiên, B4 xuyên phiên | So `psram` của `game.start` phiên N và N+1 |
| B5 | `err=OOM` · `heap_min` rất thấp · `arena_pk` chạm trần | **Hết bộ nhớ thật** khi đang chạy | C3: OOM là hệ quả, không phải lỗi script | Giảm asset của pack hoặc nâng arena budget |
| B6 | `heap_min=0` mà phiên rất ngắn | **Chưa lấy được mẫu nào** — không phải hết heap | B1: `0` ở đây là sentinel `UINT32_MAX` (§3 ràng buộc 4) | Bỏ qua; phiên chưa đủ `GAME_MEM_SAMPLE_FRAMES` frame |

#### Nhóm C — Lỗi và crash

| # | Dấu hiệu | Kết luận | Phân biệt với | Hành động |
| --- | --- | --- | --- | --- |
| C1 | `game.error phase=load` · `code=PACK_NOT_FOUND\|PACK_MANIFEST\|VALIDATOR` | **Pack hỏng hoặc thiếu** — chưa bao giờ chạy | C2: khác ở chỗ VM đã tạo được chưa | Kiểm `manifest.json`, đường dẫn, CRC validator |
| C2 | `game.error phase=load` · `code=LUA_LOAD\|LUA_VM_CREATE` | **Script lỗi cú pháp** hoặc **không cấp nổi VM** | C1: C1 là file/manifest, C2 là Lua | Đọc `msg=` — có traceback chỉ đúng dòng |
| C3 | `game.error phase=on_tick\|on_input\|on_sound_end` · `code=LUA_RUNTIME` | **Bug logic trong pack** — `phase` chỉ đúng callback nào chết | B5: B5 là OOM, C3 là lỗi script | `msg=` có traceback đầy đủ. Sửa pack |
| C4 | `code=LUA_WATCHDOG` · `end=err` | **Một pcall chạy quá 1,5 s** — vòng lặp vô hạn trong Lua | C6: watchdog **bắt được** nghĩa là Lua còn chạy | Tìm vòng `while` không thoát trong callback |
| C5 | `game.error phase=render` · `code=RENDER_INIT` | **Không vào được màn hình game** | C1/C2: pack đã load xong mới tới bước này | Kiểm LVGL/renderer, thường do hết PSRAM |
| C6 | `end=stall` · `phase=stall` · `msg="engine_task stalled..."` | **Deadlock C-binding** — `engine_task` đứng hẳn 5 s, Lua watchdog **không** thấy | C4: C4 là Lua kẹt, C6 là native kẹt | Nặng nhất. `msg` không có tên binding — đọc `last_binding_name` đường khác (§4) |
| C7 | `game.error` tới mà **không có** `game.stop` theo sau | **Crash trước khi teardown** — reset/panic | C3: C3 vẫn có `game.stop end=err` | Dùng `frames`/`dur` trong chính `game.error` (§6.1). Soi coredump nếu có |

#### Nhóm D — Hỏng âm thầm (log trông sạch)

| # | Dấu hiệu | Kết luận | Phân biệt với | Hành động |
| --- | --- | --- | --- | --- |
| D1 | `end=norm` · **`api_fail` > 0** | **Binding fail mà script không kiểm** — sprite không vẽ / không tiếng / chữ không hiện | D2: D1 có bằng chứng số, D2 không | `game.warn` có khoá mang **tên binding** (vd `"Speaker.play":2`) chỉ đúng API nào. Sửa pack: kiểm giá trị trả về |
| D2 | `end=norm` · `api_fail=0` · **người chơi báo sai** | **Điểm mù kiến trúc** (§8.2) — hoặc `api_fail` chưa nối binding đó | D1 | 6/9 file bind chưa nối counter (§10). Không kết luận được từ log |
| D3 | `drop` vị trí 3 (`nohook`) > 0 | **Audio pipeline nghẽn** — hay kèm treo GIF | D4 | Soi audio; đây là triệu chứng đã gặp nhiều lần trên head |
| D4 | `game.warn` có khoá `animerr` · `end=norm` | **Anim chết giữa chừng** nhưng game vẫn chạy tiếp | C1: lỗi *mở* anim là `game.error`, không phải warn | Kiểm file GIF/MJPEG; "chết giữa chừng" ≠ "không bao giờ mở được" |
| D5 | `drop` vị trí 1 (`in`) > 0 | **Input rớt** — SPSC ring đầy, nút bấm mất | D2: D5 có bằng chứng, D2 không | Game xử lý input quá chậm, hoặc bấm quá nhanh |
| D6 | `drop` vị trí 4/5 (`svo`/`led`) > 0 | **Back từ chối servo / LED ring đầy** | — | Không ảnh hưởng gameplay, nhưng mất hiệu ứng vật lý |

#### Nhóm E — Bất thường về phiên

| # | Dấu hiệu | Kết luận | Hành động |
| --- | --- | --- | --- |
| E1 | `load` > 3000 ms | **Pack nặng hoặc SD chậm** — người chơi chờ lâu | Giảm asset, kiểm thẻ SD |
| E2 | Đa số phiên `dur` < 10 s · `end=norm\|home` | **Game bị bỏ ngay** — không giữ chân được | Không phải lỗi kỹ thuật (§8.3). Vấn đề thiết kế game |
| E3 | `frames=0` · `dur` > 0 | **Chưa tick lần nào** — hỏng ngay khi vào | Ghép với `game.error` cùng phiên |
| E4 | `ccalls` sát 30 (`LUAI_MAXCCALLS`) | **Sắp tràn C-stack Lua** — mỗi tầng ~486 B | Giảm độ sâu đệ quy / callback lồng nhau trong pack |
| E5 | `hwm_engine` < 3000 B | **Stack `engine_task` sắp cạn** (tĩnh 24 KB) | Đo thật hiện là 6328 B (§10). Tụt sâu hơn = có đường gọi mới ăn stack |

### 7.3 Ba ca hay nhầm nhất

**Giật: game nặng hay bị preempt?** — chỉ nhìn `slow_pm` là **không** kết luận được.

```text
slow_pm cao / người chơi báo giật?
├─ draw_pm < 800   → A2b  MÀN HÌNH nghẽn   → giảm vùng bẩn, ĐỪNG tối ưu on_tick
├─ draw_pm = 0     → A2c  không frame nào ra → kiểm AnimationPlayer chiếm màn
├─ tick_us > 33000        → A1   game tự nặng      → tối ưu pack
├─ tick_us < 15000        → A2   bị preempt        → soi audio/LVGL, ĐỪNG sửa pack
└─ gap vọt theo chu kỳ log → A3  chính log gây ra → bỏ qua
```

**Hỏi `draw_pm` trước.** Ba nhánh dưới đều nói về `engine_task`; nếu nghẽn nằm ở `lvgl_timer` thì cả ba đều dẫn sai hướng.

**Treo: Lua kẹt hay native kẹt?** — hai đường sửa hoàn toàn khác nhau.

```text
game đứng hình
├─ code=LUA_WATCHDOG (1,5 s/pcall) → C4  vòng lặp trong Lua   → sửa script
├─ end=stall (5 s lỡ tick)         → C6  deadlock C-binding   → soi native
└─ frames << dur×30 nhưng vẫn tick → A6  treo từng đoạn       → khoanh cửa sổ
```

**Phiên "sạch" có đáng tin không?**

```text
end=norm
├─ api_fail > 0        → D1  có binding fail → sửa pack
├─ api_fail = 0        → chưa kết luận được: 6/9 file bind chưa nối counter
│                        → D2, phải test thủ công
└─ dur < 10 s hàng loạt → E2  bị bỏ ngay, không phải lỗi kỹ thuật
```

### 7.4 Ghép nhiều tag cho một phiên

Cả ba tag vòng đời dùng khoá `id` trên JSON nên join được. Trình tự đọc khi điều tra:

1. `game.start` — baseline `arena`/`heap`/`psram` và `load`.
2. Chuỗi `game.running` — **xu hướng**: `heap` tụt bậc thang? `arena` bò lên? `gap_us` vọt?
3. `game.warn` — cảnh báo sớm, **có trước** khi hỏng.
4. `game.error` — nếu có; `phase` chỉ đúng chỗ chết.
5. `game.stop` — tổng kết; so `arena_pk`/`heap_min` với baseline bước 1.

Cả 5 tag `game.*` nay đều immediate (§6.1), nên **thứ tự đến khớp thứ tự phát** — không còn cảnh `game.running` của phút trước tới sau `game.stop`. Vẫn đừng coi đó là bảo đảm tuyệt đối: ring phía back xả tối đa 5 bản ghi mỗi 2 s, và mất/nối lại MQTT có thể đảo lô. `game.error` tự chở `frames`/`dur` (§6.1) để không phụ thuộc thứ tự; `game.warn` không mang mốc thời gian nào nên phải ghép bằng timestamp phía server.

⚠️ **Phiên đồng bộ lại từ offline log không giữ thứ tự thời gian với phiên online**, và `game.stop`/`game.error` worst-case có thể bị drop khi mất mạng (§6.2 điều 5). Thiếu `game.stop` mà có `game.start` **không** chứng minh crash — có thể chỉ là bản ghi bị drop.

---

## 8. GIỚI HẠN — log này KHÔNG bắt được gì

### 8.1 Binding fail chỉ tồn tại trong Lua-space

Điểm mù nghiêm trọng nhất về mặt thực tế.

Binding trả `(nil, "msg")` là **thiết kế có chủ đích** (§8) — lỗi **có** message, nhưng message đi về Lua-space chứ không ra UART. Nếu script không kiểm giá trị trả về (rất hay xảy ra khi port game): sprite = nil → **không vẽ gì**; `Speaker.play()` false → **không có tiếng**; text slot pool đầy → **chữ không hiện**; font cache đầy → chỉ `ESP_LOGW`. Không trường hợp nào crash.

Mọi trường hợp trên, `game.stop` báo **phiên hoàn toàn sạch**: `end=norm`, `slow_pm=0`, không drop. Đây chính xác là kịch bản "chơi thấy sai mà log không thấy gì".

→ `api_fail` sinh ra để bịt điểm mù này. **Chưa nối đủ binding** (§9) nên `api_fail=0` hiện chưa phải bằng chứng.

### 8.2 Không có tín hiệu nào về tính đúng đắn của gameplay

**Không key nào** bắt được: game treo một màn hình, điểm số tính sai, va chạm không ăn, nút bấm không phản hồi dù input tới đủ, sprite vẽ sai vị trí, game không bao giờ kết thúc được.

Firmware **không có khái niệm "game đang chạy đúng"** — chỉ biết "task còn tick". Stall detector chỉ bắt `engine_task` wedged hoàn toàn; game vẫn tick 30 FPS mà logic chết cứng thì hoàn toàn vô hình.

**Giới hạn kiến trúc, không đóng được từ phía firmware** — firmware không biết luật chơi. Muốn phủ thì game phải tự khai báo tiến trình; còn lại vẫn phải test thủ công.

### 8.3 `end=norm` gộp hai tình huống khác nhau

Game tự kết thúc và người chơi bỏ giữa chừng không phân biệt được. Một game mà 90 % phiên `dur=8s end=norm` là dấu hiệu bị bỏ ngay, nhưng đọc log thì y hệt chơi trọn vẹn.

Tách được sẽ tốt, nhưng **hiện chỉ có một hằng số** `GAME_ENGINE_STOP_REASON_CLEAN_END = 1u` (`game_engine.h:169`), không có enum, và giá trị này **đi trên wire IPC 1 byte** sang back → phải xác minh back xử lý giá trị lạ trước, nếu không thành thay đổi cả hai board.

### 8.4 ⚠️ `dt` truyền vào `on_tick` là HẰNG SỐ — bug chưa sửa

```c
lua_vm_call_on_tick(1000 / CONFIG_GAME_ENGINE_TARGET_FPS)   // = 33, luôn luôn
```

`engine_core.c:982`

Game **luôn** nhận `dt=33` bất kể frame thật mất bao lâu. Chạy 15 FPS thì mỗi frame thật 66 ms nhưng script vẫn tính như 33 ms → **simulation trôi chậm một nửa so với đồng hồ thật**: vật rơi chậm, đếm giờ sai, animation lệch.

**Không metric nào trong doc này phát hiện được** — mọi con số vẫn đẹp vì engine tick đúng, chỉ có ngữ nghĩa thời gian bên trong game là sai.

Chưa sửa vì nó **đổi hành vi mọi pack đã viết**: pack nào đang bù trừ cho `dt` cố định sẽ chạy khác đi. Cần đợt riêng, có pack thật để kiểm chứng — không gộp vào đợt telemetry.

### 8.5 ⚠️ Cờ lifecycle kẹt → `engine_busy` vĩnh viễn (chưa rõ nguyên nhân gốc)

Quan sát thật (log 2026-08-14): 3 lần bấm mở game liên tiếp lúc 15:02 đều trả `reason=engine_busy`, **26 phút sau một teardown hoàn toàn sạch** (14:36 có đủ `deinit_begin` → `deinit_done` → `deinit complete`). Game không mở lại được cho tới khi reboot. Giữa hai mốc chỉ có SLEEP + WiFi flap.

**Dấu hiệu nhận biết trong log:** dòng `GAME_START` **không kèm `init_ok`**.

```text
14:16:31  GAME_START → init_ok → task_started → start game    ✅ bình thường
15:02:24  GAME_START → game_engine_start failed: 259          ❌ thiếu init_ok
```

Thiếu `init_ok` nghĩa là `game_engine_init()` rơi vào **nhánh sớm**:

```c
if (s_engine.initialized) {
    engine_set_event_cb(cb, user_data);
    return ESP_OK;        // ← khối reset cờ nằm SAU dòng này
}
```

Khối reset `running`/`start_pending`/`exiting`/... **bị bỏ qua hoàn toàn**. Một cờ kẹt từ teardown dở dang sẽ sống mãi, và mọi launch sau đó đều bị `game_engine_start` từ chối.

**Đã vá phòng thủ**, chưa vá nguyên nhân gốc:

1. Nhánh sớm tự phục hồi khi gặp trạng thái **không thể hợp lệ** — `start_pending=1` mà `running=0` và mailbox rỗng (task xoá cờ này ở mọi đường thoát, nên tổ hợp đó chứng tỏ cờ đã mồ côi). Log `init_stale_flags` mức ERROR.
2. `start_reject` in rõ cờ nào chặn: `running=? start_pending=? lifecycle=? init=?`. Trước đây chỉ có mã `259`, không phân biệt được "game đang chạy thật" với "cờ kẹt".
3. `deinit_timeout` in thêm `- engine wedged until reboot`. Đường này để `lifecycle=DEINITING` **cố ý** và **không được "phục hồi"**: task đang kẹt có thể tỉnh lại và chạm mailbox đã free.

**Còn thiếu:** chưa xác định được cái gì đặt `initialized=true` trở lại trong khoảng đó. Log mới sẽ chỉ ra ở lần tái hiện tiếp theo.

---

## 9. Hợp đồng lỗi của binding

Đọc trước khi động vào binding — **trả `(nil, msg)` là thiết kế, không phải bug.**

| Loại lỗi | Xử lý | Ví dụ |
| --- | --- | --- |
| **Input validation** (sai kiểu, path không an toàn) | **raise** — STRICT | `luaL_argerror` khi path unsafe (`bind_sprite.c:69-72`) |
| **Runtime failure** (file thiếu, decode fail, OOM, pool đầy) | trả `(nil, "msg")` | `asset_load_rgb565` fail (`bind_sprite.c:76-80`) |
| **Mutator tolerant** (speaker/servo/led) | trả `false` | contract trong `bindings_util.h` |

**Ràng buộc tuyệt đối:** đếm `api_fail` **không được đổi giá trị trả về**. Đổi `(nil, msg)` thành raise sẽ **vỡ mọi pack** đang viết `if not spr then ... end`. Chỉ thêm counter + log.

Chỉ đếm ở nhánh **runtime failure** — nhánh input-validation đã raise và đi đường `game.error`, đếm nữa là tính hai lần.

> `bindings_util.h` tham chiếu `docs/standards/pika-engine-binding-style.md` — **file không tồn tại** trong repo. Contract thật hiện chỉ nằm trong comment tại chỗ.

---

## 10. Trạng thái triển khai

| Hạng mục | Trạng thái |
| --- | --- |
| Vá SYSMON task-name | ✅ 6 entry, dùng tên **đã cắt 15 ký tự** |
| `game.start` + `game.stop` + accumulator | ✅ `game_session_stats_t` trong `engine_state_t` |
| `game.error` + `msg=` traceback | ✅ 4 call site: `load` · `render` · `stall` · tick-loop |
| `game.running` (thay `tick stat`) | ✅ nhịp 30 s hoặc 45× FPS frame |
| Hạ tầng `game.warn` gộp 10 s (khoá động) + counter `api_fail` | ✅ |
| Kind tự phát: `overrun`, `api_fail`, `heaplow`, `animerr` | ✅ **4 kind = toàn bộ enum** |
| Bỏ log cũ (`psram phase=`, `tick stat`, `load_fail`, `teardown_fatal`) | ✅ |
| Hạ ngân sách stack Lua theo số đo thật | ✅ `TASK_STACK` 24576 · `LUAI_MAXCCALLS` 30 |
| Đẩy `game.*` lên MQTT qua SYSMON | ✅ **cả 5 tag** — §6.1, không đụng back/IPC |
| Uplink không phụ thuộc allocator | ✅ `snprintf`, 0 ký hiệu cJSON trong `engine_core.c.obj` |
| Stack `engine_task` hết fail vì phân mảnh | ✅ static `.bss` + guard `s_engine_task_exited` (§6.2 điều 6) |
| Đường offline (mất mạng vẫn giữ telemetry) | ⬜ **KHÔNG hoạt động** — `SetNetworkStatus()` không có caller, `WriteLog` chưa từng chạy. Bật lên cần 3 việc, xem §6.1 |
| Tràn buffer telemetry không còn im lặng | ✅ `GAME_TELEMETRY_JSON_MAX` 384→448 + `ESP_LOGW` khi drop |
| Trường cùng tên khác đơn vị/ngữ nghĩa | ✅ `slow_n` · `hwm_engine` — §11 |
| **Đo được frame màn hình thật** | ✅ `draw_pm` ở `game.stop`, đếm ở `LV_EVENT_RENDER_READY` |
| **Sửa `display.fps` toàn fleet = 0** | ✅ counter cũ nằm trong `lvgl_flush_cb` mà `LVGL_USE_IRAM_BUFFER=1` không dùng; nay hook event LVGL + gate `REFR_REQUEST` |
| **`slow_pm` đếm cả frame trễ do preempt** | ✅ đổi từ `tick_us > budget` sang `gap > 34 ms` (mốc Android Vitals) |
| Tên trường nói đúng thứ đang đo | ✅ `work`→`tick_us`, `fps`→`tick_hz` (§2 kiến trúc đo) |
| Bucket `p95` phân giải quanh 33 ms | ⬜ **chưa** — vùng 33–50 ms vẫn sụp vào 1 bucket (Đợt 2) |
| **`display.fps` lấy mẫu từng giây** | ✅ `mean`/`p5`/`peak`/`samples` thay 1 số trung bình 30 s che mất freeze |
| **Đo được FPS lúc phát GIF** | ✅ đường LovyanGFX nạp cùng ring qua `display_fps_record_anim_frame()`; trước đây Learn/A2A không có metric nào |
| **Sửa `display.flush.ms` chưa từng gửi** | ✅ cùng lỗi callback không dùng; nay là `display.flush.us` đo trong `minimal_lvgl_flush_cb` (0 lần xuất hiện trên 4 log cũ) |
| **`game.error phase=launch`** | ✅ "game không mở được" trước đây KHÔNG có telemetry nào — mọi điểm phát đều nằm trong engine_task |
| Nguyên nhân gốc cờ lifecycle kẹt (§8.5) | ⬜ **chưa** — mới vá phòng thủ + thêm log chẩn đoán |
| **Hậu tố mang đơn vị** | ✅ `slow_n` (đếm) vs `slow_pm` (‰) vs `draw_pm` (‰) — không còn 2 dòng cùng tên `over` khác đơn vị |
| Gửi histogram thay window max | ⬜ chưa — percentile/max không cộng được khi aggregate fleet |
| **`dt` truyền vào `on_tick` là hằng số 33** | ⬜ **BUG chưa sửa** — xem cảnh báo §8.4 |
| `api_fail` nối vào binding | ⚠️ **7 điểm / 3 file trong 9 file bind** |
| Kind `wdog`/`oom`/`snd_nohook`/`svo_reject`/`voicedrop` | ⬜ **chưa có trong enum** (không chỉ thiếu call site) |
| `end=quit` tách khỏi `end=norm` (§8.3) | ⬜ chưa — cần kiểm back trước |

**`api_fail` đã nối 7 điểm:** `bind_sprite` 4 (`Sprite.create` · `Sprite.new` · `Sprite.image` · `Sprite.solid`), `bind_speaker` 2 (`Speaker.play/alias` · `Speaker.play`), `bind_engine` 1 (`Text.new`).

**Chưa nối:** `bind_anim` · `bind_input` · `bind_led` · `bind_ranking` · `bind_servo` · `bind_voice` (0 điểm mỗi file), và các nhánh runtime-failure còn lại của `bind_engine`. Ưu tiên 3 file đã làm vì là đường hỏng-âm-thầm hay gặp nhất khi port.

⚠️ **5 kind chưa dùng được là thiếu enum, không phải thiếu call site.** Muốn thêm `wdog`/`oom`/`snd_nohook`/`svo_reject`/`voicedrop` thì phải nối vào `engine_warn_kind_t` **và** `s_warn_kind_name[]` cùng lúc — hai mảng phải khớp thứ tự, lệch nhau là in sai tên kind mà không có cảnh báo compile.

### Mức kiểm chứng trên máy thật

Đã có **89 mẫu `game.running`** từ pack thật. Kết quả dùng được ngay: đỉnh stack `engine_task` **6328 B** và `ccalls_peak ≤ 2` — cách trần rất xa, đó là căn cứ hạ `TASK_STACK` 32768 → 24576 và `LUAI_MAXCCALLS` 40 → 30 (giữ cặp ràng buộc ~486 B/tầng, chốt ở 85 % stack). **Không hạ tiếp xuống 20480**: công thức khi đó cho 90 %, ăn hết biên cho LVGL invalidate + `luaL_traceback`.

Stack này nay là **buffer tĩnh `.bss` internal**, không cấp từ heap (§6.2 điều 6), nên 24576 B là hằng số thường trú chứ không còn phụ thuộc độ phân mảnh lúc launch. Uplink cộng thêm `GAME_TELEMETRY_JSON_MAX` (512 B) + buffer escape 160 B của `game.error` vào đỉnh stack — đã nằm trong biên trên, nhưng phải tính lại nếu nới hai hằng đó.

Bốn tham số dưới đây vẫn **chưa chốt** — 89 mẫu đủ để kết luận về stack nhưng chưa phủ đủ tình huống hỏng:

| Tham số | Giá trị hiện tại | Cần xác nhận |
| --- | --- | --- |
| Ngưỡng `heaplow` | 12 KB | Có spam liên tục hay im hoàn toàn? Cần một phiên **thật sự cạn heap** mới biết |
| Cửa sổ gộp `game.warn` | 10 s | Quá thưa (chậm phát hiện) hay quá dày (ngập UART)? |
| Bucket `p95` | 8 mốc, 2 ms–50 ms + overflow | Đủ phân giải quanh 33 ms? |
| Nhịp `game.running` | 30 s hoặc 45× FPS frame | Có bỏ sót diễn biến giữa hai dòng? **89 mẫu hiện có đo ở nhịp 5 s cũ** — chưa có mẫu nào ở 30 s |

Ngưỡng `heaplow` 12 KB chọn để **cao hơn một stack task điển hình (~8 KB)** — cảnh báo phải kịp lúc còn cứu được, không phải sau khi `xTaskCreate` đã fail với "No mem".

---

## 11. Nguồn số liệu

| Nhóm | API | Field |
| --- | --- | --- |
| Input | `game_engine_input_stats()` | `events_total` · `dropped_total` · `seq_gaps` |
| Sound | `game_engine_sound_stats()` | `played_total` · `finish_dropped` · `error_count` · `no_hookup` · `cooldown_reject` · `speaker_abandoned_peak` |
| Servo | `game_servo_get_stats()` | `sent_total` · `send_fail_total` · `dropped_total` · `back_reject_{throttle,validation,priority,queue_full}` · `drain_max_us` |
| LED | `led_ring` counters | `dropped_total` |
| Lua arena | `lua_vm_arena_stats()` | `active` · `held_bytes` · `free_bytes` · `largest_free_bytes` · `budget_bytes` |
| Heap | `heap_caps_get_largest_free_block()` | `MALLOC_CAP_INTERNAL` · `MALLOC_CAP_SPIRAM` — **largest-free, không phải total-free** |
| Accumulator phiên | `engine_state()->session` | `frames` · `over_budget` · `tick_hist[8]` · `arena_peak_bytes` · `heap_int_min_bytes` · `api_fail` · `load_ms` |

**Tên khoá trên dây log ≠ tên field trong code.** Bảng này là cầu nối — sửa một bên phải cập nhật bảng.

| Khoá log | Field code | Ghi chú |
| --- | --- | --- |
| `heap` (`game.start`) | `heap_caps_get_largest_free_block(INTERNAL)` | đọc trực tiếp, không qua accumulator |
| `heap_min` (`game.stop`) | `session.heap_int_min_bytes` | `UINT32_MAX` → in `0` |
| `heap` (`game.running`) | `engine_heap_int_largest()` | mẫu tại thời điểm log |
| `arena` / `arena_pk` | `lua_vm_arena_stats().held_bytes` / `session.arena_peak_bytes` | in nguyên byte |
| `slow_n` (`game.running`) / `slow_pm` (`game.stop`) | `session.over_budget` | **thô ở `game.running`, ‰ ở `game.stop`**; đếm theo `gap_us` > 34 ms |
| `tick_us` | `session.win_tick_max_us` | CPU thân tick, **không gồm vẽ** |
| `draw_pm` | `LV_EVENT_RENDER_READY` ÷ `session.frames` | Tử số đếm ở **lvgl_timer, core 0**; mẫu số ở engine_task, core 1 |
| `p95` | `session.tick_hist[]` | xấp xỉ = **biên trên** của bucket chứa mẫu thứ 95; ghi theo `tick_us` |
| `frames` (`game.running`) | `session.win_frames` | **cửa sổ**, không phải phiên — đọc trước khi reset |
| `frames` (`game.stop`/`game.error`) | `session.frames` | dồn cả phiên |
| `hwm_engine` | `uxTaskGetStackHighWaterMark(NULL)` | ESP-IDF trả **byte**, không phải word — không nhân 4. `NULL` = task đang gọi = `engine_task` |
| `load` | `session.load_ms` | chỉ đo `game_pack_load()`, chốt trước cửa sổ peek-STOP |

`p95` khi rơi vào **bucket overflow** (`UINT32_MAX`) thì in biên của bucket liền trước, vì `UINT32_MAX` không phải con số đọc được.

**Khoá JSON trên MQTT lệch thêm một lớp nữa** (§6.1) — bảng này là cầu nối thứ hai:

| Khoá UART | Khoá JSON | Ghi chú |
| --- | --- | --- |
| `game=` (`game.start`/`game.stop`) | `id` | cả ba tag dùng `id` để join được trên cùng một tên |
| `slow_pm` (`game.stop`) | `slow_pm` | tên đầy đủ để không lẫn với `slow_n` thô của `game.running` |
| `drop=a/b/c/d/e` | `drop_in` · `drop_snd` · `drop_nohook` · `drop_svo` · `drop_led` | field có tên, **luôn có mặt** kể cả khi 0 |
| `tick_hz`, `psram` (`game.stop`) | *(bỏ)* | `tick_hz` = `frames`/`dur`; `psram` sau teardown = baseline của `game.start`, đường cong thật ở `game.running` |
| `draw_pm` | *(cùng tên)* | Đã chuẩn hoá theo tick của chính phiên, nên aggregate được qua nhiều phiên dài ngắn khác nhau |
| `kind=` + `n=` | khoá động | Mỗi loại lỗi thành khoá riêng; `heap` là mức (byte), còn lại là delta 10 s. Bỏ khoá = 0 |
| `detail=` khi `kind∈{overrun,heaplow}` | *(bỏ)* | chỉ lặp lại `game`; JSON giữ `detail` cho `api_fail`/`animerr` |
| *(không có)* | `id`, `frames`, `psram` (`game.running`) | bản tin MQTT đứng độc lập; `frames` là **cửa sổ** (`tick_hz` làm tròn không dựng lại được), `psram` cho đường cong giữa start và stop |
| *(không có)* | `frames`, `dur` (`game.error`) | Crash có thể không bao giờ tới teardown → không có `game.stop`; dòng này phải tự đứng được |
| `arena`/`heap`/`psram`, `arena_pk`/`heap_min` | *(cùng tên)* | **byte trên cả hai** — không phải chia gì |

`game.error` giữ khoá `game` (không phải `id`): nó là sự kiện điểm, không tham gia phép join theo phiên như bộ start/running/stop — và `phase=launch` còn phát khi chưa có phiên nào. `game.warn` **không mang id nào cả** (§5): nó luôn nằm giữa một cặp start/stop đã định danh, và là tag bắn dày nhất.

## 12. Nếu UART vẫn chật

| Cách | Được | Mất |
| --- | --- | --- |
| Nâng console lên 921600 baud | Chi phí giảm **8×** — giải quyết gốc, không cắt thông tin | Đụng `sdkconfig` (**phải xin phép**) + mọi tool đang mở cổng 115200 |
| `game.running` chỉ log khi lệch ngưỡng | UART gần như sạch lúc game chạy tốt | Mất baseline để so sánh khi điều tra |
| Hạ `game.running` xuống `ESP_LOGD` | Tắt ở bản ship không cần sửa code | `CONFIG_LOG_MAXIMUM_LEVEL=3` hiện **compile-out** LOGD — phải đổi sdkconfig |
