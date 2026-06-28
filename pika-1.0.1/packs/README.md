# `packs/` — 3rd-party asset packs (explicit dependency)

Khác subsys (do Pika ship) — packs do bên thứ 3 publish; game khai trong `manifest.json.requires`.

## Layout

```
packs/
└── <publisher_id>/
    └── <pack_name>@<major>/
        ├── manifest.json    # publisher_id + sig per-pack
        ├── audio/           # hoặc images/, fonts/, ... tuỳ pack
        └── ...
```

## Pack manifest schema

Mỗi pack tự khai trong `manifest.json` (KHÁC subsys không có manifest):
- `publisher_id`, `pack_id`, `version`
- `engine_level_min` (gate compat)
- `signature` (ed25519, per-pack)
- `license`
- `assets` listing

Lý do có manifest+sig per-pack: bên thứ 3 untrusted → cần verify riêng. Subsys không cần vì Pika team single owner + HTTPS+CI.

## Access từ game

```json
// <pub>/<game>/manifest.json
{
  "requires": [
    { "pack": "acme/sfx-arcade", "major": 1 }
  ]
}
```

```lua
-- Game gọi qua audio alias chuẩn (pack mount path explicit cho tránh xung đột)
Speaker.play("@sdk:audio/acme/sfx-arcade/arcade_jump")
```

> **Note**: API exact cho pack access (alias prefix, path resolution) đang là OPEN question — quyết định khi implement packs runtime. Phase 1 focus subsys; packs sau.

## Pack hiện có

| Pack | Content |
|---|---|
| `acme/sfx-arcade@1/` | 3 sample arcade WAV (jump, coin, powerup) |

## Lifecycle

OTA pipeline `f735bd9a` (chung downloader, khác URL prefix). Game khai pack required trong `manifest.json` → downloader pull pack về.
