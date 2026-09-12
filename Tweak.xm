// DuoPhone V6.17b-safe-readonly-buildfix — scene-frame resize experiment on uploaded V6.7.
// Fixed equal panes; divider is visual only. No presentation scaling.
// Every app requests its pane width and full content height.
// Native template layout still requires device validation.
// Saves/restores only the scene frame. Keeps picker, floating exit and app probes.
// Runtime guards verify method signatures. Device-side redraw/touch still needs testing.
// Inspect RESIZE REQUEST / OBSERVED / RESTORE in DuoPhoneV6Trace.txt.
// Replace only Tweak.xm; existing package metadata is unchanged.
// Observed device APIs: foregroundSceneWithSettings:completion:,
// presentationViewWithIdentifier:, invalidatePresentationViewForIdentifier:.
// Never reuse native animation identifiers or suppress native lifecycle callbacks.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdarg.h>
#import <math.h>
#import <string.h>

static NSString *const DPTrace = @"/var/mobile/DuoPhoneV6Trace.txt";
static void DPLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSData *data = [[NSString stringWithFormat:@"[CarPlay:%d] V6.17b-safe-readonly-buildfix %@\n", getpid(), message]
                   dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized (DPTrace) {
        NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:DPTrace];
        if (!file) { [data writeToFile:DPTrace atomically:YES]; return; }
        @try { [file seekToEndOfFile]; [file writeData:data]; }
        @catch (__unused NSException *e) {}
        @finally { [file closeFile]; }
    }
}
static id DPValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}
static NSString *DPCategoryToken(NSString *sid) {
    if (![sid isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [sid componentsSeparatedByString:@":"];
    if (parts.count < 2 || ![parts[0] hasPrefix:@"Car["] || ![parts[0] hasSuffix:@"]"]) return nil;
    return [parts[0] substringWithRange:NSMakeRange(4, parts[0].length - 5)];
}
static NSString *DPBundle(NSString *sid) {
    if (![sid isKindOfClass:NSString.class]) return nil;
    NSArray *parts = [sid componentsSeparatedByString:@":"];
    if (parts.count < 2 || ![parts[0] hasPrefix:@"Car["] || ![parts[0] hasSuffix:@"]"]) return nil;
    NSString *bundle = nil;
    if (parts.count == 2) bundle = parts[1];
    else if (parts.count == 3 && [parts[1] isEqual:@"com.apple.CarPlayTemplateUIHost"]) bundle = parts[2];
    if (![bundle containsString:@"."]) return nil;
    if ([@[@"com.apple.CarPlayApp", @"com.apple.CarPlaySettings", @"com.apple.CarPlayWallpaper",
           @"com.apple.CarPlayTemplateUIHost"] containsObject:bundle]) return nil;
    return bundle;
}
@interface DPRecord : NSObject
@property(nonatomic,strong) id controller;
@property(nonatomic,copy) NSString *sid;
@property(nonatomic,copy) NSString *category;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSDictionary *settings;
@property(nonatomic,copy) NSString *presentationID;
@property(nonatomic,strong) UIView *presentation;
@property(nonatomic) BOOL nativeBackgrounded;
@property(nonatomic) BOOL restoreBackground;
@property(nonatomic) BOOL valid;
@property(nonatomic,strong) id resizeScene;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) CGSize requestedSize;
@property(nonatomic) CGSize submittedSize;
@property(nonatomic) BOOL resizeQueued;
@property(nonatomic) BOOL geometryChanged;
@property(nonatomic) NSInteger resizeState; // 0 untested, 1 setter accepted, -1 unsupported
@property(nonatomic) NSUInteger resizeAttempts;
@end
@implementation DPRecord
@end

static NSMutableDictionary<NSString *, DPRecord *> *gRecords;
static NSMutableArray<NSString *> *gOrder;
static NSArray<DPRecord *> *gPair;
static UIWindow *gButtonWindow, *gSplitWindow, *gPickerWindow;
static UIView *gLeftPane, *gRightPane, *gDivider;
static UIButton *gButton;
static NSMutableArray<NSString *> *gPickerBundles;   // snapshot khi mở picker
static NSString *gPickerFirstPick = nil;             // app đã chọn làm bên trái
static UILabel *gStatus;
static __weak UIWindowScene *gSession;
static BOOL gRunning, gOwnCall;
static NSUInteger gGeneration;
static NSUInteger gSessionEpoch;
static CGSize gNativeSize;
static BOOL gAppProbeEnabled = NO;
static void DPStop(NSString *reason);
static void DPLayout(void);
static void DPRefreshButton(void);
static void DPInspect(NSUInteger generation);
static void DPDumpConnectedScenes(NSString *tag);
static void DPProbeTemplateSurface(DPRecord *record);
static void DPTryPokeSceneUI(DPRecord *record);
static void DPPeekZeroArgObject(id target, NSString *tag, NSString *selName);
static NSString *DPName(DPRecord *record) {
    if ([record.bundle isEqualToString:@"com.apple.Maps"]) return @"Maps";
    if ([record.bundle isEqualToString:@"com.google.ios.youtubemusic"]) return @"YouTube Music";
    return [record.bundle componentsSeparatedByString:@"."].lastObject ?: @"App";
}

static UIWindowScene *DPDashboard(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
        if ([scene isKindOfClass:UIWindowScene.class] &&
            [scene.session.persistentIdentifier containsString:@"DBDashboard-Car"])
            return (UIWindowScene *)scene;
    return nil;
}
static BOOL DPSceneActive(DPRecord *record) {
    id scene = DPValue(record.controller, @"scene");
    SEL selector = NSSelectorFromString(@"isActive");
    return [scene respondsToSelector:selector] && ((BOOL(*)(id,SEL))objc_msgSend)(scene, selector);
}
static NSUInteger DPLayers(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return 0;
    NSUInteger count = [NSStringFromClass(view.class) containsString:@"_UISceneLayerHostContainerView"] ? 1 : 0;
    for (UIView *child in view.subviews) count += DPLayers(child, depth + 1);
    return count;
}
static BOOL DPReadFrame(id scene, CGRect *frame) {
    id value = DPValue(DPValue(scene, @"settings"), @"frame");
    if (![value isKindOfClass:NSValue.class] || strcmp([value objCType], @encode(CGRect))) return NO;
    *frame = [value CGRectValue];
    return isfinite(frame->size.width) && isfinite(frame->size.height) &&
           frame->size.width > 0 && frame->size.height > 0;
}
static BOOL DPFrameSetter(id settings, CGRect frame) {
    SEL setter = NSSelectorFromString(@"setFrame:");
    NSMethodSignature *sig = [settings methodSignatureForSelector:setter];
    if (!sig || sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) ||
        strcmp([sig getArgumentTypeAtIndex:2], @encode(CGRect))) return NO;
    ((void(*)(id,SEL,CGRect))objc_msgSend)(settings, setter, frame);
    return YES;
}
static BOOL DPHasFrameUpdater(id scene) {
    NSMethodSignature *sig = [scene methodSignatureForSelector:NSSelectorFromString(@"updateSettingsWithBlock:")];
    return sig && sig.numberOfArguments == 3 && !strcmp(sig.methodReturnType, @encode(void)) &&
           !strcmp([sig getArgumentTypeAtIndex:2], "@?");
}
static void DPRestoreFrame(DPRecord *record) {
    if (!record.geometryChanged || !record.valid || !record.resizeScene) return;
    id scene = record.resizeScene;
    CGRect frame = record.originalFrame;
    NSUInteger generation = gGeneration;
    if (DPValue(record.controller, @"scene") != scene || !DPHasFrameUpdater(scene)) return;
    void (^change)(id) = ^(id mutableSettings) {
        if (generation != gGeneration) return;
        @try {
            BOOL restored = DPFrameSetter(mutableSettings, frame);
            DPLog(@"RESIZE RESTORE bundle=%@ setter=%d frame=%@", record.bundle, restored, NSStringFromCGRect(frame));
        } @catch (NSException *e) { DPLog(@"RESIZE RESTORE ERROR %@ %@", record.bundle, e.name); }
    };
    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(scene, NSSelectorFromString(@"updateSettingsWithBlock:"), change);
    } @catch (NSException *e) { DPLog(@"RESIZE RESTORE ERROR %@ %@", record.bundle, e.name); }
}
static void DPQueueResize(DPRecord *record, CGSize size) {
    if (!record.presentation || !record.valid || record.resizeState < 0) return;
    record.requestedSize = size;
    if (record.resizeQueued || CGSizeEqualToSize(size, record.submittedSize)) return;
    record.resizeQueued = YES;
    NSUInteger generation = gGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!gRunning || generation != gGeneration || !record.valid) return;
        record.resizeQueued = NO;
        if (record.resizeState == 0 && ++record.resizeAttempts > 3) {
            record.resizeState = -1;
            DPLog(@"RESIZE NO CALLBACK bundle=%@", record.bundle);
            return;
        }
        id scene = DPValue(record.controller, @"scene");
        if (!record.resizeScene) {
            CGRect original;
            if (!scene || !DPHasFrameUpdater(scene) || !DPReadFrame(scene, &original)) {
                record.resizeState = -1;
                DPLog(@"RESIZE UNSUPPORTED bundle=%@ sceneClass=%@", record.bundle, NSStringFromClass([scene class]));
                DPLayout(); return;
            }
            record.resizeScene = scene; record.originalFrame = original;
        }
        if (record.resizeScene != scene) { DPStop(@"resize scene replaced"); return; }
        CGSize target = record.requestedSize;
        CGRect frame = (CGRect){CGPointZero, target};
        void (^change)(id) = ^(id mutableSettings) {
            if (![NSThread isMainThread]) { DPLog(@"RESIZE CALLBACK OFF MAIN — skipped"); return; }
            if (!gRunning || generation != gGeneration || !record.valid) return;
            @try {
                record.geometryChanged = YES; // Restore even if the setter throws part-way through.
                if (!DPFrameSetter(mutableSettings, frame)) {
                    record.resizeState = -1;
                    DPLog(@"RESIZE NO FRAME SETTER bundle=%@ settings=%@", record.bundle, NSStringFromClass([mutableSettings class]));
                    return;
                }
                record.resizeState = 1; record.submittedSize = target;
                DPLog(@"RESIZE REQUEST bundle=%@ frame=%@", record.bundle, NSStringFromCGRect(frame));
            } @catch (NSException *e) {
                record.resizeState = -1;
                DPLog(@"RESIZE ERROR %@ %@", record.bundle, e.name);
            }
        };
        @try {
            ((void(*)(id,SEL,id))objc_msgSend)(scene, NSSelectorFromString(@"updateSettingsWithBlock:"), change);
        } @catch (NSException *e) { record.resizeState = -1; DPLog(@"RESIZE UPDATE ERROR %@ %@", record.bundle, e.name); }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!gRunning || generation != gGeneration || !record.valid) return;
            CGRect actual = CGRectZero;
            BOOL readable = DPReadFrame(scene, &actual);
            DPLog(@"RESIZE OBSERVED bundle=%@ requested=%@ actual=%@ readable=%d setterState=%ld",
                  record.bundle, NSStringFromCGSize(target), NSStringFromCGRect(actual), readable, (long)record.resizeState);
            DPTryPokeSceneUI(record);
            // Observed settings are not proof that the remote application has redrawn.
            DPLayout();
        });
    });
}
static void DPFit(DPRecord *record, UIView *pane) {
    UIView *view = record.presentation;
    CGSize target = pane.bounds.size;
    if (!view || target.width <= 0 || target.height <= 0) return;
    DPQueueResize(record, target); // Identical submitted sizes are deduplicated.
    view.transform = CGAffineTransformIdentity;

    // TRƯỚC ĐÂY: trong lúc chờ vòng resize round-trip hoàn tất (~300ms),
    // source rơi về gNativeSize (kích thước FULL màn hình gốc của app,
    // ví dụ 426.67x240) — khiến view.bounds bị đặt to hơn hẳn pane (chỉ
    // ~188.83x240), rồi bị pane.clipsToBounds cắt bớt, hiện ra như đang
    // xem một PHẦN app full-size bị crop, không phải app đã resize đúng.
    //
    // GIỜ: mặc định dùng luôn kích thước PANE làm bounds ngay từ đầu (lạc
    // quan là app sẽ tự vẽ lại vừa khít) — đảm bảo hình luôn full kín pane,
    // không tràn/không hở, kể cả trước khi resize round-trip xác nhận xong.
    CGSize source = target;

    // Chỉ đổi sang kích thước THỰC TẾ mà hệ thống đã xác nhận (actual quan
    // sát được qua DPReadFrame) khi nó khác đáng kể so với target — nghĩa là
    // OS/app đã tự điều chỉnh về 1 kích thước khác thay vì chấp nhận nguyên
    // yêu cầu. Trường hợp đó ưu tiên khớp với cái THẬT để không bị lệch.
    CGRect observed = CGRectZero;
    if (record.resizeScene && DPReadFrame(record.resizeScene, &observed) &&
        (fabs(observed.size.width - target.width) > 0.5 ||
         fabs(observed.size.height - target.height) > 0.5)) {
        source = observed.size;
        DPLog(@"FIT MISMATCH bundle=%@ target=%@ actualObserved=%@ — dùng kích thước thật",
              record.bundle, NSStringFromCGSize(target), NSStringFromCGSize(observed.size));
    }

    if (source.width <= 0 || source.height <= 0) return;
    view.bounds = (CGRect){CGPointZero, source};
    view.center = CGPointMake(CGRectGetMinX(pane.bounds) + source.width * 0.5,
                              CGRectGetMinY(pane.bounds) + source.height * 0.5);
}
static const CGFloat kDividerGrabWidth = 28.0;   // vùng chạm (không hiển thị hết)
static const CGFloat kDividerVisualWidth = 5.0;  // vạch mảnh thực sự nhìn thấy
static const CGFloat kPaneGap = 2.0;
static const NSUInteger kMaxCachedApps = 6;      // nhớ tối đa 6 app đã mở trong phiên
static const CGFloat kPaneCornerRadius = 14.0;   // bo góc kiểu iPhone

static void DPLayout(void) {
    if (!gSplitWindow) return;
    CGFloat width = gSplitWindow.bounds.size.width, height = gSplitWindow.bounds.size.height;
    CGFloat split = width * 0.5;

    // Không còn chừa dải trên cùng: 2 pane chiếm full chiều cao CarPlay.
    gLeftPane.frame = CGRectMake(0, 0, MAX(1, split - kPaneGap), height);
    gRightPane.frame = CGRectMake(split + kPaneGap, 0, MAX(1, width - split - kPaneGap), height);

    // Vùng CHẠM của divider vẫn rộng (dễ kéo), nhưng chỉ vẽ 1 vạch mảnh ở giữa.
    gDivider.frame = CGRectMake(split - kDividerGrabWidth * 0.5, 0, kDividerGrabWidth, height);
    UIView *bar = [gDivider viewWithTag:9001];
    bar.frame = CGRectMake((kDividerGrabWidth - kDividerVisualWidth) * 0.5, 0,
                           kDividerVisualWidth, height);

    // Nút Thoát: pill nhỏ nổi góc trên phải, không có label tên app.
    CGFloat pillH = 26.0;
    UIButton *exitButton = (UIButton *)[gSplitWindow.rootViewController.view viewWithTag:9002];
    exitButton.frame = CGRectMake(width - 68, 6, 60, pillH);

    if (gPair.count == 2) {
        DPFit(gPair[0], gLeftPane);
        DPFit(gPair[1], gRightPane);
    }
}
static void DPStop(NSString *reason) {
    if (!gRunning) return;
    gRunning = NO;
    ++gGeneration; // Cancel delayed creation and inspection from this attempt.
    DPLog(@"STOP %@", reason);
    gSplitWindow.hidden = YES;
    BOOL previousOwnCall = gOwnCall;
    gOwnCall = YES;
    for (DPRecord *record in gPair) {
        DPRestoreFrame(record);
        record.resizeQueued = NO;
        record.resizeScene = nil;
        record.geometryChanged = NO;
        record.resizeState = 0;
        record.resizeAttempts = 0;
        record.submittedSize = CGSizeZero;
        [record.presentation removeFromSuperview];
        record.presentation = nil;
        if (!record.valid) { record.presentationID = nil; continue; }
        @try {
            SEL invalidate = NSSelectorFromString(@"invalidatePresentationViewForIdentifier:");
            if (record.presentationID && [record.controller respondsToSelector:invalidate])
                ((void(*)(id,SEL,id))objc_msgSend)(record.controller, invalidate, record.presentationID);
        } @catch (NSException *e) { DPLog(@"INVALIDATE ERROR %@ %@", record.bundle, e.name); }
        @try {
            // Restore even if invalidating the presentation failed.
            // Restore the observed native lifecycle, not FBScene.isActive:
            // an active FBScene need not be the foreground application.
            if (record.valid && record.restoreBackground) {
                SEL background = NSSelectorFromString(@"backgroundSceneWithCompletion:");
                if ([record.controller respondsToSelector:background])
                    ((void(*)(id,SEL,id))objc_msgSend)(record.controller, background, nil);
            }
        } @catch (NSException *e) { DPLog(@"CLEANUP ERROR %@ %@", record.bundle, e.name); }
        record.nativeBackgrounded = record.restoreBackground;
        record.presentationID = nil;
    }
    gOwnCall = previousOwnCall;
    gPair = nil;
    gSplitWindow = nil; gLeftPane = nil; gRightPane = nil; gDivider = nil; gStatus = nil;
    DPRefreshButton();
}
@interface DPControls : NSObject
- (void)openPicker;
- (void)closePicker;
- (void)pickerTap:(UIButton *)sender;
- (void)startWithLeftBundle:(NSString *)leftBundle rightBundle:(NSString *)rightBundle;
- (void)stop;
- (void)swap;
@end
static DPControls *gControls;
static void DPInspect(NSUInteger generation) {
    if (!gRunning || generation != gGeneration) return;
    BOOL allAttached = YES;
    for (DPRecord *record in gPair) {
        NSUInteger layers = DPLayers(record.presentation, 0);
        BOOL active = DPSceneActive(record);
        DPLog(@"RESULT bundle=%@ active=%d window=%p layers=%lu presentation=%@",
              record.bundle, active, (__bridge void *)record.presentation.window,
              (unsigned long)layers, record.presentationID);
        if (!active || !record.presentation.window || !layers) allAttached = NO;
        DPLog(@"VIEWPORT bundle=%@ logical=%@ bounds=%@ scaleX=%.3f scaleY=%.3f",
              record.bundle, NSStringFromCGSize(record.submittedSize),
              NSStringFromCGRect(record.presentation.bounds),
              record.presentation.transform.a, record.presentation.transform.d);
    }
    gStatus.text = allAttached && gPair.count == 2
        ? [NSString stringWithFormat:@"%@ | %@", DPName(gPair[0]), DPName(gPair[1])]
        : @"Chưa hiển thị đủ hai app";
    // These are structural signals, never proof of live rendering/touch.
}
@implementation DPControls
- (void)stop { DPStop(@"user exit"); }

- (void)closePicker {
    gPickerWindow.hidden = YES;
    gPickerWindow = nil;
    gPickerBundles = nil;
    gPickerFirstPick = nil;
}

// Danh sách các app còn "sống" (controller vẫn hợp lệ), mới mở gần đây lên trước.
- (NSArray<NSString *> *)validCachedBundlesNewestFirst {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *bundle in gOrder.reverseObjectEnumerator)
        if (gRecords[bundle].valid) [result addObject:bundle];
    return result;
}

// Nút "Chia" giờ mở 1 danh sách các app đã mở trong phiên lái xe (tối đa 6,
// không chỉ 2 app cuối cùng) — chạm chọn app trái, chạm tiếp chọn app phải,
// không cần quay lại Trang chủ mở lại app mỗi lần muốn đổi cặp chia màn.
- (void)openPicker {
    if (gRunning || !gSession) return;
    [self closePicker];

    NSArray<NSString *> *bundles = [self validCachedBundlesNewestFirst];
    if (bundles.count < 2) return;

    gPickerBundles = [bundles mutableCopy];

    CGRect bounds = gSession.coordinateSpace.bounds;
    gPickerWindow = [[UIWindow alloc] initWithWindowScene:gSession];
    gPickerWindow.windowLevel = UIWindowLevelAlert + 85;
    gPickerWindow.frame = CGRectMake(45, 0, MAX(1, bounds.size.width - 45), bounds.size.height);
    gPickerWindow.rootViewController = [UIViewController new];
    UIView *root = gPickerWindow.rootViewController.view;
    root.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];

    UILabel *hint = [UILabel new];
    hint.text = @"Chạm chọn app bên trái, rồi chạm app bên phải";
    hint.textColor = UIColor.whiteColor;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.frame = CGRectMake(8, 6, root.bounds.size.width - 16, 20);
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root addSubview:hint];

    CGFloat rowH = 34, gap = 6, top = 32;
    for (NSUInteger i = 0; i < gPickerBundles.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.tag = (NSInteger)i;
        row.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
        row.layer.cornerRadius = 6;
        row.tintColor = UIColor.whiteColor;
        [row setTitle:DPName(gRecords[gPickerBundles[i]]) forState:UIControlStateNormal];
        row.frame = CGRectMake(12, top + i * (rowH + gap), root.bounds.size.width - 24, rowH);
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addTarget:self action:@selector(pickerTap:) forControlEvents:UIControlEventTouchUpInside];
        [root addSubview:row];
    }

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Huỷ" forState:UIControlStateNormal];
    cancel.tintColor = UIColor.whiteColor;
    cancel.frame = CGRectMake(root.bounds.size.width - 60, 4, 52, 24);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [cancel addTarget:self action:@selector(closePicker) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:cancel];

    gPickerWindow.hidden = NO;
}

- (void)pickerTap:(UIButton *)sender {
    if (!gPickerBundles || sender.tag < 0 || (NSUInteger)sender.tag >= gPickerBundles.count) return;
    NSString *bundle = gPickerBundles[(NSUInteger)sender.tag];

    if (!gPickerFirstPick) {
        gPickerFirstPick = bundle;
        sender.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.95];
        return;
    }

    if ([gPickerFirstPick isEqualToString:bundle]) return; // không cho chọn trùng 1 app cho cả 2 bên

    NSString *left = gPickerFirstPick, *right = bundle;
    [self closePicker];
    [self startWithLeftBundle:left rightBundle:right];
}

- (void)swap {
    if (gPair.count != 2 || !gPair[0].presentation || !gPair[1].presentation) return;
    gPair = @[gPair[1], gPair[0]];
    [gLeftPane addSubview:gPair[0].presentation];
    [gRightPane addSubview:gPair[1].presentation];
    DPLayout();
    DPInspect(gGeneration);
    DPLog(@"SWAP left=%@ right=%@", gPair[0].bundle, gPair[1].bundle);
}
- (void)startWithLeftBundle:(NSString *)leftBundle rightBundle:(NSString *)rightBundle {
    if (gRunning || !gSession || DPDashboard() != gSession) return;
    DPRecord *left = gRecords[leftBundle], *right = gRecords[rightBundle];
    if (!left.valid || !right.valid) {
        DPLog(@"REFUSE invalid record left=%@(%d) right=%@(%d)",
              leftBundle, left.valid, rightBundle, right.valid);
        return;
    }
    DPDumpConnectedScenes(@"start-attempt");
    if (left.controller == right.controller) {
        // Nếu 2 bundle khác nhau nhưng CÙNG 1 controller vật lý, nhiều khả năng
        // CarPlay xếp cả 2 vào chung 1 "vai trò" (ví dụ Navigation) và chỉ cho
        // 1 app thuộc vai trò đó active tại 1 thời điểm — giới hạn tầng OS,
        // không phải lỗi ở logic ghép cặp của tweak.
        DPLog(@"REFUSE same controller=%p left=%@(cat=%@) right=%@(cat=%@) — có thể 2 app cùng 1 vai trò CarPlay (vd Navigation)",
              (__bridge void *)left.controller, leftBundle, left.category, rightBundle, right.category);
        return;
    }
    NSString *leftDisplay = [left.sid componentsSeparatedByString:@":"].firstObject;
    NSString *rightDisplay = [right.sid componentsSeparatedByString:@":"].firstObject;
    if (![leftDisplay isEqual:rightDisplay]) { DPLog(@"REFUSE mismatched displays"); return; }
    CGRect bounds = gSession.coordinateSpace.bounds;
    if (bounds.size.width <= 109 || bounds.size.height <= 60) return;
    gPair = @[left, right];
    gRunning = YES;
    NSUInteger generation = ++gGeneration;
    for (DPRecord *record in gPair) record.restoreBackground = record.nativeBackgrounded;
    gNativeSize = bounds.size;
    gSplitWindow = [[UIWindow alloc] initWithWindowScene:gSession];
    gSplitWindow.frame = CGRectMake(45, 0, MAX(1, bounds.size.width - 45), bounds.size.height);
    gSplitWindow.windowLevel = UIWindowLevelAlert + 70;
    gSplitWindow.rootViewController = [UIViewController new];
    UIView *root = gSplitWindow.rootViewController.view;
    root.backgroundColor = UIColor.blackColor; // chỉ lấp khe 2pt giữa 2 pane
    gLeftPane = [UIView new]; gRightPane = [UIView new];
    gLeftPane.clipsToBounds = YES; gRightPane.clipsToBounds = YES;
    for (UIView *pane in @[gLeftPane, gRightPane]) {
        pane.layer.cornerRadius = kPaneCornerRadius;
        if (@available(iOS 13.0, *)) pane.layer.cornerCurve = kCACornerCurveContinuous;
        pane.layer.masksToBounds = YES;
    }
    gLeftPane.backgroundColor = UIColor.blackColor;
    gRightPane.backgroundColor = UIColor.blackColor;
    [root addSubview:gLeftPane]; [root addSubview:gRightPane];

    // Không hiện tên app nữa theo yêu cầu — chỉ còn 1 pill Thoát nhỏ.
    gStatus = [UILabel new];
    gStatus.hidden = YES;

    UIButton *exit = [UIButton buttonWithType:UIButtonTypeSystem];
    exit.tag = 9002;
    [exit setTitle:@"Thoát" forState:UIControlStateNormal];
    exit.tintColor = UIColor.whiteColor;
    exit.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.55];
    exit.layer.cornerRadius = 6;
    [exit addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:exit];
    // Vùng CHẠM trong suốt (rộng, dễ bấm trúng) chứa 1 vạch mảnh làm dấu hiệu thị giác.
    gDivider = [UIView new];
    gDivider.backgroundColor = UIColor.clearColor;
    UIView *dividerBar = [UIView new];
    dividerBar.tag = 9001;
    dividerBar.backgroundColor = [UIColor colorWithWhite:0.85 alpha:0.85];
    dividerBar.layer.cornerRadius = kDividerVisualWidth * 0.5;
    dividerBar.userInteractionEnabled = NO;
    [gDivider addSubview:dividerBar];
    gDivider.userInteractionEnabled = NO; // Fixed separator, no pan or swap gestures.
    [root addSubview:gDivider];
    DPLayout(); gSplitWindow.hidden = NO; DPRefreshButton();
    DPLog(@"START FIXED 50/50 left=%@ right=%@ — unscaled scene resize", left.bundle, right.bundle);
    gOwnCall = YES;
    @try {
        for (DPRecord *record in gPair) {
            SEL foreground = NSSelectorFromString(@"foregroundSceneWithSettings:completion:");
            if (![record.controller respondsToSelector:foreground])
                @throw [NSException exceptionWithName:@"MissingForegroundAPI" reason:record.bundle userInfo:nil];
            ((void(*)(id,SEL,id,id))objc_msgSend)(record.controller, foreground, record.settings, nil);
            if (!gRunning || generation != gGeneration) { gOwnCall = NO; return; }
            record.nativeBackgrounded = NO;
        }
    } @catch (NSException *e) {
        DPLog(@"FOREGROUND ERROR %@", e.name); gOwnCall = NO; DPStop(@"foreground error"); return;
    }
    gOwnCall = NO;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!gRunning || generation != gGeneration) return;
        gOwnCall = YES;
        @try {
            for (NSUInteger index = 0; index < gPair.count; index++) {
                DPRecord *record = gPair[index];
                record.presentationID = [NSString stringWithFormat:@"com.sushibta.duophone.%lu.%lu", (unsigned long)generation, (unsigned long)index];
                SEL create = NSSelectorFromString(@"presentationViewWithIdentifier:");
                if (![record.controller respondsToSelector:create])
                    @throw [NSException exceptionWithName:@"MissingPresentationAPI" reason:record.bundle userInfo:nil];
                id result = ((id(*)(id,SEL,id))objc_msgSend)(record.controller, create, record.presentationID);
                if (!gRunning || generation != gGeneration) { gOwnCall = NO; return; }
                // A fresh owned view is required. Never steal native attached UI.
                if (![result isKindOfClass:UIView.class] || ((UIView *)result).superview)
                    @throw [NSException exceptionWithName:@"PresentationNotIndependent" reason:record.bundle userInfo:nil];
                record.presentation = result;
                [(index == 0 ? gLeftPane : gRightPane) addSubview:result];
                DPLog(@"CREATE bundle=%@ identifier=%@ class=%@ layers=%lu", record.bundle,
                      record.presentationID, NSStringFromClass([result class]), (unsigned long)DPLayers(result,0));
                DPProbeTemplateSurface(record);
            }
            DPLayout();
        } @catch (NSException *e) {
            DPLog(@"PRESENTATION ERROR %@", e.name); gOwnCall = NO; DPStop(@"presentation error"); return;
        }
        gOwnCall = NO;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
    });
}
@end

static void DPRefreshButton(void) {
    NSUInteger validCount = 0;
    for (NSString *bundle in gOrder) if (gRecords[bundle].valid) validCount++;
    BOOL ready = validCount >= 2;
    gButtonWindow.hidden = gRunning || !ready;
}
// Chỉ CHẨN ĐOÁN — quét tên method/property của controller + scene, lọc theo
// từ khoá liên quan tới template/tab bar/layout, để TÌM (không phải đoán mò)
// xem có API nào bắt hệ thống Template (CarPlayTemplateUIHost) vẽ lại UI theo
// kích thước mới hay không. Chỉ chạy 1 lần/app để không spam log.
static BOOL DPTemplateProbeNameLooksUseful(NSString *name) {
    if (!name) return NO;
    NSString *l = name.lowercaseString;
    return [l containsString:@"template"] || [l containsString:@"tabbar"] ||
           [l containsString:@"tab"] || [l containsString:@"layout"] ||
           [l containsString:@"reload"] || [l containsString:@"invalidate"] ||
           [l containsString:@"relayout"] || [l containsString:@"content"] ||
           [l containsString:@"redraw"] || [l containsString:@"update"];
}
static void DPProbeClassSurface(Class cls, NSString *tag) {
    if (!cls || !tag) return;
    DPLog(@"TEMPLATE-PROBE class=%@ super=%@", tag, NSStringFromClass(class_getSuperclass(cls)));
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (DPTemplateProbeNameLooksUseful(name))
            DPLog(@"TEMPLATE-PROBE %@ METHOD %@ argc=%u types=%s", tag, name,
                  method_getNumberOfArguments(methods[i]),
                  method_getTypeEncoding(methods[i]) ?: "?");
    }
    if (methods) free(methods);
}
// GHI CHÚ: đã bỏ hàm gọi trigger "0 tham số trả về void" (DPTryZeroArgVoid)
// dùng cho _updateSceneUI/invalidate — cả 2 đã xác nhận gây huỷ scene/crash,
// không dùng nữa. Chỉ giữ lại hàm ĐỌC bên dưới.
// Chỉ ĐỌC — gọi 1 getter không tham số trả về object, để xem giá trị hiện
// tại (currentSceneUpdate, layoutElementAssertion...), không tự ý thay đổi
// gì. Giúp hiểu cấu trúc dữ liệu trước khi dám set lại nó.
static void DPPeekZeroArgObject(id target, NSString *tag, NSString *selName) {
    if (!target) return;
    SEL sel = NSSelectorFromString(selName);
    if (![target respondsToSelector:sel]) {
        DPLog(@"PEEK %@.%@ SKIP not respond", tag, selName);
        return;
    }
    NSMethodSignature *sig = [target methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 2 || strcmp(sig.methodReturnType, @encode(id)) != 0) {
        DPLog(@"PEEK %@.%@ SKIP unexpected signature argc=%lu returnType=%s",
              tag, selName, sig ? (unsigned long)sig.numberOfArguments : 0,
              sig ? sig.methodReturnType : "?");
        return;
    }
    @try {
        id result = ((id (*)(id, SEL))objc_msgSend)(target, sel);
        DPLog(@"PEEK %@.%@ => %@ class=%@", tag, selName, result ?: @"nil",
              result ? NSStringFromClass([result class]) : @"nil");
    } @catch (NSException *e) {
        DPLog(@"PEEK %@.%@ EXCEPTION %@ %@", tag, selName, e.name, e.reason);
    }
}
static void DPTryPokeSceneUI(DPRecord *record) {
    if (!record.controller) return;

    // ĐÃ BỎ HẲN: _updateSceneUI VÀ mọi lệnh "invalidate". Log thực tế cho
    // thấy MỌI lần gọi _updateSceneUI đều ngay lập tức kéo theo
    // "STOP native scene destroyed" — nó không "vô hại" như kết luận sai ở
    // bản trước, mà chính là thứ khiến hệ thống tự huỷ scene. "invalidate"
    // cùng họ tên với các API kiểu FrontBoard chuyên dùng để "huỷ/gỡ đăng
    // ký" — CHƯA có bằng chứng nó an toàn (2 lần gọi thành công trong log
    // đều là gọi trên scene ĐÃ CHẾT sẵn từ _updateSceneUI, không chứng minh
    // được gì khi gọi trên scene còn sống). Từ bản này CHỈ ĐỌC, không gọi
    // thêm bất kỳ hàm "trigger" nào nữa cho tới khi hiểu rõ hơn.

    id controller = record.controller;
    NSString *tag = record.bundle;

    // Đào tiếp phát hiện quan trọng nhất log trước: layoutElementAssertion
    // trả về BSSimpleAssertion, bên trong có .reason là FBSDisplayLayoutElement
    // — rất có thể đây là đối tượng hệ thống dùng để đăng ký VÙNG HIỂN THỊ
    // của app. Đọc (không sửa) mọi key khả nghi để hiểu cấu trúc nó.
    id assertion = nil;
    SEL assertionSel = NSSelectorFromString(@"layoutElementAssertion");
    if ([controller respondsToSelector:assertionSel]) {
        NSMethodSignature *sig = [controller methodSignatureForSelector:assertionSel];
        if (sig && sig.numberOfArguments == 2 && strcmp(sig.methodReturnType, @encode(id)) == 0) {
            @try { assertion = ((id (*)(id, SEL))objc_msgSend)(controller, assertionSel); }
            @catch (NSException *e) { DPLog(@"PEEK %@ layoutElementAssertion EXCEPTION %@", tag, e.name); }
        }
    }

    if (!assertion) {
        DPLog(@"PEEK %@ layoutElementAssertion => nil (scene có thể đã bị huỷ)", tag);
        return;
    }

    id element = DPValue(assertion, @"reason");
    DPLog(@"PEEK %@ layoutElement=%@ class=%@", tag, element ?: @"nil",
          element ? NSStringFromClass([element class]) : @"nil");

    if (!element) return;

    // Đọc mọi key hình học/kích thước khả dĩ — KHÔNG set lại bất kỳ cái gì.
    for (NSString *key in @[@"frame", @"bounds", @"size", @"rect", @"region",
                            @"displayIdentity", @"identity", @"identifier",
                            @"contentSize", @"logicalSize", @"screenBounds"]) {
        id value = DPValue(element, key);
        if (value) DPLog(@"PEEK %@ layoutElement.%@ => %@ class=%@",
                          tag, key, value, NSStringFromClass([value class]));
    }

    // Quét thêm ivar kiểu CGRect/CGSize nếu có (đọc bằng object_getIvar an
    // toàn qua @try, không dùng con trỏ thô để tránh đọc sai kiểu).
    Class cls = [element class];
    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    for (unsigned int i = 0; i < ic; i++) {
        const char *rawName = ivar_getName(ivars[i]);
        const char *rawType = ivar_getTypeEncoding(ivars[i]);
        if (!rawName || !rawType) continue;
        NSString *name = [NSString stringWithUTF8String:rawName];
        if (strcmp(rawType, @encode(CGRect)) == 0) {
            @try {
                CGRect r;
                ptrdiff_t offset = ivar_getOffset(ivars[i]);
                memcpy(&r, (char *)(__bridge void *)element + offset, sizeof(CGRect));
                DPLog(@"PEEK %@ layoutElement IVAR %@ (CGRect) => %@", tag, name, NSStringFromCGRect(r));
            } @catch (__unused NSException *e) {}
        } else if (strcmp(rawType, @encode(CGSize)) == 0) {
            @try {
                CGSize s; ptrdiff_t offset = ivar_getOffset(ivars[i]);
                memcpy(&s, (char *)(__bridge void *)element + offset, sizeof(CGSize));
                DPLog(@"PEEK %@ layoutElement IVAR %@ (CGSize) => %@", tag, name, NSStringFromCGSize(s));
            } @catch (__unused NSException *e) {}
        }
    }
    if (ivars) free(ivars);

    // Chỉ đọc, không tự ý set — xem 2 getter này trả về gì để hiểu cấu trúc,
    // trước khi dám thử VIẾT lại chúng ở vòng sau.
    DPPeekZeroArgObject(record.controller, [tag stringByAppendingString:@".controller"], @"currentSceneUpdate");
    DPPeekZeroArgObject(record.controller, [tag stringByAppendingString:@".controller"], @"layoutElementAssertion");
}
static NSMutableSet<NSString *> *gTemplateProbed;
static void DPProbeTemplateSurface(DPRecord *record) {
    if (!record.controller) return;
    if (!gTemplateProbed) gTemplateProbed = [NSMutableSet set];
    if ([gTemplateProbed containsObject:record.bundle]) return;
    [gTemplateProbed addObject:record.bundle];

    BOOL isTemplate = [record.sid containsString:@"CarPlayTemplateUIHost"];
    DPLog(@"========== TEMPLATE-PROBE bundle=%@ isTemplate=%d ==========", record.bundle, isTemplate);

    DPProbeClassSurface([record.controller class],
                        [NSString stringWithFormat:@"controller(%@)", record.bundle]);

    id scene = DPValue(record.controller, @"scene");
    if (scene) DPProbeClassSurface([scene class],
                                   [NSString stringWithFormat:@"scene(%@)", record.bundle]);

    // Presentation view chính là bề mặt render — quét luôn để tìm hàm
    // "reload/invalidate layout" ngay trên chính view đó nếu có.
    if (record.presentation)
        DPProbeClassSurface([record.presentation class],
                            [NSString stringWithFormat:@"presentation(%@)", record.bundle]);

    DPLog(@"========== TEMPLATE-PROBE bundle=%@ END ==========", record.bundle);
}
static void DPDumpConnectedScenes(NSString *tag) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        NSString *pid = scene.session.persistentIdentifier;
        NSString *role = scene.session.role;
        BOOL active = scene.activationState == UISceneActivationStateForegroundActive;
        DPLog(@"SCENES[%@] pid=%@ role=%@ class=%@ active=%d",
              tag, pid, role, NSStringFromClass([scene class]), active);
    }
}
static void DPCapture(id controller, id settings) {
    if (gOwnCall || ![settings isKindOfClass:NSDictionary.class]) return;
    // Ignore suspended prewarming. Only retain observed explicit launch settings.
    if (!settings[@"DBActivationSettingLaunchSource"]) return;
    NSString *sid = DPValue(controller, @"sceneID"), *bundle = DPBundle(sid);
    if (!bundle) return;
    NSString *category = DPCategoryToken(sid);
    NSDictionary *copy = [settings copy];
    NSUInteger epoch = gSessionEpoch;
    void (^capture)(void) = ^{
        if (epoch != gSessionEpoch || !gSession || DPDashboard() != gSession) return;
        if (gRunning) return;
        DPRecord *record = [DPRecord new];
        record.controller = controller; record.sid = sid; record.category = category;
        record.bundle = bundle; record.settings = copy;
        record.valid = YES;
        // Nếu bundle này đã có record cũ với category KHÁC, hoặc trùng bundle
        // nhưng khác controller — đáng chú ý, log riêng để đối chiếu sau.
        DPRecord *previous = gRecords[bundle];
        if (previous && previous.controller != controller)
            DPLog(@"CAPTURE-REPLACE bundle=%@ oldController=%p oldCategory=%@ newController=%p newCategory=%@",
                  bundle, (__bridge void *)previous.controller, previous.category,
                  (__bridge void *)controller, category);
        gRecords[bundle] = record;
        [gOrder removeObject:bundle]; [gOrder addObject:bundle];
        while (gOrder.count > kMaxCachedApps) {
            [gRecords removeObjectForKey:gOrder.firstObject]; [gOrder removeObjectAtIndex:0];
        }
        DPLog(@"CAPTURE bundle=%@ category=%@ sid=%@ controller=%p source=%@ suspended=%@ isTemplate=%d", bundle, category, sid,
              (__bridge void *)controller,
              copy[@"DBActivationSettingLaunchSource"], copy[@"DBActivationSettingSuspended"],
              [sid containsString:@"CarPlayTemplateUIHost"]);
        // Dump TOÀN BỘ key trong settings — đang tìm 1 key kiểu frame/display
        // configuration có thể set NGAY LÚC connect, thay vì resize sau khi
        // đã render (cách hiện tại không hiệu quả với app kiểu Template).
        for (NSString *key in copy.allKeys)
            DPLog(@"SETTINGS-DUMP bundle=%@ key=%@ value=%@ class=%@",
                  bundle, key, copy[key], NSStringFromClass([copy[key] class]));
        DPDumpConnectedScenes([NSString stringWithFormat:@"capture:%@", bundle]);
        DPRefreshButton();
    };
    // Register before %orig can synchronously background/destroy this controller.
    if ([NSThread isMainThread]) capture();
    else dispatch_async(dispatch_get_main_queue(), capture);
}
static void DPTick(void) {
    UIWindowScene *session = DPDashboard();
    if (session != gSession) {
        ++gSessionEpoch;
        DPStop(@"display changed");
        [gControls closePicker];
        gButtonWindow.hidden = YES; gButtonWindow = nil; gButton = nil;
        [gRecords removeAllObjects]; [gOrder removeAllObjects];
        gSession = session;
        DPLog(@"DISPLAY %@", session.session.persistentIdentifier);
    }
    if (gRunning && session) {
        CGSize size = session.coordinateSpace.bounds.size;
        if (fabs(size.width - gNativeSize.width) > 0.5 || fabs(size.height - gNativeSize.height) > 0.5)
            DPStop(@"display geometry changed");
    }
    if (session && !gButtonWindow) {
        gButtonWindow = [[UIWindow alloc] initWithWindowScene:session];
        gButtonWindow.windowLevel = UIWindowLevelAlert + 80;
        gButtonWindow.rootViewController = [UIViewController new];
        gButton = [UIButton buttonWithType:UIButtonTypeSystem];
        [gButton setTitle:@"Chia" forState:UIControlStateNormal];
        gButton.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.9];
        gButton.layer.cornerRadius = 8;
        [gButton addTarget:gControls action:@selector(openPicker) forControlEvents:UIControlEventTouchUpInside];
        [gButtonWindow.rootViewController.view addSubview:gButton];
    }
    if (session) {
        CGFloat width = session.coordinateSpace.bounds.size.width;
        gButtonWindow.frame = CGRectMake(MAX(45,width-58), 0, 58, 28);
        gButton.frame = CGRectMake(0,0,58,28);
        DPRefreshButton();
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPTick(); });
}
%hook DBApplicationSceneViewController
- (void)sceneManager:(id)manager didDestroyScene:(id)scene {
    NSString *bundle = DPBundle(DPValue(self, @"sceneID"));
    DPRecord *record = bundle ? gRecords[bundle] : nil;
    if (record.controller == self) {
        BOOL wasInPair = gRunning && [gPair containsObject:record];
        if (gPickerWindow) [gControls closePicker];
        if (wasInPair) {
            // Đang hiển thị app này thật — phải dừng ngay, không trì hoãn.
            record.valid = NO;
            DPStop(@"native scene destroyed");
            [gRecords removeObjectForKey:bundle];
            [gOrder removeObject:bundle];
            DPRefreshButton();
        } else {
            // Nhiều app tự huỷ rồi tạo lại controller khi cập nhật UI nội bộ
            // (không thật sự rời CarPlay) — quan sát thấy CAPTURE-REPLACE khá
            // thường xuyên trong log thực tế. Đánh invalid ngay lập tức làm
            // điều kiện "đủ 2 app" nhấp nháy, nút "Chia" ẩn/hiện liên tục.
            // Chờ 1 nhịp xem có bị capture lại (thay thế) không rồi mới gỡ
            // thật khỏi danh sách + refresh nút.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (gRecords[bundle] == record) {
                    record.valid = NO;
                    [gRecords removeObjectForKey:bundle];
                    [gOrder removeObject:bundle];
                    DPRefreshButton();
                }
            });
        }
    }
    %orig;
}
- (void)foregroundSceneWithSettings:(id)settings completion:(id)completion {
    if (!gOwnCall && gRunning) DPStop(@"native app launch");
    DPCapture(self, settings);
    %orig;
}
- (id)presentationViewWithIdentifier:(id)identifier {
    if (!gOwnCall && gRunning && [identifier isKindOfClass:NSString.class] &&
        [identifier isEqualToString:@"kCARAppToHomeAnimationIdentifier"])
        DPStop(@"native home transition");
    return %orig;
}
- (void)backgroundSceneWithCompletion:(id)completion {
    if (!gOwnCall) {
        NSString *bundle = DPBundle(DPValue(self, @"sceneID"));
        DPRecord *record = bundle ? gRecords[bundle] : nil;
        if (record.controller == self) record.nativeBackgrounded = YES;
    }
    if (gRunning) DPLog(@"NATIVE BACKGROUND id=%@ own=%d", DPValue(self,@"sceneID"), gOwnCall);
    %orig;
}
- (void)deactivateSceneWithReasonMask:(NSUInteger)mask {
    if (gRunning) DPLog(@"NATIVE DEACTIVATE id=%@ mask=%lu", DPValue(self,@"sceneID"),(unsigned long)mask);
    %orig;
}
%end

// Chạy BÊN TRONG process của chính app bản đồ (Maps/Google Maps/Vietmap), khác
// hẳn khối hook DBApplicationSceneViewController ở trên (chạy trong CarPlayApp).
// Mục đích: xem chính app đó tự khai báo role/configuration gì khi nó kết nối
// tới scene CarPlay — dữ liệu này quyết định có spoof/redirect được không.
// _connectUIScene:withOptions: là API private phổ biến, có thể không tồn tại
// trên mọi phiên bản iOS — nếu log không thấy dòng APPSIDE-CONNECT nào dù đã
// mở app trên CarPlay, nghĩa là cần probe selector khác, không phải app không
// kết nối.
%hook UIApplication
- (void)_connectUIScene:(UIScene *)scene withOptions:(id)options {
    %orig;
    if (!gAppProbeEnabled || ![scene isKindOfClass:UIWindowScene.class]) return;
    @try {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UISceneSession *session = windowScene.session;
        DPLog(@"APPSIDE-CONNECT proc=%@ sid=%@ role=%@ configName=%@ configDelegateClass=%@ orientation=%ld",
              NSBundle.mainBundle.bundleIdentifier, session.persistentIdentifier, session.role,
              session.configuration.name, session.configuration.delegateClass,
              (long)windowScene.interfaceOrientation);
    } @catch (NSException *e) { DPLog(@"APPSIDE-CONNECT PROBE ERROR %@", e.reason); }
}
%end
%ctor {
    @autoreleasepool {
        NSString *proc = NSBundle.mainBundle.bundleIdentifier;
        // Nhánh probe: KHÔNG đụng tới bất kỳ global nào của phần host-side
        // (gRecords/gControls/...) — chỉ bật cờ cho hook UIApplication ở trên.
        if ([@[@"com.apple.Maps", @"com.google.Maps", @"vn.vietmap.live"] containsObject:proc]) {
            gAppProbeEnabled = YES;
            DPLog(@"APPSIDE PROBE ACTIVE proc=%@", proc);
            return;
        }
        if (![proc isEqualToString:@"com.apple.CarPlayApp"]) return;
        gRecords = [NSMutableDictionary dictionary]; gOrder = [NSMutableArray array];
        gControls = [DPControls new];
        dispatch_async(dispatch_get_main_queue(), ^{
            DPLog(@"CTOR MANUAL EXPERIMENT — open two apps, tap Chia; no automatic split");
            DPTick();
        });
    }
}
