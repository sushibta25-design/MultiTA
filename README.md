# DuoPhone V6.2.1 — bản sửa để thử trên thiết bị

Mục tiêu: chia hai vùng CarPlay cho hai app CarPlay đầy đủ, dựa trên Tweak.xm V6.2 trong ZIP được gửi. README-V5.1.md là tài liệu lịch sử, không phải trạng thái hiện tại.

## Đã sửa

- Import objc/message.h để khai báo objc_msgSend (lỗi build ở ảnh).
- Khai báo trực tiếp header cho getpid/floor; bỏ hàm static không sử dụng.
- Không để quét layer host ghi đè sceneHostView đã lấy từ controller đầy đủ.
- Không thay thứ tự app / ghi log đăng ký mỗi 500 ms khi controller và host không đổi.
- Giữ cấu trúc view lồng nhau đã có; đưa đúng view pane lên trước.
- Tránh chọn cùng một app cho hai pane; chỉ hiện divider khi có hai view khác nhau.
- Log TWO PANES ATTACHED chỉ nói đã gắn hai view, không khẳng định hai app đang chạy.
- Chỉ chọn dashboard scene, không dùng statusbar scene làm fallback; xóa tham chiếu giữ lại khi đổi/ngắt display.
- Đồng bộ metadata về V6.2.1.

## Build bằng GitHub Actions

1. Giải nén ZIP, mở thư mục Duophonev2-fixed.
2. Chép NỘI DUNG thư mục vào gốc repo Duophonev2, ghi đè các file cùng tên. Không tạo thêm thư mục Duophonev2-fixed bên trong repo. Phải giữ .github/workflows/build.yml.
3. Commit lên main. Vào Actions → Build DuoPhone → mở lần chạy mới (hoặc Run workflow).
4. Khi build thành công, tải artifact DuoPhone-DEB, giải nén và cài file .deb bằng trình quản lý gói đang dùng cho RootHide. Khởi động lại CarPlayApp/respring sau khi cài.

Giữ workflow và cấu hình RootHide từ bản gửi lên. build.yml ở gốc là bản sao lịch sử; GitHub chạy .github/workflows/build.yml.

## Kiểm tra trên CarPlay khi xe đang đỗ

1. Kết nối CarPlay, mở Maps, sau đó mở app CarPlay thứ hai từ dock/grid.
2. Chờ khoảng 10 giây. Ghi lại tên cả hai app.
3. Nếu có hai pane: thử chạm/cuộn ở từng pane, quan sát cả hai có cập nhật liên tục không. Kéo divider; chạm đúp divider để đổi bên.
4. Ngắt và kết nối lại CarPlay để kiểm tra có giữ nhầm view cũ không.
5. Gửi ảnh/video và /var/mobile/DuoPhoneV6Trace.txt. Tìm CTOR V6.2.1, FULL APP REGISTER, SCENE FOUND, lifecycle background/deactivate, TWO PANES ATTACHED và DISPLAY RESET.
6. Nếu Actions lỗi, gửi log từ dòng error đầu tiên; không chỉ gửi dòng exit code 2 cuối cùng.

## Giới hạn đã biết

Chưa build bằng iOS SDK/Theos và chưa chạy trên thiết bị trong phiên sửa này: môi trường hiện tại không có toolchain đó. Đã kiểm tra thay đổi nguồn và tính toàn vẹn ZIP; kết quả Actions mới là kiểm tra biên dịch thực tế.

Đây vẫn là thử nghiệm, chưa xác nhận dùng hai app tương tác song song. Giữ strong reference đến UIView/controller không ép app tiếp tục render; các hook background/deactivate vẫn gọi triển khai gốc. Nếu pane đầu đứng hình hoặc đen, cần log lifecycle để xử lý bước giữ scene hoạt động. Không bỏ các callback lifecycle một cách mù quáng.

Mã chỉ nhận scene CarPlay dạng Car[...]:bundle và loại :dashboard/:widget. Chưa cung cấp khả năng chạy app iPhone bất kỳ trên CarPlay. Chọn hai scene đầu đủ điều kiện; chưa có bộ chọn thay app thứ ba. Dock trái vẫn giả định rộng 45 point. Việc resize remote scene, tọa độ touch và quay về grid chưa được xác nhận trên thiết bị.
