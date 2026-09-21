# TAduo 0.2.0 — thử nghiệm 50/50

Dựng lại từ cơ chế capture/foreground/presentation của Duophone 6.40 (commit a17518d8751314c8ca5b44170b73430ad866bbcf). Không kế thừa các patch safe-area, offset riêng Google Maps, giả lập callback, snapshot recovery hoặc sửa cây view của app.

## Cài và thử

- Dành cho Dopamine rootless, iOS 15 trở lên; cần kiểm chứng thực tế trên iOS của thiết bị.
- Giữ DEB Duophone cũ để quay lại. Gỡ Duophone trước khi cài TAduo; hai gói khai báo xung đột để tránh cùng hook. Tắt MiniTa/DuoDash và các tweak chia màn hình khác trong lần test này.
- Kết nối CarPlay, mở Maps rồi YouTube Music từ dock mỗi app một lần.
- Chạm TAduo, chọn app cho từng ô. Có thể chọn ô phải trước.
- Hai ô bằng nhau, nằm dưới thanh Thoát cao 32pt. Không kéo divider ở bản này.
- Chạm Thoát để trả geometry đã lưu và hủy presentation riêng.
- Gửi ảnh hai ô và /var/mobile/TAduo.log; nếu có log .1 thì gửi kèm.

## Tiêu chí test thiết bị

1. Cả hai app có hình và phản hồi chạm sau khi chọn app thứ hai.
2. Nút và nội dung bên phải còn đầy đủ; không méo/kéo dài, không vùng đen bất thường.
3. Thoát trả app về kích thước cũ; ngắt/cắm lại CarPlay hoạt động.
4. Nếu một ô đen hoặc thiếu nút, ghi rõ app và thao tác xảy ra trước đó.

## Giới hạn

Đây là bản thử nghiệm, không phải bản hoàn chỉnh. Scene frame được cập nhật không chứng minh client đã relayout. Không có vòng ép foreground hay sửa safe-area để che lỗi. App nền có thể ngừng vẽ; log NATIVE BACKGROUND giúp phân biệt lỗi vòng đời và lỗi geometry. Mỗi app nhận một yêu cầu resize với fallback có giới hạn khi callback từ chối setter. Log xoay ở khoảng 1 MiB, giữ một bản trước.

Source cũ và DEB đối chiếu: https://github.com/sushibta25-design/TAduo/actions/runs/34929416564

## Thay đổi 0.2

- Yêu cầu geometry qua updateSettingsWithBlock trước khi tạo presentation. Chỉ chuyển sang updateUISettingsWithBlock khi thiếu API hoặc callback từ chối setter. Callback không tới thì báo lỗi, không chồng giao dịch.
- Sau giao dịch, gọi refresh scene/presentation có kiểm tra chữ ký hàm; không giả callback hệ thống và không scale ảnh.
- Quan sát scene/window/root bounds thật trong Maps, Google Maps, YouTube, YouTube Music, Vietmap và TemplateUIHost. Gửi kích thước qua Darwin notification về TAduo.log. Client hook chỉ đọc; không sửa bounds/safe-area/traits.
- CLIENT match=1 chỉ nói kích thước khớp, không chứng minh nút không bị cắt hoặc touch đúng. Không có dòng CLIENT cũng không chứng minh geometry sai (injection/role/notification có thể không phù hợp).
- Cần đóng/mở lại app sau cài để hook phía app được nạp. Giữ hai ô mặc định; test Maps + YouTube Music trước, sau đó Google Maps + YouTube.
- Chưa có log thiết bị của bản 0.1: đường giao dịch mới là thử nghiệm, chưa xác nhận giải quyết lỗi trong ảnh của người dùng.
