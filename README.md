# DuoPhone V4.0 — CarPlay Split Screen

Chia đôi màn hình CarPlay, chạy 2 app song song, kéo thanh divider
trái/phải để đổi tỉ lệ.

## Kiến trúc

Tweak nạp vào 2 process:

| Process | Nhiệm vụ |
|---|---|
| `com.apple.CarPlayApp` | Vẽ thanh divider, nhận thao tác kéo, publish tỉ lệ |
| `com.apple.springboard` | Bắt scene manager của car display, tạo scene cho app thứ 2, host vào nửa phải |

Hai process trao đổi tỉ lệ qua file cache + Darwin notification
`com.duophone.ratio.changed`.

## Điểm khác so với V3.9.x

- Hook `SBSystemShellExternalDisplaySceneManager` được cài **ngay trong `%ctor`**.
  Ở các bản trước hook chạy sau chuỗi `dispatch_after` dài, nên nếu CarPlay
  đã kết nối từ trước thì manager đã được tạo xong và hook bắt hụt vĩnh viễn
  (trace cũ: `capturedExternalManager=nil`).
- Bỏ hướng clone `FBSCAContextSceneLayer` (V3.8) và bộ dò object graph
  (V3.9.10, `visited=18 captured=nil`) — cả hai đã chứng minh không đi tới đâu.
- Rút từ ~5259 dòng xuống ~430 dòng.

## Build

Push lên `main`, GitHub Actions tự build (RootHide Theos + iOS 16.5 SDK).
Tải artifact `DuoPhone-DEB` ở cuối trang lần chạy.

Build local:

```
make clean package FINALPACKAGE=1
```

## Cài đặt và test

Thứ tự quan trọng:

1. Cài `.deb` (kiểm tra version là `0.7.0`, không phải bản cũ `0.6.9-10`).
2. Respring.
3. **Rồi mới** kết nối CarPlay.

## Đọc trace

Trace ghi ở `/var/mobile/DuoPhoneV4Trace.txt`.

Các dòng cần soi:

| Dòng | Ý nghĩa |
|---|---|
| `CTOR V4.0 bundle=...` | Tweak đã nạp |
| `V4.0 hooked init4` / `init3` | Hook cài thành công, trước khi CarPlay kết nối |
| `V4.0 divider ready ratio=...` | Divider đã hiện trên màn hình xe |
| `V4.0 ===== CAPTURED CAR SCENE MANAGER =====` | Bắt được manager của car display — mốc quan trọng nhất |
| `V4.0 second pane created` | Đã host được app thứ 2 |

Nếu thiếu dòng `CAPTURED CAR SCENE MANAGER`, xoá file trace, respring,
rồi cắm lại CarPlay và gửi trace mới.

## Cấu hình

Sửa trong `Tweak.xm`:

- `kSecondApp` — bundle id của app pane phải (mặc định `com.apple.Maps`)
- `kMinRatio` / `kMaxRatio` — giới hạn kéo divider
- `kCarPlayDockW` — bề rộng dock CarPlay bên trái
