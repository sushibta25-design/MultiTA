// DuoPhone V6.2.2 — template scene identity + presentation-only split
// Single-file update: replace Tweak.xm; package metadata remains unchanged.
// Device log showed Maps + CarPlaySettings pinned and YouTube Music rejected.
// This fixes selection/layout, NOT a claim of verified simultaneous app activity.
//
// Điều log V5.6 đã chứng minh:
//   - Re-parent một _UIScenePresentationView sang view khác + đổi frame
//     là hợp lệ, hệ thống không dựng lại ngay (V5.6 PROMOTE thành công).
//   - Nhưng cái được kéo sang là Car[2-3]:com.apple.Maps:dashboard —
//     widget điều hướng (DBMapsNavigationWidgetViewController, 179x224),
//     không phải app Maps đầy đủ. Nên kết quả là widget bị kéo giãn.
//
// V6.2.2 tiếp tục thử nghiệm host hai full-app scene trong CarPlayApp.
// Giữ controller/view không bảo đảm process ứng dụng còn foreground.
// Hooks lifecycle vẫn gọi %orig; phải kiểm tra cả hình động và touch trên xe.
// Mở app A rồi app B để thu thập hai scene, kéo divider để đổi tỷ lệ.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <unistd.h>
#import <math.h>

#pragma mark - Hằng số

static NSString *const kTracePath =
    @"/var/mobile/DuoPhoneV6Trace.txt";
static NSString *const kRatioKey  = @"DuoPhoneSplitRatio";
static NSString *const kLeftKey   = @"DuoPhoneLeftApp";
static NSString *const kRightKey  = @"DuoPhoneRightApp";

static const CGFloat kDividerVisualW = 16.0;
static const CGFloat kDividerGrabW   = 44.0;
static const CGFloat kMinRatio       = 0.30;
static const CGFloat kMaxRatio       = 0.80;
static const CGFloat kCarPlayDockW   = 45.0;
static const CGFloat kPaneGap        = 2.0;

#pragma mark - Trace

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

static CGFloat DPClamp(CGFloat v, CGFloat lo, CGFloat hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static id DPValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

#pragma mark - Trạng thái

static UIWindow *gDividerWindow = nil;
static UIView   *gDividerBar    = nil;
static CGFloat   gRatio         = 0.50;
static BOOL      gDragging      = NO;
static CGFloat   gDragStartX    = 0.0;

// bundle id -> presentation view của scene app đó
static NSMutableDictionary<NSString *, UIView *> *gScenes = nil;
// bundle id -> DBApplicationSceneViewController (giữ sống full app controller)
static NSMutableDictionary<NSString *, id> *gAppControllers = nil;
// thứ tự xuất hiện, dùng để chọn 2 app gần nhất
static NSMutableArray<NSString *> *gOrder = nil;

static NSString *gLeftApp  = nil;
static NSString *gRightApp = nil;

static __weak UIView *gHostRoot = nil;     // view gốc của dashboard window
static BOOL gSplitActive = NO;

static void DPLayoutDivider(void);

#pragma mark - Prefs

static void DPLoadPrefs(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    if ([d objectForKey:kRatioKey])
        gRatio = DPClamp([d doubleForKey:kRatioKey], kMinRatio, kMaxRatio);
    // Chọn lại theo scene của phiên kết nối; không hồi sinh cặp Maps/Settings cũ.
    gLeftApp = nil;
    gRightApp = nil;
    [d removeObjectForKey:kLeftKey];
    [d removeObjectForKey:kRightKey];
}

static void DPSavePrefs(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setDouble:gRatio forKey:kRatioKey];
    if (gLeftApp)  [d setObject:gLeftApp  forKey:kLeftKey];
    if (gRightApp) [d setObject:gRightApp forKey:kRightKey];
}

#pragma mark - Scene CarPlay

static UIWindowScene *DPCarPlayScene(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;

        NSString *pid = s.session.persistentIdentifier ?: @"";
        if ([pid containsString:@"DBDashboard-Car"]) return ws;
    }
    return nil;
}

// View gốc của window chứa DBDashboardRootViewController.
static UIView *DPDashboardRootView(UIWindowScene *ws) {
    if (!ws) return nil;
    if (gHostRoot.window.windowScene == ws) return gHostRoot;
    gHostRoot = nil;

    for (UIWindow *w in ws.windows) {
        UIViewController *root = w.rootViewController;
        if (!root) continue;

        if ([NSStringFromClass([root class])
                containsString:@"DBDashboardRootViewController"]) {
            gHostRoot = root.view;
            return root.view;
        }
    }
    return nil;
}

#pragma mark - Nhận diện scene app

// sceneID dạng "Car[2-3]:com.apple.Maps" hoặc
// "Car[2-3]:com.apple.Maps:dashboard" (widget — bỏ qua).
static NSString *DPBundleFromSceneID(NSString *sceneID) {
    if (!sceneID.length) return nil;

    NSArray<NSString *> *parts = [sceneID componentsSeparatedByString:@":"];

    if (parts.count < 2) return nil;
    NSString *display = parts[0];
    if (![display hasPrefix:@"Car["] || ![display hasSuffix:@"]"]) return nil;

    NSString *bundle = nil;
    if (parts.count == 3 &&
        [parts[1] isEqualToString:@"com.apple.CarPlayTemplateUIHost"]) {
        // Đã quan sát trong log thiết bị: host chung + bundle app thật.
        bundle = parts[2];
    } else if (parts.count == 2) {
        bundle = parts[1];
    } else {
        return nil; // dashboard/widget và các scene phụ chưa xác minh
    }
    if (![bundle containsString:@"."]) return nil;

    // Các surface hệ thống không phải app pane.
    if ([bundle isEqualToString:@"com.apple.CarPlayApp"] ||
        [bundle isEqualToString:@"com.apple.CarPlayWallpaper"] ||
        [bundle isEqualToString:@"com.apple.CarPlaySettings"] ||
        [bundle isEqualToString:@"com.apple.CarPlayTemplateUIHost"])
        return nil;

    return bundle;
}

static NSString *DPSceneIDOfHost(UIView *host) {
    id sid = DPValue(host, @"sceneID");
    if ([sid isKindOfClass:NSString.class]) return sid;

    // Fallback: lấy từ description, sceneID luôn được in ra.
    NSString *desc = host.description ?: @"";
    NSRange r = [desc rangeOfString:@"sceneID: "];
    if (r.location == NSNotFound) return nil;

    NSString *rest = [desc substringFromIndex:NSMaxRange(r)];
    NSRange end = [rest rangeOfString:@";"];
    if (end.location == NSNotFound) return nil;

    return [rest substringToIndex:end.location];
}

// _UIScenePresentationView là cha của _UISceneLayerHostContainerView.
static UIView *DPPresentationForHost(UIView *host) {
    UIView *cur = host;
    NSInteger depth = 0;

    while (cur && depth < 4) {
        if ([NSStringFromClass([cur class])
                containsString:@"_UIScenePresentationView"])
            return cur;
        cur = cur.superview;
        depth++;
    }
    return nil; // Không kéo một container tùy ý khi thiếu presentation view.
}

static void DPCollectScenes(UIView *v, NSInteger depth) {
    if (!v || depth > 14) return;

    NSString *cn = NSStringFromClass([v class]);

    if ([cn containsString:@"_UISceneLayerHostContainerView"]) {
        NSString *sceneID = DPSceneIDOfHost(v);
        NSString *bundle  = DPBundleFromSceneID(sceneID);

        if (bundle && !gAppControllers[bundle]) {
            UIView *presentation = DPPresentationForHost(v);

            if (presentation && gScenes[bundle] != presentation) {
                UIView *previous = gScenes[bundle];
                if (gHostRoot && previous.superview == gHostRoot)
                    [previous removeFromSuperview];
                gScenes[bundle] = presentation;
                gSplitActive = NO;

                [gOrder removeObject:bundle];
                [gOrder addObject:bundle];

                DPLog(@"V6.2.2 SCENE FOUND bundle=%@ sceneID=%@ presentation=%@ frame=%@",
                      bundle, sceneID,
                      NSStringFromClass([presentation class]),
                      NSStringFromCGRect(presentation.frame));
            }
        }
    }

    for (UIView *c in v.subviews)
        DPCollectScenes(c, depth + 1);
}

static void DPRegisterAppController(id controller) {
    if (!controller || !gScenes || !gAppControllers || !gOrder) return;

    NSString *sceneID = DPValue(controller, @"sceneID");
    if (![sceneID isKindOfClass:NSString.class]) return;

    NSString *bundle = DPBundleFromSceneID(sceneID);
    if (!bundle) return;

    id hostObj = DPValue(controller, @"sceneHostView");
    if (![hostObj isKindOfClass:UIView.class]) return;

    UIView *host = (UIView *)hostObj;
    if (![NSStringFromClass(host.class) containsString:@"_UIScenePresentationView"])
        return;

    BOOL changed = gAppControllers[bundle] != controller || gScenes[bundle] != host;
    UIView *previous = gScenes[bundle];
    if (previous != host && gHostRoot && previous.superview == gHostRoot)
        [previous removeFromSuperview];
    gAppControllers[bundle] = controller;
    gScenes[bundle] = host;

    if (!changed) return;
    gSplitActive = NO;

    [gOrder removeObject:bundle];
    [gOrder addObject:bundle];

    DPLog(@"V6.2.2 FULL APP REGISTER bundle=%@ sceneID=%@ controller=%@ host=%@ frame=%@",
          bundle, sceneID, NSStringFromClass([controller class]),
          NSStringFromClass([host class]), NSStringFromCGRect(host.frame));
    DPLog(@"V6.2.2 HOST DETAIL bundle=%@ host=%p parent=%@ children=%@",
          bundle, (__bridge void *)host, NSStringFromClass(host.superview.class), host.subviews);
}

static void DPCollectAppControllers(UIViewController *vc) {
    if (!vc) return;

    if ([NSStringFromClass([vc class]) containsString:@"DBApplicationSceneViewController"])
        DPRegisterAppController(vc);

    for (UIViewController *child in vc.childViewControllers)
        DPCollectAppControllers(child);

    if (vc.presentedViewController)
        DPCollectAppControllers(vc.presentedViewController);
}

static void DPScanScenes(UIWindowScene *ws) {
    if (!ws) return;

    for (UIWindow *w in ws.windows) {
        if (w == gDividerWindow) continue;

        if (w.rootViewController) {
            DPCollectAppControllers(w.rootViewController);
            DPCollectScenes(w.rootViewController.view, 0);
        } else {
            DPCollectScenes(w, 0);
        }
    }
}

#pragma mark - Chọn 2 app cho 2 pane

static void DPResolvePanes(void) {
    // Ưu tiên lựa chọn người dùng nếu scene tương ứng đang sống.
    BOOL leftOK  = gLeftApp  && gScenes[gLeftApp];
    BOOL rightOK = gRightApp && gScenes[gRightApp];

    if (leftOK && rightOK && ![gLeftApp isEqualToString:gRightApp]) return;
    if (leftOK && [gLeftApp isEqualToString:gRightApp]) {
        gRightApp = nil;
        rightOK = NO;
    }

    // Nếu không, lấy 2 app xuất hiện gần nhất.
    NSInteger n = (NSInteger)gOrder.count;
    if (n == 0) return;

    if (!rightOK) {
        NSString *newest = gOrder.lastObject;
        if (![newest isEqualToString:gLeftApp]) gRightApp = newest;
    }

    if (!leftOK && n >= 2) {
        for (NSInteger i = n - 1; i >= 0; i--) {
            NSString *b = gOrder[(NSUInteger)i];
            if (![b isEqualToString:gRightApp]) { gLeftApp = b; break; }
        }
    }
}

#pragma mark - Áp dụng split


static void DPPinPaneForBundle(NSString *bundle, UIView *presentation, UIView *root, CGRect frame) {
    if (!bundle.length || !presentation || !root) return;
    // Chỉ di chuyển surface của app, không di chuyển controller.view.
    if (presentation == root || [root isDescendantOfView:presentation]) return;
    if (presentation.superview != root) {
        DPLog(@"V6.2.2 MOVE SURFACE bundle=%@ from=%@ frame=%@", bundle,
              NSStringFromClass(presentation.superview.class), NSStringFromCGRect(frame));
        [root addSubview:presentation];
    }
    presentation.frame = frame;
    presentation.hidden = NO;
    presentation.alpha = 1.0;
    presentation.clipsToBounds = YES;
    presentation.userInteractionEnabled = YES;
    for (UIView *child in presentation.subviews) {
        if ([NSStringFromClass(child.class) containsString:@"_UISceneLayerHostContainerView"])
            child.frame = presentation.bounds;
    }
    // Không gọi _updateSceneUI trên controller còn thuộc layout toàn màn hình.
    // Resize remote scene và trạng thái foreground vẫn cần xác minh trên xe.
}

static void DPApplySplit(void) {
    UIWindowScene *ws = DPCarPlayScene();
    if (!ws) return;

    DPScanScenes(ws);
    DPResolvePanes();

    UIView *root = DPDashboardRootView(ws);
    if (!root) return;

    UIView *leftView  = gLeftApp  ? gScenes[gLeftApp]  : nil;
    UIView *rightView = gRightApp ? gScenes[gRightApp] : nil;

    if (!leftView || !rightView || leftView == rightView) {
        gDividerWindow.hidden = YES;
        gSplitActive = NO;
        static NSUInteger miss = 0;
        if ((miss++ % 10) == 0)
            DPLog(@"V6.2.2 WAIT TWO APPS (native layout untouched): known=%lu order=%@",
                  (unsigned long)gScenes.count, gOrder);
        return;
    }

    CGFloat W = CGRectGetWidth(ws.coordinateSpace.bounds);
    CGFloat H = CGRectGetHeight(ws.coordinateSpace.bounds);

    CGFloat usableX = kCarPlayDockW;
    CGFloat usableW = MAX(1.0, W - kCarPlayDockW);
    CGFloat splitX  = usableX + floor(usableW * gRatio);

    CGRect left  = CGRectMake(usableX, 0,
                              MAX(1.0, splitX - usableX - kPaneGap), H);
    CGRect right = CGRectMake(splitX + kPaneGap, 0,
                              MAX(1.0, W - splitX - kPaneGap), H);

    [UIView performWithoutAnimation:^{
        if (leftView)  DPPinPaneForBundle(gLeftApp, leftView, root, left);
        if (rightView) DPPinPaneForBundle(gRightApp, rightView, root, right);

        if (leftView.superview == root) [root bringSubviewToFront:leftView];
        if (rightView.superview == root) [root bringSubviewToFront:rightView];
    }];

    BOOL hasTwoPanes = leftView != rightView && leftView.superview == root && rightView.superview == root;
    gDividerWindow.hidden = !hasTwoPanes;
    if (gSplitActive != hasTwoPanes) {
        gSplitActive = hasTwoPanes;
        DPLog(@"V6.2.2 TWO PANES ATTACHED=%d (app liveness unverified)", hasTwoPanes);
        DPLog(@"V6.2.2 left=%@ (%@) right=%@ (%@)",
              gLeftApp ?: @"nil", NSStringFromCGRect(left),
              gRightApp ?: @"nil", NSStringFromCGRect(right));
    }

    static CGRect lastRight = {{0,0},{0,0}};
    if (!CGRectEqualToRect(lastRight, right)) {
        lastRight = right;
        DPLog(@"V6.2.2 panes left=%@ right=%@ ratio=%.2f",
              NSStringFromCGRect(left), NSStringFromCGRect(right), gRatio);
    }
}

#pragma mark - Divider

@interface DPDividerTarget : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)doubleTap:(UITapGestureRecognizer *)g;
@end

static DPDividerTarget *gTarget = nil;

@implementation DPDividerTarget

- (void)pan:(UIPanGestureRecognizer *)g {
    UIWindowScene *scene = DPCarPlayScene();
    if (!scene || !gDividerWindow) return;

    CGFloat usableW = MAX(1.0,
        CGRectGetWidth(scene.coordinateSpace.bounds) - kCarPlayDockW);

    if (g.state == UIGestureRecognizerStateBegan) {
        gDragging   = YES;
        gDragStartX = usableW * gRatio;
    }

    if (g.state == UIGestureRecognizerStateBegan ||
        g.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = [g translationInView:gDividerWindow].x;
        gRatio = DPClamp((gDragStartX + dx) / usableW, kMinRatio, kMaxRatio);
        DPLayoutDivider();
        DPApplySplit();            // resize 2 pane theo thời gian thực
    }

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        gDragging = NO;
        DPSavePrefs();
        DPLog(@"V6.2.2 ratio=%.3f", gRatio);
    }
}

// Chạm 2 lần: đổi chỗ 2 pane cho nhau.
- (void)doubleTap:(UITapGestureRecognizer *)g {
    NSString *tmp = gLeftApp;
    gLeftApp  = gRightApp;
    gRightApp = tmp;
    DPSavePrefs();
    DPLog(@"V6.2.2 swap left=%@ right=%@", gLeftApp ?: @"nil", gRightApp ?: @"nil");
    DPApplySplit();
}

@end

static void DPLayoutDivider(void) {
    if (!gDividerWindow) return;

    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    CGRect b = scene.coordinateSpace.bounds;
    CGFloat W = CGRectGetWidth(b), H = CGRectGetHeight(b);
    if (W <= 0 || H <= 0) return;

    CGFloat centerX = kCarPlayDockW + floor((W - kCarPlayDockW) * gRatio);

    [UIView performWithoutAnimation:^{
        gDividerWindow.frame =
            CGRectMake(centerX - kDividerGrabW * 0.5, 0, kDividerGrabW, H);
        gDividerBar.frame =
            CGRectMake((kDividerGrabW - kDividerVisualW) * 0.5, 0,
                       kDividerVisualW, H);
    }];
}

static void DPCreateDivider(void) {
    if (!DPIsCarPlay() || gDividerWindow) return;

    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    gDividerWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gDividerWindow.windowLevel     = UIWindowLevelAlert + 80.0;
    gDividerWindow.backgroundColor = UIColor.clearColor;
    gDividerWindow.rootViewController = [UIViewController new];
    gDividerWindow.rootViewController.view.backgroundColor = UIColor.clearColor;

    gDividerBar = [UIView new];
    gDividerBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    gDividerBar.layer.cornerRadius = kDividerVisualW * 0.5;
    gDividerBar.layer.shadowColor   = UIColor.blackColor.CGColor;
    gDividerBar.layer.shadowOpacity = 0.5;
    gDividerBar.layer.shadowRadius  = 6.0;
    [gDividerWindow.rootViewController.view addSubview:gDividerBar];

    UILabel *hint = [UILabel new];
    hint.text = @"⇄";
    hint.textColor = UIColor.whiteColor;
    hint.font = [UIFont boldSystemFontOfSize:15.0];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [gDividerBar addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:gDividerBar.centerXAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:gDividerBar.centerYAnchor],
    ]];

    gTarget = [DPDividerTarget new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:gTarget
                                                action:@selector(pan:)];
    pan.cancelsTouchesInView = NO;
    [gDividerWindow addGestureRecognizer:pan];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:gTarget
                                                action:@selector(doubleTap:)];
    tap.numberOfTapsRequired = 2;
    [gDividerWindow addGestureRecognizer:tap];

    DPLayoutDivider();
    gDividerWindow.hidden = YES;

    DPLog(@"V6.2.2 divider ready frame=%@",
          NSStringFromCGRect(gDividerWindow.frame));
}

#pragma mark - Vòng lặp

static void DPTick(void) {
    if (!DPIsCarPlay()) return;

    UIWindowScene *scene = DPCarPlayScene();
    if (gDividerWindow && gDividerWindow.windowScene != scene) {
        gDividerWindow.hidden = YES;
        gDividerWindow = nil;
        gDividerBar = nil;
        gTarget = nil;
        gHostRoot = nil;
        gSplitActive = NO;
        gDragging = NO;
        [gScenes removeAllObjects];
        [gAppControllers removeAllObjects];
        gLeftApp = nil;
        gRightApp = nil;
        [gOrder removeAllObjects];
        DPLog(@"V6.2.2 DISPLAY RESET: cleared retained app views");
    }

    if (!gDividerWindow) DPCreateDivider();
    if (gDividerWindow && !gDragging) DPLayoutDivider();

    DPApplySplit();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 500 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ DPTick(); });
}



#pragma mark - V6.2.2 observe lifecycle without blocking CarPlay

%hook DBApplicationSceneViewController

- (void)setScene:(id)scene {
    %orig;
    DPRegisterAppController(self);
}

- (void)setSceneHostView:(id)view {
    %orig;
    DPRegisterAppController(self);
}

- (void)foregroundSceneWithSettings:(id)settings completion:(id)completion {
    %orig;
    DPRegisterAppController(self);
}

- (void)backgroundSceneWithCompletion:(id)completion {
    NSString *sceneID = DPValue(self, @"sceneID");
    DPLog(@"V6.2.2 lifecycle background sceneID=%@", sceneID ?: @"nil");
    %orig;
    DPRegisterAppController(self);
}

- (void)deactivateSceneWithReasonMask:(NSUInteger)mask {
    NSString *sceneID = DPValue(self, @"sceneID");
    DPLog(@"V6.2.2 lifecycle deactivate sceneID=%@ mask=%lu",
          sceneID ?: @"nil", (unsigned long)mask);
    %orig;
    DPRegisterAppController(self);
}

%end

%ctor {
    @autoreleasepool {
        if (!DPIsCarPlay()) return;

        gScenes = [NSMutableDictionary dictionary];
        gAppControllers = [NSMutableDictionary dictionary];
        gOrder  = [NSMutableArray array];

        DPLoadPrefs();
        DPLog(@"V6.2.2 runtime DBApplicationSceneViewController=%@",
              NSClassFromString(@"DBApplicationSceneViewController"));
        DPLog(@"CTOR V6.2.2 bundle=%@ ratio=%.2f left=%@ right=%@",
              NSBundle.mainBundle.bundleIdentifier ?: @"nil",
              gRatio, gLeftApp ?: @"nil", gRightApp ?: @"nil");

        dispatch_async(dispatch_get_main_queue(), ^{ DPTick(); });
    }
}
