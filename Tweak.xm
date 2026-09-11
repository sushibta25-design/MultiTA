// DuoPhone V4.0 — CarPlay split screen
//
// Kiến trúc 2 process:
//
//  [CarPlay process]  — vẽ thanh divider, cho kéo trái/phải,
//                       publish tỉ lệ qua Darwin notification + file.
//  [SpringBoard]      — nhận tỉ lệ, tạo scene entity của app thứ 2
//                       trên CAR display, host sceneView vào nửa phải.
//
// Những API dưới đây đều đã được xác nhận tồn tại trên máy bạn
// qua trace V3.6/V3.9 (FBSDisplayIdentity.isCarDisplay,
// SBMainDisplaySceneManager, SBDeviceApplicationSceneEntity
// +newEntityWithApplication:sceneHandleProvider:displayIdentity:,
// SBSceneHandle newSceneViewWithReferenceSize:...,
// SBSystemShellExternalDisplaySceneManager).

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Cấu hình

static NSString *const kTracePath  = @"/var/mobile/DuoPhoneV4Trace.txt";
static NSString *const kRatioPath  = @"/var/mobile/Library/Caches/DuoPhoneRatio.txt";
static NSString *const kSecondApp  = @"com.apple.Maps";   // app pane phải

static CFStringRef const kNotifyRatio = CFSTR("com.duophone.ratio.changed");

static const CGFloat kDividerVisualW = 14.0;
static const CGFloat kDividerGrabW   = 44.0;
static const CGFloat kMinRatio       = 0.30;
static const CGFloat kMaxRatio       = 0.80;
static const CGFloat kCarPlayDockW   = 45.0;

#pragma mark - Tiện ích

static void DPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[%@:%d] %@\n",
                      NSProcessInfo.processInfo.processName ?: @"?",
                      getpid(), msg ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kTracePath];
    if (!h) { [data writeToFile:kTracePath atomically:YES]; return; }
    @try { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; }
    @catch (__unused NSException *e) {}
}

static BOOL DPIsCarPlay(void) {
    return [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.CarPlayApp"];
}
static BOOL DPIsSpringBoard(void) {
    return [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.springboard"];
}

static CGFloat DPClamp(CGFloat v, CGFloat lo, CGFloat hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static CGFloat gRatio = 0.60;

static void DPWriteRatio(CGFloat r) {
    [[NSString stringWithFormat:@"%f", r]
        writeToFile:kRatioPath atomically:YES
           encoding:NSUTF8StringEncoding error:nil];
    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kNotifyRatio, NULL, NULL, YES);
}

static CGFloat DPReadRatio(void) {
    NSString *s = [NSString stringWithContentsOfFile:kRatioPath
                                            encoding:NSUTF8StringEncoding
                                               error:nil];
    if (!s.length) return 0.60;
    return DPClamp(s.doubleValue, kMinRatio, kMaxRatio);
}

// Lấy id đối tượng qua KVC an toàn (không ném exception)
static id DPValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

#pragma mark ================= PHẦN 1: CarPlay process (divider) =========

static UIWindow *gDividerWindow = nil;
static UIView   *gDividerBar    = nil;
static BOOL      gDragging      = NO;
static CGFloat   gDragStartX    = 0.0;

@interface DPPanTarget : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
@end

static DPPanTarget *gPanTarget = nil;

static UIWindowScene *DPCarPlayScene(void) {
    UIWindowScene *fallback = nil;
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;
        if (!fallback) fallback = ws;
        if (s.activationState == UISceneActivationStateForegroundActive)
            return ws;
    }
    return fallback;
}

static void DPLayoutDivider(void) {
    if (!gDividerWindow) return;
    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    CGRect b = scene.coordinateSpace.bounds;
    CGFloat W = CGRectGetWidth(b), H = CGRectGetHeight(b);
    if (W <= 0 || H <= 0) return;

    CGFloat usableX = kCarPlayDockW;
    CGFloat usableW = MAX(0.0, W - kCarPlayDockW);
    CGFloat centerX = usableX + floor(usableW * gRatio);

    [UIView performWithoutAnimation:^{
        gDividerWindow.frame =
            CGRectMake(centerX - kDividerGrabW * 0.5, 0,
                       kDividerGrabW, H);
        gDividerBar.frame =
            CGRectMake((kDividerGrabW - kDividerVisualW) * 0.5, 0,
                       kDividerVisualW, H);
    }];
}

@implementation DPPanTarget

- (void)pan:(UIPanGestureRecognizer *)g {
    UIWindowScene *scene = DPCarPlayScene();
    if (!scene || !gDividerWindow) return;

    CGFloat usableW =
        MAX(1.0, CGRectGetWidth(scene.coordinateSpace.bounds) - kCarPlayDockW);

    if (g.state == UIGestureRecognizerStateBegan) {
        gDragging   = YES;
        gDragStartX = usableW * gRatio;
    }

    if (g.state == UIGestureRecognizerStateBegan ||
        g.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = [g translationInView:gDividerWindow].x;
        gRatio = DPClamp((gDragStartX + dx) / usableW, kMinRatio, kMaxRatio);
        DPLayoutDivider();
        DPWriteRatio(gRatio);     // báo SpringBoard resize pane phải theo thời gian thực
    }

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        gDragging = NO;
        DPWriteRatio(gRatio);
        DPLog(@"divider ratio=%.3f", gRatio);
    }
}

@end

static void DPCreateDivider(void) {
    if (!DPIsCarPlay() || gDividerWindow) return;

    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    gRatio = DPReadRatio();

    gDividerWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gDividerWindow.windowLevel     = UIWindowLevelAlert + 50;
    gDividerWindow.backgroundColor = UIColor.clearColor;
    gDividerWindow.rootViewController = [UIViewController new];
    gDividerWindow.hidden = NO;

    gDividerBar = [[UIView alloc] initWithFrame:CGRectZero];
    gDividerBar.backgroundColor  = [UIColor colorWithWhite:0.15 alpha:0.92];
    gDividerBar.layer.cornerRadius = kDividerVisualW * 0.5;
    [gDividerWindow.rootViewController.view addSubview:gDividerBar];

    // vạch kẻ tay cầm ở giữa cho dễ nhìn
    UIView *grip = [[UIView alloc] initWithFrame:CGRectZero];
    grip.backgroundColor = [UIColor colorWithWhite:0.85 alpha:0.9];
    grip.layer.cornerRadius = 1.5;
    grip.translatesAutoresizingMaskIntoConstraints = NO;
    [gDividerBar addSubview:grip];
    [NSLayoutConstraint activateConstraints:@[
        [grip.centerXAnchor constraintEqualToAnchor:gDividerBar.centerXAnchor],
        [grip.centerYAnchor constraintEqualToAnchor:gDividerBar.centerYAnchor],
        [grip.widthAnchor  constraintEqualToConstant:3.0],
        [grip.heightAnchor constraintEqualToConstant:38.0],
    ]];

    gPanTarget = [DPPanTarget new];
    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:gPanTarget
                                                action:@selector(pan:)];
    [gDividerWindow addGestureRecognizer:pan];

    DPLayoutDivider();
    DPLog(@"V4.0 divider ready ratio=%.3f", gRatio);
}

static void DPCarPlayTick(void) {
    if (!DPIsCarPlay()) return;

    if (!gDividerWindow) DPCreateDivider();
    if (gDividerWindow && !gDragging) DPLayoutDivider();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ DPCarPlayTick(); });
}

#pragma mark ================= PHẦN 2: SpringBoard (host app thứ 2) ======

static id gCarSceneManager   = nil;   // SBSystemShellExternalDisplaySceneManager
static id gCarDisplayIdentity = nil;  // FBSDisplayIdentity (isCarDisplay == YES)
static id gSecondSceneVC      = nil;  // SBDeviceApplicationSceneViewController
static UIView *gSecondPane    = nil;

// Tìm FBSDisplayIdentity của màn hình xe đang kết nối.
static id DPFindCarDisplayIdentity(void) {
    if (gCarDisplayIdentity) return gCarDisplayIdentity;

    Class cfgCls = NSClassFromString(@"FBSDisplayConfiguration");
    if (!cfgCls) return nil;

    // FBSDisplayMonitor giữ danh sách mọi display source đang gắn.
    Class monCls = NSClassFromString(@"FBSDisplayMonitor");
    id monitor = nil;
    if ([monCls respondsToSelector:@selector(sharedInstance)])
        monitor = [monCls performSelector:@selector(sharedInstance)];
    if (!monitor && [monCls respondsToSelector:@selector(monitor)])
        monitor = [monCls performSelector:@selector(monitor)];
    if (!monitor) {
        monitor = [[monCls alloc] init];   // monitor mới vẫn liệt kê được display
    }
    if (!monitor) return nil;

    id displays = DPValue(monitor, @"displays");
    if (![displays isKindOfClass:NSArray.class])
        displays = DPValue(monitor, @"connectedDisplays");

    for (id cfg in (NSArray *)displays) {
        NSNumber *isCar = DPValue(cfg, @"carDisplay");
        if (isCar.boolValue) {
            gCarDisplayIdentity = DPValue(cfg, @"identity");
            DPLog(@"V4.0 car identity=%@", gCarDisplayIdentity);
            return gCarDisplayIdentity;
        }
    }
    return nil;
}

// Bắt instance SBSystemShellExternalDisplaySceneManager ngay khi nó được tạo.
// Hook init là bắt buộc: trace trước đó cho thấy nếu tweak nạp SAU khi
// CarPlay đã kết nối thì không cách nào tìm lại được object này từ
// object graph của SBMainWorkspace (finder V3.9.10 visited=18, captured=nil).
static id (*gOrigInit4)(id, SEL, id, id, id, id) = NULL;
static id (*gOrigInit3)(id, SEL, id, id, id)     = NULL;

static void DPCaptureManager(id mgr, NSString *tag) {
    if (!mgr) return;
    id ident = DPValue(mgr, @"displayIdentity");
    NSNumber *isCar = DPValue(ident, @"carDisplay");
    DPLog(@"V4.0 %@ mgr=%@ identity=%@ isCar=%@",
          tag, NSStringFromClass([mgr class]), ident, isCar);
    if (isCar.boolValue) {
        gCarSceneManager    = mgr;
        gCarDisplayIdentity = ident;
        DPLog(@"V4.0 ===== CAPTURED CAR SCENE MANAGER =====");
    }
}

static id DPHookInit4(id self, SEL _cmd, id a, id b, id c, id d) {
    id r = gOrigInit4 ? gOrigInit4(self, _cmd, a, b, c, d) : nil;
    DPCaptureManager(r, @"init4");
    return r;
}
static id DPHookInit3(id self, SEL _cmd, id a, id b, id c) {
    id r = gOrigInit3 ? gOrigInit3(self, _cmd, a, b, c) : nil;
    DPCaptureManager(r, @"init3");
    return r;
}

static void DPInstallManagerHooks(void) {
    Class cls = NSClassFromString(@"SBSystemShellExternalDisplaySceneManager");
    if (!cls) { DPLog(@"V4.0 FAIL no external scene manager class"); return; }

    SEL s4 = NSSelectorFromString(
        @"initWithReference:sceneIdentityProvider:presentationBinder:snapshotBehavior:");
    Method m4 = class_getInstanceMethod(cls, s4);
    if (m4) {
        gOrigInit4 = (id (*)(id, SEL, id, id, id, id))method_getImplementation(m4);
        method_setImplementation(m4, (IMP)DPHookInit4);
        DPLog(@"V4.0 hooked init4");
    }

    SEL s3 = NSSelectorFromString(
        @"initWithReference:sceneIdentityProvider:presentationBinder:");
    Method m3 = class_getInstanceMethod(cls, s3);
    if (m3) {
        gOrigInit3 = (id (*)(id, SEL, id, id, id))method_getImplementation(m3);
        method_setImplementation(m3, (IMP)DPHookInit3);
        DPLog(@"V4.0 hooked init3");
    }
}

// Tạo scene entity cho app thứ 2 trên CAR display, rồi lấy view của nó.
static UIView *DPBuildSecondAppView(CGSize size) {
    id provider = gCarSceneManager;
    id identity = gCarDisplayIdentity ?: DPFindCarDisplayIdentity();

    if (!provider || !identity) {
        DPLog(@"V4.0 build FAIL provider=%@ identity=%@", provider, identity);
        return nil;
    }

    Class appCtrlCls = NSClassFromString(@"SBApplicationController");
    id appCtrl = [appCtrlCls performSelector:@selector(sharedInstance)];
    id app = [appCtrl performSelector:
              @selector(applicationWithBundleIdentifier:) withObject:kSecondApp];
    if (!app) { DPLog(@"V4.0 build FAIL no app %@", kSecondApp); return nil; }

    Class entityCls = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    SEL newEntity = NSSelectorFromString(
        @"newEntityWithApplication:sceneHandleProvider:displayIdentity:");
    if (![entityCls respondsToSelector:newEntity]) {
        DPLog(@"V4.0 build FAIL no newEntity selector"); return nil;
    }

    id (*mk)(id, SEL, id, id, id) =
        (id (*)(id, SEL, id, id, id))objc_msgSend;
    id entity = mk(entityCls, newEntity, app, provider, identity);
    if (!entity) { DPLog(@"V4.0 build FAIL entity nil"); return nil; }

    id handle = DPValue(entity, @"sceneHandle");
    if (!handle) { DPLog(@"V4.0 build FAIL handle nil"); return nil; }

    DPLog(@"V4.0 entity=%@ handle=%@ handleDisplay=%@",
          entity, handle, DPValue(handle, @"displayIdentity"));

    SEL newView = NSSelectorFromString(
        @"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:");
    if (![handle respondsToSelector:newView]) {
        DPLog(@"V4.0 build FAIL no newSceneView selector"); return nil;
    }

    UIView *(*mkv)(id, SEL, CGSize, long long, long long, id) =
        (UIView *(*)(id, SEL, CGSize, long long, long long, id))objc_msgSend;
    UIView *v = mkv(handle, newView, size, 3 /*landscapeRight*/, 3, nil);

    DPLog(@"V4.0 sceneView=%@ frame=%@",
          v, v ? NSStringFromCGRect(v.frame) : @"nil");
    return v;
}

// Đặt pane phải theo tỉ lệ hiện tại của divider.
static void DPLayoutSecondPane(void) {
    if (!gSecondPane) return;

    id cfg = DPValue(gCarDisplayIdentity, @"currentConfiguration");
    NSValue *bv = DPValue(cfg, @"bounds");
    if (!bv) return;

    CGRect b = bv.CGRectValue;
    CGFloat usableX = CGRectGetMinX(b) + kCarPlayDockW;
    CGFloat usableW = MAX(0.0, CGRectGetWidth(b) - kCarPlayDockW);
    CGFloat r = DPReadRatio();
    CGFloat leftW = floor(usableW * r);

    gSecondPane.frame = CGRectMake(usableX + leftW,
                                   CGRectGetMinY(b),
                                   usableW - leftW,
                                   CGRectGetHeight(b));
}

static void DPRatioChanged(CFNotificationCenterRef c, void *o,
                           CFStringRef n, const void *obj,
                           CFDictionaryRef ui) {
    dispatch_async(dispatch_get_main_queue(), ^{ DPLayoutSecondPane(); });
}

static void DPSpringBoardTick(void) {
    if (!DPIsSpringBoard()) return;

    if (gCarSceneManager && !gSecondPane) {
        id cfg = DPValue(gCarDisplayIdentity, @"currentConfiguration");
        NSValue *bv = DPValue(cfg, @"bounds");
        if (bv) {
            CGRect b = bv.CGRectValue;
            CGSize paneSize = CGSizeMake(
                (CGRectGetWidth(b) - kCarPlayDockW) * (1.0 - DPReadRatio()),
                CGRectGetHeight(b));
            gSecondPane = DPBuildSecondAppView(paneSize);
            if (gSecondPane) {
                DPLayoutSecondPane();
                DPLog(@"V4.0 second pane created");
            }
        }
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2000 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ DPSpringBoardTick(); });
}

#pragma mark - Entry

%ctor {
    @autoreleasepool {
        if (!DPIsCarPlay() && !DPIsSpringBoard()) return;

        DPLog(@"CTOR V4.0 bundle=%@",
              NSBundle.mainBundle.bundleIdentifier ?: @"nil");

        if (DPIsSpringBoard()) {
            // Hook NGAY trong ctor, trước khi CarPlay kịp kết nối.
            DPInstallManagerHooks();

            CFNotificationCenterAddObserver(
                CFNotificationCenterGetDarwinNotifyCenter(),
                NULL, DPRatioChanged, kNotifyRatio, NULL,
                CFNotificationSuspensionBehaviorCoalesce);

            dispatch_async(dispatch_get_main_queue(), ^{ DPSpringBoardTick(); });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{ DPCarPlayTick(); });
        }
    }
}
