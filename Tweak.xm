// TAduo 0.10.1: native scene-settings transaction and client geometry observations.
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
        NSData *data = [[NSString stringWithFormat:@"%@ [TAduo 0.10] %@\n", NSDate.date, s] dataUsingEncoding:NSUTF8StringEncoding];
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
static UIImage *TAChoiceIcon(NSString *bundle) {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary new];
    UIImage *image = cache[bundle];
    if (!image) {
        @try {
            SEL selector = NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
            if ([UIImage respondsToSelector:selector])
                image = ((id(*)(id,SEL,id,NSInteger,CGFloat))objc_msgSend)(UIImage.class, selector, bundle, 2, UIScreen.mainScreen.scale);
        } @catch (__unused NSException *e) {}
        if (image) cache[bundle] = image;
    }
    return image ?: [UIImage systemImageNamed:@"app"];
}
@interface TAControls : NSObject
@property(nonatomic, strong) UIViewController *iconPicker;
@property(nonatomic, copy) NSArray<NSString *> *iconBundles;
@property(nonatomic) NSInteger iconSlot;
@property(nonatomic) NSUInteger iconPage;
@property(nonatomic) NSUInteger iconToken;
- (void)renderIcons;
- (void)closeIcons;
- (void)selectIcon:(UIButton *)sender;
- (void)iconPage:(UIButton *)sender;
- (void)swapSides;
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
- (void)stop { [self closeIcons]; TAStop(@"user"); }
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
    floatingActions = [[UIView alloc] initWithFrame:CGRectMake(half - 78, bounds.size.height / 2 - 83, 156, 64)];
    floatingActions.backgroundColor = UIColor.clearColor;
    NSArray *titles = @[@"Chia", @"Log", @"Thoát"];
    NSArray *actions = @[@"restartSplit", @"snapshot", @"stop"];
    for (NSUInteger i=0; i<titles.count; i++) {
        UIButton *b = TAButton(titles[i], NSSelectorFromString(actions[i]));
        b.frame = CGRectMake(i*52, 34, 50, 30); b.layer.cornerRadius = 8;
        [floatingActions addSubview:b];
    }
    UIButton *swap = TAButton(@"", @selector(swapSides));
    [swap setImage:[UIImage systemImageNamed:@"arrow.left.arrow.right"] forState:UIControlStateNormal];
    swap.frame = CGRectMake(52, 0, 50, 30); swap.layer.cornerRadius = 8;
    swap.accessibilityLabel = @"Đổi vị trí hai ứng dụng";
    [floatingActions addSubview:swap];
    floatingActions.hidden = YES; [root addSubview:floatingActions];
    UIButton *menu = TAButton(@"•••", @selector(toggleActions));
    menu.frame = CGRectMake(half - 16, bounds.size.height / 2 - 15, 32, 30);
    menu.layer.cornerRadius = 10; menu.accessibilityLabel = @"Tác vụ TAduo";
    [root addSubview:menu];
    buttonWindow.hidden = YES; splitWindow.hidden = NO;
    TALog(@"START display=%@ pane=%@", NSStringFromCGRect(bounds), NSStringFromCGRect(panes[0].bounds));
}
- (void)swapSides {
    if (!running || !slots[0].presentation || !slots[1].presentation || splitWindow.rootViewController.presentedViewController) return;
    TARecord *left = slots[0]; slots[0] = slots[1]; slots[1] = left;
    for (NSInteger i = 0; i < 2; i++) {
        [panes[i] addSubview:slots[i].presentation];
        slots[i].presentation.frame = panes[i].bounds;
    }
    TALog(@"SWAP left=%@ right=%@", slots[0].bundle, slots[1].bundle);
}
- (void)closeIcons {
    UIViewController *picker = self.iconPicker;
    self.iconPicker = nil; self.iconBundles = nil;
    [picker dismissViewControllerAnimated:NO completion:nil];
}
- (void)selectIcon:(UIButton *)sender {
    if (!running || generation != self.iconToken || sender.tag < 0 || (NSUInteger)sender.tag >= self.iconBundles.count) return;
    NSString *bundle = self.iconBundles[sender.tag];
    NSInteger slot = self.iconSlot; NSUInteger token = self.iconToken;
    UIViewController *picker = self.iconPicker;
    self.iconPicker = nil; self.iconBundles = nil;
    [picker dismissViewControllerAnimated:NO completion:^{
        if (running && generation == token) [self attach:bundle slot:slot];
    }];
}
- (void)iconPage:(UIButton *)sender {
    NSInteger page = (NSInteger)self.iconPage + sender.tag;
    if (page < 0 || (NSUInteger)page >= (self.iconBundles.count + 5) / 6) return;
    self.iconPage = page; [self renderIcons];
}
- (void)renderIcons {
    UIView *root = self.iconPicker.view;
    for (UIView *v in [root.subviews copy]) [v removeFromSuperview];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectInset(splitWindow.bounds, 12, 12)];
    panel.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.98];
    panel.layer.cornerRadius = 14; [root addSubview:panel];
    CGFloat w = panel.bounds.size.width, h = panel.bounds.size.height;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, w-24, 25)];
    title.text = @"Chọn app đã mở"; title.font = [UIFont boldSystemFontOfSize:14];
    title.textColor = UIColor.whiteColor; title.textAlignment = NSTextAlignmentCenter; [panel addSubview:title];
    CGFloat cellW = (w-24)/3, cellH = (h-68)/2;
    NSUInteger first = self.iconPage * 6, end = MIN(first+6, self.iconBundles.count);
    for (NSUInteger i = first; i < end; i++) {
        NSUInteger position = i-first;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(12+(position%3)*cellW, 32+(position/3)*cellH, cellW, cellH);
        button.tag = i; button.accessibilityLabel = self.iconBundles[i];
        CGFloat size = MIN(32, cellH-8);
        UIImageView *icon = [[UIImageView alloc] initWithImage:TAChoiceIcon(self.iconBundles[i])];
        icon.frame = CGRectMake((cellW-size)/2, (cellH-size)/2, size, size);
        icon.contentMode = UIViewContentModeScaleAspectFit; icon.tintColor = UIColor.whiteColor;
        icon.layer.cornerRadius = 7; icon.clipsToBounds = YES;
        [button addSubview:icon]; [button addTarget:self action:@selector(selectIcon:) forControlEvents:UIControlEventTouchUpInside];
        [panel addSubview:button];
    }
    UIButton *cancel = TAButton(@"Hủy", @selector(closeIcons));
    cancel.frame = CGRectMake(w/2-35, h-33, 70, 30); [panel addSubview:cancel];
    if (self.iconBundles.count > 6) {
        UIButton *previous = TAButton(@"‹", @selector(iconPage:)); previous.tag = -1;
        previous.frame = CGRectMake(12, h-33, 44, 30); previous.enabled = self.iconPage > 0; [panel addSubview:previous];
        UIButton *next = TAButton(@"›", @selector(iconPage:)); next.tag = 1;
        next.frame = CGRectMake(w-56, h-33, 44, 30); next.enabled = end < self.iconBundles.count; [panel addSubview:next];
    }
    if (!self.iconBundles.count) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 40, w-24, h-80)];
        empty.text = @"Mở app từ CarPlay trước để đưa vào danh sách.";
        empty.numberOfLines = 0; empty.textAlignment = NSTextAlignmentCenter; empty.textColor = UIColor.whiteColor;
        [panel addSubview:empty];
    }
}
- (void)pick:(UIButton *)sender {
    NSInteger slot = sender.tag;
    if (!running || slot < 0 || slot > 1 || slots[slot] || splitWindow.rootViewController.presentedViewController) return;
    NSMutableArray *bundles = [NSMutableArray new];
    for (NSString *bundle in [order copy]) {
        TARecord *r = records[bundle], *other = slots[1-slot];
        if (!r || (other && (other == r || other.controller == r.controller))) continue;
        [bundles addObject:bundle];
    }
    self.iconBundles = bundles; self.iconSlot = slot; self.iconPage = 0; self.iconToken = generation;
    UIViewController *picker = [UIViewController new]; self.iconPicker = picker;
    picker.modalPresentationStyle = UIModalPresentationOverFullScreen;
    picker.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self renderIcons];
    [splitWindow.rootViewController presentViewController:picker animated:NO completion:nil];
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
        buttonWindow.frame = CGRectMake(CGRectGetMaxX(s.coordinateSpace.bounds)-88, 0, 88, 30);
        buttonWindow.rootViewController = [UIViewController new];
        UIButton *b = TAButton(@"TAduo 0.10", @selector(start)); b.frame = buttonWindow.bounds; [buttonWindow.rootViewController.view addSubview:b];
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
static void TACaptureVisible(UIWindow *w, NSString *reason);
static void TAListenTemplateTargets(void) {
    for (NSString *bundle in TAClientBundles()) {
        int token;
        notify_register_dispatch(TAChannel(bundle, @"layout-target").UTF8String, &token, dispatch_get_main_queue(), ^(__unused int delivered) {
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    TATemplateLayout(w);
                    if (![w.windowScene.session.persistentIdentifier hasSuffix:[@":" stringByAppendingString:bundle]]) continue;
                    __weak UIWindow *weakWindow=w;
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
                        UIWindow *window=weakWindow; if (window) TACaptureVisible(window,@"target-settled");
                    });
                }
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
// Read-only comparison: include native CarPlay windows, without active targets.
static NSString *TADiagnosticBundle(UIWindow *w) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"] || w.hidden) return nil;
    NSArray *parts=[w.windowScene.session.persistentIdentifier componentsSeparatedByString:@":"];
    if (parts.count!=3 || ![parts[1] isEqual:@"com.apple.CarPlayTemplateUIHost"]) return nil;
    return [TAClientBundles() containsObject:parts.lastObject] ? parts.lastObject : nil;
}
static NSString *TAItemDescription(id item) {
    if (!item) return @"none";
    return [NSString stringWithFormat:@"%@: %p",NSStringFromClass([item class]),(__bridge void *)item];
}
static void TAConstraintEvidence(UIView *view, NSUInteger depth, NSUInteger *views, NSUInteger *constraints) {
    if (!view || !*views || depth>14) return; --*views;
    NSString *name=NSStringFromClass(view.class);
    BOOL focus=[name hasPrefix:@"CPUI"] || [name isEqual:@"UIStackView"] || [name hasPrefix:@"UITabBar"] || [name isEqual:@"CPSImageRowCell"];
    if (focus) {
        TALog(@"LAYOUT NODE %@ parent=%@ frame=%@ ambiguous=%d mask=%d compression=%.0f/%.0f hugging=%.0f/%.0f",TAItemDescription(view),TAItemDescription(view.superview),NSStringFromCGRect(view.frame),view.hasAmbiguousLayout,view.translatesAutoresizingMaskIntoConstraints,
              [view contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisHorizontal],[view contentCompressionResistancePriorityForAxis:UILayoutConstraintAxisVertical],
              [view contentHuggingPriorityForAxis:UILayoutConstraintAxisHorizontal],[view contentHuggingPriorityForAxis:UILayoutConstraintAxisVertical]);
        for (NSLayoutConstraint *c in view.constraints) {
            if (!*constraints) break; --*constraints;
            TALog(@"CONSTRAINT owner=%@ first=%@ attr=%ld relation=%ld second=%@ attr=%ld multiplier=%.3f constant=%.3f priority=%.0f active=%d",TAItemDescription(view),TAItemDescription(c.firstItem),(long)c.firstAttribute,(long)c.relation,TAItemDescription(c.secondItem),(long)c.secondAttribute,c.multiplier,c.constant,c.priority,c.active);
        }
    }
    if ([name isEqual:@"CPUINowPlayingView"]) {
        unsigned int count=0; Method *methods=class_copyMethodList(view.class,&count); NSUInteger remaining=40;
        for (unsigned int i=0;i<count && remaining;i++) {
            NSString *selector=NSStringFromSelector(method_getName(methods[i])); NSString *lower=selector.lowercaseString;
            if ([lower containsString:@"layout"] || [lower containsString:@"constraint"] || [lower containsString:@"artwork"] || [lower containsString:@"size"] || [lower containsString:@"style"]) {
                TALog(@"LAYOUT METHOD class=%@ selector=%@ encoding=%s",name,selector,method_getTypeEncoding(methods[i])); --remaining;
            }
        }
        free(methods);
    }
    for (UIView *child in view.subviews) TAConstraintEvidence(child,depth+1,views,constraints);
}

// Capture both native and split geometry for comparison.
static void TACaptureVisible(UIWindow *w, NSString *reason) {
    NSString *bundle = TADiagnosticBundle(w);
    if (!bundle) return;
    TALog(@"COMPARE mode=%@ window=%@ screen=%@ scale=%.2f traits=%ld/%ld", TATemplateTarget(w,NULL) ? @"split" : @"native",NSStringFromCGRect(w.bounds),NSStringFromCGRect(w.screen.bounds),w.screen.scale,(long)w.traitCollection.horizontalSizeClass,(long)w.traitCollection.verticalSizeClass);
    TALog(@"VISIBLE BEGIN %@ reason=%@ root=%@ scene=%@", bundle, reason,
          NSStringFromClass(w.rootViewController.class), NSStringFromCGRect(w.windowScene.coordinateSpace.bounds));
    NSUInteger budget = 180; TALayoutEvidence(w.rootViewController.viewIfLoaded, bundle, 0, &budget);
    NSUInteger nodes=180, constraints=200; TAConstraintEvidence(w.rootViewController.viewIfLoaded,0,&nodes,&constraints);
    TALog(@"VISIBLE END %@ remainingBudget=%lu constraintBudget=%lu", bundle, (unsigned long)budget,(unsigned long)constraints);
}
static void TAVisibleTransition(UIViewController *vc) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"]) return;
    UIWindow *w = vc.viewIfLoaded.window;
    NSString *bundle = TADiagnosticBundle(w); if (!bundle) return;
    BOOL active=TATemplateTarget(w,NULL);
    if (!active && ![NSStringFromClass(vc.class) isEqual:@"CPSNowPlayingViewController"]) return;
    // One native layout invalidation per appearance. No font/frame edits.
    NSUInteger budget = 100; if (active) TAInvalidateTree(vc.viewIfLoaded, 0, &budget);
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
// One controlled input to the system's own layout selection. No frame edits.
%group TANowPlayingExperiment
%hook CPUINowPlayingView
- (void)recalculateLayout:(BOOL)recalculate allowsAlbumArt:(BOOL)allowsAlbumArt hasDataSource:(BOOL)hasDataSource viewArea:(CGRect)viewArea safeArea:(CGRect)safeArea rightHandDrive:(BOOL)rightHandDrive {
    UIView *view=(UIView *)self;
    BOOL narrow=TATemplateTarget(view.window,NULL) && viewArea.size.width>0 && viewArea.size.width<300;
    BOOL effectiveArt=narrow ? NO : allowsAlbumArt;
    %orig(recalculate,effectiveArt,hasDataSource,viewArea,safeArea,rightHandDrive);
    static char stampKey;
    NSString *stamp=[NSString stringWithFormat:@"%d/%d/%d/%@/%@",narrow,allowsAlbumArt,effectiveArt,NSStringFromCGRect(viewArea),NSStringFromCGRect(safeArea)];
    if (![objc_getAssociatedObject(self,&stampKey) isEqual:stamp]) {
        objc_setAssociatedObject(self,&stampKey,stamp,OBJC_ASSOCIATION_COPY_NONATOMIC);
        id height=TAValue(self,@"songDetailsViewHeightConstraint");
        CGFloat minimum=[height isKindOfClass:NSLayoutConstraint.class] ? ((NSLayoutConstraint *)height).constant : -1;
        TALog(@"NATIVE LAYOUT narrow=%d artRequested=%d artEffective=%d recalculate=%d datasource=%d area=%@ safe=%@ songMinimum=%.2f layoutClass=%@",narrow,allowsAlbumArt,effectiveArt,recalculate,hasDataSource,NSStringFromCGRect(viewArea),NSStringFromCGRect(safeArea),minimum,NSStringFromClass([TAValue(self,@"nowPlayingLayout") class]));
    }
}
%end
%end

%group TAClient
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
            if ([process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
                Class cls=NSClassFromString(@"CPUINowPlayingView");
                SEL selector=NSSelectorFromString(@"recalculateLayout:allowsAlbumArt:hasDataSource:viewArea:safeArea:rightHandDrive:");
                Method method=class_getInstanceMethod(cls,selector);
                const char *encoding=method ? method_getTypeEncoding(method) : NULL;
                if (encoding && strcmp(encoding,"v96@0:8B16B20B24{CGRect={CGPoint=dd}{CGSize=dd}}28{CGRect={CGPoint=dd}{CGSize=dd}}60B92")==0) {
                    %init(TANowPlayingExperiment);
                    TALog(@"NATIVE LAYOUT HOOK enabled");
                } else TALog(@"NATIVE LAYOUT HOOK skipped encoding=%s",encoding ?: "missing");
                dispatch_async(dispatch_get_main_queue(), ^{ TAListenTemplateTargets(); TAListenSnapshots(); });
            }
            return;
        }
        if (![process isEqual:@"com.apple.CarPlayApp"]) return;
        records = [NSMutableDictionary new]; order = [NSMutableArray new]; controls = [TAControls new];
        %init(TAHost);
        dispatch_async(dispatch_get_main_queue(), ^{ TALog(@"LOADED"); for (NSString *b in TAClientBundles()) TASetLayoutTarget(b, CGSizeZero); TAListenClients(); TATick(); });
    }
}
