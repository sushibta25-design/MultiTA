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


## 0.26.0 — split lifecycle rebuild (device validation pending)

Based on main 0.25. Preparation keeps the split window alive and clears only the chosen pane. Native launches are scoped to that preparation. Presentations must expose a connected host before resizing; one empty-presentation replacement is allowed. Removed synchronous layoutIfNeeded and redundant private scene UI refresh during attachment. Normal background callbacks run normally; companion scene/surface is checked after the transition, with at most one geometry correction per event. A disconnected companion exposes retry rather than starting foreground loops. Added begin/return trace markers around presentation and transaction calls. Surface connection is not proof of rendered pixels or working input.

Validation: CI compile/package; real CarPlay tests still required, especially cold app launches, Maps/YouTube switching and touch responsiveness. This is an experimental build, not a confirmed crash fix.
