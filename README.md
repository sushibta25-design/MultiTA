# MultiTA Beta 0.50.1

Gói `com.sushibta.multita.beta` (tên hiển thị MultiTA Beta), phát triển từ nhánh TAduo. Khai báo xung đột với `com.sushibta.multita` (0.10.24.x), `com.sushibta.taduo` và `com.sushibta.duophone`: Sileo sẽ yêu cầu gỡ các gói đó trước khi cài để không có hai tweak cùng hook CarPlay. Bàn phím tiếng Việt dùng chung của MultiTA 0.10.24.x CHƯA có trong bản này. Log: `/var/mobile/MultiTA-beta.log`.

## 0.50.1 — thu nhỏ Netflix bằng khung bọc

Log 0.50.0: Netflix đã nhận đúng scene lớn (vd. 438x325 cho ô 315x234) nhưng ô hiển thị nó ở kích thước thật, tràn phải và cụt dưới: `_UIScenePresentationView` tự đặt lại transform/khung theo scene. Giờ view hiển thị nằm trong một khung bọc (view thường, nền đen, cắt biên); khung bọc được thu nhỏ vừa ô, còn view hiển thị chỉ việc lấp đầy khung bọc. Khung bọc đi theo khi đổi bên và bị gỡ khi dọn ô.

## 0.50.0 — thu nhỏ Netflix từ phía CarPlay

Netflix vẽ theo đúng số pt của màn xe nên quá to trong ô 240pt. Cách 0.49.6 (transform cửa sổ bên trong app) làm Netflix lệch phải vì khung `CTTabletContainer` của ConnectTA tự đặt lại vị trí. Giờ thu nhỏ hoàn toàn ở CarPlay.app: scene của Netflix được đặt kích thước lớn hơn ô (ô / 0.72), còn view hiển thị (`_UIScenePresentationView`) được thu nhỏ 0.72 cho vừa ô. Netflix chỉ thấy một màn hình lớn hơn, không có hook hay transform nào bên trong app. Chỉ áp dụng khi Netflix nằm trong ô chia màn. Hệ số: bảng `TAPaneZoom`.

## 0.49.9 — chặn trình phát Netflix trong CarPlay (tránh đơ)

Log 0.49.8: Netflix mở `NFUIPlaygraphPlayerViewController` trong ô CarPlay, ngay sau đó CarPlay.app đơ tới khi watchdog khởi động lại (35 s). Netflix vốn không cho phát lên màn CarPlay/màn ngoài (thông báo "Màn hình đã kết nối không được hỗ trợ"), nên giờ trình phát bị đóng ngay khi xuất hiện trong cảnh CarPlay. Trên màn điện thoại không đổi. Log: `NETFLIX PLAYER closed in CarPlay …`.

Log 0.49.8 cũng cho thấy Netflix KHÔNG bị ConnectTA đổi idiom (`idiomImpBefore=UIKitCore`); sheet có dấu × là giao diện riêng của Netflix.

## 0.49.8 — Netflix dùng giao diện iPhone

Log 0.49.7: chính `ConnectTA.dylib` (tweak đưa app iPhone lên CarPlay) trả lời idiom iPad cho YouTube và Netflix, và bọc app trong `CTTabletContainer` (khung 1024pt thu nhỏ). Với YouTube, MultiTA ép lại `phone` từ 0.49.7 (đã được xác nhận ổn). Netflix giờ cũng được ép `phone`: trang phim mở toàn trang như trên điện thoại (nút Phát, Tải xuống) thay vì sheet iPad có thanh mờ và dấu ×. Thu nhỏ vẫn tắt cho Netflix. Log: `NETFLIX CTOR phone idiom forced …`.

"Không thể phát video — Màn hình đã kết nối không được hỗ trợ" là Netflix chặn phát lên màn hình ngoài (bảo vệ bản quyền), không liên quan MultiTA.

## 0.49.7 — ép YouTube về giao diện điện thoại, tạm tắt thu nhỏ Netflix

Log 0.49.6: hook iPad KHÔNG được cài (`YOUTUBE CTOR ipad=0`) mà YouTube vẫn báo `device=pad trait=pad` và vẫn dùng `CTTabletContainer` → có hook khác (tuỳ chọn "iPad layout" của tweak YouTube) hoặc YouTube tự nhớ. Khi công tắc iPad tắt, MultiTA giờ trả lời `phone` cho cả UIDevice lẫn UITraitCollection trong YouTube; ctor ghi file nào đang giữ hàm đó trước MultiTA (`idiomImpBefore=…`).

Ảnh 0.49.6: Netflix thu nhỏ bị dồn sang phải, hụt bên trái và cắt bên phải ở cả hai ô → tạm tắt thu nhỏ cho Netflix. Cả Netflix và YouTube ghi `CARLAYOUT …` 1.5 s sau mỗi lần đổi kích thước (khung/bounds/transform/safe area của window, root view và các view con) để tìm nguyên nhân lệch.

## 0.49.6 — thu nhỏ giao diện YouTube/Netflix trong CarPlay, tắt giao diện iPad

Ảnh thực tế: Netflix (và YouTube giao diện điện thoại) vẽ theo đúng số pt của màn xe (cao 240pt) nên header và thanh tab chiếm gần hết ô, nút toàn màn của trình phát bị đẩy ra ngoài. Giờ trong YouTube và Netflix, cửa sổ CarPlay được cho khung logic lớn hơn (chia cho 0.72) rồi thu nhỏ lại vừa ô bằng transform — giống thu nhỏ trang web: nhiều nội dung hơn, chữ nhỏ hơn, chạm vẫn đúng chỗ. Áp dụng lại mỗi 250 ms vì UIKit đặt lại khung cửa sổ mỗi lần đổi kích thước. Cửa sổ bàn phím không bị đụng. Hệ số: `TA_VIDEO_ZOOM`. Log: `VIDEO ZOOM …`.

Netflix được nạp như YouTube: không hook, chỉ bàn phím chung + thu nhỏ cửa sổ.

Log 0.49.5 cho thấy giao diện iPad của YouTube dựng lưới trên khung cố định 1024pt rồi thu cả khung vào ô (luôn 3 cột tí hon), nên giờ TẮT mặc định. Bật lại: tạo file `/var/mobile/MultiTA-youtube-ipad`, tắt hẳn YouTube rồi mở lại.

## 0.49.5 — log app client đi qua notify

Log 0.49.4: `YOUTUBE TRAITS` vẫn tới nhưng không có dòng `[com.google.ios.youtube]` nào → CarPlay.app không đọc được container của app (hoặc app không ghi được). Bỏ cách chép file. Giờ dòng log của app client đi như bản xem trước của bàn phím: cắt thành khối 8 byte vào notify state `com.sushibta.multita.clog.<bundle>.<i>`, đặt head `<seq,len>` rồi post; CarPlay.app ghép lại, ghi vào log chính và ack `<seq>`; client gửi từng dòng, chờ ack tối đa 1 s. Tối đa 1016 byte/dòng.

## 0.49.4 — log từ trong app, dump bố cục YouTube, công tắc giao diện iPad

Log 0.49.3: YouTube đã nhận iPad idiom và size class theo độ rộng ô (compact dưới 250pt) nhưng vẫn vẽ lưới 3 cột tí hon. Không có dòng `KEYBOARD CANCEL`/`KEYBOARD INPUT` nào vì app client (YouTube, Google Maps) bị sandbox, không ghi được `/var/mobile/MultiTA-beta.log` — chưa bao giờ ghi được. Giờ TALog trong app client ghi vào `<container>/tmp/MultiTA-client.log` (dòng có thêm `[bundle]`), CarPlay.app cứ 2 s chép dòng mới vào log chính.

Mỗi lần ô đổi độ rộng, 1.5 s sau YouTube ghi `YOUTUBE LAYOUT/WINDOW/GRID`: kích thước scene, màn hình nó tưởng đang chạy, frame + transform của window/root, collection view đầu tiên (frame, contentSize, layout class, 6 cell đầu, ancestor có transform). Cho biết vì sao lưới 3 cột bị thu nhỏ.

Công tắc không cần build lại: tạo file `/var/mobile/MultiTA-youtube-phone` (Filza) rồi tắt hẳn YouTube và mở lại → YouTube về giao diện điện thoại; xóa file → giao diện iPad. CarPlay.app đọc file lúc khởi động và phát trạng thái qua notify (`YOUTUBE IPAD switch=…`), YouTube đọc trong ctor (`YOUTUBE CTOR ipad=…`).

## 0.49.3 — YouTube: cột theo độ rộng ô, hủy tìm kiếm (gộp 0.46.1–0.46.3 vào 0.49.2)

Log 0.46.2: YouTube đã nhận giao diện iPad (`device=pad trait=pad`) nhưng cửa sổ CarPlay luôn là `hClass=compact` mà YouTube vẫn vẽ lưới 3 cột tí hon của iPad ngang: nó đọc size class từ chỗ khác (màn hình/cửa sổ điện thoại). Giờ mọi truy vấn `horizontalSizeClass` trong YouTube đều trả lời theo độ rộng ô CarPlay khi đang kết nối CarPlay: dưới `TA_YOUTUBE_REGULAR_WIDTH` (250pt) là compact (1 cột), từ 250pt là regular (lưới). Log `YOUTUBE TRAITS` thêm hướng màn hình và size class/hướng/độ rộng cửa sổ điện thoại.

Hủy tìm kiếm bằng nút × trên bàn phím chung: nhận thêm nút quay lại (Quay lại/Back/Đóng…) cùng hàng với ô nhập; YouTube được duyệt cây view sâu hơn (2000 view); nếu vẫn không thấy thì với YouTube pop màn tìm kiếm khỏi navigation controller (log `KEYBOARD CANCEL route=pop`). Khi hủy thất bại, log liệt kê các nút cùng hàng và chuỗi view controller để chọn đúng nút ở bản sau.

## 0.46.2 — YouTube giao diện iPad trong ô (thử nghiệm)

YouTube được cho là đang chạy trên iPad (hook duy nhất: UIDevice.userInterfaceIdiom), nên dùng giao diện iPad và tự chia cột theo độ rộng ô: ô hẹp 1 cột, ô rộng 2 cột, đổi ngay khi kéo divider. Cần tắt hẳn YouTube rồi mở lại một lần sau khi cài. Ảnh hưởng cả YouTube trên màn iPhone. Tắt: đặt `TA_YOUTUBE_IPAD` = 0 trong Tweak.xm. Log: `YOUTUBE TRAITS device=… trait=… hClass=… size=…` (YouTube gửi qua notify, CarPlay ghi hộ vì YouTube không ghi được file log).

## 0.46.1 — bàn phím chung cho ô tìm kiếm YouTube

YouTube được nạp lại nhưng chỉ chạy phần bàn phím chung (không hook giao diện), khởi động sau 2s. Ô nhập được tìm qua firstResponder của cửa sổ vì cây view YouTube vượt giới hạn 500 view.
## 0.49.1 — chỉnh chuột và lời thoại

Chuột cách divider 22pt (trước 6pt); bong bóng lời của chuột kết thúc cách divider 16pt, không đè lên thanh chia; chữ bong bóng 13pt (trước 11pt). Bỏ chữ "Chọn ứng dụng" trong lúc vuốt (0.49.2: bỏ cả icon app nằm sau quái vật); ô trống vẫn hiện "Chạm để chọn ứng dụng" sau khi thả tay.

## 0.49 — chuột và quái vật khi vuốt từ Dock

Khi vuốt từ Dock: con chuột 🐭 bám trên divider, ô bên kia có quái vật tròn màu xanh (kiểu Pac-Man, răng nanh, mắt liếc về phía chuột, lông mày dữ). Divider càng tiến lại, quái vật càng to và há miệng rộng. Chuột nói "Ơ… đi đâu đây?" → "Hình như có mùi…" → run và hét "CỨU TÔI!!!"; quái vật "Măm măm…". Thả tay để chia màn: chuột bị hút vào miệng, quái vật ngậm "chóp", nói "Măm! Ngon 😋" rồi mờ đi (~1 giây) và hai app hiện ra. Huỷ (thả sát Dock) thì biến mất ngay. Vẽ bằng code, không dùng ảnh.

## 0.48.6 — nút đổi bên sát ổ khoá, không che nút của ô

Ảnh 0.48.5: khung tay nắm phóng to che nút ">" sang trang của bảng chọn bên trái, và nút đổi bên cách xa ổ khoá. Giờ nút đổi bên nằm ngay trên ổ khoá (ổ khoá 22×44, trước 22×60), cả cụm căn giữa màn; chỉ đúng hai nút (±4pt) nhận chạm, khoảng trống quanh chúng thuộc về ô bên dưới. Khi hiện, cụm to tối đa 2 lần nhưng chừa 48pt trên và dưới cho nút của ô (≈1,56 lần trên màn cao 240pt).

## 0.48.5 — vuốt từ Home, tay nắm to khi hiện

Log 0.48.4: vuốt Dock từ màn Home luôn bị từ chối (`DOCK PULL rejected current=(null)`). Giờ vuốt từ Home cũng mở chia màn: app dùng gần nhất vào ô phải, app trước đó vào ô trái; chưa có app nào thì cả hai ô hiện bảng chọn. Log `DOCK PULL from Home recent=… + …`.

Ổ khoá (tay nắm) và nút tròn đổi bên: khi hiện lên được vẽ và nhận chạm to gấp tối đa 2 lần, giới hạn theo chiều cao màn (≈1,73 lần trên màn cao 240pt), căn giữa theo chiều dọc; khi tự ẩn thì thu về cỡ cũ để vùng chạm vô hình không đè lên app.

## 0.48.4 — divider và vuốt Dock nhạy hơn

Khó bắt divider khi lái xe. Vùng chạm divider rộng thêm: +14pt mỗi bên (44pt trên màn 426pt, trước 28pt); phần nhìn thấy không đổi. Divider bắt đầu chạy theo tay sau 5pt (trước 9pt). Vuốt Dock: divider xổ ra ngay khi ngón tay tới gần mép Dock (trước phải qua mép +4pt), chấp nhận vuốt chéo (thành phần ngang ≥ 0,6 lần dọc; trước phải gần như ngang), vùng vuốt cao 29% màn hình.

## 0.48.3 — vùng vuốt không còn trong suốt hoàn toàn

Log 0.48.2: vùng vuốt nằm trên cùng (`top=UIWindow(level 2200)`) nhưng không nhận cú chạm nào. Các vùng trong suốt 100% (0.47.0, 0.47.1, 0.48.2) đều không nhận chạm; vùng tô đỏ 0.47.3 và tay nắm cũ (alpha 0.02) thì nhận — hệ thống bỏ qua cửa sổ không có nội dung khi định tuyến cú chạm. Nền vùng vuốt giờ là đen alpha 0.02 (không nhìn thấy).

## 0.48.2 — vùng vuốt riêng ở đầu Dock, nằm trên overlay khác

Log 0.48.1: dò mọi cửa sổ Dashboard đều không thấy view Dock — Dock được vẽ ngoài cây view của CarPlayApp, nên bộ nhận vuốt gắn vào cửa sổ CarPlay không bao giờ nhận cú chạm ở Dock (đã gỡ). Chỉ cửa sổ riêng của MultiTA nhận được (như bản thử 0.47.3). Vùng vuốt giờ là cửa sổ trong suốt ở đầu Dock: rộng 14% màn hình (bề rộng Dock), cao 28% (từ giờ/Wi-Fi tới ngay trên icon đầu tiên), level Alert+200 để nằm trên CTWindow (level 2100) của tweak khác. Log `DOCK ZONE … top=<cửa sổ trên cùng tại vùng vuốt>`.

## 0.48.1 — sửa vuốt Dock không ăn ở 0.48.0

Log 0.48.0: bộ nhận vuốt đã gắn vào các cửa sổ Dashboard nhưng không lần nào bắt đầu. (1) Dò Dock thất bại vì DBLockOutWindow trả lời hit-test trên toàn màn hình, nên bề rộng Dock rơi về 60pt, trong khi ở 0.47.3 người dùng bắt đầu vuốt ở x≈43–88pt. (2) Nhận dạng cử chỉ gốc của CarPlay có thể giành mất cú vuốt. Sửa: bỏ qua DBLockOutWindow khi dò, cho cú vuốt chạy song song với cử chỉ của CarPlay, vùng mặc định 20% màn hình như bản thử đã vuốt được, log `DOCK SWIPE ignored …` khi một cú vuốt gần Dock bị bỏ qua. Thêm vùng dự phòng trong suốt ở phần trên Dock (giờ/sóng/Wi-Fi, tới ngay trên icon đầu tiên, tối đa 25% chiều cao) — cách đã chạy ở 0.47.3 và không che icon.

## 0.48 — vuốt từ cả cột Dock, icon Dock vẫn bấm được

Bản thử 0.47.3 xác nhận vuốt từ Dock hoạt động trên xe, nhưng lớp phủ che icon Dock. Giờ không còn lớp phủ: thao tác vuốt được gắn thẳng lên các cửa sổ Dashboard của CarPlay. Chạm icon Dock vẫn mở app như thường; chỉ vuốt ngang sang phải bắt đầu trong Dock mới mở chia màn (và huỷ cú chạm vào icon). Vùng bắt đầu là cả cột Dock (bề rộng Dock đo từ icon, không đo được thì lấy 14% màn hình). Log: `DOCK SWIPE installed`, `DOCK ZONE right=…`, `DOCK SWIPE start`, `DOCK PULL begin/rejected`, `PULL open/cancelled`.

## 0.47.3 — bản thử vùng vuốt to

Bản thử: vùng vuốt phủ cả cột Dock (rộng ~20% màn hình, cao hết màn), tô đỏ mờ để thấy vị trí. Icon Dock không bấm được trong bản này. Dùng để xác nhận vuốt hoạt động trên xe, sau đó thu nhỏ lại đúng khoảng trống dưới Wi-Fi (`kTADockZoneTest`).

## 0.47.2 — dò Dock rộng hơn

Log 0.47.1: vùng vuốt hiện nhưng không dò được icon Dock (`DOCK ZONE fallback`), vùng mặc định 44×72pt ở góc trên nhỏ hơn Dock thật nên không nhận được vuốt (không có `DOCK SWIPE start`). Giờ dò ở nhiều vị trí x (12/20/30/42pt), chấp nhận icon lớn hơn trên màn to; vùng mặc định rộng 12% màn hình, cao 40%. Ghi một lần `DOCK PROBE …` (view dọc mép trái mỗi 12pt) để khớp Dock từ log nếu vẫn trượt.

## 0.47.1 — vùng vuốt Dock luôn bật

0.47.0: vuốt không có tác dụng và log không có dòng DOCK nào — vùng vuốt chỉ bật khi tweak đã ghi nhận app đang mở, điều này không xảy ra trên xe thử. Giờ vùng vuốt bật bất cứ khi nào chưa chia màn; vuốt khi chưa có app dùng được thì bị từ chối và ghi lý do. Log thêm: `DOCK ZONE shown/hidden … current=… captured=…`, `DOCK SWIPE start …`.

## 0.47 — vuốt từ Dock để chia màn

Bỏ tay nắm ở cạnh phải (khó với tới trên màn xe dài). Giờ vuốt sang phải từ phần trên của thanh Dock CarPlay — vùng giờ/sóng/Wi-Fi xuống tới ngay trên icon đầu tiên — là mở chia màn luôn, không cần giữ. Khi ngón tay ra khỏi Dock, thanh divider xổ ra và chạy theo ngón tay; thả tay là chia màn ở tỉ lệ đó (thả sát Dock thì huỷ). App mới vào ô trái (cạnh Dock), app đang mở sang ô phải. Vùng vuốt chỉ có khi đang mở một app (như tay nắm cũ).

Vùng vuốt không dựa vào tên class Dock (lần trước không tìm được trên một số xe): dò icon Dock đầu tiên dọc mép trái màn hình để biết bề rộng Dock và chỗ trống phía trên. Log: `DOCK ZONE icon=… zone=…`, hoặc `DOCK ZONE fallback` (dùng vùng mặc định 44pt × 30% chiều cao phía trên), `DOCK PULL begin`, `PULL open`, `PULL cancelled`.

## 0.46.3 — log nhiệt độ

Mỗi 30 giây (và ngay khi iOS đổi mức nhiệt) ghi một dòng `HEAT` vào `/var/mobile/MultiTA-beta.log`: mức nhiệt iOS (nominal/fair/serious/critical), nhiệt độ pin, % pin, đang sạc hay không, % CPU của CarPlay (nơi MultiTA chạy, 100% = một nhân), đang chia màn không, app ô trái/phải và tỉ lệ chia.

## 0.46.2 — ô hẹp cũng được trả lại khoảng Dock

Ô chia hẹp hơn ~180pt (khoảng 42% màn 426pt) vẫn bị lệch phải: giới hạn trả lại inset tính bằng 25% độ rộng ô nên nhỏ hơn 45pt của Dock và bị bỏ qua. Giới hạn giờ tính theo màn hình CarPlay (tối đa 64pt) như bản 0.10.10. Cùng ý với DuoPhone V6.2: ô app không bao giờ nằm dưới vùng Dock 45pt.

## 0.46.1 — app tự co vừa ô (hết lệch phải)

Trong ô chia màn, app CarPlay (YouTube Music, Apple Maps, Vietmap) bị đẩy lệch sang phải và cắt mất phần bên phải, dù ở ô trái hay ô phải. Nguyên nhân: app vẫn chừa ~45pt bên trái cho Dock; 0.46 chỉ trả lại khoảng đó cho Google Maps. Giờ mọi app có mẹo layout (Apple Maps, Google Maps, YouTube Music, Vietmap) đều được trả lại khoảng đó nên nội dung lấp đầy ô. Log: TEMPLATE APPLY / TEMPLATE RESTORE.

## 0.46 — Google Maps trong ô, giữ YouTube khi kéo divider về cạnh

Log 0.45: đổi app liên tục ở một ô không còn treo. Hai lỗi hiển thị Google Maps:

1. Trong ô, bản đồ Google Maps lệch/thừa ~45pt bên trái (khoảng chừa cho Dock, 0.44 đã tắt mẹo xử lý). Bật lại DUY NHẤT mẹo trả lại 45pt đó và chỉ cho Google Maps: MultiTA lại nạp vào CarPlayTemplateUIHost nhưng chỉ với một hook UIWindow.layoutSubviews; các thí nghiệm khác vẫn tắt. Filter thêm com.apple.CarPlayTemplateUIHost.

2. Kéo divider về cạnh để giữ YouTube (bên trái) thì CarPlay lại hiện Google Maps toàn màn, vì 0.37+ bỏ qua việc mở lại YouTube. Giờ YouTube được mở native TRƯỚC khi rời chia màn (hai ô vẫn giữ app, yêu cầu đưa app bên kia xuống nền bị từ chối), 1.5s sau mới rời chia màn — đúng thứ tự an toàn tìm được ở 0.45. Log: COLLAPSE native launch before release.

## 0.45 — giữ app cũ trong ô cho tới khi app mới sẵn sàng

Log 0.44: Google Maps + Vietmap → đổi ô phải sang YouTube (chưa chạy) → CarPlay treo 62s. So toàn bộ lần mở vào ô: mọi lần treo (0.39 Apple Maps→YouTube, 0.43 YouTube Music→Zalo, 0.44 Vietmap→YouTube) đều xảy ra ngay sau khi Dashboard đưa xuống nền đúng app vừa được gỡ khỏi ô; mọi lần mở YouTube thành công thì yêu cầu đưa xuống nền rơi vào một app vẫn đang ở trong ô và bị từ chối.

Giờ khi đổi app trong một ô bằng cách mở qua Dashboard, app cũ vẫn ở trong ô (bị che bởi "Đang mở …") cho tới khi app mới sẵn sàng; yêu cầu đưa nó xuống nền của Dashboard bị từ chối như các lần thành công. Khi app mới sẵn sàng, app cũ mới được gỡ và chính tweak đưa nó xuống nền. Log: LAUNCH IN PANE keeps …, SLOT CLEAR … replaced after launch.

## 0.44 — bản nền ổn định

Không còn code nào chạy bên trong app: Filter chỉ còn com.apple.CarPlayApp và %ctor thoát với mọi tiến trình khác. Tắt toàn bộ thí nghiệm giao diện kế thừa TAduo (lấy lại 45pt bên trái, rút gọn tab, co hàng ảnh, ẩn thanh cuộn, bỏ ảnh bìa Now Playing). App template trong ô có thể dư dải trống bên trái; chữ tab có thể bị cắt. Sẽ bật lại từng thứ một sau khi nền ổn định.

Sửa lỗi của 0.43: kích thước native học riêng cho từng app và không vượt độ rộng màn (0.43 học 426pt từ CleanTA rồi trả YouTube về 426pt, đè Dock).

App đi qua cầu nối (không phải app CarPlay, không phải Apple, trừ YouTube) chưa chạy thì không mở vào ô: ô báo "Mở … ở ngoài trước rồi chọn lại" (Zalo làm CarPlay treo ngay lúc khởi động khi đang chia màn). App đó đã chạy thì mở vào ô như thường. Log: LAUNCH IN PANE refused cold bridged app.

## 0.43 — sửa khung app bị kẹt ở cỡ ô, ô trống do view giả

Ảnh 3 (Google Maps mở toàn màn sau khi thoát chia): bản đồ chỉ chiếm ~208pt, phần còn lại là hình nền — scene vẫn giữ cỡ ô. Nguyên nhân: "kích thước gốc" được đọc lúc gắn vào ô, nếu scene đang mang cỡ ô cũ thì khôi phục về đúng cỡ sai đó. Giờ tweak học kích thước app native lớn nhất trên màn này; không bao giờ lấy cỡ nhỏ hơn làm kích thước gốc (ORIGINAL FIXED), và khi một app lên toàn màn với khung nhỏ hơn thì tự sửa lại (NATIVE FRAME REPAIRED).

Ảnh 1 (ô phải tối trống): Apple Maps gắn trực tiếp trả về UIView thường chứ không phải _UIScenePresentationView → ô không có app. View như vậy giờ bị huỷ và coi là "không có hình"; tự thử lại một lần qua Dashboard (AUTO RETRY via Dashboard).

Bỏ lịch PANE CHECK của 0.42: view native của Dashboard không chứa context nào trong lúc ô đang hiển thị, nên phép so luôn rỗng.

Còn mở: ô chỉ hiện hình nền với app template (YouTube Music lúc 11:26:08) dù đã mở qua Dashboard. Cần log template (/var/mobile/MultiTA-beta-template.log) cùng thời điểm.

## 0.42 — tự phát hiện và dựng lại ô chỉ còn hình nền

Log 0.41: mọi lần mở vào ô đều báo ATTACHED với surface=1 nhưng ô phải vẫn chỉ hiện hình nền. surface=1 chỉ nói có một lớp hiển thị từ xa, không nói lớp đó còn đúng. Giả thuyết: ô được tạo khi app vừa khởi động; app sau đó thay "ngữ cảnh vẽ" của mình, ô vẫn trỏ vào ngữ cảnh cũ.

Kiểm tra sau khi gắn 1.5s và 4.5s: so các context id mà ô đang hiển thị với các context id mà chính Dashboard đang hiển thị cho app đó. Nếu không trùng cái nào, dựng lại riêng khung nhìn của ô (không đụng tới app), tối đa 3 lần. Mọi app mở vào ô (không riêng YouTube) giờ chờ hình gốc của app xuất hiện ≥1s (tối thiểu 1s, tối đa 4s; YouTube 2s/2s/6s). Log: PANE CHECK, PANE REFRESH.

## 0.41 — app đang ở nền cũng mở qua Dashboard vào ô

Log 0.40: ô phải (mở app qua Dashboard ngay trong ô) ổn; ô trái chọn YouTube rồi YouTube Music — cả hai đang ở nền — được kéo lên bằng lệnh foreground trực tiếp và ô chỉ còn hình nền. Giờ chỉ app đang hiển thị native ngay lúc đó mới được gắn trực tiếp; mọi app đang ở nền (kể cả app đi kèm khi kéo cạnh, và khi khôi phục cặp) đều được mở qua Dashboard ngay trong ô như 0.39–0.40. Mỗi lần chỉ một lệnh mở; lệnh thứ hai xếp hàng ("Chờ mở …"). App không có trong danh mục Dashboard thì gắn trực tiếp nếu còn cảnh sống. Log: LAUNCH IN PANE queued.

## 0.40 — chờ YouTube sẵn sàng, không ghép app chạy ngầm, thử lại bằng cách mở lại

Log 0.39 (máy sạch): YouTube được mở vào ô và gắn ~1s sau lần khởi chạy → CarPlay treo 48s (mất cảm ứng) → khởi động lại. Mở YouTube ngoài trước rồi mới chia thì ổn. Với app không phải template (YouTube), việc gắn vào ô chờ tới khi hình gốc của app (Dashboard vẽ phía sau cửa sổ chia màn) đã xuất hiện ≥2s, hoặc tối đa 6s kể từ lúc mở; không bao giờ sớm hơn 2s. App template vẫn gắn sau 0.8s yên. Thời gian chặn đưa-xuống-nền kéo dài thành 14s, hạn mở 16s. Log: LAUNCH IN PANE native picture seen.

Kéo cạnh chỉ ghép với app người dùng thực sự mở trong phiên CarPlay này (có launch source) và lần gắn gần nhất có hình. Apple Maps tự khôi phục ngầm khi cắm (không có launch source) không còn được tự ghép.

Gắn vào ô mà không có hình trong 8s: app bị đánh dấu; chạm thử lại (hoặc chọn lại app đó) sẽ mở nó qua Dashboard ngay trong ô thay vì gắn lại cảnh cũ.

## 0.39 — mở app chưa chạy ngay trong ô, không rời chia màn

Log 0.38: sau AUTO REJOIN, YouTube (bị đẩy xuống nền khi rời chia màn để mở app mới) được gắn lại và ô chỉ còn hình nền, tiếng vẫn chạy; VIDEO KICK không gỡ được. Kết luận: YouTube không vẽ lại sau khi bị đưa xuống nền rồi lên lại — nên không được để nó xuống nền.

Chọn một app chưa có scene giờ giữ nguyên chia màn: ô đó hiện icon + "Đang mở …", Dashboard khởi chạy app ở phía sau cửa sổ chia màn, và ngay khi scene sẵn sàng (≥0.8s yên) app được gắn vào đúng ô. Trong tối đa 8 giây của lần mở này, nếu Dashboard định đẩy xuống nền một app đang hiển thị trong ô, yêu cầu đó bị từ chối (gọi completion luôn, đánh dấu để khi thoát chia màn mới đưa xuống nền đúng cách). Không còn hộp thoại "Đưa app vào bên nào?" cho app đang được mở vào ô. Quá 12 giây chưa lên thì ô báo lỗi, chạm để thử lại. Log: LAUNCH IN PANE, BACKGROUND DECLINED.

## 0.38 — giữ đúng cặp khi đổi sang app chưa mở, gỡ YouTube đứng hình

Log 0.37: CarPlay không còn MAIN STALL; nút Màn hình chính chạy (HOME via _homeTapped:). Kịch bản lỗi: Maps + YouTube → đổi ô trái sang YouTube Music (chưa có scene) → mở toàn màn → kéo cạnh ghép YouTube Music với app dùng gần nhất (Maps) thay vì YouTube, và YouTube vừa bị đẩy xuống nền.

Giờ khi chọn app chưa có scene: nhớ app mới, bên cần đặt, và app giữ lại ở bên kia. App template (YouTube Music, Maps, Vietmap…) được tự ghép lại đúng cặp, đúng bên sau khi đã mở ổn định ≥1.25s (AUTO REJOIN). App không phải template (YouTube) thì không tự ghép (tránh treo như 0.31–0.33); lần kéo cạnh tiếp theo trong 3 phút sẽ dùng đúng cặp và đúng bên (EDGE PULL uses remembered pair).

YouTube đứng hình còn tiếng: người dùng gỡ bằng bấm bài trước/sau. Khi một app không phải template (YouTube) được gắn lại vào ô sau khi ở nền, hoặc lên toàn màn sau khi từng ở trong ô, nếu đúng app đó đang phát thì gửi Tạm dừng rồi Phát sau 0.35s để trình phát vẽ lại hình (VIDEO KICK). Không đổi bài; có thể nghe một nhịp ngắt rất ngắn.

## 0.37 — không nạp vào YouTube, sửa Home, sửa nhận diện gián đoạn

Log 0.36: không còn MAIN STALL của CarPlay khi mở lại YouTube, nhưng YouTube vẫn đứng. Bỏ YouTube khỏi Filter và chặn trong %ctor: không còn hook nào chạy trong tiến trình YouTube (mất phần ẩn thanh cuộn 44pt của YouTube trong ô hẹp). Bộ đo treo trong YouTube của 0.36 không ghi được log vì YouTube bị sandbox — đã bỏ.

Home: log 0.36 liệt kê DBDashboard có -_homeTapped:(id), -_handleHomeEvent:(id), -_handleReturnToHomeScreenEvent:(id). Nút Màn hình chính gọi -_homeTapped:nil (hành động của nút Home trên Dock).

Nhận diện lùi xe: mỗi controller đều nhận thông báo cho mọi scene bị huỷ nên 0.36 báo nhầm "nhiều app bị huỷ". Giờ chỉ tính khi scene bị huỷ là scene của chính controller đó.

## 0.36 — màn rộng, YouTube, Home, lùi xe

Màn rộng (CarPlay không dây 640pt): giới hạn tính theo điểm thay vì phần trăm cố định. Ô nhỏ nhất 128pt (màn 426pt giữ đúng 30/70, màn 640pt thành 20/80). Thoát chia màn khi ô nhỏ còn dưới ~60pt; kéo cạnh bị huỷ khi kéo chưa tới ~72pt (trước đây là 20% màn = 128pt trên màn rộng). Dải kéo cạnh 16–18pt theo độ rộng màn. Ngưỡng bắt đầu kéo 9pt (trước 12pt).

YouTube: không tự mở lại toàn màn một app không phải template (YouTube qua cầu nối) sau khi kéo divider về cạnh; log COLLAPSE skip native relaunch. Tiến trình YouTube có bộ đo treo riêng (CLIENT LOADED youtube, MAIN STALL pid=<youtube>) để phân biệt YouTube treo hay CarPlay treo.

Home: ghi một lần các phương thức "home" của DBDashboard (HOME candidate) và thử các phương thức không tham số có tên kiểu go/show/open/press/tap/handle/return + home.

Lùi xe: log 0.35 cho thấy camera lùi làm iOS huỷ cửa sổ của nhiều app cùng lúc và đổi hình dạng màn. Tweak theo dõi trạng thái phát (MediaRemote) mỗi giây; khi màn CarPlay mất/đổi hình dạng hoặc cửa sổ của ≥2 app bị huỷ trong 0.5s, ghi lại có đang phát không; khi màn trở lại (hoặc app lên lại), nếu trước đó đang phát mà giờ im thì gửi lệnh Phát sau 2.5s, kiểm tra lại và gửi thêm lần nữa ở 5s. Không làm gì nếu trước đó không phát hoặc gián đoạn quá 5 phút. Log: INTERRUPTION begin/end, RESUME play sent.

## 0.35 — giữ 1 giây để mở trang Tác vụ

Thao tác mới: chạm 1 lần gần divider/tay nắm chỉ để hiện divider; nhấn giữ từ 1 giây trở lên vào divider hoặc tay nắm thì mở trang "Vạn dặm bình an!". Chạm 2–3 lần vào tay nắm vẫn là đổi app. Bỏ chạm đúp divider về 5:5 (chạm để hiện divider hay vô tình đưa tỉ lệ về 5:5). Việc giữ được nhận cả qua bộ nhận nhấn giữ lẫn qua bộ đếm thời gian trong đường kéo (màn xe rung tay có thể làm cú giữ bị hiểu là bắt đầu kéo). Chặn yêu cầu kích thước scene lớn hơn màn hình (log template có một lần 443pt trên màn 426pt). Log: HOLD open.

## 0.34 — nhẹ hơn, mũi tên đổi trái ↔ phải trên tay nắm

Hiệu năng: tắt toàn bộ chẩn đoán kế thừa từ TAduo (kTADiag=NO): dump cây view/constraint mỗi lần màn hình template xuất hiện, báo cáo kích thước CLIENT sau mỗi lần layout cửa sổ, ghi vết chạm trong app, quan sát resize 3 mốc 0.25/1/3s. Bỏ mọi UIVisualEffectView (kính mờ) — tay nắm, thẻ Tác vụ, biểu tượng đổi app, nút bảng chọn — thay bằng nền tối đặc bán trong suốt; kính mờ đè lên bản đồ phải vẽ lại mỗi khung hình. Quét tìm Dock chỉ 5 giây/lần khi chưa tìm thấy (trước đây mỗi giây).

Đổi vị trí: nút tròn mũi tên hai chiều (arrow.left.arrow.right, cyan) nằm ngay trên tay nắm, cùng tự ẩn sau 3 giây nhưng vẫn chạm được khi ẩn. Chạm = đổi app trái ↔ phải (mỗi app giữ nguyên độ rộng, không resize), mờ đi khi chưa đủ hai app. Log: SWAP tap.

## 0.33.1 — tránh treo khi chọn app chưa mở (YouTube)

Log thiết bị cho thấy 3/3 lần: chọn YouTube khi nó chưa có scene sống → PREPARE (mở native) → dựng lại cặp ngay → luồng chính CarPlayApp bị chặn 16–58s → watchdog khởi động lại. Chọn YouTube qua kéo cạnh thì không lỗi. Bỏ việc tự dựng lại cặp sau khi mở native: chọn một app chưa có scene sống sẽ thoát chia màn và mở app đó toàn màn; muốn chia thì kéo cạnh phải (ghép với app dùng gần nhất). Loại com.apple.InCallService (giao diện cuộc gọi) khỏi danh sách chọn. Log: OPEN NATIVE.

## 0.33 — trang Tác vụ tối giản

Trang Tác vụ chỉ còn dòng "Vạn dặm bình an!" cỡ lớn (38pt, tự thu nếu thiếu chỗ) và hai nút tròn: biểu tượng Màn hình chính CarPlay (cam) và ô tô (cyan). Màn hình chính: thu chia màn (giữ cặp app để mở lại) rồi thử gọi selector Home của DBDashboard nếu có; log HOME via … hoặc HOME no dashboard selector. Ô tô: đóng trang. Bỏ danh sách tác vụ; đổi app bằng chạm hai lần tay nắm, đổi tỉ lệ/thoát bằng kéo divider.

## 0.32 — ưu tiên app dẫn đường/giải trí, giao diện chọn app và trang Tác vụ mới

Bảng chọn app sắp theo nhóm: dẫn đường trước, rồi giải trí (nhạc, video, podcast, radio), rồi app khác; trong mỗi nhóm app dùng gần nhất đứng trước. Nhận nhóm theo danh sách bundle ID đã biết, thể loại App Store (genreID 6010/6011/6016/6008) và từ khoá trong bundle ID. Nút đóng, mũi tên trang dạng kính mờ tròn với SF Symbol; chỉ số trang dạng chấm (trang hiện tại là viên cyan) kèm "1 / 3" font bo tròn.

Trang Tác vụ thay UIAlertController bằng thẻ kính mờ riêng: dòng chữ "Vạn dặm bình an!" gradient cyan→cam, danh sách tác vụ cuộn được, dưới cùng là nút ô tô — chạm để đóng trang (ô tô chạy sang phải). Chạm ra ngoài thẻ hoặc chạm tay nắm cũng đóng. Log: ACTIONS open.

## 0.31.2 — tay nắm bị divider che

Log 0.31.1: không có dòng HANDLE TAP nào, nhưng có hàng loạt DIVIDER ratio=0.500 khi chạm tay nắm. Nguyên nhân: khi mở chia màn bằng kéo cạnh, thanh ray (divider) được đưa lên trên cùng và nằm đè lên tay nắm; chạm vào tay nắm thực ra rơi vào divider, và bộ nhận chạm đúp của divider đưa tỉ lệ về 5:5. Giờ tay nắm luôn được đưa lên trên divider sau khi kéo cạnh.

## 0.31.1 — sửa đổi app bằng tay nắm, bỏ phần bàn phím

Bỏ hoàn toàn thử nghiệm bàn phím tìm kiếm toàn màn (0.31), quay về mã 0.30 để tránh đè hook. Nguyên nhân chạm tay nắm không vào chế độ đổi app: ngón tay rung nhẹ trên màn xe làm cú chạm bị nhận thành kéo divider (hiện lớp che icon, huỷ chế độ đổi app). Giờ kéo chỉ bắt đầu khi ngón tay đi quá 12pt; dưới mức đó cú chạm được tính là một lần chạm tay nắm. Tay nắm đếm chạm thủ công (khoảng chờ 0.6s): chạm lần 2 vào chế độ đổi app, chạm 1 lần mở menu Tác vụ sau 0.6s. Ô đổi app nhận chạm khi nhấc tay, không phụ thuộc rung. Log: HANDLE TAP, CHANGE MODE.

## 0.30 — tay nắm mới, tự ẩn, chạm hai lần để đổi app

Hai ô chỉ cách nhau 4pt; vùng chạm của divider giữ nguyên (rộng ~16pt + 6pt mỗi bên, đè lên mép hai ô). Nền divider trong suốt, vạch mảnh 2pt. Nút ••• thay bằng tay nắm dạng viên thuốc 22×60 nền kính mờ tối, viền mảnh, ba chấm; vùng chạm 56×88. Tay nắm và vạch divider tự mờ sau 3 giây; vùng chạm vẫn hoạt động khi đã ẩn. Chạm gần divider (±48pt) thì hiện lại; chạm trong app thì không.

Chạm 1 lần vào tay nắm: menu Tác vụ (trễ ~0.3s để chờ xem có phải chạm đúp). Chạm 2 hoặc 3 lần: hai ô hiện biểu tượng vòng xoay + chữ "Chạm"; chạm ô nào thì mở bảng chọn app cho ô đó (app đã mở đứng đầu). Tự tắt sau 6 giây hoặc chạm tay nắm lần nữa. Ẩn hẳn nút vuông cyan/cam góc trên phải; dải kéo cạnh phải giờ chạy gần hết chiều cao. Log: CHANGE MODE.

## 0.29 — kéo divider về sát cạnh để thu chia màn

Ngoài khoảng 30–70% divider vẫn đi theo tay (chậm lại ~55%) để có thể kéo về phía cạnh. Qua mốc 88% (hoặc 12%) vạch grip đổi sang màu cam: thả tay lúc đó là thoát chia màn. App ở ô còn lại (ô lớn) trở về toàn màn native; nếu đó không phải app đang mở native trước khi chia thì mở nó qua Dashboard. Thả trước mốc cam thì bật về 30/70 như cũ. Log: COLLAPSE.

## 0.28 — nhấn giữ cạnh phải rồi kéo để chia màn

Khi một app đang mở toàn màn trên CarPlay (đã mở qua CarPlay ít nhất một lần), cạnh phải màn có tay nắm mỏng (dải chạm 16pt, bắt đầu dưới nút launcher góc trên). Nhấn giữ 0.3s rồi kéo sang trái: thanh ray tối màu có icon app đi kèm theo tay, app đang mở co về ô trái; tới 70/30 thì thành divider thường và tiếp tục theo tay trong khoảng 30–70% cho tới khi thả. Thả khi còn sát cạnh (>80%) thì huỷ, app giữ nguyên toàn màn. Thả ở chỗ khác thì chốt tỉ lệ rồi mới gắn app: ô trái là app đang mở, ô phải là app dùng gần nhất khác (hoặc bảng chọn app nếu chưa có).

Bỏ trigger A→Home→B→Home của 0.27. Dải 16pt ở cạnh phải không nhận chạm của app khi tay nắm hiện. Chưa build/test trên máy.

---

# TAduo 0.21.0 — thử nghiệm 50/50

Dựng lại từ cơ chế capture/foreground/presentation của Duophone 6.40 (commit a17518d8751314c8ca5b44170b73430ad866bbcf). Không kế thừa các patch safe-area, offset riêng Google Maps, giả lập callback, snapshot recovery hoặc sửa cây view của app.

## Cài và thử

- Dành cho Dopamine rootless, iOS 15 trở lên; cần kiểm chứng thực tế trên iOS của thiết bị.
- Giữ DEB Duophone cũ để quay lại. Gỡ Duophone trước khi cài TAduo; hai gói khai báo xung đột để tránh cùng hook. Tắt MiniTa/DuoDash và các tweak chia màn hình khác trong lần test này.
- Kết nối CarPlay, mở Maps rồi YouTube Music từ dock mỗi app một lần.
- Chạm TAduo, chọn app cho từng ô. Có thể chọn ô phải trước.
- Hai ô bằng nhau, dùng toàn bộ chiều cao; menu ••• ở giữa có Chia / Log / Thoát. Không kéo divider ở bản này.
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

## Thử nghiệm 0.3 — layout template

Log 0.2 của thiết bị xác nhận scene/window/root đã nhận 213.33 x 208 điểm; ảnh vẫn chồng chữ. Giữ nguyên đường geometry này.

0.3 chỉ bật chỉnh layout trong CARTemplateUIApplicationSceneViewController khi scene khớp đúng kích thước mà phiên TAduo đang yêu cầu. Bù phần safe-area ngang kế thừa ở root (giới hạn 25% chiều rộng mỗi cạnh), giữ nguyên top/bottom, làm mới constraints và collection layout có giới hạn. Không đặt frame từng nút, không sửa cỡ chữ, không ép trait hoặc screen.bounds. Khôi phục additionalSafeAreaInsets đã lưu khi thoát.

Đây là thử nghiệm có giả thuyết safe-area/layout cache, chưa chứng minh nguyên nhân duy nhất hay đã sửa chồng chữ. Phác họa giao diện là mục tiêu, không phải cam kết rằng template hệ thống hỗ trợ bố cục đó ở chiều rộng 213 điểm.

Cài 0.3, respring và mở lại app. Test YouTube Music + Google Maps. Gửi ảnh và cả /var/mobile/TAduo.log lẫn /var/mobile/TAduo-template.log. Log template ghi safe-area, traits và tối đa 60 view sau một lần áp dụng; không ghi nội dung bài hát/tìm kiếm. Mỗi file xoay khoảng 1 MiB, giữ một bản cũ.

## 0.4 — full chiều cao

Bỏ thanh tiêu đề 32pt. Hai ô bắt đầu ở y=0 và nhận toàn bộ chiều cao màn hình (trên thiết bị test: 213.33 x 240 thay vì 213.33 x 208). Nút Chia và Thoát nổi ở góc trên trái/phải, chỉ vùng nút nhận chạm và có thể che một phần nhỏ nội dung phía dưới. Chia trả geometry cũ rồi mở lại hai ô trống để chọn lại app. Giữ nguyên xử lý template 0.3 để tách tác động của thay đổi chiều cao. Không thêm divider kéo.

## 0.5 — chuyển màn và thu gọn tác vụ

Giữ geometry 213.33 x 240 đã được xác nhận trên thiết bị. Thu Chia/Thoát vào nút ••• ở chính giữa màn, trên đường chia hai app; thêm Log để chụp trạng thái layout đang hiển thị. Nút nổi nhỏ vẫn có vùng che nội dung.

Khi controller của template xuất hiện trong scene TAduo đang quản lý, yêu cầu làm mới constraints/collection layout một lần, ghi cây view sau 400ms. Log sâu tối đa 14 tầng/180 view để tới nhãn Đang phát; ghi font, số dòng, intrinsic size, không ghi nội dung text. Có giới hạn trùng sự kiện và xoay file. Đây chưa phải bản sửa trực tiếp font/frame của màn Đang phát.

Test: mở Google Maps + YouTube Music; vào màn Đang phát, chờ 2 giây; bấm ••• → Log khi chữ chồng. Chụp ảnh và gửi TAduo.log, TAduo-template.log (kèm .1 nếu đã xoay). Thử Quay lại rồi vào Đang phát một lần nữa để so sánh.

## 0.6 — narrow template adapter (experimental)
Runtime evidence: song details height 2.33pt and tab label 72pt inside a 53pt button. Within active TAduo scenes under 300pt only, post-layout adapters reserve song text height, reduce artwork, constrain tab labels, and arrange image-row items equally with square artwork. This is a template-specific layout adapter, not native system support for virtual displays. Original system layout runs first; adapters stop outside the active target. Verify home, Now Playing, tab switching, and exit back to native full screen on device.

## 0.7 — own adapter geometry and restore constraints
0.6 device evidence: song outer frame 55pt, inner title still 0pt; tab labels retain overflowing widths. Save/deactivate placement and own-size constraints for adapter-managed views, preserving descendant constraints. Reapply song/image-row layout after stack layout, and tab-label bounds after button layout. Restore saved constraints and autoresizing-mask settings when the TAduo target clears. Device validation required, especially native layout restoration and touch alignment.

## 0.8 — recovery baseline
Restore the exact 0.5 centered-actions implementation, with version identifiers bumped to 0.8. Remove all template-specific frame and constraint adapters introduced in 0.6/0.7. Latest freeze report's host log still identified 0.6; no crash report was supplied, so the termination cause and installation of 0.7 are unconfirmed. This recovery intentionally retains known narrow-template visual defects. Validate touch, 60-second session, exit, and re-entry before further layout experiments.

## 0.9 — native/split comparison diagnostics
Uses 0.8 layout behavior. Captures native Now Playing on appearance and settled geometry after target changes, including exit. Read-only bounded constraint attributes, class/pointer relationships, priorities, ambiguity, screen/window geometry, and relevant method names (never invoked). No new frame/constraint edits. Test native Now Playing first, enter split and log Now Playing, then exit and wait two seconds. Collect both log files, including .1 if rotated. The launch button shows 0.9.

## 0.10 — native Now Playing without artwork in narrow active panes
Device 0.9 evidence: native song minimum height 68pt; split 2pt, with artwork above the song details. Runtime exposes recalculateLayout:allowsAlbumArt:hasDataSource:viewArea:safeArea:rightHandDrive:. Guard its exact observed ABI and pass allowsAlbumArt=NO only in an active TAduo scene with viewArea width under 300pt. All other inputs and native/full-screen calls remain unchanged. No child frame changes, constraint deactivation, or recursive layout calls. This tests the system's no-art layout; it does not fix tabs or image rows. Compare same song native/split/native, touch and exit, and collect NATIVE LAYOUT plus geometry logs.

## 0.11 — native tab title fitting; image-row diagnostics
Keep 0.10 geometry and Now Playing behavior. Device test of 0.10: 3m17s before user exit, successful restore/re-entry, user confirms responsive touch with no freeze. Baseline commit: 78ca0c3135f4bfaa7eca1c0b14f5d2b724ef8f62.

Only in active narrow YouTube Music template windows, shorten long UITabBarItem titles using composed-character-safe ellipsis and the available per-item width. UIKit lays out its own buttons; no child frame/constraint changes. Save and restore original titles/accessibility labels, respect incoming app title changes, and restore tracked bars on target-clear even when hidden behind Now Playing. No synchronous layout calls or repeat timers.

Image rows are not fixed in this build. Add bounded read-only CPSImageRowCell method signatures and stack configuration evidence to choose the next native layout input. Test home tabs and rows, tap each tab, open Now Playing, exit to native home and confirm full titles return. Capture home with ••• → Log and send both current logs plus screenshot. Build success is not device validation.

## 0.12 — equal square image-row buttons
0.11 device photo confirms tab labels no longer overlap. Image rows still squeeze unequal widths. The device reports horizontal equal-spacing stacks with four buttons, each with required fixed 61pt width and height, in a 135.33pt row.

Scoped to active narrow YouTube Music scenes and verified CPSImageRowCell structure: wait for the native row-width constraint to match cell width minus its observed 12pt margins, then reduce only each matched 61pt width/height pair to a common square size, allowing at least 6pt inter-item space. Keep row height, stack distribution, frames, callbacks and selection actions native. Skip unknown structures and sizes below 20pt. Save constants weakly; restore on target clear, ordinary non-target layout, and cell reuse, without overwriting a newer system value. At most one adaptation attempt per geometry/constraint set to avoid repeatedly fighting native layout. No constraint deactivation, recursive layout, new gesture recognizers, or polling.

This is a template-specific adaptation, not proof that arbitrary apps support narrow CarPlay screens. Artwork rendering and tap selection require device validation. Test home image rows, scroll, select each cover, enter Now Playing, exit to full screen and re-enter. Capture a home screenshot and both logs using the centered Log action.

## 0.13 — resume split after native Home/navigation launch
Includes the unvalidated 0.12 image-row experiment. Save selected bundle IDs when Home, a different native launch, or scene destruction interrupts a split. Restore geometry and release presentations before native navigation. The TAduo button restores valid current records; when a newly launched app is available, ask which side to replace and preserve the other side. Missing records leave an actionable empty picker. Explicit Exit, Chia, and display disconnect clear the saved selection. Nothing is persisted across respring.

Recognize real foreground dictionaries for supported navigation apps even without DBActivationSettingLaunchSource; capture once again on the next main-queue turn if the scene ID was late. Match the current dashboard, preserve active records, and never stop for an in-session foreground refresh of the same controller. Pin saved/active apps in a 24-entry recent list. Show the launch button with one known app or a saved session. No forced relaunch timer, synthesized activation dictionary, or UI touch override.

Device validation: Maps + music → CarPlay Home → Apple Maps or Vietmap → TAduo → choose left/right → verify companion preserved and both touch inputs work. Repeat with the other map, then native Home without opening a different app → TAduo should restore the pair. Explicit Exit should discard resume. Capture both logs before respring; verify SESSION SAVED/CAPTURE/ATTACHED chronology.

## 0.14 — change one pane, fold, swap and recent pairs
Centered actions: Đổi trái / Đổi phải / Đổi bên / Thu / Cặp gần / Log / Thoát. Pick known apps by readable name, newest first. Replacing one pane releases only that record. Foreground/presentation failure or scene destruction resets only the affected pane. Per-slot request IDs reject stale delayed attachments after replacing or swapping. Swap requires two attached presentations and changes only their parents at fixed 50/50 geometry. Keep up to four recent completed pairs in memory; disabled pairs need apps reopened. Thu retains the selected pair and shows native CarPlay again; Exit clears resume. These controls do not directly invoke native Home or launch an unseen app.

Google Maps review: template root is 213.33x240, but the nested map viewport is x45/y44, width168.33, height196. Latest 0.13 snapshot was native/full width, not split. Add bounded read-only controller method signatures and exact map-owner constraints/child frames, including during search transitions. No speculative global offset or frame correction. Need split-map and split-search screenshots plus logs to distinguish cached dock offset from intentional map layout.

Test changing Maps to Apple Maps/Vietmap while music remains, failed-pane recovery, swap, Thu → native Home → open map → TAduo, and a recent pair. Log Google Maps first on map, then search menu. Do not claim device stability from compile success.

## 0.15 — bounded activation readiness and pending-scene identity
Replace fixed one-second capture with a bounded readiness check (250ms, minimum two turns, maximum four seconds). Foreground is called once; each check reads the current controller scene. During an outstanding attach, native foreground/Home-animation callbacks no longer tear down the split session. Capture may replace a pending controller with the current controller for the same bundle and dashboard. Preserve real launch activation settings when later refresh callbacks omit launch source. Identify occupied apps by bundle as well as controller pointer. Use unique presentation IDs per slot request; timeout, scene mismatch and presentation failure clear only the affected slot.

This is a hypothesis-driven fix for navigation activation, not a confirmed root cause from the sparse 0.14 logs. Test Đổi trái/right → Apple Maps/Vietmap, keep companion visible, allow up to four seconds, no repeated tapping. Send logs containing ATTACH BEGIN / ATTACH REBIND / ATTACHED or ATTACH TIMEOUT, plus a screenshot if no attach request appears. Google Maps diagnostics and 0.14 menu remain.

## 0.16 — keep split during native app transitions

Native app foreground and app-to-home presentation callbacks no longer stop the split session. An external launch with a captured launch source offers left/right placement without first clearing either pane; a busy picker defers selection to the existing Change menu. Explicit Fold/Exit retain their prior behavior.

Scene destruction checks scene identity before clearing an affected slot, never clears the companion, and retains the controller/activation record for an explicit retry (not a guarantee that the OS will recreate its scene). Added bounded event logs for foreground and scene destruction. Existing resize behavior is unchanged.

Device gate: attach Apple Maps and Vietmap separately; replace either side of Google Maps + YouTube Music; verify companion touch and no split dismissal. Also check native external launch and explicit Fold/Exit. Build success is not device validation.

## 0.17 — minimal controls and per-pane app grid

Cyan/orange vector split icon mounts inside the discovered native vertical DBDock view. Uniformly compacts its interactive content to reserve a 36pt button, preserving native icon aspect ratios. No top-right launcher. Dock discovery/placement requires device validation on iOS versions.

Full-height 50/50 panes initially say “Chạm để chọn ứng dụng”. Each pane offers a scrollable two-column grid of captured CarPlay apps, with system icons when available (initial-letter fallback), dimmed/disabled apps occupied by the companion, and cyan marking for the current selection. Apps must have been opened on CarPlay once; this is not an installed-app enumerator.

Divider controls: Swap, curved-arrow Fold, Exit. Observe UIWindow sendEvent after forwarding; reveal for one second after touch without intercepting gestures. Long-press Swap for change-left/change-right/log; long-press Dock Split for log outside split. Explicit Fold and Exit retain 0.16 semantics. Existing geometry and lifecycle logic unchanged. Loading placeholder shows app icon but readiness still measures scene geometry, not first rendered frame.

Validation: CI arm64/arm64e rootless build; on-device gates are Dock accessibility and preserved native Dock buttons, both picker orders/scrolling/dimmed duplicate, touch/drag/pinch unaffected, timed divider reveal, Swap/Fold/Exit and map switching.

## 0.19 — clearer divider, rounded panes, activation queue

Use bold system glyphs and visible Vietnamese labels (Đổi / Thu / Thoát) on a 56pt opaque divider panel, still hidden one second after touch. Add 8pt corner radius, 3pt outer insets and 6pt central gap; request actual pane dimensions from each app, no transform scaling.

Serialize foreground/presentation attachment when the companion is still attaching (bounded 6s queue with generation/request cancellation), including pair resume and rapid picker choices. This removes overlapping TAduo activation requests; it does not establish the root cause of black rendered content or detect first rendered frames.

Long-press Đổi offers Tải lại ô trái/phải and logs before rebuilding only that slot. Selecting its current app again also retries it. Initial rendering readiness still uses scene geometry; device validation and logs are required for black panes. Built from 0.17 (047f604a), without 0.18 launcher fallback or Dock diagnostics. Native Dock integration remains unverified; the previously reported missing-launcher issue from 0.17 is not claimed fixed.

## 0.20 — launcher recovery on the 0.19 branch

Keep the rounded panes, 6pt gap, labeled divider controls, per-pane retry and serialized attachment from 0.19. Add only an independent cyan/orange split launcher when the native Dock button is not visible/hittable; place the fallback at top-right and hide it during split. No captured apps required.

Add bounded Dock hierarchy diagnostics at connection and on long-press launcher / manual log. Reset old Dock modifications on display change. Native Dock placement remains pending device evidence; the top-right launcher is a temporary recovery path. No new changes to scene activation or resize.

## 0.21 — installed catalog and fresh native activation (unbuilt draft)

Local change based on 0.20. Catalog merges captured apps with installed DBApplicationInfo CarPlay declarations and installed known test apps. It is not guaranteed to exactly match the customized Home roster. Native dashboard launch uses DBApplicationLaunchInfo initialized with application and activation settings, as found in MiniTa, with method-signature guards and no role/entitlement rewriting.

Pending requests wait for a fresh foreground callback to rebind the controller; a captured-controller fallback remains when native launch is unsupported. Build the presentation behind the loading placeholder and wait up to 8 seconds for a nonzero LayerHost context. This verifies a hosting connection, NOT visible pixels; unsupported layer structures fail visibly instead of claiming success. Error placeholder is tappable to retry, and the companion remains selected.

Not compiled or device-tested yet. GitHub connector currently fails with HTTP 400 Invalid MCP request metadata. Required gates: compile, catalog availability before first app launch, fresh app activation, Google Maps cold/warm attach, timeout/retry, companion input, Fold/Exit. Existing 0.20 install remains the last built artifact.

## 0.22 — unified actions and icon-only picker

Keep a visible 44pt ellipsis button at the divider. Its menu contains both app pickers, swap, recent pairs, individual retries, reset selection, Fold, log and Exit. Picker tiles show only icons, with accessibility names retained, current-app cyan borders and companion-app disabling.

A shared case-insensitive bundle filter excludes CarPlay shell pages (including Settings, Wallpaper and TemplateUIHost), SpringBoard, Home and Siri service entries from both captured scenes and installed candidates. It keeps Apple Maps/Music and third-party apps; existing CarPlay eligibility checks still apply.

Device checks: open both pickers before launching apps; check no Wallpaper/Settings/Home entries or visible app names; scroll and select each side; use all ellipsis actions, including cancel/reopen, retries and recent pairs. This UI/filter change does not establish a fix for the existing black-scene/crash issue.

## 0.23 — retain the companion scene, picker touch handling

Device evidence from 0.22: at 06:09:44 UTC, YouTube Music attached successfully, then native backgrounding of Google Maps reset its client geometry from 207.25x234 to 426.75x240. Hold native background requests only for live independently hosted split scenes; validate the completion block ABI before acknowledging, otherwise use the original path. Remember the deferred background state so pane release/Fold/Exit can perform the real background. A single guarded post-callback geometry check repairs a reset without repeated foreground launches.

Picker buttons now respond without the scroll-view touch delay; real drags cancel selection, deceleration stops on contact, and bounce is disabled. This targets the TAduo app chooser, not arbitrary native-app gestures. Add up to 40 passive input summaries per targeted client window to diagnose reported taps turning into scrolls inside hosted apps. No global input remapping.

Device gates: Maps first then YouTube Music, reverse order, switch each side, retry, swap, Fold/restore and Exit. Confirm BACKGROUND HELD and both panes remain visible and interactive. If hosted-app taps still scroll, reproduce several taps and one deliberate swipe then collect both logs for INPUT records. Build success alone does not establish either device fix.

## 0.24 — stable picker pages and scene-lifetime correction

0.23 device logs show Google Maps pending with no bound scene, then an unrelated destruction notification cancels that request. Only destruction of the exact owned scene now triggers deferred pane cleanup; an unbound request waits for its existing timeout.

Replace the scrolling app chooser and custom touch tracking with fixed icon pages and Previous/Next buttons. At the observed 207x234 pane size, each page holds six icons. Catalog order is retained across pages. Native app gestures remain native.

Move file writes/rotation to a serial background queue with append writes, pause Dock discovery/compaction during split, and remove automatic Dock tree dumps. A held background completion is delivered asynchronously to avoid reentering the native transition. Passive touch summaries now also cover two-component native/CarBridge scene IDs such as YouTube.

After YouTube attaches at 06:19:18, 0.23 stops producing scheduled observations and the host logs LOADED at 06:20:17 without STOP. This supports a host restart, not a proven exception or watchdog cause. Add a low-frequency off-main responsiveness probe (at most one pending main-queue ping). A matching CarPlayApp .ips report is needed to identify the termination cause.

Device gates: page navigation/selection, cold Google Maps attach, Maps + YouTube interaction for at least one minute, replacement/retry, Fold and Exit. Neither compilation nor these mitigations prove the crash resolved.

User follow-up: remove the up/down arrow rail. The prior device hierarchy identifies `_UIStaticScrollBar` and `_UIStaticScrollbarButton` on YouTube Music's right edge. Hide and disable that exact rail in targeted split app windows; restore native visibility/interaction when the target clears or the rail leaves the window. Native scrolling remains enabled. This removes the rail's hit targets; it does not prove the rail caused all reported gesture errors.

## 0.25 — separate native preparation from split attachment

Replace always-native Dashboard launch plus suppressed background completion. An app with a live controller, matching display, valid scene frame and captured activation settings reuses its already foreground scene, or is foregrounded directly through that controller when backgrounded. No Dashboard app switch occurs on this warm path. Native background calls and their original completion arguments always run normally; the tweak never invokes a supplied native completion itself.

An uncaptured app is prepared outside split: save the pair, release/restore presentations, launch normally, wait for a fresh foreground observation, valid scene and at least 1.25s of transition quiet, then rebuild the saved pair through direct activation. Preparation is bounded to 10s and cancelled by display/session change or a tap on the split launcher. Automatic pair restoration cannot recursively prepare apps. A scene that is missing/backgrounded shows an explicit per-pane retry instead of a foreground loop.

Cold preparation can briefly show the app full-screen. Menu, icon pages, rounded geometry and hidden up/down rails remain. Existing surface checks do not prove visible pixels. Main-thread stall probe remains; native foreground/background and preparation return boundaries identify which operation fails to return.

Device gates: both Maps/YouTube launch orders, already-open versus cold YouTube, existing companion preserved on warm replacement, cancelled/timed-out preparation, rapid selection, retry, Fold/Exit and disconnect. This removes the suspect lifecycle bypass, but exact original termination cause remains unknown without a matching crash stack. Compile validation is not device stability validation.

## 0.26 — divider kéo được (30–70%)

Bỏ chia cố định 50/50. Divider rộng ~3% chiều ngang màn (số chẵn, tối thiểu 16pt, vùng chạm nới thêm 6pt mỗi bên). Kéo divider hoặc kéo chính nút ••• để đổi tỉ lệ; giới hạn 30%–70%. Kéo quá giới hạn vẫn đi theo tay có lực cản rồi bật về đúng 30%/70% khi thả. Gần 50% (±3%) tự hút về 5:5. Chạm đúp divider = về 5:5. Menu ••• thêm Tỉ lệ 7:3 / 5:5 / 3:7.

Trong lúc kéo chỉ di chuyển khung pane, app bị che bằng lớp tối có icon; resize scene (TAResize) chỉ chạy một lần khi thả tay, rồi bỏ lớp che sau 0.45s. Đổi trái ↔ phải lật tỉ lệ để mỗi app giữ nguyên kích thước (không resize). Tỉ lệ giữ nguyên qua Thu/Home, reset khi respring.

Device gates: kéo chậm/nhanh, kéo quá 30/70, chạm đúp, preset trong menu, Swap sau khi đổi tỉ lệ, kéo trong lúc một ô đang attach, Maps/YouTube layout ở ô 30%.

## 0.27 — chia màn tự động bằng thanh ray (A → Home → B → Home)

Mở app A → Home → mở app B → Home (trong vòng 5 phút) thì tự vào trạng thái chờ chia: B chiếm gần hết màn, bên trái là thanh ray tối màu rộng ~12% (tối thiểu 56pt) có icon app A. Kéo ray sang phải: ray thu nhỏ dần thành divider thường, ô A lộ ra; tới 30% (3:7) thì thành chia màn thường và tiếp tục đi theo tay tới 70% cho tới khi thả. Thả trước ~20% thì ray bật về, B vẫn lớn. Thả sau đó thì chốt tỉ lệ (tối thiểu 3:7), A được gắn vào ô trái, B resize một lần. Chạm một lần vào ray = mở 3:7, chạm đúp = 5:5.

Mỗi cặp Home chỉ kích hoạt một lần; Home liên tiếp từ cùng một app không kích hoạt; bỏ qua nếu B không còn scene sống. Bắt Home qua `kCARAppToHomeAnimationIdentifier` — cần log `HOME FROM` trên máy để xác nhận hook này bắn khi không chia màn.

Device gates: A→Home→B→Home với Maps/YouTube cả hai thứ tự, kéo chậm qua 30%, thả trước 20%, chạm/chạm đúp ray, Home khi đang ở trạng thái ray, Thoát rồi lặp lại luồng.
