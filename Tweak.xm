// DuoPhone V6.2.4 — temporary native-layout lifecycle diagnostic.
// No view reparenting, divider, activation suppression, or completion substitution.
// Collect actual private method signatures before attempting dual foreground scenes.
// Replace only Tweak.xm; package metadata is intentionally unchanged.

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <stdarg.h>
#import <stdlib.h>

static NSString *const kTracePath = @"/var/mobile/DuoPhoneV6Trace.txt";
static NSMutableSet<NSString *> *gDumpedClasses;
static NSMapTable *gObservedHosts;
static NSMapTable *gObservedScenes;

static void DPLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"[%@:%d] V6.2.4 %@\n",
        NSProcessInfo.processInfo.processName, getpid(), message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    @synchronized (kTracePath) {
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:kTracePath];
        if (!handle) { [data writeToFile:kTracePath atomically:YES]; return; }
        @try { [handle seekToEndOfFile]; [handle writeData:data]; }
        @catch (__unused NSException *exception) {}
        @finally { [handle closeFile]; }
    }
}

static id DPValue(id object, NSString *key) {
    @try { return [object valueForKey:key]; }
    @catch (__unused NSException *exception) { return nil; }
}

static BOOL DPInteresting(NSString *name) {
    NSString *lower = name.lowercaseString;
    for (NSString *word in @[@"scene", @"activ", @"foreground", @"background",
                            @"setting", @"present", @"visible", @"appear",
                            @"assert", @"suspend", @"resume", @"display",
                            @"frame", @"bound", @"orient", @"content", @"context"]) {
        if ([lower containsString:word]) return YES;
    }
    return NO;
}

static void DPDumpClass(Class cls) {
    // Up to three class levels; UIKit/NSObject APIs are not the missing evidence.
    for (NSUInteger level = 0; cls && level < 3; level++, cls = class_getSuperclass(cls)) {
        if (cls == UIViewController.class || cls == UIView.class || cls == NSObject.class) break;
        NSString *name = NSStringFromClass(cls);
        if ([gDumpedClasses containsObject:name]) continue;
        [gDumpedClasses addObject:name];
        DPLog(@"API CLASS %@", name);
        unsigned int count = 0;
        Method *methods = class_copyMethodList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *selector = NSStringFromSelector(method_getName(methods[i]));
            if (DPInteresting(selector))
                DPLog(@"API METHOD %@ %@ types=%s", name, selector,
                      method_getTypeEncoding(methods[i]) ?: "?");
        }
        free(methods);
        objc_property_t *properties = class_copyPropertyList(cls, &count);
        for (unsigned int i = 0; i < count; i++) {
            NSString *property = @(property_getName(properties[i]));
            if (DPInteresting(property))
                DPLog(@"API PROPERTY %@ %@ attributes=%s", name, property,
                      property_getAttributes(properties[i]) ?: "?");
        }
        free(properties);
    }
}

static void DPSnapshot(id controller, NSString *event) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DPSnapshot(controller, event); });
        return;
    }
    id sceneID = DPValue(controller, @"sceneID");
    DPDumpClass([controller class]);
    id scene = [gObservedScenes objectForKey:controller];
    if (scene) DPDumpClass([scene class]);
    // viewIfLoaded avoids creating a view merely to inspect it.
    UIView *view = [controller isKindOfClass:UIViewController.class]
        ? ((UIViewController *)controller).viewIfLoaded : nil;
    // Do not call sceneHostView: the prior log showed changing presentation
    // wrappers around the same layer host. A getter may create a new wrapper.
    id hostObject = [gObservedHosts objectForKey:controller];
    UIView *host = [hostObject isKindOfClass:UIView.class] ? hostObject : nil;
    DPLog(@"EVENT %@ id=%@ controller=%p sceneClass=%@ viewLoaded=%d",
          event, sceneID, (__bridge void *)controller, NSStringFromClass([scene class]), view != nil);
    DPLog(@"NATIVE HOST id=%@ host=%p parent=%@ window=%p hidden=%d alpha=%.2f frame=%@ children=%lu",
          sceneID, (__bridge void *)host, NSStringFromClass(host.superview.class),
          (__bridge void *)host.window, host.hidden, host.alpha,
          NSStringFromCGRect(host.frame), (unsigned long)host.subviews.count);
    DPLog(@"NATIVE VIEW id=%@ parent=%@ window=%p hidden=%d frame=%@",
          sceneID, NSStringFromClass(view.superview.class), (__bridge void *)view.window,
          view.hidden, NSStringFromCGRect(view.frame));
}

static void DPAfterTransition(id controller, NSString *event) {
    __weak id weakController = controller;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        id current = weakController;
        if (current) DPSnapshot(current, event);
    });
}

static void DPActivationArgument(id controller, id settings, NSString *event) {
    // Observe exactly the object supplied by CarPlay; do not replay settings yet.
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DPActivationArgument(controller, settings, event); });
        return;
    }
    DPLog(@"ACTIVATION %@ id=%@ settingsClass=%@ copyable=%d",
          event, DPValue(controller, @"sceneID"), NSStringFromClass([settings class]),
          [settings conformsToProtocol:@protocol(NSCopying)]);
    if (settings) DPDumpClass([settings class]);
    if ([settings isKindOfClass:NSDictionary.class]) {
        NSDictionary *dictionary = settings;
        // Record keys and value classes, not application content.
        for (id key in dictionary) {
            DPLog(@"ACTIVATION KEY %@ valueClass=%@", key,
                  NSStringFromClass([dictionary[key] class]));
        }
    }
    DPAfterTransition(controller, [event stringByAppendingString:@" settled +1s"]);
}

static void DPPresentationResult(id controller, id identifier, id result) {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ DPPresentationResult(controller, identifier, result); });
        return;
    }
    UIView *view = [result isKindOfClass:UIView.class] ? result : nil;
    DPLog(@"PRESENTATION id=%@ identifier=%@ resultClass=%@ view=%p window=%p children=%lu",
          DPValue(controller, @"sceneID"), identifier, NSStringFromClass([result class]),
          (__bridge void *)view, (__bridge void *)view.window, (unsigned long)view.subviews.count);
    if (result) DPDumpClass([result class]);
    __weak UIView *weakView = view;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        UIView *current = weakView;
        DPLog(@"PRESENTATION SETTLED identifier=%@ view=%p parent=%@ window=%p alpha=%.2f children=%lu",
              identifier, (__bridge void *)current, NSStringFromClass(current.superview.class),
              (__bridge void *)current.window, current.alpha, (unsigned long)current.subviews.count);
    });
}

%hook DBApplicationSceneViewController

- (void)activateSceneWithSettings:(id)settings completion:(id)completion {
    DPActivationArgument(self, settings, @"activate");
    %orig;
}

- (void)foregroundSceneWithSettings:(id)settings completion:(id)completion {
    DPActivationArgument(self, settings, @"foreground");
    %orig;
}

- (id)presentationViewWithIdentifier:(id)identifier {
    id result = %orig;
    DPPresentationResult(self, identifier, result);
    return result;
}

- (void)invalidatePresentationViewForIdentifier:(id)identifier {
    DPLog(@"INVALIDATE PRESENTATION id=%@ identifier=%@", DPValue(self, @"sceneID"), identifier);
    %orig;
}

- (void)setScene:(id)scene {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (scene) [gObservedScenes setObject:scene forKey:self];
        else [gObservedScenes removeObjectForKey:self];
        DPSnapshot(self, @"setScene after");
    });
}

- (void)setSceneHostView:(id)view {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (view) [gObservedHosts setObject:view forKey:self];
        else [gObservedHosts removeObjectForKey:self];
        DPSnapshot(self, @"setSceneHostView after");
        DPAfterTransition(self, @"host settled +1s");
    });
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    DPSnapshot(self, @"viewDidAppear");
}

- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    DPSnapshot(self, @"viewDidDisappear");
}

- (void)backgroundSceneWithCompletion:(id)completion {
    DPSnapshot(self, @"background BEFORE");
    %orig;
    DPAfterTransition(self, @"background settled +1s");
}

- (void)deactivateSceneWithReasonMask:(NSUInteger)mask {
    DPSnapshot(self, [NSString stringWithFormat:@"deactivate BEFORE mask=%lu", (unsigned long)mask]);
    %orig;
    DPAfterTransition(self, [NSString stringWithFormat:@"deactivate settled mask=%lu", (unsigned long)mask]);
}

%end

%ctor {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayApp"]) return;
        gDumpedClasses = [NSMutableSet set];
        gObservedHosts = [NSMapTable weakToWeakObjectsMapTable];
        gObservedScenes = [NSMapTable weakToWeakObjectsMapTable];
        dispatch_async(dispatch_get_main_queue(), ^{
            DPLog(@"CTOR NATIVE DIAGNOSTIC — split disabled, original lifecycle preserved");
            DPDumpClass(NSClassFromString(@"DBApplicationSceneViewController"));
        });
    }
}
