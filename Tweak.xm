// TAduo 0.1.0: fixed panes, observed CarPlay scenes, one geometry transaction.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import <string.h>

static void TALog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    @synchronized (NSFileManager.defaultManager) {
        NSString *path = @"/var/mobile/TAduo.log";
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attrs fileSize] > 1024 * 1024) {
            [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
            [NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
        }
        NSData *data = [[NSString stringWithFormat:@"%@ [TAduo 0.1] %@\n", NSDate.date, s] dataUsingEncoding:NSUTF8StringEncoding];
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
static __weak UIWindowScene *dashboard;
static BOOL running, ownCall;
static NSUInteger generation;
static void TAStop(NSString *reason);
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
static NSString *TAUpdater(id scene) {
    for (NSString *name in @[@"updateUISettingsWithBlock:", @"updateSettingsWithBlock:"]) {
        NSMethodSignature *sig = [scene methodSignatureForSelector:NSSelectorFromString(name)];
        if (sig && sig.numberOfArguments == 3 && !strcmp(sig.methodReturnType, @encode(void)) && !strcmp([sig getArgumentTypeAtIndex:2], "@?")) return name;
    }
    return nil;
}
static void TAResize(TARecord *r, CGSize size) {
    r.scene = TAValue(r.controller, @"scene");
    r.updater = TAUpdater(r.scene);
    CGRect original = CGRectZero;
    if (!r.updater || !TAReadFrame(r.scene, &original)) { TALog(@"RESIZE UNSUPPORTED %@", r.bundle); return; }
    r.originalFrame = original;
    NSUInteger token = generation;
    void (^change)(id) = ^(id settings) {
        if (!running || generation != token) return;
        @try {
            r.changed = TASetFrame(settings, (CGRect){CGPointZero, size});
            TALog(@"RESIZE REQUEST %@ size=%@ setter=%d path=%@", r.bundle, NSStringFromCGSize(size), r.changed, r.updater);
        } @catch (NSException *e) { TALog(@"RESIZE ERROR %@ %@", r.bundle, e.name); }
    };
    @try { ((void(*)(id,SEL,id))objc_msgSend)(r.scene, NSSelectorFromString(r.updater), change); }
    @catch (NSException *e) { TALog(@"TRANSACTION ERROR %@", e.name); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (!running || generation != token) return;
        CGRect actual = CGRectZero; BOOL readable = TAReadFrame(r.scene, &actual);
        TALog(@"RESIZE OBSERVED %@ requested=%@ scene=%@ readable=%d host=%@ (client redraw still needs visual verification)", r.bundle, NSStringFromCGSize(size), NSStringFromCGRect(actual), readable, NSStringFromCGRect(r.presentation.bounds));
    });
}
static void TACleanup(TARecord *r) {
    if (!r) return;
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
    r.presentationID = nil; r.scene = nil; r.changed = NO;
}
static void TAStop(NSString *reason) {
    if (!running) return;
    running = NO; ++generation;
    TALog(@"STOP %@", reason);
    BOOL previous = ownCall; ownCall = YES;
    for (NSInteger i = 0; i < 2; i++) { TACleanup(slots[i]); slots[i] = nil; panes[i] = nil; choose[i] = nil; }
    ownCall = previous;
    splitWindow.hidden = YES; splitWindow = nil;
    buttonWindow.hidden = order.count < 2;
}
@interface TAControls : NSObject
- (void)start;
- (void)stop;
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
- (void)start {
    if (running || !dashboard || TADashboard() != dashboard) return;
    CGRect bounds = dashboard.coordinateSpace.bounds;
    if (bounds.size.width < 150 || bounds.size.height < 100) return;
    running = YES; ++generation;
    splitWindow = [[UIWindow alloc] initWithWindowScene:dashboard];
    splitWindow.frame = bounds; splitWindow.windowLevel = UIWindowLevelAlert + 70;
    splitWindow.rootViewController = [UIViewController new];
    UIView *root = splitWindow.rootViewController.view; root.backgroundColor = UIColor.blackColor;
    // Reserve a real toolbar above BOTH scenes; do not cover any app controls.
    CGFloat toolbar = 32, half = bounds.size.width / 2;
    for (NSInteger i = 0; i < 2; i++) {
        panes[i] = [[UIView alloc] initWithFrame:CGRectMake(i * half, toolbar, half, bounds.size.height - toolbar)];
        panes[i].clipsToBounds = YES; [root addSubview:panes[i]];
        choose[i] = TAButton(i == 0 ? @"Chọn app trái" : @"Chọn app phải", @selector(pick:));
        choose[i].tag = i; choose[i].frame = panes[i].bounds; [panes[i] addSubview:choose[i]];
    }
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(8, 0, half, toolbar)];
    label.text = @"TAduo 0.1 · 50/50"; label.textColor = UIColor.whiteColor; label.font = [UIFont systemFontOfSize:12]; [root addSubview:label];
    UIButton *exit = TAButton(@"Thoát", @selector(stop)); exit.frame = CGRectMake(bounds.size.width - 64, 0, 64, toolbar); [root addSubview:exit];
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
            SEL create = NSSelectorFromString(@"presentationViewWithIdentifier:");
            if (![r.controller respondsToSelector:create]) @throw [NSException exceptionWithName:@"MissingPresentationAPI" reason:bundle userInfo:nil];
            r.presentationID = [NSString stringWithFormat:@"com.sushibta.taduo.%lu.%ld", (unsigned long)token, (long)slot];
            id v = ((id(*)(id,SEL,id))objc_msgSend)(r.controller, create, r.presentationID);
            if (![v isKindOfClass:UIView.class] || ((UIView *)v).superview) @throw [NSException exceptionWithName:@"NotIndependent" reason:bundle userInfo:nil];
            r.presentation = v;
            r.presentation.transform = CGAffineTransformIdentity;
            r.presentation.frame = panes[slot].bounds;
            [panes[slot] addSubview:r.presentation]; choose[slot].hidden = YES;
            TAResize(r, panes[slot].bounds.size);
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
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayApp"]) return;
        records = [NSMutableDictionary new]; order = [NSMutableArray new]; controls = [TAControls new];
        %init(TAHost);
        dispatch_async(dispatch_get_main_queue(), ^{ TALog(@"LOADED"); TATick(); });
    }
}
