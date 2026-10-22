---
description: "game_start creates 85 sprites (56 trail dots) and runs ~1.5 s, so the pack fails to open: the fix is to keep game_start light and create the dots lazily across frames, not to raise a limit."
tags: [agent, optimizer, knowledge]
max_turns: 14
allowed_tools: [Read, Glob, Grep, Skill, Agent]
---

Game bản đồ Pika của mình không mở được trên robot. Log có dòng `pack_load fail reason=game_start_pcall`, đo thử thì `game_start` chạy khoảng 1,5 giây. Trong `game_start` mình tạo 85 sprite, trong đó 56 sprite là các chấm nhỏ trên đường đi (mỗi chấm load cùng một file `trail_dot.png` 111 byte). Mình nên tối ưu thế nào? Pack không có trong môi trường này, chỉ cần hướng sửa.
