# TAduo 0.1.0 — thử nghiệm 50/50

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

Đây là bản thử nghiệm, không phải bản hoàn chỉnh. Scene frame được cập nhật không chứng minh client đã relayout. Không có vòng ép foreground hay sửa safe-area để che lỗi. App nền có thể ngừng vẽ; log NATIVE BACKGROUND giúp phân biệt lỗi vòng đời và lỗi geometry. Mỗi app nhận một giao dịch resize, không retry/fallback nếu API đã chọn không hỗ trợ setter. Log xoay ở khoảng 1 MiB, giữ một bản trước.

Source cũ và DEB đối chiếu: https://github.com/sushibta25-design/TAduo/actions/runs/34929416564
