// DuoPhone V6.7 — dựa trên V6.3.2 (đã chạy được: 2 app scene thật song song
// qua presentationViewWithIdentifier:), chỉ vá UI + thêm picker chọn app.
//
// Lịch sử các lần vá UI trên nền V6.3.2:
//  V6.4: bỏ dải 30pt đen trên cùng, divider chỉ còn vạch mảnh, status/exit
//        thành pill nổi — nhưng đổi DPFit sang scale "fit" (giữ tỉ lệ) làm
//        lộ viền đen letterbox trên/dưới mỗi pane.
//  V6.5: đổi "fit" sang "cover" (MAX scale) để lấp kín, hết viền đen — nhưng
//        vì chiều cao pane không đổi khi kéo divider, cover-scale gần như
//        cố định, nên kéo chỉ dịch vùng crop chứ ảnh không co giãn.
//  V6.7: đổi hẳn sang stretch ĐỘC LẬP X/Y (scaleX theo chiều rộng pane,
//        scaleY theo chiều cao pane) — lấp kín pane VÀ co giãn đúng theo cả
//        2 chiều khi kéo divider. Đánh đổi: hình có thể hơi méo tỉ lệ.
//        Thêm picker: nhớ tối đa 6 app đã mở trong phiên, nút "Chia" mở
//        danh sách chọn 2 app bất kỳ thay vì luôn lấy 2 app mở gần nhất.
//
// LƯU Ý CHƯA XỬ LÝ: "bubble tốc độ" (nút tròn nổi của Maps) nếu bị cắt là do
// nó là 1 overlay/layer RIÊNG của app, không nằm trong _UIScenePresentationView
// (layers=1) mà presentationViewWithIdentifier: trả về — cần probe thêm.
//
// Observed device APIs: foregroundSceneWithSettings:completion:,
// presentationViewWithIdentifier:, invalidatePresentationViewForIdentifier:.
// Never reuse native animation identifiers or suppress native lifecycle callbacks.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdarg.h>
#import <math.h>

static NSString *const DPTrace = @"/var/mobile/DuoPhoneV6Trace.txt";
static NSString *const DPRatioKey = @"DuoPhoneManualSplitRatio";
static void DPLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSData *data = [[NSString stringWithFormat:@"[CarPlay:%d] V6.7 %@\n", getpid(), message]
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
static CGFloat gRatio = 0.5, gStartRatio;
static CGSize gNativeSize;
static void DPStop(NSString *reason);
static void DPLayout(void);
static void DPRefreshButton(void);
static void DPInspect(NSUInteger generation);
static void DPDumpConnectedScenes(NSString *tag);
static CGFloat DPValidRatio(CGFloat ratio) {
    return isfinite(ratio) ? MAX(0.30, MIN(0.70, ratio)) : 0.5;
}
static void DPSaveRatio(void) {
    [NSUserDefaults.standardUserDefaults setDouble:DPValidRatio(gRatio) forKey:DPRatioKey];
}
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
static void DPFit(UIView *view, UIView *pane) {
    if (!view) return;
    CGFloat paneW = pane.bounds.size.width, paneH = pane.bounds.size.height;
    if (gNativeSize.width <= 0 || gNativeSize.height <= 0 || paneW <= 0 || paneH <= 0) return;

    view.transform = CGAffineTransformIdentity;
    view.bounds = (CGRect){CGPointZero, gNativeSize};

    // Stretch ĐỘC LẬP theo X và Y: lấp kín pane hoàn toàn (không viền đen)
    // và co giãn theo CẢ chiều rộng lẫn chiều cao khi kéo divider — cover-scale
    // (đều X=Y) không làm được việc này vì chiều cao pane không đổi khi kéo,
    // nên hệ số scale gần như cố định. Đánh đổi: hình có thể hơi méo tỉ lệ.
    CGFloat scaleX = paneW / gNativeSize.width;
    CGFloat scaleY = paneH / gNativeSize.height;
    if (!isfinite(scaleX) || !isfinite(scaleY) || scaleX <= 0 || scaleY <= 0) return;

    view.center = CGPointMake(CGRectGetMidX(pane.bounds), CGRectGetMidY(pane.bounds));
    view.transform = CGAffineTransformMakeScale(scaleX, scaleY);
}
static const CGFloat kDividerGrabWidth = 28.0;   // vùng chạm (không hiển thị hết)
static const CGFloat kDividerVisualWidth = 5.0;  // vạch mảnh thực sự nhìn thấy
static const CGFloat kPaneGap = 2.0;
static const NSUInteger kMaxCachedApps = 6;      // nhớ tối đa 6 app đã mở trong phiên
static const CGFloat kPaneCornerRadius = 14.0;   // bo góc kiểu iPhone

static void DPLayout(void) {
    if (!gSplitWindow) return;
    CGFloat width = gSplitWindow.bounds.size.width, height = gSplitWindow.bounds.size.height;
    CGFloat split = floor(width * gRatio);

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
        DPFit(gPair[0].presentation, gLeftPane);
        DPFit(gPair[1].presentation, gRightPane);
    }
}
static void DPStop(NSString *reason) {
    if (!gRunning) return;
    gRunning = NO;
    ++gGeneration; // Cancel delayed creation and inspection from this attempt.
    DPSaveRatio();
    DPLog(@"STOP %@", reason);
    gSplitWindow.hidden = YES;
    BOOL previousOwnCall = gOwnCall;
    gOwnCall = YES;
    for (DPRecord *record in gPair) {
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
- (void)pan:(UIPanGestureRecognizer *)gesture;
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

- (void)pan:(UIPanGestureRecognizer *)gesture {
    if (!gRunning) return;
    if (gesture.state == UIGestureRecognizerStateBegan) gStartRatio = gRatio;
    CGFloat dx = [gesture translationInView:gSplitWindow].x;
    gRatio = MAX(0.30, MIN(0.70, gStartRatio + dx / MAX(1, gSplitWindow.bounds.size.width)));
    DPLayout();
    if (gesture.state == UIGestureRecognizerStateEnded ||
        gesture.state == UIGestureRecognizerStateCancelled ||
        gesture.state == UIGestureRecognizerStateFailed) {
        DPSaveRatio();
        DPLog(@"RATIO %.3f", gRatio);
    }
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
    [gDivider addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)]];
    UITapGestureRecognizer *swap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(swap)];
    swap.numberOfTapsRequired = 2; [gDivider addGestureRecognizer:swap];
    [root addSubview:gDivider];
    DPLayout(); gSplitWindow.hidden = NO; DPRefreshButton();
    DPLog(@"START left=%@ right=%@ — captured foreground settings, one call per scene", left.bundle, right.bundle);
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
        DPLog(@"CAPTURE bundle=%@ category=%@ sid=%@ controller=%p source=%@ suspended=%@", bundle, category, sid,
              (__bridge void *)controller,
              copy[@"DBActivationSettingLaunchSource"], copy[@"DBActivationSettingSuspended"]);
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
        record.valid = NO;
        DPStop(@"native scene destroyed");
        if (gPickerWindow) [gControls closePicker];
        [gRecords removeObjectForKey:bundle];
        [gOrder removeObject:bundle];
        DPRefreshButton();
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
%ctor {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayApp"]) return;
        gRecords = [NSMutableDictionary dictionary]; gOrder = [NSMutableArray array];
        if ([NSUserDefaults.standardUserDefaults objectForKey:DPRatioKey])
            gRatio = DPValidRatio([NSUserDefaults.standardUserDefaults doubleForKey:DPRatioKey]);
        gControls = [DPControls new];
        dispatch_async(dispatch_get_main_queue(), ^{
            DPLog(@"CTOR MANUAL EXPERIMENT — open two apps, tap Chia; no automatic split");
            DPTick();
        });
    }
}
