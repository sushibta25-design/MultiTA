// MultiTA 0.47.2 (beta, from TAduo) STABLE BASE: no code inside apps, per-app native size, bridged apps must be open first.
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <math.h>
#import <string.h>
#import <notify.h>
#import <objc/runtime.h>
#import <fcntl.h>
#import <dlfcn.h>
#import <unistd.h>
#import <sys/resource.h>

static void TALog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *s = [[NSString alloc] initWithFormat:format arguments:args]; va_end(args);
    // Never perform file IO on CarPlay's UI/event thread. O_APPEND also avoids
    // seek/write races between the host and native-app processes sharing a log.
    static dispatch_queue_t queue; static dispatch_once_t once;
    dispatch_once(&once, ^{ queue=dispatch_queue_create("com.sushibta.multita.beta.log",DISPATCH_QUEUE_SERIAL); });
    NSDate *time=NSDate.date;
    dispatch_async(queue, ^{
        @autoreleasepool {
            NSString *path=[NSBundle.mainBundle.bundleIdentifier isEqual:@"com.apple.CarPlayTemplateUIHost"] ? @"/var/mobile/MultiTA-beta-template.log" : @"/var/mobile/MultiTA-beta.log";
            static NSUInteger writes;
            if ((writes++ % 64)==0 && [[NSFileManager.defaultManager attributesOfItemAtPath:path error:nil] fileSize]>1024*1024) {
                [NSFileManager.defaultManager removeItemAtPath:[path stringByAppendingString:@".1"] error:nil];
                [NSFileManager.defaultManager moveItemAtPath:path toPath:[path stringByAppendingString:@".1"] error:nil];
            }
            NSData *data=[[NSString stringWithFormat:@"%@ [MultiTA 0.47.2] %@\n",time,s] dataUsingEncoding:NSUTF8StringEncoding];
            int fd=open(path.fileSystemRepresentation,O_WRONLY|O_CREAT|O_APPEND,0644);
            if (fd>=0) { (void)write(fd,data.bytes,data.length); close(fd); }
        }
    });
}
// Heavy TAduo-era diagnostics (view-tree/constraint dumps, per-layout client
// reports, touch traces, multi-stage resize observations) cost CPU and log IO
// in every CarPlay app. Off by default since 0.34.
static const BOOL kTADiag=NO;
static id TAValue(id o, NSString *key) {
    @try { return [o valueForKey:key]; } @catch (__unused NSException *e) { return nil; }
}
// Apply this to captured scenes AND installed catalog entries. CarPlay's
// shell pages are not standalone applications that can occupy a split pane.
static BOOL TASelectableBundle(NSString *bundle) {
    if (![bundle isKindOfClass:NSString.class] || ![bundle containsString:@"."]) return NO;
    NSString *key=bundle.lowercaseString;
    if ([key hasPrefix:@"com.apple.carplay"]) return NO;
    return ![@[@"com.apple.springboard", @"com.apple.backboardd",
               @"com.apple.home", @"com.apple.siri", @"com.apple.siriviewservice", @"com.apple.incallservice"] containsObject:key];
}
static NSString *TABundle(id controller) {
    NSString *sid = TAValue(controller, @"sceneID");
    if (![sid isKindOfClass:NSString.class] || ![sid hasPrefix:@"Car["]) return nil;
    NSArray *parts = [sid componentsSeparatedByString:@":"];
    NSString *bundle = parts.count == 2 ? parts[1] :
        (parts.count == 3 && [parts[1] isEqual:@"com.apple.CarPlayTemplateUIHost"] ? parts[2] : nil);
    if (!TASelectableBundle(bundle)) return nil;
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
@property(nonatomic) BOOL foregroundIssued;
@property(nonatomic) BOOL userLaunched;   // opened by the user this session (launch source present)
@property(nonatomic) BOOL noSurface;      // last attach produced no picture: relaunch via Dashboard
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
// Resizable split. splitRatio = divider centre / display width, kept for the
// SpringBoard lifetime so Fold/Home resume with the same proportions.
// Limits are defined in points so every display feels the same. The small
// wired unit (426pt wide) keeps exactly 30/70; a wide wireless unit (640pt)
// gets 20/80, i.e. the same 128pt minimum pane instead of a 192pt one.
static const CGFloat kTAMinPane=128, kTACollapseEdge=60, kTAPullCancel=72;
static CGFloat TADisplayWidth(void);
static CGFloat TAMinRatioFor(CGFloat w) { return MIN(0.30,MAX(0.18,kTAMinPane/MAX(1,w))); }
#define kTAMinRatio (TAMinRatioFor(TADisplayWidth()))
#define kTAMaxRatio (1-TAMinRatioFor(TADisplayWidth()))
static CGFloat splitRatio=0.5, dragStartRatio=0.5;
static UIView *dividerView, *dividerGrip;
static UIView *dragCovers[2];
// Edge pull: while an app is open natively, a thin handle sits on the right
// edge. Long-press it and drag left: a dark rail follows the finger, the open
// app shrinks to the left pane and the companion app appears on the right.
// Nothing is attached until the finger lifts; lifting early cancels cleanly.
static BOOL staged;                       // edge pull in progress
static NSString *pullCurrent, *pullCompanion, *nativeForeground;
static NSInteger pullCurrentSlot;
// Picking an app with no live scene opens it natively. Remember which side
// it was meant for and which app stays on the other side, so the pair is
// rebuilt (automatically for template apps, or by the next edge pull).
static NSString *openBundle, *openKeep;
static NSInteger openSlot;
static NSTimeInterval openTime;
// In-pane launch (0.39): an app with no live scene is launched by Dashboard
// while the split stays up; the pane shows "Đang mở…" and adopts the app as
// soon as its scene exists. During that short window Dashboard's attempt to
// background an app that is shown in a pane is declined.
static NSString *launchBundle;
static NSInteger launchSlot;
static NSTimeInterval launchGuardUntil, launchStart, launchSurfaceSince;
static BOOL allowLaunchInSplit;
static UIWindow *edgeWindow;       // Dock swipe zone (0.47; was the right-edge handle)
static BOOL pullFromLeft;          // current pull started in the Dock and moves right
static BOOL layoutMirror;
static CGFloat dockZoneRight;      // right edge of the CarPlay Dock, in display points
static UIImageView *railIcon;
// Capsule handle (visual part fades after 3s; its touch area stays live).
static UIView *lockVisual, *swapVisual;
static const CGFloat kTASwapArea=46;   // top part of the handle container
static NSUInteger chromeToken;
static BOOL chromeHold;
// Change mode: double/triple tap on the handle shows a change badge on both panes.
static UIView *changeOverlays[2];
static UIView *actionPanel;   // custom Tác vụ page
static NSTimeInterval changeModeSince;
static const CGFloat kTAPaneGap=4;
// Handle taps are counted manually. Head-unit touches wobble and arrive late,
// so a tap may be delivered as a tiny pan; both paths feed this counter.
static NSUInteger lockTaps, lockTapSerial;
static BOOL dragMoved;
// Hold ≥1s on the divider/handle opens the Tác vụ page (greeting card).
static NSUInteger holdSerial;
static BOOL holdFired;
static const CGFloat kTADragSlop=9;
static __weak UIWindowScene *dashboard;
static BOOL running, ownCall;
static NSArray<NSString *> *resumeBundles;
static NSString *resumeCandidate;
static NSUInteger generation;
static NSString *primeBundle;
static NSArray<NSString *> *primeSelection, *primePrevious;
static BOOL primeSawForeground;
static NSTimeInterval lastNativeTransition;

static NSUInteger slotRequests[2];
static NSMutableArray<NSArray<NSString *> *> *recentPairs;
static void TAStop(NSString *reason);
static void TAClearSlot(NSInteger slot, NSString *reason);
static BOOL TAAttachPending(void) { return slots[0].attaching || slots[1].attaching; }
static NSArray<NSString *> *TAClientBundles(void);
static void TASetLayoutTarget(NSString *bundle, CGSize size);
static void TAUpdateEdge(void);
static void TAKickVideo(NSString *bundle, NSString *why);
static NSMutableSet<NSString *> *hostedBundles;   // non-template apps shown in a pane this session
// Largest app frame Dashboard has used natively on this display. A scene
// frame smaller than this outside the split is one we left behind.
static NSMutableDictionary<NSString *,NSValue *> *TANativeSizes;   // per app, learned outside the split
static CGSize TANativeSizeFor(NSString *bundle) { return bundle ? [TANativeSizes[bundle] CGSizeValue] : CGSizeZero; }
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
                if (kTADiag) TAObserve(r, token, serial, @"after-transaction");
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
    if (splitWindow) {
        CGSize limit=splitWindow.bounds.size;
        size=CGSizeMake(MIN(size.width,limit.width-6),MIN(size.height,limit.height-6));
    }
    id scene = TAValue(r.controller, @"scene");
    if (!r.frameCaptured) {
        CGRect original = CGRectZero;
        if (!TAReadFrame(scene, &original)) { TALog(@"RESIZE NO FRAME %@", r.bundle); return; }
        CGSize known=TANativeSizeFor(r.bundle);
        if (known.width>0 && original.size.width<known.width-1) {
            TALog(@"ORIGINAL FIXED %@ read=%@ native=%@",r.bundle,NSStringFromCGSize(original.size),NSStringFromCGSize(known));
            original=(CGRect){original.origin,known};
        }
        r.scene = scene; r.originalFrame = original; r.frameCaptured = YES;
    }
    if (r.scene != scene) { for (NSInteger i=0;i<2;i++) if (slots[i]==r) TAClearSlot(i,@"resize scene changed"); return; }
    r.targetSize = size;
    TASetLayoutTarget(r.bundle, size);
    NSUInteger token = generation, serial = ++r.resizeSerial;
    TATransact(r, token, serial, 0);
    for (NSNumber *delay in kTADiag ? @[@0.25, @1.0, @3.0] : @[]) {
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
    return @{@"com.apple.Maps":@"Apple Maps",@"com.google.Maps":@"Google Maps",@"vn.vietmap.live":@"Vietmap Live",@"com.google.ios.youtubemusic":@"YouTube Music",@"com.google.ios.youtube":@"YouTube",@"com.apple.Music":@"Nhạc",@"vn.com.vng.zingalo":@"Zalo"}[bundle] ?: bundle;
}
static void TARememberPair(void) {
    if (!slots[0].presentation || !slots[1].presentation) return;
    NSArray *pair=@[slots[0].bundle,slots[1].bundle];
    if (!recentPairs) recentPairs=[NSMutableArray new];
    [recentPairs removeObject:pair]; [recentPairs insertObject:pair atIndex:0];
    while (recentPairs.count>4) [recentPairs removeLastObject];
}
// Catalog and launch use the same DBApplicationInfo/DBApplicationLaunchInfo
// contract inspected in MiniTa. No synthetic CarPlay entitlements or roles.
static __weak id nativeDashboard;
static NSMutableDictionary<NSString *,id> *catalog;
static NSMutableDictionary<NSString *,NSNumber *> *genres;   // App Store genre id per bundle
static BOOL TAObjectMethod(id object, SEL sel, NSUInteger arguments) {
    NSMethodSignature *sig=[object methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments!=arguments+2 || sig.methodReturnType[0]!='@') return NO;
    for (NSUInteger i=2;i<sig.numberOfArguments;i++) if ([sig getArgumentTypeAtIndex:i][0]!='@') return NO;
    return YES;
}
static BOOL TAVoidObjects(id object, SEL sel, NSUInteger arguments) {
    NSMethodSignature *sig=[object methodSignatureForSelector:sel];
    if (!sig || sig.numberOfArguments!=arguments+2 || strcmp(sig.methodReturnType,@encode(void))) return NO;
    for (NSUInteger i=2;i<sig.numberOfArguments;i++) if ([sig getArgumentTypeAtIndex:i][0]!='@') return NO;
    return YES;
}
static BOOL TADirectReady(TARecord *r) {
    if (!r || !r.activation || ![TABundle(r.controller) isEqual:r.bundle]) return NO;
    NSString *sid=TAValue(r.controller,@"sceneID");
    NSString *display=[sid componentsSeparatedByString:@":"].firstObject;
    if (!display.length || ![dashboard.session.persistentIdentifier hasSuffix:display]) return NO;
    CGRect frame=CGRectZero;
    return TAReadFrame(TAValue(r.controller,@"scene"),&frame) &&
        TAVoidObjects(r.controller,NSSelectorFromString(@"foregroundSceneWithSettings:completion:"),2);
}
static void TARefreshCatalog(void) {
    if (!catalog) catalog=[NSMutableDictionary new];
    Class workspaceClass=NSClassFromString(@"LSApplicationWorkspace"), infoClass=NSClassFromString(@"DBApplicationInfo");
    SEL factory=NSSelectorFromString(@"defaultWorkspace"), list=NSSelectorFromString(@"allInstalledApplications");
    if (!TAObjectMethod(workspaceClass,factory,0) || !infoClass) return;
    @try {
        id workspace=((id(*)(id,SEL))objc_msgSend)(workspaceClass,factory);
        if (!TAObjectMethod(workspace,list,0)) return;
        id proxies=((id(*)(id,SEL))objc_msgSend)(workspace,list);
        if (![proxies isKindOfClass:NSArray.class]) return;
        NSMutableDictionary *next=[NSMutableDictionary new];
        NSUInteger examined=0;
        for (id proxy in proxies) {
            if (++examined>600) break;
            NSString *bundle=TAValue(proxy,@"bundleIdentifier");
            if (!TASelectableBundle(bundle)) continue;
            id genre=TAValue(proxy,@"genreID");
            if ([genre respondsToSelector:@selector(integerValue)] && [genre integerValue]>0) {
                if (!genres) genres=[NSMutableDictionary new];
                genres[bundle]=@([genre integerValue]);
            }
            @try {
                id allocated=[infoClass alloc]; SEL initializer=NSSelectorFromString(@"initWithApplicationProxy:");
                if (!TAObjectMethod(allocated,initializer,1)) break;
                id info=((id(*)(id,SEL,id))objc_msgSend)(allocated,initializer,proxy);
                id valid=TAValue(info,@"isValid"); id declaration=TAValue(info,@"carPlayDeclaration");
                BOOL known=[TAClientBundles() containsObject:bundle];
                // Captured apps remain selectable even if a bridge has no
                // standard declaration. Never list every installed iPhone app.
                if (info && (([valid respondsToSelector:@selector(boolValue)] && [valid boolValue] && declaration) || known || records[bundle])) next[bundle]=info;
            } @catch (__unused NSException *e) {}
        }
        catalog=next;
        TALog(@"CATALOG installed=%lu carplayCandidates=%lu owner=%@",(unsigned long)[proxies count],(unsigned long)catalog.count,NSStringFromClass([nativeDashboard class]));
    } @catch (NSException *e) { TALog(@"CATALOG ERROR %@",e.name); }
}
// Picker priority: 0 = navigation, 1 = entertainment (music/video/podcast/
// radio), 2 = everything else. Known bundle IDs first, then App Store genre
// (6010 Navigation, 6011 Music, 6016 Entertainment, 6008 Photo & Video),
// then bundle-ID keywords. Within a group: most recently used first.
static NSInteger TAAppPriority(NSString *bundle) {
    NSString *b=bundle.lowercaseString;
    static NSArray *nav, *fun, *navWords, *funWords;
    if (!nav) {
        nav=@[@"com.apple.maps",@"com.google.maps",@"vn.vietmap.live",@"com.waze.iphone",@"com.here.app.maps",@"com.sygic.aura",@"com.grabtaxi.passenger"];
        fun=@[@"com.apple.music",@"com.apple.podcasts",@"com.apple.tv",@"com.apple.ibooks",@"com.google.ios.youtube",@"com.google.ios.youtubemusic",@"com.spotify.client",@"com.audible.iphone",@"com.soundcloud.touchapp"];
        navWords=@[@"map",@"navi",@"gps",@"vietmap",@"waze",@"route",@"traffic"];
        funWords=@[@"music",@"youtube",@"spotify",@"podcast",@"radio",@"zing",@"mp3",@"nhaccuatui",@"nct",@"audio",@"video",@"movie",@"film",@"sound",@"tiktok"];
    }
    if ([nav containsObject:b]) return 0;
    if ([fun containsObject:b]) return 1;
    NSInteger genre=genres[bundle].integerValue;
    if (genre==6010) return 0;
    if (genre==6011 || genre==6016 || genre==6008) return 1;
    for (NSString *w in navWords) if ([b containsString:w]) return 0;
    for (NSString *w in funWords) if ([b containsString:w]) return 1;
    return 2;
}
static NSArray<NSString *> *TAPickerBundles(void) {
    TARefreshCatalog();
    NSMutableOrderedSet *all=[NSMutableOrderedSet orderedSetWithArray:[[order reverseObjectEnumerator] allObjects]];
    [all addObjectsFromArray:[[catalog allKeys] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)]];
    NSMutableArray *selectable=[NSMutableArray new];
    for (NSString *bundle in all) if (TASelectableBundle(bundle)) [selectable addObject:bundle];
    // Stable sort keeps "recent first, then A–Z" inside each priority group.
    return [selectable sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        NSInteger pa=TAAppPriority(a), pb=TAAppPriority(b);
        return pa<pb ? NSOrderedAscending : (pa>pb ? NSOrderedDescending : NSOrderedSame);
    }];
}
static BOOL TANativeLaunch(NSString *bundle) {
    // A Dashboard launch is never allowed while two hosted panes are active.
    if (running && !allowLaunchInSplit) { TALog(@"PREPARE rejected native launch during split %@",bundle); return NO; }
    id info=catalog[bundle]; Class launchClass=NSClassFromString(@"DBApplicationLaunchInfo");
    SEL init=NSSelectorFromString(@"initWithApplication:activationSettings:"), launch=NSSelectorFromString(@"_launchAppWithInfo:forURL:");
    id allocated=[launchClass alloc];
    if (!info || !TAObjectMethod(allocated,init,2) || !TAVoidObjects(nativeDashboard,launch,2)) {
        TALog(@"NATIVE REQUEST unsupported bundle=%@ owner=%@ info=%d",bundle,NSStringFromClass([nativeDashboard class]),info!=nil); return NO;
    }
    @try {
        id request=((id(*)(id,SEL,id,id))objc_msgSend)(allocated,init,info,@{@"DBActivationSettingLaunchSource":@"MultiTA"});
        if (!request) return NO;
        TALog(@"NATIVE REQUEST bundle=%@ requestClass=%@",bundle,NSStringFromClass([request class]));
        ((void(*)(id,SEL,id,id))objc_msgSend)(nativeDashboard,launch,request,nil); TALog(@"NATIVE REQUEST RETURNED %@",bundle); return YES;
    } @catch (NSException *e) { TALog(@"NATIVE REQUEST ERROR %@ bundle=%@",e.name,bundle); return NO; }
}
// Remote-render context ids hosted under a layer tree (LayerHost layers).
static void TACollectContexts(CALayer *layer, NSUInteger depth, NSInteger *budget, NSMutableSet *out) {
    if (!layer || depth>14 || --*budget<0) return;
    if ([NSStringFromClass(layer.class) containsString:@"LayerHost"]) {
        id context=TAValue(layer,@"contextId");
        if ([context respondsToSelector:@selector(unsignedLongLongValue)] && [context unsignedLongLongValue]!=0) [out addObject:context];
    }
    for (CALayer *child in layer.sublayers) TACollectContexts(child,depth+1,budget,out);
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
static void TAShowChrome(void) {
    if (!running || !floatingActions) return;
    floatingActions.hidden=NO;
    NSUInteger token=++chromeToken;
    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:^{
        lockVisual.alpha=1; dividerGrip.alpha=1;
        swapVisual.alpha=(slots[0].presentation && slots[1].presentation) ? 1 : 0.35;
    } completion:nil];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,3*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (!running || chromeHold || token!=chromeToken) return;
        // Only the visuals fade. Hit areas remain active (alpha of the
        // touch containers is untouched), so a hidden handle still works.
        [UIView animateWithDuration:0.35 delay:0 options:UIViewAnimationOptionAllowUserInteraction animations:^{
            lockVisual.alpha=0; swapVisual.alpha=0; if (!staged) dividerGrip.alpha=0;
        } completion:nil];
    });
}
static void TARevealActions(void) { TAShowChrome(); }
@interface TASplitWindow : UIWindow
@end
@implementation TASplitWindow
- (void)sendEvent:(UIEvent *)event {
    [super sendEvent:event];
    // Reveal the handle only for touches that begin near the divider, so
    // normal use of either app lets it stay hidden.
    if (event.type!=UIEventTypeTouches || !dividerView) return;
    for (UITouch *touch in event.allTouches) {
        if (touch.phase!=UITouchPhaseBegan) continue;
        if (fabs([touch locationInView:self].x-dividerView.center.x)<48) { TAShowChrome(); break; }
    }
}
@end
@interface TAAppTile : UIButton
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic) NSInteger slot;
@property(nonatomic) NSUInteger token;
@end
@implementation TAAppTile
@end
// Button that runs a block (used by the custom action panel).
@interface TABlockButton : UIButton
@property(nonatomic,copy) void (^handler)(void);
@end
@implementation TABlockButton
+ (instancetype)buttonWithHandler:(void (^)(void))handler {
    TABlockButton *b=[self buttonWithType:UIButtonTypeCustom];
    b.handler=handler; [b addTarget:b action:@selector(fire) forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)fire { if (self.handler) self.handler(); }
@end
static UIFont *TARoundedFont(CGFloat size, UIFontWeight weight) {
    UIFont *font=[UIFont systemFontOfSize:size weight:weight];
    UIFontDescriptor *rounded=[font.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
    return rounded ? [UIFont fontWithDescriptor:rounded size:size] : font;
}
// Frosted circular/capsule button with an SF Symbol.
static UIButton *TAGlassButton(NSString *symbol, CGFloat point, CGRect frame, SEL action) {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
    b.frame=frame; b.layer.cornerRadius=MIN(frame.size.width,frame.size.height)/2; b.clipsToBounds=YES;
    b.layer.borderWidth=0.5; b.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.22].CGColor;
    b.backgroundColor=[UIColor colorWithWhite:0.16 alpha:0.92];
    UIImage *image=[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:point weight:UIImageSymbolWeightBold]];
    [b setImage:image forState:UIControlStateNormal]; b.tintColor=UIColor.whiteColor;
    [b bringSubviewToFront:b.imageView];
    if (action) [b addTarget:nil action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}
static NSArray<NSString *> *pickerItems[2];
static NSInteger pickerPages[2];
static UIView *appPickers[2];
static NSString *retryTargets[2];
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

// ---- Resizable divider -------------------------------------------------
// Divider is ~3% of display width (even number of points, min 16pt). The
// hit area extends 6pt into each pane so it is easy to grab while driving.
@interface TADividerView : UIView
@end
@implementation TADividerView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return CGRectContainsPoint(CGRectInset(self.bounds,-6,0),point);
}
@end
static CGFloat TADividerWidth(CGFloat width) { return MAX(16,2*round(width*0.015)); }
static CGFloat TADisplayWidth(void) {
    if (splitWindow) return splitWindow.bounds.size.width;
    return dashboard ? dashboard.coordinateSpace.bounds.size.width : 426;
}
static CGFloat TAClampRatio(CGFloat r) { return MIN(kTAMaxRatio,MAX(kTAMinRatio,r)); }
// UIScrollView-style resistance past the 30/70 limits: the divider keeps
// following the finger a little, then springs back to the limit on release.
static CGFloat TARubber(CGFloat over, CGFloat limit) { return (1.0-1.0/(over*0.55/limit+1.0))*limit; }
// Past 30/70 the divider still follows at ~55% speed so it can be pulled
// toward an edge; releasing beyond kTACollapse closes the split.
// Collapse when the smaller pane would be under ~60pt (0.86 on 426pt, 0.91 on 640pt).
#define kTACollapse (MAX(kTAMaxRatio+0.05,1-kTACollapseEdge/MAX(1,TADisplayWidth())))
static CGFloat TAVisualRatio(CGFloat raw) {
    if (raw<kTAMinRatio) return MAX(0.03,kTAMinRatio-(kTAMinRatio-raw)*0.55);
    if (raw>kTAMaxRatio) return MIN(0.97,kTAMaxRatio+(raw-kTAMaxRatio)*0.55);
    return raw;
}
static CGFloat TARailWidth(CGFloat width) { return MAX(56,round(width*0.12)); }
static UIColor *TADividerColor(void) { return staged ? [UIColor colorWithWhite:0.035 alpha:1] : UIColor.clearColor; }
// Only moves containers. Hosted presentations keep their committed frame
// until TACommitSplit, so no scene resize happens per touch-move.
static void TALayoutAt(CGFloat cx, CGFloat dw) {
    if (!splitWindow || !panes[0] || !panes[1]) return;
    CGSize size=splitWindow.bounds.size; CGFloat inset=3, height=size.height-2*inset;
    if (layoutMirror) cx=size.width-cx;   // a Dock pull is the right-edge pull, mirrored
    CGFloat normal=TADividerWidth(size.width), rail=TARailWidth(size.width);
    // Visual gap between panes is only 4pt; the divider view keeps its full
    // width (plus 6pt each side) as touch area and overlaps the pane edges.
    // While the pull rail is wider than normal, the gap grows with it.
    CGFloat gap=dw>normal ? kTAPaneGap+(dw-normal) : kTAPaneGap;
    CGFloat lw=cx-gap/2-inset;
    panes[0].hidden=lw<2; panes[0].frame=CGRectMake(inset,inset,MAX(1,lw),height);
    CGFloat rx=cx+gap/2, rw=size.width-inset-rx;
    panes[1].hidden=rw<2; panes[1].frame=CGRectMake(rx,inset,MAX(1,rw),height);
    dividerView.frame=CGRectMake(cx-dw/2,0,dw,size.height);
    dividerGrip.frame=CGRectMake((dw-2)/2,18,2,MAX(0,size.height-36));
    CGFloat look=rail>normal ? MIN(1,MAX(0,(dw-normal)/(rail-normal))) : 0;
    railIcon.frame=CGRectMake((dw-40)/2,14,40,40); railIcon.alpha=staged ? look : 0;
    dividerGrip.hidden=look>0.5;
    if (floatingActions) floatingActions.center=CGPointMake(cx,floatingActions.center.y);
    for (NSInteger i=0;i<2;i++) { choose[i].frame=panes[i].bounds; dragCovers[i].frame=panes[i].bounds; }
}
static void TALayoutSplit(CGFloat ratio) {
    if (!splitWindow) return;
    CGFloat width=splitWindow.bounds.size.width;
    TALayoutAt(round(width*ratio),TADividerWidth(width));
}
// Divider centre follows the finger. From the right edge down to 70% the
// rail narrows into the normal divider; past that it is a normal 30–70% drag.
static CGFloat TAPullRestRatio(void) {
    CGFloat width=MAX(1,splitWindow.bounds.size.width);
    return 1-TARailWidth(width)/2/width;
}
static void TALayoutPullFromRight(CGFloat raw);
static void TALayoutPull(CGFloat raw) {
    if (!pullFromLeft) { TALayoutPullFromRight(raw); return; }
    layoutMirror=YES; TALayoutPullFromRight(1-raw); layoutMirror=NO;
}
static void TALayoutPullFromRight(CGFloat raw) {
    if (!splitWindow) return;
    CGFloat width=splitWindow.bounds.size.width, rest=TAPullRestRatio();
    CGFloat normal=TADividerWidth(width), rail=TARailWidth(width);
    if (raw<=kTAMaxRatio) { TALayoutAt(round(width*TAVisualRatio(raw)),normal); return; }
    if (raw>rest) raw=rest+TARubber(raw-rest,0.02);
    CGFloat t=MIN(1,MAX(0,(rest-raw)/(rest-kTAMaxRatio)));
    TALayoutAt(round(width*raw),round(rail+(normal-rail)*t));
}
static void TAShowCovers(BOOL show) {
    for (NSInteger i=0;i<2;i++) {
        if (show) {
            if (!slots[i].presentation || !panes[i]) continue;
            if (!dragCovers[i]) {
                UIView *cover=[[UIView alloc] initWithFrame:panes[i].bounds];
                cover.backgroundColor=[UIColor colorWithWhite:0.07 alpha:1]; cover.userInteractionEnabled=NO; cover.alpha=0;
                UIImageView *icon=[[UIImageView alloc] initWithImage:TAAppIcon(slots[i].bundle)];
                icon.frame=CGRectMake(0,0,52,52); icon.layer.cornerRadius=12; icon.clipsToBounds=YES;
                icon.center=CGPointMake(CGRectGetMidX(cover.bounds),CGRectGetMidY(cover.bounds));
                icon.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;
                [cover addSubview:icon]; [panes[i] addSubview:cover]; dragCovers[i]=cover;
            }
            [panes[i] bringSubviewToFront:dragCovers[i]];
            [UIView animateWithDuration:0.12 animations:^{ dragCovers[i].alpha=1; }];
        } else if (dragCovers[i]) {
            UIView *cover=dragCovers[i]; dragCovers[i]=nil;
            [UIView animateWithDuration:0.2 animations:^{ cover.alpha=0; } completion:^(__unused BOOL f){ [cover removeFromSuperview]; }];
        }
    }
}

static void TAClearSlot(NSInteger slot, NSString *reason) {
    ++slotRequests[slot]; retryTargets[slot]=nil;
    TARecord *r=slots[slot]; r.attaching=NO; slots[slot]=nil;
    BOOL previous=ownCall; ownCall=YES; TACleanup(r); ownCall=previous;
    choose[slot].hidden=NO; choose[slot].enabled=YES;
    [choose[slot] setImage:nil forState:UIControlStateNormal];
    [choose[slot] setTitle:@"Chạm để chọn ứng dụng" forState:UIControlStateNormal];
    TALog(@"SLOT CLEAR side=%ld reason=%@",(long)slot,reason);
}
static void TAStop(NSString *reason) {
    if (primeBundle) { primeBundle=nil; primeSelection=nil; primePrevious=nil; primeSawForeground=NO; ++generation; }
    resumeBundles=nil; resumeCandidate=nil;
    if (!running) return;
    running = NO; ++generation;
    for (NSInteger i=0;i<2;i++) { [appPickers[i] removeFromSuperview]; appPickers[i]=nil; pickerItems[i]=nil; pickerPages[i]=0; retryTargets[i]=nil; }
    TALog(@"STOP %@", reason);
    BOOL previous = ownCall; ownCall = YES;
    for (NSInteger i = 0; i < 2; i++) { TACleanup(slots[i]); slots[i] = nil; panes[i] = nil; choose[i] = nil; }
    ownCall = previous;
    dividerView = nil; dividerGrip = nil; railIcon = nil; dragCovers[0] = dragCovers[1] = nil;
    staged = NO; pullFromLeft = NO; pullCurrent = nil; pullCompanion = nil;
    lockVisual = nil; swapVisual = nil; chromeHold = NO; ++chromeToken; changeOverlays[0] = changeOverlays[1] = nil;
    lockTaps = 0; ++lockTapSerial; dragMoved = NO; actionPanel = nil;
    launchBundle = nil; launchGuardUntil = 0;
    splitWindow.hidden = YES; splitWindow = nil; floatingActions = nil;
    buttonWindow.hidden = YES;   // square launcher retired; edge pull is the entry
    TAUpdateEdge();
}
// Native Home releases presentations and restores geometry, but retains the
// selected bundle IDs. Never retain old scene pointers as a resume snapshot.
static void TASuspend(NSString *reason) {
    if (!running) return;
    NSArray *selection=@[slots[0].bundle ?: @"",slots[1].bundle ?: @""];
    TAStop(reason);
    resumeBundles=selection;
    TALog(@"SESSION SAVED left=%@ right=%@",selection[0],selection[1]);
    buttonWindow.hidden=YES;
}
@interface TAControls : NSObject
- (void)start;
- (void)enter;
- (void)selectTile:(TAAppTile *)tile;
- (void)closePicker:(UIButton *)sender;
- (void)pickerPage:(UIButton *)sender;
- (void)renderPicker:(NSInteger)slot;
- (void)showActions;
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
- (void)prepare:(NSString *)bundle slot:(NSInteger)slot;
- (void)waitPreparation:(NSString *)bundle slot:(NSInteger)slot generation:(NSUInteger)token attempt:(NSUInteger)attempt;
- (void)stop;
- (void)restartSplit;
- (void)toggleActions;
- (void)snapshot;
- (void)pick:(UIButton *)sender;
- (void)attach:(NSString *)bundle slot:(NSInteger)slot;
- (void)waitAttach:(NSString *)bundle slot:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt;
- (void)retryPane:(NSInteger)slot;
- (void)failAttach:(NSInteger)slot bundle:(NSString *)bundle reason:(NSString *)reason;
- (void)paneAction:(UIButton *)sender;
- (void)dragDivider:(UIPanGestureRecognizer *)gesture;
- (void)resetDivider:(UITapGestureRecognizer *)gesture;
- (void)commitSplit:(CGFloat)ratio;
- (void)dockPull:(UIPanGestureRecognizer *)gesture;
- (BOOL)beginPullFromLeft;
- (void)finishPull:(CGFloat)ratio;
- (void)collapseTo:(NSInteger)winner;
- (void)lockTap:(UITapGestureRecognizer *)gesture;
- (void)enterChangeMode;
- (void)registerLockTap;
- (void)changeTap:(UIGestureRecognizer *)gesture;
- (void)exitChangeMode;
- (void)closeActionPanel:(void (^)(void))then;
- (void)goHome;
- (void)swapFromHandle;
- (void)autoRejoin:(NSUInteger)attempt;
- (void)verifyPane:(NSInteger)slot record:(TARecord *)r generation:(NSUInteger)token attempt:(NSUInteger)attempt;
- (void)waitLaunch:(NSUInteger)attempt generation:(NSUInteger)token;
- (void)holdHandle:(UILongPressGestureRecognizer *)gesture;
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
        if (records[bundle] && !records[bundle].backgrounded && TADirectReady(records[bundle])) [self attach:bundle slot:i];
        else if (records[bundle] || catalog[bundle]) [self prepare:bundle slot:i];
        else TALog(@"RESUME missing slot=%ld bundle=%@",(long)i,bundle);
    }
}
- (void)enter {
    if (primeBundle) {
        NSArray *previous=[primePrevious copy];
        TAStop(@"cancel preparation"); [self start]; [self restoreSelection:previous]; return;
    }
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
    floatingActions.hidden=NO;
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
- (void)fold { floatingActions.hidden=NO; TARememberPair(); TASuspend(@"fold"); }
- (void)changeLeft { [self pick:choose[0]]; }
- (void)changeRight { [self pick:choose[1]]; }
- (void)replace:(NSString *)bundle slot:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || (!records[bundle] && !catalog[bundle])) return;
    if ([slots[slot].bundle isEqual:bundle]) { [self retryPane:slot]; return; }
    if ([slots[1-slot].bundle isEqual:bundle]) return;
    // 0.41: only an app that is on screen natively right now is adopted
    // directly. Pulling a backgrounded scene forward ourselves left the pane
    // showing only the wallpaper (YouTube, YouTube Music; 0.40 log); asking
    // Dashboard to open it inside the pane works for every app.
    TARecord *existing=records[bundle];
    if (!TADirectReady(existing) || existing.noSurface || existing.backgrounded) { [self prepare:bundle slot:slot]; return; }
    TAClearSlot(slot,@"replace"); [self attach:bundle slot:slot];
}
- (void)retryPane:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || slots[slot].attaching) return;
    NSString *bundle=[slots[slot].bundle copy] ?: [retryTargets[slot] copy]; if (!bundle.length) return;
    if (!TADirectReady(records[bundle]) || records[bundle].noSurface || records[bundle].backgrounded) { [self prepare:bundle slot:slot]; return; }
    TALog(@"MANUAL RETRY side=%ld bundle=%@",(long)slot,bundle);
    [self snapshot];
    TAClearSlot(slot,@"manual retry"); [self attach:bundle slot:slot];
}
- (void)swapSides {
    if (!running || !slots[0].presentation || !slots[1].presentation) return;
    for (NSInteger i=0;i<2;i++) { [appPickers[i] removeFromSuperview]; appPickers[i]=nil; }
    TARecord *left=slots[0]; slots[0]=slots[1]; slots[1]=left;
    ++slotRequests[0]; ++slotRequests[1];
    // Mirror the divider: each app keeps its own width, so no scene resize.
    splitRatio=1-splitRatio; TALayoutSplit(splitRatio);
    for (NSInteger i=0;i<2;i++) {
        [panes[i] addSubview:slots[i].presentation]; slots[i].presentation.frame=panes[i].bounds;
    }
    floatingActions.hidden=NO; TARememberPair(); TALog(@"SWAP completed");
}
- (void)showPairs {
    if (!running || splitWindow.rootViewController.presentedViewController) return;
    floatingActions.hidden=NO;
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
- (void)toggleActions { [self showActions]; }
- (void)snapshot {
    floatingActions.hidden = NO;
    TALog(@"MANUAL SNAPSHOT REQUEST");
    TADumpDock();
    notify_post("com.sushibta.multita.beta.snapshot");
}
- (void)restartSplit {
    if (!running || splitWindow.rootViewController.presentedViewController) return;
    TAStop(@"choose apps again");
    dispatch_async(dispatch_get_main_queue(), ^{ [self start]; });
}
- (void)start {
    if (running || primeBundle || !dashboard || TADashboard() != dashboard) return;
    CGRect bounds = dashboard.coordinateSpace.bounds;
    if (bounds.size.width < 150 || bounds.size.height < 100) return;
    TARefreshCatalog();
    running = YES; ++generation;
    splitWindow = [[TASplitWindow alloc] initWithWindowScene:dashboard];
    splitWindow.frame = bounds; splitWindow.windowLevel = UIWindowLevelAlert + 70;
    splitWindow.rootViewController = [UIViewController new];
    UIView *root = splitWindow.rootViewController.view; root.backgroundColor = UIColor.blackColor;
    // Scene target equals rounded pane bounds: 3pt outer inset, ~3% divider.
    // No image scaling or independent crop of the app content.
    splitRatio = TAClampRatio(splitRatio);
    CGFloat half = round(bounds.size.width * splitRatio);
    for (NSInteger i = 0; i < 2; i++) {
        panes[i] = [[UIView alloc] initWithFrame:CGRectZero];
        panes[i].layer.cornerRadius=8; panes[i].layer.cornerCurve=kCACornerCurveContinuous;
        panes[i].clipsToBounds = YES; [root addSubview:panes[i]];
        choose[i] = TAButton(@"Chạm để chọn ứng dụng", @selector(paneAction:));
        choose[i].titleLabel.font=[UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        choose[i].titleLabel.numberOfLines=2; choose[i].titleLabel.textAlignment=NSTextAlignmentCenter;
        choose[i].backgroundColor=[UIColor colorWithWhite:0.065 alpha:1];
        choose[i].tag = i; [panes[i] addSubview:choose[i]];
    }
    dividerView = [[TADividerView alloc] initWithFrame:CGRectZero];
    dividerView.backgroundColor = [UIColor colorWithWhite:0.1 alpha:1];
    dividerView.accessibilityLabel = @"Thanh chia màn hình";
    dividerGrip = [[UIView alloc] initWithFrame:CGRectZero];
    dividerGrip.backgroundColor = [UIColor colorWithWhite:1 alpha:0.35];
    dividerGrip.layer.cornerRadius = 1; dividerGrip.userInteractionEnabled = NO;
    [dividerView addSubview:dividerGrip]; [root addSubview:dividerView];
    [dividerView addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:controls action:@selector(dragDivider:)]];
    // Hold ≥1s on the divider opens the Tác vụ page. (Double-tap-to-5:5 was
    // removed: taps meant to reveal the divider kept resetting the ratio.)
    UILongPressGestureRecognizer *dividerHold = [[UILongPressGestureRecognizer alloc] initWithTarget:controls action:@selector(holdHandle:)];
    dividerHold.minimumPressDuration = 1.0; dividerHold.allowableMovement = 14; [dividerView addGestureRecognizer:dividerHold];
    railIcon = [[UIImageView alloc] initWithFrame:CGRectZero];
    railIcon.layer.cornerRadius = 10; railIcon.clipsToBounds = YES; railIcon.alpha = 0; railIcon.userInteractionEnabled = NO;
    [dividerView addSubview:railIcon];

    // Touch container: 56 wide; top 46pt = swap button, below = 88pt capsule
    // area. The capsule stays vertically centred on the display.
    floatingActions = [[UIView alloc] initWithFrame:CGRectMake(half-28,MAX(0,MAX(4,(bounds.size.height-88)/2)-kTASwapArea),56,88+kTASwapArea)];
    floatingActions.backgroundColor=UIColor.clearColor;
    floatingActions.isAccessibilityElement=YES;
    floatingActions.accessibilityLabel=@"Tay nắm chia màn: chạm mở tác vụ, chạm hai lần để đổi app, kéo để đổi tỉ lệ";
    // Visible part: 22x60 dark frosted capsule with hairline and three dots.
    lockVisual=[[UIView alloc] initWithFrame:CGRectMake(17,14+kTASwapArea,22,60)];
    lockVisual.userInteractionEnabled=NO; lockVisual.layer.cornerRadius=11; lockVisual.clipsToBounds=YES;
    lockVisual.layer.borderWidth=0.5; lockVisual.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.28].CGColor;
    lockVisual.backgroundColor=[UIColor colorWithWhite:0.1 alpha:0.82];
    for (NSInteger d=0;d<3;d++) {
        UIView *dot=[[UIView alloc] initWithFrame:CGRectMake(8.5,19+d*9,5,5)];
        dot.backgroundColor=[UIColor colorWithWhite:1 alpha:0.9]; dot.layer.cornerRadius=2.5; [lockVisual addSubview:dot];
    }
    [floatingActions addSubview:lockVisual];
    // Two-way arrow above the capsule: swap left ↔ right. The button keeps
    // alpha 1 (so it stays tappable); only its visual fades with the handle.
    TABlockButton *swap=[TABlockButton buttonWithHandler:^{ [controls swapFromHandle]; }];
    swap.frame=CGRectMake(6,2,44,kTASwapArea-4); swap.accessibilityLabel=@"Đổi trái ↔ phải";
    swapVisual=[[UIView alloc] initWithFrame:CGRectMake(6,4,32,32)];
    swapVisual.userInteractionEnabled=NO; swapVisual.layer.cornerRadius=16;
    swapVisual.backgroundColor=[UIColor colorWithWhite:0.1 alpha:0.82];
    swapVisual.layer.borderWidth=0.5; swapVisual.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.28].CGColor;
    UIImageView *arrows=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.left.arrow.right" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:13 weight:UIImageSymbolWeightBold]]];
    arrows.tintColor=TACyan(); arrows.contentMode=UIViewContentModeCenter; arrows.frame=swapVisual.bounds;
    [swapVisual addSubview:arrows]; [swap addSubview:swapVisual];
    [floatingActions addSubview:swap];
    [root addSubview:floatingActions];
    // Tap = menu, double (or triple) tap = change mode, drag = move divider.
    [floatingActions addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:controls action:@selector(lockTap:)]];
    UILongPressGestureRecognizer *handleHold=[[UILongPressGestureRecognizer alloc] initWithTarget:controls action:@selector(holdHandle:)];
    handleHold.minimumPressDuration=1.0; handleHold.allowableMovement=14; [floatingActions addGestureRecognizer:handleHold];
    [floatingActions addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:controls action:@selector(dragDivider:)]];
    TALayoutSplit(splitRatio);
    buttonWindow.hidden = YES; splitWindow.hidden = NO;
    TAShowChrome();
    TALog(@"START display=%@ ratio=%.2f left=%@ right=%@", NSStringFromCGRect(bounds), splitRatio, NSStringFromCGRect(panes[0].bounds), NSStringFromCGRect(panes[1].bounds));
}
- (void)holdDock:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateBegan) [self snapshot];
}
// Tác vụ page: greeting + two buttons (CarPlay Home, car = close).
- (void)showActions {
    UIView *root=splitWindow.rootViewController.view;
    if (!running || !root || actionPanel || splitWindow.rootViewController.presentedViewController) return;
    [self exitChangeMode];
    CGSize size=root.bounds.size;
    UIView *panel=[[UIView alloc] initWithFrame:root.bounds];
    panel.backgroundColor=[UIColor colorWithWhite:0 alpha:0.45]; panel.alpha=0;
    TABlockButton *backdrop=[TABlockButton buttonWithHandler:^{ [self closeActionPanel:nil]; }];
    backdrop.frame=panel.bounds; [panel addSubview:backdrop];
    CGFloat cw=MIN(size.width-32,380), ch=MIN(size.height-24,196);
    UIView *card=[[UIView alloc] initWithFrame:CGRectMake((size.width-cw)/2,(size.height-ch)/2,cw,ch)];
    card.layer.cornerRadius=22; card.clipsToBounds=YES;
    card.layer.borderWidth=0.5; card.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.18].CGColor;
    card.backgroundColor=[UIColor colorWithWhite:0.1 alpha:0.96];
    [panel addSubview:card];

    // Large greeting, rounded heavy type with a cyan→orange gradient fill.
    CGFloat greetingHeight=ch*0.44;
    UILabel *greeting=[[UILabel alloc] initWithFrame:CGRectMake(0,0,cw-24,greetingHeight)];
    greeting.text=@"Vạn dặm bình an!"; greeting.textAlignment=NSTextAlignmentCenter;
    greeting.font=TARoundedFont(38,UIFontWeightHeavy);
    greeting.adjustsFontSizeToFitWidth=YES; greeting.minimumScaleFactor=0.6;
    [greeting setNeedsDisplay]; [greeting.layer displayIfNeeded];
    CAGradientLayer *gradient=[CAGradientLayer layer];
    gradient.frame=CGRectMake(12,10,cw-24,greetingHeight);
    gradient.colors=@[(id)TACyan().CGColor,(id)[UIColor colorWithRed:0.62 green:0.8 blue:1 alpha:1].CGColor,(id)TAOrange().CGColor];
    gradient.startPoint=CGPointMake(0.15,0.5); gradient.endPoint=CGPointMake(0.85,0.5);
    gradient.mask=greeting.layer;
    [card.layer addSublayer:gradient];
    UIView *rule=[[UIView alloc] initWithFrame:CGRectMake(cw/2-32,greetingHeight+14,64,3)];
    rule.layer.cornerRadius=1.5; rule.backgroundColor=[UIColor colorWithWhite:1 alpha:0.18]; [card addSubview:rule];

    // Two round buttons side by side.
    CGFloat side=MIN(64,ch-greetingHeight-44), gap=44;
    CGFloat by=greetingHeight+14+(ch-greetingHeight-14-side)/2;
    TABlockButton *(^makeButton)(NSString *, UIColor *, NSString *, void (^)(void))=^(NSString *symbol, UIColor *tint, NSString *label, void (^handler)(void)) {
        TABlockButton *b=[TABlockButton buttonWithHandler:handler];
        b.layer.cornerRadius=side/2; b.backgroundColor=[UIColor colorWithWhite:1 alpha:0.08];
        b.layer.borderWidth=1; b.layer.borderColor=[tint colorWithAlphaComponent:0.55].CGColor;
        [b setImage:[UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:side*0.4 weight:UIImageSymbolWeightSemibold]] forState:UIControlStateNormal];
        b.tintColor=tint; b.accessibilityLabel=label;
        return b;
    };
    TABlockButton *home=makeButton(@"square.grid.2x2.fill",TAOrange(),@"Màn hình chính CarPlay",^{
        [self closeActionPanel:^{ [self goHome]; }];
    });
    home.frame=CGRectMake(cw/2-gap/2-side,by,side,side); [card addSubview:home];
    __block __weak TABlockButton *weakCar=nil;
    TABlockButton *car=makeButton(@"car.fill",TACyan(),@"Đóng",^{
        [UIView animateWithDuration:0.28 delay:0 options:UIViewAnimationOptionCurveEaseIn animations:^{
            weakCar.transform=CGAffineTransformMakeTranslation(cw,0);
        } completion:nil];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,180*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self closeActionPanel:nil]; });
    });
    car.frame=CGRectMake(cw/2+gap/2,by,side,side); [card addSubview:car]; weakCar=car;

    [root addSubview:panel]; actionPanel=panel;
    card.transform=CGAffineTransformMakeScale(0.94,0.94);
    [UIView animateWithDuration:0.22 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:0 animations:^{
        panel.alpha=1; card.transform=CGAffineTransformIdentity;
    } completion:nil];
    TALog(@"ACTIONS open");
}
// Home: keep the pair for resume (same as "Thu về CarPlay"), then ask the
// Dashboard to show CarPlay Home if it exposes a known no-argument selector.
- (void)goHome {
    if (!running) return;
    TARememberPair();
    TASuspend(@"home");
    id dash=nativeDashboard;
    // Candidates: known names first, then no-argument void methods of the
    // Dashboard class whose name says "home" + an action word (logged once).
    NSMutableArray *names=[@[@"handleHomeButtonPress",@"_handleHomeButtonPress",@"homeButtonPressed",@"_homeButtonPressed",@"goHome",@"_goHome"] mutableCopy];
    static NSArray *discovered;
    if (!discovered && dash) {
        NSMutableArray *found=[NSMutableArray new];
        for (Class c=[dash class]; c && c!=NSObject.class; c=class_getSuperclass(c)) {
            unsigned int count=0; Method *methods=class_copyMethodList(c,&count);
            for (unsigned int i=0;i<count;i++) {
                NSString *name=NSStringFromSelector(method_getName(methods[i]));
                NSString *lower=name.lowercaseString;
                if (![lower containsString:@"home"]) continue;
                TALog(@"HOME candidate %@ %s",name,method_getTypeEncoding(methods[i]));
                if ([name containsString:@":"]) continue;
                if ([lower containsString:@"go"] || [lower containsString:@"show"] || [lower containsString:@"open"] || [lower containsString:@"press"] || [lower containsString:@"tap"] || [lower containsString:@"handle"] || [lower containsString:@"return"])
                    [found addObject:name];
            }
            free(methods);
        }
        discovered=found;
    }
    [names addObjectsFromArray:discovered ?: @[]];
    // Device (0.36 log): DBDashboard has -_homeTapped:(id) — the Dock Home
    // button action. Call it with a nil sender first.
    SEL tapped=NSSelectorFromString(@"_homeTapped:");
    if ([dash respondsToSelector:tapped]) {
        @try { ((void(*)(id,SEL,id))objc_msgSend)(dash,tapped,nil); TALog(@"HOME via _homeTapped:"); return; }
        @catch (NSException *e) { TALog(@"HOME _homeTapped: error %@",e.name); }
    }
    for (NSString *name in names) {
        SEL sel=NSSelectorFromString(name);
        NSMethodSignature *sig=[dash methodSignatureForSelector:sel];
        if (!sig || sig.numberOfArguments!=2 || strcmp(sig.methodReturnType,@encode(void))) continue;
        @try { ((void(*)(id,SEL))objc_msgSend)(dash,sel); TALog(@"HOME via %@",name); return; }
        @catch (NSException *e) { TALog(@"HOME error %@ %@",name,e.name); }
    }
    TALog(@"HOME no dashboard selector (owner=%@); split folded only",NSStringFromClass([dash class]));
}
- (void)holdHandle:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateBegan || !running || staged) return;
    ++lockTapSerial; lockTaps=0;   // a hold is not a tap
    TALog(@"HOLD open");
    [self showActions];
}
- (void)swapFromHandle {
    if (!running || staged) return;
    if (actionPanel) { [self closeActionPanel:nil]; return; }
    TAShowChrome();
    [self exitChangeMode];
    BOOL ready=slots[0].presentation && slots[1].presentation && !TAAttachPending();
    TALog(@"SWAP tap ready=%d",ready);
    if (!ready) return;
    [UIView transitionWithView:splitWindow.rootViewController.view duration:0.25 options:UIViewAnimationOptionTransitionCrossDissolve|UIViewAnimationOptionAllowUserInteraction animations:^{
        [self swapSides];
    } completion:nil];
}
- (void)closeActionPanel:(void (^)(void))then {
    UIView *panel=actionPanel; actionPanel=nil;
    if (!panel) { if (then) then(); return; }
    [UIView animateWithDuration:0.18 animations:^{ panel.alpha=0; } completion:^(__unused BOOL f) {
        [panel removeFromSuperview];
        if (then) then();
    }];
}
- (void)closePicker:(UIButton *)sender {
    NSInteger slot=sender.tag; if (slot<0 || slot>1) return;
    [appPickers[slot] removeFromSuperview]; appPickers[slot]=nil;
}
- (void)selectTile:(TAAppTile *)tile {
    if (!TASelectableBundle(tile.bundle) || !running || tile.token!=generation || tile.slot<0 || tile.slot>1 || [slots[1-tile.slot].bundle isEqual:tile.bundle]) return;
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
    pickerItems[slot]=TAPickerBundles(); pickerPages[slot]=0;
    [self renderPicker:slot];
}
- (void)pickerPage:(UIButton *)sender {
    NSInteger slot=sender.tag/2;
    if (!running || slot<0 || slot>1 || !appPickers[slot] || sender.superview!=appPickers[slot]) return;
    pickerPages[slot]+=sender.tag%2 ? 1 : -1;
    [self renderPicker:slot];
}
- (void)renderPicker:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || !panes[slot]) return;
    NSArray *available=pickerItems[slot] ?: @[];
    [appPickers[slot] removeFromSuperview];
    UIView *panel=[[UIView alloc] initWithFrame:panes[slot].frame]; panel.backgroundColor=[UIColor colorWithWhite:0.055 alpha:1];
    appPickers[slot]=panel; [splitWindow.rootViewController.view insertSubview:panel belowSubview:floatingActions];
    UILabel *title=[[UILabel alloc] initWithFrame:CGRectMake(10,6,panel.bounds.size.width-46,28)];
    title.text=slot==0 ? @"Ứng dụng bên trái" : @"Ứng dụng bên phải"; title.font=[UIFont systemFontOfSize:12 weight:UIFontWeightSemibold]; title.textColor=UIColor.whiteColor; [panel addSubview:title];
    title.font=TARoundedFont(13,UIFontWeightBold);
    UIButton *close=TAGlassButton(@"xmark",12,CGRectMake(panel.bounds.size.width-36,5,30,30),NULL);
    [close addTarget:self action:@selector(closePicker:) forControlEvents:UIControlEventTouchUpInside];
    close.tag=slot; close.accessibilityLabel=@"Đóng chọn ứng dụng"; [panel addSubview:close];
    UIView *grid=[[UIView alloc] initWithFrame:CGRectMake(6,38,panel.bounds.size.width-12,MAX(0,panel.bounds.size.height-82))];
    grid.clipsToBounds=YES; [panel addSubview:grid];
    NSUInteger columns=grid.bounds.size.width>=180 ? 3 : 2;
    NSUInteger rows=MAX(1,(NSInteger)floor(grid.bounds.size.height/64));
    NSUInteger perPage=columns*rows, pages=MAX((NSUInteger)1,(available.count+perPage-1)/perPage);
    pickerPages[slot]=MAX(0,MIN(pickerPages[slot],(NSInteger)pages-1));
    CGFloat width=grid.bounds.size.width/columns;
    CGFloat rowHeight=MIN(64,grid.bounds.size.height/rows);
    NSUInteger first=pickerPages[slot]*perPage, last=MIN(available.count,first+perPage), index=0;
    TALog(@"PICKER PAGE side=%ld page=%ld/%lu apps=%lu",(long)slot,(long)pickerPages[slot]+1,(unsigned long)pages,(unsigned long)available.count);
    for (NSUInteger item=first;item<last;item++) {
        NSString *bundle=available[item];
        TARecord *r=records[bundle];
        BOOL used=[slots[1-slot].bundle isEqual:bundle] || (r.controller && slots[1-slot] && slots[1-slot].controller==r.controller);
        TAAppTile *tile=[TAAppTile buttonWithType:UIButtonTypeCustom]; tile.bundle=bundle; tile.slot=slot; tile.token=generation;
        tile.frame=CGRectMake((index%columns)*width,(index/columns)*rowHeight,width,rowHeight); tile.enabled=!used; tile.alpha=used ? 0.25 : 1;
        tile.accessibilityLabel=[TAAppName(bundle) stringByAppendingString:used ? @", đang dùng ở ô kia" : @""];
        UIImageView *icon=[[UIImageView alloc] initWithFrame:CGRectMake((width-48)/2,6,48,48)]; icon.image=TAAppIcon(bundle); icon.contentMode=UIViewContentModeScaleAspectFit; icon.layer.cornerRadius=10; icon.clipsToBounds=YES; [tile addSubview:icon];
        if (!icon.image) {
            icon.backgroundColor=[UIColor colorWithWhite:0.2 alpha:1];
            icon.image=[UIImage systemImageNamed:@"app"];
            icon.tintColor=UIColor.lightGrayColor;
        }
        if ([slots[slot].bundle isEqual:bundle]) { icon.layer.borderWidth=2; icon.layer.borderColor=TACyan().CGColor; }

        [tile addTarget:self action:@selector(selectTile:) forControlEvents:UIControlEventTouchUpInside]; [grid addSubview:tile]; index++;
    }
    CGFloat footer=panel.bounds.size.height-42;
    for (NSInteger direction=0;direction<2;direction++) {
        UIButton *button=TAGlassButton(direction ? @"chevron.right" : @"chevron.left",15,CGRectMake(direction ? panel.bounds.size.width-54 : 8,footer+2,46,36),NULL);
        [button addTarget:self action:@selector(pickerPage:) forControlEvents:UIControlEventTouchUpInside];
        button.tag=slot*2+direction;
        button.enabled=direction ? pickerPages[slot]+1<(NSInteger)pages : pickerPages[slot]>0;
        button.tintColor=button.enabled ? TACyan() : UIColor.whiteColor;
        button.alpha=button.enabled ? 1 : 0.25;
        button.accessibilityLabel=direction ? @"Trang sau" : @"Trang trước"; [panel addSubview:button];
    }
    // Page indicator: capsule dots (current one is a cyan pill) + "1 / 3".
    CGFloat midX=panel.bounds.size.width/2;
    NSUInteger shown=MIN(pages,(NSUInteger)5);
    CGFloat dotsWidth=shown*6+(shown-1)*5+10;
    CGFloat dx=midX-dotsWidth/2;
    for (NSUInteger p=0;p<shown;p++) {
        BOOL current=(NSInteger)p==MIN(pickerPages[slot],(NSInteger)shown-1);
        UIView *dot=[[UIView alloc] initWithFrame:CGRectMake(dx,footer+8,current ? 16 : 6,6)];
        dot.layer.cornerRadius=3; dot.backgroundColor=current ? TACyan() : [UIColor colorWithWhite:1 alpha:0.3];
        [panel addSubview:dot]; dx+=(current ? 16 : 6)+5;
    }
    UILabel *pageLabel=[[UILabel alloc] initWithFrame:CGRectMake(60,footer+18,panel.bounds.size.width-120,20)];
    NSMutableAttributedString *pageText=[[NSMutableAttributedString alloc] initWithString:[NSString stringWithFormat:@"%ld",(long)pickerPages[slot]+1] attributes:@{NSFontAttributeName:TARoundedFont(14,UIFontWeightBold),NSForegroundColorAttributeName:UIColor.whiteColor}];
    [pageText appendAttributedString:[[NSAttributedString alloc] initWithString:[NSString stringWithFormat:@" / %lu",(unsigned long)pages] attributes:@{NSFontAttributeName:TARoundedFont(12,UIFontWeightMedium),NSForegroundColorAttributeName:[UIColor colorWithWhite:1 alpha:0.45]}]];
    pageLabel.attributedText=pageText; pageLabel.textAlignment=NSTextAlignmentCenter; [panel addSubview:pageLabel];
    if (!index) {
        UILabel *empty=[[UILabel alloc] initWithFrame:grid.bounds]; empty.text=@"Chưa đọc được danh sách ứng dụng CarPlay. Hãy kết nối lại rồi thử chọn."; empty.textColor=UIColor.lightGrayColor; empty.font=[UIFont systemFontOfSize:13]; empty.numberOfLines=0; empty.textAlignment=NSTextAlignmentCenter; [grid addSubview:empty];
    }
}
- (void)dragDivider:(UIPanGestureRecognizer *)gesture {
    UIView *root=splitWindow.rootViewController.view;
    if (!running || staged || !root || !panes[0] || !panes[1]) return;
    if (gesture.state==UIGestureRecognizerStateBegan && root.window.rootViewController.presentedViewController) {
        gesture.enabled=NO; gesture.enabled=YES; return;
    }
    CGFloat width=MAX(1,root.bounds.size.width);
    CGFloat raw=dragStartRatio+[gesture translationInView:root].x/width;
    switch (gesture.state) {
        case UIGestureRecognizerStateBegan:
            dragStartRatio=splitRatio; floatingActions.hidden=NO; chromeHold=YES; TAShowChrome();
            dragMoved=NO; holdFired=NO;
            {
                NSUInteger serial=++holdSerial;
                __weak UIPanGestureRecognizer *weakGesture=gesture;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{
                    UIGestureRecognizerState state=weakGesture.state;
                    if (serial!=holdSerial || dragMoved || !running) return;
                    if (state!=UIGestureRecognizerStateBegan && state!=UIGestureRecognizerStateChanged) return;
                    holdFired=YES; TALog(@"HOLD open (pan path)");
                    [self showActions];
                });
            }
            break;
        case UIGestureRecognizerStateChanged:
            if (!dragMoved) {
                CGPoint t=[gesture translationInView:root];
                if (hypot(t.x,t.y)<kTADragSlop) break;
                // Real drag starts only now.
                dragMoved=YES; ++holdSerial; [self exitChangeMode];
                for (NSInteger i=0;i<2;i++) appPickers[i].hidden=YES;
                TAShowCovers(YES);
            }
            TALayoutSplit(TAVisualRatio(raw));
            // Orange grip = releasing here closes the split.
            dividerGrip.backgroundColor=(raw>=kTACollapse || raw<=1-kTACollapse) ? TAOrange() : TACyan();
            break;
        case UIGestureRecognizerStateEnded: {
            // Short flick projection, then clamp to 30–70%.
            CGFloat projected=raw+[gesture velocityInView:root].x/width*0.08;
            chromeHold=NO; TAShowChrome(); ++holdSerial;
            if (holdFired) { holdFired=NO; dividerGrip.backgroundColor=[UIColor colorWithWhite:1 alpha:0.35]; break; }
            if (!dragMoved) {
                // Finger barely moved: this was a tap, not a drag.
                dividerGrip.backgroundColor=[UIColor colorWithWhite:1 alpha:0.35];
                for (NSInteger i=0;i<2;i++) appPickers[i].hidden=NO;
                if (gesture.view==floatingActions) {
                    if ([gesture locationInView:floatingActions].y<kTASwapArea) [self swapFromHandle];
                    else [self registerLockTap];
                }
                break;
            }
            if (projected>=kTACollapse) { [self collapseTo:0]; break; }
            if (projected<=1-kTACollapse) { [self collapseTo:1]; break; }
            [self commitSplit:projected];
            break;
        }
        default:
            chromeHold=NO; TAShowChrome(); ++holdSerial; holdFired=NO;
            if (!dragMoved) { for (NSInteger i=0;i<2;i++) appPickers[i].hidden=NO; break; }
            [self commitSplit:splitRatio];
            break;
    }
}
- (void)resetDivider:(UITapGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateRecognized) [self commitSplit:0.5];
}
// Swipe right from the empty top of the CarPlay Dock: once the finger leaves
// the Dock, the divider slides out and follows it. The new app takes the
// left pane (next to the Dock), the app already open takes the right pane.
- (void)dockPull:(UIPanGestureRecognizer *)gesture {
    CGFloat x=[gesture locationInView:edgeWindow].x+edgeWindow.frame.origin.x;
    CGFloat width=MAX(1,splitWindow ? splitWindow.bounds.size.width : TADisplayWidth());
    switch (gesture.state) {
        case UIGestureRecognizerStateChanged: {
            if (staged) { TALayoutPull(x/width); break; }
            CGPoint moved=[gesture translationInView:edgeWindow];
            if (fabs(moved.y)>12 && fabs(moved.y)>fabs(moved.x)) { gesture.enabled=NO; gesture.enabled=YES; break; }
            if (moved.x>0 && x>dockZoneRight+4 && ![self beginPullFromLeft]) { gesture.enabled=NO; gesture.enabled=YES; break; }
            if (staged) TALayoutPull(x/width);
            break;
        }
        case UIGestureRecognizerStateEnded:
            if (staged) [self finishPull:x/width];
            break;
        case UIGestureRecognizerStateBegan:
            TALog(@"DOCK SWIPE start x=%.1f dockRight=%.1f current=%@",x,dockZoneRight,nativeForeground ?: @"-");
            break;
        default:
            if (staged) [self finishPull:0];
            break;
    }
}
- (BOOL)beginPullFromLeft {
    NSString *current=[nativeForeground copy];
    if (running || primeBundle || !current.length || !TADirectReady(records[current])) {
        TALog(@"DOCK PULL rejected current=%@ running=%d ready=%d",current,running,TADirectReady(records[current]));
        return NO;
    }
    // Companion: most recently used other app that can attach directly.
    NSString *companion=nil; pullCurrentSlot=1;
    if (openBundle && [current isEqual:openBundle] && NSProcessInfo.processInfo.systemUptime-openTime<180 && openKeep.length && TADirectReady(records[openKeep])) {
        companion=openKeep; pullCurrentSlot=openSlot;
        TALog(@"DOCK PULL uses remembered pair %@ + %@",current,companion);
    }
    openBundle=nil; openKeep=nil;
    // Only apps the user actually opened this session and that last
    // rendered fine. Apple Maps restored in the background at connect
    // (no launch source) had a scene but never drew in a pane (0.39 log).
    if (!companion) for (NSString *bundle in [order reverseObjectEnumerator]) {
        TARecord *candidate=records[bundle];
        if (![bundle isEqual:current] && candidate.userLaunched && !candidate.noSurface && TADirectReady(candidate)) { companion=bundle; break; }
    }
    resumeBundles=nil; resumeCandidate=nil;
    staged=YES; pullFromLeft=YES; pullCurrent=current; pullCompanion=companion;
    [self start];
    if (!running) { staged=NO; pullFromLeft=NO; pullCurrent=nil; pullCompanion=nil; return NO; }
    floatingActions.hidden=YES;
    dividerView.backgroundColor=TADividerColor();
    railIcon.image=companion ? TAAppIcon(companion) : [UIImage systemImageNamed:@"plus.square.on.square"];
    railIcon.tintColor=UIColor.lightGrayColor;
    for (NSInteger i=0;i<2;i++) {
        NSString *bundle=i==pullCurrentSlot ? current : companion;
        [choose[i] setTitle:bundle ? @"" : @"Chọn ứng dụng" forState:UIControlStateNormal];
        [choose[i] setImage:bundle ? TAAppIcon(bundle) : nil forState:UIControlStateNormal];
        choose[i].enabled=NO; choose[i].adjustsImageWhenDisabled=NO;
    }
    // Rail above the panes, but the handle must stay above the rail:
    // otherwise the divider's own tap recognizers swallow handle taps.
    [splitWindow.rootViewController.view bringSubviewToFront:dividerView];
    [splitWindow.rootViewController.view bringSubviewToFront:floatingActions];
    TALog(@"DOCK PULL begin current=%@ companion=%@ dockRight=%.1f",current,companion,dockZoneRight);
    return YES;
}
- (void)finishPull:(CGFloat)ratio {
    if (!running || !staged) return;
    NSString *current=[pullCurrent copy], *companion=[pullCompanion copy];
    BOOL fromLeft=pullFromLeft;
    staged=NO; pullFromLeft=NO; pullCurrent=nil; pullCompanion=nil;
    // Released close to where it started: nothing was attached, just remove
    // the overlay (within ~72pt of the right edge, or of the Dock's edge).
    CGFloat display=MAX(1,TADisplayWidth());
    BOOL cancel=fromLeft ? ratio<(dockZoneRight+kTAPullCancel*0.6)/display : ratio>1-kTAPullCancel/display;
    if (cancel) { TALog(@"PULL cancelled ratio=%.3f fromLeft=%d",ratio,fromLeft); TAStop(@"pull cancelled"); return; }
    ratio=TAClampRatio(ratio);
    if (fabs(ratio-0.5)<0.03) ratio=0.5;
    splitRatio=ratio;
    dividerView.backgroundColor=TADividerColor(); floatingActions.hidden=NO;
    [splitWindow.rootViewController.view bringSubviewToFront:floatingActions];
    for (NSInteger i=0;i<2;i++) {
        [choose[i] setImage:nil forState:UIControlStateNormal];
        [choose[i] setTitle:@"Chạm để chọn ứng dụng" forState:UIControlStateNormal];
        choose[i].enabled=YES;
    }
    [UIView animateWithDuration:0.25 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        TALayoutSplit(ratio);
    } completion:nil];
    TALog(@"PULL open ratio=%.3f fromLeft=%d current=%@ companion=%@",ratio,fromLeft,current,companion);
    TAUpdateEdge();
    NSInteger cs=pullCurrentSlot; pullCurrentSlot=0;
    [self attach:current slot:cs];
    if (companion.length) [self replace:companion slot:1-cs];
}
// Divider dragged to an edge: the pane that keeps the screen returns to
// native full screen; the other app goes back to the background as normal.
- (void)collapseTo:(NSInteger)winner {
    if (!running || staged || winner<0 || winner>1) return;
    NSString *keep=[slots[winner].bundle copy];
    TALog(@"COLLAPSE keep=%@ side=%ld",keep,(long)winner);
    CGFloat width=splitWindow.bounds.size.width;
    NSUInteger token=generation;
    TAShowCovers(YES);
    BOOL templKeep=[keep hasPrefix:@"com.apple."] || [[TAValue(records[keep].controller,@"sceneID") componentsSeparatedByString:@":"] count]==3;
    if (keep.length && !templKeep && ![keep isEqual:nativeForeground]) {
        // Kept app is bridged (YouTube). Ask Dashboard to show it natively
        // while both panes still hold their apps (its request to background
        // the other pane's app is declined), then leave the split. Releasing
        // first and launching a bridged app afterwards is the hang pattern.
        launchGuardUntil=NSProcessInfo.processInfo.systemUptime+4;
        allowLaunchInSplit=YES; BOOL ok=TANativeLaunch(keep); allowLaunchInSplit=NO;
        TALog(@"COLLAPSE native launch before release %@ ok=%d",keep,ok);
        [UIView animateWithDuration:0.22 animations:^{ TALayoutAt(winner==0 ? width+20 : -20,TADividerWidth(width)); }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.5*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if (!running || generation!=token) return;
            if (slots[winner]) slots[winner].restoreBackground=NO;
            launchGuardUntil=0;
            if (ok) nativeForeground=keep;
            TARememberPair();
            TAStop(@"collapse");
        });
        return;
    }
    [UIView animateWithDuration:0.22 animations:^{
        TALayoutAt(winner==0 ? width+20 : -20,TADividerWidth(width));
    } completion:^(__unused BOOL finished) {
        if (!running || generation!=token) return;
        // Keep the winner foreground instead of restoring its old background state.
        if (slots[winner]) slots[winner].restoreBackground=NO;
        TARememberPair();
        TAStop(@"collapse");
        // 6/6 host stalls followed a native foreground of a non-template app
        // (YouTube via bridge) whose scene had been resized in the split.
        // Only template/Apple apps are relaunched automatically.
        BOOL safeRelaunch=[keep hasPrefix:@"com.apple."] || [[TAValue(records[keep].controller,@"sceneID") componentsSeparatedByString:@":"] count]==3;
        if (keep.length && !safeRelaunch) TALog(@"COLLAPSE skip native relaunch %@ (non-template)",keep);
        if (keep.length && safeRelaunch && ![keep isEqual:nativeForeground]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (running || primeBundle) return;
                BOOL ok=TANativeLaunch(keep);
                TALog(@"COLLAPSE native launch %@ ok=%d",keep,ok);
            });
        }
    }];
}
- (void)lockTap:(UITapGestureRecognizer *)gesture {
    if (gesture.state==UIGestureRecognizerStateRecognized) [self registerLockTap];
}
// 1 tap = reveal the divider/handle only. 2 or 3 taps, each within 0.6s of
// the previous one, = change mode (entered on the 2nd tap). Hold ≥1s = Tác vụ page.
- (void)registerLockTap {
    if (!running || staged) return;
    if (actionPanel) { [self closeActionPanel:nil]; return; }
    TAShowChrome();
    NSUInteger serial=++lockTapSerial;
    if (++lockTaps==2) [self enterChangeMode];
    TALog(@"HANDLE TAP count=%lu",(unsigned long)lockTaps);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
        if (serial!=lockTapSerial || !running) return;
        NSUInteger taps=lockTaps; lockTaps=0;
        if (taps!=1) return;
        // A single tap only reveals the divider (TAShowChrome above). The
        // Tác vụ page opens with a hold ≥1s instead.
        if (changeOverlays[0] || changeOverlays[1]) [self exitChangeMode];
    });
}
- (void)enterChangeMode {
    if (!running || staged || splitWindow.rootViewController.presentedViewController) return;
    TAShowChrome();
    [self exitChangeMode];
    changeModeSince=NSProcessInfo.processInfo.systemUptime;
    for (NSInteger i=0;i<2;i++) {
        if (!panes[i]) continue;
        [appPickers[i] removeFromSuperview]; appPickers[i]=nil;
        UIView *overlay=[[UIView alloc] initWithFrame:panes[i].bounds];
        overlay.tag=i; overlay.backgroundColor=[UIColor colorWithWhite:0 alpha:0.5]; overlay.alpha=0;
        overlay.autoresizingMask=UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        UIView *badge=[[UIView alloc] initWithFrame:CGRectMake(0,0,96,96)];
        badge.userInteractionEnabled=NO; badge.layer.cornerRadius=24; badge.clipsToBounds=YES;
        badge.layer.borderWidth=0.5; badge.layer.borderColor=[UIColor colorWithWhite:1 alpha:0.25].CGColor;
        badge.backgroundColor=[UIColor colorWithWhite:0.1 alpha:0.9];
        UIImageView *icon=[[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"arrow.triangle.2.circlepath" withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:30 weight:UIImageSymbolWeightSemibold]]];
        icon.tintColor=TACyan(); icon.contentMode=UIViewContentModeCenter; icon.frame=CGRectMake(0,12,96,46); [badge addSubview:icon];
        UILabel *label=[[UILabel alloc] initWithFrame:CGRectMake(0,60,96,22)];
        label.text=@"Chạm"; label.textAlignment=NSTextAlignmentCenter; label.textColor=UIColor.whiteColor;
        label.font=[UIFont systemFontOfSize:15 weight:UIFontWeightSemibold]; [badge addSubview:label];
        badge.center=CGPointMake(CGRectGetMidX(overlay.bounds),CGRectGetMidY(overlay.bounds));
        badge.autoresizingMask=UIViewAutoresizingFlexibleLeftMargin|UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleBottomMargin;
        [overlay addSubview:badge];
        // Fires on lift regardless of finger wobble (head-unit touches jitter).
        UILongPressGestureRecognizer *press=[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(changeTap:)];
        press.minimumPressDuration=0; press.allowableMovement=CGFLOAT_MAX;
        [overlay addGestureRecognizer:press];
        [panes[i] addSubview:overlay]; changeOverlays[i]=overlay;
        [UIView animateWithDuration:0.18 animations:^{ overlay.alpha=1; }];
    }
    TALog(@"CHANGE MODE on");
    NSTimeInterval since=changeModeSince;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,6*NSEC_PER_SEC),dispatch_get_main_queue(),^{
        if (running && changeModeSince==since) [self exitChangeMode];
    });
}
- (void)changeTap:(UIGestureRecognizer *)gesture {
    NSInteger slot=gesture.view.tag;
    if (gesture.state!=UIGestureRecognizerStateEnded || !running || slot<0 || slot>1) return;
    [self exitChangeMode];
    TALog(@"CHANGE MODE pick side=%ld",(long)slot);
    [self pick:choose[slot]];
}
- (void)exitChangeMode {
    changeModeSince=changeOverlays[0] || changeOverlays[1] ? 0 : changeModeSince;
    for (NSInteger i=0;i<2;i++) {
        UIView *overlay=changeOverlays[i]; changeOverlays[i]=nil;
        [UIView animateWithDuration:0.15 animations:^{ overlay.alpha=0; } completion:^(__unused BOOL f){ [overlay removeFromSuperview]; }];
    }
}
- (void)commitSplit:(CGFloat)ratio {
    if (staged) return;
    if (!running || !panes[0] || !panes[1]) return;
    ratio=TAClampRatio(ratio);
    if (fabs(ratio-0.5)<0.03) ratio=0.5;   // light magnet to the centre
    splitRatio=ratio; dividerGrip.backgroundColor=[UIColor colorWithWhite:1 alpha:0.35];
    BOOL needsCover=NO;
    for (NSInteger i=0;i<2;i++) if (slots[i].presentation) needsCover=YES;
    if (needsCover) TAShowCovers(YES);
    NSUInteger token=generation;
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0 options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        TALayoutSplit(ratio);
    } completion:^(__unused BOOL finished) {
        if (!running || generation!=token) return;
        TALayoutSplit(splitRatio);
        for (NSInteger i=0;i<2;i++) {
            TARecord *r=slots[i]; if (!r.presentation) continue;
            CGSize target=panes[i].bounds.size;
            r.presentation.frame=panes[i].bounds;
            if (fabs(r.targetSize.width-target.width)>0.5 || fabs(r.targetSize.height-target.height)>0.5) {
                BOOL previous=ownCall; ownCall=YES;
                @try { TAResize(r,target); } @catch (NSException *e) { TALog(@"DIVIDER RESIZE ERROR %@ %@",r.bundle,e.name); }
                ownCall=previous;
            }
        }
        for (NSInteger i=0;i<2;i++) if (appPickers[i]) [self renderPicker:i];
        TALog(@"DIVIDER ratio=%.3f left=%@ right=%@",splitRatio,NSStringFromCGSize(panes[0].bounds.size),NSStringFromCGSize(panes[1].bounds.size));
        // Let the resized scenes lay out before revealing them.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.45*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if (running && generation==token) TAShowCovers(NO);
        });
    }];
}
- (void)paneAction:(UIButton *)sender {
    NSInteger slot=sender.tag; if (slot<0 || slot>1) return;
    if (retryTargets[slot]) [self retryPane:slot]; else [self pick:sender];
}
- (void)failAttach:(NSInteger)slot bundle:(NSString *)bundle reason:(NSString *)reason {
    if (!running) return;
    NSString *target=[bundle copy];
    TALog(@"ATTACH FAILED side=%ld bundle=%@ reason=%@",(long)slot,target,reason);
    if ([reason containsString:@"no hosted surface"]) {
        BOOL first=!records[target].noSurface;
        records[target].noSurface=YES;
        if (first && catalog[target]) {
            NSUInteger token=generation;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,400*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
                if (running && generation==token && !slots[slot]) { TALog(@"AUTO RETRY via Dashboard %@",target); [self prepare:target slot:slot]; }
            });
        }
    }
    TAClearSlot(slot,reason); retryTargets[slot]=target;
    [choose[slot] setTitle:@"Chưa hiển thị được\nChạm để thử lại" forState:UIControlStateNormal];
    choose[slot].hidden=NO; choose[slot].enabled=YES;
}
// An app without a live CarPlay scene is NOT auto-rebuilt into the split any
// more. Device logs (0.31.2, 0.32, 0.33) show the same sequence three times:
// PREPARE of com.google.ios.youtube -> immediate pair rebuild -> CarPlayApp
// main thread blocked 16-58s -> watchdog restart. Instead: leave the split,
// open the app full screen natively, and let the user pull the right edge
// (edge pull pairs it with the most recently used other app).
// 0.39: picking an app with no live scene keeps the split. Leaving the split
// to open it (0.33–0.38) backgrounded the app in the other pane; YouTube
// never redrew after coming back from the background (blank pane, audio on).
- (void)prepare:(NSString *)bundle slot:(NSInteger)slot {
    if (!running || staged || slot<0 || slot>1 || primeBundle) return;
    if (!catalog[bundle]) {
        // Not launchable through Dashboard (no catalog entry): fall back to
        // adopting its live scene if there is one.
        if (TADirectReady(records[bundle])) { TAClearSlot(slot,@"no catalog entry"); [self attach:bundle slot:slot]; }
        else [self failAttach:slot bundle:bundle reason:@"not launchable"];
        return;
    }
    // Apps bridged into CarPlay (not a CarPlay app, not Apple) that are not
    // running: starting them while the split is up hung CarPlay (Zalo, 0.43).
    // YouTube is the tested exception (waits for its first picture).
    TARecord *known=records[bundle];
    BOOL live=TADirectReady(known);
    BOOL bridged=known ? [[TAValue(known.controller,@"sceneID") componentsSeparatedByString:@":"] count]==2 : TAValue(catalog[bundle],@"carPlayDeclaration")==nil;
    if (!live && bridged && ![bundle hasPrefix:@"com.apple."] && ![bundle isEqual:@"com.google.ios.youtube"]) {
        TALog(@"LAUNCH IN PANE refused cold bridged app %@",bundle);
        [self failAttach:slot bundle:bundle reason:@"bridged app not running"];
        [choose[slot] setTitle:[NSString stringWithFormat:@"Mở %@ ở ngoài trước\nrồi chọn lại",TAAppName(bundle)] forState:UIControlStateNormal];
        return;
    }
    if (launchBundle) {
        // One Dashboard launch at a time; queue this one.
        NSString *queued=[bundle copy]; NSUInteger token=generation;
        TALog(@"LAUNCH IN PANE queued %@ (busy with %@)",queued,launchBundle);
        [choose[slot] setTitle:[NSString stringWithFormat:@"  Chờ mở %@…",TAAppName(queued)] forState:UIControlStateNormal];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,600*NSEC_PER_MSEC),dispatch_get_main_queue(),^{
            if (running && generation==token && ![slots[slot].bundle isEqual:queued]) [self prepare:queued slot:slot];
        });
        return;
    }
    // Keep the current app in the pane (covered) until the new one is ready.
    // Every launch-in-pane hang (0.39 Apple Maps→YouTube, 0.43 YouTube Music→
    // Zalo, 0.44 Vietmap→YouTube) followed Dashboard backgrounding the app we
    // had just released from that pane; every launch where Dashboard's
    // background request hit an app still in a pane (and was declined) was fine.
    if (slots[slot] && !slots[slot].attaching) {
        TALog(@"LAUNCH IN PANE keeps %@ until %@ is ready",slots[slot].bundle,bundle);
        [panes[slot] bringSubviewToFront:choose[slot]];
    } else TAClearSlot(slot,@"launch in pane");
    launchBundle=[bundle copy]; launchSlot=slot;
    launchStart=NSProcessInfo.processInfo.systemUptime; launchSurfaceSince=0;
    launchGuardUntil=launchStart+14;
    [choose[slot] setImage:TAAppIcon(bundle) forState:UIControlStateNormal];
    [choose[slot] setTitle:[NSString stringWithFormat:@"  Đang mở %@…",TAAppName(bundle)] forState:UIControlStateNormal];
    choose[slot].enabled=NO; choose[slot].adjustsImageWhenDisabled=NO; choose[slot].hidden=NO;
    NSUInteger token=generation;
    lastNativeTransition=NSProcessInfo.processInfo.systemUptime;
    allowLaunchInSplit=YES; BOOL ok=TANativeLaunch(bundle); allowLaunchInSplit=NO;
    TALog(@"LAUNCH IN PANE bundle=%@ side=%ld requested=%d",bundle,(long)slot,ok);
    if (!ok) { launchBundle=nil; launchGuardUntil=0; [self failAttach:slot bundle:bundle reason:@"launch request failed"]; return; }
    [self waitLaunch:0 generation:token];
}
// A pane showing only the wallpaper still has a hosted layer, but it points
// at a render context the app has since replaced (the pane was created while
// the app was still starting). Compare with the context ids Dashboard's own
// view of the same app is hosting; if they share none, build a fresh pane view.
- (void)verifyPane:(NSInteger)slot record:(TARecord *)r generation:(NSUInteger)token attempt:(NSUInteger)attempt {
    NSTimeInterval delay=attempt==0 ? 1.5 : 3.0;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        if (!running || generation!=token || slots[slot]!=r || !r.presentation || r.attaching) return;
        UIView *native=[r.controller isKindOfClass:UIViewController.class] ? ((UIViewController *)r.controller).viewIfLoaded : nil;
        NSMutableSet *nativeIDs=[NSMutableSet new], *paneIDs=[NSMutableSet new];
        NSInteger b1=300, b2=300;
        if (native && ![r.presentation isDescendantOfView:native]) TACollectContexts(native.layer,0,&b1,nativeIDs);
        TACollectContexts(r.presentation.layer,0,&b2,paneIDs);
        BOOL stale=nativeIDs.count && paneIDs.count && ![paneIDs intersectsSet:nativeIDs];
        TALog(@"PANE CHECK side=%ld bundle=%@ native=%@ pane=%@ stale=%d",(long)slot,r.bundle,nativeIDs.allObjects,paneIDs.allObjects,stale);
        if (!stale) { if (attempt==0) [self verifyPane:slot record:r generation:token attempt:1]; return; }
        if (attempt>=3) { TALog(@"PANE CHECK giving up side=%ld",(long)slot); return; }
        // Rebuild only our view of the scene; the app itself is untouched.
        BOOL previous=ownCall; ownCall=YES;
        @try {
            SEL invalidate=NSSelectorFromString(@"invalidatePresentationViewForIdentifier:");
            UIView *old=r.presentation; NSString *oldID=r.presentationID;
            NSString *newID=[oldID stringByAppendingFormat:@".r%lu",(unsigned long)attempt+1];
            id view=((id(*)(id,SEL,id))objc_msgSend)(r.controller,NSSelectorFromString(@"presentationViewWithIdentifier:"),newID);
            if ([view isKindOfClass:UIView.class] && !((UIView *)view).superview) {
                ((UIView *)view).frame=panes[slot].bounds;
                [panes[slot] insertSubview:view aboveSubview:old];
                [old removeFromSuperview];
                if (oldID && [r.controller respondsToSelector:invalidate]) ((void(*)(id,SEL,id))objc_msgSend)(r.controller,invalidate,oldID);
                r.presentation=view; r.presentationID=newID;
                [view setNeedsLayout]; [view layoutIfNeeded];
                TALog(@"PANE REFRESH side=%ld bundle=%@",(long)slot,r.bundle);
            }
        } @catch (NSException *e) { TALog(@"PANE REFRESH error %@",e.name); }
        ownCall=previous;
        [self verifyPane:slot record:r generation:token attempt:attempt+1];
    });
}
- (void)waitLaunch:(NSUInteger)attempt generation:(NSUInteger)token {
    if (!running || generation!=token || !launchBundle) return;
    NSString *bundle=launchBundle; NSInteger slot=launchSlot;
    TARecord *r=records[bundle];
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    // Attaching YouTube (non-template, bridged) ~1s after its cold launch
    // froze CarPlay's main thread in every case (0.31–0.33 and 0.39 logs);
    // attaching it ≥5s after launch never did. Template apps are fine at 0.8s.
    BOOL templ=r && [[TAValue(r.controller,@"sceneID") componentsSeparatedByString:@":"] count]==3;
    BOOL settledApp=YES;
    if (r) {
        BOOL slow=!templ && ![bundle hasPrefix:@"com.apple."];
        NSTimeInterval floor=slow ? 2 : 1, hold=slow ? 2 : 1, cap=slow ? 6 : 4;
        // Readiness signal + time cap: the app's own native picture (drawn by
        // Dashboard behind the split window) must exist for ≥2s, or 6s must
        // have passed since the launch request. Never before 2s.
        NSInteger budget=240;
        UIView *native=[r.controller isKindOfClass:UIViewController.class] ? ((UIViewController *)r.controller).viewIfLoaded : nil;
        if (launchSurfaceSince<=0 && native && TAHasHostedSurface(native.layer,0,&budget)) {
            launchSurfaceSince=now; TALog(@"LAUNCH IN PANE native picture seen %@ after %.1fs",bundle,now-launchStart);
        }
        settledApp=now-launchStart>=floor && ((launchSurfaceSince>0 && now-launchSurfaceSince>=hold) || now-launchStart>=cap);
    }
    BOOL ready=r && TADirectReady(r) && now-lastNativeTransition>=0.8 && settledApp;
    if (ready && slots[slot] && ![slots[slot].bundle isEqual:bundle]) {
        // Now release the previous app (it is backgrounded by us, afterwards).
        TAClearSlot(slot,@"replaced after launch");
        [choose[slot] setImage:TAAppIcon(bundle) forState:UIControlStateNormal];
        [choose[slot] setTitle:[NSString stringWithFormat:@"  Đang mở %@…",TAAppName(bundle)] forState:UIControlStateNormal];
        choose[slot].enabled=NO;
    }
    if (ready && !slots[slot]) {
        launchBundle=nil;
        TALog(@"LAUNCH IN PANE ready %@ attempt=%lu",bundle,(unsigned long)attempt);
        [self attach:bundle slot:slot];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),dispatch_get_main_queue(),^{ launchGuardUntil=0; });
        return;
    }
    if (attempt>=64) {
        launchBundle=nil; launchGuardUntil=0;
        [self failAttach:slot bundle:bundle reason:@"app did not start within 16s"]; return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self waitLaunch:attempt+1 generation:token]; });
}
// Rebuild the pair once the newly opened app has settled natively. Only for
// template apps: auto-rebuilding right after a YouTube (non-template) launch
// hung CarPlay in 0.31–0.33. For those, the next edge pull uses the pair.
- (void)autoRejoin:(NSUInteger)attempt {
    if (running || primeBundle || !openBundle) return;
    NSString *bundle=openBundle;
    TARecord *r=records[bundle];
    BOOL settled=NSProcessInfo.processInfo.systemUptime-lastNativeTransition>=1.25;
    BOOL ready=r && TADirectReady(r) && [nativeForeground isEqual:bundle];
    if (!(ready && settled)) {
        if (attempt>=40) { TALog(@"AUTO REJOIN gave up %@",bundle); return; }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ [self autoRejoin:attempt+1]; });
        return;
    }
    BOOL templ=[[TAValue(r.controller,@"sceneID") componentsSeparatedByString:@":"] count]==3;
    if (!templ) { TALog(@"AUTO REJOIN skipped %@ (non-template): edge pull will pair it with %@",bundle,openKeep); return; }
    NSMutableArray *selection=[@[@"",@""] mutableCopy];
    selection[openSlot]=bundle; if (openKeep.length) selection[1-openSlot]=openKeep;
    openBundle=nil; openKeep=nil;
    TALog(@"AUTO REJOIN left=%@ right=%@",selection[0],selection[1]);
    [self start];
    if (running) [self restoreSelection:selection];
}
- (void)waitPreparation:(NSString *)bundle slot:(NSInteger)slot generation:(NSUInteger)token attempt:(NSUInteger)attempt {
    if (running || generation!=token || ![primeBundle isEqual:bundle]) return;
    BOOL ready=primeSawForeground && TADirectReady(records[bundle]);
    BOOL settled=NSProcessInfo.processInfo.systemUptime-lastNativeTransition>=1.25;
    if ((ready && settled && attempt>=5) || attempt>=40) {
        NSMutableArray *selection=[primeSelection mutableCopy];
        BOOL success=ready && settled;
        if (!success) selection[slot]=@"";
        primeBundle=nil; primeSelection=nil; primePrevious=nil; primeSawForeground=NO;
        TALog(@"PREPARE END bundle=%@ success=%d attempt=%lu",bundle,success,(unsigned long)attempt);
        [self start];
        if (!running) return;
        [self restoreSelection:selection];
        if (!success) [self failAttach:slot bundle:bundle reason:@"native preparation did not settle"];
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self waitPreparation:bundle slot:slot generation:token attempt:attempt+1];
    });
}
- (void)attach:(NSString *)bundle slot:(NSInteger)slot {
    if (!running || slot<0 || slot>1 || slots[slot]) return;
    TARecord *r=records[bundle], *other=slots[1-slot];
    if ([other.bundle isEqual:bundle] || (r.controller && other.controller==r.controller)) return;
    if (other.attaching) {
        NSUInteger request=++slotRequests[slot];
        choose[slot].enabled=NO; [choose[slot] setTitle:@"Đang chuẩn bị…" forState:UIControlStateNormal];
        [self waitAttach:bundle slot:slot generation:generation request:request attempt:0]; return;
    }
    if (!TADirectReady(r)) { [self failAttach:slot bundle:bundle reason:@"no live scene; select again to prepare"]; return; }
    retryTargets[slot]=nil; slots[slot]=r; r.restoreBackground=r.backgrounded; r.attaching=YES;
    r.foregroundIssued=NO;
    NSUInteger token=generation, request=++slotRequests[slot];
    [choose[slot] setImage:nil forState:UIControlStateNormal]; choose[slot].hidden=NO; choose[slot].enabled=NO;
    [choose[slot] setTitle:[NSString stringWithFormat:@"Đang mở %@…",TAAppName(bundle)] forState:UIControlStateNormal];
    TALog(@"DIRECT FOREGROUND BEGIN side=%ld bundle=%@ controller=%p",(long)slot,bundle,r.controller);
    BOOL previous=ownCall; ownCall=YES;
    @try {
        // Reuse only a live controller with captured native activation settings.
        // Do not dispatch a second Dashboard launch or invent its completion.
        if (r.backgrounded) {
            ((void(*)(id,SEL,id,id))objc_msgSend)(r.controller,NSSelectorFromString(@"foregroundSceneWithSettings:completion:"),r.activation,nil);
        } else {
            TALog(@"DIRECT REUSE FOREGROUND bundle=%@",bundle);
        }
        r.foregroundIssued=YES;
        TALog(@"DIRECT FOREGROUND RETURNED side=%ld bundle=%@",(long)slot,bundle);
    } @catch (NSException *e) {
        ownCall=previous; [self failAttach:slot bundle:bundle reason:e.name]; return;
    }
    ownCall=previous;
    if (!running || generation!=token || slotRequests[slot]!=request || slots[slot]!=r) return;
    [self finishAttach:slot generation:token request:request attempt:0];
}
- (void)waitAttach:(NSString *)bundle slot:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt {
    if (!running || generation!=token || slotRequests[slot]!=request || slots[slot]) return;
    if (!slots[1-slot].attaching) {
        choose[slot].enabled=YES;
        [choose[slot] setTitle:@"Chạm để chọn ứng dụng" forState:UIControlStateNormal];
        [self attach:bundle slot:slot]; return;
    }
    if (attempt>=40) { [self failAttach:slot bundle:bundle reason:@"activation queue timeout"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self waitAttach:bundle slot:slot generation:token request:request attempt:attempt+1];
    });
}
- (void)finishAttach:(NSInteger)slot generation:(NSUInteger)token request:(NSUInteger)request attempt:(NSUInteger)attempt {
    if (!running || generation!=token || slotRequests[slot]!=request || !slots[slot].attaching) return;
    TARecord *r=slots[slot]; id live=TAValue(r.controller,@"scene"); CGRect frame=CGRectZero;
    BOOL ready=TAReadFrame(live,&frame) && r.foregroundIssued;
    if (r.presentation && live!=r.scene) { [self failAttach:slot bundle:r.bundle reason:@"scene replaced while attaching"]; return; }
    if (ready && attempt>=2 && !r.presentation) {
        BOOL previous=ownCall; ownCall=YES;
        @try {
            TAResize(r,panes[slot].bounds.size);
            if (!running || slots[slot]!=r || !r.frameCaptured) @throw [NSException exceptionWithName:@"SceneNotReady" reason:r.bundle userInfo:nil];
            SEL create=NSSelectorFromString(@"presentationViewWithIdentifier:");
            if (!TAObjectMethod(r.controller,create,1)) @throw [NSException exceptionWithName:@"MissingPresentationAPI" reason:r.bundle userInfo:nil];
            r.presentationID=[NSString stringWithFormat:@"com.sushibta.multita.beta.%lu.%ld.%lu",(unsigned long)token,(long)slot,(unsigned long)request];
            id view=((id(*)(id,SEL,id))objc_msgSend)(r.controller,create,r.presentationID);
            if (![view isKindOfClass:UIView.class] || ((UIView *)view).superview) @throw [NSException exceptionWithName:@"NotIndependent" reason:r.bundle userInfo:nil];
            // 0.42 log: Apple Maps adopted directly returned a plain UIView
            // (empty pane). Only a scene presentation view carries the app.
            if (![NSStringFromClass([view class]) containsString:@"ScenePresentation"]) {
                SEL invalidate=NSSelectorFromString(@"invalidatePresentationViewForIdentifier:");
                if ([r.controller respondsToSelector:invalidate]) ((void(*)(id,SEL,id))objc_msgSend)(r.controller,invalidate,r.presentationID);
                r.presentationID=nil;
                @throw [NSException exceptionWithName:@"no hosted surface (placeholder view)" reason:r.bundle userInfo:nil];
            }
            r.presentation=view; r.presentation.transform=CGAffineTransformIdentity; r.presentation.frame=panes[slot].bounds;
            [panes[slot] insertSubview:r.presentation belowSubview:choose[slot]];
            [r.presentation setNeedsLayout]; [r.presentation layoutIfNeeded];
            TALog(@"PRESENTATION CREATED bundle=%@ class=%@",r.bundle,NSStringFromClass(r.presentation.class));
        } @catch (NSException *e) { ownCall=previous; if (running && slots[slot]==r) [self failAttach:slot bundle:r.bundle reason:e.name]; return; }
        ownCall=previous;
    }
    NSInteger budget=240;
    BOOL surface=r.presentation && TAHasHostedSurface(r.presentation.layer,0,&budget);
    if (surface && ready) {
        choose[slot].hidden=YES; r.attaching=NO; r.backgrounded=NO; r.noSurface=NO;
        // Non-template apps (YouTube via bridge) can come back from the
        // background with a frozen picture while audio keeps playing.
        if (![r.bundle hasPrefix:@"com.apple."] && [[TAValue(r.controller,@"sceneID") componentsSeparatedByString:@":"] count]==2) {
            if (!hostedBundles) hostedBundles=[NSMutableSet new];
            [hostedBundles addObject:r.bundle];
            if (r.restoreBackground) TAKickVideo(r.bundle,@"attached from background");
        }
        TALog(@"ATTACHED slot=%ld bundle=%@ surface=1 foregroundIssued=%d attempt=%lu (not pixel validation)",(long)slot,r.bundle,r.foregroundIssued,(unsigned long)attempt);
        TARememberPair(); return;
    }
    if (attempt%4==0) TALog(@"ATTACH WAIT bundle=%@ frame=%d foregroundIssued=%d presentation=%d hostedSurface=%d",r.bundle,ready,r.foregroundIssued,r.presentation!=nil,surface);
    if (attempt>=32) { [self failAttach:slot bundle:r.bundle reason:@"no hosted surface within 8s"]; return; }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,250*NSEC_PER_MSEC),dispatch_get_main_queue(), ^{
        [self finishAttach:slot generation:token request:request attempt:attempt+1];
    });
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
        dockButton.backgroundColor=UIColor.clearColor; dockButton.accessibilityLabel=@"MultiTA — Chia màn hình";
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
    id environment=TAValue(controller,@"environment");
    if ([NSStringFromClass([environment class]) isEqual:@"DBDashboard"]) nativeDashboard=environment;
    NSString *bundle=TABundle(controller);
    if (!bundle || ![settings isKindOfClass:NSDictionary.class]) return;
    NSString *sid=TAValue(controller,@"sceneID");
    NSString *display=[sid componentsSeparatedByString:@":"].firstObject;
    if (![dashboard.session.persistentIdentifier hasSuffix:display]) return;
    BOOL launch=settings[@"DBActivationSettingLaunchSource"]!=nil;
    // Some navigation foreground callbacks omit launch-source. Preserve their
    // actual activation dictionary rather than inventing one.
    BOOL pendingBundle=[slots[0].bundle isEqual:bundle] || [slots[1].bundle isEqual:bundle] || [primeBundle isEqual:bundle];
    if ([primeBundle isEqual:bundle]) primeSawForeground=YES;
    if (!launch && ![TAClientBundles() containsObject:bundle] && !pendingBundle) return;
    TARecord *r=records[bundle];
    for (NSInteger i=0;i<2;i++) {
        TARecord *pending=slots[i];
        if (running && pending.attaching && [pending.bundle isEqual:bundle]) {
            pending.foregroundIssued=YES;
            if (pending.controller!=controller) {
                TALog(@"ATTACH REBIND side=%ld bundle=%@",(long)i,bundle);
                pending.controller=controller;
            }
            if (launch || !pending.activation) pending.activation=[settings copy];
            if (launch) pending.userLaunched=YES;
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
    if (launch) r.userLaunched=YES;
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
}
// MediaRemote (loaded lazily). Used only to resume playback after the head
// unit borrows the screen (reverse camera) — the same "play" a steering-wheel
// button sends. Nothing is sent unless audio/video was playing just before.
typedef void (*TAMRIsPlayingFn)(dispatch_queue_t, void (^)(Boolean));
typedef Boolean (*TAMRSendFn)(uint32_t, CFDictionaryRef);
static TAMRIsPlayingFn TAMRIsPlaying;
static TAMRSendFn TAMRSend;
typedef void (*TAMRDisplayIDFn)(dispatch_queue_t, void (^)(CFStringRef));
static TAMRDisplayIDFn TAMRDisplayID;
static NSTimeInterval lastPlayingSeen, interruptionStart;
static BOOL interruptionWasPlaying;
static void TALoadMediaRemote(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h=dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote",RTLD_LAZY);
        if (!h) { TALog(@"MEDIA remote unavailable"); return; }
        TAMRIsPlaying=(TAMRIsPlayingFn)dlsym(h,"MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        TAMRSend=(TAMRSendFn)dlsym(h,"MRMediaRemoteSendCommand");
        TAMRDisplayID=(TAMRDisplayIDFn)dlsym(h,"MRMediaRemoteGetNowPlayingApplicationDisplayID");
        TALog(@"MEDIA remote isPlaying=%d send=%d",TAMRIsPlaying!=NULL,TAMRSend!=NULL);
    });
}
static void TAPollPlaying(void) {
    if (!TAMRIsPlaying) return;
    TAMRIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
        if (playing) lastPlayingSeen=NSProcessInfo.processInfo.systemUptime;
    });
}
// Frozen picture, audio still running (device photo, 0.37): the user fixes
// it by pressing previous/next, which rebuilds YouTube's player. A pause/play
// pair has the same effect on the video layer without changing the track.
// Only when this exact app is the now-playing app and is playing.
static void TAKickVideo(NSString *bundle, NSString *why) {
    if (!TAMRSend || !TAMRIsPlaying || !TAMRDisplayID || !bundle.length) return;
    NSString *target=[bundle copy], *reason=[why copy];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        TAMRDisplayID(dispatch_get_main_queue(), ^(CFStringRef displayID) {
            if (![(__bridge NSString *)displayID isEqual:target]) return;
            TAMRIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
                if (!playing) return;
                TAMRSend(1,NULL);   // kMRPause
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW,350*NSEC_PER_MSEC),dispatch_get_main_queue(),^{ TAMRSend(0,NULL); });   // kMRPlay
                TALog(@"VIDEO KICK %@ reason=%@",target,reason);
            });
        });
    });
}
static void TAInterruptionBegan(NSString *why) {
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if (interruptionStart>0 && now-interruptionStart<300) return;
    interruptionStart=now;
    interruptionWasPlaying=lastPlayingSeen>0 && now-lastPlayingSeen<3.5;
    TALog(@"INTERRUPTION begin reason=%@ wasPlaying=%d",why,interruptionWasPlaying);
}
static void TAInterruptionEnded(NSString *why) {
    if (interruptionStart<=0) return;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime, duration=now-interruptionStart;
    BOOL wasPlaying=interruptionWasPlaying;
    interruptionStart=0; interruptionWasPlaying=NO;
    TALog(@"INTERRUPTION end reason=%@ after=%.1fs wasPlaying=%d",why,duration,wasPlaying);
    if (!wasPlaying || duration>300 || !TAMRSend) return;
    // Give the app time to recreate its scene, then press Play once; check
    // again and press once more if still silent.
    for (NSNumber *delay in @[@2.5,@5.0]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(delay.doubleValue*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            if (!TAMRIsPlaying) { TAMRSend(0,NULL); TALog(@"RESUME play sent (blind)"); return; }
            TAMRIsPlaying(dispatch_get_main_queue(), ^(Boolean playing) {
                if (playing) return;
                Boolean ok=TAMRSend(0,NULL);   // kMRPlay
                TALog(@"RESUME play sent ok=%d at=%.1fs",ok,delay.doubleValue);
            });
        });
    }
}
static void TAStartResponsivenessProbe(void) {
    static dispatch_source_t timer;
    if (timer) return;
    dispatch_queue_t queue=dispatch_queue_create("com.sushibta.multita.beta.heartbeat",DISPATCH_QUEUE_SERIAL);
    __block BOOL pending=NO;
    __block NSTimeInterval sent=0, lastReport=0;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,queue);
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,2*NSEC_PER_SEC),2*NSEC_PER_SEC,NSEC_PER_SEC/4);
    dispatch_source_set_event_handler(timer, ^{
        NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
        if (pending) {
            if (now-sent>=4 && now-lastReport>=10) { lastReport=now; TALog(@"MAIN STALL pid=%d waiting=%.1fs",getpid(),now-sent); }
            return;
        }
        pending=YES; sent=now;
        dispatch_async(dispatch_get_main_queue(), ^{
            dispatch_async(queue, ^{
                NSTimeInterval delay=NSProcessInfo.processInfo.systemUptime-sent;
                if (delay>=4) TALog(@"MAIN RECOVERED pid=%d delay=%.1fs",getpid(),delay);
                pending=NO;
            });
        });
    });
    dispatch_resume(timer);
}
// Heat diagnostics: every 30s (and on each iOS thermal-state change) log the
// thermal state, battery temperature/level/charging, this process's CPU use,
// and the split state, so a drive log shows when heat starts and what ran.
static double TABatteryCelsius(void) {
    typedef CFMutableDictionaryRef (*MatchFn)(const char *);
    typedef unsigned int (*ServiceFn)(unsigned int, CFDictionaryRef);
    typedef CFTypeRef (*PropFn)(unsigned int, CFStringRef, CFAllocatorRef, unsigned int);
    typedef int (*ReleaseFn)(unsigned int);
    static MatchFn matching; static ServiceFn service; static PropFn property; static ReleaseFn release;
    static BOOL loaded;
    if (!loaded) {
        loaded=YES;
        void *iokit=dlopen("/System/Library/Frameworks/IOKit.framework/IOKit",RTLD_LAZY);
        if (iokit) {
            matching=(MatchFn)dlsym(iokit,"IOServiceMatching");
            service=(ServiceFn)dlsym(iokit,"IOServiceGetMatchingService");
            property=(PropFn)dlsym(iokit,"IORegistryEntryCreateCFProperty");
            release=(ReleaseFn)dlsym(iokit,"IOObjectRelease");
        }
    }
    if (!matching || !service || !property || !release) return NAN;
    unsigned int battery=service(0,matching("AppleSmartBattery"));   // consumes the dictionary
    if (!battery) return NAN;
    CFTypeRef value=property(battery,CFSTR("Temperature"),kCFAllocatorDefault,0);
    release(battery);
    double celsius=NAN; int centi=0;
    if (value && CFGetTypeID(value)==CFNumberGetTypeID() && CFNumberGetValue((CFNumberRef)value,kCFNumberIntType,&centi)) celsius=centi/100.0;
    if (value) CFRelease(value);
    return celsius;
}
static void TALogHeat(NSString *reason) {
    static double lastCPU=-1, lastWall=0;
    struct rusage usage; getrusage(RUSAGE_SELF,&usage);
    double cpu=usage.ru_utime.tv_sec+usage.ru_utime.tv_usec/1e6+usage.ru_stime.tv_sec+usage.ru_stime.tv_usec/1e6;
    double wall=NSProcessInfo.processInfo.systemUptime;
    NSString *percent=lastCPU>=0 && wall>lastWall ? [NSString stringWithFormat:@"%.1f%%",(cpu-lastCPU)/(wall-lastWall)*100] : @"?";
    lastCPU=cpu; lastWall=wall;
    NSArray *states=@[@"nominal",@"fair",@"serious",@"critical"];
    NSInteger thermal=NSProcessInfo.processInfo.thermalState;
    UIDevice *device=UIDevice.currentDevice; device.batteryMonitoringEnabled=YES;
    NSArray *charge=@[@"unknown",@"unplugged",@"charging",@"full"];
    double celsius=TABatteryCelsius();
    TALog(@"HEAT %@ thermal=%@ battery=%@ level=%.0f%% power=%@ cpu=%@ split=%d left=%@ right=%@ ratio=%.2f",reason,
          thermal>=0 && thermal<(NSInteger)states.count ? (id)states[thermal] : (id)@(thermal),
          isnan(celsius) ? @"?" : [NSString stringWithFormat:@"%.1fC",celsius],
          device.batteryLevel*100,(NSUInteger)device.batteryState<charge.count ? (id)charge[device.batteryState] : (id)@(device.batteryState),
          percent,running,slots[0].bundle ?: @"-",slots[1].bundle ?: @"-",splitRatio);
}
static void TAHeatTick(void) {
    TALogHeat(@"tick");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{ TAHeatTick(); });
}
static void TAStartHeatLog(void) {
    static BOOL started;
    if (started) return;
    started=YES;
    [NSNotificationCenter.defaultCenter addObserverForName:NSProcessInfoThermalStateDidChangeNotification object:nil
        queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *note) { TALogHeat(@"change"); }];
    TALogHeat(@"start");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,30*NSEC_PER_SEC),dispatch_get_main_queue(),^{ TAHeatTick(); });
}
static void TATick(void) {
    UIWindowScene *s = TADashboard();
    // Track playback and the display's shape. A lost or reshaped CarPlay
    // display (reverse camera, head unit taking the screen) is an interruption;
    // getting the usual shape back ends it.
    TAPollPlaying();
    static CGSize usual;
    static __weak UIWindowScene *seenScene;
    CGSize now=s ? s.coordinateSpace.bounds.size : CGSizeZero;
    // A different display object: same shape = the screen came back; other
    // shape = a different head unit, which becomes the new reference.
    if (s && s!=seenScene) { seenScene=s; if (!CGSizeEqualToSize(now,usual) && interruptionStart<=0) usual=now; }
    if (s && usual.width<=0) usual=now;
    if (!s || !CGSizeEqualToSize(now,usual)) {
        if (usual.width>0) TAInterruptionBegan(s ? [NSString stringWithFormat:@"display %@",NSStringFromCGSize(now)] : @"display gone");
    } else if (interruptionStart>0) TAInterruptionEnded(@"display back");
    if (s != dashboard) {
        TAStop(@"display changed"); buttonWindow.hidden = YES; buttonWindow = nil;
        TARestoreDock(); [dockButton removeFromSuperview]; mountedDock=nil;
        [records removeAllObjects]; [order removeAllObjects]; dashboard = s;
        nativeForeground=nil; edgeWindow.hidden=YES; edgeWindow=nil; [TANativeSizes removeAllObjects];
        TALog(@"DISPLAY %@", s.session.persistentIdentifier);
    }
    if (running && !CGRectEqualToRect(splitWindow.frame, s.coordinateSpace.bounds)) TAStop(@"display geometry changed");
    UIView *dock=nil;
    static NSUInteger dockScan;
    BOOL scan=!running && (mountedDock.window ? NO : (dockScan++%5==0));
    if (scan) for (UIWindow *window in s.windows) {
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
        button.layer.cornerRadius=10; button.accessibilityLabel=@"MultiTA — Chia màn hình";
        [button addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:controls action:@selector(holdDock:)]];
        [buttonWindow.rootViewController.view addSubview:button];
    }
    if (s) {
        CGRect bounds=s.coordinateSpace.bounds;
        buttonWindow.frame=CGRectMake(CGRectGetMaxX(bounds)-42,CGRectGetMinY(bounds)+4,38,38);
        [buttonWindow.rootViewController.view viewWithTag:1818].frame=buttonWindow.bounds;
        BOOL fallback=NO;   // square launcher hidden by request
        buttonWindow.hidden=!fallback;
        static __weak UIWindowScene *lastScene;
        static BOOL lastFallback;
        static NSUInteger attempts;
        if (lastScene!=s) { lastScene=s; attempts=0; }
        if (lastFallback!=fallback || attempts==0) TALog(@"LAUNCHER fallback=%d dockVisible=%d running=%d",fallback,TADockButtonVisible(),running);
        lastFallback=fallback;
        // Full Dock trees are captured only by the explicit log action.
        if (attempts<4) attempts++;
    }
    TAUpdateEdge();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ TATick(); });
}
// Darwin state channels carry only dimensions, never application content.
// The host logs receipt as an observation, not proof of correct app layout.
static NSString *TAChannel(NSString *bundle, NSString *kind) {
    return [NSString stringWithFormat:@"com.sushibta.multita.beta.geometry.%@.%@", bundle, kind];
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
static BOOL TAInputTarget(UIWindow *window, NSString **bundleOut) {
    NSArray *parts=[window.windowScene.session.persistentIdentifier componentsSeparatedByString:@":"];
    if (parts.count<2 || ![parts.firstObject hasPrefix:@"Car["]) return NO;
    NSString *bundle=parts.lastObject;
    if (![TAClientBundles() containsObject:bundle]) return NO;
    int token=TATargetToken(bundle); uint64_t packed=0;
    if (token<0 || notify_get_state(token,&packed)!=NOTIFY_STATUS_OK || !packed) return NO;
    if (bundleOut) *bundleOut=bundle;
    return YES;
}
// Device hierarchy identifies this exact class as the 44pt up/down rail.
// Hide and disable the rail only while its CarPlay app has a split target;
// leave the owning scroll view and its native pan recognizer untouched.
static NSHashTable<UIView *> *TAHiddenScrollBars;
static char TAScrollBarStateKey, TAScrollBarBusyKey;
static void TAUpdateScrollBar(UIView *bar) {
    if (!NSThread.isMainThread || [objc_getAssociatedObject(bar,&TAScrollBarBusyKey) boolValue]) return;
    if (!TAHiddenScrollBars) TAHiddenScrollBars=[NSHashTable weakObjectsHashTable];
    if (bar.window) [TAHiddenScrollBars addObject:bar]; else [TAHiddenScrollBars removeObject:bar];
    BOOL active=TAInputTarget(bar.window,NULL);
    NSMutableDictionary *state=objc_getAssociatedObject(bar,&TAScrollBarStateKey);
    if (!active && !state) return;
    objc_setAssociatedObject(bar,&TAScrollBarBusyKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    @try {
        if (active) {
            if (!state) {
                state=[@{@"hidden":@(bar.hidden),@"interactive":@(bar.userInteractionEnabled)} mutableCopy];
                objc_setAssociatedObject(bar,&TAScrollBarStateKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
                TALog(@"SCROLL RAIL hidden class=%@",NSStringFromClass(bar.class));
            }
            bar.hidden=YES; bar.userInteractionEnabled=NO;
        } else {
            bar.hidden=[state[@"hidden"] boolValue]; bar.userInteractionEnabled=[state[@"interactive"] boolValue];
            objc_setAssociatedObject(bar,&TAScrollBarStateKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    } @finally { objc_setAssociatedObject(bar,&TAScrollBarBusyKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
}
static void TAListenScrollBars(void) {
    for (NSString *bundle in TAClientBundles()) {
        int token;
        notify_register_dispatch(TAChannel(bundle,@"layout-target").UTF8String,&token,dispatch_get_main_queue(), ^(__unused int delivered) {
            for (UIView *bar in TAHiddenScrollBars.allObjects) TAUpdateScrollBar(bar);
        });
    }
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
    // 0.46.2: every template app with a split target reclaims the 45pt
    // leading inset meant for the Dock, which is not beside a pane (0.46 did
    // this for Google Maps only, so other apps drew shifted right in a pane).
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
            // Cap by the physical display, not the pane: a pane narrower than
            // 180pt made 25% of its width smaller than the 45pt Dock inset, so
            // narrow panes kept the inset and drew shifted right (0.10.10 fix).
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
            if (kTADiag) { NSUInteger evidence = 60; TALayoutEvidence(root.view, currentBundle, 0, &evidence); }
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
                    if (!kTADiag) continue;
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
    if (!kTADiag) return;
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
    if (!kTADiag) return;
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
    if (!kTADiag) return;
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
    notify_register_dispatch("com.sushibta.multita.beta.snapshot", &token, dispatch_get_main_queue(), ^(__unused int delivered) {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) TACaptureVisible(w, @"manual");
        }
    });
}
// Record only bounded gesture summaries in targeted CarPlay client windows.
// No gesture delegates, event replacement or coordinate remapping.
static void TATraceClientTouch(UIWindow *window, UIEvent *event) {
    if (!kTADiag) return;
    if (event.type!=UIEventTypeTouches || !NSThread.isMainThread) return;
    NSString *bundle=nil; if (!TAInputTarget(window,&bundle)) return;
    static char touchKey, countKey;
    NSUInteger count=[objc_getAssociatedObject(window,&countKey) unsignedIntegerValue];
    if (count>=40) return;
    for (UITouch *touch in [event touchesForWindow:window]) {
        CGPoint point=[touch locationInView:window];
        NSMutableDictionary *state=objc_getAssociatedObject(touch,&touchKey);
        if (touch.phase==UITouchPhaseBegan) {
            UIView *view=touch.view; UIScrollView *scroll=nil;
            for (UIView *v=view;v && v!=window;v=v.superview) if ([v isKindOfClass:UIScrollView.class]) { scroll=(UIScrollView *)v; break; }
            state=[@{@"start":[NSValue valueWithCGPoint:point],@"max":@0,
                     @"view":NSStringFromClass(view.class) ?: @"nil",
                     @"offset":[NSValue valueWithCGPoint:scroll ? scroll.contentOffset : CGPointZero]} mutableCopy];
            objc_setAssociatedObject(touch,&touchKey,state,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
        if (!state) continue;
        CGPoint start=[state[@"start"] CGPointValue];
        state[@"max"]=@(MAX([state[@"max"] doubleValue],hypot(point.x-start.x,point.y-start.y)));
        if (touch.phase==UITouchPhaseEnded || touch.phase==UITouchPhaseCancelled) {
            UIScrollView *scroll=nil;
            for (UIView *v=touch.view;v && v!=window;v=v.superview) if ([v isKindOfClass:UIScrollView.class]) { scroll=(UIScrollView *)v; break; }
            TALog(@"INPUT bundle=%@ phase=%ld target=%@ start=%@ end=%@ travel=%.2f scroll=%@ offsetBefore=%@ offsetAfter=%@ pan=%ld window=%@",
                  bundle,(long)touch.phase,state[@"view"],NSStringFromCGPoint(start),NSStringFromCGPoint(point),[state[@"max"] doubleValue],
                  NSStringFromClass(scroll.class),NSStringFromCGPoint([state[@"offset"] CGPointValue]),NSStringFromCGPoint(scroll ? scroll.contentOffset : CGPointZero),
                  (long)scroll.panGestureRecognizer.state,NSStringFromCGRect(window.bounds));
            objc_setAssociatedObject(touch,&touchKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            objc_setAssociatedObject(window,&countKey,@(++count),OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        }
    }
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

%group TAScrollRail
%hook _UIStaticScrollBar
- (void)didMoveToWindow { %orig; TAUpdateScrollBar((UIView *)self); }
- (void)layoutSubviews { %orig; TAUpdateScrollBar((UIView *)self); }
- (void)setHidden:(BOOL)hidden {
    if (![objc_getAssociatedObject(self,&TAScrollBarBusyKey) boolValue]) {
        NSMutableDictionary *state=objc_getAssociatedObject(self,&TAScrollBarStateKey);
        if (state) state[@"hidden"]=@(hidden);
        if (state && TAInputTarget(((UIView *)self).window,NULL)) hidden=YES;
    }
    %orig(hidden);
}
- (void)setUserInteractionEnabled:(BOOL)enabled {
    if (![objc_getAssociatedObject(self,&TAScrollBarBusyKey) boolValue]) {
        NSMutableDictionary *state=objc_getAssociatedObject(self,&TAScrollBarStateKey);
        if (state) state[@"interactive"]=@(enabled);
        if (state && TAInputTarget(((UIView *)self).window,NULL)) enabled=NO;
    }
    %orig(enabled);
}
%end
%end
#import "TAKeyboard.h"
// The per-pane side buttons this hid (0.10.21) no longer exist; the keyboard
// window already sits above the split window and floatingActions is hidden.
static void TAHideSideActions(void) {}

// 0.46.1: the only code in CarPlayTemplateUIHost — pane inset reclaim.
%group TAInsetOnly
%hook UIWindow
- (void)layoutSubviews {
    %orig;
    TATemplateLayout(self);
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
- (void)sendEvent:(UIEvent *)event {
    %orig;
    TATraceClientTouch(self,event);
}
- (void)layoutSubviews {
    %orig;
    TAClientObserve(self);
    TATemplateLayout(self);
}
%end
%end
%group TAHost
%hook DBDashboard
- (void)_handleCarPlayUIReady {
    nativeDashboard=self;
    %orig;
}
- (void)_launchAppWithInfo:(id)info forURL:(id)url {
    nativeDashboard=self;
    TALog(@"DASHBOARD launch argument=%@",NSStringFromClass([info class]));
    %orig;
}
%end
%hook UIView
- (void)layoutSubviews {
    %orig;
    if (!running && self==mountedDock && !dockAdjusting) TAInstallDock(self);
}
%end
// Locate the first Dock icon by hit-testing down the left edge of the
// display, so the swipe zone needs no Dock class name (the class-based Dock
// search found nothing on some head units). The zone covers the Dock from
// the top (clock, signal, Wi-Fi) down to just above that icon.
static BOOL TAOwnWindow(UIWindow *w) {
    return w==edgeWindow || w==splitWindow || w==buttonWindow || w==TAKBWindow;
}
static UIPanGestureRecognizer *dockSwipe;
static NSArray<UIWindow *> *TADockProbeWindows(UIWindowScene *s) {
    return [s.windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *c) {
        return a.windowLevel>c.windowLevel ? NSOrderedAscending : a.windowLevel<c.windowLevel ? NSOrderedDescending : NSOrderedSame;
    }];
}
// One-time record of what sits along the left edge (window, hit view and two
// ancestors every 12pt), so a missed Dock can be matched from a single log.
static void TALogDockProbe(UIWindowScene *s) {
    static __weak UIWindowScene *logged;
    if (logged==s) return;
    logged=s;
    CGRect b=s.coordinateSpace.bounds;
    TALog(@"DOCK PROBE display=%@",NSStringFromCGRect(b));
    for (CGFloat y=CGRectGetMinY(b)+6;y<CGRectGetMaxY(b);y+=12) {
        for (UIWindow *w in TADockProbeWindows(s)) {
            if (w.hidden || w.alpha<0.01 || TAOwnWindow(w)) continue;
            UIView *hit=[w hitTest:[w convertPoint:CGPointMake(CGRectGetMinX(b)+20,y) fromCoordinateSpace:s.coordinateSpace] withEvent:nil];
            if (!hit) continue;
            NSMutableString *chain=[NSMutableString string];
            NSUInteger depth=0;
            for (UIView *v=hit;v && v!=w && depth<3;v=v.superview,depth++)
                [chain appendFormat:@" %@%@%@",NSStringFromClass(v.class),NSStringFromCGRect([v convertRect:v.bounds toCoordinateSpace:s.coordinateSpace]),
                    [v isKindOfClass:UIControl.class] || v.gestureRecognizers.count ? @"*" : @""];
            TALog(@"DOCK PROBE y=%.0f window=%@%@",y,NSStringFromClass(w.class),chain);
            break;
        }
    }
}
static CGRect TAFindDockZone(UIWindowScene *s) {
    CGRect b=s.coordinateSpace.bounds;
    TALogDockProbe(s);
    NSArray<UIWindow *> *windows=TADockProbeWindows(s);
    CGFloat limit=MAX(96,round(b.size.width*0.16));   // largest plausible Dock icon
    // Probe several x positions: the Dock is wider than 44pt on large screens.
    for (NSNumber *probeX in @[@12,@20,@30,@42]) {
        CGFloat probe=CGRectGetMinX(b)+probeX.doubleValue;
        for (CGFloat y=CGRectGetMinY(b)+6;y<CGRectGetMinY(b)+b.size.height*0.8;y+=3) {
            for (UIWindow *w in windows) {
                if (w.hidden || w.alpha<0.01 || TAOwnWindow(w)) continue;
                CGPoint point=[w convertPoint:CGPointMake(probe,y) fromCoordinateSpace:s.coordinateSpace];
                UIView *hit=[w hitTest:point withEvent:nil];
                for (UIView *v=hit;v && v!=w;v=v.superview) {
                    CGRect f=[v convertRect:v.bounds toCoordinateSpace:s.coordinateSpace];
                    BOOL iconSized=f.size.width>=28 && f.size.width<=limit && f.size.height>=28 && f.size.height<=limit*1.4;
                    NSString *name=NSStringFromClass(v.class);
                    BOOL iconLike=[v isKindOfClass:UIControl.class] || [name containsString:@"Icon"] || [name containsString:@"Button"] || v.gestureRecognizers.count>0;
                    if (iconSized && iconLike && CGRectGetMinY(f)>CGRectGetMinY(b)+20) {
                        CGFloat right=MIN(round(b.size.width*0.2),MAX(40,round(CGRectGetMaxX(f)+CGRectGetMinX(f)-2*CGRectGetMinX(b))));
                        CGFloat bottom=CGRectGetMinY(f)-4;
                        CGRect zone=CGRectMake(CGRectGetMinX(b),CGRectGetMinY(b),right,MAX(0,bottom-CGRectGetMinY(b)));
                        static NSString *lastFound;
                        NSString *found=[NSString stringWithFormat:@"%@ %@",name,NSStringFromCGRect(f)];
                        if (![found isEqual:lastFound]) { lastFound=found; TALog(@"DOCK ZONE icon=%@ zone=%@",found,NSStringFromCGRect(zone)); }
                        return zone;
                    }
                }
            }
        }
    }
    CGRect fallback=CGRectMake(CGRectGetMinX(b),CGRectGetMinY(b),MAX(44,round(b.size.width*0.12)),round(b.size.height*0.4));
    static BOOL loggedFallback;
    if (!loggedFallback) { loggedFallback=YES; TALog(@"DOCK ZONE fallback: no Dock icon found; zone=%@",NSStringFromCGRect(fallback)); }
    return fallback;
}
// Show the Dock swipe zone only while a captured app is open natively.
static void TAUpdateEdge(void) {
    UIWindowScene *s=dashboard;
    if (!s) { edgeWindow.hidden=YES; return; }
    if (!edgeWindow || edgeWindow.windowScene!=s) {
        edgeWindow.hidden=YES;
        edgeWindow=[[UIWindow alloc] initWithWindowScene:s];
        edgeWindow.windowLevel=UIWindowLevelAlert+75;
        edgeWindow.rootViewController=[UIViewController new];
        UIView *root=edgeWindow.rootViewController.view; root.backgroundColor=UIColor.clearColor;
        dockSwipe=[[UIPanGestureRecognizer alloc] initWithTarget:controls action:@selector(dockPull:)];
        dockSwipe.maximumNumberOfTouches=1;
        [root addGestureRecognizer:dockSwipe];
        root.accessibilityLabel=@"Vuốt sang phải để chia màn";
    }
    // Never move or hide the zone under a finger: that would cancel the swipe.
    UIGestureRecognizerState state=dockSwipe.state;
    if (staged || state==UIGestureRecognizerStateBegan || state==UIGestureRecognizerStateChanged) { edgeWindow.hidden=NO; return; }
    // Available whenever no split is open; a swipe with no usable app open
    // is rejected and logged (0.47.0 gated this on a captured foreground app,
    // and on some head units the zone never appeared).
    BOOL show=!running && !primeBundle;
    // The Dock changes with the open app: re-measure when the zone appears and
    // every 3s while shown. Hit-testing skips MultiTA's own windows.
    static NSTimeInterval measured;
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if (show && (edgeWindow.hidden || now-measured>=3)) {
        measured=now;
        CGRect zone=TAFindDockZone(s);
        dockZoneRight=CGRectGetMaxX(zone);
        if (zone.size.height>=24) edgeWindow.frame=zone; else show=NO;
    }
    if (edgeWindow.hidden==show)
        TALog(@"DOCK ZONE %@ frame=%@ current=%@ captured=%d",show ? @"shown" : @"hidden",NSStringFromCGRect(edgeWindow.frame),nativeForeground ?: @"-",nativeForeground.length && records[nativeForeground]!=nil);
    edgeWindow.hidden=!show;
}
%hook DBApplicationSceneViewController
- (void)foregroundSceneWithSettings:(id)settings completion:(id)completion {
    BOOL external=!ownCall;
    lastNativeTransition=NSProcessInfo.processInfo.systemUptime;
    TALog(@"FOREGROUND controller=%p sid=%@ running=%d own=%d pending=%d",self,TAValue(self,@"sceneID"),running,ownCall,TAAttachPending());
    NSString *bundle=TABundle(self);
    BOOL current=slots[0].controller==self || slots[1].controller==self || [slots[0].bundle isEqual:bundle] || [slots[1].bundle isEqual:bundle];
    BOOL launch=[settings isKindOfClass:NSDictionary.class] && settings[@"DBActivationSettingLaunchSource"]!=nil;
    if (external && running && !TAAttachPending() && !current && bundle && [settings isKindOfClass:NSDictionary.class] && (launch || [TAClientBundles() containsObject:bundle])) TALog(@"NATIVE LAUNCH retain split bundle=%@",bundle);
    if (external) TACapture(self,settings);
    %orig;
    lastNativeTransition=NSProcessInfo.processInfo.systemUptime;
    TALog(@"FOREGROUND NATIVE RETURNED bundle=%@ own=%d",bundle,ownCall);
    TARecord *foregroundRecord=records[bundle ?: @""];
    if (foregroundRecord.controller==self) foregroundRecord.backgrounded=NO;
    if (external && !running && bundle) { nativeForeground=bundle; dispatch_async(dispatch_get_main_queue(), ^{ TAUpdateEdge(); }); }
    if (external && !running && bundle) {
        // Learn the native app size; repair a scene still at a split size
        // (device photo: Google Maps full screen showing only ~208pt of map).
        id nativeScene=TAValue(self,@"scene"); CGRect f=CGRectZero;
        if (TAReadFrame(nativeScene,&f)) {
            // Learned per app (0.43 learned one global size from a full-display
            // app and restored others over the Dock). Never wider than the display.
            if (!TANativeSizes) TANativeSizes=[NSMutableDictionary new];
            CGSize known=TANativeSizeFor(bundle);
            CGFloat displayWidth=dashboard.coordinateSpace.bounds.size.width;
            if (f.size.width>known.width+0.5 && f.size.width<=displayWidth+0.5) TANativeSizes[bundle]=[NSValue valueWithCGSize:f.size];
            else if (known.width>0 && f.size.width<known.width-1 && TAHasUpdater(nativeScene,@"updateSettingsWithBlock:")) {
                CGRect fixed=(CGRect){f.origin,known};
                @try {
                    ((void(*)(id,SEL,id))objc_msgSend)(nativeScene,NSSelectorFromString(@"updateSettingsWithBlock:"),^(id settings){ TASetFrame(settings,fixed); });
                    TALog(@"NATIVE FRAME REPAIRED %@ %@ -> %@",bundle,NSStringFromCGSize(f.size),NSStringFromCGSize(known));
                } @catch (NSException *e) { TALog(@"NATIVE FRAME REPAIR error %@",e.name); }
            }
        }
    }
    if (external && running && bundle && [bundle isEqual:launchBundle]) nativeForeground=bundle;
    if (external && bundle && [hostedBundles containsObject:bundle]) TAKickVideo(bundle,@"native foreground after split");
    if (external && interruptionStart>0) {
        NSString *b=[bundle copy];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,NSEC_PER_SEC),dispatch_get_main_queue(),^{ TAInterruptionEnded([@"foreground " stringByAppendingString:b ?: @"?"]); });
    }
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
            if (running && lateBundle && activation[@"DBActivationSettingLaunchSource"] && ![lateBundle isEqual:launchBundle] && ![slots[0].bundle isEqual:lateBundle] && ![slots[1].bundle isEqual:lateBundle]) [controls offerNative:lateBundle];
        });
    }
}
- (void)backgroundSceneWithCompletion:(id)completion {
    TARecord *r=records[TABundle(self) ?: @""];
    if (!ownCall && running && NSProcessInfo.processInfo.systemUptime<launchGuardUntil && r && r.controller==self && (r==slots[0] || r==slots[1])) {
        // Dashboard switches its own "current app" to the one being launched
        // into the other pane. Keep this pane's app running; it is backgrounded
        // properly when the split ends (restoreBackground).
        r.restoreBackground=YES;
        TALog(@"BACKGROUND DECLINED during in-pane launch bundle=%@",r.bundle);
        if (completion) ((void(^)(BOOL))completion)(YES);
        return;
    }
    BOOL owned=!ownCall && running && r && r.controller==self && (r==slots[0] || r==slots[1]);
    NSUInteger token=generation, serial=r.resizeSerial;
    if (r.controller==self) r.backgrounded=YES;
    lastNativeTransition=NSProcessInfo.processInfo.systemUptime;
    TALog(@"BACKGROUND NATIVE BEGIN bundle=%@ owned=%d",r.bundle,owned);
    if (!ownCall && !running && [TABundle(self) isEqual:nativeForeground]) { nativeForeground=nil; TAUpdateEdge(); }
    %orig;
    lastNativeTransition=NSProcessInfo.processInfo.systemUptime;
    TALog(@"BACKGROUND NATIVE RETURNED bundle=%@ owned=%d",r.bundle,owned);
    if (owned) dispatch_async(dispatch_get_main_queue(), ^{
        if (!running || generation!=token || r.resizeSerial!=serial || !r.backgrounded) return;
        // Surface a lost native session instead of fighting Dashboard in a
        // foreground/background loop. Only an explicit user retry reopens it.
        for (NSInteger slot=0;slot<2;slot++) if (slots[slot]==r) {
            r.restoreBackground=NO;
            [controls failAttach:slot bundle:r.bundle reason:@"native session backgrounded; tap to reopen"];
        }
    });
}
- (id)presentationViewWithIdentifier:(id)identifier {
    if (!ownCall && !running && !staged && [identifier isEqual:@"kCARAppToHomeAnimationIdentifier"]) { nativeForeground=nil; TAUpdateEdge(); }
    if (!ownCall && running && [identifier isEqual:@"kCARAppToHomeAnimationIdentifier"]) {
        if (TAAttachPending()) TALog(@"HOME TRANSITION during attach (session retained)");
        else TALog(@"HOME TRANSITION retain split bundle=%@",TABundle(self));
    }
    return %orig;
}
- (void)sceneManager:(id)manager didDestroyScene:(id)scene {
    NSString *bundle=TABundle(self); TARecord *r=records[bundle ?: @""];
    id currentScene=TAValue(self,@"scene");
    BOOL affected=r && r.controller==self && scene && r.scene==scene;
    TALog(@"SCENE DESTROY bundle=%@ destroyed=%p current=%p owned=%p affected=%d pending=%d",bundle,scene,currentScene,r.scene,affected,r.attaching);
    // Scenes of two different apps destroyed within 0.5s = the head unit took
    // the screen (normal app switching destroys one app's scenes at a time).
    static NSTimeInterval lastDestroy; static NSString *lastDestroyBundle;
    NSTimeInterval destroyedAt=NSProcessInfo.processInfo.systemUptime;
    // Every controller is told about every destroyed scene, so only count a
    // destruction of this controller's own scene (current or owned by us).
    BOOL own=scene && (scene==currentScene || scene==r.scene);
    if (own) {
        if (bundle && lastDestroyBundle && ![bundle isEqual:lastDestroyBundle] && destroyedAt-lastDestroy<0.5)
            TAInterruptionBegan(@"scenes of several apps destroyed");
        lastDestroy=destroyedAt; lastDestroyBundle=[bundle copy];
    }
    NSUInteger token=generation;
    %orig;
    if (!affected) return;
    // Native destruction finishes before we release our presentation. Requests
    // with no owned scene remain pending and use the bounded attach timeout.
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!running || generation!=token || r.scene!=scene) return;
        for (NSInteger slot=0;slot<2;slot++) if (slots[slot]==r) {
            r.changed=NO; r.restoreBackground=NO;
            [controls failAttach:slot bundle:r.bundle reason:@"owned scene destroyed"];
        }
    });
}
%end
%end
%ctor {
    @autoreleasepool {
        NSString *process = NSBundle.mainBundle.bundleIdentifier;

        // Shared keyboard: restore the last proven common-keyboard path.
        if ([TAClientBundles() containsObject:process] &&
            ![process isEqual:@"com.google.ios.youtube"] &&
            ![process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
            dispatch_async(dispatch_get_main_queue(), ^{ TAKBInstallClients(); });
            return;
        }
        // YouTube is a full UIKit app bridged into CarPlay. It hung repeatedly
        // after being hosted; keep MultiTA code out of its process entirely.
        if ([process isEqual:@"com.google.ios.youtube"]) return;
        // 0.44 stable base: all in-app layout experiments (45pt inset reclaim,
        // tab-title/image-row compaction, scroll-rail hiding, Now Playing art)
        // are off. Apps draw in a pane exactly as CarPlay renders them.
        if ([process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
            %init(TAInsetOnly);
            dispatch_async(dispatch_get_main_queue(), ^{ TAKBInstallClients(); });
            dispatch_async(dispatch_get_main_queue(), ^{ TAListenTemplateTargets(); });
            return;
        }
        if (![process isEqual:@"com.apple.CarPlayApp"]) return;
        if ([TAClientBundles() containsObject:process] || [process isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
            %init(TAClient);
            if (NSClassFromString(@"_UIStaticScrollBar")) {
                %init(TAScrollRail);
                dispatch_async(dispatch_get_main_queue(), ^{ TAListenScrollBars(); });
            }
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
        dispatch_async(dispatch_get_main_queue(), ^{ TAKBInstallHost(); });
        dispatch_async(dispatch_get_main_queue(), ^{ TALog(@"LOADED pid=%d",getpid()); TAStartResponsivenessProbe(); TAStartHeatLog(); TALoadMediaRemote(); for (NSString *b in TAClientBundles()) TASetLayoutTarget(b, CGSizeZero); TAListenClients(); TATick(); });
    }
}
