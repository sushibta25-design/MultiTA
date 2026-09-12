// DuoPhone V6.3.1 — stability update on device-confirmed V6.3 split/touch.
// Keeps the same presentation creation and aspect-fit geometry as V6.3.
// Replace only Tweak.xm. Package metadata stays unchanged.
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
    NSData *data = [[NSString stringWithFormat:@"[CarPlay:%d] V6.3.1 %@\n", getpid(), message]
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
static UIWindow *gButtonWindow, *gSplitWindow;
static UIView *gLeftPane, *gRightPane, *gDivider;
static UIButton *gButton;
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
    if (!view || gNativeSize.width <= 0 || gNativeSize.height <= 0) return;
    // Preserve native app geometry; first test scales the full surface to fit.
    view.transform = CGAffineTransformIdentity;
    view.bounds = (CGRect){CGPointZero, gNativeSize};
    CGFloat scale = MIN(pane.bounds.size.width / gNativeSize.width,
                        pane.bounds.size.height / gNativeSize.height);
    view.center = CGPointMake(CGRectGetMidX(pane.bounds), CGRectGetMidY(pane.bounds));
    view.transform = CGAffineTransformMakeScale(scale, scale);
}
static void DPLayout(void) {
    if (!gSplitWindow) return;
    CGFloat width = gSplitWindow.bounds.size.width, height = gSplitWindow.bounds.size.height;
    CGFloat split = floor(width * gRatio), top = 30.0;
    gLeftPane.frame = CGRectMake(0, top, MAX(1, split - 3), MAX(1, height - top));
    gRightPane.frame = CGRectMake(split + 3, top, MAX(1, width - split - 3), MAX(1, height - top));
    gDivider.frame = CGRectMake(split - 12, top, 24, MAX(1, height - top));
    gStatus.frame = CGRectMake(6, 0, MAX(1, width - 72), 30);
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
- (void)start;
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
- (void)start {
    if (gRunning || gOrder.count < 2 || !gSession || DPDashboard() != gSession) return;
    DPRecord *left = gRecords[gOrder[gOrder.count - 2]], *right = gRecords[gOrder.lastObject];
    if (!left.valid || !right.valid || left.controller == right.controller) return;
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
    root.backgroundColor = UIColor.blackColor;
    gLeftPane = [UIView new]; gRightPane = [UIView new];
    gLeftPane.clipsToBounds = YES; gRightPane.clipsToBounds = YES;
    [root addSubview:gLeftPane]; [root addSubview:gRightPane];
    gStatus = [UILabel new]; gStatus.text = @"Đang mở hai ứng dụng…";
    gStatus.textColor = UIColor.whiteColor; gStatus.font = [UIFont systemFontOfSize:11];
    [root addSubview:gStatus];
    UIButton *exit = [UIButton buttonWithType:UIButtonTypeSystem];
    [exit setTitle:@"Thoát" forState:UIControlStateNormal];
    exit.frame = CGRectMake(gSplitWindow.bounds.size.width - 64, 0, 64, 30);
    [exit addTarget:self action:@selector(stop) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:exit];
    gDivider = [UIView new]; gDivider.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
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
    BOOL ready = gOrder.count == 2 && gRecords[gOrder[0]].valid && gRecords[gOrder[1]].valid;
    gButtonWindow.hidden = gRunning || !ready;
}
static void DPCapture(id controller, id settings) {
    if (gOwnCall || ![settings isKindOfClass:NSDictionary.class]) return;
    // Ignore suspended prewarming. Only retain observed explicit launch settings.
    if (!settings[@"DBActivationSettingLaunchSource"]) return;
    NSString *sid = DPValue(controller, @"sceneID"), *bundle = DPBundle(sid);
    if (!bundle) return;
    NSDictionary *copy = [settings copy];
    NSUInteger epoch = gSessionEpoch;
    void (^capture)(void) = ^{
        if (epoch != gSessionEpoch || !gSession || DPDashboard() != gSession) return;
        if (gRunning) return;
        DPRecord *record = [DPRecord new];
        record.controller = controller; record.sid = sid; record.bundle = bundle; record.settings = copy;
        record.valid = YES;
        gRecords[bundle] = record;
        [gOrder removeObject:bundle]; [gOrder addObject:bundle];
        while (gOrder.count > 2) {
            [gRecords removeObjectForKey:gOrder.firstObject]; [gOrder removeObjectAtIndex:0];
        }
        DPLog(@"CAPTURE bundle=%@ source=%@ suspended=%@", bundle,
              copy[@"DBActivationSettingLaunchSource"], copy[@"DBActivationSettingSuspended"]);
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
        [gButton addTarget:gControls action:@selector(start) forControlEvents:UIControlEventTouchUpInside];
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
