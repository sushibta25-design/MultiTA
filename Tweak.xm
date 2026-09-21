// TAduo 0.6.0: native scene-settings transaction and client geometry observations.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import <string.h>
#import <notify.h>
#import <objc/runtime.h>

static void TALog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    @synchronized (NSFileManager.defaultManager) {
        NSString *path = [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"] ? @"/var/mobile/TAduo-template.log" : @"/var/mobile/TAduo.log";
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attrs fileSize] > 1024 * 1024) {
            [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
            [NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
        }
        NSData *data = [[NSString stringWithFormat:@"%@ [TAduo 0.6] %@\n", NSDate.date, s] dataUsingEncoding:NSUTF8StringEncoding];
        NSFileHandle *f = [NSFileHandle fileHandleForWritingAtPath:path];
        if (!f) { [data writeToFile:path atomically:YES]; return; }
        @try { [f seekToEndOfFile]; [f writeData:data]; } @catch (__unused NSException *e) {} @finally { [f closeFile]; }
    }
}
static id TAValue(id o, NSString *key) {
    @try { return [o valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
static NSString *TABundle(id controller) {
    NSString *sid = TAValue(controller, @"sceneID");
    if (![sid isKindOfClass:NSString.class] || ![sid hasPrefix:@"Car["]) return nil;
    NSArray *parts = [sid componentsSeparatedByString:@":"];
    NSString *bundle = parts.count == 2 ? parts[1] :
        (parts.count == 3 && [parts[1] isEqual:@"com.apple.CarPlayTemplateUIHost"] ? parts[2] : nil);
    if (![bundle containsString:@"."] || [@[@"com.apple.CarPlayApp", @"com.apple.CarPlaySettings", @"com.apple.CarPlayWallpaper", @"com.apple.CarPlayTemplateUIHost"] containsObject:bundle]) return nil;
    return bundle;
}
@interface TARecord : NSObject
@property(nonatomic,strong) id controller;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSDictionary *activation;
@property(nonatomic,strong) id scene;
@property(nonatomic,strong) UIView *presentation;
@property(nonatomic,copy) NSString *presentationID;
@property(nonatomic,copy) NSString *updater;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) BOOL changed;
@property(nonatomic) BOOL frameCaptured;
@property(nonatomic) CGSize targetSize;
@property(nonatomic) NSUInteger resizeSerial;
@property(nonatomic) BOOL backgrounded;
@property(nonatomic) BOOL restoreBackground;
@end
@implementation TARecord
@end
static NSMutableDictionary<NSString *, TARecord *> *records;
static NSMutableArray<NSString *> *order;
static TARecord *slots[2];
static UIView *panes[2];
static UIButton *choose[2];
static UIWindow *splitWindow, *buttonWindow;
static UIView *floatingActions;
static __weak UIWindowScene *dashboard;
static BOOL running, ownCall;
static NSUInteger generation;
static void TAStop(NSString *reason);
static void TASetLayoutTarget(NSString *bundle, CGSize size);
static UIWindowScene *TADashboard(void) {
    for (UIScene *s in UIApplication.sharedApplication.connectedScenes)
        if ([s isKindOfClass:UIWindowScene.class] && [s.session.persistentIdentifier containsString:@"DBDashboard-Car"])
            return (UIWindowScene *)s;
    return nil;
}
static BOOL TAReadFrame(id scene, CGRect *frame) {
    id v = TAValue(TAValue(scene, @"settings"), @"frame");
    if (![v isKindOfClass:NSValue.class] || strcmp([v objCType], @encode(CGRect))) return NO;
    *frame = [v CGRectValue];
    return isfinite(frame->size.width) && isfinite(frame->size.height) && frame->size.width > 0 && frame->size.height > 0;
}
static BOOL TASetFrame(id settings, CGRect frame) {
    SEL sel = NSSelectorFromString(@"setFrame:");
    NSMethodSignature *sig = [settings methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) || strcmp([sig getArgumentTypeAtIndex:2], @encode(CGRect))) return NO;
    ((void(*)(id,SEL,CGRect))objc_msgSend)(settings, sel, frame); return YES;
}
// Do not confuse the existence of a UI updater with its ability to mutate a
// scene frame. Prefer the native scene-settings transaction; fall back only
// after the chosen callback explicitly rejects the frame setter.
static BOOL TAHasUpdater(id scene, NSString *name) {
    NSMethodSignature *sig = [scene methodSignatureForSelector:NSSelectorFromString(name)];
    return sig && sig.numberOfArguments == 3 && !strcmp(sig.methodReturnType, @encode(void)) && !strcmp([sig getArgumentTypeAtIndex:2], "@?");
}
static void TAInvokeVoid(id object, NSString *name) {
    SEL sel = NSSelectorFromString(name);
    NSMethodSignature *sig = [object methodSignatureForSelector:sel];
    if (sig && sig.numberOfArguments == 2 && !strcmp(sig.methodReturnType, @encode(void)))
        ((void(*)(id,SEL))objc_msgSend)(object, sel);
}
static void TAObserve(TARecord *r, NSUInteger token, NSUInteger serial, NSString *phase) {
    if (!running || generation != token || r.resizeSerial != serial) return;
    CGRect actual = CGRectZero; BOOL readable = TAReadFrame(r.scene, &actual);
    TALog(@"HOST %@ bundle=%@ target=%@ settings=%@ readable=%d presentation=%@ transform=%@", phase, r.bundle,
          NSStringFromCGSize(r.targetSize), NSStringFromCGRect(actual), readable,
          NSStringFromCGRect(r.presentation.bounds), NSStringFromCGAffineTransform(r.presentation.transform));
}
static void TATransact(TARecord *r, NSUInteger token, NSUInteger serial, NSUInteger index) {
    NSArray *paths = @[@"updateSettingsWithBlock:", @"updateUISettingsWithBlock:"];
    if (!running || generation != token || r.resizeSerial != serial) return;
    if (index >= paths.count) { TALog(@"RESIZE UNSUPPORTED %@", r.bundle); return; }
    NSString *path = paths[index];
    if (!TAHasUpdater(r.scene, path)) { TATransact(r, token, serial, index + 1); return; }
    __block BOOL called = NO;
    void (^change)(id) = ^(id settings) {
        called = YES;
        if (!running || generation != token || r.resizeSerial != serial || r.scene != TAValue(r.controller, @"scene")) return;
        @try {
            BOOL accepted = TASetFrame(settings, (CGRect){CGPointZero, r.targetSize});
            TALog(@"RESIZE REQUEST %@ target=%@ setter=%d path=%@ settingsClass=%@", r.bundle,
                  NSStringFromCGSize(r.targetSize), accepted, path, NSStringFromClass([settings class]));
            if (accepted) { r.changed = YES; r.updater = path; }
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!running || generation != token || r.resizeSerial != serial) return;
                if (!accepted) { TATransact(r, token, serial, index + 1); return; }
                @try {
                    TAInvokeVoid(r.controller, @"_updateSceneUI");
                    TAInvokeVoid(r.presentation, @"_updateFrameAndTransform");
                    [r.presentation setNeedsLayout];
                } @catch (NSException *e) { TALog(@"REFRESH ERROR %@", e.name); }
                TAObserve(r, token, serial, @"after-transaction");
            });
        } @catch (NSException *e) { TALog(@"RESIZE ERROR %@ %@", r.bundle, e.name); }
    };
    @try { ((void(*)(id,SEL,id))objc_msgSend)(r.scene, NSSelectorFromString(path), change); }
    @catch (NSException *e) { TALog(@"TRANSACTION ERROR %@ %@", r.bundle, e.name); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (running && generation == token && r.resizeSerial == serial && !called)
            TALog(@"RESIZE NO CALLBACK %@ path=%@ (no speculative fallback)", r.bundle, path);
    });
}
static void TAResize(TARecord *r, CGSize size) {
    id scene = TAValue(r.controller, @"scene");
    if (!r.frameCaptured) {
        CGRect original = CGRectZero;
        if (!TAReadFrame(scene, &original)) { TALog(@"RESIZE NO FRAME %@", r.bundle); return; }
        r.scene = scene; r.originalFrame = original; r.frameCaptured = YES;
    }
    if (r.scene != scene) { TAStop(@"resize scene changed"); return; }
    r.targetSize = size;
    TASetLayoutTarget(r.bundle, size);
    NSUInteger token = generation, serial = ++r.resizeSerial;
    TATransact(r, token, serial, 0);
    for (NSNumber *delay in @[@0.25, @1.0, @3.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            TAObserve(r, token, serial, [NSString stringWithFormat:@"after-%@s", delay]);
        });
    }
}
static void TACleanup(TARecord *r) {
    if (!r) return;
    TASetLayoutTarget(r.bundle, CGSizeZero);
    if (r.changed && r.scene == TAValue(r.controller, @"scene")) {
        CGRect original = r.originalFrame;
        void (^restore)(id) = ^(id settings) { @try { TALog(@"RESTORE %@ ok=%d", r.bundle, TASetFrame(settings, original)); } @catch (__unused NSException *e) {} };
        @try { ((void(*)(id,SEL,id))objc_msgSend)(r.scene, NSSelectorFromString(r.updater), restore); } @catch (__unused NSException *e) {}
    }
    [r.presentation removeFromSuperview]; r.presentation = nil;
    @try {
        SEL invalidate = NSSelectorFromString(@"invalidatePresentationViewForIdentifier:");
        if (r.presentationID && [r.controller respondsToSelector:invalidate]) ((void(*)(id,SEL,id))objc_msgSend)(r.controller, invalidate, r.presentationID);
    } @catch (__unused NSException *e) {}
    @try {
        SEL bg = NSSelectorFromString(@"backgroundSceneWithCompletion:");
        if (r.restoreBackground && [r.controller respondsToSelector:bg]) ((void(*)(id,SEL,id))objc_msgSend)(r.controller, bg, nil);
    } @catch (__unused NSException *e) {}
    r.backgrounded = r.restoreBackground;
    r.presentationID = nil; r.scene = nil; r.changed = NO; r.frameCaptured = NO; ++r.resizeSerial;
}
static void TAStop(NSString *reason) {
    if (!running) return;
    running = NO; ++generation;
    TALog(@"STOP %@", reason);
    BOOL previous = ownCall; ownCall = YES;
    for (NSInteger i = 0; i < 2; i++) { TACleanup(slots[i]); slots[i] = nil; panes[i] = nil; choose[i] = nil; }
    ownCall = previous;
    splitWindow.hidden = YES; splitWindow = nil; floatingActions = nil;
    buttonWindow.hidden = order.count < 2;
}
@interface TAControls : NSObject
- (void)start;
- (void)stop;
- (void)restartSplit;
- (void)toggleActions;
- (void)snapshot;
- (void)pick:(UIButton *)sender;
- (void)attach:(NSString *)bundle slot:(NSInteger)slot;
@end
static TAControls *controls;
static UIButton *TAButton(NSString *title, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal]; b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.95];
    [b addTarget:controls action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
@implementation TAControls
- (void)stop { TAStop(@"user"); }
- (void)toggleActions { floatingActions.hidden = !floatingActions.hidden; }
- (void)snapshot {
    floatingActions.hidden = YES;
    TALog(@"MANUAL SNAPSHOT REQUEST");
    notify_post("com.sushibta.taduo.snapshot");
}
- (void)restartSplit {
    if (!running || splitWindow.rootViewController.presentedViewController) return;
    TAStop(@"choose apps again");
    dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
}
- (void)start {
    if (running || !dashboard || TADashboard() != dashboard) return;
    CGRect bounds = dashboard.coordinateSpace.bounds;
    if (bounds.size.width < 150 || bounds.size.height < 100) return;
    running = YES; ++generation;
    splitWindow = [[UIWindow alloc] initWithWindowScene:dashboard];
    splitWindow.frame = bounds; splitWindow.windowLevel = UIWindowLevelAlert + 70;
    splitWindow.rootViewController = [UIViewController new];
    UIView *root = splitWindow.rootViewController.view; root.backgroundColor = UIColor.blackColor;
    // Both scenes occupy full display height. Only floating button hit areas
    // cover content; no toolbar strip is reserved in scene geometry.
    CGFloat half = bounds.size.width / 2;
    for (NSInteger i = 0; i < 2; i++) {
        panes[i] = [[UIView alloc] initWithFrame:CGRectMake(i * half, 0, half, bounds.size.height)];
        panes[i].clipsToBounds = YES; [root addSubview:panes[i]];
        choose[i] = TAButton(i == 0 ? @"Chọn app trái" : @"Chọn app phải", @selector(pick:));
        choose[i].tag = i; choose[i].frame = panes[i].bounds; [panes[i] addSubview:choose[i]];
    }
    floatingActions = [[UIView alloc] initWithFrame:CGRectMake(half - 78, bounds.size.height / 2 - 49, 156, 30)];
    floatingActions.backgroundColor = UIColor.clearColor;
    NSArray *titles = @[@"Chia", @"Log", @"Thoát"];
    NSArray *actions = @[@"restartSplit", @"snapshot", @"stop"];
    for (NSUInteger i=0; i<titles.count; i++) {
        UIButton *b = TAButton(titles[i], NSSelectorFromString(actions[i]));
        b.frame = CGRectMake(i*52, 0, 50, 30); b.layer.cornerRadius = 8;
        [floatingActions addSubview:b];
    }
    floatingActions.hidden = YES; [root addSubview:floatingActions];
    UIButton *menu = TAButton(@"•••", @selector(toggleActions));
    menu.frame = CGRectMake(half - 16, bounds.size.height / 2 - 15, 32, 30);
    menu.layer.cornerRadius = 10; menu.accessibilityLabel = @"Tác vụ TAduo";
    [root addSubview:menu];
    buttonWindow.hidden = YES; splitWindow.hidden = NO;
    TALog(@"START display=%@ pane=%@", NSStringFromCGRect(bounds), NSStringFromCGRect(panes[0].bounds));
}
- (void)pick:(UIButton *)sender {
    NSInteger slot = sender.tag;
    if (!running || slots[slot] || splitWindow.rootViewController.presentedViewController) return;
    UIAlertController *picker = [UIAlertController alertControllerWithTitle:@"Chọn app đã mở" message:@"Mở app từ CarPlay trước để đưa vào danh sách." preferredStyle:UIAlertControllerStyleAlert];
    NSUInteger token = generation;
    for (NSString *bundle in [order copy]) {
        TARecord *r = records[bundle]; TARecord *other = slots[1-slot];
        if (!r || (other && (other == r || other.controller == r.controller))) continue;
        [picker addAction:[UIAlertAction actionWithTitle:bundle style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (running && token == generation) [self attach:bundle slot:slot]; });
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Hủy" style:UIAlertActionStyleCancel handler:nil]];
    [splitWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}
- (void)attach:(NSString *)bundle slot:(NSInteger)slot {
    TARecord *r = records[bundle], *other = slots[1-slot];
    if (!running || slots[slot] || !r || (other && (other == r || other.controller == r.controller))) return;
    NSString *sid = TAValue(r.controller, @"sceneID"), *otherSID = TAValue(other.controller, @"sceneID");
    if (other && ![[sid componentsSeparatedByString:@":"].firstObject isEqual:[otherSID componentsSeparatedByString:@":"].firstObject]) return;
    slots[slot] = r; r.restoreBackground = r.backgrounded;
    NSUInteger token = generation;
    BOOL previous = ownCall; ownCall = YES;
    @try {
        SEL fg = NSSelectorFromString(@"foregroundSceneWithSettings:completion:");
        if (![r.controller respondsToSelector:fg]) @throw [NSException exceptionWithName:@"MissingForegroundAPI" reason:bundle userInfo:nil];
        ((void(*)(id,SEL,id,id))objc_msgSend)(r.controller, fg, r.activation, nil);
        r.backgrounded = NO;
    } @catch (NSException *e) { TALog(@"ATTACH ERROR %@", e.name); TAStop(@"foreground failed"); ownCall = previous; return; }
    ownCall = previous; choose[slot].enabled = NO; [choose[slot] setTitle:@"Đang mở…" forState:UIControlStateNormal];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!running || token != generation || slots[slot] != r) return;
        BOOL old = ownCall; ownCall = YES;
        @try {
            TAResize(r, panes[slot].bounds.size);
            SEL create = NSSelectorFromString(@"presentationViewWithIdentifier:");
            if (![r.controller respondsToSelector:create]) @throw [NSException exceptionWithName:@"MissingPresentationAPI" reason:bundle userInfo:nil];
            r.presentationID = [NSString stringWithFormat:@"com.sushibta.taduo.%lu.%ld", (unsigned long)token, (long)slot];
            id v = ((id(*)(id,SEL,id))objc_msgSend)(r.controller, create, r.presentationID);
            if (![v isKindOfClass:UIView.class] || ((UIView *)v).superview) @throw [NSException exceptionWithName:@"NotIndependent" reason:bundle userInfo:nil];
            r.presentation = v;
            r.presentation.transform = CGAffineTransformIdentity;
            r.presentation.frame = panes[slot].bounds;
            [panes[slot] addSubview:r.presentation]; choose[slot].hidden = YES;
            TALog(@"ATTACHED slot=%ld bundle=%@", (long)slot, bundle);
        } @catch (NSException *e) { TALog(@"PRESENTATION ERROR %@", e.name); TAStop(@"presentation failed"); }
        ownCall = old;
    });
}
@end
static void TACapture(id controller, id settings) {
    if (ownCall || ![NSThread isMainThread] || !dashboard || TADashboard() != dashboard || ![settings isKindOfClass:NSDictionary.class] || !settings[@"DBActivationSettingLaunchSource"]) return;
    NSString *bundle = TABundle(controller); if (!bundle) return;
    TARecord *r = [TARecord new]; r.controller = controller; r.bundle = bundle; r.activation = [settings copy]; records[bundle] = r;
    [order removeObject:bundle]; [order addObject:bundle];
    while (order.count > 6) { [records removeObjectForKey:order.firstObject]; [order removeObjectAtIndex:0]; }
    TALog(@"CAPTURE %@ sid=%@", bundle, TAValue(controller, @"sceneID"));
}
static void TATick(void) {
    UIWindowScene *s = TADashboard();
    if (s != dashboard) {
        TAStop(@"display changed"); buttonWindow.hidden = YES; buttonWindow = nil;
        [records removeAllObjects]; [order removeAllObjects]; dashboard = s;
        TALog(@"DISPLAY %@", s.session.persistentIdentifier);
    }
    if (running && !CGRectEqualToRect(splitWindow.frame, s.coordinateSpace.bounds)) TAStop(@"display geometry changed");
    if (s && !buttonWindow) {
        buttonWindow = [[UIWindow alloc] initWithWindowScene:s]; buttonWindow.windowLevel = UIWindowLevelAlert + 80;
        buttonWindow.frame = CGRectMake(CGRectGetMaxX(s.coordinateSpace.bounds)-64, 0, 64, 30);
        buttonWindow.rootViewController = [UIViewController new];
        UIButton *b = TAButton(@"TAduo", @selector(start)); b.frame = buttonWindow.bounds; [buttonWindow.rootViewController.view addSubview:b];
    }
    buttonWindow.hidden = running || order.count < 2;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TATick(); });
}
// Darwin state channels carry only dimensions, never application content.
// The host logs receipt as an observation, not proof of correct app layout.
static NSString *TAChannel(NSString *bundle, NSString *kind) {
    return [NSString stringWithFormat:@"com.sushibta.taduo.geometry.%@.%@", bundle, kind];
}
static NSArray<NSString *> *TAClientBundles(void) {
    return @[@"com.apple.Maps", @"com.google.Maps", @"com.google.ios.youtube", @"com.google.ios.youtubemusic", @"vn.vietmap.live"];
}
// The layout experiment is enabled only for the exact scene dimensions
// currently owned by TAduo. No global narrow-screen heuristics.
static int TATargetToken(NSString *bundle) {
    static NSMutableDictionary *tokens;
    if (!tokens) tokens = [NSMutableDictionary new];
    NSNumber *existing = tokens[bundle]; if (existing) return existing.intValue;
    int token = -1;
    NSString *name = TAChannel(bundle, @"layout-target");
    if (notify_register_check(name.UTF8String, &token) != NOTIFY_STATUS_OK) return -1;
    tokens[bundle] = @(token); return token;
}
static void TASetLayoutTarget(NSString *bundle, CGSize size) {
    int token = TATargetToken(bundle); if (token < 0) return;
    uint64_t packed = ((uint64_t)llround(size.width * 4) << 32) | (uint32_t)llround(size.height * 4);
    if (notify_set_state(token, packed) == NOTIFY_STATUS_OK) notify_post(TAChannel(bundle, @"layout-target").UTF8String);
}
static BOOL TATemplateTarget(UIWindow *w, NSString **bundleOut) {
    NSString *sid = w.windowScene.session.persistentIdentifier;
    NSArray *parts = [sid componentsSeparatedByString:@":"];
    if (parts.count != 3 || ![parts[1] isEqual:@"com.apple.CarPlayTemplateUIHost"]) return NO;
    NSString *bundle = parts.lastObject; if (bundleOut) *bundleOut = bundle;
    if (![TAClientBundles() containsObject:bundle]) return NO;
    int token = TATargetToken(bundle); uint64_t packed = 0;
    if (token < 0 || notify_get_state(token, &packed) != NOTIFY_STATUS_OK || !packed) return NO;
    CGSize target = CGSizeMake((packed >> 32)/4.0, (packed & 0xffffffff)/4.0);
    CGSize actual = w.windowScene.coordinateSpace.bounds.size;
    return fabs(target.width-actual.width)<0.5 && fabs(target.height-actual.height)<0.5;
}
static void TAInvalidateTree(UIView *view, NSUInteger depth, NSUInteger *budget) {
    if (!view || !*budget || depth > 8) return; --*budget;
    [view setNeedsUpdateConstraints]; [view setNeedsLayout];
    if ([view isKindOfClass:UICollectionView.class]) [((UICollectionView *)view).collectionViewLayout invalidateLayout];
    for (UIView *child in view.subviews) TAInvalidateTree(child, depth+1, budget);
}
static void TALayoutEvidence(UIView *view, NSString *bundle, NSUInteger depth, NSUInteger *budget) {
    if (!view || !*budget || depth > 14) return; --*budget;
    TALog(@"TEMPLATE VIEW %@ depth=%lu class=%@ frame=%@ bounds=%@ safe=%@ margins=%@ constraints=%lu",
          bundle, (unsigned long)depth, NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
          NSStringFromCGRect(view.bounds), NSStringFromUIEdgeInsets(view.safeAreaInsets),
          NSStringFromUIEdgeInsets(view.layoutMargins), (unsigned long)view.constraints.count);
    if ([view isKindOfClass:UILabel.class]) {
        UILabel *label = (UILabel *)view;
        TALog(@"LABEL %@ class=%@ font=%.2f lines=%ld fit=%d minScale=%.2f intrinsic=%@ hidden=%d alpha=%.2f",
              bundle, NSStringFromClass(view.class), label.font.pointSize, (long)label.numberOfLines,
              label.adjustsFontSizeToFitWidth, label.minimumScaleFactor, NSStringFromCGSize(label.intrinsicContentSize), label.hidden, label.alpha);
    }
    for (UIView *child in view.subviews) TALayoutEvidence(child, bundle, depth+1, budget);
}
static char TAOriginalInsetsKey, TALayoutStampKey, TALayoutQueuedKey;
static void TATemplateLayout(UIWindow *w) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"]) return;
    UIViewController *root = w.rootViewController;
    if (!root.viewIfLoaded || ![NSStringFromClass(root.class) isEqual:@"CARTemplateUIApplicationSceneViewController"]) return;
    NSString *bundle = nil; BOOL active = TATemplateTarget(w, &bundle);
    NSValue *saved = objc_getAssociatedObject(root, &TAOriginalInsetsKey);
    if (!active && !saved) return;
    NSString *stamp = active ? NSStringFromCGRect(w.windowScene.coordinateSpace.bounds) : @"restore";
    if ([objc_getAssociatedObject(root, &TALayoutStampKey) isEqual:stamp] || [objc_getAssociatedObject(root, &TALayoutQueuedKey) boolValue]) return;
    objc_setAssociatedObject(root, &TALayoutQueuedKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        objc_setAssociatedObject(root, &TALayoutQueuedKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        if (w.rootViewController != root || !root.viewIfLoaded) return;
        NSString *currentBundle = nil; BOOL currentActive = TATemplateTarget(w, &currentBundle);
        NSValue *original = objc_getAssociatedObject(root, &TAOriginalInsetsKey);
        if (!currentActive && !original) return;
        UIEdgeInsets before = root.view.safeAreaInsets;
        if (currentActive) {
            if (!original) {
                original = [NSValue valueWithUIEdgeInsets:root.additionalSafeAreaInsets];
                objc_setAssociatedObject(root, &TAOriginalInsetsKey, original, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            UIEdgeInsets desired = original.UIEdgeInsetsValue;
            // Reclaim only inherited lateral display chrome at the scene root.
            // Keep top/bottom navigation regions intact. Do not patch children.
            CGFloat left = MAX(0, before.left-root.additionalSafeAreaInsets.left);
            CGFloat right = MAX(0, before.right-root.additionalSafeAreaInsets.right);
            CGFloat limit = w.bounds.size.width * 0.25;
            if (left <= limit) desired.left -= left;
            if (right <= limit) desired.right -= right;
            root.additionalSafeAreaInsets = desired;
            objc_setAssociatedObject(root, &TALayoutStampKey, NSStringFromCGRect(w.windowScene.coordinateSpace.bounds), OBJC_ASSOCIATION_COPY_NONATOMIC);
            TALog(@"TEMPLATE APPLY %@ scene=%@ safeBefore=%@ additional=%@", currentBundle,
                  NSStringFromCGRect(w.windowScene.coordinateSpace.bounds), NSStringFromUIEdgeInsets(before), NSStringFromUIEdgeInsets(desired));
        } else {
            root.additionalSafeAreaInsets = original.UIEdgeInsetsValue;
            objc_setAssociatedObject(root, &TAOriginalInsetsKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(root, &TALayoutStampKey, nil, OBJC_ASSOCIATION_COPY_NONATOMIC);
            TALog(@"TEMPLATE RESTORE %@ additional=%@", currentBundle ?: bundle, NSStringFromUIEdgeInsets(root.additionalSafeAreaInsets));
        }
        NSUInteger budget = 100; TAInvalidateTree(root.view, 0, &budget);
        [root.view layoutIfNeeded];
        if (currentActive) {
            TALog(@"TEMPLATE AFTER %@ safe=%@ traits=%ld/%ld", currentBundle, NSStringFromUIEdgeInsets(root.view.safeAreaInsets),
                  (long)root.traitCollection.horizontalSizeClass, (long)root.traitCollection.verticalSizeClass);
            NSUInteger evidence = 60; TALayoutEvidence(root.view, currentBundle, 0, &evidence);
        }
    });
}
static void TAListenTemplateTargets(void) {
    for (NSString *bundle in TAClientBundles()) {
        int token;
        notify_register_dispatch(TAChannel(bundle, @"layout-target").UTF8String, &token, dispatch_get_main_queue(), ^(__unused int delivered) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) TATemplateLayout(w);
            }
        });
    }
}
static void TASendSize(NSString *bundle, NSString *kind, CGSize size) {
    if (!isfinite(size.width) || !isfinite(size.height) || size.width <= 0 || size.height <= 0 || size.width > 16000 || size.height > 16000) return;
    static NSMutableDictionary *tokens;
    if (!tokens) tokens = [NSMutableDictionary new];
    NSString *name = TAChannel(bundle, kind); NSNumber *cached = tokens[name]; int token;
    if (!cached) {
        if (notify_register_check(name.UTF8String, &token) != NOTIFY_STATUS_OK) return;
        tokens[name] = @(token);
    } else token = cached.intValue;
    uint64_t packed = ((uint64_t)llround(size.width * 4) << 32) | (uint32_t)llround(size.height * 4);
    if (notify_set_state(token, packed) == NOTIFY_STATUS_OK) notify_post(name.UTF8String);
}
static void TAListenClients(void) {
    for (NSString *bundle in TAClientBundles()) for (NSString *kind in @[@"scene", @"window", @"root"]) {
        int token;
        uint32_t status = notify_register_dispatch(TAChannel(bundle, kind).UTF8String, &token, dispatch_get_main_queue(), ^(int delivered) {
            if (!running) return;
            TARecord *r = records[bundle];
            if (!r || (r != slots[0] && r != slots[1])) return;
            uint64_t value = 0; if (notify_get_state(delivered, &value) != NOTIFY_STATUS_OK) return;
            CGSize observed = CGSizeMake((value >> 32) / 4.0, (value & 0xffffffff) / 4.0);
            TALog(@"CLIENT %@ bundle=%@ observed=%@ target=%@ match=%d", kind, bundle,
                  NSStringFromCGSize(observed), NSStringFromCGSize(r.targetSize),
                  fabs(observed.width-r.targetSize.width) < 0.5 && fabs(observed.height-r.targetSize.height) < 0.5);
        });
        if (status != NOTIFY_STATUS_OK) TALog(@"CLIENT LISTENER FAILED %@ %@ status=%u", bundle, kind, status);
    }
}
static void TAClientObserve(UIWindow *w) {
    if (![NSThread isMainThread]) return;
    UIWindowScene *ws = w.windowScene; if (!ws) return;
    NSString *sid = ws.session.persistentIdentifier ?: @"", *role = ws.session.role ?: @"";
    if (![sid hasPrefix:@"Car["] && ![role containsString:@"CarPlay"]) return;
    NSString *bundle = NSBundle.mainBundle.bundleIdentifier;
    if ([bundle isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
        NSArray *parts = [sid componentsSeparatedByString:@":"];
        if (parts.count != 3) return; bundle = parts.lastObject;
    }
    if (![TAClientBundles() containsObject:bundle]) return;
    static char observationKey;
    UIView *root = w.rootViewController.viewIfLoaded;
    NSString *stamp = [NSString stringWithFormat:@"%@|%@|%@|%@|%@", sid, NSStringFromCGRect(ws.coordinateSpace.bounds),
                       NSStringFromCGRect(w.bounds), NSStringFromCGRect(root.bounds), NSStringFromUIEdgeInsets(root.safeAreaInsets)];
    if ([objc_getAssociatedObject(w, &observationKey) isEqual:stamp]) return;
    objc_setAssociatedObject(w, &observationKey, stamp, OBJC_ASSOCIATION_COPY_NONATOMIC);
    TASendSize(bundle, @"scene", ws.coordinateSpace.bounds.size);
    TASendSize(bundle, @"window", w.bounds.size);
    if (root) TASendSize(bundle, @"root", root.bounds.size);
}
// Capture the screen that is visible NOW, not only the initial tab list.
static void TACaptureVisible(UIWindow *w, NSString *reason) {
    NSString *bundle = nil;
    if (!TATemplateTarget(w, &bundle)) return;
    TALog(@"VISIBLE BEGIN %@ reason=%@ root=%@ scene=%@", bundle, reason,
          NSStringFromClass(w.rootViewController.class), NSStringFromCGRect(w.windowScene.coordinateSpace.bounds));
    NSUInteger budget = 180; TALayoutEvidence(w.rootViewController.viewIfLoaded, bundle, 0, &budget);
    TALog(@"VISIBLE END %@ remainingBudget=%lu", bundle, (unsigned long)budget);
}
static void TAVisibleTransition(UIViewController *vc) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"]) return;
    UIWindow *w = vc.viewIfLoaded.window;
    NSString *bundle = nil; if (!TATemplateTarget(w, &bundle)) return;
    // One native layout invalidation per appearance. No font/frame edits.
    NSUInteger budget = 100; TAInvalidateTree(vc.viewIfLoaded, 0, &budget);
    __weak UIWindow *weakWindow = w;
    __weak UIViewController *weakController = vc;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400*NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        UIWindow *window = weakWindow; UIViewController *controller = weakController;
        if (!window || !controller || controller.viewIfLoaded.window != window) return;
        static char stampKey;
        NSString *stamp = [NSString stringWithFormat:@"%@|%@", NSStringFromClass(controller.class), NSStringFromCGRect(window.bounds)];
        NSDictionary *previous = objc_getAssociatedObject(window, &stampKey);
        NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
        if ([previous[@"stamp"] isEqual:stamp] && now-[previous[@"time"] doubleValue]<2) return;
        objc_setAssociatedObject(window, &stampKey, @{@"stamp":stamp,@"time":@(now)}, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TACaptureVisible(window, [@"appeared:" stringByAppendingString:NSStringFromClass(controller.class)]);
    });
}
static void TAListenSnapshots(void) {
    int token;
    notify_register_dispatch("com.sushibta.taduo.snapshot", &token, dispatch_get_main_queue(), ^(__unused int delivered) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) TACaptureVisible(w, @"manual");
        }
    });
}
// Narrow-template adapter, enabled only in a scene currently owned by TAduo.
static UIView *TAChild(UIView *v, NSString *name) {
    for (UIView *child in v.subviews) if ([NSStringFromClass(child.class) isEqual:name]) return child;
    return nil;
}
static BOOL TANarrow(UIView *v) {
    return TATemplateTarget(v.window, NULL) && v.window.bounds.size.width < 300;
}
static void TASongLayout(UIView *v) {
    if (!TANarrow(v)) return;
    UIStackView *stack = (id)TAChild(v, @"UIStackView"); if (!stack) return;
    stack.frame = v.bounds;
    CGFloat y = 0;
    for (UIView *row in stack.arrangedSubviews) {
        if (row.hidden) continue;
        CGFloat h = [NSStringFromClass(row.class) isEqual:@"CPUITitleView"] ? 21 : 17;
        row.frame = CGRectMake(0, y, v.bounds.size.width, h); y += h;
        [row layoutIfNeeded];
    }
}
static void TANowLayout(UIView *v) {
    if (!TANarrow(v)) return;
    CGFloat w = v.bounds.size.width, top = MAX(0, v.safeAreaInsets.top);
    CGFloat bottom = v.bounds.size.height - MAX(0, v.safeAreaInsets.bottom) - 4;
    UIView *art = TAChild(v,@"CPUIShadowImageView"), *song = TAChild(v,@"CPUISongDetailsView");
    UIView *transport = TAChild(v,@"CPUITransportControlView"), *progress = TAChild(v,@"CPUIProgressView"), *mode = TAChild(v,@"CPUIPlayModeControlView");
    if (!song || !transport || !progress || !mode) return;
    CGFloat artSize = MIN(40, MAX(0, bottom-top-150));
    if (art) { art.frame=CGRectMake((w-artSize)/2,top+2,artSize,artSize); [art layoutIfNeeded]; }
    CGFloat y=top+artSize+4;
    song.frame=CGRectMake(12,y,w-24,55); [song layoutIfNeeded]; TASongLayout(song); y+=57;
    transport.frame=CGRectMake(12,y,w-24,44); [transport layoutIfNeeded]; y+=46;
    progress.frame=CGRectMake(12,y,w-24,18); [progress layoutIfNeeded]; y+=20;
    mode.frame=CGRectMake(2,y,w-4,26); [mode layoutIfNeeded];
}
static void TATabLayout(UITabBar *bar) {
    if (!TANarrow(bar)) return;
    for (UIView *button in bar.subviews) {
        if (![NSStringFromClass(button.class) isEqual:@"UITabBarButton"]) continue;
        for (UIView *child in button.subviews) if ([child isKindOfClass:UILabel.class]) {
            UILabel *label=(id)child; CGRect f=label.frame;
            f.origin.x=3; f.size.width=MAX(0,button.bounds.size.width-6); label.frame=f;

        }
    }
}
static void TAImageRows(UIView *cell) {
    if (!TANarrow(cell)) return;
    UIStackView *stack=(id)TAChild(cell,@"UIStackView"); if (!stack || stack.axis!=UILayoutConstraintAxisHorizontal) return;
    NSMutableArray *items=[NSMutableArray new];
    for (UIView *item in stack.arrangedSubviews) if (!item.hidden) [items addObject:item];
    if (!items.count) return;
    CGRect frame=stack.frame; frame.origin.x=12; frame.size.width=MAX(0,cell.bounds.size.width-24); stack.frame=frame;
    CGFloat gap=4, width=MAX(0,(frame.size.width-gap*(items.count-1))/items.count);
    for (NSUInteger i=0;i<items.count;i++) {
        UIView *item=items[i]; item.frame=CGRectMake(i*(width+gap),0,width,stack.bounds.size.height); [item layoutIfNeeded];
        for (UIView *child in item.subviews) if ([child isKindOfClass:UIImageView.class]) {
            CGFloat side=MAX(0,MIN(width-6,item.bounds.size.height-6));
            child.frame=CGRectMake((width-side)/2,(item.bounds.size.height-side)/2,side,side);

        }
    }
}

%group TAClient
%hook CPUINowPlayingView
- (void)layoutSubviews {
    %orig;
    TANowLayout((UIView *)self);
}
%end
%hook CPUISongDetailsView
- (void)layoutSubviews {
    %orig;
    TASongLayout((UIView *)self);
}
%end
%hook UITabBar
- (void)layoutSubviews {
    %orig;
    TATabLayout(self);
}
%end
%hook CPSImageRowCell
- (void)layoutSubviews {
    %orig;
    TAImageRows((UIView *)self);
}
%end

%hook UIViewController
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TAVisibleTransition(self);
}
%end
%hook UIWindow
- (void)layoutSubviews {
    %orig;
    TAClientObserve(self);
    TATemplateLayout(self);
}
%end
%end
%group TAHost
%hook DBApplicationSceneViewController
- (void)foregroundSceneWithSettings:(id)settings completion:(id)completion {
    if (!ownCall && running) TAStop(@"native app launch");
    TACapture(self, settings); %orig;
}
- (void)backgroundSceneWithCompletion:(id)completion {
    TARecord *r = records[TABundle(self) ?: @""];
    if (!ownCall && r.controller == self) { r.backgrounded = YES; if (running) TALog(@"NATIVE BACKGROUND %@", r.bundle); }
    %orig;
}
- (id)presentationViewWithIdentifier:(id)identifier {
    if (!ownCall && running && [identifier isEqual:@"kCARAppToHomeAnimationIdentifier"]) TAStop(@"native home");
    return %orig;
}
- (void)sceneManager:(id)manager didDestroyScene:(id)scene {
    NSString *bundle = TABundle(self); TARecord *r = records[bundle ?: @""];
    if (r && r.controller == self) {
        if (r == slots[0] || r == slots[1]) TAStop(@"scene destroyed");
        [records removeObjectForKey:bundle]; [order removeObject:bundle];
    }
    %orig;
}
%end
%end
%ctor {
    @autoreleasepool {
        NSString *process = NSBundle.mainBundle.bundleIdentifier;
        if ([TAClientBundles() containsObject:process] || [process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
            %init(TAClient);
            if ([process isEqual:@"com.apple.CarPlayTemplateUIHost"])
                dispatch_async(dispatch_get_main_queue(), ^{ TAListenTemplateTargets(); TAListenSnapshots(); });
            return;
        }
        if (![process isEqual:@"com.apple.CarPlayApp"]) return;
        records = [NSMutableDictionary new]; order = [NSMutableArray new]; controls = [TAControls new];
        %init(TAHost);
        dispatch_async(dispatch_get_main_queue(), ^{ TALog(@"LOADED"); for (NSString *b in TAClientBundles()) TASetLayoutTarget(b, CGSizeZero); TAListenClients(); TATick(); });
    }
}
