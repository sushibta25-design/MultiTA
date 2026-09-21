// TAduo 0.20.0: native scene-settings transaction and client geometry observations.
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
        NSData *data = [[NSString stringWithFormat:@"%@ [TAduo 0.20] %@\n", NSDate.date, s] dataUsingEncoding:NSUTF8StringEncoding];
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
@property(nonatomic) BOOL attaching;
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
static NSArray<NSString *> *resumeBundles;
static NSString *resumeCandidate;
static NSUInteger generation;
static NSUInteger slotRequests[2];
static NSMutableArray<NSArray<NSString *> *> *recentPairs;
static void TAStop(NSString *reason);
static void TAClearSlot(NSInteger slot, NSString *reason);
static BOOL TAAttachPending(void) { return slots[0].attaching || slots[1].attaching; }
static NSArray<NSString *> *TAClientBundles(void);
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
    if (r.scene != scene) { for (NSInteger i=0;i<2;i++) if (slots[i]==r) TAClearSlot(i,@"resize scene changed"); return; }
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
static NSString *TAAppName(NSString *bundle) {
    return @{@"com.apple.Maps":@"Apple Maps",@"com.google.Maps":@"Google Maps",@"vn.vietmap.live":@"Vietmap Live",@"com.google.ios.youtubemusic":@"YouTube Music",@"com.google.ios.youtube":@"YouTube",@"com.apple.Music":@"Nhạc"}[bundle] ?: bundle;
}
static void TARememberPair(void) {
    if (!slots[0].presentation || !slots[1].presentation) return;
    NSArray *pair=@[slots[0].bundle,slots[1].bundle];
    if (!recentPairs) recentPairs=[NSMutableArray new];
    [recentPairs removeObject:pair]; [recentPairs insertObject:pair atIndex:0];
    while (recentPairs.count>4) [recentPairs removeLastObject];
}
// Vector controls: minimal ivory/orange family, cyan/orange split glyph.
static UIColor *TACyan(void) { return [UIColor colorWithRed:0 green:0.83 blue:1 alpha:1]; }
static UIColor *TAOrange(void) { return [UIColor colorWithRed:1 green:0.48 blue:0.05 alpha:1]; }
static UIImage *TAGlyph(NSInteger kind) {
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(32,32), NO, 0);
    UIColor *white=[UIColor colorWithWhite:0.95 alpha:1];
    CGContextRef c=UIGraphicsGetCurrentContext();
    CGContextSetLineWidth(c,3); CGContextSetLineCap(c,kCGLineCapRound); CGContextSetLineJoin(c,kCGLineJoinRound);
    if (kind==0) {
        [TACyan() setStroke]; [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(3,6,12,20) cornerRadius:3] stroke];
        [TAOrange() setStroke]; [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(17,6,12,20) cornerRadius:3] stroke];
    } else if (kind==1) {
        [white setStroke]; CGContextMoveToPoint(c,27,10); CGContextAddLineToPoint(c,5,10); CGContextAddLineToPoint(c,11,4); CGContextMoveToPoint(c,5,10); CGContextAddLineToPoint(c,11,16); CGContextStrokePath(c);
        [TAOrange() setStroke]; CGContextMoveToPoint(c,5,23); CGContextAddLineToPoint(c,27,23); CGContextAddLineToPoint(c,21,17); CGContextMoveToPoint(c,27,23); CGContextAddLineToPoint(c,21,29); CGContextStrokePath(c);
    } else if (kind==2) {
        [white setStroke]; UIBezierPath *p=[UIBezierPath bezierPath]; p.lineWidth=3; p.lineCapStyle=kCGLineCapRound;
        [p moveToPoint:CGPointMake(8,11)]; [p addCurveToPoint:CGPointMake(9,26) controlPoint1:CGPointMake(32,-2) controlPoint2:CGPointMake(34,31)]; [p stroke];
        [TAOrange() setStroke]; CGContextMoveToPoint(c,8,4); CGContextAddLineToPoint(c,7,12); CGContextAddLineToPoint(c,15,12); CGContextStrokePath(c);
    } else {
        [white setStroke]; CGContextMoveToPoint(c,16,4); CGContextAddLineToPoint(c,5,4); CGContextAddLineToPoint(c,5,28); CGContextAddLineToPoint(c,16,28); CGContextStrokePath(c);
        [TAOrange() setStroke]; CGContextMoveToPoint(c,13,16); CGContextAddLineToPoint(c,29,16); CGContextAddLineToPoint(c,23,10); CGContextMoveToPoint(c,29,16); CGContextAddLineToPoint(c,23,22); CGContextStrokePath(c);
    }
    UIImage *image=UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext();
    return [image imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}
static UIImage *TAAppIcon(NSString *bundle) {
    static NSMutableDictionary *cache; if (!cache) cache=[NSMutableDictionary new];
    UIImage *image=cache[bundle]; if (image) return image;
    SEL sel=NSSelectorFromString(@"_applicationIconImageForBundleIdentifier:format:scale:");
    @try {
        if ([UIImage respondsToSelector:sel]) image=((id(*)(id,SEL,id,NSInteger,CGFloat))objc_msgSend)(UIImage.class,sel,bundle,2,UIScreen.mainScreen.scale);
    } @catch (__unused NSException *e) {}
    if (image) cache[bundle]=image;
    return image;
}
static NSUInteger actionVisibilitySerial;
static void TARevealActions(void) {
    if (!running || !floatingActions) return;
    floatingActions.hidden=NO;
    NSUInteger serial=++actionVisibilitySerial, token=generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        if (running && generation==token && actionVisibilitySerial==serial) floatingActions.hidden=YES;
    });
}
@interface TASplitWindow : UIWindow
@end
@implementation TASplitWindow
- (void)sendEvent:(UIEvent *)event {
    [super sendEvent:event];
    if (event.type==UIEventTypeTouches && event.allTouches.count) TARevealActions();
}
@end
@interface TAAppTile : UIButton
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic) NSInteger slot;
@property(nonatomic) NSUInteger token;
@end
@implementation TAAppTile
@end
static UIView *appPickers[2];
static UIButton *dockButton;
static __weak UIView *mountedDock;
// Original native Dock geometry, restored before each compaction. Uniform
// scaling preserves icon aspect ratio and UIKit's touch coordinate mapping.
static NSMapTable *dockGeometry;
static BOOL dockAdjusting;
static void TARestoreDock(void) {
    for (UIView *v in dockGeometry) {
        NSDictionary *saved=[dockGeometry objectForKey:v];
        CGAffineTransform applied=[saved[@"applied"] CGAffineTransformValue];
        if (CGAffineTransformEqualToTransform(v.transform,applied)) {
            v.transform=[saved[@"transform"] CGAffineTransformValue];
            if (CGPointEqualToPoint(v.center,[saved[@"appliedCenter"] CGPointValue])) v.center=[saved[@"center"] CGPointValue];
        }
    }
    [dockGeometry removeAllObjects];
}
static UIView *TAFindDock(UIView *view, NSUInteger depth) {
    if (!view || depth>14 || view.hidden || view.alpha<0.01) return nil;
    NSString *name=NSStringFromClass(view.class);
    if ([name hasPrefix:@"DB"] && [name containsString:@"Dock"] && view.bounds.size.width>=32 && view.bounds.size.width<=100 && view.bounds.size.height>=140) return view;
    for (UIView *child in view.subviews) { UIView *found=TAFindDock(child,depth+1); if (found) return found; }
    return nil;
}

static BOOL TADockButtonVisible(void) {
    if (!dockButton.window || dockButton.window.hidden || dockButton.hidden) return NO;
    CGRect visible=[dockButton convertRect:dockButton.bounds toView:dockButton.window];
    if (!CGRectIntersectsRect(visible,dockButton.window.bounds)) return NO;
    for (UIView *parent=dockButton;parent;parent=parent.superview) {
        if (parent.hidden || parent.alpha<0.01 || !parent.userInteractionEnabled) return NO;
        if (parent.clipsToBounds) {
            CGRect clip=[parent convertRect:parent.bounds toView:dockButton.window];
            visible=CGRectIntersection(visible,clip);
            if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return NO;
        }
    }
    CGPoint center=[dockButton convertPoint:CGPointMake(CGRectGetMidX(dockButton.bounds),CGRectGetMidY(dockButton.bounds)) toView:dockButton.window];
    UIView *hit=[dockButton.window hitTest:center withEvent:nil];
    return hit==dockButton || [hit isDescendantOfView:dockButton];
}
static void TADumpDockTree(UIView *view, NSUInteger depth, NSInteger *budget) {
    if (!view || depth>12 || *budget<=0) return;
    --*budget;
    NSString *name=NSStringFromClass(view.class);
    if (depth<3 || [name hasPrefix:@"DB"] || [name containsString:@"Dock"] || [name containsString:@"Sidebar"]) {
        TALog(@"DOCK TREE depth=%lu class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f interactive=%d",(unsigned long)depth,name,NSStringFromCGRect(view.frame),NSStringFromCGRect(view.bounds),view.hidden,view.alpha,view.userInteractionEnabled);
    }
    for (UIView *child in view.subviews) TADumpDockTree(child,depth+1,budget);
}
static void TADumpDock(void) {
    NSInteger budget=180;
    for (UIWindow *window in dashboard.windows) {
        if (window==splitWindow || window==buttonWindow) continue;
        TALog(@"DOCK WINDOW class=%@ level=%.1f hidden=%d",NSStringFromClass(window.class),window.windowLevel,window.hidden);
        TADumpDockTree(window,0,&budget);
    }
}

static void TAClearSlot(NSInteger slot, NSString *reason) {
    ++slotRequests[slot];
    TARecord *r=slots[slot]; r.attaching=NO; slots[slot]=nil;
    BOOL previous=ownCall; ownCall=YES; TACleanup(r); ownCall=previous;
    choose[slot].hidden=NO; choose[slot].enabled=YES;
    [choose[slot] setImage:nil forState:UIControlStateNormal];
    [choose[slot] setTitle:@"Chạm để chọn ứng dụng" forState:UIControlStateNormal];
    TALog(@"SLOT CLEAR side=%ld reason=%@",(long)slot,reason);
}
static void TAStop(NSString *reason) {
    resumeBundles=nil; resumeCandidate=nil;
    if (!running) return;
    running = NO; ++generation; ++actionVisibilitySerial;
    for (NSInteger i=0;i<2;i++) { [appPickers[i] removeFromSuperview]; appPickers[i]=nil; }
    TALog(@"STOP %@", reason);
    BOOL previous = ownCall; ownCall = YES;
    for (NSInteger i = 0; i < 2; i++) { TACleanup(slots[i]); slots[i] = nil; panes[i] = nil; choose[i] = nil; }
    ownCall = previous;
    splitWindow.hidden = YES; splitWindow = nil; floatingActions = nil;
    buttonWindow.hidden = order.count < 1;
}
// Native Home releases presentations and restores geometry, but retains the
// selected bundle IDs. Never retain old scene pointers as a resume snapshot.
static void TASuspend(NSString *reason) {
    if (!running) return;
    NSArray *selection=@[slots[0].bundle ?: @"",slots[1].bundle ?: @""];
    TAStop(reason);
    resumeBundles=selection;
    TALog(@"SESSION SAVED left=%@ right=%@",selection[0],selection[1]);
    buttonWindow.hidden=NO;
}
@interface TAControls : NSObject
- (void)start;
- (void)enter;
- (void)selectTile:(TAAppTile *)tile;
- (void)closePicker:(UIButton *)sender;
- (void)holdSwap:(UILongPressGestureRecognizer *)gesture;
- (void)holdDock:(UILongPressGestureRecognizer *)gesture;
- (void)offerNative:(NSString *)bundle;
- (void)finishAttach:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt;
- (void)fold;
- (void)changeLeft;
- (void)changeRight;
- (void)swapSides;
- (void)showPairs;
- (void)replace:(NSString *)bundle slot:(NSInteger)slot;
- (void)restoreSelection:(NSArray<NSString *> *)selection;
- (void)stop;
- (void)restartSplit;
- (void)toggleActions;
- (void)snapshot;
- (void)pick:(UIButton *)sender;
- (void)attach:(NSString *)bundle slot:(NSInteger)slot;
- (void)waitAttach:(NSString *)bundle slot:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt;
- (void)retryPane:(NSInteger)slot;
@end
static TAControls *controls;
static UIButton *TAButton(NSString *title, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal]; b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.95];
    [b addTarget:controls action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
@implementation TAControls
- (void)restoreSelection:(NSArray<NSString *> *)selection {
    if (!running || selection.count!=2) return;
    for (NSInteger i=0;i<2;i++) {
        NSString *bundle=selection[i];
        if (!bundle.length) continue;
        if (records[bundle]) [self attach:bundle slot:i];
        else TALog(@"RESUME missing slot=%ld bundle=%@",(long)i,bundle);
    }
}
- (void)enter {
    if (running) { TARevealActions(); return; }
    NSArray<NSString *> *selection=[resumeBundles copy];
    NSString *candidate=[resumeCandidate copy];
    [self start];
    if (!running) return;
    resumeBundles=nil; resumeCandidate=nil;
    if (selection.count!=2) return;
    if (!candidate.length || [selection containsObject:candidate] || !records[candidate]) {
        [self restoreSelection:selection]; return;
    }
    NSDictionary *names=@{@"com.apple.Maps":@"Apple Maps",@"com.google.Maps":@"Google Maps",@"vn.vietmap.live":@"Vietmap Live",@"com.google.ios.youtubemusic":@"YouTube Music",@"com.google.ios.youtube":@"YouTube"};
    UIAlertController *picker=[UIAlertController alertControllerWithTitle:@"Đưa app vừa mở vào đâu?" message:names[candidate] ?: @"App ở bên còn lại sẽ được giữ nguyên." preferredStyle:UIAlertControllerStyleAlert];
    NSUInteger token=generation;
    for (NSInteger side=0;side<2;side++) {
        [picker addAction:[UIAlertAction actionWithTitle:side==0 ? @"Bên trái" : @"Bên phải" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!running || generation!=token) return;
                NSMutableArray *next=[selection mutableCopy]; next[side]=candidate;
                [self restoreSelection:next];
            });
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Giữ cặp cũ" style:UIAlertActionStyleCancel handler:^(__unused UIAlertAction *action) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (running && generation==token) [self restoreSelection:selection]; });
    }]];
    [splitWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}
- (void)offerNative:(NSString *)bundle {
    if (!running || !records[bundle] || TAAttachPending() || [slots[0].bundle isEqual:bundle] || [slots[1].bundle isEqual:bundle]) return;
    if (splitWindow.rootViewController.presentedViewController) { TALog(@"NATIVE OFFER deferred to picker bundle=%@",bundle); return; }
    floatingActions.hidden=YES;
    UIAlertController *picker=[UIAlertController alertControllerWithTitle:TAAppName(bundle) message:@"Đưa app vào bên nào?" preferredStyle:UIAlertControllerStyleAlert];
    NSUInteger token=generation;
    for (NSInteger side=0;side<2;side++) {
        [picker addAction:[UIAlertAction actionWithTitle:side==0 ? @"Bên trái" : @"Bên phải" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (running && generation==token) [self replace:bundle slot:side];
            });
        }]];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Giữ nguyên" style:UIAlertActionStyleCancel handler:nil]];
    TALog(@"NATIVE OFFER bundle=%@",bundle);
    [splitWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}
- (void)fold { floatingActions.hidden=YES; TARememberPair(); TASuspend(@"fold"); }
- (void)changeLeft { [self pick:choose[0]]; }
- (void)changeRight { [self pick:choose[1]]; }
- (void)replace:(NSString *)bundle slot:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || !records[bundle]) return;
    if ([slots[slot].bundle isEqual:bundle]) { [self retryPane:slot]; return; }
    if ([slots[1-slot].bundle isEqual:bundle]) return;
    TAClearSlot(slot,@"replace"); [self attach:bundle slot:slot];
}
- (void)retryPane:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || slots[slot].attaching) return;
    NSString *bundle=[slots[slot].bundle copy]; if (!bundle.length) return;
    TALog(@"MANUAL RETRY side=%ld bundle=%@",(long)slot,bundle);
    [self snapshot];
    TAClearSlot(slot,@"manual retry"); [self attach:bundle slot:slot];
}
- (void)swapSides {
    if (!running || !slots[0].presentation || !slots[1].presentation) return;
    for (NSInteger i=0;i<2;i++) { [appPickers[i] removeFromSuperview]; appPickers[i]=nil; }
    TARecord *left=slots[0]; slots[0]=slots[1]; slots[1]=left;
    ++slotRequests[0]; ++slotRequests[1];
    for (NSInteger i=0;i<2;i++) {
        [panes[i] addSubview:slots[i].presentation]; slots[i].presentation.frame=panes[i].bounds;
    }
    floatingActions.hidden=YES; TARememberPair(); TALog(@"SWAP completed");
}
- (void)showPairs {
    if (!running || splitWindow.rootViewController.presentedViewController) return;
    floatingActions.hidden=YES;
    UIAlertController *picker=[UIAlertController alertControllerWithTitle:@"Cặp gần dùng" message:recentPairs.count ? nil : @"Ghép hai app để lưu cặp gần dùng." preferredStyle:UIAlertControllerStyleAlert];
    NSUInteger token=generation;
    for (NSArray *pair in [recentPairs copy]) {
        NSString *title=[NSString stringWithFormat:@"%@ + %@",TAAppName(pair[0]),TAAppName(pair[1])];
        UIAlertAction *action=[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (!running || generation!=token) return;
                TAClearSlot(0,@"recent pair"); TAClearSlot(1,@"recent pair"); [self restoreSelection:pair];
            });
        }];
        action.enabled=records[pair[0]]!=nil && records[pair[1]]!=nil; [picker addAction:action];
    }
    [picker addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [splitWindow.rootViewController presentViewController:picker animated:YES completion:nil];
}
- (void)stop { TARememberPair(); TAStop(@"user"); }
- (void)toggleActions { TARevealActions(); }
- (void)snapshot {
    floatingActions.hidden = YES;
    TALog(@"MANUAL SNAPSHOT REQUEST");
    TADumpDock();
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
    splitWindow = [[TASplitWindow alloc] initWithWindowScene:dashboard];
    splitWindow.frame = bounds; splitWindow.windowLevel = UIWindowLevelAlert + 70;
    splitWindow.rootViewController = [UIViewController new];
    UIView *root = splitWindow.rootViewController.view; root.backgroundColor = UIColor.blackColor;
    // Scene target equals rounded pane bounds: 3pt outer inset, 6pt gap.
    // No image scaling or independent crop of the app content.
    CGFloat half = bounds.size.width / 2;
    for (NSInteger i = 0; i < 2; i++) {
        panes[i] = [[UIView alloc] initWithFrame:CGRectMake(i * half + 3, 3, half - 6, bounds.size.height - 6)];
        panes[i].layer.cornerRadius=8; panes[i].layer.cornerCurve=kCACornerCurveContinuous;
        panes[i].clipsToBounds = YES; [root addSubview:panes[i]];
        choose[i] = TAButton(@"Chạm để chọn ứng dụng", @selector(pick:));
        choose[i].titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        choose[i].titleLabel.numberOfLines=2; choose[i].titleLabel.textAlignment=NSTextAlignmentCenter;
        choose[i].backgroundColor=[UIColor colorWithWhite:0.065 alpha:1];
        choose[i].tag = i; choose[i].frame = panes[i].bounds; [panes[i] addSubview:choose[i]];
    }

    floatingActions = [[UIView alloc] initWithFrame:CGRectMake(half-28,MAX(4,(bounds.size.height-148)/2),56,148)];
    floatingActions.backgroundColor=[UIColor colorWithWhite:0.04 alpha:1]; floatingActions.layer.cornerRadius=10;
    floatingActions.layer.borderWidth=1; floatingActions.layer.borderColor=[UIColor colorWithWhite:0.5 alpha:1].CGColor;
    NSArray *titles=@[@"Đổi trái phải",@"Thu về CarPlay",@"Thoát chia màn"];
    NSArray *actions=@[@"swapSides",@"fold",@"stop"];
    for (NSUInteger i=0;i<3;i++) {
        UIButton *b=TAButton(@"",NSSelectorFromString(actions[i]));
        b.frame=CGRectMake(2,2+i*48,52,46); b.backgroundColor=UIColor.clearColor;
        NSArray *symbols=@[@"arrow.left.arrow.right",@"arrow.uturn.backward",@"xmark"];
        UIImage *glyph=[UIImage systemImageNamed:symbols[i] withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:22 weight:UIImageSymbolWeightBold]];
        UIImageView *iv=[[UIImageView alloc] initWithImage:glyph]; iv.frame=CGRectMake(14,3,24,23); iv.contentMode=UIViewContentModeScaleAspectFit;
        iv.tintColor=i==2 ? TAOrange() : UIColor.whiteColor; [b addSubview:iv];
        UILabel *caption=[[UILabel alloc] initWithFrame:CGRectMake(0,28,52,15)]; caption.text=(@[@"Đổi",@"Thu",@"Thoát"])[i]; caption.textAlignment=NSTextAlignmentCenter; caption.font=[UIFont boldSystemFontOfSize:11]; caption.textColor=iv.tintColor; [b addSubview:caption];
        b.accessibilityLabel=titles[i];
        if (i==0) [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(holdSwap:)]];
        [floatingActions addSubview:b];
    }
    floatingActions.hidden=YES; [root addSubview:floatingActions];
    buttonWindow.hidden = YES; splitWindow.hidden = NO;
    TALog(@"START display=%@ pane=%@", NSStringFromCGRect(bounds), NSStringFromCGRect(panes[0].bounds));
}
- (void)holdDock:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan) [self snapshot];
}
- (void)holdSwap:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateBegan || !running || splitWindow.rootViewController.presentedViewController) return;
    UIAlertController *menu=[UIAlertController alertControllerWithTitle:@"Đổi ứng dụng" message:nil preferredStyle:UIAlertControllerStyleAlert];
    NSUInteger token=generation;
    for (NSInteger i=0;i<2;i++) [menu addAction:[UIAlertAction actionWithTitle:i==0 ? @"Đổi app trái" : @"Đổi app phải" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
        dispatch_async(dispatch_get_main_queue(), ^{ if (running && generation==token) [self pick:choose[i]]; });
    }]];
    for (NSInteger i=0;i<2;i++) {
        if (!slots[i].bundle) continue;
        [menu addAction:[UIAlertAction actionWithTitle:i==0 ? @"Tải lại ô trái" : @"Tải lại ô phải" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) {
            dispatch_async(dispatch_get_main_queue(), ^{ if (running && generation==token) [self retryPane:i]; });
        }]];
    }
    [menu addAction:[UIAlertAction actionWithTitle:@"Lấy log" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *a) { [self snapshot]; }]];
    [menu addAction:[UIAlertAction actionWithTitle:@"Đóng" style:UIAlertActionStyleCancel handler:nil]];
    [splitWindow.rootViewController presentViewController:menu animated:YES completion:nil];
}
- (void)closePicker:(UIButton *)sender {
    NSInteger slot=sender.tag; if (slot<0 || slot>1) return;
    [appPickers[slot] removeFromSuperview]; appPickers[slot]=nil;
}
- (void)selectTile:(TAAppTile *)tile {
    if (!running || tile.token!=generation || tile.slot<0 || tile.slot>1 || [slots[1-tile.slot].bundle isEqual:tile.bundle]) return;
    NSInteger slot=tile.slot; NSString *bundle=tile.bundle;
    [appPickers[slot] removeFromSuperview]; appPickers[slot]=nil;
    TALog(@"PICK SELECT side=%ld bundle=%@",(long)slot,bundle);
    [self replace:bundle slot:slot];
    NSInteger other=1-slot;
    if (appPickers[other]) [self pick:choose[other]];
}
- (void)pick:(UIButton *)sender {
    NSInteger slot=sender.tag;
    if (!running || slot<0 || slot>1 || splitWindow.rootViewController.presentedViewController) return;
    TALog(@"ICON PICKER side=%ld count=%lu",(long)slot,(unsigned long)order.count);
    [appPickers[slot] removeFromSuperview];
    UIView *panel=[[UIView alloc] initWithFrame:panes[slot].frame]; panel.backgroundColor=[UIColor colorWithWhite:0.055 alpha:1];
    appPickers[slot]=panel; [splitWindow.rootViewController.view insertSubview:panel belowSubview:floatingActions];
    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(10,6,panel.bounds.size.width-46,28)];
    title.text=slot==0 ? @"Ứng dụng bên trái" : @"Ứng dụng bên phải"; title.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; title.textColor=UIColor.whiteColor; [panel addSubview:title];
    UIButton *close=TAButton(@"×",@selector(closePicker:)); close.tag=slot; close.frame=CGRectMake(panel.bounds.size.width-34,4,30,30); close.accessibilityLabel=@"Đóng chọn ứng dụng"; [panel addSubview:close];
    UIScrollView *grid=[[UIScrollView alloc] initWithFrame:CGRectMake(6,38,panel.bounds.size.width-12,panel.bounds.size.height-42)]; [panel addSubview:grid];
    CGFloat width=grid.bounds.size.width/2; NSUInteger index=0;
    for (NSString *bundle in [[order copy] reverseObjectEnumerator]) {
        TARecord *r=records[bundle]; if (!r) continue;
        BOOL used=[slots[1-slot].bundle isEqual:bundle] || (slots[1-slot] && slots[1-slot].controller==r.controller);
        TAAppTile *tile=[TAAppTile buttonWithType:UIButtonTypeCustom]; tile.bundle=bundle; tile.slot=slot; tile.token=generation;
        tile.frame=CGRectMake((index%2)*width,(index/2)*80,width,76); tile.enabled=!used; tile.alpha=used ? 0.25 : 1;
        tile.accessibilityLabel=[TAAppName(bundle) stringByAppendingString:used ? @", đang dùng ở ô kia" : @""];
        UIImageView *icon=[[UIImageView alloc] initWithFrame:CGRectMake((width-44)/2,3,44,44)]; icon.image=TAAppIcon(bundle); icon.contentMode=UIViewContentModeScaleAspectFit; icon.layer.cornerRadius=10; icon.clipsToBounds=YES; [tile addSubview:icon];
        if (!icon.image) {
            icon.backgroundColor=[UIColor colorWithWhite:0.2 alpha:1];
            UILabel *fallback=[[UILabel alloc] initWithFrame:icon.bounds]; fallback.text=[[TAAppName(bundle) substringToIndex:1] uppercaseString]; fallback.font=[UIFont boldSystemFontOfSize:24]; fallback.textAlignment=NSTextAlignmentCenter; fallback.textColor=UIColor.whiteColor; [icon addSubview:fallback];
        }
        if ([slots[slot].bundle isEqual:bundle]) { icon.layer.borderWidth=2; icon.layer.borderColor=TACyan().CGColor; }
        UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(2,50,width-4,24)]; label.text=TAAppName(bundle); label.textColor=UIColor.whiteColor; label.font=[UIFont systemFontOfSize:10 weight:UIFontWeightMedium]; label.textAlignment=NSTextAlignmentCenter; label.numberOfLines=2; [tile addSubview:label];
        [tile addTarget:self action:@selector(selectTile:) forControlEvents:UIControlEventTouchUpInside]; [grid addSubview:tile]; index++;
    }
    grid.contentSize=CGSizeMake(grid.bounds.size.width,((index+1)/2)*80);
    if (!index) {
        UILabel *empty=[[UILabel alloc] initWithFrame:grid.bounds]; empty.text=@"Mở ứng dụng trên CarPlay một lần, rồi quay lại chọn."; empty.textColor=UIColor.lightGrayColor; empty.font=[UIFont systemFontOfSize:13]; empty.numberOfLines=0; empty.textAlignment=NSTextAlignmentCenter; [grid addSubview:empty];
    }
}
- (void)attach:(NSString *)bundle slot:(NSInteger)slot {
    TARecord *r = records[bundle], *other = slots[1-slot];
    if (!running || slots[slot] || !r || (other && (other == r || other.controller == r.controller))) return;
    if (other.attaching) {
        NSUInteger request=++slotRequests[slot];
        choose[slot].enabled=NO; [choose[slot] setTitle:@"Đang chuẩn bị…" forState:UIControlStateNormal];
        TALog(@"ATTACH QUEUED side=%ld bundle=%@",(long)slot,bundle);
        [self waitAttach:bundle slot:slot generation:generation request:request attempt:0]; return;
    }
    NSString *sid = TAValue(r.controller, @"sceneID"), *otherSID = TAValue(other.controller, @"sceneID");
    if (other && ![[sid componentsSeparatedByString:@":"].firstObject isEqual:[otherSID componentsSeparatedByString:@":"].firstObject]) return;
    slots[slot] = r; r.restoreBackground = r.backgrounded; r.attaching=YES;
    NSUInteger token = generation, request=++slotRequests[slot];
    TALog(@"ATTACH BEGIN side=%ld bundle=%@",(long)slot,bundle);
    BOOL previous = ownCall; ownCall = YES;
    @try {
        SEL fg = NSSelectorFromString(@"foregroundSceneWithSettings:completion:");
        if (![r.controller respondsToSelector:fg]) @throw [NSException exceptionWithName:@"MissingForegroundAPI" reason:bundle userInfo:nil];
        ((void(*)(id,SEL,id,id))objc_msgSend)(r.controller, fg, r.activation, nil);
        r.backgrounded = NO;
    } @catch (NSException *e) { TALog(@"ATTACH ERROR %@", e.name); TAClearSlot(slot,@"foreground failed"); ownCall = previous; return; }
    ownCall = previous;
    UIImage *icon=TAAppIcon(bundle);
    if (icon) { UIGraphicsBeginImageContextWithOptions(CGSizeMake(36,36),NO,0); [icon drawInRect:CGRectMake(0,0,36,36)]; UIImage *small=UIGraphicsGetImageFromCurrentImageContext(); UIGraphicsEndImageContext(); [choose[slot] setImage:[small imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal] forState:UIControlStateNormal]; }
    choose[slot].enabled = NO; [choose[slot] setTitle:@"Đang mở…" forState:UIControlStateNormal];
    [self finishAttach:slot generation:token request:request attempt:0];
}
- (void)waitAttach:(NSString *)bundle slot:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt {
    if (!running || generation!=token || slotRequests[slot]!=request || slots[slot]) return;
    if (!slots[1-slot].attaching) {
        choose[slot].enabled=YES;
        [choose[slot] setTitle:@"Chạm để chọn ứng dụng" forState:UIControlStateNormal];
        [self attach:bundle slot:slot]; return;
    }
    if (attempt>=24) { TAClearSlot(slot,@"activation queue timeout"); return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self waitAttach:bundle slot:slot generation:token request:request attempt:attempt+1];
    });
}
- (void)finishAttach:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt {
    if (!running || generation!=token || slotRequests[slot]!=request || !slots[slot].attaching) return;
    TARecord *r=slots[slot];
    CGRect frame=CGRectZero;
    BOOL ready=TAReadFrame(TAValue(r.controller,@"scene"),&frame);
    // Give native activation time to settle; re-read the current controller
    // every time. Foreground is requested once, never polled/replayed.
    if (attempt<2 || !ready) {
        if (attempt>=16) { TALog(@"ATTACH TIMEOUT side=%ld bundle=%@",(long)slot,r.bundle); TAClearSlot(slot,@"scene timeout"); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
            [self finishAttach:slot generation:token request:request attempt:attempt+1];
        });
        return;
    }
    BOOL old=ownCall; ownCall=YES;
    @try {
        TAResize(r,panes[slot].bounds.size);
        if (!running || slots[slot]!=r || !r.frameCaptured) @throw [NSException exceptionWithName:@"SceneNotReady" reason:r.bundle userInfo:nil];
        SEL create=NSSelectorFromString(@"presentationViewWithIdentifier:");
        if (![r.controller respondsToSelector:create]) @throw [NSException exceptionWithName:@"MissingPresentationAPI" reason:r.bundle userInfo:nil];
        r.presentationID=[NSString stringWithFormat:@"com.sushibta.taduo.%lu.%ld.%lu",(unsigned long)token,(long)slot,(unsigned long)request];
        id v=((id(*)(id,SEL,id))objc_msgSend)(r.controller,create,r.presentationID);
        if (![v isKindOfClass:UIView.class] || ((UIView *)v).superview) @throw [NSException exceptionWithName:@"NotIndependent" reason:r.bundle userInfo:nil];
        r.presentation=v; r.presentation.transform=CGAffineTransformIdentity; r.presentation.frame=panes[slot].bounds;
        [panes[slot] addSubview:r.presentation]; choose[slot].hidden=YES; r.attaching=NO;
        TALog(@"ATTACHED slot=%ld bundle=%@ attempt=%lu",(long)slot,r.bundle,(unsigned long)attempt); TARememberPair();
    } @catch (NSException *e) {
        TALog(@"PRESENTATION ERROR %@ bundle=%@",e.name,r.bundle);
        if (running && slots[slot]==r) TAClearSlot(slot,@"presentation failed");
    } @finally { ownCall=old; }

}
@end
static void TAInstallDock(UIView *dock) {
    if (dockAdjusting || !dock || dock.bounds.size.height<140) return;
    dockAdjusting=YES;
    if (!dockGeometry) dockGeometry=[NSMapTable weakToStrongObjectsMapTable];
    TARestoreDock();
    if (mountedDock!=dock) { [dockButton removeFromSuperview]; mountedDock=dock; TALog(@"DOCK mounted class=%@ bounds=%@",NSStringFromClass(dock.class),NSStringFromCGRect(dock.bounds)); }
    if (!dockButton) {
        dockButton=TAButton(@"",@selector(enter)); [dockButton setImage:TAGlyph(0) forState:UIControlStateNormal];
        dockButton.backgroundColor=UIColor.clearColor; dockButton.accessibilityLabel=@"TAduo — Chia màn hình";
        [dockButton addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:controls action:@selector(holdDock:)]];
    }
    CGFloat height=dock.bounds.size.height, width=dock.bounds.size.width;
    CGFloat factor=(height-38)/height;
    for (UIView *child in dock.subviews) {
        if (child==dockButton || child.hidden || !child.userInteractionEnabled) continue;
        CGAffineTransform original=child.transform; CGPoint center=child.center;
        CGAffineTransform applied=CGAffineTransformScale(original,factor,factor);
        CGPoint compressed=CGPointMake(width/2+(center.x-width/2)*factor,center.y*factor);
        [dockGeometry setObject:@{@"transform":[NSValue valueWithCGAffineTransform:original],@"center":[NSValue valueWithCGPoint:center],@"applied":[NSValue valueWithCGAffineTransform:applied],@"appliedCenter":[NSValue valueWithCGPoint:compressed]} forKey:child];
        child.transform=applied; child.center=compressed;
    }
    dockButton.frame=CGRectMake((width-36)/2,height-37,36,36); [dock addSubview:dockButton]; dockButton.hidden=NO;
    dockAdjusting=NO;
}
static void TACapture(id controller, id settings) {
    if (ownCall || !NSThread.isMainThread || !dashboard || TADashboard()!=dashboard) return;
    NSString *bundle=TABundle(controller);
    if (!bundle || ![settings isKindOfClass:NSDictionary.class]) return;
    NSString *sid=TAValue(controller,@"sceneID");
    NSString *display=[sid componentsSeparatedByString:@":"].firstObject;
    if (![dashboard.session.persistentIdentifier hasSuffix:display]) return;
    BOOL launch=settings[@"DBActivationSettingLaunchSource"]!=nil;
    // Some navigation foreground callbacks omit launch-source. Preserve their
    // actual activation dictionary rather than inventing one.
    if (!launch && ![TAClientBundles() containsObject:bundle]) return;
    TARecord *r=records[bundle];
    for (NSInteger i=0;i<2;i++) {
        TARecord *pending=slots[i];
        if (running && pending.attaching && [pending.bundle isEqual:bundle]) {
            if (pending.controller!=controller) {
                TALog(@"ATTACH REBIND side=%ld bundle=%@",(long)i,bundle);
                pending.controller=controller;
            }
            if (launch || !pending.activation) pending.activation=[settings copy];
            records[bundle]=pending; return;
        }
    }
    if (running && (slots[0].controller==controller || slots[1].controller==controller)) {
        if (launch && r.controller==controller) r.activation=[settings copy];
        return;
    }
    if (!r || r.controller!=controller) {
        r=[TARecord new]; r.controller=controller; r.bundle=bundle;
    }
    if (launch || !r.activation) r.activation=[settings copy]; records[bundle]=r;
    [order removeObject:bundle]; [order addObject:bundle];
    // Keep resumable/active apps pinned when trimming recently seen apps.
    while (order.count>24) {
        NSString *victim=nil;
        for (NSString *entry in order) {
            if ([resumeBundles containsObject:entry] || [resumeCandidate isEqual:entry] || [slots[0].bundle isEqual:entry] || [slots[1].bundle isEqual:entry] || [entry isEqual:bundle]) continue;
            victim=entry; break;
        }
        if (!victim) break;
        [records removeObjectForKey:victim]; [order removeObject:victim];
    }
    if (resumeBundles && (launch || [TAClientBundles() containsObject:bundle])) resumeCandidate=bundle;
    TALog(@"CAPTURE %@ sid=%@ launchSource=%d",bundle,sid,launch);
    if (!running) buttonWindow.hidden=NO;
}
static void TATick(void) {
    UIWindowScene *s = TADashboard();
    if (s != dashboard) {
        TAStop(@"display changed"); buttonWindow.hidden = YES; buttonWindow = nil;
        TARestoreDock(); [dockButton removeFromSuperview]; mountedDock=nil;
        [records removeAllObjects]; [order removeAllObjects]; dashboard = s;
        TALog(@"DISPLAY %@", s.session.persistentIdentifier);
    }
    if (running && !CGRectEqualToRect(splitWindow.frame, s.coordinateSpace.bounds)) TAStop(@"display geometry changed");
    UIView *dock=nil;
    for (UIWindow *window in s.windows) {
        if (window==splitWindow || window==buttonWindow) continue;
        dock=TAFindDock(window,0); if (dock) break;
    }
    if (dock) TAInstallDock(dock);
    if (s && !buttonWindow) {
        buttonWindow=[[UIWindow alloc] initWithWindowScene:s];
        buttonWindow.windowLevel=UIWindowLevelAlert+80;
        buttonWindow.rootViewController=[UIViewController new];
        buttonWindow.rootViewController.view.backgroundColor=UIColor.clearColor;
        UIButton *button=TAButton(@"",@selector(enter));
        button.tag=1818; [button setImage:TAGlyph(0) forState:UIControlStateNormal];
        button.layer.cornerRadius=10; button.accessibilityLabel=@"TAduo 0.20 — Chia màn hình";
        [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:controls action:@selector(holdDock:)]];
        [buttonWindow.rootViewController.view addSubview:button];
    }
    if (s) {
        CGRect bounds=s.coordinateSpace.bounds;
        buttonWindow.frame=CGRectMake(CGRectGetMaxX(bounds)-42,CGRectGetMinY(bounds)+4,38,38);
        [buttonWindow.rootViewController.view viewWithTag:1818].frame=buttonWindow.bounds;
        BOOL fallback=!running && !TADockButtonVisible();
        buttonWindow.hidden=!fallback;
        static __weak UIWindowScene *lastScene;
        static BOOL lastFallback;
        static NSUInteger attempts;
        if (lastScene!=s) { lastScene=s; attempts=0; }
        if (lastFallback!=fallback || attempts==0) TALog(@"LAUNCHER fallback=%d dockVisible=%d running=%d",fallback,TADockButtonVisible(),running);
        lastFallback=fallback;
        if (!running && (attempts==0 || attempts==3)) TADumpDock();
        if (attempts<4) attempts++;
    }
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
// Change only native tab item titles. UIKit still owns all button geometry.
static NSHashTable<UITabBar *> *TACompactTabBars;
static char TATabTitleKey, TATabBusyKey;
static NSString *TAFitTabTitle(NSString *title, CGFloat width) {
    NSDictionary *attributes=@{NSFontAttributeName:[UIFont systemFontOfSize:11 weight:UIFontWeightSemibold]};
    if ([title sizeWithAttributes:attributes].width<=width) return title;
    NSString *prefix=title;
    while (prefix.length) {
        NSRange last=[prefix rangeOfComposedCharacterSequenceAtIndex:prefix.length-1];
        prefix=[prefix substringToIndex:last.location];
        NSString *candidate=[prefix stringByAppendingString:@"…"];
        if ([candidate sizeWithAttributes:attributes].width<=width) return candidate;
    }
    return @"…";
}
static void TACompactTabs(UITabBar *bar) {
    if ([objc_getAssociatedObject(bar,&TATabBusyKey) boolValue]) return;
    NSString *bundle=nil;
    BOOL active=TATemplateTarget(bar.window,&bundle) && [bundle isEqual:@"com.google.ios.youtubemusic"] && bar.bounds.size.width>0 && bar.bounds.size.width<300;
    if (!active && ![TACompactTabBars containsObject:bar]) return;
    objc_setAssociatedObject(bar,&TATabBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        if (!TACompactTabBars) TACompactTabBars=[NSHashTable weakObjectsHashTable];
        if (active) [TACompactTabBars addObject:bar];
        CGFloat width=MAX(12,bar.bounds.size.width/MAX((NSUInteger)1,bar.items.count)-10);
        NSUInteger changed=0;
        for (UITabBarItem *item in bar.items) {
            NSDictionary *saved=objc_getAssociatedObject(item,&TATabTitleKey);
            // An application title update supersedes our saved value.
            if (saved && ![item.title isEqual:saved[@"applied"]]) {
                if ([item.accessibilityLabel isEqual:saved[@"original"]]) item.accessibilityLabel=saved[@"accessibility"]==NSNull.null ? nil : saved[@"accessibility"];
                saved=nil; objc_setAssociatedObject(item,&TATabTitleKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            NSString *original=saved ? saved[@"original"] : item.title;
            if (!original) continue;
            NSString *desired=active ? TAFitTabTitle(original,width) : original;
            if (![desired isEqual:original]) {
                id accessibility=saved ? saved[@"accessibility"] : (item.accessibilityLabel ?: (id)NSNull.null);
                objc_setAssociatedObject(item,&TATabTitleKey,@{@"original":original,@"applied":desired,@"accessibility":accessibility},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!item.accessibilityLabel) item.accessibilityLabel=original;
            } else if (saved) {
                if ([item.accessibilityLabel isEqual:original]) item.accessibilityLabel=saved[@"accessibility"]==NSNull.null ? nil : saved[@"accessibility"];
                objc_setAssociatedObject(item,&TATabTitleKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (![item.title isEqual:desired]) { item.title=desired; ++changed; }
        }
        if (!active) [TACompactTabBars removeObject:bar];
        if (changed) TALog(@"TAB TITLES active=%d count=%lu changed=%lu width=%.2f",active,(unsigned long)bar.items.count,(unsigned long)changed,width);
    } @finally {
        objc_setAssociatedObject(bar,&TATabBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
}
// Device evidence: four fixed 61pt square buttons in a 135pt image row.
// Adjust only the verified matching width/height constants; keep native layout.
static NSHashTable<UIView *> *TAImageRows;
static char TARowConstantsKey, TARowBusyKey, TARowStampKey;
static void TARestoreImageRow(UIView *cell) {
    NSMapTable *saved=objc_getAssociatedObject(cell,&TARowConstantsKey);
    for (NSLayoutConstraint *c in saved.keyEnumerator) {
        NSDictionary *entry=[saved objectForKey:c];
        if (fabs(c.constant-[entry[@"applied"] doubleValue])<0.01) c.constant=[entry[@"original"] doubleValue];
    }
    if (saved.count) TALog(@"IMAGE ROW restore count=%lu",(unsigned long)saved.count);
    objc_setAssociatedObject(cell,&TARowConstantsKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(cell,&TARowStampKey,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);
    [TAImageRows removeObject:cell];
}
static void TACompactImageRow(UIView *cell) {
    if ([objc_getAssociatedObject(cell,&TARowBusyKey) boolValue]) return;
    NSString *bundle=nil;
    BOOL active=TATemplateTarget(cell.window,&bundle) && [bundle isEqual:@"com.google.ios.youtubemusic"] && cell.bounds.size.width>48 && cell.bounds.size.width<300;
    if (!active) { TARestoreImageRow(cell); return; }
    objc_setAssociatedObject(cell,&TARowBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        NSMapTable *saved=objc_getAssociatedObject(cell,&TARowConstantsKey);
        for (UIView *child in cell.subviews) {
            if (![child isKindOfClass:UIStackView.class]) continue;
            UIStackView *stack=(UIStackView *)child;
            NSArray<UIView *> *buttons=stack.arrangedSubviews;
            if (stack.axis!=UILayoutConstraintAxisHorizontal || stack.distribution!=UIStackViewDistributionEqualSpacing || buttons.count<2 || buttons.count>8) continue;
            // The observed native row has 12pt margins. Wait until its own
            // width constraint has caught up with the resized cell.
            CGFloat available=cell.bounds.size.width-24;
            BOOL rowWidthReady=NO;
            for (NSLayoutConstraint *c in stack.constraints) {
                if (c.active && c.firstItem==stack && !c.secondItem && c.firstAttribute==NSLayoutAttributeWidth && c.relation==NSLayoutRelationEqual && fabs(c.constant-available)<1) rowWidthReady=YES;
            }
            if (!rowWidthReady) continue;
            NSMutableArray<NSLayoutConstraint *> *dimensions=[NSMutableArray new];
            BOOL valid=YES;
            for (UIView *button in buttons) {
                if (![NSStringFromClass(button.class) isEqual:@"CPUIHighlightButton"]) { valid=NO; break; }
                NSLayoutConstraint *width=nil,*height=nil;
                for (NSLayoutConstraint *c in button.constraints) {
                    NSDictionary *entry=[saved objectForKey:c];
                    CGFloat original=entry ? [entry[@"original"] doubleValue] : c.constant;
                    if (!c.active || c.firstItem!=button || c.secondItem || c.relation!=NSLayoutRelationEqual || fabs(original-61)>0.01 || c.priority!=UILayoutPriorityRequired) continue;
                    if (c.firstAttribute==NSLayoutAttributeWidth) width=c;
                    if (c.firstAttribute==NSLayoutAttributeHeight) height=c;
                }
                if (!width || !height) { valid=NO; break; }
                [dimensions addObject:width]; [dimensions addObject:height];
            }
            if (!valid) continue;
            CGFloat side=MIN(61,floor((available-6*(buttons.count-1))/buttons.count));
            if (side<20) continue;
            NSString *stamp=[NSString stringWithFormat:@"%.2f/%lu/%.2f/%p/%p",available,(unsigned long)buttons.count,side,(__bridge void *)dimensions.firstObject,(__bridge void *)dimensions.lastObject];
            // At most one attempt per geometry/constraint set. If native code
            // resets a constant, do not fight it on every layout pass.
            if ([objc_getAssociatedObject(cell,&TARowStampKey) isEqual:stamp]) continue;
            if (!saved) {
                saved=[NSMapTable weakToStrongObjectsMapTable];
                objc_setAssociatedObject(cell,&TARowConstantsKey,saved,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            for (NSLayoutConstraint *c in dimensions) {
                NSDictionary *entry=[saved objectForKey:c];
                // Preserve a new value supplied by the system between passes.
                CGFloat original=entry && fabs(c.constant-[entry[@"applied"] doubleValue])<0.01 ? [entry[@"original"] doubleValue] : c.constant;
                [saved setObject:@{@"original":@(original),@"applied":@(side)} forKey:c];
                if (fabs(c.constant-side)>0.01) c.constant=side;
            }
            if (!TAImageRows) TAImageRows=[NSHashTable weakObjectsHashTable];
            [TAImageRows addObject:cell];
            if (![objc_getAssociatedObject(cell,&TARowStampKey) isEqual:stamp]) {
                objc_setAssociatedObject(cell,&TARowStampKey,stamp,OBJC_ASSOCIATION_COPY_NONATOMIC);
                TALog(@"IMAGE ROW apply available=%.2f count=%lu side=%.2f constants=%lu",available,(unsigned long)buttons.count,side,(unsigned long)dimensions.count);
            }
        }
    } @finally { objc_setAssociatedObject(cell,&TARowBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
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
            for (UITabBar *bar in TACompactTabBars.allObjects) TACompactTabs(bar);
            for (UIView *cell in TAImageRows.allObjects) TACompactImageRow(cell);
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
    if ([view isKindOfClass:UIStackView.class]) {
        UIStackView *stack=(UIStackView *)view;
        TALog(@"STACK CONFIG parent=%@ axis=%ld distribution=%ld alignment=%ld spacing=%.2f arranged=%lu",NSStringFromClass(view.superview.class),(long)stack.axis,(long)stack.distribution,(long)stack.alignment,stack.spacing,(unsigned long)stack.arrangedSubviews.count);
    }
    BOOL imageRow=[name isEqual:@"CPSImageRowCell"];
    if ([name isEqual:@"CPUINowPlayingView"] || imageRow) {
        unsigned int count=0; Method *methods=class_copyMethodList(view.class,&count); NSUInteger remaining=60;
        for (unsigned int i=0;i<count && remaining;i++) {
            NSString *selector=NSStringFromSelector(method_getName(methods[i])); NSString *lower=selector.lowercaseString;
            if (imageRow || [lower containsString:@"layout"] || [lower containsString:@"constraint"] || [lower containsString:@"artwork"] || [lower containsString:@"size"] || [lower containsString:@"style"]) {
                TALog(@"LAYOUT METHOD class=%@ selector=%@ encoding=%s",name,selector,method_getTypeEncoding(methods[i])); --remaining;
            }
        }
        free(methods);
    }
    for (UIView *child in view.subviews) TAConstraintEvidence(child,depth+1,views,constraints);
}

// Read-only Google Maps controller/layout evidence: root geometry is correct
// but a nested map viewport retains a 45pt leading offset on this device.
static void TAMapControllerEvidence(UIViewController *vc, NSUInteger depth, NSUInteger *budget) {
    if (!vc || depth>10 || !*budget) return; --*budget;
    TALog(@"MAP CONTROLLER class=%@ frame=%@ safe=%@ additional=%@",NSStringFromClass(vc.class),NSStringFromCGRect(vc.viewIfLoaded.frame),NSStringFromUIEdgeInsets(vc.viewIfLoaded.safeAreaInsets),NSStringFromUIEdgeInsets(vc.additionalSafeAreaInsets));
    if ([NSStringFromClass(vc.class) hasPrefix:@"CPS"]) {
        unsigned int count=0; Method *methods=class_copyMethodList(vc.class,&count); NSUInteger limit=35;
        for (unsigned int i=0;i<count && limit;i++) {
            NSString *name=NSStringFromSelector(method_getName(methods[i])); NSString *lower=name.lowercaseString;
            if ([lower containsString:@"layout"] || [lower containsString:@"safe"] || [lower containsString:@"inset"] || [lower containsString:@"map"] || [lower containsString:@"size"]) {
                TALog(@"MAP METHOD class=%@ selector=%@ encoding=%s",NSStringFromClass(vc.class),name,method_getTypeEncoding(methods[i])); --limit;
            }
        }
        free(methods);
    }
    for (UIViewController *child in vc.childViewControllers) TAMapControllerEvidence(child,depth+1,budget);
}
static void TAMapViewportEvidence(UIView *view, NSUInteger depth, NSUInteger *budget) {
    if (!view || depth>12 || !*budget) return; --*budget;
    BOOL mapOwner=NO;
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) isEqual:@"UIStackView"]) {
            for (UIView *button in child.subviews) if ([NSStringFromClass(button.class) isEqual:@"CPSMapButton"]) mapOwner=YES;
        }
    }
    if (mapOwner) {
        TALog(@"MAP VIEWPORT owner=%@ frame=%@ safe=%@",TAItemDescription(view),NSStringFromCGRect(view.frame),NSStringFromUIEdgeInsets(view.safeAreaInsets));
        for (UIView *child in view.subviews) TALog(@"MAP CHILD item=%@ frame=%@",TAItemDescription(child),NSStringFromCGRect(child.frame));
        NSUInteger limit=60;
        for (NSLayoutConstraint *c in view.constraints) {
            if (!limit--) break;
            TALog(@"MAP CONSTRAINT first=%@ attr=%ld relation=%ld second=%@ attr=%ld constant=%.2f priority=%.0f active=%d",TAItemDescription(c.firstItem),(long)c.firstAttribute,(long)c.relation,TAItemDescription(c.secondItem),(long)c.secondAttribute,c.constant,c.priority,c.active);
        }
    }
    for (UIView *child in view.subviews) TAMapViewportEvidence(child,depth+1,budget);
}
// Capture both native and split geometry for comparison.
static void TACaptureVisible(UIWindow *w, NSString *reason) {
    NSString *bundle = TADiagnosticBundle(w);
    if (!bundle) return;
    TALog(@"COMPARE mode=%@ window=%@ screen=%@ scale=%.2f traits=%ld/%ld", TATemplateTarget(w,NULL) ? @"split" : @"native",NSStringFromCGRect(w.bounds),NSStringFromCGRect(w.screen.bounds),w.screen.scale,(long)w.traitCollection.horizontalSizeClass,(long)w.traitCollection.verticalSizeClass);
    TALog(@"VISIBLE BEGIN %@ reason=%@ root=%@ scene=%@", bundle, reason,
          NSStringFromClass(w.rootViewController.class), NSStringFromCGRect(w.windowScene.coordinateSpace.bounds));
    NSUInteger budget = 180; TALayoutEvidence(w.rootViewController.viewIfLoaded, bundle, 0, &budget);
    if ([bundle isEqual:@"com.google.Maps"]) {
        NSUInteger controllers=24, viewports=120;
        TAMapControllerEvidence(w.rootViewController,0,&controllers);
        TAMapViewportEvidence(w.rootViewController.viewIfLoaded,0,&viewports);
    }
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

%group TAImageRowExperiment
%hook CPSImageRowCell
- (void)layoutSubviews {
    %orig;
    TACompactImageRow((UIView *)self);
}
- (void)prepareForReuse {
    TARestoreImageRow((UIView *)self);
    %orig;
}
%end
%end

%group TACompactHome
%hook UITabBar
- (void)layoutSubviews {
    TACompactTabs(self);
    %orig;
}
- (void)didMoveToWindow {
    %orig;
    TACompactTabs(self);
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
%hook UIView
- (void)layoutSubviews {
    %orig;
    if (self==mountedDock && !dockAdjusting) TAInstallDock(self);
}
%end
%hook DBApplicationSceneViewController
- (void)foregroundSceneWithSettings:(id)settings completion:(id)completion {
    BOOL external=!ownCall;
    TALog(@"FOREGROUND controller=%p sid=%@ running=%d own=%d pending=%d",self,TAValue(self,@"sceneID"),running,ownCall,TAAttachPending());
    NSString *bundle=TABundle(self);
    BOOL current=slots[0].controller==self || slots[1].controller==self || [slots[0].bundle isEqual:bundle] || [slots[1].bundle isEqual:bundle];
    BOOL launch=[settings isKindOfClass:NSDictionary.class] && settings[@"DBActivationSettingLaunchSource"]!=nil;
    if (external && running && !TAAttachPending() && !current && bundle && [settings isKindOfClass:NSDictionary.class] && (launch || [TAClientBundles() containsObject:bundle])) TALog(@"NATIVE LAUNCH retain split bundle=%@",bundle);
    if (external) TACapture(self,settings);
    %orig;
    // Retry once after native foreground has established its scene ID. No
    // fabricated callback or repeated foreground requests.
    if (external && [settings isKindOfClass:NSDictionary.class]) {
        __weak id controller=self;
        NSDictionary *activation=[settings copy];
        NSUInteger token=generation;
        dispatch_async(dispatch_get_main_queue(), ^{
            id strongController=controller;
            if (!strongController || generation!=token) return;
            NSString *lateBundle=TABundle(strongController);
            BOOL occupied=slots[0].controller==strongController || slots[1].controller==strongController || [slots[0].bundle isEqual:lateBundle] || [slots[1].bundle isEqual:lateBundle];
            if (running && !TAAttachPending() && !occupied && lateBundle && (activation[@"DBActivationSettingLaunchSource"] || [TAClientBundles() containsObject:lateBundle])) TALog(@"NATIVE LAUNCH settled retain split bundle=%@",lateBundle);
            TACapture(strongController,activation);
            if (running && lateBundle && activation[@"DBActivationSettingLaunchSource"]) [controls offerNative:lateBundle];
        });
    }
}
- (void)backgroundSceneWithCompletion:(id)completion {
    TARecord *r = records[TABundle(self) ?: @""];
    if (!ownCall && r.controller == self) { r.backgrounded = YES; if (running) TALog(@"NATIVE BACKGROUND %@", r.bundle); }
    %orig;
}
- (id)presentationViewWithIdentifier:(id)identifier {
    if (!ownCall && running && [identifier isEqual:@"kCARAppToHomeAnimationIdentifier"]) {
        if (TAAttachPending()) TALog(@"HOME TRANSITION during attach (session retained)");
        else TALog(@"HOME TRANSITION retain split bundle=%@",TABundle(self));
    }
    return %orig;
}
- (void)sceneManager:(id)manager didDestroyScene:(id)scene {
    NSString *bundle = TABundle(self); TARecord *r = records[bundle ?: @""];
    id currentScene=TAValue(self,@"scene");
    TALog(@"SCENE DESTROY bundle=%@ controller=%p destroyed=%p current=%p attached=%p running=%d own=%d",bundle,self,scene,currentScene,r.scene,running,ownCall);
    if (r && r.controller == self && scene) {
        // A late destruction notification for an old scene must not evict a
        // newer scene on the same controller. Keep activation data for retry.
        BOOL attachedDestroyed=r.scene==scene;
        BOOL pendingDestroyed=r.attaching && (!currentScene || currentScene==scene);
        if (attachedDestroyed || pendingDestroyed) {
            r.changed=NO; r.restoreBackground=NO;
            if (r == slots[0]) TAClearSlot(0,@"current scene destroyed");
            if (r == slots[1]) TAClearSlot(1,@"current scene destroyed");
        }
        TALog(@"SCENE RECORD retained bundle=%@ affected=%d",bundle,attachedDestroyed || pendingDestroyed);
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
                %init(TACompactHome);
                if (NSClassFromString(@"CPSImageRowCell")) {
                    %init(TAImageRowExperiment);
                }
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
