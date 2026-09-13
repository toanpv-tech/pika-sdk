# Changelog

Lịch sử thay đổi của **Pika SDK**. Mỗi lần release (commit có tăng
`sdk_version`) thêm một mục ở đầu file.

Đánh version theo [SemVer](https://semver.org/lang/vi/) trên **hợp đồng API mà
SDK viết theo**, không phải trên số lượng file thay đổi:

| Tăng | Khi |
|---|---|
| **MAJOR** | Đổi/gỡ API Lua, hook, hoặc key manifest — game pack cũ phải sửa mới chạy |
| **MINOR** | Thêm API/binding/thư viện/example, hoặc sửa tài liệu cho khớp engine |
| **PATCH** | Sửa lỗi chính tả, link hỏng, làm rõ câu chữ — không đổi hợp đồng |

`sdk_version` được tool đối chiếu với version firmware báo lúc chạy và cảnh báo
(mềm) nếu lệch — xem [README §Version](README.md#version).

Phân loại thay đổi: `Thêm` · `Sửa` · `Gỡ` · `Sai số liệu` · `Tài liệu`.

---

## 1.1.1 — 2026-09-14

Đồng bộ toàn bộ tài liệu/skill/example với triển khai thật của engine
(`head_esp32/components/game_engine`). Trước bản này tài liệu SDK là một nhánh
fork đã trôi khỏi engine: một số API ghi trong tài liệu **không còn tồn tại**,
và một số con số là sai.

### Gỡ

- **`State.*`** (`set`/`get`/`save`/`load`/`has_save`/`clear`) — binding đã bị gỡ
  khỏi engine. **Hiện không có API lưu trạng thái**: Lua không ghi được file nào,
  trạng thái chỉ sống trong một phiên chơi. Muốn giữ điểm thì dùng `Ranking.report`.
- **`Voice.mode()`** — thay bằng `params.is_a2a` trong `game_start(params)`.
- **`libraries/save.lua`** — dựng hoàn toàn trên `State.*`, mọi hàm no-op (không
  crash nhưng cũng không lưu gì). Xoá khỏi `libs.index.json` và `libraries/README.md`.
- **Nhánh Continue/resume trong `libraries/settings.lua`** (`has_save`/`on_resume`/
  `_resume_row`) — không có persistence thì `has_save` vĩnh viễn false, code không
  bao giờ chạy tới.

### Sửa (breaking với pack cũ)

- **Manifest v2**: `display_name`/`entry_script` → **`name`/`main`**, thêm
  `peripherals`. Parser **không còn fallback** — pack chỉ dùng tên v1 sẽ có tên
  rỗng và không nạp được entry script. Đã cập nhật cả 4 example và template.
- **`game_start(params)`**: tham số là **table** (luôn là table — body rỗng/hỏng
  decode thành `{}`), không phải string JSON. Engine tự thêm `params.is_a2a` và
  `params.language`.

### Thêm

- **`Ranking.*`** (`report` / `get_result`) — leaderboard qua IPC sang back.
  `duration_ms` do engine tự tính, không nhận từ Lua. `get_result` là
  **consume-once**, phải poll từ `on_tick()`.
- **`Engine.stack_hwm()`** (debug).
- **[docs/manifest.md](docs/manifest.md)** — schema manifest v2 đầy đủ.

### Sai số liệu (đối chiếu Kconfig + source)

| Mục | Ghi sai | Thực tế |
|---|---|---|
| Cooldown `Speaker.play` | 80 ms | **150 ms** (`CONFIG_GAME_SOUND_PLAY_COOLDOWN_MS`; 80 chỉ là fallback khi Kconfig vắng) |
| Trần sprite | "tối đa 32" | **không có trần** — giới hạn là PSRAM còn trống |
| `audio.sounds` vượt 64 | "âm thầm bỏ bớt" | **reject cả pack** (`install_entry` fail → `goto bad`) |
| Tên action / alias | ≤ 24 ký tự | **≤ 23** (buffer 24 gồm NUL; `n >= 24` là reject) |
| `path` của sound | ≤ 64 ký tự | **≤ 63** |

Hai dòng cuối dễ mất thời gian debug: viết đúng 24 ký tự theo tài liệu cũ thì
pack **bị từ chối nạp**.

### Tài liệu

- Gỡ 46 link chết trỏ tới mã firmware (`../../head_esp32/...`) — hợp lệ khi ở
  `docs/pika-engine/` nhưng hỏng trong SDK vì đây là repo độc lập không chứa mã
  firmware. Chuyển thành tên file dạng code.
- `monitor.md` thay bằng bản viết lại theo pha vòng đời (`game.start` /
  `running` / `stop` / `error` / `warn`).
- `getting-started.md`: bảng example đúng với 4 pack đang có, bảng phím
  simulator, và những hành vi simulator **không** mô phỏng (HOME/`on_home`,
  servo/LED, Voice).
- `skill/` (nguồn chống-bịa-API cho AI sinh game): cập nhật `api-contract.md`,
  `constraints.md`, `pitfalls.md`, recipes và template.

---

## 1.0.2 và trước đó

Không có changelog — xem `git log`.
