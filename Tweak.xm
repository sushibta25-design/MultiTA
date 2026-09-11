#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>

static NSString * const kTracePath =
    @"/var/mobile/DuoPhoneV3Trace.txt";

static CFStringRef const kBridgeRequest =
    CFSTR("com.duophone.appbridge.request");

static CFStringRef const kBridgeReply =
    CFSTR("com.duophone.appbridge.reply");

static UIWindow *gDividerWindow = nil;
static UIView *gDivider = nil;
static UILabel *gDividerLabel = nil;
static CGFloat gSplitRatio = 0.70;
static CGFloat gDragStartCenterX = 0.0;
static BOOL gDragging = NO;
static BOOL gRefreshRunning = NO;
static BOOL gSpringBoardMapDone = NO;
static BOOL gSpringBoardHostProbeDone = NO;
static BOOL gSpringBoardActivationProbeDone = NO;
static BOOL gV33ActivationHooksInstalled = NO;
static id gV34CapturedMapsEntity = nil;
static id gV34CapturedMapsActivationSettings = nil;
static id gV34CarPlayDisplayConfiguration = nil;
static BOOL gV34ActivationAttempted = NO;
static id gV35CarPlayDisplayIdentity = nil;
static id gV35CarPlayDisplayConfiguration = nil;
static BOOL gV35LoggedIdentityRuntime = NO;
static BOOL gV36CarPlayRuntimeProbeDone = NO;
static BOOL gV361SingletonProbeDone = NO;
static NSUInteger gV362CarDisplayProbePass = 0;
static id gV32Application = nil;
static id gV32Entity = nil;
static id gV32SceneHandle = nil;
static id gV32SceneViewController = nil;
static BOOL gCarPlayBridgeRequestSent = NO;
static BOOL gV370CarPlaySceneHostMapDone = NO;
static BOOL gV371ContextProbeDone = NO;
static BOOL gV372LayerProbeDone = NO;
static BOOL gV380CloneAttachDone = NO;
static id gV380CloneSceneLayer = nil;
static BOOL gV3802RollbackScheduled = NO;
static BOOL gV390SceneViewProbeDone = NO;
static BOOL gV391CarDisplayEntityProbeDone = NO;
static BOOL gV392CarIdentityPublished = NO;
static BOOL gV393BridgeRequestDeferredForIdentity = NO;
static BOOL gV394ProviderProbeDone = NO;
static BOOL gV395ProviderHookInstalled = NO;
static id gV395CapturedSceneHandleProvider = nil;
static id gV395CapturedDisplayIdentity = nil;
static BOOL gV397ProviderClassMapDone = NO;
static BOOL gV398ExternalManagerHooksInstalled = NO;
static id gV398CapturedExternalManager = nil;
static BOOL gV399LiveSelfHooksInstalled = NO;
static BOOL gV3910ActiveFinderDone = NO;
static BOOL gV3911CarDisplaySourceProbeDone = NO;
static id gV3911CapturedCarDisplaySource = nil;
static void DPV392PublishCarIdentityFromCarPlay(void);
static id DPV392LoadBridgedCarIdentity(void);
static void DPV391ProbeCarDisplayEntity(id application);
static void DPV394ProbeSceneHandleProvider(id application);
static void DPV395InstallProviderCaptureHooks(void);
static void DPV397ProbeProviderClassMap(id provider);
static void DPV398InstallExternalManagerCaptureHooks(void);
static void DPV399InstallLiveSelfCaptureHooks(void);
static void DPV3910FindExternalManagerFromObjectGraph(id root);
static void DPV3911ProbeCarDisplaySourceGraph(id root);
static void DPV390ProbeSceneHandleViewPath(id sceneHandle);

static const CGFloat kVisibleDividerWidth = 18.0;
static const CGFloat kGrabWidth = 42.0;
static const CGFloat kMinRatio = 0.30;
static const CGFloat kMaxRatio = 0.85;

static void DPTrace(NSString *format, ...) {
    va_list args;
    va_start(args, format);

    NSString *message =
        [[NSString alloc] initWithFormat:format arguments:args];

    va_end(args);

    NSString *prefix =
        [NSString stringWithFormat:
            @"[%@:%d] ",
            NSProcessInfo.processInfo.processName ?: @"?",
            getpid()];

    NSString *line =
        [NSString stringWithFormat:@"%@%@\n",
            prefix,
            message ?: @""];

    NSData *data =
        [line dataUsingEncoding:NSUTF8StringEncoding];

    NSFileManager *fm =
        NSFileManager.defaultManager;

    if (![fm fileExistsAtPath:kTracePath]) {
        [data writeToFile:kTracePath atomically:YES];
        return;
    }

    NSFileHandle *handle =
        [NSFileHandle fileHandleForWritingAtPath:kTracePath];

    if (!handle)
        return;

    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
        [handle closeFile];
    } @catch (__unused NSException *e) {
    }
}

static BOOL DPIsCarPlay(void) {
    return [NSBundle.mainBundle.bundleIdentifier
        isEqualToString:@"com.apple.CarPlayApp"];
}

static BOOL DPIsSpringBoard(void) {
    return [NSBundle.mainBundle.bundleIdentifier
        isEqualToString:@"com.apple.springboard"];
}

static CGFloat DPClamp(CGFloat value, CGFloat lo, CGFloat hi) {
    if (value < lo)
        return lo;

    if (value > hi)
        return hi;

    return value;
}

static UIWindowScene *DPBestCarPlayScene(void) {
    UIWindowScene *fallback = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        UIWindowScene *ws =
            (UIWindowScene *)scene;

        if (!fallback)
            fallback = ws;

        if (scene.activationState ==
            UISceneActivationStateForegroundActive)
            return ws;
    }

    return fallback;
}

@interface DuoPhoneDividerWindow : UIWindow
@end

@implementation DuoPhoneDividerWindow
@end

@interface DuoPhonePanTarget : NSObject
@end

static DuoPhonePanTarget *gPanTarget = nil;

static void DPLayoutDivider(void) {
    if (!gDividerWindow)
        return;

    UIWindowScene *scene =
        DPBestCarPlayScene();

    if (!scene)
        return;

    CGRect bounds =
        scene.coordinateSpace.bounds;

    CGFloat width =
        CGRectGetWidth(bounds);

    CGFloat height =
        CGRectGetHeight(bounds);

    if (width <= 0.0 || height <= 0.0)
        return;

    CGFloat centerX =
        floor(width * gSplitRatio);

    [UIView performWithoutAnimation:^{
        gDividerWindow.frame =
            CGRectMake(
                centerX - kGrabWidth * 0.5,
                0.0,
                kGrabWidth,
                height
            );

        gDivider.frame =
            CGRectMake(
                (kGrabWidth - kVisibleDividerWidth) * 0.5,
                0.0,
                kVisibleDividerWidth,
                height
            );

        gDividerLabel.frame =
            gDivider.bounds;
    }];
}

@implementation DuoPhonePanTarget

- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIWindowScene *scene =
        DPBestCarPlayScene();

    if (!scene || !gDividerWindow)
        return;

    CGFloat width =
        CGRectGetWidth(scene.coordinateSpace.bounds);

    if (width <= 0.0)
        return;

    if (pan.state == UIGestureRecognizerStateBegan) {
        gDragging = YES;
        gDragStartCenterX =
            width * gSplitRatio;
    }

    if (pan.state == UIGestureRecognizerStateBegan ||
        pan.state == UIGestureRecognizerStateChanged) {

        CGPoint translation =
            [pan translationInView:gDividerWindow];

        CGFloat centerX =
            gDragStartCenterX + translation.x;

        gSplitRatio =
            DPClamp(
                centerX / width,
                kMinRatio,
                kMaxRatio
            );

        DPLayoutDivider();
    }

    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {

        gDragging = NO;

        [NSUserDefaults.standardUserDefaults
            setDouble:gSplitRatio
            forKey:@"DuoPhoneSplitRatio"];
    }
}

@end

static void DPCreateDivider(void) {
    if (!DPIsCarPlay() || gDividerWindow)
        return;

    UIWindowScene *scene =
        DPBestCarPlayScene();

    if (!scene)
        return;

    if ([NSUserDefaults.standardUserDefaults
            objectForKey:@"DuoPhoneSplitRatio"]) {
        gSplitRatio =
            DPClamp(
                (CGFloat)[NSUserDefaults.standardUserDefaults
                    doubleForKey:@"DuoPhoneSplitRatio"],
                kMinRatio,
                kMaxRatio
            );
    }

    DuoPhoneDividerWindow *window =
        [[DuoPhoneDividerWindow alloc]
            initWithWindowScene:scene];

    window.backgroundColor =
        UIColor.clearColor;

    window.windowLevel =
        UIWindowLevelAlert + 80.0;

    UIViewController *vc =
        [UIViewController new];

    vc.view.backgroundColor =
        UIColor.clearColor;

    window.rootViewController =
        vc;

    UIView *divider =
        [UIView new];

    divider.backgroundColor =
        UIColor.whiteColor;

    divider.userInteractionEnabled =
        YES;

    divider.layer.shadowColor =
        UIColor.blackColor.CGColor;

    divider.layer.shadowOpacity =
        0.45;

    divider.layer.shadowRadius =
        6.0;

    divider.layer.shadowOffset =
        CGSizeZero;

    [vc.view addSubview:divider];

    UILabel *label =
        [UILabel new];

    label.text =
        @"↔";

    label.textAlignment =
        NSTextAlignmentCenter;

    label.font =
        [UIFont boldSystemFontOfSize:18.0];

    label.textColor =
        UIColor.blackColor;

    label.userInteractionEnabled =
        NO;

    [divider addSubview:label];

    gDividerWindow = window;
    gDivider = divider;
    gDividerLabel = label;
    gPanTarget = [DuoPhonePanTarget new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc]
            initWithTarget:gPanTarget
                    action:@selector(handlePan:)];

    pan.cancelsTouchesInView = NO;
    pan.delaysTouchesBegan = NO;
    pan.delaysTouchesEnded = NO;

    [vc.view addGestureRecognizer:pan];

    DPLayoutDivider();

    window.hidden = NO;

    DPTrace(@"V3 divider ready frame=%@",
            NSStringFromCGRect(window.frame));
}

static BOOL DPNameMatches(NSString *name) {
    if (!name)
        return NO;

    NSString *lower =
        name.lowercaseString;

    NSArray<NSString *> *tokens = @[
        @"scene",
        @"application",
        @"handle",
        @"entity",
        @"workspace",
        @"host",
        @"viewcontroller",
        @"bundle",
        @"display",
        @"activate",
        @"launch"
    ];

    for (NSString *token in tokens) {
        if ([lower containsString:token])
            return YES;
    }

    return NO;
}

static void DPMapClassNamed(NSString *className) {
    Class cls =
        NSClassFromString(className);

    if (!cls) {
        DPTrace(@"APPBRIDGE CLASS missing %@", className);
        return;
    }

    DPTrace(@"========== APPBRIDGE CLASS %@ ==========",
            className);

    DPTrace(@"class=%@ super=%@",
            NSStringFromClass(cls),
            class_getSuperclass(cls)
                ? NSStringFromClass(class_getSuperclass(cls))
                : @"nil");

    unsigned int methodCount = 0;
    Method *methods =
        class_copyMethodList(cls, &methodCount);

    for (unsigned int i = 0; i < methodCount; i++) {
        Method method =
            methods[i];

        NSString *name =
            NSStringFromSelector(method_getName(method));

        if (!DPNameMatches(name))
            continue;

        DPTrace(@"METHOD -%@ argc=%u types=%s",
                name,
                method_getNumberOfArguments(method),
                method_getTypeEncoding(method) ?: "?");
    }

    free(methods);

    Class meta =
        object_getClass(cls);

    methodCount = 0;
    methods =
        class_copyMethodList(meta, &methodCount);

    for (unsigned int i = 0; i < methodCount; i++) {
        Method method =
            methods[i];

        NSString *name =
            NSStringFromSelector(method_getName(method));

        if (!DPNameMatches(name))
            continue;

        DPTrace(@"METHOD +%@ argc=%u types=%s",
                name,
                method_getNumberOfArguments(method),
                method_getTypeEncoding(method) ?: "?");
    }

    free(methods);

    unsigned int ivarCount = 0;
    Ivar *ivars =
        class_copyIvarList(cls, &ivarCount);

    for (unsigned int i = 0; i < ivarCount; i++) {
        const char *nameC =
            ivar_getName(ivars[i]);

        NSString *name =
            nameC
                ? [NSString stringWithUTF8String:nameC]
                : nil;

        if (!DPNameMatches(name))
            continue;

        DPTrace(@"IVAR %@ type=%s offset=%td",
                name ?: @"?",
                ivar_getTypeEncoding(ivars[i]) ?: "?",
                ivar_getOffset(ivars[i]));
    }

    free(ivars);

    DPTrace(@"========== APPBRIDGE CLASS END %@ ==========",
            className);
}

static void DPSpringBoardTargetMap(void) {
    if (!DPIsSpringBoard() || gSpringBoardMapDone)
        return;

    gSpringBoardMapDone = YES;

    DPTrace(@"========== DUOPHONE V3 APPBRIDGE TARGET MAP ==========");

    NSArray<NSString *> *classes = @[
        @"SBMainWorkspace",
        @"SBDeviceApplicationSceneViewController",
        @"SBDeviceApplicationSceneHandle",
        @"SBDeviceApplicationSceneEntity",
        @"FBScene",
        @"FBSScene",
        @"UIRootSceneWindow",
        @"_UIScenePresentationView"
    ];

    for (NSString *name in classes)
        DPMapClassNamed(name);

    Class workspaceClass =
        NSClassFromString(@"SBMainWorkspace");

    NSArray<NSString *> *selectors = @[
        @"sharedInstance",
        @"sharedInstanceIfExists",
        @"sharedWorkspace",
        @"mainWorkspace"
    ];

    for (NSString *selectorName in selectors) {
        SEL sel =
            NSSelectorFromString(selectorName);

        if (!workspaceClass ||
            ![workspaceClass respondsToSelector:sel])
            continue;

        typedef id (*Fn)(id, SEL);

        Fn fn =
            (Fn)[workspaceClass methodForSelector:sel];

        if (!fn)
            continue;

        @try {
            id workspace =
                fn(workspaceClass, sel);

            DPTrace(@"SBMainWorkspace +%@ => %@ class=%@",
                    selectorName,
                    workspace ?: @"nil",
                    workspace
                        ? NSStringFromClass([workspace class])
                        : @"nil");
        } @catch (NSException *e) {
            DPTrace(@"SBMainWorkspace +%@ exception=%@",
                    selectorName,
                    e.name ?: @"?");
        }
    }

    DPTrace(@"========== DUOPHONE V3 APPBRIDGE TARGET MAP END ==========");
}


static id DPCallObjectSelector0(id obj, NSString *selectorName) {
    if (!obj || !selectorName)
        return nil;

    SEL sel =
        NSSelectorFromString(selectorName);

    if (![obj respondsToSelector:sel])
        return nil;

    typedef id (*Fn)(id, SEL);

    Fn fn =
        (Fn)[obj methodForSelector:sel];

    if (!fn)
        return nil;

    @try {
        return fn(obj, sel);
    } @catch (NSException *e) {
        DPTrace(@"V3.1 CALL %@.%@ exception=%@ reason=%@",
                NSStringFromClass([obj class]),
                selectorName,
                e.name ?: @"?",
                e.reason ?: @"?");
        return nil;
    }
}

static id DPCallObjectSelector1(id obj,
                                NSString *selectorName,
                                id arg) {
    if (!obj || !selectorName)
        return nil;

    SEL sel =
        NSSelectorFromString(selectorName);

    if (![obj respondsToSelector:sel])
        return nil;

    typedef id (*Fn)(id, SEL, id);

    Fn fn =
        (Fn)[obj methodForSelector:sel];

    if (!fn)
        return nil;

    @try {
        return fn(obj, sel, arg);
    } @catch (NSException *e) {
        DPTrace(@"V3.1 CALL %@.%@ exception=%@ reason=%@",
                NSStringFromClass([obj class]),
                selectorName,
                e.name ?: @"?",
                e.reason ?: @"?");
        return nil;
    }
}

static id DPCallClassSelector1(Class cls,
                               NSString *selectorName,
                               id arg) {
    if (!cls || !selectorName)
        return nil;

    SEL sel =
        NSSelectorFromString(selectorName);

    if (![cls respondsToSelector:sel])
        return nil;

    typedef id (*Fn)(id, SEL, id);

    Fn fn =
        (Fn)[cls methodForSelector:sel];

    if (!fn)
        return nil;

    @try {
        return fn(cls, sel, arg);
    } @catch (NSException *e) {
        DPTrace(@"V3.1 CALL +%@.%@ exception=%@ reason=%@",
                NSStringFromClass(cls),
                selectorName,
                e.name ?: @"?",
                e.reason ?: @"?");
        return nil;
    }
}

static void DPLogInterestingObjectKeys(id obj,
                                       NSString *tag) {
    if (!obj || !tag)
        return;

    DPTrace(@"V3.1 OBJECT %@ class=%@ object=%@",
            tag,
            NSStringFromClass([obj class]),
            obj);

    NSArray<NSString *> *keys = @[
        @"application",
        @"sceneHandle",
        @"applicationSceneHandle",
        @"scene",
        @"sceneIdentifier",
        @"identifier",
        @"mainScene",
        @"entity",
        @"viewController",
        @"sceneViewController",
        @"displayIdentity",
        @"display",
        @"bundleIdentifier",
        @"process"
    ];

    for (NSString *key in keys) {
        @try {
            id value =
                [obj valueForKey:key];

            DPTrace(@"V3.1 KVC %@.%@ => %@ class=%@",
                    tag,
                    key,
                    value ?: @"nil",
                    value ? NSStringFromClass([value class]) : @"nil");
        } @catch (NSException *e) {
            DPTrace(@"V3.1 KVC %@.%@ exception=%@",
                    tag,
                    key,
                    e.name ?: @"?");
        }
    }
}

static void DPSpringBoardHostProbe(void) {
    if (!DPIsSpringBoard() ||
        gSpringBoardHostProbeDone)
        return;

    gSpringBoardHostProbeDone =
        YES;

    DPTrace(@"========== DUOPHONE V3.1 HOST PROBE ==========");

    Class workspaceClass =
        NSClassFromString(@"SBMainWorkspace");

    id workspace =
        DPCallObjectSelector0(
            workspaceClass,
            @"sharedInstance"
        );

    if (!workspace) {
        workspace =
            DPCallObjectSelector0(
                workspaceClass,
                @"mainWorkspace"
            );
    }

    DPTrace(@"V3.1 workspace=%@ class=%@",
            workspace ?: @"nil",
            workspace ? NSStringFromClass([workspace class]) : @"nil");

    if (workspace)
        DPV3910FindExternalManagerFromObjectGraph(workspace);
    if (workspace)
        DPV3911ProbeCarDisplaySourceGraph(workspace);

    if (!workspace) {
        DPTrace(@"V3.1 ABORT no workspace");
        DPTrace(@"========== DUOPHONE V3.1 HOST PROBE END ==========");
        return;
    }

    NSString *bundleID =
        @"com.apple.Maps";

    id application =
        DPCallObjectSelector1(
            workspace,
            @"_applicationForIdentifier:",
            bundleID
        );

    DPTrace(@"V3.1 application bid=%@ object=%@ class=%@",
            bundleID,
            application ?: @"nil",
            application ? NSStringFromClass([application class]) : @"nil");

    if ([bundleID isEqualToString:@"com.apple.Maps"])
        DPV391ProbeCarDisplayEntity(application);

    if (!application) {
        DPTrace(@"V3.1 ABORT no application object");
        DPTrace(@"========== DUOPHONE V3.1 HOST PROBE END ==========");
        return;
    }

    DPLogInterestingObjectKeys(
        application,
        @"APPLICATION"
    );

    Class entityClass =
        NSClassFromString(@"SBDeviceApplicationSceneEntity");

    id entity =
        DPCallClassSelector1(
            entityClass,
            @"defaultEntityWithApplicationForMainDisplay:",
            application
        );

    DPTrace(@"V3.1 entity=%@ class=%@",
            entity ?: @"nil",
            entity ? NSStringFromClass([entity class]) : @"nil");

    if (!entity) {
        DPTrace(@"V3.1 ABORT entity creation failed");
        DPTrace(@"========== DUOPHONE V3.1 HOST PROBE END ==========");
        return;
    }

    DPLogInterestingObjectKeys(
        entity,
        @"ENTITY"
    );

    id sceneHandle =
        DPCallObjectSelector0(
            entity,
            @"sceneHandle"
        );

    if (!sceneHandle)
        sceneHandle =
            DPCallObjectSelector0(
                entity,
                @"applicationSceneHandle"
            );

    if (!sceneHandle)
        sceneHandle =
            DPCallObjectSelector0(
                entity,
                @"scene"
            );

    DPTrace(@"V3.1 resolvedSceneHandle=%@ class=%@",
            sceneHandle ?: @"nil",
            sceneHandle ? NSStringFromClass([sceneHandle class]) : @"nil");

    if (sceneHandle)
        DPV390ProbeSceneHandleViewPath(sceneHandle);

    if (sceneHandle) {
        DPLogInterestingObjectKeys(
            sceneHandle,
            @"SCENE_HANDLE"
        );

        id viewController =
            DPCallObjectSelector0(
                sceneHandle,
                @"newSceneViewController"
            );

        DPTrace(@"V3.1 newSceneViewController=%@ class=%@",
                viewController ?: @"nil",
                viewController
                    ? NSStringFromClass([viewController class])
                    : @"nil");

        if (viewController) {
            DPLogInterestingObjectKeys(
                viewController,
                @"SCENE_VIEW_CONTROLLER"
            );

            id contentView =
                DPCallObjectSelector0(
                    viewController,
                    @"sceneContentView"
                );

            DPTrace(@"V3.1 sceneContentView=%@ class=%@ frame=%@",
                    contentView ?: @"nil",
                    contentView
                        ? NSStringFromClass([contentView class])
                        : @"nil",
                    [contentView isKindOfClass:UIView.class]
                        ? NSStringFromCGRect(((UIView *)contentView).frame)
                        : @"nil");
        }
    }

    DPTrace(@"V3.1 NOTE no scene/view was attached to any window");
    DPTrace(@"========== DUOPHONE V3.1 HOST PROBE END ==========");
}


static id DPV32Workspace(void) {
    Class workspaceClass =
        NSClassFromString(@"SBMainWorkspace");

    if (!workspaceClass)
        return nil;

    id workspace =
        DPCallObjectSelector0(
            workspaceClass,
            @"sharedInstance"
        );

    if (!workspace)
        workspace =
            DPCallObjectSelector0(
                workspaceClass,
                @"mainWorkspace"
            );

    return workspace;
}

static void DPV32InspectHandle(NSString *tag) {
    if (!gV32SceneHandle)
        return;

    DPTrace(@"========== V3.2 HANDLE INSPECT %@ ==========",
            tag ?: @"?");

    DPTrace(@"V3.2 handle=%@ class=%@",
            gV32SceneHandle,
            NSStringFromClass([gV32SceneHandle class]));

    NSArray<NSString *> *keys = @[
        @"scene",
        @"sceneIdentifier",
        @"displayIdentity",
        @"application",
        @"process",
        @"windowScene"
    ];

    for (NSString *key in keys) {
        @try {
            id value =
                [gV32SceneHandle valueForKey:key];

            DPTrace(@"V3.2 HANDLE %@ => %@ class=%@",
                    key,
                    value ?: @"nil",
                    value ? NSStringFromClass([value class]) : @"nil");
        } @catch (NSException *e) {
            DPTrace(@"V3.2 HANDLE %@ exception=%@",
                    key,
                    e.name ?: @"?");
        }
    }

    if (gV32SceneViewController) {
        id contentView =
            DPCallObjectSelector0(
                gV32SceneViewController,
                @"sceneContentView"
            );

        DPTrace(@"V3.2 sceneContentView=%@ class=%@ frame=%@",
                contentView ?: @"nil",
                contentView
                    ? NSStringFromClass([contentView class])
                    : @"nil",
                [contentView isKindOfClass:UIView.class]
                    ? NSStringFromCGRect(((UIView *)contentView).frame)
                    : @"nil");
    }

    DPTrace(@"========== V3.2 HANDLE INSPECT END ==========");
}

static void __attribute__((unused)) DPV32ActivateMapsScene(void) {
    if (!DPIsSpringBoard() ||
        gSpringBoardActivationProbeDone)
        return;

    gSpringBoardActivationProbeDone =
        YES;

    DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE ==========");

    id workspace =
        DPV32Workspace();

    if (!workspace) {
        DPTrace(@"V3.2 ABORT no SBMainWorkspace");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    NSString *bundleID =
        @"com.apple.Maps";

    id application =
        DPCallObjectSelector1(
            workspace,
            @"_applicationForIdentifier:",
            bundleID
        );

    if (!application) {
        DPTrace(@"V3.2 ABORT no application");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    gV32Application =
        application;

    Class entityClass =
        NSClassFromString(@"SBDeviceApplicationSceneEntity");

    id entity =
        DPCallClassSelector1(
            entityClass,
            @"defaultEntityWithApplicationForMainDisplay:",
            application
        );

    if (!entity) {
        DPTrace(@"V3.2 ABORT entity failed");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    gV32Entity =
        entity;

    id handle =
        DPCallObjectSelector0(
            entity,
            @"sceneHandle"
        );

    if (!handle) {
        DPTrace(@"V3.2 ABORT sceneHandle=nil");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    gV32SceneHandle =
        handle;

    id vc =
        DPCallObjectSelector0(
            handle,
            @"newSceneViewController"
        );

    gV32SceneViewController =
        vc;

    DPTrace(@"V3.2 application=%@", application);
    DPTrace(@"V3.2 entity=%@", entity);
    DPTrace(@"V3.2 handle BEFORE=%@", handle);
    DPTrace(@"V3.2 viewController=%@", vc ?: @"nil");

    DPV32InspectHandle(@"BEFORE");

    SEL createSel =
        NSSelectorFromString(
            @"createRequestForApplicationActivation:options:"
        );

    SEL executeSel =
        NSSelectorFromString(
            @"_executeApplicationTransitionRequest:"
        );

    if (![workspace respondsToSelector:createSel] ||
        ![workspace respondsToSelector:executeSel]) {

        DPTrace(@"V3.2 ABORT activation selectors missing");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    typedef id (*CreateRequestFn)(id, SEL, id, unsigned long long);
    typedef BOOL (*ExecuteRequestFn)(id, SEL, id);

    CreateRequestFn createFn =
        (CreateRequestFn)[workspace methodForSelector:createSel];

    ExecuteRequestFn executeFn =
        (ExecuteRequestFn)[workspace methodForSelector:executeSel];

    if (!createFn || !executeFn) {
        DPTrace(@"V3.2 ABORT activation IMP missing");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    id request = nil;

    @try {
        request =
            createFn(
                workspace,
                createSel,
                application,
                0ULL
            );

        DPTrace(@"V3.2 activationRequest=%@ class=%@",
                request ?: @"nil",
                request
                    ? NSStringFromClass([request class])
                    : @"nil");
    } @catch (NSException *e) {
        DPTrace(@"V3.2 createRequest exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
    }

    if (!request) {
        DPTrace(@"V3.2 ABORT request=nil");
        DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
        return;
    }

    BOOL accepted =
        NO;

    @try {
        accepted =
            executeFn(
                workspace,
                executeSel,
                request
            );

        DPTrace(@"V3.2 executeApplicationTransitionRequest accepted=%d",
                accepted);
    } @catch (NSException *e) {
        DPTrace(@"V3.2 executeRequest exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1000 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            DPV32InspectHandle(@"PLUS_1S");
        }
    );

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            2500 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            DPV32InspectHandle(@"PLUS_2_5S");
        }
    );

    DPTrace(@"V3.2 NOTE no view is attached to CarPlay in this build");
    DPTrace(@"========== DUOPHONE V3.2 SCENE ACTIVATION PROBE END ==========");
}


static void DPV33LogActivationObject(id obj, NSString *tag) {
    if (!tag)
        return;

    if (!obj) {
        DPTrace(@"V3.3 %@ = nil", tag);
        return;
    }

    DPTrace(@"V3.3 %@ class=%@ object=%@",
            tag,
            NSStringFromClass([obj class]),
            obj);

    NSArray<NSString *> *keys = @[
        @"application",
        @"bundleIdentifier",
        @"identifier",
        @"targetApplication",
        @"targetContentIdentifier",
        @"activationSettings",
        @"settings",
        @"sceneIdentifier",
        @"displayIdentity",
        @"displayConfiguration",
        @"openApplicationOptions",
        @"request"
    ];

    for (NSString *key in keys) {
        @try {
            id value =
                [obj valueForKey:key];

            DPTrace(@"V3.3 KVC %@.%@ => %@ class=%@",
                    tag,
                    key,
                    value ?: @"nil",
                    value ? NSStringFromClass([value class]) : @"nil");
        } @catch (NSException *e) {
            DPTrace(@"V3.3 KVC %@.%@ exception=%@",
                    tag,
                    key,
                    e.name ?: @"?");
        }
    }
}

static BOOL DPV33ObjectLooksLikeMaps(id obj) {
    if (!obj)
        return NO;

    NSString *desc =
        [NSString stringWithFormat:@"%@", obj];

    if ([desc containsString:@"com.apple.Maps"])
        return YES;

    NSArray<NSString *> *keys =
        @[
            @"bundleIdentifier",
            @"identifier",
            @"targetApplication"
        ];

    for (NSString *key in keys) {
        @try {
            id value =
                [obj valueForKey:key];

            NSString *text =
                [NSString stringWithFormat:@"%@", value ?: @""];

            if ([text containsString:@"com.apple.Maps"])
                return YES;
        } @catch (__unused NSException *e) {
        }
    }

    return NO;
}



static id DPV341SafeValue(id obj, NSString *key) {
    if (!obj || !key)
        return nil;

    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static NSArray *DPV341ObjectsFromContainer(id container) {
    if (!container)
        return @[];

    if ([container isKindOfClass:NSArray.class])
        return container;

    if ([container isKindOfClass:NSSet.class])
        return [container allObjects];

    if ([container isKindOfClass:NSOrderedSet.class])
        return [container array];

    if ([container isKindOfClass:NSDictionary.class])
        return [container allValues];

    if ([container respondsToSelector:@selector(allObjects)]) {
        @try {
            id all = [container allObjects];
            if ([all isKindOfClass:NSArray.class])
                return all;
        } @catch (__unused NSException *e) {
        }
    }

    return @[];
}


static id DPV363SceneWorkspaceFromManager(id manager) {
    if (!manager)
        return nil;

    id workspace = nil;

    @try {
        workspace = [manager valueForKey:@"workspace"];
    } @catch (__unused NSException *e) {
    }

    if (workspace)
        return workspace;

    @try {
        workspace = [manager valueForKey:@"_workspace"];
    } @catch (__unused NSException *e) {
    }

    if (workspace)
        return workspace;

    Class cls = [manager class];

    while (cls) {
        Ivar ivar = class_getInstanceVariable(cls, "_workspace");
        if (ivar) {
            @try {
                workspace = object_getIvar(manager, ivar);
            } @catch (__unused NSException *e) {
            }

            if (workspace)
                return workspace;
        }

        cls = class_getSuperclass(cls);
    }

    return nil;
}

static NSArray *DPV363AllScenesFromWorkspace(id workspace) {
    if (!workspace)
        return @[];

    SEL allScenesSel = NSSelectorFromString(@"allScenes");

    if ([workspace respondsToSelector:allScenesSel]) {
        typedef id (*Fn)(id, SEL);
        Fn fn = (Fn)[workspace methodForSelector:allScenesSel];

        if (fn) {
            id value = nil;

            @try {
                value = fn(workspace, allScenesSel);
            } @catch (__unused NSException *e) {
            }

            NSArray *objects = DPV341ObjectsFromContainer(value);

            if (objects.count > 0) {
                DPTrace(@"V3.6.3 workspace allScenes count=%lu class=%@",
                        (unsigned long)objects.count,
                        NSStringFromClass([value class]));
                return objects;
            }
        }
    }

    @try {
        id dict = [workspace valueForKey:@"_allScenesByID"];

        if ([dict isKindOfClass:NSDictionary.class]) {
            NSArray *values = [dict allValues];

            DPTrace(@"V3.6.3 workspace _allScenesByID count=%lu",
                    (unsigned long)values.count);

            return values;
        }
    } @catch (__unused NSException *e) {
    }

    return @[];
}

static NSArray *DPV341EnumerateSceneCandidates(id manager) {
    if (!manager)
        return @[];

    NSMutableArray *results =
        [NSMutableArray array];

    id sceneWorkspace =
        DPV363SceneWorkspaceFromManager(manager);

    DPTrace(@"V3.6.3 manager=%@ class=%@ workspace=%@ workspaceClass=%@",
            manager,
            NSStringFromClass([manager class]),
            sceneWorkspace ?: @"nil",
            sceneWorkspace ? NSStringFromClass([sceneWorkspace class]) : @"nil");

    NSArray *workspaceScenes =
        DPV363AllScenesFromWorkspace(sceneWorkspace);

    if (workspaceScenes.count > 0)
        [results addObjectsFromArray:workspaceScenes];

    NSArray<NSString *> *selectors = @[
        @"scenes",
        @"allScenes",
        @"connectedScenes",
        @"managedScenes",
        @"sceneList"
    ];

    for (NSString *name in selectors) {
        SEL sel =
            NSSelectorFromString(name);

        if (![manager respondsToSelector:sel])
            continue;

        typedef id (*Fn)(id, SEL);

        Fn fn =
            (Fn)[manager methodForSelector:sel];

        if (!fn)
            continue;

        id value =
            nil;

        @try {
            value =
                fn(manager, sel);
        } @catch (__unused NSException *e) {
        }

        NSArray *objects =
            DPV341ObjectsFromContainer(value);

        if (objects.count > 0) {
            DPTrace(@"V3.4.1 scene source selector=%@ count=%lu class=%@",
                    name,
                    (unsigned long)objects.count,
                    NSStringFromClass([value class]));

            [results addObjectsFromArray:objects];
        }
    }

    NSArray<NSString *> *keys = @[
        @"scenes",
        @"_scenes",
        @"sceneMap",
        @"_sceneMap",
        @"workspaceScenes",
        @"_workspaceScenes"
    ];

    for (NSString *key in keys) {
        id value =
            DPV341SafeValue(
                manager,
                key
            );

        NSArray *objects =
            DPV341ObjectsFromContainer(value);

        if (objects.count > 0) {
            DPTrace(@"V3.4.1 scene source key=%@ count=%lu class=%@",
                    key,
                    (unsigned long)objects.count,
                    NSStringFromClass([value class]));

            [results addObjectsFromArray:objects];
        }
    }

    // Last resort: inspect manager ivars whose names mention scene.
    Class cls =
        [manager class];

    for (NSUInteger depth = 0;
         cls && depth < 4;
         depth++, cls = class_getSuperclass(cls)) {

        unsigned int count =
            0;

        Ivar *ivars =
            class_copyIvarList(
                cls,
                &count
            );

        for (unsigned int i = 0;
             i < count;
             i++) {

            const char *nameC =
                ivar_getName(
                    ivars[i]
                );

            if (!nameC)
                continue;

            NSString *name =
                [NSString stringWithUTF8String:nameC];

            if (![name.lowercaseString containsString:@"scene"])
                continue;

            id value =
                nil;

            @try {
                value =
                    object_getIvar(
                        manager,
                        ivars[i]
                    );
            } @catch (__unused NSException *e) {
            }

            NSArray *objects =
                DPV341ObjectsFromContainer(value);

            if (objects.count > 0) {
                DPTrace(@"V3.4.1 scene source ivar=%@ count=%lu class=%@",
                        name,
                        (unsigned long)objects.count,
                        NSStringFromClass([value class]));

                [results addObjectsFromArray:objects];
            }
        }

        if (ivars)
            free(ivars);
    }

    // De-duplicate by pointer identity.
    NSMutableArray *unique =
        [NSMutableArray array];

    NSHashTable *seen =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];

    for (id obj in results) {
        if (!obj || [seen containsObject:obj])
            continue;

        [seen addObject:obj];
        [unique addObject:obj];
    }

    return unique;
}

static id DPV341DisplayConfigurationFromScene(id scene) {
    if (!scene)
        return nil;

    id settings =
        DPV341SafeValue(
            scene,
            @"settings"
        );

    id config =
        DPV341SafeValue(
            settings,
            @"displayConfiguration"
        );

    if (!config)
        config =
            DPV341SafeValue(
                scene,
                @"displayConfiguration"
            );

    if (!config) {
        id display =
            DPV341SafeValue(
                scene,
                @"display"
            );

        config =
            DPV341SafeValue(
                display,
                @"configuration"
            );

        if (!config)
            config =
                DPV341SafeValue(
                    display,
                    @"displayConfiguration"
                );
    }

    return config;
}

static BOOL DPV341LooksLikeCarPlayScene(id scene) {
    if (!scene)
        return NO;

    NSMutableString *text =
        [NSMutableString stringWithFormat:@"%@", scene];

    NSArray<NSString *> *keys = @[
        @"identifier",
        @"workspaceIdentifier",
        @"role",
        @"session",
        @"identity",
        @"specification",
        @"settings"
    ];

    for (NSString *key in keys) {
        id value =
            DPV341SafeValue(
                scene,
                key
            );

        if (value)
            [text appendFormat:@" | %@=%@",
                key,
                value];
    }

    NSString *lower =
        text.lowercaseString;

    return
        [lower containsString:@"dbdashboard-car"] ||
        [lower containsString:@"statusbar-car"] ||
        [lower containsString:@"carplay"] ||
        [lower containsString:@"uiwindowscenesessionrolecarplay"] ||
        [lower containsString:@"car["];
}



static BOOL DPV36NameLooksUseful(NSString *name) {
    if (!name)
        return NO;

    NSString *l = name.lowercaseString;

    return [l containsString:@"display"] ||
           [l containsString:@"scene"] ||
           [l containsString:@"car"] ||
           [l containsString:@"dashboard"] ||
           [l containsString:@"identity"] ||
           [l containsString:@"configuration"] ||
           [l containsString:@"workspace"];
}

static void DPV36ProbeClassRuntime(Class cls, NSString *tag) {
    if (!cls || !tag)
        return;

    DPTrace(@"========== V3.6 RUNTIME %@ class=%@ ==========",
            tag, NSStringFromClass(cls));

    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        SEL sel = method_getName(methods[i]);
        NSString *name = NSStringFromSelector(sel);
        if (!DPV36NameLooksUseful(name))
            continue;

        DPTrace(@"V3.6 %@ METHOD %@ types=%s",
                tag,
                name,
                method_getTypeEncoding(methods[i]) ?: "?");
    }
    if (methods) free(methods);

    unsigned int pc = 0;
    objc_property_t *props = class_copyPropertyList(cls, &pc);
    for (unsigned int i = 0; i < pc; i++) {
        const char *n = property_getName(props[i]);
        NSString *name = n ? [NSString stringWithUTF8String:n] : nil;
        if (DPV36NameLooksUseful(name))
            DPTrace(@"V3.6 %@ PROPERTY %@", tag, name);
    }
    if (props) free(props);

    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);
    for (unsigned int i = 0; i < ic; i++) {
        const char *n = ivar_getName(ivars[i]);
        NSString *name = n ? [NSString stringWithUTF8String:n] : nil;
        if (DPV36NameLooksUseful(name))
            DPTrace(@"V3.6 %@ IVAR %@ type=%s",
                    tag,
                    name,
                    ivar_getTypeEncoding(ivars[i]) ?: "?");
    }
    if (ivars) free(ivars);

    DPTrace(@"========== V3.6 RUNTIME %@ END ==========", tag);
}


static id DPV361CallObjectNoArg(id target, NSString *selectorName) {
    if (!target || !selectorName)
        return nil;

    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel])
        return nil;

    typedef id (*Fn)(id, SEL);
    Fn fn = (Fn)[target methodForSelector:sel];
    if (!fn)
        return nil;

    @try {
        return fn(target, sel);
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static BOOL DPV361CallBoolNoArg(id target, NSString *selectorName, BOOL *ok) {
    if (ok) *ok = NO;
    if (!target || !selectorName)
        return NO;

    SEL sel = NSSelectorFromString(selectorName);
    if (![target respondsToSelector:sel])
        return NO;

    typedef BOOL (*Fn)(id, SEL);
    Fn fn = (Fn)[target methodForSelector:sel];
    if (!fn)
        return NO;

    @try {
        BOOL value = fn(target, sel);
        if (ok) *ok = YES;
        return value;
    } @catch (__unused NSException *e) {
        return NO;
    }
}

static void DPV361ProbeCarDisplaySingletons(void) {
    if (!DPIsSpringBoard())
        return;

    if (gV35CarPlayDisplayIdentity &&
        gV35CarPlayDisplayConfiguration)
        return;

    gV362CarDisplayProbePass++;

    DPTrace(@"========== V3.6.2 CAR DISPLAY SINGLETON PROBE ==========");
    DPTrace(@"V3.6.2 probePass=%lu",
            (unsigned long)gV362CarDisplayProbePass);

    Class identityClass = NSClassFromString(@"FBSDisplayIdentity");
    if (!identityClass) {
        DPTrace(@"V3.6.1 FBSDisplayIdentity missing");
        return;
    }

    NSArray<NSString *> *selectors = @[
        @"mainDisplay",
        @"carDisplay",
        @"carInstrumentsDisplay"
    ];

    for (NSString *name in selectors) {
        id identity = DPV361CallObjectNoArg(identityClass, name);

        DPTrace(@"V3.6.2 +%@ => %@ class=%@",
                name,
                identity ?: @"nil",
                identity ? NSStringFromClass([identity class]) : @"nil");

        if (!identity)
            continue;

        BOOL okCar = NO, okMain = NO, okInstr = NO;
        BOOL isCar = DPV361CallBoolNoArg(identity, @"isCarDisplay", &okCar);
        BOOL isMain = DPV361CallBoolNoArg(identity, @"isMainDisplay", &okMain);
        BOOL isInstr = DPV361CallBoolNoArg(identity, @"isCarInstrumentsDisplay", &okInstr);

        id config = DPV361CallObjectNoArg(identity, @"currentConfiguration");

        id displayID = nil;
        @try { displayID = [identity valueForKey:@"displayID"]; }
        @catch (__unused NSException *e) {}

        DPTrace(@"V3.6.2 identity=%@ displayID=%@ isCar=%d/%d isMain=%d/%d isInstr=%d/%d",
                identity,
                displayID ?: @"nil",
                okCar, isCar,
                okMain, isMain,
                okInstr, isInstr);

        DPTrace(@"V3.6.2 currentConfiguration=%@ class=%@",
                config ?: @"nil",
                config ? NSStringFromClass([config class]) : @"nil");

        if (isCar && config) {
            gV35CarPlayDisplayIdentity = identity;
            gV35CarPlayDisplayConfiguration = config;
            gV34CarPlayDisplayConfiguration = config;
            gV361SingletonProbeDone = YES;

            DPTrace(@"========== V3.6.2 RESOLVED REAL CARPLAY DISPLAY ==========");
            DPTrace(@"V3.6.2 CAR IDENTITY=%@", identity);
            DPTrace(@"V3.6.2 CAR CONFIG=%@", config);
            DPTrace(@"========== V3.6.2 RESOLVED REAL CARPLAY DISPLAY END ==========");
        }
    }

    DPTrace(@"========== V3.6.2 CAR DISPLAY SINGLETON PROBE END ==========");
}

static void DPV36ProbeCarPlayRuntimeOnce(void) {
    if (!DPIsSpringBoard() || gV36CarPlayRuntimeProbeDone)
        return;

    gV36CarPlayRuntimeProbeDone = YES;

    DPTrace(@"========== V3.6 CARPLAY IDENTITY PROBE ==========");

    NSArray<NSString *> *classNames = @[
        @"FBSDisplayIdentity",
        @"FBSDisplayConfiguration",
        @"FBSceneManager",
        @"FBSceneWorkspace",
        @"SBMainWorkspace",
        @"SBDeviceApplicationSceneEntity",
        @"SBDeviceApplicationSceneHandle"
    ];

    for (NSString *name in classNames) {
        Class cls = NSClassFromString(name);
        if (!cls) {
            DPTrace(@"V3.6 class missing %@", name);
            continue;
        }

        DPV36ProbeClassRuntime(cls, name);
        DPV36ProbeClassRuntime(object_getClass(cls),
                               [name stringByAppendingString:@"+"]);
    }

    // Probe known SpringBoard workspace objects without mutating them.
    Class wsClass = NSClassFromString(@"SBMainWorkspace");
    id workspace = nil;
    if (wsClass) {
        SEL sharedSel = NSSelectorFromString(@"sharedInstance");
        if ([wsClass respondsToSelector:sharedSel]) {
            typedef id (*Fn)(id, SEL);
            Fn fn = (Fn)[wsClass methodForSelector:sharedSel];
            if (fn) workspace = fn(wsClass, sharedSel);
        }
    }

    DPTrace(@"V3.6 workspace=%@ class=%@",
            workspace ?: @"nil",
            workspace ? NSStringFromClass([workspace class]) : @"nil");

    NSArray<NSString *> *keys = @[
        @"sceneManager",
        @"displayManager",
        @"workspace",
        @"displayIdentity",
        @"displayConfiguration",
        @"mainDisplayIdentity",
        @"mainDisplayConfiguration"
    ];

    for (NSString *key in keys) {
        @try {
            id v = [workspace valueForKey:key];
            DPTrace(@"V3.6 workspace KVC %@ => %@ class=%@",
                    key,
                    v ?: @"nil",
                    v ? NSStringFromClass([v class]) : @"nil");

            if (v)
                DPV36ProbeClassRuntime([v class],
                                      [@"WORKSPACE_" stringByAppendingString:key]);
        } @catch (NSException *e) {
            DPTrace(@"V3.6 workspace KVC %@ exception=%@",
                    key,
                    e.name ?: @"?");
        }
    }

    DPTrace(@"========== V3.6 CARPLAY IDENTITY PROBE END ==========");
}

static BOOL DPV35DisplayIsCarPlay(id config) {
    if (!config)
        return NO;

    NSString *d =
        [NSString stringWithFormat:@"%@", config];

    NSString *l =
        d.lowercaseString;

    if ([l containsString:@"main; mode"] ||
        [l containsString:@"375x667"])
        return NO;

    return [l containsString:@"car"] ||
           [l containsString:@"640x240"] ||
           [l containsString:@"426.667"] ||
           [l containsString:@"dashboard"] ||
           [l containsString:@"external"];
}

static void DPV35LogIdentityRuntimeOnce(id identity) {
    if (!identity || gV35LoggedIdentityRuntime)
        return;

    gV35LoggedIdentityRuntime = YES;

    DPTrace(@"========== V3.5 DISPLAY IDENTITY RUNTIME ==========");
    DPTrace(@"V3.5 identity=%@ class=%@",
            identity,
            NSStringFromClass([identity class]));

    Class cls = [identity class];

    for (NSUInteger depth = 0; cls && depth < 5;
         depth++, cls = class_getSuperclass(cls)) {

        unsigned int count = 0;
        Method *methods =
            class_copyMethodList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(sel);
            NSString *lower = name.lowercaseString;

            if ([lower containsString:@"display"] ||
                [lower containsString:@"identity"] ||
                [lower containsString:@"configuration"] ||
                [lower containsString:@"identifier"] ||
                [lower containsString:@"main"] ||
                [lower containsString:@"car"] ||
                [lower containsString:@"external"]) {

                DPTrace(@"V3.5 ID METHOD %@.%@ types=%s",
                        NSStringFromClass(cls),
                        name,
                        method_getTypeEncoding(methods[i]) ?: "?");
            }
        }

        if (methods)
            free(methods);
    }

    DPTrace(@"========== V3.5 DISPLAY IDENTITY RUNTIME END ==========");
}

static void DPV35CaptureDisplayFromRequest(id request,
                                           id explicitConfiguration,
                                           NSString *tag) {
    if (!request && !explicitConfiguration)
        return;

    id config = explicitConfiguration;
    id identity = nil;

    if (!config) {
        @try {
            config = [request valueForKey:@"displayConfiguration"];
        } @catch (__unused NSException *e) {}
    }

    @try {
        identity = [request valueForKey:@"displayIdentity"];
    } @catch (__unused NSException *e) {}

    DPTrace(@"V3.5 DISPLAY OBSERVE tag=%@ identity=%@ config=%@",
            tag ?: @"?",
            identity ?: @"nil",
            config ?: @"nil");

    if (!DPV35DisplayIsCarPlay(config))
        return;

    gV35CarPlayDisplayConfiguration = config;

    if (identity)
        gV35CarPlayDisplayIdentity = identity;

    DPTrace(@"========== V3.5 CAPTURED CARPLAY DISPLAY ==========");
    DPTrace(@"V3.5 displayIdentity=%@ class=%@",
            gV35CarPlayDisplayIdentity ?: @"nil",
            gV35CarPlayDisplayIdentity
                ? NSStringFromClass([gV35CarPlayDisplayIdentity class])
                : @"nil");
    DPTrace(@"V3.5 displayConfiguration=%@",
            gV35CarPlayDisplayConfiguration ?: @"nil");
    DPTrace(@"========== V3.5 CAPTURED CARPLAY DISPLAY END ==========");

    DPV35LogIdentityRuntimeOnce(
        gV35CarPlayDisplayIdentity
    );
}

static id DPV34ResolveCarPlayDisplayConfiguration(void) {
    if (gV35CarPlayDisplayConfiguration) {
        gV34CarPlayDisplayConfiguration =
            gV35CarPlayDisplayConfiguration;
        return gV34CarPlayDisplayConfiguration;
    }

    if (gV34CarPlayDisplayConfiguration)
        return gV34CarPlayDisplayConfiguration;

    id workspace =
        nil;

    Class workspaceClass =
        NSClassFromString(@"SBMainWorkspace");

    if (workspaceClass) {
        SEL sel =
            NSSelectorFromString(@"sharedInstance");

        if ([workspaceClass respondsToSelector:sel]) {
            typedef id (*Fn)(id, SEL);

            Fn fn =
                (Fn)[workspaceClass methodForSelector:sel];

            if (fn)
                workspace =
                    fn(workspaceClass, sel);
        }
    }

    id manager =
        DPV341SafeValue(
            workspace,
            @"sceneManager"
        );

    if (!manager) {
        Class managerClass =
            NSClassFromString(@"FBSceneManager");

        if (managerClass) {
            SEL sel =
                NSSelectorFromString(@"sharedInstance");

            if ([managerClass respondsToSelector:sel]) {
                typedef id (*Fn)(id, SEL);

                Fn fn =
                    (Fn)[managerClass methodForSelector:sel];

                if (fn)
                    manager =
                        fn(managerClass, sel);
            }
        }
    }

    if (!manager) {
        DPTrace(@"V3.4.1 RESOLVER no FBSceneManager");
        return nil;
    }

    NSArray *scenes =
        DPV341EnumerateSceneCandidates(
            manager
        );

    DPTrace(@"========== V3.4.1 CARPLAY SCENE RESOLVER ==========");
    DPTrace(@"V3.4.1 manager=%@ class=%@ candidateCount=%lu",
            manager,
            NSStringFromClass([manager class]),
            (unsigned long)scenes.count);

    NSUInteger index =
        0;

    for (id scene in scenes) {
        BOOL isCar =
            DPV341LooksLikeCarPlayScene(
                scene
            );

        id config =
            DPV341DisplayConfigurationFromScene(
                scene
            );

        DPTrace(@"V3.4.1 SCENE[%lu] car=%d class=%@ object=%@",
                (unsigned long)index,
                isCar,
                NSStringFromClass([scene class]),
                scene);

        DPTrace(@"V3.4.1 SCENE[%lu] displayConfig=%@ class=%@",
                (unsigned long)index,
                config ?: @"nil",
                config ? NSStringFromClass([config class]) : @"nil");

        if (isCar && config) {
            NSString *desc =
                [NSString stringWithFormat:@"%@", config];

            // Prefer the wide landscape CarPlay display, never iPhone Main.
            if (![desc containsString:@"375x667"] &&
                ![desc containsString:@"Main; mode"]) {

                gV34CarPlayDisplayConfiguration =
                    config;

                DPTrace(@"V3.4.1 RESOLVED CARPLAY DISPLAY=%@",
                        config);

                break;
            }
        }

        index++;
    }

    if (!gV34CarPlayDisplayConfiguration) {
        id sceneWorkspace =
            DPV363SceneWorkspaceFromManager(manager);

        NSArray *workspaceScenes =
            DPV363AllScenesFromWorkspace(sceneWorkspace);

        DPTrace(@"========== V3.6.3 DIRECT WORKSPACE SCENE PASS ==========");
        DPTrace(@"V3.6.3 workspaceSceneCount=%lu",
                (unsigned long)workspaceScenes.count);

        NSUInteger directIndex = 0;

        for (id scene in workspaceScenes) {
            id settings = DPV341SafeValue(scene, @"settings");
            id config = DPV341DisplayConfigurationFromScene(scene);

            NSString *sceneDesc =
                [NSString stringWithFormat:@"%@", scene];

            NSString *configDesc =
                config ? [NSString stringWithFormat:@"%@", config] : @"nil";

            BOOL car =
                DPV341LooksLikeCarPlayScene(scene) ||
                [configDesc.lowercaseString containsString:@"car["] ||
                [configDesc.lowercaseString containsString:@"carplay"];

            DPTrace(@"V3.6.3 DIRECT[%lu] car=%d scene=%@",
                    (unsigned long)directIndex,
                    car,
                    sceneDesc);

            DPTrace(@"V3.6.3 DIRECT[%lu] settings=%@ config=%@",
                    (unsigned long)directIndex,
                    settings ?: @"nil",
                    config ?: @"nil");

            if (car && config) {
                gV34CarPlayDisplayConfiguration = config;

                @try {
                    id identity = [config valueForKey:@"identity"];
                    if (identity)
                        gV35CarPlayDisplayIdentity = identity;
                } @catch (__unused NSException *e) {
                }

                gV35CarPlayDisplayConfiguration = config;

                DPTrace(@"========== V3.6.3 RESOLVED CARPLAY FROM FBSCENEWORKSPACE ==========");
                DPTrace(@"V3.6.3 CAR CONFIG=%@", config);
                DPTrace(@"V3.6.3 CAR IDENTITY=%@",
                        gV35CarPlayDisplayIdentity ?: @"nil");
                DPTrace(@"========== V3.6.3 RESOLVED CARPLAY FROM FBSCENEWORKSPACE END ==========");

                break;
            }

            directIndex++;
        }

        DPTrace(@"========== V3.6.3 DIRECT WORKSPACE SCENE PASS END ==========");
    }

    DPTrace(@"========== V3.4.1 CARPLAY SCENE RESOLVER END ==========");

    return gV34CarPlayDisplayConfiguration;
}

static void DPV34TryActivateMapsOnCarPlay(void) {
    if (!DPIsSpringBoard() ||
        gV34ActivationAttempted ||
        !gV34CapturedMapsEntity)
        return;

    id carConfig =
        DPV34ResolveCarPlayDisplayConfiguration();

    if (!carConfig) {
        DPTrace(@"V3.4 WAIT no CarPlay display configuration yet");
        return;
    }

    Class workspaceClass =
        NSClassFromString(@"SBMainWorkspace");

    if (!workspaceClass)
        return;

    SEL sharedSel =
        NSSelectorFromString(@"sharedInstance");

    if (![workspaceClass respondsToSelector:sharedSel])
        return;

    typedef id (*SharedFn)(id, SEL);

    SharedFn sharedFn =
        (SharedFn)[workspaceClass methodForSelector:sharedSel];

    id workspace =
        sharedFn
            ? sharedFn(workspaceClass, sharedSel)
            : nil;

    if (!workspace)
        return;

    SEL createSel =
        NSSelectorFromString(
            @"createRequestForApplicationActivation:withDisplayConfiguration:options:"
        );

    SEL executeSel =
        NSSelectorFromString(
            @"_executeApplicationTransitionRequest:"
        );

    if (![workspace respondsToSelector:createSel] ||
        ![workspace respondsToSelector:executeSel]) {

        DPTrace(@"V3.4 ABORT missing workspace selectors");
        return;
    }

    typedef id (*CreateFn)(id, SEL, id, id, unsigned long long);
    typedef BOOL (*ExecuteFn)(id, SEL, id);

    CreateFn createFn =
        (CreateFn)[workspace methodForSelector:createSel];

    ExecuteFn executeFn =
        (ExecuteFn)[workspace methodForSelector:executeSel];

    if (!createFn || !executeFn)
        return;

    gV34ActivationAttempted =
        YES;

    DPTrace(@"========== V3.4 MAPS CARPLAY ACTIVATION ==========");
    DPTrace(@"V3.4 entity=%@", gV34CapturedMapsEntity);
    DPTrace(@"V3.4 activationSettings=%@",
            gV34CapturedMapsActivationSettings ?: @"nil");
    DPTrace(@"V3.4 carConfig=%@", carConfig);

    id request =
        nil;

    @try {
        request =
            createFn(
                workspace,
                createSel,
                gV34CapturedMapsEntity,
                carConfig,
                2ULL
            );

        DPTrace(@"V3.4 request=%@ class=%@",
                request ?: @"nil",
                request ? NSStringFromClass([request class]) : @"nil");
    } @catch (NSException *e) {
        DPTrace(@"V3.4 create exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
    }

    if (!request) {
        DPTrace(@"V3.4 ABORT request=nil");
        DPTrace(@"========== V3.4 MAPS CARPLAY ACTIVATION END ==========");
        return;
    }

    BOOL accepted =
        NO;

    @try {
        accepted =
            executeFn(
                workspace,
                executeSel,
                request
            );

        DPTrace(@"V3.4 execute accepted=%d",
                accepted);
    } @catch (NSException *e) {
        DPTrace(@"V3.4 execute exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
    }

    id handle =
        nil;

    @try {
        handle =
            [gV34CapturedMapsEntity valueForKey:@"sceneHandle"];
    } @catch (__unused NSException *e) {
    }

    DPTrace(@"V3.4 handle immediately=%@",
            handle ?: @"nil");

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1200 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            id h =
                nil;

            @try {
                h =
                    [gV34CapturedMapsEntity valueForKey:@"sceneHandle"];
            } @catch (__unused NSException *e) {
            }

            DPTrace(@"V3.4 +1.2s handle=%@",
                    h ?: @"nil");

            if (h) {
                id vc =
                    nil;

                SEL vcSel =
                    NSSelectorFromString(@"newSceneViewController");

                if ([h respondsToSelector:vcSel]) {
                    typedef id (*Fn)(id, SEL);
                    Fn fn =
                        (Fn)[h methodForSelector:vcSel];

                    if (fn)
                        vc =
                            fn(h, vcSel);
                }

                id content =
                    nil;

                if (vc) {
                    SEL contentSel =
                        NSSelectorFromString(@"sceneContentView");

                    if ([vc respondsToSelector:contentSel]) {
                        typedef id (*Fn)(id, SEL);
                        Fn fn =
                            (Fn)[vc methodForSelector:contentSel];

                        if (fn)
                            content =
                                fn(vc, contentSel);
                    }
                }

                DPTrace(@"V3.4 +1.2s vc=%@ content=%@",
                        vc ?: @"nil",
                        content ?: @"nil");
            }
        }
    );

    DPTrace(@"========== V3.4 MAPS CARPLAY ACTIVATION END ==========");
}

static id (*DPV33OrigCreateActivationRequest)(id, SEL, id, unsigned long long) = NULL;
static id (*DPV33OrigCreateActivationRequestDisplay)(id, SEL, id, id, unsigned long long) = NULL;

static id DPV33HookCreateActivationRequest(id self,
                                           SEL _cmd,
                                           id activationObject,
                                           unsigned long long options) {
    BOOL maps =
        DPV33ObjectLooksLikeMaps(
            activationObject
        );

    DPTrace(@"========== V3.3 CREATE ACTIVATION REQUEST ==========");
    DPTrace(@"V3.3 selector=%@ options=%llu mapsCandidate=%d",
            NSStringFromSelector(_cmd),
            options,
            maps);

    DPV33LogActivationObject(
        activationObject,
        @"activationObject"
    );

    id result =
        nil;

    if (DPV33OrigCreateActivationRequest) {
        result =
            DPV33OrigCreateActivationRequest(
                self,
                _cmd,
                activationObject,
                options
            );
    }

    DPTrace(@"V3.3 requestResult=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    if (result)
        DPV33LogActivationObject(
            result,
            @"requestResult"
        );

    DPTrace(@"========== V3.3 CREATE ACTIVATION REQUEST END ==========");

    return result;
}

static id DPV33HookCreateActivationRequestDisplay(id self,
                                                  SEL _cmd,
                                                  id activationObject,
                                                  id displayConfiguration,
                                                  unsigned long long options) {
    BOOL maps =
        DPV33ObjectLooksLikeMaps(
            activationObject
        );

    if (maps) {
        gV34CapturedMapsEntity =
            activationObject;

        @try {
            gV34CapturedMapsActivationSettings =
                [activationObject valueForKey:@"activationSettings"];
        } @catch (__unused NSException *e) {
            gV34CapturedMapsActivationSettings =
                nil;
        }

        DPTrace(@"V3.4 CAPTURED REAL MAPS ENTITY=%@",
                gV34CapturedMapsEntity);
    }

    DPTrace(@"========== V3.3 CREATE ACTIVATION REQUEST DISPLAY ==========");
    DPTrace(@"V3.3 selector=%@ options=%llu mapsCandidate=%d",
            NSStringFromSelector(_cmd),
            options,
            maps);

    DPV33LogActivationObject(
        activationObject,
        @"activationObject"
    );

    DPV33LogActivationObject(
        displayConfiguration,
        @"displayConfiguration"
    );

    DPV35CaptureDisplayFromRequest(
        nil,
        displayConfiguration,
        @"ARGUMENT"
    );

    id result =
        nil;

    if (DPV33OrigCreateActivationRequestDisplay) {
        result =
            DPV33OrigCreateActivationRequestDisplay(
                self,
                _cmd,
                activationObject,
                displayConfiguration,
                options
            );
    }

    DPTrace(@"V3.3 requestDisplayResult=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    if (result)
        DPV33LogActivationObject(
            result,
            @"requestDisplayResult"
        );

    DPV35CaptureDisplayFromRequest(
        result,
        displayConfiguration,
        @"RETURNED_REQUEST"
    );

    DPTrace(@"========== V3.3 CREATE ACTIVATION REQUEST DISPLAY END ==========");

    if (maps) {
        dispatch_after(
            dispatch_time(
                DISPATCH_TIME_NOW,
                700 * NSEC_PER_MSEC
            ),
            dispatch_get_main_queue(),
            ^{
                DPV34TryActivateMapsOnCarPlay();
            }
        );
    }

    return result;
}

static void DPV33InstallActivationHooks(void) {
    if (!DPIsSpringBoard() ||
        gV33ActivationHooksInstalled)
        return;

    Class cls =
        NSClassFromString(@"SBMainWorkspace");

    if (!cls) {
        DPTrace(@"V3.3 HOOK ABORT SBMainWorkspace missing");
        return;
    }

    SEL sel1 =
        NSSelectorFromString(
            @"createRequestForApplicationActivation:options:"
        );

    Method m1 =
        class_getInstanceMethod(
            cls,
            sel1
        );

    if (m1) {
        const char *types =
            method_getTypeEncoding(m1);

        DPTrace(@"V3.3 HOOK candidate %@ types=%s",
                NSStringFromSelector(sel1),
                types ?: "?");

        IMP original =
            method_getImplementation(m1);

        if (original) {
            DPV33OrigCreateActivationRequest =
                (id (*)(id, SEL, id, unsigned long long))original;

            method_setImplementation(
                m1,
                (IMP)DPV33HookCreateActivationRequest
            );

            DPTrace(@"V3.3 HOOK installed %@",
                    NSStringFromSelector(sel1));
        }
    }

    SEL sel2 =
        NSSelectorFromString(
            @"createRequestForApplicationActivation:withDisplayConfiguration:options:"
        );

    Method m2 =
        class_getInstanceMethod(
            cls,
            sel2
        );

    if (m2) {
        const char *types =
            method_getTypeEncoding(m2);

        DPTrace(@"V3.3 HOOK candidate %@ types=%s",
                NSStringFromSelector(sel2),
                types ?: "?");

        IMP original =
            method_getImplementation(m2);

        if (original) {
            DPV33OrigCreateActivationRequestDisplay =
                (id (*)(id, SEL, id, id, unsigned long long))original;

            method_setImplementation(
                m2,
                (IMP)DPV33HookCreateActivationRequestDisplay
            );

            DPTrace(@"V3.3 HOOK installed %@",
                    NSStringFromSelector(sel2));
        }
    }

    gV33ActivationHooksInstalled =
        YES;

    DPTrace(@"V3.3 activation signature hooks ready");
}


static id DPV390SafeValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void DPV390ProbeSceneHandleViewPath(id sceneHandle) {
    if (!sceneHandle || gV390SceneViewProbeDone) return;
    gV390SceneViewProbeDone = YES;

    DPTrace(@"========== V3.9 SCENE VIEW HOST PROBE ==========");
    DPTrace(@"V3.9 sceneHandle=%@ class=%@",
            sceneHandle,
            NSStringFromClass([sceneHandle class]));

    id displayIdentity = DPV390SafeValue(sceneHandle, @"displayIdentity");
    id windowScene = DPV390SafeValue(sceneHandle, @"_windowScene");
    id scene = nil;

    @try { scene = [sceneHandle valueForKey:@"scene"]; }
    @catch (__unused NSException *e) {}

    DPTrace(@"V3.9 sceneHandle.displayIdentity=%@ class=%@",
            displayIdentity ?: @"nil",
            displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");

    DPTrace(@"V3.9 sceneHandle._windowScene=%@ class=%@",
            windowScene ?: @"nil",
            windowScene ? NSStringFromClass([windowScene class]) : @"nil");

    DPTrace(@"V3.9 sceneHandle.scene=%@ class=%@",
            scene ?: @"nil",
            scene ? NSStringFromClass([scene class]) : @"nil");

    id vc = nil;
    SEL vcSel = NSSelectorFromString(@"newSceneViewController");

    if ([sceneHandle respondsToSelector:vcSel]) {
        typedef id (*Fn)(id, SEL);
        Fn fn = (Fn)[sceneHandle methodForSelector:vcSel];

        if (fn) {
            @try { vc = fn(sceneHandle, vcSel); }
            @catch (NSException *e) {
                DPTrace(@"V3.9 newSceneViewController exception=%@ reason=%@",
                        e.name ?: @"?",
                        e.reason ?: @"?");
            }
        }
    }

    DPTrace(@"V3.9 newSceneViewController=%@ class=%@",
            vc ?: @"nil",
            vc ? NSStringFromClass([vc class]) : @"nil");

    if (vc) {
        id contentView = DPV390SafeValue(vc, @"sceneContentView");

        DPTrace(@"V3.9 sceneContentView=%@ class=%@ frame=%@",
                contentView ?: @"nil",
                contentView ? NSStringFromClass([contentView class]) : @"nil",
                [contentView isKindOfClass:UIView.class]
                    ? NSStringFromCGRect(((UIView *)contentView).frame)
                    : @"nil");

        DPTrace(@"V3.9 sceneResizesHostedContext=%@",
                DPV390SafeValue(vc, @"sceneResizesHostedContext") ?: @"nil");
    }

    SEL viewSel = NSSelectorFromString(
        @"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:"
    );

    DPTrace(@"V3.9 newSceneViewWithReferenceSize available=%d",
            [sceneHandle respondsToSelector:viewSel]);

    for (NSString *className in @[@"_UIScenePresentationView",
                                  @"_UISceneLayerHostContainerView"]) {
        Class cls = NSClassFromString(className);

        DPTrace(@"V3.9 class %@ => %@",
                className,
                cls ? NSStringFromClass(cls) : @"nil");

        if (!cls) continue;

        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;

            if ([lower containsString:@"scene"] ||
                [lower containsString:@"host"] ||
                [lower containsString:@"container"] ||
                [lower containsString:@"presentation"] ||
                [lower containsString:@"layer"]) {
                DPTrace(@"V3.9 %@ METHOD %@ types=%s",
                        className,
                        name,
                        method_getTypeEncoding(methods[i]) ?: "?");
            }
        }

        if (methods) free(methods);
    }

    DPTrace(@"========== V3.9 SCENE VIEW HOST PROBE END ==========");
}



static NSString *DPV392IdentityArchivePath(void) {
    return @"/var/mobile/Library/Caches/DuoPhoneCarDisplayIdentity.archive";
}

static void DPV392PublishCarIdentityFromCarPlay(void) {
    if (!DPIsCarPlay() || gV392CarIdentityPublished)
        return;

    id displayConfig = nil;
    id carIdentity = nil;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        id fbsScene = DPV341SafeValue(scene, @"_FBSScene");
        if (!fbsScene)
            fbsScene = DPV341SafeValue(scene, @"scene");

        id settings = DPV341SafeValue(fbsScene, @"settings");
        id candidate = DPV341SafeValue(settings, @"displayConfiguration");
        id identity = DPV341SafeValue(candidate, @"identity");

        if (!candidate || !identity)
            continue;

        NSString *desc = [candidate description] ?: @"";
        if (![desc containsString:@"Car["])
            continue;

        displayConfig = candidate;
        carIdentity = identity;
        break;
    }

    DPTrace(@"========== V3.9.2 CAR IDENTITY PUBLISH ==========");
    DPTrace(@"V3.9.2 displayConfig=%@ class=%@",
            displayConfig ?: @"nil",
            displayConfig ? NSStringFromClass([displayConfig class]) : @"nil");
    DPTrace(@"V3.9.2 carIdentity=%@ class=%@",
            carIdentity ?: @"nil",
            carIdentity ? NSStringFromClass([carIdentity class]) : @"nil");

    if (!carIdentity) {
        DPTrace(@"V3.9.2 publish WAIT no live Car identity yet");
        DPTrace(@"========== V3.9.2 CAR IDENTITY PUBLISH END ==========");
        return;
    }

    NSData *data = nil;

    @try {
        NSError *archiveError = nil;
        data = [NSKeyedArchiver archivedDataWithRootObject:carIdentity
                                    requiringSecureCoding:NO
                                                    error:&archiveError];

        DPTrace(@"V3.9.2 archive error=%@",
                archiveError ?: @"nil");
    } @catch (NSException *e) {
        DPTrace(@"V3.9.2 archive exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
    }

    DPTrace(@"V3.9.2 archive bytes=%lu",
            (unsigned long)data.length);

    if (!data.length) {
        DPTrace(@"V3.9.2 publish FAIL archive empty");
        DPTrace(@"========== V3.9.2 CAR IDENTITY PUBLISH END ==========");
        return;
    }

    NSError *writeError = nil;
    BOOL wrote =
        [data writeToFile:DPV392IdentityArchivePath()
                  options:NSDataWritingAtomic
                    error:&writeError];

    DPTrace(@"V3.9.2 archive write=%d path=%@ error=%@",
            wrote,
            DPV392IdentityArchivePath(),
            writeError ?: @"nil");

    if (wrote) {
        gV392CarIdentityPublished = YES;

        if (gV393BridgeRequestDeferredForIdentity) {
            gV393BridgeRequestDeferredForIdentity = NO;
            DPTrace(@"V3.9.3 identity became ready after defer; AppBridge will send on next refresh");
        }
    }

    DPTrace(@"========== V3.9.2 CAR IDENTITY PUBLISH END ==========");
}

static id DPV392LoadBridgedCarIdentity(void) {
    NSData *data =
        [NSData dataWithContentsOfFile:DPV392IdentityArchivePath()];

    DPTrace(@"V3.9.2 load archive bytes=%lu path=%@",
            (unsigned long)data.length,
            DPV392IdentityArchivePath());

    if (!data.length)
        return nil;

    Class identityClass =
        NSClassFromString(@"FBSDisplayIdentity");

    if (!identityClass)
        return nil;

    id obj = nil;

    @try {
        NSError *error = nil;
        obj = [NSKeyedUnarchiver unarchivedObjectOfClass:identityClass
                                                fromData:data
                                                   error:&error];

        DPTrace(@"V3.9.2 unarchive error=%@",
                error ?: @"nil");
    } @catch (NSException *e) {
        DPTrace(@"V3.9.2 unarchive exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
    }

    DPTrace(@"V3.9.2 bridgedIdentity=%@ class=%@",
            obj ?: @"nil",
            obj ? NSStringFromClass([obj class]) : @"nil");

    return obj;
}

static id DPV391GetCarDisplayIdentityFromRuntime(void) {
    Class identityClass = NSClassFromString(@"FBSDisplayIdentity");
    if (!identityClass) return nil;
    SEL carSel = NSSelectorFromString(@"carDisplay");
    if ([identityClass respondsToSelector:carSel]) {
        typedef id (*Fn)(id, SEL);
        Fn fn = (Fn)[identityClass methodForSelector:carSel];
        if (fn) {
            @try { id value = fn(identityClass, carSel); if (value) return value; }
            @catch (__unused NSException *e) {}
        }
    }
    return nil;
}


static BOOL DPV394NameLooksProviderRelated(NSString *name) {
    if (!name) return NO;
    NSString *l = name.lowercaseString;
    return [l containsString:@"provider"] ||
           [l containsString:@"scenehandle"] ||
           [l containsString:@"scene"] ||
           [l containsString:@"displayidentity"];
}

static void DPV394DumpProviderSurface(id obj, NSString *tag) {
    if (!obj || !tag) return;

    DPTrace(@"========== V3.9.4 PROVIDER OBJECT %@ ==========", tag);
    DPTrace(@"V3.9.4 %@ object=%@ class=%@", tag, obj, NSStringFromClass([obj class]));

    for (NSString *key in @[
        @"sceneHandleProvider",
        @"_sceneHandleProvider",
        @"sceneHandle",
        @"displayIdentity",
        @"application",
        @"entity",
        @"sceneManager",
        @"workspace",
        @"provider"
    ]) {
        id value = nil;
        @try { value = [obj valueForKey:key]; }
        @catch (NSException *e) {
            DPTrace(@"V3.9.4 %@ KVC %@ exception=%@", tag, key, e.name ?: @"?");
            continue;
        }

        DPTrace(@"V3.9.4 %@ KVC %@ => %@ class=%@",
                tag, key,
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");
    }

    Class cls = [obj class];
    NSUInteger depth = 0;

    while (cls && depth < 8) {
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);
        for (unsigned int i = 0; i < mc; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            if (DPV394NameLooksProviderRelated(name)) {
                DPTrace(@"V3.9.4 %@ METHOD %@.%@ types=%s",
                        tag,
                        NSStringFromClass(cls),
                        name,
                        method_getTypeEncoding(methods[i]) ?: "?");
            }
        }
        if (methods) free(methods);

        unsigned int ic = 0;
        Ivar *ivars = class_copyIvarList(cls, &ic);
        for (unsigned int i = 0; i < ic; i++) {
            const char *raw = ivar_getName(ivars[i]);
            NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;
            if (DPV394NameLooksProviderRelated(name)) {
                DPTrace(@"V3.9.4 %@ IVAR %@.%@ type=%s",
                        tag,
                        NSStringFromClass(cls),
                        name,
                        ivar_getTypeEncoding(ivars[i]) ?: "?");
            }
        }
        if (ivars) free(ivars);

        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pc);
        for (unsigned int i = 0; i < pc; i++) {
            const char *raw = property_getName(props[i]);
            NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;
            if (DPV394NameLooksProviderRelated(name)) {
                DPTrace(@"V3.9.4 %@ PROPERTY %@.%@",
                        tag,
                        NSStringFromClass(cls),
                        name);
            }
        }
        if (props) free(props);

        cls = class_getSuperclass(cls);
        depth++;
    }

    DPTrace(@"========== V3.9.4 PROVIDER OBJECT %@ END ==========", tag);
}


static BOOL DPV395ApplicationIsMaps(id application) {
    if (!application)
        return NO;

    id bid = nil;
    @try {
        bid = [application valueForKey:@"bundleIdentifier"];
    } @catch (__unused NSException *e) {
    }

    return [bid isKindOfClass:NSString.class] &&
           [bid isEqualToString:@"com.apple.Maps"];
}

static id (*DPV395OrigInitEntity)(id, SEL, id, id, id) = NULL;

static id DPV395HookInitEntity(id self,
                               SEL _cmd,
                               id application,
                               id sceneHandleProvider,
                               id displayIdentity) {
    if (DPV395ApplicationIsMaps(application)) {
        DPTrace(@"========== V3.9.5 PROVIDER CAPTURE INIT ==========");
        DPTrace(@"V3.9.5 selector=%@", NSStringFromSelector(_cmd));
        DPTrace(@"V3.9.5 sceneHandleProvider=%@ class=%@",
                sceneHandleProvider ?: @"nil",
                sceneHandleProvider ? NSStringFromClass([sceneHandleProvider class]) : @"nil");
        DPTrace(@"V3.9.5 displayIdentity=%@ class=%@",
                displayIdentity ?: @"nil",
                displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");

        if (sceneHandleProvider)
            gV395CapturedSceneHandleProvider = sceneHandleProvider;

        if (displayIdentity)
            gV395CapturedDisplayIdentity = displayIdentity;

        DPTrace(@"========== V3.9.5 PROVIDER CAPTURE INIT END ==========");
    }

    if (!DPV395OrigInitEntity)
        return nil;

    return DPV395OrigInitEntity(self, _cmd, application, sceneHandleProvider, displayIdentity);
}

static id (*DPV395OrigNewEntity)(id, SEL, id, id, id) = NULL;

static id DPV395HookNewEntity(id cls,
                              SEL _cmd,
                              id application,
                              id sceneHandleProvider,
                              id displayIdentity) {
    if (DPV395ApplicationIsMaps(application)) {
        DPTrace(@"========== V3.9.5 PROVIDER CAPTURE CLASS ==========");
        DPTrace(@"V3.9.5 selector=%@", NSStringFromSelector(_cmd));
        DPTrace(@"V3.9.5 sceneHandleProvider=%@ class=%@",
                sceneHandleProvider ?: @"nil",
                sceneHandleProvider ? NSStringFromClass([sceneHandleProvider class]) : @"nil");
        DPTrace(@"V3.9.5 displayIdentity=%@ class=%@",
                displayIdentity ?: @"nil",
                displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");

        if (sceneHandleProvider)
            gV395CapturedSceneHandleProvider = sceneHandleProvider;

        if (displayIdentity)
            gV395CapturedDisplayIdentity = displayIdentity;

        DPTrace(@"========== V3.9.5 PROVIDER CAPTURE CLASS END ==========");
    }

    if (!DPV395OrigNewEntity)
        return nil;

    return DPV395OrigNewEntity(cls, _cmd, application, sceneHandleProvider, displayIdentity);
}

static void DPV395InstallProviderCaptureHooks(void) {
    if (gV395ProviderHookInstalled)
        return;

    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    if (!entityClass) {
        DPTrace(@"V3.9.5 hook FAIL no SBDeviceApplicationSceneEntity");
        return;
    }

    BOOL installedAny = NO;

    SEL initSel = NSSelectorFromString(@"initWithApplication:sceneHandleProvider:displayIdentity:");
    Method initMethod = class_getInstanceMethod(entityClass, initSel);

    if (initMethod) {
        IMP current = method_getImplementation(initMethod);
        if (current && current != (IMP)DPV395HookInitEntity) {
            DPV395OrigInitEntity = (id (*)(id, SEL, id, id, id))current;
            method_setImplementation(initMethod, (IMP)DPV395HookInitEntity);
            DPTrace(@"V3.9.5 hook installed %@", NSStringFromSelector(initSel));
            installedAny = YES;
        }
    } else {
        DPTrace(@"V3.9.5 hook missing %@", NSStringFromSelector(initSel));
    }

    SEL newSel = NSSelectorFromString(@"newEntityWithApplication:sceneHandleProvider:displayIdentity:");
    Method newMethod = class_getClassMethod(entityClass, newSel);

    if (newMethod) {
        IMP current = method_getImplementation(newMethod);
        if (current && current != (IMP)DPV395HookNewEntity) {
            DPV395OrigNewEntity = (id (*)(id, SEL, id, id, id))current;
            method_setImplementation(newMethod, (IMP)DPV395HookNewEntity);
            DPTrace(@"V3.9.5 hook installed %@", NSStringFromSelector(newSel));
            installedAny = YES;
        }
    } else {
        DPTrace(@"V3.9.5 hook missing %@", NSStringFromSelector(newSel));
    }

    gV395ProviderHookInstalled = installedAny;
    DPTrace(@"V3.9.5 provider capture hooks ready=%d", gV395ProviderHookInstalled);
}

static void DPV395LogCapturedProviderSnapshot(void) {
    DPTrace(@"========== V3.9.5 CAPTURE SNAPSHOT ==========");
    DPTrace(@"V3.9.5 capturedProvider=%@ class=%@",
            gV395CapturedSceneHandleProvider ?: @"nil",
            gV395CapturedSceneHandleProvider
                ? NSStringFromClass([gV395CapturedSceneHandleProvider class])
                : @"nil");
    DPTrace(@"V3.9.5 capturedDisplayIdentity=%@ class=%@",
            gV395CapturedDisplayIdentity ?: @"nil",
            gV395CapturedDisplayIdentity
                ? NSStringFromClass([gV395CapturedDisplayIdentity class])
                : @"nil");
    DPTrace(@"========== V3.9.5 CAPTURE SNAPSHOT END ==========");
}

static BOOL DPV397InterestingProviderMemberName(NSString *name) {
    if (!name)
        return NO;

    NSString *l = name.lowercaseString;

    return [l containsString:@"display"] ||
           [l containsString:@"scene"] ||
           [l containsString:@"application"] ||
           [l containsString:@"entity"] ||
           [l containsString:@"handle"] ||
           [l containsString:@"workspace"] ||
           [l containsString:@"provider"];
}

static void DPV397LogProviderKVC(id provider) {
    if (!provider)
        return;

    NSArray<NSString *> *keys = @[
        @"display",
        @"_display",
        @"displayIdentity",
        @"_displayIdentity",
        @"displayConfiguration",
        @"_displayConfiguration",
        @"sceneManager",
        @"_sceneManager",
        @"workspace",
        @"_workspace",
        @"mainWorkspace",
        @"windowScene",
        @"scene",
        @"sceneHandle",
        @"sceneHandleProvider",
        @"application",
        @"rootDisplay",
        @"fbsDisplay"
    ];

    for (NSString *key in keys) {
        id value = nil;

        @try {
            value = [provider valueForKey:key];
        } @catch (NSException *e) {
            DPTrace(@"V3.9.7 PROVIDER KVC %@ exception=%@",
                    key,
                    e.name ?: @"?");
            continue;
        }

        DPTrace(@"V3.9.7 PROVIDER KVC %@ => %@ class=%@",
                key,
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");
    }
}

static void DPV397DumpClassSurface(Class cls, NSString *tag) {
    if (!cls || !tag)
        return;

    DPTrace(@"========== V3.9.7 CLASS %@ ==========", tag);
    DPTrace(@"V3.9.7 class=%@ super=%@",
            NSStringFromClass(cls),
            NSStringFromClass(class_getSuperclass(cls)));

    unsigned int protocolCount = 0;
    Protocol *__unsafe_unretained *protocols =
        class_copyProtocolList(cls, &protocolCount);

    for (unsigned int i = 0; i < protocolCount; i++) {
        const char *raw = protocol_getName(protocols[i]);
        DPTrace(@"V3.9.7 %@ PROTOCOL %s",
                tag,
                raw ?: "?");
    }

    if (protocols)
        free(protocols);

    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);

    for (unsigned int i = 0; i < mc; i++) {
        NSString *name =
            NSStringFromSelector(method_getName(methods[i]));

        if (!DPV397InterestingProviderMemberName(name))
            continue;

        DPTrace(@"V3.9.7 %@ METHOD %@ types=%s",
                tag,
                name,
                method_getTypeEncoding(methods[i]) ?: "?");
    }

    if (methods)
        free(methods);

    unsigned int ic = 0;
    Ivar *ivars = class_copyIvarList(cls, &ic);

    for (unsigned int i = 0; i < ic; i++) {
        const char *rawName = ivar_getName(ivars[i]);
        NSString *name =
            rawName ? [NSString stringWithUTF8String:rawName] : nil;

        if (!DPV397InterestingProviderMemberName(name))
            continue;

        DPTrace(@"V3.9.7 %@ IVAR %@ type=%s",
                tag,
                name ?: @"?",
                ivar_getTypeEncoding(ivars[i]) ?: "?");
    }

    if (ivars)
        free(ivars);

    unsigned int pc = 0;
    objc_property_t *properties = class_copyPropertyList(cls, &pc);

    for (unsigned int i = 0; i < pc; i++) {
        const char *rawName = property_getName(properties[i]);
        NSString *name =
            rawName ? [NSString stringWithUTF8String:rawName] : nil;

        if (!DPV397InterestingProviderMemberName(name))
            continue;

        DPTrace(@"V3.9.7 %@ PROPERTY %@ attrs=%s",
                tag,
                name ?: @"?",
                property_getAttributes(properties[i]) ?: "?");
    }

    if (properties)
        free(properties);

    DPTrace(@"========== V3.9.7 CLASS %@ END ==========", tag);
}

static void DPV397EnumerateCandidateProviderClasses(void) {
    int count = objc_getClassList(NULL, 0);

    if (count <= 0)
        return;

    Class *classes =
        (Class *)malloc(sizeof(Class) * (NSUInteger)count);

    if (!classes)
        return;

    count = objc_getClassList(classes, count);

    NSUInteger logged = 0;

    for (int i = 0; i < count; i++) {
        Class cls = classes[i];

        if (!cls)
            continue;

        NSString *name =
            NSStringFromClass(cls);

        NSString *l =
            name.lowercaseString;

        BOOL candidate =
            ([l containsString:@"displayscenemanager"] ||
             [l containsString:@"scenehandleprovider"] ||
             ([l containsString:@"car"] &&
              [l containsString:@"scenemanager"]) ||
             ([l containsString:@"external"] &&
              [l containsString:@"scenemanager"]));

        if (!candidate)
            continue;

        DPTrace(@"V3.9.7 CANDIDATE CLASS %@ super=%@",
                name,
                NSStringFromClass(class_getSuperclass(cls)));

        DPV397DumpClassSurface(
            cls,
            [NSString stringWithFormat:@"CANDIDATE_%@", name]
        );

        logged++;

        if (logged >= 24)
            break;
    }

    free(classes);

    DPTrace(@"V3.9.7 candidate class count logged=%lu",
            (unsigned long)logged);
}


static id DPV398SafeKVC(id obj, NSString *key) {
    if (!obj || !key)
        return nil;

    @try {
        return [obj valueForKey:key];
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static void DPV398DumpObjectChain(id obj, NSString *tag) {
    if (!obj || !tag)
        return;

    DPTrace(@"========== V3.9.8 OBJECT %@ ==========", tag);
    DPTrace(@"V3.9.8 %@ object=%@ class=%@",
            tag,
            obj,
            NSStringFromClass([obj class]));

    NSArray<NSString *> *keys = @[
        @"displayIdentity",
        @"display",
        @"displayConfiguration",
        @"windowScene",
        @"_windowScene",
        @"sceneManager",
        @"sceneIdentityProvider",
        @"_sceneIdentityProvider",
        @"reference",
        @"_reference",
        @"presentationBinder",
        @"_presentationBinder",
        @"screen",
        @"scene",
        @"settings"
    ];

    for (NSString *key in keys) {
        id value = DPV398SafeKVC(obj, key);

        DPTrace(@"V3.9.8 %@ KVC %@ => %@ class=%@",
                tag,
                key,
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");

        if (!value || value == obj)
            continue;

        if ([key isEqualToString:@"windowScene"] ||
            [key isEqualToString:@"_windowScene"] ||
            [key isEqualToString:@"scene"] ||
            [key isEqualToString:@"settings"] ||
            [key isEqualToString:@"displayConfiguration"]) {

            for (NSString *subKey in @[
                @"displayIdentity",
                @"displayConfiguration",
                @"display",
                @"screen",
                @"scene",
                @"settings",
                @"identity"
            ]) {
                id subValue = DPV398SafeKVC(value, subKey);

                DPTrace(@"V3.9.8 %@ KVC %@.%@ => %@ class=%@",
                        tag,
                        key,
                        subKey,
                        subValue ?: @"nil",
                        subValue ? NSStringFromClass([subValue class]) : @"nil");
            }
        }
    }

    DPTrace(@"========== V3.9.8 OBJECT %@ END ==========", tag);
}

static id (*DPV398OrigExternalInit4)(id, SEL, id, id, id, id) = NULL;

static id DPV398HookExternalInit4(id self,
                                  SEL _cmd,
                                  id reference,
                                  id sceneIdentityProvider,
                                  id presentationBinder,
                                  id snapshotBehavior) {
    DPTrace(@"========== V3.9.8 EXTERNAL MANAGER INIT4 ==========");
    DPTrace(@"V3.9.8 selector=%@", NSStringFromSelector(_cmd));
    DPTrace(@"V3.9.8 self(before)=%@ class=%@",
            self ?: @"nil",
            self ? NSStringFromClass([self class]) : @"nil");
    DPTrace(@"V3.9.8 reference=%@ class=%@",
            reference ?: @"nil",
            reference ? NSStringFromClass([reference class]) : @"nil");
    DPTrace(@"V3.9.8 sceneIdentityProvider=%@ class=%@",
            sceneIdentityProvider ?: @"nil",
            sceneIdentityProvider ? NSStringFromClass([sceneIdentityProvider class]) : @"nil");
    DPTrace(@"V3.9.8 presentationBinder=%@ class=%@",
            presentationBinder ?: @"nil",
            presentationBinder ? NSStringFromClass([presentationBinder class]) : @"nil");
    DPTrace(@"V3.9.8 snapshotBehavior=%@ class=%@",
            snapshotBehavior ?: @"nil",
            snapshotBehavior ? NSStringFromClass([snapshotBehavior class]) : @"nil");

    id result = nil;

    if (DPV398OrigExternalInit4) {
        result = DPV398OrigExternalInit4(self,
                                         _cmd,
                                         reference,
                                         sceneIdentityProvider,
                                         presentationBinder,
                                         snapshotBehavior);
    }

    DPTrace(@"V3.9.8 result=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    if (result) {
        gV398CapturedExternalManager = result;
        DPV398DumpObjectChain(result, @"EXTERNAL_MANAGER_INIT4");
    }

    DPTrace(@"========== V3.9.8 EXTERNAL MANAGER INIT4 END ==========");

    return result;
}

static id (*DPV398OrigExternalInit3)(id, SEL, id, id, id) = NULL;

static id DPV398HookExternalInit3(id self,
                                  SEL _cmd,
                                  id reference,
                                  id sceneIdentityProvider,
                                  id presentationBinder) {
    DPTrace(@"========== V3.9.8 EXTERNAL MANAGER INIT3 ==========");
    DPTrace(@"V3.9.8 selector=%@", NSStringFromSelector(_cmd));
    DPTrace(@"V3.9.8 reference=%@ class=%@",
            reference ?: @"nil",
            reference ? NSStringFromClass([reference class]) : @"nil");
    DPTrace(@"V3.9.8 sceneIdentityProvider=%@ class=%@",
            sceneIdentityProvider ?: @"nil",
            sceneIdentityProvider ? NSStringFromClass([sceneIdentityProvider class]) : @"nil");
    DPTrace(@"V3.9.8 presentationBinder=%@ class=%@",
            presentationBinder ?: @"nil",
            presentationBinder ? NSStringFromClass([presentationBinder class]) : @"nil");

    id result = nil;

    if (DPV398OrigExternalInit3) {
        result = DPV398OrigExternalInit3(self,
                                         _cmd,
                                         reference,
                                         sceneIdentityProvider,
                                         presentationBinder);
    }

    DPTrace(@"V3.9.8 result=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    if (result) {
        gV398CapturedExternalManager = result;
        DPV398DumpObjectChain(result, @"EXTERNAL_MANAGER_INIT3");
    }

    DPTrace(@"========== V3.9.8 EXTERNAL MANAGER INIT3 END ==========");

    return result;
}

static void DPV398InstallExternalManagerCaptureHooks(void) {
    if (gV398ExternalManagerHooksInstalled)
        return;

    Class cls =
        NSClassFromString(@"SBSystemShellExternalDisplaySceneManager");

    if (!cls) {
        DPTrace(@"V3.9.8 hook FAIL no SBSystemShellExternalDisplaySceneManager");
        return;
    }

    BOOL installed = NO;

    SEL init4 =
        NSSelectorFromString(@"initWithReference:sceneIdentityProvider:presentationBinder:snapshotBehavior:");

    Method m4 =
        class_getInstanceMethod(cls, init4);

    if (m4) {
        IMP current = method_getImplementation(m4);

        if (current &&
            current != (IMP)DPV398HookExternalInit4) {
            DPV398OrigExternalInit4 =
                (id (*)(id, SEL, id, id, id, id))current;

            method_setImplementation(
                m4,
                (IMP)DPV398HookExternalInit4
            );

            DPTrace(@"V3.9.8 hook installed %@",
                    NSStringFromSelector(init4));

            installed = YES;
        }
    } else {
        DPTrace(@"V3.9.8 hook missing %@",
                NSStringFromSelector(init4));
    }

    SEL init3 =
        NSSelectorFromString(@"initWithReference:sceneIdentityProvider:presentationBinder:");

    Method m3 =
        class_getInstanceMethod(cls, init3);

    if (m3) {
        IMP current = method_getImplementation(m3);

        if (current &&
            current != (IMP)DPV398HookExternalInit3) {
            DPV398OrigExternalInit3 =
                (id (*)(id, SEL, id, id, id))current;

            method_setImplementation(
                m3,
                (IMP)DPV398HookExternalInit3
            );

            DPTrace(@"V3.9.8 hook installed %@",
                    NSStringFromSelector(init3));

            installed = YES;
        }
    } else {
        DPTrace(@"V3.9.8 hook missing %@",
                NSStringFromSelector(init3));
    }

    gV398ExternalManagerHooksInstalled = installed;

    DPTrace(@"V3.9.8 external manager capture hooks ready=%d",
            gV398ExternalManagerHooksInstalled);
}


static void DPV399CaptureExternalSelf(id self, SEL _cmd, NSString *tag) {
    if (!self)
        return;

    Class wanted = NSClassFromString(@"SBSystemShellExternalDisplaySceneManager");

    if (!wanted || ![self isKindOfClass:wanted])
        return;

    BOOL first = (gV398CapturedExternalManager != self);
    gV398CapturedExternalManager = self;

    DPTrace(@"========== V3.9.9 LIVE EXTERNAL SELF ==========");
    DPTrace(@"V3.9.9 tag=%@ selector=%@", tag, NSStringFromSelector(_cmd));
    DPTrace(@"V3.9.9 self=%@ class=%@ first=%d",
            self,
            NSStringFromClass([self class]),
            first);

    if (first)
        DPV398DumpObjectChain(self, @"V399_LIVE_EXTERNAL_MANAGER");

    DPTrace(@"========== V3.9.9 LIVE EXTERNAL SELF END ==========");
}

static id (*DPV399OrigExternalApplicationSceneHandles)(id, SEL) = NULL;

static id DPV399HookExternalApplicationSceneHandles(id self, SEL _cmd) {
    DPV399CaptureExternalSelf(self, _cmd, @"externalApplicationSceneHandles");

    id result = DPV399OrigExternalApplicationSceneHandles
        ? DPV399OrigExternalApplicationSceneHandles(self, _cmd)
        : nil;

    DPTrace(@"V3.9.9 externalApplicationSceneHandles result=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    return result;
}

static id (*DPV399OrigRunningApplicationScenes)(id, SEL) = NULL;

static id DPV399HookRunningApplicationScenes(id self, SEL _cmd) {
    DPV399CaptureExternalSelf(self, _cmd, @"runningApplicationScenes");

    id result = DPV399OrigRunningApplicationScenes
        ? DPV399OrigRunningApplicationScenes(self, _cmd)
        : nil;

    DPTrace(@"V3.9.9 runningApplicationScenes result=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    return result;
}

static id (*DPV399OrigWindowScene)(id, SEL) = NULL;

static id DPV399HookWindowScene(id self, SEL _cmd) {
    DPV399CaptureExternalSelf(self, _cmd, @"_windowScene");

    id result = DPV399OrigWindowScene
        ? DPV399OrigWindowScene(self, _cmd)
        : nil;

    DPTrace(@"V3.9.9 _windowScene result=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    if (result)
        DPV398DumpObjectChain(result, @"V399_WINDOW_SCENE");

    return result;
}

static id (*DPV399OrigNewSceneIdentifier)(id, SEL, id, BOOL) = NULL;

static id DPV399HookNewSceneIdentifier(id self,
                                       SEL _cmd,
                                       id bundleIdentifier,
                                       BOOL supportsMultiwindow) {
    DPV399CaptureExternalSelf(self, _cmd, @"newSceneIdentifier");

    DPTrace(@"V3.9.9 newSceneIdentifier bundle=%@ supportsMultiwindow=%d",
            bundleIdentifier ?: @"nil",
            supportsMultiwindow);

    id result = DPV399OrigNewSceneIdentifier
        ? DPV399OrigNewSceneIdentifier(self,
                                       _cmd,
                                       bundleIdentifier,
                                       supportsMultiwindow)
        : nil;

    DPTrace(@"V3.9.9 newSceneIdentifier result=%@ class=%@",
            result ?: @"nil",
            result ? NSStringFromClass([result class]) : @"nil");

    return result;
}

static void DPV399InstallLiveSelfCaptureHooks(void) {
    if (gV399LiveSelfHooksInstalled)
        return;

    Class cls = NSClassFromString(@"SBSystemShellExternalDisplaySceneManager");

    if (!cls) {
        DPTrace(@"V3.9.9 live hook FAIL no SBSystemShellExternalDisplaySceneManager");
        return;
    }

    BOOL installed = NO;

    SEL sel1 = NSSelectorFromString(@"externalApplicationSceneHandles");
    Method m1 = class_getInstanceMethod(cls, sel1);
    if (m1) {
        IMP imp = method_getImplementation(m1);
        if (imp && imp != (IMP)DPV399HookExternalApplicationSceneHandles) {
            DPV399OrigExternalApplicationSceneHandles =
                (id (*)(id, SEL))imp;
            method_setImplementation(m1,
                                     (IMP)DPV399HookExternalApplicationSceneHandles);
            DPTrace(@"V3.9.9 hook installed %@",
                    NSStringFromSelector(sel1));
            installed = YES;
        }
    }

    SEL sel2 = NSSelectorFromString(@"runningApplicationScenes");
    Method m2 = class_getInstanceMethod(cls, sel2);
    if (m2) {
        IMP imp = method_getImplementation(m2);
        if (imp && imp != (IMP)DPV399HookRunningApplicationScenes) {
            DPV399OrigRunningApplicationScenes =
                (id (*)(id, SEL))imp;
            method_setImplementation(m2,
                                     (IMP)DPV399HookRunningApplicationScenes);
            DPTrace(@"V3.9.9 hook installed %@",
                    NSStringFromSelector(sel2));
            installed = YES;
        }
    }

    SEL sel3 = NSSelectorFromString(@"_windowScene");
    Method m3 = class_getInstanceMethod(cls, sel3);
    if (m3) {
        IMP imp = method_getImplementation(m3);
        if (imp && imp != (IMP)DPV399HookWindowScene) {
            DPV399OrigWindowScene =
                (id (*)(id, SEL))imp;
            method_setImplementation(m3,
                                     (IMP)DPV399HookWindowScene);
            DPTrace(@"V3.9.9 hook installed %@",
                    NSStringFromSelector(sel3));
            installed = YES;
        }
    }

    SEL sel4 =
        NSSelectorFromString(@"newSceneIdentifierForBundleIdentifier:supportsMultiwindow:");
    Method m4 = class_getInstanceMethod(cls, sel4);
    if (m4) {
        IMP imp = method_getImplementation(m4);
        if (imp && imp != (IMP)DPV399HookNewSceneIdentifier) {
            DPV399OrigNewSceneIdentifier =
                (id (*)(id, SEL, id, BOOL))imp;
            method_setImplementation(m4,
                                     (IMP)DPV399HookNewSceneIdentifier);
            DPTrace(@"V3.9.9 hook installed %@",
                    NSStringFromSelector(sel4));
            installed = YES;
        }
    }

    gV399LiveSelfHooksInstalled = installed;

    DPTrace(@"V3.9.9 live self capture hooks ready=%d",
            gV399LiveSelfHooksInstalled);
}


static BOOL DPV3910InterestingIvarName(NSString *name) {
    if (!name) return NO;
    NSString *l = name.lowercaseString;
    return [l containsString:@"scene"] || [l containsString:@"display"] ||
           [l containsString:@"manager"] || [l containsString:@"external"] ||
           [l containsString:@"car"] || [l containsString:@"shell"] ||
           [l containsString:@"workspace"];
}

static BOOL DPV3910InterestingObject(id obj) {
    if (!obj) return NO;
    NSString *l = NSStringFromClass([obj class]).lowercaseString;
    return [l containsString:@"scene"] || [l containsString:@"display"] ||
           [l containsString:@"manager"] || [l containsString:@"workspace"] ||
           [l containsString:@"shell"];
}

static void DPV3910WalkObject(id obj, NSString *path, NSUInteger depth, NSHashTable *visited) {
    if (!obj || depth > 4 || !visited || [visited containsObject:obj]) return;
    [visited addObject:obj];

    Class wanted = NSClassFromString(@"SBSystemShellExternalDisplaySceneManager");
    if (wanted && [obj isKindOfClass:wanted]) {
        gV398CapturedExternalManager = obj;
        DPTrace(@"========== V3.9.10 FOUND EXTERNAL MANAGER ==========");
        DPTrace(@"V3.9.10 path=%@ object=%@ class=%@", path, obj, NSStringFromClass([obj class]));
        DPV398DumpObjectChain(obj, @"V3910_FOUND_EXTERNAL_MANAGER");
        DPTrace(@"========== V3.9.10 FOUND EXTERNAL MANAGER END ==========");
        return;
    }

    Class cls=[obj class];
    for (NSUInteger cd=0; cls && cd<7; cd++, cls=class_getSuperclass(cls)) {
        unsigned int count=0;
        Ivar *ivars=class_copyIvarList(cls,&count);
        for (unsigned int i=0;i<count;i++) {
            Ivar iv=ivars[i];
            const char *rn=ivar_getName(iv), *rt=ivar_getTypeEncoding(iv);
            if (!rn || !rt || rt[0]!='@') continue;
            NSString *name=[NSString stringWithUTF8String:rn];
            if (!DPV3910InterestingIvarName(name)) continue;

            id value=nil;
            @try { value=object_getIvar(obj,iv); } @catch (__unused NSException *e) {}
            if (!value) continue;

            NSString *next=[NSString stringWithFormat:@"%@.%@",path ?: @"root",name];
            DPTrace(@"V3.9.10 EDGE %@ => %@ class=%@",next,value,NSStringFromClass([value class]));

            if (wanted && [value isKindOfClass:wanted]) {
                gV398CapturedExternalManager=value;
                DPTrace(@"========== V3.9.10 FOUND EXTERNAL MANAGER ==========");
                DPTrace(@"V3.9.10 path=%@ object=%@ class=%@",next,value,NSStringFromClass([value class]));
                DPV398DumpObjectChain(value,@"V3910_FOUND_EXTERNAL_MANAGER");
                DPTrace(@"========== V3.9.10 FOUND EXTERNAL MANAGER END ==========");
            }
            if (depth<4 && DPV3910InterestingObject(value))
                DPV3910WalkObject(value,next,depth+1,visited);
        }
        if (ivars) free(ivars);
    }
}

static void DPV3910FindExternalManagerFromObjectGraph(id root) {
    if (!root || gV3910ActiveFinderDone) return;
    gV3910ActiveFinderDone=YES;
    DPTrace(@"========== V3.9.10 ACTIVE EXTERNAL MANAGER FINDER ==========");
    DPTrace(@"V3.9.10 root=%@ class=%@",root,NSStringFromClass([root class]));
    NSHashTable *visited=[NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];
    DPV3910WalkObject(root,@"workspace",0,visited);
    DPTrace(@"V3.9.10 finder visited=%lu captured=%@ class=%@",
            (unsigned long)visited.count,
            gV398CapturedExternalManager ?: @"nil",
            gV398CapturedExternalManager ? NSStringFromClass([gV398CapturedExternalManager class]) : @"nil");
    DPTrace(@"========== V3.9.10 ACTIVE EXTERNAL MANAGER FINDER END ==========");
}

static id DPV3911SafeValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static BOOL DPV3911LooksCarDisplayObject(id obj) {
    if (!obj) return NO;
    NSString *d = nil;
    @try { d = [obj description]; } @catch (__unused NSException *e) {}
    if (!d) return NO;
    NSString *l = d.lowercaseString;
    return [l containsString:@"car["] ||
           [l containsString:@"wireless0"] ||
           [l containsString:@"wireless"] ||
           [l containsString:@"1280x720"];
}

static BOOL DPV3911InterestingName(NSString *name) {
    if (!name) return NO;
    NSString *l = name.lowercaseString;
    return [l containsString:@"display"] ||
           [l containsString:@"source"] ||
           [l containsString:@"scene"] ||
           [l containsString:@"manager"] ||
           [l containsString:@"owner"] ||
           [l containsString:@"controller"] ||
           [l containsString:@"provider"] ||
           [l containsString:@"monitor"] ||
           [l containsString:@"external"] ||
           [l containsString:@"workspace"] ||
           [l containsString:@"shell"];
}

static void DPV3911DumpObject(id obj, NSString *tag) {
    if (!obj || !tag) return;

    DPTrace(@"========== V3.9.11 OBJECT %@ ==========", tag);
    DPTrace(@"V3.9.11 %@ object=%@ class=%@", tag, obj, NSStringFromClass([obj class]));

    for (NSString *key in @[
        @"displayIdentity", @"identity", @"display", @"displayConfiguration",
        @"configuration", @"source", @"displaySource", @"owner", @"manager",
        @"sceneManager", @"windowScene", @"_windowScene", @"scene", @"workspace",
        @"provider", @"sceneHandleProvider", @"controller", @"delegate", @"monitor"
    ]) {
        id value = DPV3911SafeValue(obj, key);
        if (value) {
            DPTrace(@"V3.9.11 %@ KVC %@ => %@ class=%@",
                    tag, key, value, NSStringFromClass([value class]));
        }
    }

    Class cls = [obj class];
    for (NSUInteger depth = 0; cls && depth < 8; depth++, cls = class_getSuperclass(cls)) {
        unsigned int count = 0;
        Ivar *ivars = class_copyIvarList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            Ivar iv = ivars[i];
            const char *rn = ivar_getName(iv);
            const char *rt = ivar_getTypeEncoding(iv);
            if (!rn || !rt || rt[0] != '@') continue;

            NSString *name = [NSString stringWithUTF8String:rn];
            if (!DPV3911InterestingName(name)) continue;

            id value = nil;
            @try { value = object_getIvar(obj, iv); }
            @catch (__unused NSException *e) {}
            if (!value) continue;

            DPTrace(@"V3.9.11 %@ IVAR %@ => %@ class=%@",
                    tag, name, value, NSStringFromClass([value class]));
        }

        if (ivars) free(ivars);
    }

    DPTrace(@"========== V3.9.11 OBJECT %@ END ==========", tag);
}

static id DPV3911FindDisplayMonitor(id root) {
    if (!root) return nil;

    NSMutableArray *queue = [NSMutableArray arrayWithObject:root];
    NSHashTable *visited =
        [NSHashTable hashTableWithOptions:NSPointerFunctionsObjectPointerPersonality];

    NSUInteger cursor = 0;

    while (cursor < queue.count && cursor < 160) {
        id obj = queue[cursor++];
        if (!obj || [visited containsObject:obj]) continue;
        [visited addObject:obj];

        NSString *cn = NSStringFromClass([obj class]);
        if ([cn containsString:@"FBSDisplayMonitor"]) {
            DPTrace(@"V3.9.11 displayMonitor FOUND %@ class=%@", obj, cn);
            return obj;
        }

        Class cls = [obj class];
        for (NSUInteger cd = 0; cls && cd < 5; cd++, cls = class_getSuperclass(cls)) {
            unsigned int count = 0;
            Ivar *ivars = class_copyIvarList(cls, &count);

            for (unsigned int i = 0; i < count; i++) {
                Ivar iv = ivars[i];
                const char *rn = ivar_getName(iv);
                const char *rt = ivar_getTypeEncoding(iv);
                if (!rn || !rt || rt[0] != '@') continue;

                NSString *name = [NSString stringWithUTF8String:rn];
                if (!DPV3911InterestingName(name)) continue;

                id value = nil;
                @try { value = object_getIvar(obj, iv); }
                @catch (__unused NSException *e) {}

                if (value && queue.count < 300)
                    [queue addObject:value];
            }

            if (ivars) free(ivars);
        }
    }

    DPTrace(@"V3.9.11 displayMonitor NOT FOUND visited=%lu",
            (unsigned long)visited.count);
    return nil;
}

static void DPV3911InspectSources(id monitor) {
    if (!monitor) return;

    id map = DPV3911SafeValue(monitor, @"_lock_sourcesByDisplay");
    if (!map) map = DPV3911SafeValue(monitor, @"sourcesByDisplay");

    DPTrace(@"V3.9.11 sourcesByDisplay=%@ class=%@",
            map ?: @"nil",
            map ? NSStringFromClass([map class]) : @"nil");

    if (![map isKindOfClass:[NSDictionary class]]) {
        DPV3911DumpObject(monitor, @"DISPLAY_MONITOR");
        return;
    }

    NSDictionary *dict = (NSDictionary *)map;

    for (id key in dict) {
        id value = dict[key];

        DPTrace(@"V3.9.11 DISPLAY MAP key=%@ class=%@ value=%@ class=%@",
                key,
                NSStringFromClass([key class]),
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");

        if (!(DPV3911LooksCarDisplayObject(key) || DPV3911LooksCarDisplayObject(value)))
            continue;

        gV3911CapturedCarDisplaySource = value;

        DPTrace(@"========== V3.9.11 CAR DISPLAY SOURCE FOUND ==========");
        DPTrace(@"V3.9.11 carKey=%@ class=%@", key, NSStringFromClass([key class]));
        DPTrace(@"V3.9.11 carSource=%@ class=%@",
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");

        DPV3911DumpObject(key, @"CAR_DISPLAY_KEY");
        if (value) DPV3911DumpObject(value, @"CAR_DISPLAY_SOURCE");

        if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
            for (id item in value) {
                DPTrace(@"V3.9.11 CAR SOURCE ITEM %@ class=%@",
                        item, NSStringFromClass([item class]));
                DPV3911DumpObject(item, @"CAR_SOURCE_ITEM");
            }
        }

        DPTrace(@"========== V3.9.11 CAR DISPLAY SOURCE FOUND END ==========");
    }
}

static void DPV3911ProbeCarDisplaySourceGraph(id root) {
    if (!root || gV3911CarDisplaySourceProbeDone) return;
    gV3911CarDisplaySourceProbeDone = YES;

    DPTrace(@"========== V3.9.11 CAR DISPLAY SOURCE GRAPH ==========");
    DPTrace(@"V3.9.11 root=%@ class=%@", root, NSStringFromClass([root class]));

    id monitor = DPV3911FindDisplayMonitor(root);

    DPTrace(@"V3.9.11 monitor=%@ class=%@",
            monitor ?: @"nil",
            monitor ? NSStringFromClass([monitor class]) : @"nil");

    if (monitor) DPV3911InspectSources(monitor);

    DPTrace(@"V3.9.11 capturedCarDisplaySource=%@ class=%@",
            gV3911CapturedCarDisplaySource ?: @"nil",
            gV3911CapturedCarDisplaySource
                ? NSStringFromClass([gV3911CapturedCarDisplaySource class])
                : @"nil");

    DPTrace(@"========== V3.9.11 CAR DISPLAY SOURCE GRAPH END ==========");
}

static void DPV397ProbeProviderClassMap(id provider) {
    if (!provider || gV397ProviderClassMapDone)
        return;

    gV397ProviderClassMapDone = YES;

    DPTrace(@"========== V3.9.7 PROVIDER CLASS MAP ==========");
    DPTrace(@"V3.9.7 provider=%@ class=%@",
            provider,
            NSStringFromClass([provider class]));

    DPV397LogProviderKVC(provider);

    Class cls = [provider class];
    NSUInteger depth = 0;

    while (cls && depth < 8) {
        DPV397DumpClassSurface(
            cls,
            [NSString stringWithFormat:@"PROVIDER_DEPTH_%lu_%@",
             (unsigned long)depth,
             NSStringFromClass(cls)]
        );

        cls = class_getSuperclass(cls);
        depth++;
    }

    DPV397EnumerateCandidateProviderClasses();

    DPTrace(@"========== V3.9.7 PROVIDER CLASS MAP END ==========");
}

static void DPV394ProbeSceneHandleProvider(id application) {
    if (!application || gV394ProviderProbeDone)
        return;

    gV394ProviderProbeDone = YES;

    DPTrace(@"========== V3.9.4 SCENE HANDLE PROVIDER PROBE ==========");

    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    SEL mainEntitySel = NSSelectorFromString(@"newEntityWithApplicationForMainDisplay:");

    id mainEntity = nil;

    if (entityClass && [entityClass respondsToSelector:mainEntitySel]) {
        typedef id (*Fn)(id, SEL, id);
        Fn fn = (Fn)[entityClass methodForSelector:mainEntitySel];
        if (fn) {
            @try {
                mainEntity = fn(entityClass, mainEntitySel, application);
            } @catch (NSException *e) {
                DPTrace(@"V3.9.4 main entity create exception=%@ reason=%@",
                        e.name ?: @"?",
                        e.reason ?: @"?");
            }
        }
    }

    DPV394DumpProviderSurface(mainEntity, @"MAIN_ENTITY");

    id mainSceneHandle = nil;
    @try { mainSceneHandle = [mainEntity valueForKey:@"sceneHandle"]; }
    @catch (__unused NSException *e) {}

    DPV394DumpProviderSurface(mainSceneHandle, @"MAIN_SCENE_HANDLE");

    Class baseEntity = NSClassFromString(@"SBApplicationSceneEntity");
    if (baseEntity)
        DPV394DumpProviderSurface((id)baseEntity, @"SBApplicationSceneEntity_CLASS");

    Class handleClass = NSClassFromString(@"SBDeviceApplicationSceneHandle");
    if (handleClass)
        DPV394DumpProviderSurface((id)handleClass, @"SBDeviceApplicationSceneHandle_CLASS");

    DPTrace(@"========== V3.9.4 SCENE HANDLE PROVIDER PROBE END ==========");
}

static void DPV391ProbeCarDisplayEntity(id application) {
    if (!application || gV391CarDisplayEntityProbeDone) return;
    gV391CarDisplayEntityProbeDone = YES;
    DPTrace(@"========== V3.9.1 CAR DISPLAY ENTITY PROBE ==========");
    DPV395LogCapturedProviderSnapshot();
    DPV394ProbeSceneHandleProvider(application);
    DPTrace(@"V3.9.6 provider probe completed; snapshot after capture follows");
    DPV395LogCapturedProviderSnapshot();

    if (gV395CapturedSceneHandleProvider)
        DPV397ProbeProviderClassMap(gV395CapturedSceneHandleProvider);

    DPTrace(@"V3.9.8 capturedExternalManager=%@ class=%@",
            gV398CapturedExternalManager ?: @"nil",
            gV398CapturedExternalManager
                ? NSStringFromClass([gV398CapturedExternalManager class])
                : @"nil");

    if (gV398CapturedExternalManager)
        DPV398DumpObjectChain(gV398CapturedExternalManager,
                              @"EXTERNAL_MANAGER_SNAPSHOT");

    id carIdentity = DPV392LoadBridgedCarIdentity();

    if (!carIdentity) {
        DPTrace(@"V3.9.3 no bridged Car identity yet; aborting Car entity probe instead of falling back to Main");
    }

    if (!carIdentity)
        carIdentity = DPV391GetCarDisplayIdentityFromRuntime();
    DPTrace(@"V3.9.1 carIdentity=%@ class=%@", carIdentity ?: @"nil", carIdentity ? NSStringFromClass([carIdentity class]) : @"nil");
    if (carIdentity) {
        BOOL isCar = NO;
        SEL carSel = NSSelectorFromString(@"isCarDisplay");

        if ([carIdentity respondsToSelector:carSel]) {
            typedef BOOL (*BoolFn)(id, SEL);
            BoolFn boolFn = (BoolFn)[carIdentity methodForSelector:carSel];
            if (boolFn) {
                @try { isCar = boolFn(carIdentity, carSel); }
                @catch (__unused NSException *e) {}
            }
        }

        id currentConfiguration =
            DPV341SafeValue(carIdentity, @"currentConfiguration");

        DPTrace(@"V3.9.2 identity validation isCarDisplay=%d currentConfiguration=%@",
                isCar,
                currentConfiguration ?: @"nil");
    }
    if (!carIdentity) {
        DPTrace(@"V3.9.1 FAIL no car display identity");
        DPTrace(@"========== V3.9.1 CAR DISPLAY ENTITY PROBE END ==========");
        return;
    }
    Class entityClass = NSClassFromString(@"SBDeviceApplicationSceneEntity");
    SEL entitySel = NSSelectorFromString(@"newEntityWithApplication:sceneHandleProvider:displayIdentity:");
    id entity = nil;
    if (entityClass && [entityClass respondsToSelector:entitySel]) {
        typedef id (*Fn)(id, SEL, id, id, id);
        Fn fn = (Fn)[entityClass methodForSelector:entitySel];
        if (fn) {
            id provider = gV395CapturedSceneHandleProvider;

            DPTrace(@"========== V3.9.6 CAR ENTITY CREATE ==========");
            DPTrace(@"V3.9.6 provider=%@ class=%@",
                    provider ?: @"nil",
                    provider ? NSStringFromClass([provider class]) : @"nil");
            DPTrace(@"V3.9.6 carIdentity=%@ class=%@",
                    carIdentity ?: @"nil",
                    carIdentity ? NSStringFromClass([carIdentity class]) : @"nil");

            if (!provider) {
                DPTrace(@"V3.9.6 ABORT provider still nil after provider probe");
            } else {
                @try {
                    entity = fn(entityClass,
                                entitySel,
                                application,
                                provider,
                                carIdentity);
                } @catch (NSException *e) {
                    DPTrace(@"V3.9.6 entity create exception=%@ reason=%@",
                            e.name ?: @"?",
                            e.reason ?: @"?");
                }
            }

            DPTrace(@"========== V3.9.6 CAR ENTITY CREATE END ==========");
        }
    }
    DPTrace(@"V3.9.1 entity=%@ class=%@", entity ?: @"nil", entity ? NSStringFromClass([entity class]) : @"nil");
    id sceneHandle = DPV390SafeValue(entity, @"sceneHandle");
    DPTrace(@"V3.9.1 sceneHandle=%@ class=%@", sceneHandle ?: @"nil", sceneHandle ? NSStringFromClass([sceneHandle class]) : @"nil");
    if (sceneHandle) {
        id displayIdentity = DPV390SafeValue(sceneHandle, @"displayIdentity");
        id scene = nil;
        @try { scene = [sceneHandle valueForKey:@"scene"]; } @catch (__unused NSException *e) {}
        DPTrace(@"V3.9.1 sceneHandle.displayIdentity=%@ class=%@", displayIdentity ?: @"nil", displayIdentity ? NSStringFromClass([displayIdentity class]) : @"nil");
        DPTrace(@"V3.9.1 sceneHandle.scene=%@ class=%@", scene ?: @"nil", scene ? NSStringFromClass([scene class]) : @"nil");
        id vc = nil; SEL vcSel = NSSelectorFromString(@"newSceneViewController");
        if ([sceneHandle respondsToSelector:vcSel]) {
            typedef id (*VCFn)(id, SEL); VCFn vcFn = (VCFn)[sceneHandle methodForSelector:vcSel];
            if (vcFn) { @try { vc = vcFn(sceneHandle, vcSel); } @catch (NSException *e) { DPTrace(@"V3.9.1 newSceneViewController exception=%@ reason=%@", e.name ?: @"?", e.reason ?: @"?"); } }
        }
        DPTrace(@"V3.9.1 viewController=%@ class=%@", vc ?: @"nil", vc ? NSStringFromClass([vc class]) : @"nil");
        if (vc) {
            id contentView = DPV390SafeValue(vc, @"sceneContentView");
            DPTrace(@"V3.9.1 sceneContentView=%@ class=%@ frame=%@", contentView ?: @"nil", contentView ? NSStringFromClass([contentView class]) : @"nil", [contentView isKindOfClass:UIView.class] ? NSStringFromCGRect(((UIView *)contentView).frame) : @"nil");
        }
        SEL viewSel = NSSelectorFromString(@"newSceneViewWithReferenceSize:contentOrientation:containerOrientation:hostRequester:");
        DPTrace(@"V3.9.1 newSceneViewWithReferenceSize available=%d", [sceneHandle respondsToSelector:viewSel]);
    }
    DPTrace(@"========== V3.9.1 CAR DISPLAY ENTITY PROBE END ==========");
}

static void DPSpringBoardBridgeRequest(void) {
    if (!DPIsSpringBoard())
        return;

    DPTrace(@"========== APPBRIDGE REQUEST RECEIVED ==========");
    DPTrace(@"requested bundle=com.apple.Maps");

    DPSpringBoardTargetMap();

    DPSpringBoardHostProbe();

    DPV33InstallActivationHooks();

    gV361SingletonProbeDone = NO;
    DPV361ProbeCarDisplaySingletons();

    DPTrace(@"V3.6.2 AppBridge request: forced fresh CarPlay display lookup");

    DPV34TryActivateMapsOnCarPlay();

    CFNotificationCenterPostNotification(
        CFNotificationCenterGetDarwinNotifyCenter(),
        kBridgeReply,
        NULL,
        NULL,
        YES
    );

    DPTrace(@"APPBRIDGE REPLY posted");
    DPTrace(@"========== APPBRIDGE REQUEST END ==========");
}

static void DPBridgeRequestCallback(CFNotificationCenterRef center,
                                    void *observer,
                                    CFStringRef name,
                                    const void *object,
                                    CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    dispatch_async(
        dispatch_get_main_queue(),
        ^{
            DPSpringBoardBridgeRequest();
        }
    );
}

static void DPBridgeReplyCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    (void)center;
    (void)observer;
    (void)name;
    (void)object;
    (void)userInfo;

    DPTrace(@"APPBRIDGE REPLY received in CarPlay");
}

static void DPRegisterBridgeNotifications(void) {
    if (DPIsSpringBoard()) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            DPBridgeRequestCallback,
            kBridgeRequest,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        DPTrace(@"SpringBoard AppBridge listener ready");
    DPV395InstallProviderCaptureHooks();
    DPV398InstallExternalManagerCaptureHooks();
    DPV399InstallLiveSelfCaptureHooks();
    }

    if (DPIsCarPlay()) {
        CFNotificationCenterAddObserver(
            CFNotificationCenterGetDarwinNotifyCenter(),
            NULL,
            DPBridgeReplyCallback,
            kBridgeReply,
            NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately
        );

        DPTrace(@"CarPlay AppBridge reply listener ready");
    }
}


static id DPV370SafeValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void DPV370LogObjectKeys(id obj, NSString *tag, NSArray<NSString *> *keys) {
    if (!obj || !tag) return;
    DPTrace(@"V3.7 %@ object=%@ class=%@", tag, obj, NSStringFromClass([obj class]));
    for (NSString *key in keys) {
        id value = DPV370SafeValue(obj, key);
        DPTrace(@"V3.7 %@.%@ => %@ class=%@", tag, key, value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");
    }
}

static void DPV370RuntimeMethods(id obj, NSString *tag) {
    if (!obj || !tag) return;
    Class cls = [obj class];
    NSUInteger depth = 0;
    while (cls && depth < 5) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;
            if ([lower containsString:@"scene"] || [lower containsString:@"display"] ||
                [lower containsString:@"context"] || [lower containsString:@"layer"] ||
                [lower containsString:@"identity"] || [lower containsString:@"host"] ||
                [lower containsString:@"client"]) {
                DPTrace(@"V3.7 %@ METHOD %@.%@ types=%s", tag, NSStringFromClass(cls), name,
                        method_getTypeEncoding(methods[i]) ?: "?");
            }
        }
        if (methods) free(methods);
        cls = class_getSuperclass(cls);
        depth++;
    }
}

static void DPV370CollectViews(UIView *view, NSMutableArray *hosts) {
    if (!view || !hosts) return;
    NSString *className = NSStringFromClass([view class]);
    if ([className isEqualToString:@"_UIContextLayerHostView"] ||
        [className containsString:@"SceneLayerHost"] ||
        [className containsString:@"ScenePresentation"]) {
        [hosts addObject:view];
    }
    for (UIView *child in view.subviews) DPV370CollectViews(child, hosts);
}

static void DPV370MapCarPlaySceneAndHosts(void) {
    if (!DPIsCarPlay() || gV370CarPlaySceneHostMapDone) return;
    gV370CarPlaySceneHostMapDone = YES;
    DPTrace(@"========== V3.7 CARPLAY SCENE HOST MAP ==========");
    NSUInteger sceneIndex = 0;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        DPTrace(@"V3.7 SCENE[%lu] role=%@ pid=%@ activation=%ld class=%@",
                (unsigned long)sceneIndex, scene.session.role ?: @"nil",
                scene.session.persistentIdentifier ?: @"nil", (long)scene.activationState,
                NSStringFromClass([scene class]));
        DPTrace(@"V3.7 SCENE[%lu] coordinateBounds=%@ screenBounds=%@",
                (unsigned long)sceneIndex, NSStringFromCGRect(ws.coordinateSpace.bounds),
                NSStringFromCGRect(ws.screen.bounds));
        id fbsScene = DPV370SafeValue(scene, @"_FBSScene");
        if (!fbsScene) fbsScene = DPV370SafeValue(scene, @"scene");
        id settings = DPV370SafeValue(fbsScene, @"settings");
        id clientSettings = DPV370SafeValue(fbsScene, @"clientSettings");
        id displayConfig = DPV370SafeValue(settings, @"displayConfiguration");
        if (!displayConfig) displayConfig = DPV370SafeValue(scene, @"displayConfiguration");
        NSArray *sceneKeys = @[@"identifier",@"settings",@"clientSettings",@"hostProcess",@"sceneLayer",@"context",@"displayIdentity",@"displayConfiguration"];
        NSArray *settingsKeys = @[@"displayConfiguration",@"frame",@"foreground",@"level",@"interfaceOrientation",@"sceneIdentifier",@"identifier"];
        NSArray *displayKeys = @[@"identity",@"displayIdentity",@"identifier",@"displayID",@"name",@"bounds",@"currentMode",@"CADisplay"];
        DPV370LogObjectKeys(fbsScene,[NSString stringWithFormat:@"FBSSCENE[%lu]",(unsigned long)sceneIndex],sceneKeys);
        DPV370LogObjectKeys(settings,[NSString stringWithFormat:@"SETTINGS[%lu]",(unsigned long)sceneIndex],settingsKeys);
        DPV370LogObjectKeys(clientSettings,[NSString stringWithFormat:@"CLIENTSETTINGS[%lu]",(unsigned long)sceneIndex],settingsKeys);
        DPV370LogObjectKeys(displayConfig,[NSString stringWithFormat:@"DISPLAY[%lu]",(unsigned long)sceneIndex],displayKeys);
        DPV370RuntimeMethods(fbsScene,[NSString stringWithFormat:@"FBSSCENE[%lu]",(unsigned long)sceneIndex]);
        DPV370RuntimeMethods(displayConfig,[NSString stringWithFormat:@"DISPLAY[%lu]",(unsigned long)sceneIndex]);
        NSUInteger windowIndex = 0;
        for (UIWindow *window in ws.windows) {
            DPTrace(@"V3.7 WINDOW[%lu:%lu] class=%@ frame=%@ hidden=%d level=%.1f root=%@",
                    (unsigned long)sceneIndex,(unsigned long)windowIndex,NSStringFromClass([window class]),
                    NSStringFromCGRect(window.frame),window.hidden,window.windowLevel,
                    window.rootViewController ? NSStringFromClass([window.rootViewController class]) : @"nil");
            if (window.rootViewController) {
                NSMutableArray *hosts=[NSMutableArray array];
                DPV370CollectViews(window.rootViewController.view,hosts);
                NSUInteger hostIndex=0;
                for (UIView *hostView in hosts) {
                    CALayer *layer=hostView.layer;
                    id sceneLayer=DPV370SafeValue(hostView,@"sceneLayer");
                    id presentation=DPV370SafeValue(hostView,@"currentPresentationContext");
                    id context=DPV370SafeValue(layer,@"context");
                    id contextId=DPV370SafeValue(layer,@"contextId");
                    id sceneContextId=DPV370SafeValue(sceneLayer,@"contextID");
                    id sceneId=DPV370SafeValue(sceneLayer,@"sceneID");
                    id externalSceneId=DPV370SafeValue(sceneLayer,@"externalSceneID");
                    DPTrace(@"========== V3.7 REMOTE HOST ==========");
                    DPTrace(@"V3.7 HOST[%lu:%lu:%lu] view=%@ frame=%@ layer=%@",
                            (unsigned long)sceneIndex,(unsigned long)windowIndex,(unsigned long)hostIndex,
                            NSStringFromClass([hostView class]),NSStringFromCGRect(hostView.frame),NSStringFromClass([layer class]));
                    DPTrace(@"V3.7 HOST contextId=%@ sceneContextID=%@ sceneID=%@ externalSceneID=%@",
                            contextId ?: @"nil", sceneContextId ?: @"nil", sceneId ?: @"nil", externalSceneId ?: @"nil");
                    DPTrace(@"V3.7 HOST sceneLayer=%@ class=%@",sceneLayer ?: @"nil",sceneLayer ? NSStringFromClass([sceneLayer class]) : @"nil");
                    DPTrace(@"V3.7 HOST presentation=%@ class=%@",presentation ?: @"nil",presentation ? NSStringFromClass([presentation class]) : @"nil");
                    DPTrace(@"V3.7 HOST context=%@ class=%@",context ?: @"nil",context ? NSStringFromClass([context class]) : @"nil");
                    DPV370LogObjectKeys(sceneLayer,@"HOST_SCENELAYER",@[@"scene",@"sceneID",@"externalSceneID",@"contextID",@"identifier",@"displayIdentity",@"displayConfiguration",@"client",@"host"]);
                    DPV370LogObjectKeys(presentation,@"HOST_PRESENTATION",@[@"scene",@"sceneIdentifier",@"identifier",@"sceneLayer",@"context",@"contextID",@"displayIdentity"]);
                    DPV370RuntimeMethods(sceneLayer,@"HOST_SCENELAYER");
                    DPTrace(@"========== V3.7 REMOTE HOST END ==========");
                    hostIndex++;
                }
            }
            windowIndex++;
        }
        sceneIndex++;
    }
    DPTrace(@"========== V3.7 CARPLAY SCENE HOST MAP END ==========");
}


static id DPV371SafeValue(id obj, NSString *key) {
    if (!obj || !key) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

static void DPV371LogRuntimeFiltered(id obj, NSString *tag) {
    if (!obj || !tag) return;
    Class cls = [obj class];
    NSUInteger depth = 0;

    while (cls && depth < 6) {
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);

        for (unsigned int i = 0; i < count; i++) {
            NSString *name = NSStringFromSelector(method_getName(methods[i]));
            NSString *lower = name.lowercaseString;

            if ([lower containsString:@"scene"] ||
                [lower containsString:@"context"] ||
                [lower containsString:@"layer"] ||
                [lower containsString:@"client"] ||
                [lower containsString:@"host"] ||
                [lower containsString:@"display"] ||
                [lower containsString:@"identity"] ||
                [lower containsString:@"attach"] ||
                [lower containsString:@"detach"]) {
                DPTrace(@"V3.7.1 %@ METHOD %@.%@ types=%s",
                        tag,
                        NSStringFromClass(cls),
                        name,
                        method_getTypeEncoding(methods[i]) ?: "?");
            }
        }

        if (methods) free(methods);
        cls = class_getSuperclass(cls);
        depth++;
    }
}

static id DPV371FindDashboardFBSScene(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        NSString *pid = scene.session.persistentIdentifier ?: @"";
        if (![pid containsString:@"DBDashboard-Car"]) continue;

        id fbsScene = DPV371SafeValue(scene, @"_FBSScene");
        if (!fbsScene) fbsScene = DPV371SafeValue(scene, @"scene");
        if (fbsScene) return fbsScene;
    }
    return nil;
}

static UIView *DPV371FindLiveContextHostView(void) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;

        NSString *pid = scene.session.persistentIdentifier ?: @"";
        if (![pid containsString:@"DBDashboard-Car"]) continue;

        UIWindowScene *ws = (UIWindowScene *)scene;

        for (UIWindow *window in ws.windows) {
            if (!window.rootViewController) continue;

            NSMutableArray *hosts = [NSMutableArray array];
            DPV370CollectViews(window.rootViewController.view, hosts);

            for (UIView *host in hosts) {
                if ([NSStringFromClass([host class]) isEqualToString:@"_UIContextLayerHostView"])
                    return host;
            }
        }
    }
    return nil;
}

static void DPV371ProbeSceneContexts(void) {
    if (!DPIsCarPlay() || gV371ContextProbeDone) return;

    gV371ContextProbeDone = YES;

    id fbsScene = DPV371FindDashboardFBSScene();
    UIView *hostView = DPV371FindLiveContextHostView();

    DPTrace(@"========== V3.7.1 FBS SCENE CONTEXT PROBE ==========");
    DPTrace(@"V3.7.1 dashboardFBSScene=%@ class=%@",
            fbsScene ?: @"nil",
            fbsScene ? NSStringFromClass([fbsScene class]) : @"nil");

    NSArray<NSString *> *sceneKeys = @[
        @"identity",
        @"identityToken",
        @"identifier",
        @"display",
        @"fbsDisplay",
        @"contexts",
        @"layers",
        @"hostProcess",
        @"clientProcess",
        @"settings",
        @"clientSettings",
        @"uiClientSettings"
    ];

    for (NSString *key in sceneKeys) {
        id value = DPV371SafeValue(fbsScene, key);
        DPTrace(@"V3.7.1 FBSScene.%@ => %@ class=%@",
                key,
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");
    }

    id contexts = DPV371SafeValue(fbsScene, @"contexts");
    NSArray *contextArray = DPV341ObjectsFromContainer(contexts);

    DPTrace(@"V3.7.1 contexts count=%lu",
            (unsigned long)contextArray.count);

    NSUInteger contextIndex = 0;
    for (id ctx in contextArray) {
        DPTrace(@"========== V3.7.1 SCENE CONTEXT[%lu] ==========",
                (unsigned long)contextIndex);
        DPTrace(@"V3.7.1 CONTEXT[%lu] object=%@ class=%@",
                (unsigned long)contextIndex,
                ctx,
                NSStringFromClass([ctx class]));

        NSArray<NSString *> *ctxKeys = @[
            @"identifier",
            @"contextID",
            @"scene",
            @"sceneID",
            @"externalSceneID",
            @"displayIdentity",
            @"displayConfiguration",
            @"layer",
            @"sceneLayer",
            @"host",
            @"client",
            @"clientIdentity",
            @"processIdentifier",
            @"pid"
        ];

        for (NSString *key in ctxKeys) {
            id value = DPV371SafeValue(ctx, key);
            DPTrace(@"V3.7.1 CONTEXT[%lu].%@ => %@ class=%@",
                    (unsigned long)contextIndex,
                    key,
                    value ?: @"nil",
                    value ? NSStringFromClass([value class]) : @"nil");
        }

        DPV371LogRuntimeFiltered(
            ctx,
            [NSString stringWithFormat:@"CONTEXT[%lu]",
             (unsigned long)contextIndex]
        );

        contextIndex++;
    }

    id layers = DPV371SafeValue(fbsScene, @"layers");
    NSArray *layerArray = DPV341ObjectsFromContainer(layers);

    DPTrace(@"V3.7.1 layers count=%lu",
            (unsigned long)layerArray.count);

    NSUInteger layerIndex = 0;
    for (id layer in layerArray) {
        DPTrace(@"V3.7.1 LAYER[%lu] object=%@ class=%@",
                (unsigned long)layerIndex,
                layer,
                NSStringFromClass([layer class]));

        NSArray<NSString *> *layerKeys = @[
            @"contextID",
            @"sceneID",
            @"externalSceneID",
            @"identifier"
        ];

        for (NSString *key in layerKeys) {
            id value = DPV371SafeValue(layer, key);
            DPTrace(@"V3.7.1 LAYER[%lu].%@ => %@ class=%@",
                    (unsigned long)layerIndex,
                    key,
                    value ?: @"nil",
                    value ? NSStringFromClass([value class]) : @"nil");
        }

        layerIndex++;
    }

    if (hostView) {
        CALayer *hostLayer = hostView.layer;
        id hostSceneLayer = DPV371SafeValue(hostView, @"sceneLayer");
        id hostPresentation = DPV371SafeValue(hostView, @"currentPresentationContext");
        id hostContext = DPV371SafeValue(hostLayer, @"context");
        id hostContextId = DPV371SafeValue(hostLayer, @"contextId");

        DPTrace(@"========== V3.7.1 LIVE HOST DETAIL ==========");
        DPTrace(@"V3.7.1 hostLayer=%@ class=%@ contextId=%@",
                hostLayer,
                NSStringFromClass([hostLayer class]),
                hostContextId ?: @"nil");

        DPTrace(@"V3.7.1 hostSceneLayer=%@ class=%@",
                hostSceneLayer ?: @"nil",
                hostSceneLayer ? NSStringFromClass([hostSceneLayer class]) : @"nil");

        DPTrace(@"V3.7.1 hostPresentation=%@ class=%@",
                hostPresentation ?: @"nil",
                hostPresentation ? NSStringFromClass([hostPresentation class]) : @"nil");

        DPTrace(@"V3.7.1 hostCAContext=%@ class=%@",
                hostContext ?: @"nil",
                hostContext ? NSStringFromClass([hostContext class]) : @"nil");

        DPV371LogRuntimeFiltered(hostSceneLayer, @"HOST_SCENELAYER");
        DPV371LogRuntimeFiltered(hostPresentation, @"HOST_PRESENTATION");
        DPV371LogRuntimeFiltered(hostContext, @"HOST_CACONTEXT");

        NSArray<NSString *> *hostContextKeys = @[
            @"contextId",
            @"contextID",
            @"layer",
            @"scene",
            @"displayIdentity",
            @"displayConfiguration",
            @"client",
            @"host"
        ];

        for (NSString *key in hostContextKeys) {
            id value = DPV371SafeValue(hostContext, key);
            DPTrace(@"V3.7.1 HOST_CACONTEXT.%@ => %@ class=%@",
                    key,
                    value ?: @"nil",
                    value ? NSStringFromClass([value class]) : @"nil");
        }

        DPTrace(@"========== V3.7.1 LIVE HOST DETAIL END ==========");
    }

    DPV371LogRuntimeFiltered(fbsScene, @"FBSSCENE");
    DPTrace(@"========== V3.7.1 FBS SCENE CONTEXT PROBE END ==========");
}


static BOOL DPV372UsefulName(NSString *name) {
    if (!name) return NO;
    NSString *l = name.lowercaseString;

    return [l containsString:@"context"] ||
           [l containsString:@"scene"] ||
           [l containsString:@"layer"] ||
           [l containsString:@"display"] ||
           [l containsString:@"identity"] ||
           [l containsString:@"host"] ||
           [l containsString:@"client"] ||
           [l containsString:@"attach"] ||
           [l containsString:@"detach"] ||
           [l containsString:@"identifier"] ||
           [l containsString:@"port"] ||
           [l containsString:@"fence"];
}

static void DPV372ProbeObject(id obj, NSString *tag) {
    if (!obj || !tag) return;

    DPTrace(@"========== V3.7.2 OBJECT %@ ==========", tag);
    DPTrace(@"V3.7.2 %@ object=%@ class=%@",
            tag,
            obj,
            NSStringFromClass([obj class]));

    NSArray<NSString *> *keys = @[
        @"contextID",
        @"contextId",
        @"sceneID",
        @"externalSceneID",
        @"identifier",
        @"scene",
        @"sceneLayer",
        @"layer",
        @"display",
        @"displayIdentity",
        @"displayConfiguration",
        @"client",
        @"clientIdentity",
        @"host",
        @"hostProcess",
        @"clientProcess",
        @"contexts",
        @"layers",
        @"port",
        @"fence"
    ];

    for (NSString *key in keys) {
        id value = DPV371SafeValue(obj, key);

        DPTrace(@"V3.7.2 %@.%@ => %@ class=%@",
                tag,
                key,
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");
    }

    Class cls = [obj class];
    NSUInteger depth = 0;

    while (cls && depth < 6) {
        unsigned int mc = 0;
        Method *methods = class_copyMethodList(cls, &mc);

        for (unsigned int i = 0; i < mc; i++) {
            SEL sel = method_getName(methods[i]);
            NSString *name = NSStringFromSelector(sel);

            if (!DPV372UsefulName(name))
                continue;

            DPTrace(@"V3.7.2 %@ METHOD %@.%@ types=%s",
                    tag,
                    NSStringFromClass(cls),
                    name,
                    method_getTypeEncoding(methods[i]) ?: "?");
        }

        if (methods) free(methods);

        unsigned int pc = 0;
        objc_property_t *props = class_copyPropertyList(cls, &pc);

        for (unsigned int i = 0; i < pc; i++) {
            const char *raw = property_getName(props[i]);
            NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;

            if (DPV372UsefulName(name))
                DPTrace(@"V3.7.2 %@ PROPERTY %@.%@",
                        tag,
                        NSStringFromClass(cls),
                        name);
        }

        if (props) free(props);

        unsigned int ic = 0;
        Ivar *ivars = class_copyIvarList(cls, &ic);

        for (unsigned int i = 0; i < ic; i++) {
            const char *raw = ivar_getName(ivars[i]);
            NSString *name = raw ? [NSString stringWithUTF8String:raw] : nil;

            if (DPV372UsefulName(name))
                DPTrace(@"V3.7.2 %@ IVAR %@.%@ type=%s",
                        tag,
                        NSStringFromClass(cls),
                        name,
                        ivar_getTypeEncoding(ivars[i]) ?: "?");
        }

        if (ivars) free(ivars);

        cls = class_getSuperclass(cls);
        depth++;
    }

    DPTrace(@"========== V3.7.2 OBJECT %@ END ==========", tag);
}

static void DPV372ProbeCAContextSceneLayers(void) {
    if (!DPIsCarPlay() || gV372LayerProbeDone)
        return;

    gV372LayerProbeDone = YES;

    id fbsScene = DPV371FindDashboardFBSScene();

    DPTrace(@"========== V3.7.2 FBSCAContextSceneLayer PROBE ==========");
    DPTrace(@"V3.7.2 dashboardFBSScene=%@ class=%@",
            fbsScene ?: @"nil",
            fbsScene ? NSStringFromClass([fbsScene class]) : @"nil");

    if (!fbsScene) {
        DPTrace(@"V3.7.2 no dashboard FBSScene");
        DPTrace(@"========== V3.7.2 FBSCAContextSceneLayer PROBE END ==========");
        return;
    }

    id clientSettings = DPV371SafeValue(fbsScene, @"clientSettings");
    id layers = DPV371SafeValue(clientSettings, @"layers");

    NSArray *layerArray = DPV341ObjectsFromContainer(layers);

    DPTrace(@"V3.7.2 clientSettings=%@ class=%@",
            clientSettings ?: @"nil",
            clientSettings ? NSStringFromClass([clientSettings class]) : @"nil");

    DPTrace(@"V3.7.2 clientSettings.layers count=%lu",
            (unsigned long)layerArray.count);

    NSUInteger index = 0;

    for (id layer in layerArray) {
        NSString *className = NSStringFromClass([layer class]);

        DPTrace(@"V3.7.2 CLIENT_LAYER[%lu] class=%@ object=%@",
                (unsigned long)index,
                className,
                layer);

        if ([className containsString:@"FBSCAContextSceneLayer"] ||
            [className containsString:@"FBSceneLayer"]) {
            DPV372ProbeObject(
                layer,
                [NSString stringWithFormat:@"CLIENT_LAYER[%lu]",
                 (unsigned long)index]
            );
        }

        index++;
    }

    id sceneLayers = DPV371SafeValue(fbsScene, @"layers");
    NSArray *sceneLayerArray = DPV341ObjectsFromContainer(sceneLayers);

    DPTrace(@"V3.7.2 fbsScene.layers count=%lu",
            (unsigned long)sceneLayerArray.count);

    index = 0;

    for (id layer in sceneLayerArray) {
        DPTrace(@"V3.7.2 SCENE_LAYER[%lu] class=%@ object=%@",
                (unsigned long)index,
                NSStringFromClass([layer class]),
                layer);

        DPV372ProbeObject(
            layer,
            [NSString stringWithFormat:@"SCENE_LAYER[%lu]",
             (unsigned long)index]
        );

        index++;
    }

    NSArray<NSString *> *sceneKeys = @[
        @"identity",
        @"identityToken",
        @"identifier",
        @"display",
        @"fbsDisplay",
        @"contexts",
        @"layers",
        @"settings",
        @"clientSettings",
        @"uiClientSettings",
        @"hostProcess",
        @"clientProcess"
    ];

    for (NSString *key in sceneKeys) {
        id value = DPV371SafeValue(fbsScene, key);

        DPTrace(@"V3.7.2 FBSScene.%@ => %@ class=%@",
                key,
                value ?: @"nil",
                value ? NSStringFromClass([value class]) : @"nil");
    }

    DPV372ProbeObject(fbsScene, @"DASHBOARD_FBSSCENE");

    DPTrace(@"========== V3.7.2 FBSCAContextSceneLayer PROBE END ==========");
}


static CGRect DPV380RightPaneFrameForScene(id unusedScene) {
    (void)unusedScene;

    CGRect bounds = CGRectZero;

    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class])
            continue;

        NSString *pid = scene.session.persistentIdentifier ?: @"";

        if (![pid containsString:@"DBDashboard-Car"])
            continue;

        UIWindowScene *ws = (UIWindowScene *)scene;
        bounds = ws.coordinateSpace.bounds;
        break;
    }

    if (CGRectIsEmpty(bounds))
        return CGRectZero;

    CGFloat dock = 45.0;
    CGFloat mainX = CGRectGetMinX(bounds) + dock;
    CGFloat mainW = MAX(0.0, CGRectGetWidth(bounds) - dock);
    CGFloat half = floor(mainW * 0.5);

    return CGRectMake(mainX + half,
                      CGRectGetMinY(bounds),
                      mainW - half,
                      CGRectGetHeight(bounds));
}

static id DPV380FirstContextSceneLayer(id fbsScene) {
    if (!fbsScene)
        return nil;

    id contexts = DPV371SafeValue(fbsScene, @"contexts");
    NSArray *items = DPV341ObjectsFromContainer(contexts);

    for (id item in items) {
        NSString *cn = NSStringFromClass([item class]);

        if ([cn containsString:@"FBSCAContextSceneLayer"] ||
            [cn containsString:@"FBSceneLayer"]) {
            id cid = DPV371SafeValue(item, @"contextID");

            if (!cid)
                cid = DPV371SafeValue(item, @"contextId");

            if (cid)
                return item;
        }
    }

    return nil;
}

static id DPV380CreateCloneSceneLayer(id sourceLayer) {
    if (!sourceLayer)
        return nil;

    id contextIDValue = DPV371SafeValue(sourceLayer, @"contextID");

    if (!contextIDValue)
        contextIDValue = DPV371SafeValue(sourceLayer, @"contextId");

    if (![contextIDValue respondsToSelector:@selector(unsignedIntValue)])
        return nil;

    unsigned int contextID =
        (unsigned int)[contextIDValue unsignedIntValue];

    Class cls = NSClassFromString(@"FBSCAContextSceneLayer");

    if (!cls)
        return nil;

    SEL initCIDLevel =
        NSSelectorFromString(@"initWithCAContextID:level:");

    if ([cls instancesRespondToSelector:initCIDLevel]) {
        typedef id (*Fn)(id, SEL, unsigned int, double);

        id obj = [cls alloc];
        Fn fn = (Fn)[obj methodForSelector:initCIDLevel];

        if (fn) {
            @try {
                return fn(obj, initCIDLevel, contextID, 0.0);
            } @catch (__unused NSException *e) {
            }
        }
    }

    SEL initCID =
        NSSelectorFromString(@"initWithCAContextID:");

    if ([cls instancesRespondToSelector:initCID]) {
        typedef id (*Fn)(id, SEL, unsigned int);

        id obj = [cls alloc];
        Fn fn = (Fn)[obj methodForSelector:initCID];

        if (fn) {
            @try {
                return fn(obj, initCID, contextID);
            } @catch (__unused NSException *e) {
            }
        }
    }

    return nil;
}

static BOOL DPV380AttachLayerToScene(id fbsScene,
                                     id sceneLayer) {
    if (!fbsScene || !sceneLayer)
        return NO;

    SEL sel = NSSelectorFromString(@"attachLayer:");

    if (![fbsScene respondsToSelector:sel])
        return NO;

    typedef void (*Fn)(id, SEL, id);
    Fn fn = (Fn)[fbsScene methodForSelector:sel];

    if (!fn)
        return NO;

    @try {
        fn(fbsScene, sel, sceneLayer);
        return YES;
    } @catch (NSException *e) {
        DPTrace(@"V3.8 attachLayer exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
        return NO;
    }
}


static BOOL DPV3802DetachLayerFromScene(id fbsScene,
                                        id sceneLayer) {
    if (!fbsScene || !sceneLayer)
        return NO;

    SEL sel = NSSelectorFromString(@"detachLayer:");

    if (![fbsScene respondsToSelector:sel])
        return NO;

    typedef void (*Fn)(id, SEL, id);
    Fn fn = (Fn)[fbsScene methodForSelector:sel];

    if (!fn)
        return NO;

    @try {
        fn(fbsScene, sel, sceneLayer);
        return YES;
    } @catch (NSException *e) {
        DPTrace(@"V3.8.0.2 detachLayer exception=%@ reason=%@",
                e.name ?: @"?",
                e.reason ?: @"?");
        return NO;
    }
}

static void DPV3802LogSceneLayerState(id fbsScene,
                                      NSString *tag) {
    if (!fbsScene || !tag)
        return;

    id layers = DPV371SafeValue(fbsScene, @"layers");
    id contexts = DPV371SafeValue(fbsScene, @"contexts");

    DPTrace(@"V3.8.0.2 %@ layers=%@", tag, layers ?: @"nil");
    DPTrace(@"V3.8.0.2 %@ contexts=%@", tag, contexts ?: @"nil");
}

static BOOL DPV380ConfigureCloneFrame(id sceneLayer,
                                      CGRect frame) {
    if (!sceneLayer || CGRectIsEmpty(frame))
        return NO;

    NSArray<NSString *> *keys = @[
        @"frame",
        @"bounds"
    ];

    BOOL changed = NO;

    for (NSString *key in keys) {
        @try {
            NSValue *v =
                [NSValue valueWithCGRect:frame];

            [sceneLayer setValue:v forKey:key];

            DPTrace(@"V3.8 set %@=%@ on %@",
                    key,
                    NSStringFromCGRect(frame),
                    sceneLayer);

            changed = YES;
        } @catch (__unused NSException *e) {
        }
    }

    return changed;
}

static void DPV380RunCloneAttachExperiment(void) {
    if (!DPIsCarPlay() ||
        gV380CloneAttachDone)
        return;

    gV380CloneAttachDone = YES;

    id fbsScene = DPV371FindDashboardFBSScene();

    DPTrace(@"========== V3.8.0.2 CLONE LAYER ATTACH EXPERIMENT ==========");
    DPTrace(@"V3.8 dashboardFBSScene=%@ class=%@",
            fbsScene ?: @"nil",
            fbsScene ? NSStringFromClass([fbsScene class]) : @"nil");

    if (!fbsScene) {
        DPTrace(@"V3.8 FAIL no dashboard FBSScene");
        DPTrace(@"========== V3.8 CLONE LAYER ATTACH EXPERIMENT END ==========");
        return;
    }

    id sourceLayer =
        DPV380FirstContextSceneLayer(
            fbsScene
        );

    DPTrace(@"V3.8.0.2 sourceLayer=%@ class=%@ contextID=%@",
            sourceLayer ?: @"nil",
            sourceLayer ? NSStringFromClass([sourceLayer class]) : @"nil",
            sourceLayer ? (DPV371SafeValue(sourceLayer, @"contextID") ?: @"nil") : @"nil");

    if (!sourceLayer) {
        DPTrace(@"V3.8 FAIL no source FBSCAContextSceneLayer");
        DPTrace(@"========== V3.8 CLONE LAYER ATTACH EXPERIMENT END ==========");
        return;
    }

    id clone =
        DPV380CreateCloneSceneLayer(
            sourceLayer
        );

    DPTrace(@"V3.8.0.2 clone=%@ class=%@ contextID=%@",
            clone ?: @"nil",
            clone ? NSStringFromClass([clone class]) : @"nil",
            clone ? (DPV371SafeValue(clone, @"contextID") ?: @"nil") : @"nil");

    if (!clone) {
        DPTrace(@"V3.8 FAIL clone layer creation failed");
        DPTrace(@"========== V3.8 CLONE LAYER ATTACH EXPERIMENT END ==========");
        return;
    }

    CGRect rightPane =
        DPV380RightPaneFrameForScene(
            fbsScene
        );

    DPTrace(@"V3.8.0.2 targetPane=%@",
            NSStringFromCGRect(rightPane));

    DPV380ConfigureCloneFrame(
        clone,
        rightPane
    );

    BOOL attached =
        DPV380AttachLayerToScene(
            fbsScene,
            clone
        );

    DPTrace(@"V3.8.0.2 attachLayer returned=%d", attached);

    if (attached) {
        gV380CloneSceneLayer = clone;

        DPV3802LogSceneLayerState(
            fbsScene,
            @"AFTER_ATTACH"
        );

        DPTrace(@"========== V3.8.0.2 CLONE ATTACHED ==========");

        if (!gV3802RollbackScheduled) {
            gV3802RollbackScheduled = YES;

            __weak id weakScene = fbsScene;
            __weak id weakClone = clone;

            dispatch_after(
                dispatch_time(
                    DISPATCH_TIME_NOW,
                    1200 * NSEC_PER_MSEC
                ),
                dispatch_get_main_queue(),
                ^{
                    id strongScene = weakScene;
                    id strongClone = weakClone;

                    DPTrace(@"========== V3.8.0.2 ROLLBACK START ==========");

                    if (!strongScene || !strongClone) {
                        DPTrace(@"V3.8.0.2 rollback missing scene/clone");
                        DPTrace(@"========== V3.8.0.2 ROLLBACK END ==========");
                        return;
                    }

                    DPV3802LogSceneLayerState(
                        strongScene,
                        @"BEFORE_DETACH"
                    );

                    BOOL detached =
                        DPV3802DetachLayerFromScene(
                            strongScene,
                            strongClone
                        );

                    DPTrace(@"V3.8.0.2 detachLayer returned=%d",
                            detached);

                    DPV3802LogSceneLayerState(
                        strongScene,
                        @"AFTER_DETACH"
                    );

                    if (detached) {
                        gV380CloneSceneLayer = nil;
                        DPTrace(@"========== V3.8.0.2 ROLLBACK SUCCESS ==========");
                    }

                    DPTrace(@"========== V3.8.0.2 ROLLBACK END ==========");
                }
            );
        }
    }

    DPTrace(@"========== V3.8.0.2 CLONE LAYER ATTACH EXPERIMENT END ==========");
}

static void DPCarPlayRefresh(void) {
    if (!DPIsCarPlay())
        return;

    if (!gDividerWindow)
        DPCreateDivider();

    if (gDividerWindow && !gDragging)
        DPLayoutDivider();

    if (gDividerWindow &&
        !gV370CarPlaySceneHostMapDone) {
        static NSUInteger gV370DelayTicks = 0;
        gV370DelayTicks++;
        if (gV370DelayTicks >= 4)
            DPV370MapCarPlaySceneAndHosts();
    }

    if (gDividerWindow &&
        gV370CarPlaySceneHostMapDone &&
        !gV371ContextProbeDone) {
        static NSUInteger gV371DelayTicks = 0;
        gV371DelayTicks++;

        if (gV371DelayTicks >= 3)
            DPV371ProbeSceneContexts();
    }

    if (gDividerWindow &&
        gV371ContextProbeDone &&
        !gV372LayerProbeDone) {
        static NSUInteger gV372DelayTicks = 0;
        gV372DelayTicks++;

        if (gV372DelayTicks >= 3)
            DPV372ProbeCAContextSceneLayers();
    }

    if (gDividerWindow &&
        gV372LayerProbeDone &&
        !gV380CloneAttachDone) {
        static NSUInteger gV380DelayTicks = 0;
        gV380DelayTicks++;

        if (gV380DelayTicks >= 4)
            DPV380RunCloneAttachExperiment();
    }

    if (gDividerWindow &&
        !gV392CarIdentityPublished) {
        DPV392PublishCarIdentityFromCarPlay();

        if (!gV392CarIdentityPublished) {
            gV393BridgeRequestDeferredForIdentity = YES;
            DPTrace(@"V3.9.3 AppBridge request deferred: Car identity not published yet");
            return;
        }

        DPTrace(@"V3.9.3 Car identity published before AppBridge request");
    }

    if (gDividerWindow &&
        !gCarPlayBridgeRequestSent) {
        gCarPlayBridgeRequestSent = YES;

        DPTrace(@"APPBRIDGE REQUEST posting bundle=com.apple.Maps");

        CFNotificationCenterPostNotification(
            CFNotificationCenterGetDarwinNotifyCenter(),
            kBridgeRequest,
            NULL,
            NULL,
            YES
        );
    }

    dispatch_after(
        dispatch_time(
            DISPATCH_TIME_NOW,
            1000 * NSEC_PER_MSEC
        ),
        dispatch_get_main_queue(),
        ^{
            DPCarPlayRefresh();
        }
    );
}

%ctor {
    @autoreleasepool {
        if (!DPIsCarPlay() &&
            !DPIsSpringBoard())
            return;

        DPTrace(@"CTOR V3.9.11 bundle=%@ process=%@",
                NSBundle.mainBundle.bundleIdentifier ?: @"nil",
                NSProcessInfo.processInfo.processName ?: @"nil");

        DPRegisterBridgeNotifications();

        dispatch_async(
            dispatch_get_main_queue(),
            ^{
                if (DPIsSpringBoard()) {
                    DPSpringBoardTargetMap();
                    DPV33InstallActivationHooks();

                    dispatch_after(
                        dispatch_time(DISPATCH_TIME_NOW,
                                      2500 * NSEC_PER_MSEC),
                        dispatch_get_main_queue(),
                        ^{
                            DPV36ProbeCarPlayRuntimeOnce();

                            for (NSUInteger retryIndex = 0;
                                 retryIndex < 15;
                                 retryIndex++) {
                                dispatch_after(
                                    dispatch_time(DISPATCH_TIME_NOW,
                                                  (int64_t)(retryIndex * 2000) * NSEC_PER_MSEC),
                                    dispatch_get_main_queue(),
                                    ^{
                                        if (gV35CarPlayDisplayIdentity &&
                                            gV35CarPlayDisplayConfiguration)
                                            return;

                                        gV361SingletonProbeDone = NO;
                                        DPV361ProbeCarDisplaySingletons();
                                    }
                                );
                            }

                            dispatch_after(
                                dispatch_time(DISPATCH_TIME_NOW,
                                              2000 * NSEC_PER_MSEC),
                                dispatch_get_main_queue(),
                                ^{
                                    DPV361ProbeCarDisplaySingletons();
                                }
                            );
                        }
                    );
                } else if (DPIsCarPlay() &&
                           !gRefreshRunning) {
                    gRefreshRunning = YES;
                    DPCarPlayRefresh();
                }
            }
        );
    }
}
