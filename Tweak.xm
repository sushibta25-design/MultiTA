// MultiTA 0.10.26: shared keyboard with an always-visible number row.
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
        NSString *path = [NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"] ? @"/var/mobile/MultiTA-template.log" : @"/var/mobile/MultiTA.log";
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        if ([attrs fileSize] > 1024 * 1024) {
            [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
            [NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
        }
        NSData *data = [[NSString stringWithFormat:@"%@ [MultiTA 0.10.26] %@\n", NSDate.date, s] dataUsingEncoding:NSUTF8StringEncoding];
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
@property(nonatomic) BOOL attaching;
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
static UIButton *sideActions[2];
static void TAHideSideActions(void) {
    for (NSInteger i=0;i<2;i++) sideActions[i].hidden=YES;
}
static UIView *dividerView;
static UIView *splitShortcut;
static UILabel *dividerFeedback;
static UIView *dividerHighlight;
static UIButton *entryControl;
static BOOL entryExpanded=NO, entryDragging=NO, entryLeft=NO;
static CGFloat entryYRatio=0.5;
static void TALayoutEntry(void);
static UIControl *gapTouchShield;
static const CGFloat TADividerGap=4;
static const CGFloat TADividerHitWidth=18;
static const CGFloat TADividerHitHeight=84;
static CGFloat splitRatio=0.5, dragStartRatio=0.5;
static NSString *resumeBundles[2];
static CGFloat resumeRatio=0.5;
static BOOL dividerDragging=NO;
static UIColor *TAGlassColor(CGFloat alpha) { return [UIColor colorWithRed:0.035 green:0.055 blue:0.085 alpha:alpha]; }
static UIColor *TACyan(void) { return [UIColor colorWithRed:0.12 green:0.83 blue:1 alpha:1]; }
static UIColor *TAOrange(void) { return [UIColor colorWithRed:1 green:0.48 blue:0.14 alpha:1]; }
static void TAStyleGlass(UIView *view, CGFloat radius, UIColor *accent) {
    view.backgroundColor=TAGlassColor(0.72);
    view.layer.cornerRadius=radius;
    if (@available(iOS 13.0,*)) view.layer.cornerCurve=kCACornerCurveContinuous;
    view.layer.borderWidth=0.75;
    view.layer.borderColor=(accent ?: [UIColor colorWithWhite:1 alpha:0.20]).CGColor;
    view.clipsToBounds=YES;
}
static void TADividerFeedback(BOOL active) {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        dividerFeedback.alpha=active ? 1 : 0;
        dividerFeedback.transform=active ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.88,0.88);
        dividerHighlight.alpha=active ? 1 : 0;
        splitShortcut.alpha=active ? 0.7 : 1;
        splitShortcut.transform=active ? CGAffineTransformMakeScale(0.92,0.92) : CGAffineTransformIdentity;
    } completion:nil];
}
static CGPoint entryDragStart;
static __weak UIWindowScene *dashboard;
static BOOL running, ownCall;
static NSUInteger generation;
static NSUInteger slotRequests[2];
static void TAKBHostStop(void);
static BOOL TAYoutubeClientReady(CGSize target);
@interface TASplitWindow : UIWindow
@end
@implementation TASplitWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    // Modal picker and visible menu keep their normal priority.
    if (self.rootViewController.presentedViewController) return [super hitTest:point withEvent:event];
    if (splitShortcut && !splitShortcut.hidden && [splitShortcut pointInside:[splitShortcut convertPoint:point fromView:self] withEvent:event])
        return [splitShortcut hitTest:[splitShortcut convertPoint:point fromView:self] withEvent:event];
    for (NSInteger i=0;i<2;i++) {
        UIButton *b=sideActions[i];
        if (b && !b.hidden && [b pointInside:[b convertPoint:point fromView:self] withEvent:event])
            return [b hitTest:[b convertPoint:point fromView:self] withEvent:event];
    }
    if (floatingActions && !floatingActions.hidden &&
        [floatingActions pointInside:[floatingActions convertPoint:point fromView:self] withEvent:event])
        return [super hitTest:point withEvent:event];
    if (dividerView && !dividerView.hidden &&
        [dividerView pointInside:[dividerView convertPoint:point fromView:self] withEvent:event])
        return [dividerView hitTest:[dividerView convertPoint:point fromView:self] withEvent:event];
    if (gapTouchShield && !gapTouchShield.hidden &&
        [gapTouchShield pointInside:[gapTouchShield convertPoint:point fromView:self] withEvent:event])
        return gapTouchShield;
    return [super hitTest:point withEvent:event];
}
@end
static void TAStop(NSString *reason);
static void TAClearSlot(NSInteger slot, NSString *reason);
static NSArray<NSString *> *TAClientBundles(void);
static BOOL TAAttachPending(void) { return slots[0].attaching || slots[1].attaching; }
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
static void TAClearSlot(NSInteger slot, NSString *reason) {
    TAKBHostStop();
    ++slotRequests[slot];
    TARecord *r=slots[slot]; r.attaching=NO; slots[slot]=nil;
    BOOL previous=ownCall; ownCall=YES; TACleanup(r); ownCall=previous;
    choose[slot].hidden=NO; choose[slot].enabled=YES;
    [choose[slot] setTitle:slot==0 ? @"Chọn app trái" : @"Chọn app phải" forState:UIControlStateNormal];
    TALog(@"SLOT CLEAR side=%ld reason=%@",(long)slot,reason);
}
static void TAStop(NSString *reason) {
    if (!running) return;
    // Remember identities, never retain hosted views or stale scene pointers.
    for (NSInteger i=0;i<2;i++) resumeBundles[i]=[slots[i].bundle copy];
    resumeRatio=splitRatio;
    TAKBHostStop();
    running = NO; ++generation;
    TALog(@"STOP %@", reason);
    BOOL previous = ownCall; ownCall = YES;
    for (NSInteger i = 0; i < 2; i++) { TACleanup(slots[i]); slots[i] = nil; panes[i] = nil; choose[i] = nil; sideActions[i]=nil; }
    ownCall = previous;
    splitWindow.hidden = YES; splitWindow = nil; floatingActions = nil; dividerView=nil; gapTouchShield=nil; dividerDragging=NO;
    splitShortcut=nil; dividerFeedback=nil; dividerHighlight=nil;
    entryExpanded=NO; TALayoutEntry();
    buttonWindow.hidden = !dashboard;
}
static BOOL TAHasHostedSurface(CALayer *layer, NSUInteger depth, NSInteger *budget) {
    if (!layer || depth>14 || --*budget<0) return NO;
    if ([NSStringFromClass(layer.class) containsString:@"LayerHost"]) {
        id context=TAValue(layer,@"contextId");
        if ([context respondsToSelector:@selector(unsignedLongLongValue)] && [context unsignedLongLongValue]!=0) return YES;
    }
    for (CALayer *child in layer.sublayers) if (TAHasHostedSurface(child,depth+1,budget)) return YES;
    return NO;
}
static BOOL TAMapBundle(NSString *bundle) {
    return [@[@"com.google.Maps",@"vn.vietmap.live",@"com.apple.Maps"] containsObject:bundle];
}
static void TAPresentationEvidence(TARecord *r, NSString *phase) {
    if (!r) return;
    NSInteger budget=240;
    TALog(@"PRESENTATION %@ bundle=%@ controller=%p scene=%p current=%p view=%@ parent=%@ window=%d hidden=%d alpha=%.2f surface=%d",phase,r.bundle,r.controller,r.scene,TAValue(r.controller,@"scene"),NSStringFromClass(r.presentation.class),NSStringFromClass(r.presentation.superview.class),r.presentation.window!=nil,r.presentation.hidden,r.presentation.alpha,TAHasHostedSurface(r.presentation.layer,0,&budget));
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
@interface TAControls : NSObject <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UIViewController *iconPicker;
@property(nonatomic, copy) NSArray<NSString *> *iconBundles;
@property(nonatomic) NSInteger iconSlot;
@property(nonatomic) NSUInteger iconPage;
@property(nonatomic) NSUInteger iconToken;
- (void)replace:(NSString *)bundle slot:(NSInteger)slot;
- (void)finishAttach:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt;
- (void)checkPresentation:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt;
- (void)settleYouTube:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt stable:(NSUInteger)stable;
- (void)dragDivider:(UIPanGestureRecognizer *)gesture;
- (void)pressDivider:(UILongPressGestureRecognizer *)gesture;
- (void)layoutSplit:(BOOL)commit;
- (void)dragEntry:(UIPanGestureRecognizer *)gesture;
- (void)showChrome;
- (void)hideChrome;
- (void)touchActivity:(UIEvent *)event;
- (void)enter;
- (void)renderIcons;
- (void)closeIcons;
- (void)selectIcon:(UIButton *)sender;
- (void)iconPage:(UIButton *)sender;
- (void)swapSides;
- (void)start;
- (void)resumeSlot:(NSInteger)slot token:(NSUInteger)token attempt:(NSUInteger)attempt;
- (void)stop;
- (void)restartSplit;
- (void)changeSide:(UIButton *)sender;
- (void)toggleActions;
- (void)pick:(UIButton *)sender;
- (void)attach:(NSString *)bundle slot:(NSInteger)slot;
@end
static TAControls *controls;
static UIButton *TAButton(NSString *title, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal]; b.tintColor = UIColor.whiteColor;
    TAStyleGlass(b,12,nil);
    [b addTarget:controls action:action forControlEvents:UIControlEventTouchUpInside]; return b;
}
static UIImage *TASplitIcon(void) {
    static UIImage *icon;
    if (!icon) {
        UIGraphicsBeginImageContextWithOptions(CGSizeMake(30,24),NO,0);
        [[UIColor colorWithRed:0 green:0.88 blue:1 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(1,2,12,20) cornerRadius:2] fill];
        [[UIColor colorWithRed:1 green:0.43 blue:0.10 alpha:1] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(17,2,12,20) cornerRadius:2] fill];
        icon=[UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
        UIGraphicsEndImageContext();
    }
    return icon;
}
static void TALayoutEntry(void) {
    if (!buttonWindow || !dashboard || entryDragging) return;
    CGRect screen=dashboard.coordinateSpace.bounds;
    CGFloat width=entryExpanded ? 52 : 18, height=44;
    CGFloat x=entryLeft ? CGRectGetMinX(screen) : CGRectGetMaxX(screen)-width;
    CGFloat y=CGRectGetMinY(screen)+MAX(0,screen.size.height-height)*entryYRatio;
    buttonWindow.frame=CGRectMake(x,y,width,height);
    entryControl.frame=buttonWindow.bounds;
    TAStyleGlass(entryControl,entryExpanded ? 15 : 8,entryExpanded ? [UIColor colorWithWhite:1 alpha:0.24] : [UIColor colorWithWhite:1 alpha:0.14]);
    entryControl.backgroundColor=TAGlassColor(entryExpanded ? 0.78 : 0.46);
    [entryControl setImage:entryExpanded ? TASplitIcon() : nil forState:UIControlStateNormal];
    [entryControl setTitle:entryExpanded ? @"" : (entryLeft ? @"›" : @"‹") forState:UIControlStateNormal];
    entryControl.accessibilityLabel=entryExpanded ? @"MultiTA: mở chia màn" : @"Mở phím tắt MultiTA";
}
static UIImage *TAActionIcon(BOOL exitAction) {
    static UIImage *swapIcon, *exitIcon;
    UIImage *cached=exitAction ? exitIcon : swapIcon;
    if (cached) return cached;
    UIGraphicsBeginImageContextWithOptions(CGSizeMake(30,24),NO,0);
    UIColor *cyan=[UIColor colorWithRed:0 green:0.88 blue:1 alpha:1];
    UIColor *orange=[UIColor colorWithRed:1 green:0.43 blue:0.10 alpha:1];
    for (NSUInteger i=0;i<2;i++) {
        [(i==0 ? cyan : orange) setStroke];
        UIBezierPath *path=[UIBezierPath bezierPath];
        path.lineWidth=3.5; path.lineCapStyle=kCGLineCapRound; path.lineJoinStyle=kCGLineJoinRound;
        if (exitAction) {
            [path moveToPoint:CGPointMake(7,i==0 ? 4 : 20)];
            [path addLineToPoint:CGPointMake(23,i==0 ? 20 : 4)];
        } else if (i==0) {
            [path moveToPoint:CGPointMake(26,6)];
            [path addLineToPoint:CGPointMake(4,6)];
            [path moveToPoint:CGPointMake(9,2)];
            [path addLineToPoint:CGPointMake(4,6)];
            [path addLineToPoint:CGPointMake(9,10)];
        } else {
            [path moveToPoint:CGPointMake(4,18)];
            [path addLineToPoint:CGPointMake(26,18)];
            [path moveToPoint:CGPointMake(21,14)];
            [path addLineToPoint:CGPointMake(26,18)];
            [path addLineToPoint:CGPointMake(21,22)];
        }
        [path stroke];
    }
    UIImage *result=[UIGraphicsGetImageFromCurrentImageContext() imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    UIGraphicsEndImageContext();
    if (exitAction) exitIcon=result; else swapIcon=result;
    return result;
}
@implementation TAControls
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)first shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)second {
    return first.view==second.view && ([first isKindOfClass:UILongPressGestureRecognizer.class] || [second isKindOfClass:UILongPressGestureRecognizer.class]);
}
- (void)pressDivider:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan) TADividerFeedback(YES);
    if ((gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) && !dividerDragging) TADividerFeedback(NO);
}
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)gesture {
    if (!running || TAAttachPending() || splitWindow.rootViewController.presentedViewController) return NO;
    if ([gesture isKindOfClass:UIPanGestureRecognizer.class]) {
        CGPoint v=[(UIPanGestureRecognizer *)gesture velocityInView:splitWindow.rootViewController.view];
        return fabs(v.x)>fabs(v.y);
    }
    return YES;
}
- (void)layoutSplit:(BOOL)commit {
    if (!running) return;
    CGFloat available=splitWindow.bounds.size.width-TADividerGap, height=splitWindow.bounds.size.height;
    CGFloat left=available*splitRatio, center=left+TADividerGap/2;
    panes[0].frame=CGRectMake(0,0,left,height);
    panes[1].frame=CGRectMake(left+TADividerGap,0,available-left,height);
    gapTouchShield.frame=CGRectMake(left,0,TADividerGap,height);
    CGFloat endInset=MIN(56,height*0.18);
    dividerView.frame=CGRectMake(center-TADividerHitWidth/2,endInset,TADividerHitWidth,height-2*endInset);
    dividerHighlight.frame=CGRectMake(1,endInset,MAX(1,TADividerGap-2),height-2*endInset);
    splitShortcut.frame=CGRectMake(center-25,4,50,42);
    dividerFeedback.frame=CGRectMake(center-36,height/2-19,72,38);
    floatingActions.frame=CGRectMake(MAX(0,MIN(center-84,splitWindow.bounds.size.width-168)),52,168,44);
    for (NSInteger i=0;i<2;i++) {
        choose[i].frame=panes[i].bounds;
        sideActions[i].frame=CGRectMake(CGRectGetMidX(panes[i].frame)-22,CGRectGetMidY(panes[i].frame)-22,44,44);
        TARecord *r=slots[i];
        r.presentation.frame=panes[i].bounds;
        if (commit && r.presentation && !r.attaching) {
            TAResize(r,panes[i].bounds.size);
        }
    }
    if (commit) {
        TALog(@"DIVIDER COMMIT ratio=%.3f left=%@ right=%@",splitRatio,NSStringFromCGRect(panes[0].bounds),NSStringFromCGRect(panes[1].bounds));

    }
}
- (void)dragDivider:(UIPanGestureRecognizer *)gesture {
    if (!running || TAAttachPending()) return;
    if (gesture.state==UIGestureRecognizerStateBegan) {
        dividerDragging=YES; dragStartRatio=splitRatio; [self showChrome];
        TADividerFeedback(YES);
        floatingActions.hidden=YES;
        TAHideSideActions();
    }
    CGFloat available=splitWindow.bounds.size.width-TADividerGap;
    if (available<=0) return;
    if (gesture.state==UIGestureRecognizerStateBegan || gesture.state==UIGestureRecognizerStateChanged || gesture.state==UIGestureRecognizerStateEnded) {
        CGFloat minimum=MIN(140,available/2);
        CGFloat requested=available*dragStartRatio+[gesture translationInView:splitWindow.rootViewController.view].x;
        splitRatio=MAX(minimum,MIN(available-minimum,requested))/available;
        [self layoutSplit:gesture.state==UIGestureRecognizerStateEnded];
    }
    if (gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) {
        splitRatio=dragStartRatio; [self layoutSplit:NO];
    }
    if (gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) {
        dividerDragging=NO; [self showChrome];
        TADividerFeedback(NO);
    }
}
- (void)dragEntry:(UIPanGestureRecognizer *)gesture {
    if (!buttonWindow || running) return;
    if (gesture.state==UIGestureRecognizerStateBegan) { entryDragging=YES; entryDragStart=buttonWindow.frame.origin; }
    CGPoint delta=[gesture translationInView:nil];
    CGRect bounds=dashboard.coordinateSpace.bounds, frame=buttonWindow.frame;
    frame.origin.x=MAX(CGRectGetMinX(bounds),MIN(CGRectGetMaxX(bounds)-frame.size.width,entryDragStart.x+delta.x));
    frame.origin.y=MAX(CGRectGetMinY(bounds),MIN(CGRectGetMaxY(bounds)-frame.size.height,entryDragStart.y+delta.y));
    buttonWindow.frame=frame;
    if (gesture.state==UIGestureRecognizerStateEnded || gesture.state==UIGestureRecognizerStateCancelled || gesture.state==UIGestureRecognizerStateFailed) {
        entryLeft=CGRectGetMidX(frame)<CGRectGetMidX(bounds);
        entryYRatio=(frame.origin.y-CGRectGetMinY(bounds))/MAX(1,bounds.size.height-frame.size.height);
        entryDragging=NO; TALayoutEntry(); [self showChrome];
    }
}
- (void)enter {
    if (!running && !entryExpanded) { entryExpanded=YES; TALayoutEntry(); [self showChrome]; return; }
    [self showChrome];
    if (running) [self toggleActions]; else [self start];
}
- (void)showChrome {
    buttonWindow.hidden=running || !dashboard;
    if (running) splitShortcut.hidden=NO;
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideChrome) object:nil];
    [self performSelector:@selector(hideChrome) withObject:nil afterDelay:3.0 inModes:@[NSRunLoopCommonModes]];
}
- (void)hideChrome {
    if (dividerDragging || entryDragging) { [self showChrome]; return; }
    if (splitWindow.rootViewController.presentedViewController) {
        [self showChrome]; return;
    }
    floatingActions.hidden=YES; buttonWindow.hidden=running || !dashboard;
    splitShortcut.hidden=YES;
    entryExpanded=NO; TALayoutEntry();
    TAHideSideActions();
}
- (void)touchActivity:(UIEvent *)event {
    if (!running) {
        for (UITouch *touch in event.allTouches) if (touch.phase==UITouchPhaseBegan && touch.window.windowScene==dashboard && touch.window!=buttonWindow) {
            entryExpanded=NO; TALayoutEntry();
        }
        return;
    }
    for (UITouch *touch in event.allTouches) {
        if (touch.window.windowScene!=dashboard || touch.phase!=UITouchPhaseBegan) continue;
        if ([touch.view isDescendantOfView:sideActions[0]] || [touch.view isDescendantOfView:sideActions[1]]) {
            [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideChrome) object:nil];
            continue;
        }
        if ([touch.view isDescendantOfView:splitShortcut]) { [self showChrome]; continue; }
        TAHideSideActions();
        if ([touch.view isDescendantOfView:floatingActions]) [self showChrome];
        else if (![touch.view isDescendantOfView:dividerView]) { floatingActions.hidden=YES; splitShortcut.hidden=YES; }
    }
}
- (void)stop { [self closeIcons]; TAStop(@"user"); [self showChrome]; }
- (void)toggleActions { if (splitWindow.rootViewController.presentedViewController) return; TAHideSideActions(); [self showChrome]; floatingActions.hidden = !floatingActions.hidden; }
- (void)restartSplit {
    if (!running || TAAttachPending() || splitWindow.rootViewController.presentedViewController) return;
    floatingActions.hidden=YES;
    for (NSInteger side=0;side<2;side++) {
        sideActions[side].hidden=NO;
        [splitWindow.rootViewController.view bringSubviewToFront:sideActions[side]];
    }
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideChrome) object:nil];
    [self performSelector:@selector(hideChrome) withObject:nil afterDelay:5.0 inModes:@[NSRunLoopCommonModes]];
}
- (void)changeSide:(UIButton *)sender {
    NSInteger side=sender.tag;
    if (!running || side<0 || side>1 || TAAttachPending() || splitWindow.rootViewController.presentedViewController) return;
    TAHideSideActions();
    [self pick:choose[side]];
}
- (void)start {
    if (running || !dashboard || TADashboard() != dashboard) return;
    CGRect bounds = dashboard.coordinateSpace.bounds;
    if (bounds.size.width < 150 || bounds.size.height < 100) return;
    // First entry uses the last two explicitly opened, distinct apps, ordered
    // chronologically. A previous split remains authoritative when resumable.
    for (NSInteger i=0;i<2;i++) if (resumeBundles[i] && !records[resumeBundles[i]]) resumeBundles[i]=nil;
    if (!resumeBundles[0] && !resumeBundles[1]) {
        NSMutableArray<NSString *> *recent=[NSMutableArray new];
        for (NSString *bundle in order) if (records[bundle]) [recent addObject:bundle];
        if (recent.count>=2) { resumeBundles[0]=recent[recent.count-2]; resumeBundles[1]=recent.lastObject; }
        else if (recent.count==1) resumeBundles[0]=recent.firstObject;
        TALog(@"FIRST SPLIT left=%@ right=%@",resumeBundles[0],resumeBundles[1]);
    }
    running = YES; ++generation; splitRatio=MAX(0.2,MIN(0.8,resumeRatio));
    splitWindow = [[TASplitWindow alloc] initWithWindowScene:dashboard];
    splitWindow.frame = bounds; splitWindow.windowLevel = UIWindowLevelAlert + 70;
    splitWindow.opaque=YES; splitWindow.backgroundColor=[UIColor colorWithRed:0.012 green:0.020 blue:0.035 alpha:1];
    splitWindow.rootViewController = [UIViewController new];
    UIView *root = splitWindow.rootViewController.view; root.backgroundColor=splitWindow.backgroundColor; root.opaque=YES;
    // Thin visual gap; enlarged hit area overlaps each pane by 7pt at the center.
    CGFloat half = bounds.size.width / 2;
    CGFloat gap=TADividerGap, paneWidth=(bounds.size.width-gap)/2;
    for (NSInteger i = 0; i < 2; i++) {
        panes[i] = [[UIView alloc] initWithFrame:CGRectMake(i * (paneWidth+gap), 0, paneWidth, bounds.size.height)];
        panes[i].backgroundColor=UIColor.blackColor;
        panes[i].layer.cornerRadius=12;
        if (@available(iOS 13.0,*)) panes[i].layer.cornerCurve=kCACornerCurveContinuous;
        panes[i].clipsToBounds = YES; [root addSubview:panes[i]];
        choose[i] = [UIButton buttonWithType:UIButtonTypeCustom];
        UIColor *accent=i==0 ? TACyan() : TAOrange();
        [choose[i] setTitle:i==0 ? @"Chọn ứng dụng trái" : @"Chọn ứng dụng phải" forState:UIControlStateNormal];
        choose[i].backgroundColor=TAGlassColor(0.88);
        [choose[i] setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        choose[i].tintColor=accent;
        UIImageSymbolConfiguration *chooseConfig=[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightMedium];
        [choose[i] setImage:[UIImage systemImageNamed:@"rectangle.stack.badge.plus" withConfiguration:chooseConfig] forState:UIControlStateNormal];
        choose[i].imageEdgeInsets=UIEdgeInsetsMake(0,-8,0,8);
        choose[i].layer.borderWidth=1; choose[i].layer.borderColor=[accent colorWithAlphaComponent:0.52].CGColor;
        choose[i].titleLabel.font=[UIFont boldSystemFontOfSize:18];
        choose[i].titleLabel.numberOfLines=2; choose[i].titleLabel.textAlignment=NSTextAlignmentCenter;
        choose[i].contentEdgeInsets=UIEdgeInsetsMake(8,8,8,8);
        [choose[i] addTarget:self action:@selector(pick:) forControlEvents:UIControlEventTouchUpInside];
        choose[i].tag = i; choose[i].frame = panes[i].bounds; [panes[i] addSubview:choose[i]];
    }
    gapTouchShield=[[UIControl alloc] initWithFrame:CGRectMake(paneWidth,0,TADividerGap,bounds.size.height)];
    gapTouchShield.backgroundColor=UIColor.blackColor; gapTouchShield.opaque=YES;
    gapTouchShield.userInteractionEnabled=YES; [root addSubview:gapTouchShield];
    dividerHighlight=[UIView new]; dividerHighlight.backgroundColor=TACyan();
    dividerHighlight.layer.cornerRadius=1; dividerHighlight.alpha=0; dividerHighlight.userInteractionEnabled=NO;
    [gapTouchShield addSubview:dividerHighlight];
    dividerView=[[UIView alloc] initWithFrame:CGRectMake(half-TADividerHitWidth/2,(bounds.size.height-TADividerHitHeight)/2,TADividerHitWidth,TADividerHitHeight)];
    dividerView.backgroundColor=UIColor.clearColor;
    UIPanGestureRecognizer *drag=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragDivider:)];
    drag.maximumNumberOfTouches=1; drag.delegate=self; [dividerView addGestureRecognizer:drag];
    UITapGestureRecognizer *tap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleActions)];
    [tap requireGestureRecognizerToFail:drag]; [dividerView addGestureRecognizer:tap];
    dividerView.accessibilityLabel=@"Chạm mở tác vụ, kéo để chia màn";
    [root addSubview:dividerView];
    splitShortcut=[UIView new]; TAStyleGlass(splitShortcut,15,[UIColor colorWithWhite:1 alpha:0.22]);
    UIImageView *logo=[[UIImageView alloc] initWithImage:TASplitIcon()];
    logo.frame=CGRectMake(10,9,30,24); logo.userInteractionEnabled=NO; [splitShortcut addSubview:logo];
    splitShortcut.accessibilityLabel=@"MultiTA: chạm mở tác vụ, kéo để chia màn";
    splitShortcut.isAccessibilityElement=YES;
    [root addSubview:splitShortcut];
    UIPanGestureRecognizer *topDrag=[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dragDivider:)];
    topDrag.maximumNumberOfTouches=1; topDrag.delegate=self; [splitShortcut addGestureRecognizer:topDrag];
    UITapGestureRecognizer *topTap=[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(toggleActions)];
    [topTap requireGestureRecognizerToFail:topDrag]; [splitShortcut addGestureRecognizer:topTap];
    for (UIView *handle in @[dividerView,splitShortcut]) {
        UILongPressGestureRecognizer *press=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(pressDivider:)];
        press.minimumPressDuration=0; press.cancelsTouchesInView=NO; press.delegate=self;
        [handle addGestureRecognizer:press];
    }
    dividerFeedback=[UILabel new]; dividerFeedback.text=@"‹   ›"; dividerFeedback.textAlignment=NSTextAlignmentCenter;
    dividerFeedback.font=[UIFont systemFontOfSize:20 weight:UIFontWeightSemibold]; dividerFeedback.textColor=UIColor.whiteColor;
    TAStyleGlass(dividerFeedback,19,[TACyan() colorWithAlphaComponent:0.35]);
    dividerFeedback.alpha=0; dividerFeedback.transform=CGAffineTransformMakeScale(0.88,0.88); dividerFeedback.userInteractionEnabled=NO; [root addSubview:dividerFeedback];
    floatingActions = [[UIView alloc] initWithFrame:CGRectMake(half-84,bounds.size.height/2-22,168,44)];
    TAStyleGlass(floatingActions,16,[UIColor colorWithWhite:1 alpha:0.22]);
    NSArray *titles = @[@"", @"", @""];
    NSArray *actions = @[@"restartSplit", @"swapSides", @"stop"];
    for (NSUInteger i=0; i<titles.count; i++) {
        UIButton *b = TAButton(titles[i], NSSelectorFromString(actions[i]));
        b.frame = CGRectMake(5+i*54,5,50,34); b.backgroundColor=UIColor.clearColor;
        b.layer.cornerRadius=11; b.layer.borderWidth=0;
        if (i==0) { [b setImage:TASplitIcon() forState:UIControlStateNormal]; b.accessibilityLabel=@"Chia màn hình"; }
        if (i==1) {
            [b setImage:TAActionIcon(NO) forState:UIControlStateNormal];
            b.accessibilityLabel=@"Đổi vị trí hai ứng dụng";
        }
        if (i==2) { [b setImage:TAActionIcon(YES) forState:UIControlStateNormal]; b.accessibilityLabel=@"Thoát chia màn hình"; }
        [floatingActions addSubview:b];
    }
    floatingActions.hidden = YES; [root addSubview:floatingActions];
    for (NSInteger side=0;side<2;side++) {
        UIButton *b=TAButton(@"",@selector(changeSide:));
        b.tag=side; b.layer.cornerRadius=22; b.layer.borderWidth=1;
        b.tintColor=side==0 ? TACyan() : TAOrange();
        b.backgroundColor=TAGlassColor(0.78);
        b.layer.borderColor=b.tintColor.CGColor;
        UIImageSymbolConfiguration *config=[UIImageSymbolConfiguration configurationWithPointSize:24 weight:UIImageSymbolWeightSemibold];
        [b setImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:config] forState:UIControlStateNormal];
        b.accessibilityLabel=side==0 ? @"Đổi ứng dụng bên trái" : @"Đổi ứng dụng bên phải";
        b.hidden=YES; [root addSubview:b]; sideActions[side]=b;
    }
    splitWindow.hidden = NO; buttonWindow.hidden=YES; [self showChrome];
    TALog(@"START display=%@ pane=%@", NSStringFromCGRect(bounds), NSStringFromCGRect(panes[0].bounds));
    [self layoutSplit:NO];
    [self resumeSlot:0 token:generation attempt:0];
}
- (void)resumeSlot:(NSInteger)slot token:(NSUInteger)token attempt:(NSUInteger)attempt {
    if (!running || generation!=token || slot>1 || attempt>=60) return;
    if (TAAttachPending() || splitWindow.rootViewController.presentedViewController) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            [self resumeSlot:slot token:token attempt:attempt+1];
        });
        return;
    }
    NSString *bundle=resumeBundles[slot];
    if (!slots[slot] && bundle.length && records[bundle]) [self attach:bundle slot:slot];
    [self resumeSlot:slot+1 token:token attempt:0];
}
- (void)swapSides {
    if (!running || TAAttachPending() || !slots[0].presentation || !slots[1].presentation || splitWindow.rootViewController.presentedViewController) return;
    TARecord *left = slots[0]; slots[0] = slots[1]; slots[1] = left;
    for (NSInteger i = 0; i < 2; i++) {
        [panes[i] addSubview:slots[i].presentation];
        slots[i].presentation.frame = panes[i].bounds;
    }
    [self layoutSplit:YES];
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
        if (running && generation == token) [self replace:bundle slot:slot];
    }];
}
- (void)iconPage:(UIButton *)sender {
    NSInteger page = (NSInteger)self.iconPage + sender.tag;
    if (page < 0 || (NSUInteger)page >= (self.iconBundles.count + 5) / 6) return;
    self.iconPage = page; [self renderIcons];
}
- (void)renderIcons {
    UIView *root = self.iconPicker.view;
    root.backgroundColor=[UIColor colorWithWhite:0.10 alpha:1];
    for (UIView *v in [root.subviews copy]) [v removeFromSuperview];
    UIView *panel = [[UIView alloc] initWithFrame:CGRectInset(splitWindow.bounds, 12, 12)];
    panel.backgroundColor = [UIColor colorWithWhite:0.16 alpha:0.98];
    panel.layer.cornerRadius = 14; [root addSubview:panel];
    CGFloat w = panel.bounds.size.width, h = panel.bounds.size.height;
    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(12, 5, w-24, 40)];
    title.text = @"ỨNG DỤNG ĐÃ MỞ"; title.font = [UIFont boldSystemFontOfSize:28];
    title.textColor = self.iconSlot==0 ? [UIColor colorWithRed:0 green:0.88 blue:1 alpha:1] : [UIColor colorWithRed:1 green:0.43 blue:0.10 alpha:1]; title.textAlignment = NSTextAlignmentCenter; [panel addSubview:title];
    CGFloat cellW = (w-24)/3, cellH = (h-88)/2;
    NSUInteger first = self.iconPage * 6, end = MIN(first+6, self.iconBundles.count);
    for (NSUInteger i = first; i < end; i++) {
        NSUInteger position = i-first;
        UIButton *button = [UIButton buttonWithType:UIButtonTypeCustom];
        button.frame = CGRectMake(12+(position%3)*cellW, 52+(position/3)*cellH, cellW, cellH);
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
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(12, 52, w-24, h-92)];
        empty.text = @"Mở app từ CarPlay trước để đưa vào danh sách.";
        empty.numberOfLines = 0; empty.textAlignment = NSTextAlignmentCenter; empty.textColor = UIColor.whiteColor;
        [panel addSubview:empty];
    }
}
- (void)pick:(UIButton *)sender {
    NSInteger slot = sender.tag;
    if (!running || slot < 0 || slot > 1 || TAAttachPending() || splitWindow.rootViewController.presentedViewController) return;
    NSMutableArray *bundles = [NSMutableArray new];
    for (NSString *bundle in [order copy]) {
        TARecord *r = records[bundle], *other = slots[1-slot];
        if (!r || (other && (other == r || [other.bundle isEqual:r.bundle] || other.controller == r.controller))) continue;
        [bundles addObject:bundle];
    }
    self.iconBundles = bundles; self.iconSlot = slot; self.iconPage = 0; self.iconToken = generation;
    UIViewController *picker = [UIViewController new]; self.iconPicker = picker;
    picker.modalPresentationStyle = UIModalPresentationOverFullScreen;
    picker.view.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    [self renderIcons];
    [splitWindow.rootViewController presentViewController:picker animated:NO completion:nil];
}
- (void)replace:(NSString *)bundle slot:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || !records[bundle]) return;
    if ([slots[slot].bundle isEqual:bundle]) return;
    if ([slots[1-slot].bundle isEqual:bundle]) return;
    TAClearSlot(slot,@"replace"); [self attach:bundle slot:slot];
}
- (void)attach:(NSString *)bundle slot:(NSInteger)slot {
    TARecord *r = records[bundle], *other = slots[1-slot];
    if (!running || slots[slot] || !r || (other && (other == r || [other.bundle isEqual:r.bundle] || other.controller == r.controller))) return;
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
    ownCall = previous; choose[slot].enabled = NO; [choose[slot] setTitle:@"Đang mở…" forState:UIControlStateNormal];
    [self finishAttach:slot generation:token request:request attempt:0];
}
- (void)finishAttach:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt {
    if (!running || generation!=token || slotRequests[slot]!=request || !slots[slot].attaching) return;
    TARecord *r=slots[slot];
    CGRect frame=CGRectZero;
    BOOL ready=TAReadFrame(TAValue(r.controller,@"scene"),&frame);
    // Give native activation time to settle; re-read the current controller
    // every time. Foreground is requested once, never polled/replayed.
    if (attempt<4 || !ready) {
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
        r.presentationID=[NSString stringWithFormat:@"com.sushibta.multita.%lu.%ld.%lu",(unsigned long)token,(long)slot,(unsigned long)request];
        id v=((id(*)(id,SEL,id))objc_msgSend)(r.controller,create,r.presentationID);
        if (![v isKindOfClass:UIView.class] || ((UIView *)v).superview) @throw [NSException exceptionWithName:@"NotIndependent" reason:r.bundle userInfo:nil];
        r.presentation=v; r.presentation.transform=CGAffineTransformIdentity; r.presentation.frame=panes[slot].bounds;
        [panes[slot] addSubview:r.presentation];
        if (TAMapBundle(r.bundle)) {
            [panes[slot] bringSubviewToFront:choose[slot]];
            [choose[slot] setTitle:@"Đang tải bản đồ…" forState:UIControlStateNormal];
            TAPresentationEvidence(r,@"created");
            [self checkPresentation:slot generation:token request:request attempt:0];
        } else if ([r.bundle isEqual:@"com.google.ios.youtube"]) {
            // Keep the opaque chooser above the live surface while resize settles.
            // Do not hide the presentation itself: its client must keep laying out.
            [panes[slot] bringSubviewToFront:choose[slot]];
            [self settleYouTube:slot generation:token request:request attempt:0 stable:0];
        } else {
            choose[slot].hidden=YES; r.attaching=NO;
            TALog(@"ATTACHED slot=%ld bundle=%@ attempt=%lu",(long)slot,r.bundle,(unsigned long)attempt);
        }
    } @catch (NSException *e) {
        TALog(@"PRESENTATION ERROR %@ bundle=%@",e.name,r.bundle);
        if (running && slots[slot]==r) TAClearSlot(slot,@"presentation failed");
    } @finally { ownCall=old; }

}
- (void)settleYouTube:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt stable:(NSUInteger)stable {
    if (!running || generation!=token || slotRequests[slot]!=request || !slots[slot].attaching) return;
    TARecord *r=slots[slot];
    if (r.scene!=TAValue(r.controller,@"scene") || !r.presentation) {
        TAClearSlot(slot,@"YouTube scene changed while settling"); return;
    }
    CGRect actual=CGRectZero;
    CGSize target=panes[slot].bounds.size, shown=r.presentation.bounds.size;
    BOOL matches=TAReadFrame(r.scene,&actual) &&
        fabs(actual.size.width-target.width)<0.5 && fabs(actual.size.height-target.height)<0.5 &&
        fabs(shown.width-target.width)<0.5 && fabs(shown.height-target.height)<0.5 &&
        CGAffineTransformIsIdentity(r.presentation.transform) && TAYoutubeClientReady(target);
    NSUInteger nextStable=matches ? stable+1 : 0;
    // Five quarter-second intervals cover the observed first-second transition.
    // Host geometry stability is not proof that all YouTube content is settled.
    if ((attempt>=5 && nextStable>=3) || attempt>=12) {
        choose[slot].hidden=YES; r.attaching=NO;
        TALog(@"YOUTUBE REVEAL slot=%ld attempt=%lu stable=%lu geometry=%d timeout=%d target=%@",
              (long)slot,(unsigned long)attempt,(unsigned long)nextStable,matches,
              attempt>=12,NSStringFromCGSize(target));
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self settleYouTube:slot generation:token request:request attempt:attempt+1 stable:nextStable];
    });
}
- (void)checkPresentation:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt {
    if (!running || token!=generation || request!=slotRequests[slot] || !slots[slot].attaching) return;
    TARecord *r=slots[slot];
    if (r.scene!=TAValue(r.controller,@"scene")) {
        TAClearSlot(slot,@"map scene changed while connecting");
        return;
    }
    NSInteger budget=240;
    BOOL connected=TAHasHostedSurface(r.presentation.layer,0,&budget);
    if (connected && attempt>0) {
        r.attaching=NO; choose[slot].hidden=YES;
        TAPresentationEvidence(r,@"connected");
        TALog(@"ATTACHED slot=%ld bundle=%@ surface=1 (not pixel validation)",(long)slot,r.bundle);
        return;
    }
    if (attempt==8 && !connected) {
        // One replacement of the presentation only. Do not relaunch the app,
        // replay foreground, or restore/change the other pane's geometry.
        BOOL previous=ownCall; ownCall=YES;
        @try {
            SEL invalidate=NSSelectorFromString(@"invalidatePresentationViewForIdentifier:");
            SEL create=NSSelectorFromString(@"presentationViewWithIdentifier:");
            if ([r.controller respondsToSelector:invalidate] && [r.controller respondsToSelector:create]) {
                TAPresentationEvidence(r,@"before-rebind");
                [r.presentation removeFromSuperview]; r.presentation=nil;
                ((void(*)(id,SEL,id))objc_msgSend)(r.controller,invalidate,r.presentationID);
                r.presentationID=[r.presentationID stringByAppendingString:@".rebind"];
                id view=((id(*)(id,SEL,id))objc_msgSend)(r.controller,create,r.presentationID);
                if (![view isKindOfClass:UIView.class] || ((UIView *)view).superview)
                    @throw [NSException exceptionWithName:@"NotIndependent" reason:r.bundle userInfo:nil];
                r.presentation=view; r.presentation.transform=CGAffineTransformIdentity;
                r.presentation.frame=panes[slot].bounds;
                [panes[slot] addSubview:r.presentation]; [panes[slot] bringSubviewToFront:choose[slot]];
                TAPresentationEvidence(r,@"rebound");
            }
        } @catch (NSException *e) {
            TALog(@"MAP REBIND ERROR %@ bundle=%@",e.name,r.bundle);
            TAClearSlot(slot,@"map rebind failed");
        } @finally { ownCall=previous; }
        if (!running || slots[slot]!=r || request!=slotRequests[slot]) return;
    }
    if (attempt>=24) {
        TAPresentationEvidence(r,@"timeout");
        TAClearSlot(slot,@"map surface timeout");
        [choose[slot] setTitle:@"Bản đồ chưa hiện. Chạm để chọn lại" forState:UIControlStateNormal];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self checkPresentation:slot generation:token request:request attempt:attempt+1];
    });
}

@end
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
    // Unknown passive navigation callbacks must not seed the user's recent-app list.
    // Existing/pending records still receive scene updates for split recovery.
    if (!launch && !r) {
        TALog(@"CAPTURE PASSIVE ignored bundle=%@",bundle);
        return;
    }
    if (!r || r.controller!=controller) {
        r=[TARecord new]; r.controller=controller; r.bundle=bundle;
    }
    if (launch || !r.activation) r.activation=[settings copy]; records[bundle]=r;
    if (launch) { [order removeObject:bundle]; [order addObject:bundle]; }
    // Keep resumable/active apps pinned when trimming recently seen apps.
    while (order.count>24) {
        NSString *victim=nil;
        for (NSString *entry in order) {
            if ([slots[0].bundle isEqual:entry] || [slots[1].bundle isEqual:entry] || [entry isEqual:bundle]) continue;
            victim=entry; break;
        }
        if (!victim) break;
        [records removeObjectForKey:victim]; [order removeObject:victim];
    }
    TALog(@"CAPTURE %@ sid=%@ launchSource=%d",bundle,sid,launch);
    if (!running) [controls showChrome];
}
static void TATick(void) {
    static NSTimeInterval previousTick=0;
    NSTimeInterval now=NSDate.timeIntervalSinceReferenceDate;
    if (previousTick && now-previousTick>4) TALog(@"MAIN LOOP GAP seconds=%.2f",now-previousTick);
    previousTick=now;
    UIWindowScene *s=TADashboard();
    if (s!=dashboard) {
        TAStop(@"display changed"); buttonWindow.hidden=YES; buttonWindow=nil; entryControl=nil; entryExpanded=NO; entryDragging=NO;
        [records removeAllObjects]; [order removeAllObjects]; dashboard=s;
        TALog(@"DISPLAY %@",s.session.persistentIdentifier);
    }
    if (running && !CGRectEqualToRect(splitWindow.frame,s.coordinateSpace.bounds)) TAStop(@"display geometry changed");
    if (s && !buttonWindow) {
        buttonWindow=[[UIWindow alloc] initWithWindowScene:s];
        buttonWindow.windowLevel=UIWindowLevelAlert+80;
        CGRect screen=s.coordinateSpace.bounds;
        buttonWindow.frame=CGRectMake(CGRectGetMinX(screen)+(screen.size.width-4)*resumeRatio+2-22,CGRectGetMinY(screen)+4,44,40);
        buttonWindow.backgroundColor=UIColor.clearColor; buttonWindow.opaque=NO;
        buttonWindow.rootViewController=[UIViewController new];
        buttonWindow.rootViewController.view.backgroundColor=UIColor.clearColor;
        UIButton *entry=[UIButton buttonWithType:UIButtonTypeCustom];
        [entry addTarget:controls action:@selector(enter) forControlEvents:UIControlEventTouchUpInside];
        [entry setTitleColor:[UIColor colorWithRed:0 green:0.88 blue:1 alpha:1] forState:UIControlStateNormal];
        entry.titleLabel.font=[UIFont boldSystemFontOfSize:24]; entryControl=entry;
        [entry setImage:TASplitIcon() forState:UIControlStateNormal];
        entry.frame=buttonWindow.bounds; entry.backgroundColor=UIColor.clearColor; entry.layer.borderWidth=0;
        entry.accessibilityLabel=@"Chia màn hình; kéo để di chuyển";
        UIPanGestureRecognizer *pan=[[UIPanGestureRecognizer alloc] initWithTarget:controls action:@selector(dragEntry:)];
        pan.maximumNumberOfTouches=1; [entry addGestureRecognizer:pan];
        [buttonWindow.rootViewController.view addSubview:entry];
        TALayoutEntry();
        TALog(@"ENTRY floating created");
    }
    buttonWindow.hidden=running || !s;
    if (!running) TALayoutEntry();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ TATick(); });
}
// Darwin state channels carry only dimensions, never application content.
// The host logs receipt as an observation, not proof of correct app layout.
static NSString *TAChannel(NSString *bundle, NSString *kind) {
    return [NSString stringWithFormat:@"com.sushibta.multita.geometry.%@.%@", bundle, kind];
}
static NSArray<NSString *> *TAClientBundles(void) {
    return @[@"com.apple.Maps", @"com.google.Maps", @"com.google.ios.youtube", @"com.google.ios.youtubemusic", @"vn.vietmap.live"];
}
// The layout experiment is enabled only for the exact scene dimensions
// currently owned by MultiTA. No global narrow-screen heuristics.
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
    if (notify_set_state(token, packed) == NOTIFY_STATUS_OK) {
        notify_post(TAChannel(bundle, @"layout-target").UTF8String);
        notify_post("com.sushibta.multita.template-targets-changed");
    }
}
static BOOL TATemplateTarget(UIWindow *w, NSString **bundleOut) {
    NSString *sid = w.windowScene.session.persistentIdentifier;
    NSArray *parts = [sid componentsSeparatedByString:@":"];
    if (parts.count != 3 || ![parts[1] isEqual:@"com.apple.CarPlayTemplateUIHost"]) return NO;
    NSString *bundle = parts.lastObject; if (bundleOut) *bundleOut = bundle;
    if (![bundle containsString:@"."]) return NO;
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
    BOOL active=TATemplateTarget(bar.window,&bundle) && bar.bounds.size.width>0 && bar.bounds.size.width<300;
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
    BOOL active=TATemplateTarget(cell.window,&bundle) && cell.bounds.size.width>48 && cell.bounds.size.width<300;
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
// Synchronize only YouTube's direct, frame-managed CarPlay root.
// A mismatched root is the repair condition, not a prerequisite for relayout.
static char TAYoutubeLayoutStamp, TAYoutubeLayoutQueued, TAYoutubeAttempts, TAYoutubeMask;
static BOOL TAYoutubeSizeMatches(CGSize a, CGSize b) {
    return fabs(a.width-b.width)<0.5 && fabs(a.height-b.height)<0.5;
}
static CGRect TAYoutubeOwnedRootFrame(UIView *view, CGRect requested) {
    UIWindow *w=view.window;
    UIView *root=w.rootViewController.viewIfLoaded;
    if (!w || !root || !CGAffineTransformIsIdentity(view.transform)) return requested;
    // A root can sit inside UIKit transition wrappers and use Auto Layout.
    // 0.10.17 silently skipped both cases, so the guard never reached those roots.
    BOOL owns=NO, reachesWindow=NO; UIView *cursor=root;
    for (NSUInteger depth=0;cursor && depth<6;depth++,cursor=cursor.superview) {
        if (cursor==w) { reachesWindow=YES; break; }
        if (!CGAffineTransformIsIdentity(cursor.transform)) return requested;
        if (cursor!=root && ![@[@"UIView",@"UITransitionView",@"UIViewControllerWrapperView",@"UILayoutContainerView"] containsObject:NSStringFromClass(cursor.class)]) return requested;
        if (cursor==view) owns=YES;
    }
    if (!owns || !reachesWindow) return requested;
    NSString *sid=w.windowScene.session.persistentIdentifier ?: @"";
    NSString *role=w.windowScene.session.role ?: @"";
    if (![sid hasPrefix:@"Car["] && ![role containsString:@"CarPlay"]) return requested;
    int token=TATargetToken(@"com.google.ios.youtube"); uint64_t packed=0;
    if (token<0 || notify_get_state(token,&packed)!=NOTIFY_STATUS_OK || !packed) return requested;
    CGSize target=CGSizeMake((packed>>32)/4.0,(packed&0xffffffff)/4.0);
    if (!TAYoutubeSizeMatches(w.bounds.size,target) ||
        !TAYoutubeSizeMatches(w.windowScene.coordinateSpace.bounds.size,target)) return requested;
    // Restrict this to the root/wrapper chain. Collection cells and scroll content
    // must remain free to exceed their viewport, so never clamp arbitrary subviews.
    return [view.superview convertRect:w.bounds fromView:w];
}
static NSMapTable<NSLayoutConstraint *,NSNumber *> *TAYoutubeSavedConstraints;
static void TAYoutubeRootConstraints(UIView *root, CGSize size, BOOL active) {
    if (!TAYoutubeSavedConstraints) TAYoutubeSavedConstraints=[NSMapTable weakToStrongObjectsMapTable];
    if (!active) {
        for (NSLayoutConstraint *c in TAYoutubeSavedConstraints.keyEnumerator.allObjects) {
            c.constant=[TAYoutubeSavedConstraints objectForKey:c].doubleValue;
            [TAYoutubeSavedConstraints removeObjectForKey:c];
        }
        return;
    }
    NSMutableArray *constraints=[NSMutableArray arrayWithArray:root.constraints];
    if (root.superview) [constraints addObjectsFromArray:root.superview.constraints];
    for (NSLayoutConstraint *c in constraints) {
        if (c.firstItem!=root || c.secondItem || c.relation!=NSLayoutRelationEqual || !c.active || c.constant<=0) continue;
        if (c.firstAttribute!=NSLayoutAttributeWidth && c.firstAttribute!=NSLayoutAttributeHeight) continue;
        CGFloat wanted=c.firstAttribute==NSLayoutAttributeWidth ? size.width : size.height;
        if (fabs(c.constant-wanted)<0.5) continue;
        if (![TAYoutubeSavedConstraints objectForKey:c]) [TAYoutubeSavedConstraints setObject:@(c.constant) forKey:c];
        c.constant=wanted;
    }
}
static void TAYoutubeFitControllerRoots(UIViewController *parent, NSUInteger depth, NSUInteger *budget) {
    if (!parent || depth>5 || !*budget) return; --*budget;
    UIView *container=parent.viewIfLoaded; if (!container) return;
    for (UIViewController *child in parent.childViewControllers) {
        UIView *v=child.viewIfLoaded; if (!v || !v.window) continue;
        // Repair only a full-height direct child controller that overflows its
        // parent. This excludes scroll views, page offsets, cards, and artwork.
        if (v.superview==container && v.translatesAutoresizingMaskIntoConstraints &&
            ![v isKindOfClass:UIScrollView.class] && CGAffineTransformIsIdentity(v.transform) &&
            fabs(v.frame.origin.x)<0.5 && fabs(v.frame.origin.y)<0.5 &&
            fabs(v.bounds.size.height-container.bounds.size.height)<1 &&
            v.bounds.size.width>container.bounds.size.width+0.5) {
            CGRect frame=v.frame; frame.size.width=container.bounds.size.width;
            v.frame=frame; [v setNeedsLayout];
        }
        TAYoutubeFitControllerRoots(child,depth+1,budget);
    }
}
static int TAYoutubeReadyToken(void) {
    static int token=-1; static dispatch_once_t once;
    dispatch_once(&once, ^{ notify_register_check("com.sushibta.multita.youtube-ready",&token); });
    return token;
}
static BOOL TAYoutubeClientReady(CGSize target) {
    int token=TAYoutubeReadyToken(); uint64_t packed=0;
    if (token<0 || notify_get_state(token,&packed)!=NOTIFY_STATUS_OK || !packed) return NO;
    return TAYoutubeSizeMatches(target,CGSizeMake((packed>>32)/4.0,(packed&0xffffffff)/4.0));
}
static void TAYoutubeReportReady(UIWindow *w) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.google.ios.youtube"]) return;
    NSString *sid=w.windowScene.session.persistentIdentifier ?: @"";
    if (![sid hasPrefix:@"Car["] && ![w.windowScene.session.role containsString:@"CarPlay"]) return;
    int targetToken=TATargetToken(@"com.google.ios.youtube"), ready=TAYoutubeReadyToken();
    uint64_t packed=0; if (targetToken<0 || ready<0) return;
    notify_get_state(targetToken,&packed);
    CGSize target=CGSizeMake((packed>>32)/4.0,(packed&0xffffffff)/4.0);
    UIView *root=w.rootViewController.viewIfLoaded;
    BOOL match=packed && root && !w.hidden && TAYoutubeSizeMatches(w.bounds.size,target) &&
        TAYoutubeSizeMatches(w.windowScene.coordinateSpace.bounds.size,target) &&
        TAYoutubeSizeMatches(root.bounds.size,target) && CGAffineTransformIsIdentity(root.transform);
    notify_set_state(ready,match ? packed : 0);
}
static void TAYoutubeClientLayout(UIWindow *w) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.google.ios.youtube"]) return;
    NSString *sid=w.windowScene.session.persistentIdentifier ?: @"";
    NSString *role=w.windowScene.session.role ?: @"";
    if (![sid hasPrefix:@"Car["] && ![role containsString:@"CarPlay"]) return;
    UIView *root=w.rootViewController.viewIfLoaded; if (!root) return;
    int token=TATargetToken(@"com.google.ios.youtube"); uint64_t packed=0;
    if (token<0 || notify_get_state(token,&packed)!=NOTIFY_STATUS_OK) return;
    if (!packed) {
        TAYoutubeRootConstraints(root,CGSizeZero,NO);
        NSNumber *mask=objc_getAssociatedObject(root,&TAYoutubeMask);
        if (mask) {
            root.autoresizingMask=mask.unsignedIntegerValue;
            objc_setAssociatedObject(root,&TAYoutubeMask,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            // The host's restore transaction can arrive later; restored autoresizing
            // and UIKit own subsequent fullscreen geometry.
            if (root.superview==w && root.translatesAutoresizingMaskIntoConstraints &&
                CGAffineTransformIsIdentity(root.transform)) root.frame=w.bounds;
            [root setNeedsLayout];
        }
        objc_setAssociatedObject(w,&TAYoutubeLayoutStamp,nil,OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(w,&TAYoutubeAttempts,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return;
    }
    CGSize target=CGSizeMake((packed>>32)/4.0,(packed&0xffffffff)/4.0);
    if (!TAYoutubeSizeMatches(w.windowScene.coordinateSpace.bounds.size,target) ||
        !TAYoutubeSizeMatches(w.bounds.size,target)) return;
    if ([objc_getAssociatedObject(w,&TAYoutubeLayoutQueued) boolValue]) return;
    NSString *stamp=[NSString stringWithFormat:@"%@/%llu/%p",sid,(unsigned long long)packed,(__bridge void *)root];
    BOOL same=[objc_getAssociatedObject(w,&TAYoutubeLayoutStamp) isEqual:stamp];
    NSUInteger attempts=same ? [objc_getAssociatedObject(w,&TAYoutubeAttempts) unsignedIntegerValue] : 0;
    // One pass per target also invalidates cached collection layouts when the
    // root already matches but its contained controller still has the old width.
    if (same && TAYoutubeSizeMatches(root.bounds.size,target)) return;
    if (attempts>=3) return; // Never fight an app that keeps resetting its root.
    objc_setAssociatedObject(w,&TAYoutubeLayoutStamp,stamp,OBJC_ASSOCIATION_COPY_NONATOMIC);
    objc_setAssociatedObject(w,&TAYoutubeAttempts,@(attempts+1),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(w,&TAYoutubeLayoutQueued,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_async(dispatch_get_main_queue(), ^{
        @try {
            uint64_t current=0;
            if (notify_get_state(token,&current)!=NOTIFY_STATUS_OK || current!=packed ||
                w.rootViewController.viewIfLoaded!=root ||
                !TAYoutubeSizeMatches(w.bounds.size,target) ||
                !TAYoutubeSizeMatches(w.windowScene.coordinateSpace.bounds.size,target)) return;
            CGRect before=root.frame;
            CGRect sentinel=CGRectMake(-12345,-12345,1,1);
            CGRect desired=TAYoutubeOwnedRootFrame(root,sentinel);
            BOOL owned=!CGRectEqualToRect(desired,sentinel);
            if (owned) {
                if (!objc_getAssociatedObject(root,&TAYoutubeMask))
                    objc_setAssociatedObject(root,&TAYoutubeMask,@(root.autoresizingMask),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (root.translatesAutoresizingMaskIntoConstraints)
                    root.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
                TAYoutubeRootConstraints(root,target,YES);
                // Ancestors first, then the app root; preserve UIKit view ownership.
                NSMutableArray<UIView *> *chain=[NSMutableArray new];
                for (UIView *v=root;v && v!=w;v=v.superview) [chain addObject:v];
                for (UIView *v in chain.reverseObjectEnumerator) v.frame=TAYoutubeOwnedRootFrame(v,v.frame);
                NSUInteger controllerBudget=24; TAYoutubeFitControllerRoots(w.rootViewController,0,&controllerBudget);
            }
            NSUInteger budget=100; TAInvalidateTree(root,0,&budget);
            [w setNeedsLayout]; [w layoutIfNeeded]; [root layoutIfNeeded];
            TALog(@"YOUTUBE ROOT SYNC owned=%d attempt=%lu target=%@ before=%@ after=%@ parent=%@",
                  owned,(unsigned long)(attempts+1),NSStringFromCGSize(target),NSStringFromCGRect(before),
                  NSStringFromCGRect(root.frame),NSStringFromClass(root.superview.class));
            for (UIViewController *child in w.rootViewController.childViewControllers)
                TALog(@"YOUTUBE CHILD class=%@ frame=%@ bounds=%@ parent=%@ mask=%d",NSStringFromClass(child.class),NSStringFromCGRect(child.viewIfLoaded.frame),NSStringFromCGRect(child.viewIfLoaded.bounds),NSStringFromClass(child.viewIfLoaded.superview.class),child.viewIfLoaded.translatesAutoresizingMaskIntoConstraints);
        } @finally { objc_setAssociatedObject(w,&TAYoutubeLayoutQueued,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
    });
}
static void TAListenYouTubeTarget(void) {
    int token;
    notify_register_dispatch(TAChannel(@"com.google.ios.youtube",@"layout-target").UTF8String,
        &token,dispatch_get_main_queue(),^(__unused int delivered) {
            int ready=TAYoutubeReadyToken(); if (ready>=0) notify_set_state(ready,0);
            for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
                if (![scene isKindOfClass:UIWindowScene.class]) continue;
                for (UIWindow *w in ((UIWindowScene *)scene).windows) TAYoutubeClientLayout(w);
            }
        });
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
            CGFloat limit = MIN(64, w.screen.bounds.size.width * 0.25);
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
        }
    });
}
// Google Maps navigation title competes with back and two trailing controls.
// Shorten only title text; native layout, hit targets, and icon sizes stay native.
static NSHashTable<UIView *> *TAGoogleBars;
static char TAGoogleTitleKey, TAGoogleBusyKey;
static NSString *TAFitGoogleTitle(NSString *text, UIFont *font, CGFloat width) {
    NSDictionary *attrs=@{NSFontAttributeName:font};
    if ([text sizeWithAttributes:attrs].width<=width) return text;
    NSString *prefix=text;
    while (prefix.length) {
        NSRange last=[prefix rangeOfComposedCharacterSequenceAtIndex:prefix.length-1];
        prefix=[prefix substringToIndex:last.location];
        NSString *candidate=[prefix stringByAppendingString:@"…"];
        if ([candidate sizeWithAttributes:attrs].width<=width) return candidate;
    }
    return @"…";
}
static void TAGoogleTitleWalk(UIView *view, BOOL title, BOOL active, CGFloat width, NSUInteger depth) {
    if (depth>4) return;
    title=title || [NSStringFromClass(view.class) isEqual:@"_CarTitleView"];
    if (title && [view isKindOfClass:UILabel.class]) {
        UILabel *label=(UILabel *)view;
        NSDictionary *saved=objc_getAssociatedObject(label,&TAGoogleTitleKey);
        if (saved && ![label.text isEqual:saved[@"applied"]]) {
            if ([label.accessibilityLabel isEqual:saved[@"original"]])
                label.accessibilityLabel=saved[@"accessibility"]==NSNull.null ? nil : saved[@"accessibility"];
            saved=nil; objc_setAssociatedObject(label,&TAGoogleTitleKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        NSString *original=saved ? saved[@"original"] : label.text;
        if (original.length && (!label.attributedText || saved)) {
            NSString *desired=active ? TAFitGoogleTitle(original,label.font,width) : original;
            if (![desired isEqual:original]) {
                id accessibility=saved ? saved[@"accessibility"] : (label.accessibilityLabel ?: (id)NSNull.null);
                objc_setAssociatedObject(label,&TAGoogleTitleKey,@{@"original":original,@"applied":desired,@"accessibility":accessibility},OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                if (!label.accessibilityLabel) label.accessibilityLabel=original;
            } else if (saved) {
                if ([label.accessibilityLabel isEqual:original])
                    label.accessibilityLabel=saved[@"accessibility"]==NSNull.null ? nil : saved[@"accessibility"];
                objc_setAssociatedObject(label,&TAGoogleTitleKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            }
            if (![label.text isEqual:desired]) {
                label.text=desired;
                [label invalidateIntrinsicContentSize]; [label.superview invalidateIntrinsicContentSize];
                TALog(@"GOOGLE BAR titleFit active=%d budget=%.1f",active,width);
            }
        }
    }
    for (UIView *child in view.subviews) TAGoogleTitleWalk(child,title,active,width,depth+1);
}
static void TACompactGoogleBar(UIView *bar) {
    if ([objc_getAssociatedObject(bar,&TAGoogleBusyKey) boolValue]) return;
    NSString *bundle=nil;
    BOOL active=TATemplateTarget(bar.window,&bundle) && [bundle isEqual:@"com.google.Maps"] &&
        bar.bounds.size.width>0 && bar.bounds.size.width<300;
    if (!active && ![TAGoogleBars containsObject:bar]) return;
    objc_setAssociatedObject(bar,&TAGoogleBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        if (!TAGoogleBars) TAGoogleBars=[NSHashTable weakObjectsHashTable];
        if (active) [TAGoogleBars addObject:bar];
        // Observed controls: back 44pt, trailing 37+8+37pt, plus margins.
        TAGoogleTitleWalk(bar,NO,active,MAX(20,bar.bounds.size.width-160),0);
        if (!active) [TAGoogleBars removeObject:bar];
    } @finally { objc_setAssociatedObject(bar,&TAGoogleBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}
static void TAListenTemplateTargets(void) {
    int token;
    notify_register_dispatch("com.sushibta.multita.template-targets-changed", &token, dispatch_get_main_queue(), ^(__unused int delivered) {
        for (UITabBar *bar in TACompactTabBars.allObjects) TACompactTabs(bar);
        for (UIView *cell in TAImageRows.allObjects) TACompactImageRow(cell);
        for (UIView *bar in TAGoogleBars.allObjects) {
            TACompactGoogleBar(bar); [bar setNeedsLayout];
        }
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) TATemplateLayout(w);
        }
    });
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
    return [parts.lastObject containsString:@"."] ? parts.lastObject : nil;
}
static void TAVisibleTransition(UIViewController *vc) {
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"]) return;
    UIWindow *w = vc.viewIfLoaded.window;
    NSString *bundle = TADiagnosticBundle(w); if (!bundle) return;
    BOOL active=TATemplateTarget(w,NULL);
    if (!active && ![NSStringFromClass(vc.class) isEqual:@"CPSNowPlayingViewController"]) return;
    // One native layout invalidation per appearance. No font/frame edits.
    NSUInteger budget = 100; if (active) TAInvalidateTree(vc.viewIfLoaded, 0, &budget);
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

%group TAGoogleNavigation
%hook CPSNavigationBar
- (void)layoutSubviews {
    TACompactGoogleBar((UIView *)self);
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

#import "TAKeyboard.h"

%group TAClient
%hook UIViewController
- (void)viewDidLayoutSubviews {
    %orig;
    UIWindow *w=self.viewIfLoaded.window;
    if (w.rootViewController==self) { TAYoutubeClientLayout(w); TAYoutubeReportReady(w); }
}
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
    TAYoutubeClientLayout(self);
    TAYoutubeReportReady(self);
}
%end
%end
%group TAYoutubeRootGuard
%hook UIView
- (void)setFrame:(CGRect)frame {
    %orig(TAYoutubeOwnedRootFrame(self,frame));
}
- (void)setBounds:(CGRect)bounds {
    CGRect owned=TAYoutubeOwnedRootFrame(self,bounds);
    bounds.size=owned.size;
    %orig(bounds);
}
%end
%end
%group TAHost
%hook UIWindow
- (void)sendEvent:(UIEvent *)event {
    // Deliver first so waking controls cannot steal the touch.
    %orig;
    if (event.type==UIEventTypeTouches && ((UIWindow *)self).windowScene==dashboard)
        [controls touchActivity:event];
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
    TALog(@"FOREGROUND RETURN bundle=%@ running=%d own=%d",bundle,running,ownCall);
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
            if (running && lateBundle) {
                // A new controller for the same selected app replaces only its old slot.
                for (NSInteger i=0;i<2;i++) {
                    TARecord *oldRecord=slots[i];
                    if (oldRecord && !oldRecord.attaching && [oldRecord.bundle isEqual:lateBundle] && records[lateBundle]!=oldRecord) {
                        oldRecord.restoreBackground=NO;
                        TAClearSlot(i,@"native controller replaced");
                        [controls attach:lateBundle slot:i];
                        return;
                    }
                }
                // Record native apps silently. Only the user picker chooses a split slot.
            }
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
        BOOL pendingDestroyed=NO; // pending attachment owns its bounded readiness timeout
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
        if (([TAClientBundles() containsObject:process] && ![process isEqual:@"vn.vietmap.live"]) || [process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
            %init(TAClient);
            dispatch_async(dispatch_get_main_queue(), ^{ TAKBInstallClients(); });
            if ([process isEqual:@"com.google.ios.youtube"]) {
                %init(TAYoutubeRootGuard);
                dispatch_async(dispatch_get_main_queue(), ^{ TAListenYouTubeTarget(); });
            }
            if ([process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
                %init(TACompactHome);
                if (NSClassFromString(@"CPSNavigationBar")) { %init(TAGoogleNavigation); }
                if (NSClassFromString(@"CPSImageRowCell")) { %init(TAImageRowExperiment); }
                Class cls=NSClassFromString(@"CPUINowPlayingView");
                SEL selector=NSSelectorFromString(@"recalculateLayout:allowsAlbumArt:hasDataSource:viewArea:safeArea:rightHandDrive:");
                Method method=class_getInstanceMethod(cls,selector);
                const char *encoding=method ? method_getTypeEncoding(method) : NULL;
                if (encoding && strcmp(encoding,"v96@0:8B16B20B24{CGRect={CGPoint=dd}{CGSize=dd}}28{CGRect={CGPoint=dd}{CGSize=dd}}60B92")==0) {
                    %init(TANowPlayingExperiment);
                    TALog(@"NATIVE LAYOUT HOOK enabled");
                } else TALog(@"NATIVE LAYOUT HOOK skipped encoding=%s",encoding ?: "missing");
                dispatch_async(dispatch_get_main_queue(), ^{ TAListenTemplateTargets(); });
            }
            return;
        }
        if (![process isEqual:@"com.apple.CarPlayApp"]) return;
        records = [NSMutableDictionary new]; order = [NSMutableArray new]; controls = [TAControls new];
        %init(TAHost);
        dispatch_async(dispatch_get_main_queue(), ^{ TAKBInstallHost(); });
        dispatch_async(dispatch_get_main_queue(), ^{ TALog(@"LOADED"); for (NSString *b in TAClientBundles()) TASetLayoutTarget(b, CGSizeZero); TAListenClients(); TATick(); });
    }
}
