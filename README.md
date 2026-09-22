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


## 0.10.1
Based on exact 0.10.0. Captured-app picker uses 32-point icons without visible names, six per page. Swap button sits above Log and exchanges the two existing presentations only after both attach. Log remains available. Attach, resize and scene lifecycle remain as in 0.10.0. Device validation required.


## 0.10.2 – native launch retention
Ports selected lifecycle handling from 0.16 onto 0.10.1: native launch/Home animation no longer stop the split, capture accepts navigation callbacks without launch-source, and attach requests foreground once then waits up to four seconds for scene geometry. Per-slot request tokens cancel stale work; failures clear only the affected pane. Old scene destruction cannot evict a newer attached scene. Background completion always goes to the original implementation. Chia now chooses the side to replace using the existing icon picker; swap and Log stay in their positions. No installed-app catalog or 0.21–0.26 activation changes. Native layout routines are retained from 0.10.1. Device test: open YouTube and Vietmap before entering, split each with another app, replace each via Chia, return from native app launch, repeat and inspect logs for stalls/black panes. Build success does not establish on-device stability.


## 0.10.3 – map presentation recovery trial
Device logs on 0.10.2 show Google Maps client root/window/scene match 213.33x240 and TemplateUIHost has map controls while the user sees a blank right pane. This does not establish the precise compositor failure. For Google Maps, Vietmap and Apple Maps, keep the loading placeholder until an attached LayerHost has a nonzero context. If missing after two seconds, recreate only that presentation once; no repeated foreground or native launch. Six-second surface timeout restores the affected pane to selection. Manual Log includes per-pane host/presentation evidence. Connected context is not proof of visible pixels. Keep YouTube attachment and all resize transactions/client layout unchanged; no new background interception.


## 0.10.4 UI
Cyan/orange split icon at top right and in actions. Action row is Split, Swap, Exit; no Log button or duplicate swap. Controls wake after original CarPlay touch delivery, stay during touch and app selection, hide after three idle seconds. Fixed panes have 6pt corner radius, 4pt gap, transparent noninteractive divider. Geometry is (display width - 4)/2 by full display height. 0.10.3 map recovery/scene lifecycle retained. Device validation required for external CarPlay touch delivery.


## 0.10.5 divider
Horizontal drag on center menu or transparent 20pt hit region around the 4pt gap. Pan preview adjusts containers; release submits one scene resize per pane. Cancel restores previous ratio. Each pane stays at least 140pt on the test display. Swap resizes both scenes to destination widths. Controls stay during drag and hide three seconds after release. Automatic post-resize snapshots capture Google Maps layout; screenshot alone cannot distinguish clipped controls from stale geometry, so no speculative map font/control patch. Map recovery and background lifecycle unchanged.

User refinement: remove center ellipsis entirely. Top-right split icon opens the three-action row directly below it while split is active; in native mode it starts split. Invisible center-gap drag region remains. Three-second auto-hide applies to the icon and opened menu.


## 0.10.6
Restore exact 0.16 YouTube Music tab-title and equal-size image-row helpers/hooks and restore callbacks. Google Maps narrow split title intrinsic size trial reserves toolbar space without changing icon transforms; device validation needed. Native split entry moves into detected DB Dock with reversible space reservation, no corner overlay fallback. During split tap transparent divider for menu and drag to resize; menu auto-hides and dismisses on outside touches. If native Dock detection fails no overlay is placed over app controls; report missing entry. No changes to attachment/recovery.


## 0.10.7 entry recovery
Keep a draggable 36x32 entry window whenever native Dock entry is absent, clipped, hidden, or fails its window hit test. Fallback stays visible outside split so users cannot lose access through an unobserved remote touch; moving it avoids app controls. During split the corner fallback is hidden and divider tap opens actions. Dock presence alone is no longer success. Music/Maps layout and scene lifecycle unchanged.


## 0.10.8 recovery
0.10.6 supplied logs have no START or DOCK MOUNT and just one template initialization line; freeze cause is not established. Remove Dock search/transforms and new Maps title-size override, restore pre-0.10.6 invalidation behavior. Keep 0.16-derived Music compact helpers. Floating draggable entry remains visible in native mode; divider opens actions in split. Add native foreground-return and main-loop gap evidence. 0.10.7 superseded before delivery.


## 0.10.9 diagnostic load reduction
No explicit phone-app launcher was found in 0.10.8: foregroundSceneWithSettings is used on the CarPlay controller during attachment. Remove direct Vietmap process injection (size observation only); keep CarPlay template integration and user-selected Vietmap split support. Disable automatic deep hierarchy/constraint dumps, divider snapshots and delayed appearance/target-settled diagnostic capture. Keep layout changes, Music compact helpers, attach timeout and low-volume lifecycle/geometry evidence unchanged. Heat causation is unproven; this is an overhead-reduction build, not a verified thermal fix. Google Maps narrow-pane inset guard and Vietmap presentation timeout remain unresolved.

Cleanup audit: delete retired menuButton/chromeVisible state and unbound snapshot selector, deep view/constraint/runtime-method walkers, snapshot notification listener, and delayed diagnostic capture scheduling. Retain native appearance layout invalidation, active menu/picker, divider gestures and scene recovery. No geometry/activation changes in this cleanup.


## 0.10.10 explicit controls and narrow-pane inset fix
Remove automatic offerNative modal entirely; native callbacks still capture applications and preserve split sessions. 0.10.9 log at 15:50:28 confirms a Vietmap event without launchSource triggered the old special-case offer. Reserve a 20pt ivory gap, 20x56 centered touch region, permanent 4x28 dark grip; tap opens actions, horizontal drag resizes, app touches do not wake chrome. Fix lateral inset guard: derive maximum inherited chrome from physical display (capped 64pt) rather than pane width. Previous 45pt dock inset failed below 180pt pane width, explaining the approximately 42% threshold on a 426.67pt display. Keep Music helpers and reduced diagnostics. Vietmap missing hosted surface remains unresolved; no speculative scene API changes.


## 0.10.11 transparent divider and recent-app eligibility
Replace ivory 20pt gap with clear 12pt gap and small translucent grip. Make split window/root nonopaque; panes keep opaque black backing. Transparency reveals existing underlying CarPlay content, not a guaranteed wallpaper. Center hit region stays within gap. Picker gets opaque backing to avoid underlying pane text showing through. Unknown passive foreground callbacks lacking DBActivationSettingLaunchSource no longer create recent-app records. Existing and pending app records still update; explicit launch-source callbacks seed/reorder recents. This is an observable proxy for a user launch; callbacks without source cannot conclusively distinguish user actions from background activity. Keep inset fix and Music helpers. No phone-app launch API added.
