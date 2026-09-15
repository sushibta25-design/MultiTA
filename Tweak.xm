// DuoPhone V6.36-skip-foreground-recreate — based on V6.34 clean-gap movable split.
// V6.35: redesigned four controls + auto-hide after 1s; any CarPlay touch reveals them.
// Divider remains invisible and movable; pane geometry/resizing logic is unchanged.
// Every app requests its pane width and full content height.
// Native template layout still requires device validation.
// Saves/restores only the scene frame. Keeps picker, floating exit and app probes.
// Runtime guards verify method signatures. Device-side redraw/touch still needs testing.
// Inspect RESIZE REQUEST / OBSERVED / RESTORE in DuoPhoneV6Trace.txt.
// Replace only Tweak.xm; existing package metadata is unchanged.
// Observed device APIs: foregroundSceneWithSettings:completion:,
// presentationViewWithIdentifier:, invalidatePresentationViewForIdentifier:.
// Never reuse native animation identifiers or suppress native lifecycle callbacks.
#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>
#import <unistd.h>
#import <stdarg.h>
#import <math.h>
#import <string.h>

static NSString *const DPTrace = @"/var/mobile/DuoPhoneV6Trace.txt";
static void DPLog(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSData *data = [[NSString stringWithFormat:@"[CarPlay:%d] V6.36-skip-foreground-recreate %@\n", getpid(), message]
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
static NSString *DPCategoryToken(NSString *sid) {
    if (![sid isKindOfClass:NSString.class]) return nil;
    NSArray<NSString *> *parts = [sid componentsSeparatedByString:@":"];
    if (parts.count < 2 || ![parts[0] hasPrefix:@"Car["] || ![parts[0] hasSuffix:@"]"]) return nil;
    return [parts[0] substringWithRange:NSMakeRange(4, parts[0].length - 5)];
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
@property(nonatomic,copy) NSString *category;
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic,copy) NSDictionary *settings;
@property(nonatomic,copy) NSString *presentationID;
@property(nonatomic,strong) UIView *presentation;
@property(nonatomic) BOOL nativeBackgrounded;
@property(nonatomic) BOOL restoreBackground;
@property(nonatomic) BOOL valid;
@property(nonatomic,strong) id resizeScene;
@property(nonatomic) CGRect originalFrame;
@property(nonatomic) CGSize requestedSize;
@property(nonatomic) CGSize submittedSize;
@property(nonatomic) BOOL resizeQueued;
@property(nonatomic) BOOL geometryChanged;
@property(nonatomic) NSInteger resizeState; // 0 untested, 1 setter accepted, -1 unsupported
@property(nonatomic) NSUInteger resizeAttempts;
@property(nonatomic) BOOL clientSafeAreaCaptured;
@property(nonatomic) UIEdgeInsets originalClientSafeArea;
@property(nonatomic,copy) NSString *clientSafeAreaKey;
@property(nonatomic) NSUInteger v636BlankChecks;
@property(nonatomic) BOOL v636RecoveryAttempted;
@end
@implementation DPRecord
@end

static NSMutableDictionary<NSString *, DPRecord *> *gRecords;
static NSMutableArray<NSString *> *gOrder;
static NSArray<DPRecord *> *gPair;
@class DPControls;
static DPControls *gControls;
static UIWindow *gButtonWindow, *gSplitWindow, *gPickerWindow;
static UIView *gLeftPane, *gRightPane, *gDivider, *gDockOverlay;
static UIButton *gButton;
static NSUInteger gControlsHideToken = 0;
static NSMutableArray<NSString *> *gPickerBundles;   // snapshot khi mở picker
static NSString *gPickerFirstPick = nil;             // app đã chọn làm bên trái
static UILabel *gStatus;
static __weak UIWindowScene *gSession;
static BOOL gRunning, gOwnCall;
static NSUInteger gGeneration;
static NSUInteger gSessionEpoch;
static CGSize gNativeSize;
static BOOL gAppProbeEnabled = NO;
static void DPStop(NSString *reason);
static void DPLayout(void);
static void DPRefreshButton(void);
static void DPInspect(NSUInteger generation);
static void DPDumpConnectedScenes(NSString *tag);
static void DPProbeTemplateSurface(DPRecord *record);
static void DPDumpDockCandidates(void);
static void DPTryPokeSceneUI(DPRecord *record);
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

// V6.36: chụp nhanh view thành ảnh nhỏ, kiểm tra có phải toàn 1 màu (thường
// là đen — chưa có nội dung thật) hay không. drawViewHierarchyInRect: dùng
// được cả với nội dung cross-process (cùng cơ chế App Switcher chụp preview
// app khác), nên áp dụng được cho presentation view remote-hosted ở đây.
static BOOL DPV636SnapshotAppearsBlank(UIView *view) {
    if (!view || view.bounds.size.width < 2 || view.bounds.size.height < 2) return YES;

    UIGraphicsImageRendererFormat *format = [UIGraphicsImageRendererFormat preferredFormat];
    format.opaque = YES;
    format.scale = 1.0;
    CGSize thumbSize = CGSizeMake(16, 16);
    UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:thumbSize format:format];

    UIImage *snapshot = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        CGContextRef cg = ctx.CGContext;
        CGSize src = view.bounds.size;
        CGContextScaleCTM(cg, thumbSize.width / MAX(src.width, 1), thumbSize.height / MAX(src.height, 1));
        [view drawViewHierarchyInRect:view.bounds afterScreenUpdates:NO];
    }];

    CGImageRef cgImage = snapshot.CGImage;
    if (!cgImage) return YES;

    CFDataRef rawData = CGDataProviderCopyData(CGImageGetDataProvider(cgImage));
    if (!rawData) return YES;
    const unsigned char *bytes = CFDataGetBytePtr(rawData);
    NSUInteger length = (NSUInteger)CFDataGetLength(rawData);
    NSUInteger bytesPerPixel = CGImageGetBitsPerPixel(cgImage) / 8;

    BOOL uniform = YES;
    if (bytesPerPixel >= 3 && length >= bytesPerPixel) {
        unsigned char r0 = bytes[0], g0 = bytes[1], b0 = bytes[2];
        for (NSUInteger off = 0; off + bytesPerPixel <= length; off += bytesPerPixel) {
            int dr = (int)bytes[off] - r0, dg = (int)bytes[off + 1] - g0, db = (int)bytes[off + 2] - b0;
            if (abs(dr) > 6 || abs(dg) > 6 || abs(db) > 6) { uniform = NO; break; }
        }
    }
    CFRelease(rawData);
    return uniform;
}

// V6.36: nếu presentation của 1 record vẫn trống sau vài giây, tạo lại
// presentation MỚI (invalidate cái cũ + xin cái mới với identifier khác) —
// đây là cặp API "làm mới nội dung" tự nhiên nhất trong bản này (không có
// bước resize từ xa riêng để gửi lại như nhánh V6.79, vì bản này chỉ
// transform/scale cục bộ, không đụng geometry thật của app nguồn).
static void DPV636RecreatePresentationIfBlank(DPRecord *record, UIView *pane, NSUInteger generation) {
    if (!gRunning || generation != gGeneration || !record.valid || !record.presentation) return;
    if (record.v636RecoveryAttempted) return;

    BOOL blank = DPV636SnapshotAppearsBlank(record.presentation);
    if (!blank) { DPLog(@"V636 CONTENT-CHECK bundle=%@ blank=0 (ổn)", record.bundle); return; }

    record.v636BlankChecks++;
    DPLog(@"V636 CONTENT-CHECK bundle=%@ blank=1 lần thứ=%lu", record.bundle, (unsigned long)record.v636BlankChecks);
    if (record.v636BlankChecks < 3) return; // cho vài lần kiểm tra trước khi cứu hộ, tránh phản ứng quá sớm

    record.v636RecoveryAttempted = YES;
    DPLog(@"V636 RECREATE bundle=%@ — nội dung vẫn trống, tạo lại presentation mới", record.bundle);

    BOOL previousOwnCall = gOwnCall;
    gOwnCall = YES;
    @try {
        SEL invalidate = NSSelectorFromString(@"invalidatePresentationViewForIdentifier:");
        if (record.presentationID && [record.controller respondsToSelector:invalidate])
            ((void(*)(id,SEL,id))objc_msgSend)(record.controller, invalidate, record.presentationID);

        [record.presentation removeFromSuperview];
        record.presentation = nil;

        NSString *newID = [record.presentationID stringByAppendingString:@".r"];
        SEL create = NSSelectorFromString(@"presentationViewWithIdentifier:");
        id result = [record.controller respondsToSelector:create]
            ? ((id(*)(id,SEL,id))objc_msgSend)(record.controller, create, newID)
            : nil;

        if ([result isKindOfClass:UIView.class] && !((UIView *)result).superview) {
            record.presentationID = newID;
            record.presentation = result;
            [pane addSubview:result];
            DPLayout();
            DPLog(@"V636 RECREATE bundle=%@ OK identifier=%@", record.bundle, newID);
        } else {
            DPLog(@"V636 RECREATE bundle=%@ FAIL result=%@", record.bundle, result ?: @"nil");
        }
    } @catch (NSException *e) {
        DPLog(@"V636 RECREATE bundle=%@ EXCEPTION %@ %@", record.bundle, e.name, e.reason);
    }
    gOwnCall = previousOwnCall;
}

static NSUInteger DPLayers(UIView *view, NSUInteger depth) {
    if (!view || depth > 12) return 0;
    NSUInteger count = [NSStringFromClass(view.class) containsString:@"_UISceneLayerHostContainerView"] ? 1 : 0;
    for (UIView *child in view.subviews) count += DPLayers(child, depth + 1);
    return count;
}
static BOOL DPReadFrame(id scene, CGRect *frame) {
    id value = DPValue(DPValue(scene, @"settings"), @"frame");
    if (![value isKindOfClass:NSValue.class] || strcmp([value objCType], @encode(CGRect))) return NO;
    *frame = [value CGRectValue];
    return isfinite(frame->size.width) && isfinite(frame->size.height) &&
           frame->size.width > 0 && frame->size.height > 0;
}
static BOOL DPFrameSetter(id settings, CGRect frame) {
    SEL setter = NSSelectorFromString(@"setFrame:");
    NSMethodSignature *sig = [settings methodSignatureForSelector:setter];
    if (!sig || sig.numberOfArguments != 3 || strcmp(sig.methodReturnType, @encode(void)) ||
        strcmp([sig getArgumentTypeAtIndex:2], @encode(CGRect))) return NO;
    ((void(*)(id,SEL,CGRect))objc_msgSend)(settings, setter, frame);
    return YES;
}
static BOOL DPEdgeInsetsGetter(id obj, NSString *key, UIEdgeInsets *outInsets) {
    if (!obj || !key.length || !outInsets) return NO;
    SEL getter = NSSelectorFromString(key);
    NSMethodSignature *sig = [obj methodSignatureForSelector:getter];
    if (sig && sig.numberOfArguments == 2 && !strcmp(sig.methodReturnType, @encode(UIEdgeInsets))) {
        *outInsets = ((UIEdgeInsets(*)(id,SEL))objc_msgSend)(obj, getter);
        return YES;
    }
    @try {
        id value = [obj valueForKey:key];
        if ([value isKindOfClass:NSValue.class] && !strcmp([value objCType], @encode(UIEdgeInsets))) {
            [value getValue:outInsets];
            return YES;
        }
    } @catch (__unused NSException *e) {}
    return NO;
}

static BOOL DPEdgeInsetsSetter(id obj, NSString *key, UIEdgeInsets insets) {
    if (!obj || !key.length) return NO;
    NSString *setterName = [NSString stringWithFormat:@"set%@%@:",
                            [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
    SEL setter = NSSelectorFromString(setterName);
    NSMethodSignature *sig = [obj methodSignatureForSelector:setter];
    if (sig && sig.numberOfArguments == 3 && !strcmp(sig.methodReturnType, @encode(void)) &&
        !strcmp([sig getArgumentTypeAtIndex:2], @encode(UIEdgeInsets))) {
        ((void(*)(id,SEL,UIEdgeInsets))objc_msgSend)(obj, setter, insets);
        return YES;
    }
    @try {
        [obj setValue:[NSValue valueWithUIEdgeInsets:insets] forKey:key];
        return YES;
    } @catch (__unused NSException *e) {}
    return NO;
}

static void DPClientSafeAreaPatch(id mutableSettings, DPRecord *record, BOOL split) {
    if (!mutableSettings || !record) return;
    NSArray<NSString *> *keys = record.clientSafeAreaKey.length ?
        @[record.clientSafeAreaKey] : @[@"safeAreaInsetsPortrait", @"safeAreaInsets"];
    BOOL touched = NO;
    for (NSString *key in keys) {
        UIEdgeInsets current = UIEdgeInsetsZero;
        if (!DPEdgeInsetsGetter(mutableSettings, key, &current)) continue;
        if (!record.clientSafeAreaCaptured) {
            record.clientSafeAreaCaptured = YES;
            record.originalClientSafeArea = current;
            record.clientSafeAreaKey = key;
            DPLog(@"CLIENT-SAFEAREA CAPTURE bundle=%@ key=%@ value=%@ settingsClass=%@",
                  record.bundle, key, NSStringFromUIEdgeInsets(current), NSStringFromClass([mutableSettings class]));
        }
        UIEdgeInsets desired = split ? current : record.originalClientSafeArea;
        if (split) {
            desired.left = 0.0;
            desired.right = 0.0;
            // Google Maps still anchors the navigation camera slightly to the right
            // after the physical CarPlay sidebar inset is reclaimed.  Compensate the
            // client viewport only (not the host pane) so the vehicle target moves
            // back toward the visual center.  Keep this app-specific and modest.
            if ([record.bundle isEqualToString:@"com.google.Maps"]) desired.right = 36.0;
        }
        if (DPEdgeInsetsSetter(mutableSettings, key, desired)) {
            UIEdgeInsets verify = UIEdgeInsetsZero;
            BOOL readable = DPEdgeInsetsGetter(mutableSettings, key, &verify);
            DPLog(@"CLIENT-SAFEAREA %@ bundle=%@ key=%@ before=%@ desired=%@ after=%@ readable=%d",
                  split ? @"PATCH" : @"RESTORE", record.bundle, key,
                  NSStringFromUIEdgeInsets(current), NSStringFromUIEdgeInsets(desired),
                  readable ? NSStringFromUIEdgeInsets(verify) : @"?", readable);
            touched = YES;
            break;
        }
    }
    if (!touched && split) {
        static NSMutableSet *logged; static dispatch_once_t once; dispatch_once(&once, ^{ logged=[NSMutableSet set]; });
        NSString *cls = NSStringFromClass([mutableSettings class]);
        if (![logged containsObject:cls]) {
            [logged addObject:cls];
            DPLog(@"CLIENT-SAFEAREA UNSUPPORTED settingsClass=%@ bundle=%@", cls, record.bundle);
            unsigned int count = 0; Method *methods = class_copyMethodList([mutableSettings class], &count);
            for (unsigned int i=0;i<count;i++) {
                NSString *name = NSStringFromSelector(method_getName(methods[i]));
                NSString *lower = name.lowercaseString;
                if ([lower containsString:@"safe"] || [lower containsString:@"inset"]) {
                    DPLog(@"CLIENT-SAFEAREA METHOD class=%@ selector=%@ types=%s", cls, name, method_getTypeEncoding(methods[i]));
                }
            }
            if (methods) free(methods);
        }
    }
}

static BOOL DPHasBlockUpdater(id scene, NSString *selectorName) {
    SEL sel = NSSelectorFromString(selectorName);
    NSMethodSignature *sig = [scene methodSignatureForSelector:sel];
    return sig && sig.numberOfArguments == 3 && !strcmp(sig.methodReturnType, @encode(void)) &&
           !strcmp([sig getArgumentTypeAtIndex:2], "@?");
}
static BOOL DPHasFrameUpdater(id scene) {
    return DPHasBlockUpdater(scene, @"updateUISettingsWithBlock:") ||
           DPHasBlockUpdater(scene, @"updateSettingsWithBlock:");
}

static NSString *DPObjSummary(id obj) {
    if (!obj) return @"(nil)";
    NSString *desc = nil;
    @try { desc = [obj description]; } @catch (__unused NSException *e) {}
    if (!desc) desc = @"?";
    if (desc.length > 500) desc = [[desc substringToIndex:500] stringByAppendingString:@"…"];
    return [NSString stringWithFormat:@"<%@:%p> %@", NSStringFromClass([obj class]), (__bridge void *)obj, desc];
}

// V6.25: map một FBScene / presentation object về record bằng chính scene
// identifier/description, thay vì dựa vào controller đang hook. Cách này tránh
// cross-fire giữa Maps và YouTube Music đã thấy trong log V6.24.
static DPRecord *DPRecordForSceneObject(id scene) {
    if (!scene || !gRunning || gPair.count != 2) return nil;
    NSString *desc = nil;
    @try { desc = [scene description]; } @catch (__unused NSException *e) {}
    if (!desc) desc = @"";
    for (DPRecord *record in gPair) {
        if (record.valid && record.bundle.length && [desc containsString:record.bundle]) return record;
    }
    for (NSString *key in @[@"identifier", @"sceneID", @"workspaceIdentifier", @"persistentIdentifier"]) {
        id value = DPValue(scene, key);
        if (![value isKindOfClass:NSString.class]) continue;
        for (DPRecord *record in gPair) {
            if (record.valid && [value containsString:record.bundle]) return record;
        }
    }
    return nil;
}
static DPRecord *DPRecordForPresentation(id presentation) {
    if (!presentation || !gRunning || gPair.count != 2) return nil;
    for (DPRecord *record in gPair) if (record.valid && record.presentation == presentation) return record;
    return nil;
}
static void DPDumpClientObject(DPRecord *record, NSString *tag, id object) {
    if (!record || !object) return;
    DPLog(@"CLIENT-OBJECT bundle=%@ tag=%@ class=%@ value=%@",
          record.bundle, tag, NSStringFromClass([object class]), DPObjSummary(object));
    for (NSString *key in @[@"frame", @"bounds", @"geometry", @"settings", @"sceneSettings",
                             @"clientSettings", @"displayConfiguration", @"interfaceOrientation",
                             @"safeAreaInsets", @"transitionContext"]) {
        id v = DPValue(object, key);
        if (v) DPLog(@"CLIENT-OBJECT-KVC bundle=%@ tag=%@ key=%@ value=%@",
                     record.bundle, tag, key, DPObjSummary(v));
    }
}
static void DPDumpSceneUpdateState(DPRecord *record, NSString *tag) {
    if (!record.controller) return;
    @try {
        id scene = DPValue(record.controller, @"scene");
        id current = nil;
        SEL curSel = NSSelectorFromString(@"currentSceneUpdate");
        if ([record.controller respondsToSelector:curSel])
            current = ((id(*)(id,SEL))objc_msgSend)(record.controller, curSel);
        id settings = DPValue(scene, @"settings");
        id frameObj = DPValue(settings, @"frame");
        DPLog(@"SCENE-UPDATE-STATE bundle=%@ tag=%@ scene=%@ settingsClass=%@ frame=%@ current=%@",
              record.bundle, tag, NSStringFromClass([scene class]), NSStringFromClass([settings class]),
              frameObj, DPObjSummary(current));
        if (current) {
            for (NSString *key in @[@"frame", @"bounds", @"geometry", @"settings", @"context", @"sceneSettings", @"clientSettings", @"transitionContext"]) {
                id v = DPValue(current, key);
                if (v) DPLog(@"SCENE-UPDATE-KVC bundle=%@ tag=%@ key=%@ value=%@", record.bundle, tag, key, DPObjSummary(v));
            }
        }
    } @catch (NSException *e) { DPLog(@"SCENE-UPDATE-STATE ERROR %@ %@", record.bundle, e.name); }
}
static void DPTryPropagateSceneUpdate(DPRecord *record, NSString *tag) {
    if (!record.controller || !record.valid) return;
    DPDumpSceneUpdateState(record, [tag stringByAppendingString:@"-before"]);
    @try {
        SEL updateUI = NSSelectorFromString(@"_updateSceneUI");
        if ([record.controller respondsToSelector:updateUI]) {
            ((void(*)(id,SEL))objc_msgSend)(record.controller, updateUI);
            DPLog(@"SCENE-UPDATE-POKE bundle=%@ tag=%@ selector=_updateSceneUI", record.bundle, tag);
        } else {
            DPLog(@"SCENE-UPDATE-POKE bundle=%@ tag=%@ selector=_updateSceneUI unsupported", record.bundle, tag);
        }
    } @catch (NSException *e) { DPLog(@"SCENE-UPDATE-POKE ERROR %@ %@", record.bundle, e.name); }
    DPDumpSceneUpdateState(record, [tag stringByAppendingString:@"-after"]);
}
static void DPRestoreFrame(DPRecord *record) {
    if (!record.geometryChanged || !record.valid || !record.resizeScene) return;
    id scene = record.resizeScene;
    CGRect frame = record.originalFrame;
    NSUInteger generation = gGeneration;
    if (DPValue(record.controller, @"scene") != scene || !DPHasFrameUpdater(scene)) return;
    NSString *updaterName = DPHasBlockUpdater(scene, @"updateUISettingsWithBlock:") ?
                            @"updateUISettingsWithBlock:" : @"updateSettingsWithBlock:";
    void (^change)(id) = ^(id mutableSettings) {
        if (generation != gGeneration) return;
        @try {
            BOOL restored = DPFrameSetter(mutableSettings, frame);
            DPClientSafeAreaPatch(mutableSettings, record, NO);
            DPLog(@"RESIZE RESTORE bundle=%@ path=%@ settingsClass=%@ setter=%d frame=%@",
                  record.bundle, updaterName, NSStringFromClass([mutableSettings class]), restored, NSStringFromCGRect(frame));
        } @catch (NSException *e) { DPLog(@"RESIZE RESTORE ERROR %@ %@", record.bundle, e.name); }
    };
    @try {
        ((void(*)(id,SEL,id))objc_msgSend)(scene, NSSelectorFromString(updaterName), change);
    } @catch (NSException *e) { DPLog(@"RESIZE RESTORE ERROR %@ %@", record.bundle, e.name); }
}
static void DPQueueResize(DPRecord *record, CGSize size) {
    if (!record.presentation || !record.valid || record.resizeState < 0) return;
    record.requestedSize = size;
    if (record.resizeQueued || CGSizeEqualToSize(size, record.submittedSize)) return;
    record.resizeQueued = YES;
    NSUInteger generation = gGeneration;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        if (!gRunning || generation != gGeneration || !record.valid) return;
        record.resizeQueued = NO;
        if (record.resizeState == 0 && ++record.resizeAttempts > 3) {
            record.resizeState = -1;
            DPLog(@"RESIZE NO CALLBACK bundle=%@", record.bundle);
            return;
        }
        id scene = DPValue(record.controller, @"scene");
        if (!record.resizeScene) {
            CGRect original;
            if (!scene || !DPHasFrameUpdater(scene) || !DPReadFrame(scene, &original)) {
                record.resizeState = -1;
                DPLog(@"RESIZE UNSUPPORTED bundle=%@ sceneClass=%@", record.bundle, NSStringFromClass([scene class]));
                DPLayout(); return;
            }
            record.resizeScene = scene; record.originalFrame = original;
        }
        if (record.resizeScene != scene) { DPStop(@"resize scene replaced"); return; }
        CGSize target = record.requestedSize;
        CGRect frame = (CGRect){CGPointZero, target};

        // V6.22: ưu tiên UI settings. V6.20 đã chứng minh updateSettingsWithBlock:
        // thay được scene.settings.frame nhưng remote app KHÔNG relayout. Scene này
        // còn expose updateUISettingsWithBlock:, đây mới là đường có khả năng tạo
        // geometry diff gửi tới client UIWindowScene.
        NSString *updaterName = DPHasBlockUpdater(scene, @"updateUISettingsWithBlock:") ?
                                @"updateUISettingsWithBlock:" : @"updateSettingsWithBlock:";
        __block BOOL setterWorked = NO;
        void (^change)(id) = ^(id mutableSettings) {
            if (![NSThread isMainThread]) { DPLog(@"RESIZE CALLBACK OFF MAIN — skipped"); return; }
            if (!gRunning || generation != gGeneration || !record.valid) return;
            @try {
                record.geometryChanged = YES;
                setterWorked = DPFrameSetter(mutableSettings, frame);
                if (!setterWorked) {
                    DPLog(@"RESIZE UI NO FRAME SETTER bundle=%@ path=%@ settings=%@",
                          record.bundle, updaterName, NSStringFromClass([mutableSettings class]));
                    return;
                }
                // V6.30: the TemplateUIHost host safe-area was reclaimed in V6.28, but the
                // remote CarPlay client can still receive the physical 45pt left safe-area.
                // That makes map camera centering use (45 + paneWidth)/2, visually shifting
                // the vehicle ~22.5pt to the right. Patch the client scene safe-area too.
                DPClientSafeAreaPatch(mutableSettings, record, YES);
                record.resizeState = 1; record.submittedSize = target;
                DPLog(@"RESIZE REQUEST bundle=%@ path=%@ settingsClass=%@ frame=%@",
                      record.bundle, updaterName, NSStringFromClass([mutableSettings class]), NSStringFromCGRect(frame));
            } @catch (NSException *e) {
                DPLog(@"RESIZE ERROR %@ %@", record.bundle, e.name);
            }
        };
        @try {
            ((void(*)(id,SEL,id))objc_msgSend)(scene, NSSelectorFromString(updaterName), change);
        } @catch (NSException *e) { DPLog(@"RESIZE UPDATE ERROR %@ %@", record.bundle, e.name); }

        // Nếu UI-settings object không có frame setter thì fallback về đường cũ,
        // để V6.22 vẫn chạy được thay vì vô hiệu hóa split.
        if (!setterWorked && ![updaterName isEqualToString:@"updateSettingsWithBlock:"] &&
            DPHasBlockUpdater(scene, @"updateSettingsWithBlock:")) {
            void (^fallback)(id) = ^(id mutableSettings) {
                if (!gRunning || generation != gGeneration || !record.valid) return;
                @try {
                    if (DPFrameSetter(mutableSettings, frame)) {
                        DPClientSafeAreaPatch(mutableSettings, record, YES);
                        record.resizeState = 1; record.submittedSize = target;
                        DPLog(@"RESIZE FALLBACK bundle=%@ settingsClass=%@ frame=%@",
                              record.bundle, NSStringFromClass([mutableSettings class]), NSStringFromCGRect(frame));
                    }
                } @catch (__unused NSException *e) {}
            };
            @try { ((void(*)(id,SEL,id))objc_msgSend)(scene, NSSelectorFromString(@"updateSettingsWithBlock:"), fallback); }
            @catch (__unused NSException *e) {}
        }

        // V6.24: frame trong scene settings đã được V6.22 xác nhận thay đổi đúng,
        // nhưng client content chưa relayout. Sau transaction, ép controller chạy
        // đúng đường scene-update mà Dashboard dùng và quan sát currentSceneUpdate.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!gRunning || generation != gGeneration || !record.valid) return;
            DPTryPropagateSceneUpdate(record, @"post-settings-25ms");
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!gRunning || generation != gGeneration || !record.valid) return;
            DPTryPropagateSceneUpdate(record, @"post-settings-120ms");
        });

        // Presentation có hook nội bộ này (đã probe được). Gọi lại sau geometry
        // update để host view cập nhật transform/frame từ presentation context mới.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 40 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!gRunning || generation != gGeneration || !record.presentation) return;
            @try {
                SEL refresh = NSSelectorFromString(@"_updateFrameAndTransform");
                if ([record.presentation respondsToSelector:refresh]) {
                    ((void(*)(id,SEL))objc_msgSend)(record.presentation, refresh);
                    DPLog(@"PRESENTATION GEOMETRY REFRESH bundle=%@ frame=%@ bounds=%@",
                          record.bundle, NSStringFromCGRect(record.presentation.frame), NSStringFromCGRect(record.presentation.bounds));
                }
                [record.presentation setNeedsLayout];
                [record.presentation layoutIfNeeded];
            } @catch (NSException *e) { DPLog(@"PRESENTATION REFRESH ERROR %@ %@", record.bundle, e.name); }
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            if (!gRunning || generation != gGeneration || !record.valid) return;
            CGRect actual = CGRectZero;
            BOOL readable = DPReadFrame(scene, &actual);
            DPLog(@"RESIZE OBSERVED bundle=%@ requested=%@ actual=%@ readable=%d setterState=%ld",
                  record.bundle, NSStringFromCGSize(target), NSStringFromCGRect(actual), readable, (long)record.resizeState);
            DPTryPokeSceneUI(record);
            // Observed settings are not proof that the remote application has redrawn.
            DPLayout();
        });
    });
}
static void DPFit(DPRecord *record, UIView *pane) {
    UIView *view = record.presentation;
    CGSize target = pane.bounds.size;
    if (!view || target.width <= 0 || target.height <= 0) return;
    DPQueueResize(record, target); // Identical submitted sizes are deduplicated.
    view.transform = CGAffineTransformIdentity;

    // TRƯỚC ĐÂY: trong lúc chờ vòng resize round-trip hoàn tất (~300ms),
    // source rơi về gNativeSize (kích thước FULL màn hình gốc của app,
    // ví dụ 426.67x240) — khiến view.bounds bị đặt to hơn hẳn pane (chỉ
    // ~188.83x240), rồi bị pane.clipsToBounds cắt bớt, hiện ra như đang
    // xem một PHẦN app full-size bị crop, không phải app đã resize đúng.
    //
    // GIỜ: mặc định dùng luôn kích thước PANE làm bounds ngay từ đầu (lạc
    // quan là app sẽ tự vẽ lại vừa khít) — đảm bảo hình luôn full kín pane,
    // không tràn/không hở, kể cả trước khi resize round-trip xác nhận xong.
    CGSize source = target;

    // Chỉ đổi sang kích thước THỰC TẾ mà hệ thống đã xác nhận (actual quan
    // sát được qua DPReadFrame) khi nó khác đáng kể so với target — nghĩa là
    // OS/app đã tự điều chỉnh về 1 kích thước khác thay vì chấp nhận nguyên
    // yêu cầu. Trường hợp đó ưu tiên khớp với cái THẬT để không bị lệch.
    CGRect observed = CGRectZero;
    if (record.resizeScene && DPReadFrame(record.resizeScene, &observed) &&
        (fabs(observed.size.width - target.width) > 0.5 ||
         fabs(observed.size.height - target.height) > 0.5)) {
        source = observed.size;
        DPLog(@"FIT MISMATCH bundle=%@ target=%@ actualObserved=%@ — dùng kích thước thật",
              record.bundle, NSStringFromCGSize(target), NSStringFromCGSize(observed.size));
    }

    if (source.width <= 0 || source.height <= 0) return;
    view.bounds = (CGRect){CGPointZero, source};
    view.center = CGPointMake(CGRectGetMinX(pane.bounds) + source.width * 0.5,
                              CGRectGetMinY(pane.bounds) + source.height * 0.5);
}
static const CGFloat kDividerGrabWidth = 34.0;   // vùng chạm trong suốt quanh khe
static const CGFloat kPaneGap = 6.0;              // tổng khoảng hở nhìn thấy giữa hai main
static const CGFloat kMinSplitRatio = 0.30;       // tránh pane quá hẹp
static const CGFloat kMaxSplitRatio = 0.70;
static CGFloat gSplitRatio = 0.50;
static const NSUInteger kMaxCachedApps = 6;      // nhớ tối đa 6 app đã mở trong phiên
static const CGFloat kPaneCornerRadius = 14.0;   // bo góc kiểu iPhone

static BOOL DPDockClassLooksUseful(NSString *name) {
    if (!name.length) return NO;
    NSString *l = name.lowercaseString;
    return [l containsString:@"dock"] || [l containsString:@"sidebar"] ||
           [l containsString:@"home"] || [l containsString:@"status"] ||
           [l containsString:@"dashboard"] || [l containsString:@"appgrid"];
}

static void DPWalkDockViews(UIView *view, NSUInteger depth) {
    if (!view || depth > 8) return;
    NSString *name = NSStringFromClass(view.class);
    CGRect f = view.frame;
    // Native CarPlay dock/sidebar is normally narrow and hugs one display edge.
    BOOL edgeish = (f.size.width > 0 && f.size.width <= 90 && f.size.height >= 80) ||
                   (f.size.height > 0 && f.size.height <= 90 && f.size.width >= 120);
    if (DPDockClassLooksUseful(name) || edgeish) {
        DPLog(@"DOCK-CANDIDATE depth=%lu class=%@ frame=%@ bounds=%@ hidden=%d alpha=%.2f windowLevel=%.1f super=%@",
              (unsigned long)depth, name, NSStringFromCGRect(f), NSStringFromCGRect(view.bounds),
              view.hidden, view.alpha, view.window.windowLevel,
              view.superview ? NSStringFromClass(view.superview.class) : @"nil");
    }
    for (UIView *child in view.subviews) DPWalkDockViews(child, depth + 1);
}

static void DPDumpDockCandidates(void) {
    UIWindowScene *scene = gSession ?: DPDashboard();
    if (!scene) return;
    DPLog(@"========== DOCK-PROBE windows=%lu =========", (unsigned long)scene.windows.count);
    for (UIWindow *w in scene.windows) {
        if (w == gSplitWindow || w == gButtonWindow || w == gPickerWindow) continue;
        DPLog(@"DOCK-WINDOW class=%@ level=%.1f hidden=%d frame=%@ root=%@",
              NSStringFromClass(w.class), w.windowLevel, w.hidden, NSStringFromCGRect(w.frame),
              w.rootViewController ? NSStringFromClass(w.rootViewController.class) : @"nil");
        DPWalkDockViews(w.rootViewController.view ?: w, 0);
    }
    DPLog(@"========== DOCK-PROBE END =========");
}

static UIButton *DPControlButton(NSString *symbolName, NSString *fallback, NSString *label, SEL action) {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage *image = nil;
    if (@available(iOS 13.0, *)) {
        UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:15 weight:UIImageSymbolWeightSemibold];
        image = [[UIImage systemImageNamed:symbolName] imageWithConfiguration:cfg];
    }
    if (image) {
        [b setImage:image forState:UIControlStateNormal];
    } else {
        [b setTitle:fallback forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    }
    b.accessibilityLabel = label;
    b.tintColor = UIColor.whiteColor;
    b.backgroundColor = [UIColor colorWithWhite:0.04 alpha:0.68];
    b.layer.cornerRadius = 17.0;
    b.layer.borderWidth = 0.6;
    b.layer.borderColor = [UIColor colorWithWhite:1.0 alpha:0.22].CGColor;
    b.layer.shadowColor = UIColor.blackColor.CGColor;
    b.layer.shadowOpacity = 0.22;
    b.layer.shadowRadius = 3.0;
    b.layer.shadowOffset = CGSizeMake(0, 1);
    b.layer.masksToBounds = NO;
    [b addTarget:gControls action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

static UIButton *DPExitButton(void) {
    UIButton *b = DPControlButton(@"xmark", @"×", @"Thoát chia màn hình", @selector(stop));
    b.tag = 9002;
    return b;
}

static void DPSetControlsVisible(BOOL visible, BOOL animated) {
    if (!gSplitWindow) return;
    UIButton *exitButton = (UIButton *)[gSplitWindow.rootViewController.view viewWithTag:9002];
    NSArray *targets = @[(id)(gDockOverlay ?: [NSNull null]), (id)(exitButton ?: [NSNull null])];
    void (^changes)(void) = ^{
        for (id obj in targets) {
            if (![obj isKindOfClass:UIView.class]) continue;
            ((UIView *)obj).alpha = visible ? 1.0 : 0.0;
        }
    };
    for (id obj in targets) if ([obj isKindOfClass:UIView.class]) ((UIView *)obj).userInteractionEnabled = visible;
    if (animated) [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionBeginFromCurrentState|UIViewAnimationOptionAllowUserInteraction animations:changes completion:nil];
    else changes();
}

static void DPScheduleControlsHide(void) {
    if (!gRunning) return;
    NSUInteger token = ++gControlsHideToken;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (!gRunning || token != gControlsHideToken) return;
        DPSetControlsVisible(NO, YES);
        DPLog(@"CONTROLS AUTO-HIDE");
    });
}

static void DPRevealControls(void) {
    if (!gRunning || !gSplitWindow) return;
    DPSetControlsVisible(YES, YES);
    DPScheduleControlsHide();
}

static void DPLayout(void) {
    if (!gSplitWindow) return;
    CGFloat width = gSplitWindow.bounds.size.width, height = gSplitWindow.bounds.size.height;
    CGFloat ratio = MIN(kMaxSplitRatio, MAX(kMinSplitRatio, gSplitRatio));
    CGFloat split = round(width * ratio * 3.0) / 3.0; // khớp lưới 3x của màn CarPlay hiện tại
    CGFloat halfGap = kPaneGap * 0.5;

    // Hai pane full chiều cao; ở giữa chỉ để một khe đen sạch, không còn vạch divider.
    gLeftPane.frame = CGRectMake(0, 0, MAX(1, split - halfGap), height);
    gRightPane.frame = CGRectMake(split + halfGap, 0, MAX(1, width - split - halfGap), height);

    // Divider thật chỉ là hit-zone trong suốt để kéo. Khe giữa chính là dấu hiệu thị giác.
    gDivider.frame = CGRectMake(split - kDividerGrabWidth * 0.5, 0, kDividerGrabWidth, height);

    // V6.35: all four controls use the same compact circular visual language.
    UIButton *exitButton = (UIButton *)[gSplitWindow.rootViewController.view viewWithTag:9002];
    exitButton.frame = CGRectMake(width - 42.0, 7.0, 34.0, 34.0);

    // Three left controls float independently; no bulky white square/rail.
    if (gDockOverlay) {
        CGFloat dockW = 38.0, buttonD = 34.0, gap = 7.0;
        CGFloat dockH = buttonD * 3.0 + gap * 2.0;
        gDockOverlay.frame = CGRectMake(5.0, MAX(6.0, (height - dockH) * 0.5), dockW, dockH);
        NSArray *buttons = gDockOverlay.subviews;
        for (NSUInteger i = 0; i < buttons.count; i++) {
            UIView *v = buttons[i];
            v.frame = CGRectMake(2.0, i * (buttonD + gap), buttonD, buttonD);
        }
    }

    if (gPair.count == 2) {
        DPFit(gPair[0], gLeftPane);
        DPFit(gPair[1], gRightPane);
    }
}
static void DPStop(NSString *reason) {
    if (!gRunning) return;
    gRunning = NO;
    ++gControlsHideToken; // cancel pending auto-hide callback
    ++gGeneration; // Cancel delayed creation and inspection from this attempt.
    DPLog(@"STOP %@", reason);
    gSplitWindow.hidden = YES;
    BOOL previousOwnCall = gOwnCall;
    gOwnCall = YES;
    for (DPRecord *record in gPair) {
        DPRestoreFrame(record);
        record.resizeQueued = NO;
        record.resizeScene = nil;
        record.geometryChanged = NO;
        record.resizeState = 0;
        record.resizeAttempts = 0;
        record.submittedSize = CGSizeZero;
        record.v636BlankChecks = 0;
        record.v636RecoveryAttempted = NO;
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
    gSplitWindow = nil; gLeftPane = nil; gRightPane = nil; gDivider = nil; gDockOverlay = nil; gStatus = nil;
    DPRefreshButton();
}
@interface DPControls : NSObject
- (void)openPicker;
- (void)closePicker;
- (void)pickerTap:(UIButton *)sender;
- (void)startWithLeftBundle:(NSString *)leftBundle rightBundle:(NSString *)rightBundle;
- (void)stop;
- (void)swap;
- (void)dockHome;
- (void)dockApps;
- (void)dividerPan:(UIPanGestureRecognizer *)pan;
- (void)revealControls;
@end
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
        DPLog(@"VIEWPORT bundle=%@ logical=%@ bounds=%@ scaleX=%.3f scaleY=%.3f",
              record.bundle, NSStringFromCGSize(record.submittedSize),
              NSStringFromCGRect(record.presentation.bounds),
              record.presentation.transform.a, record.presentation.transform.d);
    }
    gStatus.text = allAttached && gPair.count == 2
        ? [NSString stringWithFormat:@"%@ | %@", DPName(gPair[0]), DPName(gPair[1])]
        : @"Chưa hiển thị đủ hai app";
    // These are structural signals, never proof of live rendering/touch.
}
@implementation DPControls
- (void)revealControls { DPRevealControls(); }
- (void)stop { DPStop(@"user exit"); }
- (void)dockHome { DPStop(@"dock home"); }
- (void)dockApps {
    DPStop(@"dock apps");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [gControls openPicker]; });
}

- (void)dividerPan:(UIPanGestureRecognizer *)pan {
    if (!gRunning || !gSplitWindow || gPair.count != 2) return;
    DPRevealControls();
    UIView *root = gSplitWindow.rootViewController.view;
    CGFloat width = root.bounds.size.width;
    if (width <= 1.0) return;

    CGPoint point = [pan locationInView:root];
    CGFloat ratio = point.x / width;
    ratio = MIN(kMaxSplitRatio, MAX(kMinSplitRatio, ratio));

    if (pan.state == UIGestureRecognizerStateBegan ||
        pan.state == UIGestureRecognizerStateChanged) {
        gSplitRatio = ratio;
        DPLayout();
    }
    if (pan.state == UIGestureRecognizerStateEnded ||
        pan.state == UIGestureRecognizerStateCancelled ||
        pan.state == UIGestureRecognizerStateFailed) {
        gSplitRatio = ratio;
        DPLayout();
        DPLog(@"DIVIDER MOVE END ratio=%.4f left=%.1f right=%.1f gap=%.1f",
              gSplitRatio, gLeftPane.bounds.size.width, gRightPane.bounds.size.width, kPaneGap);
        DPInspect(gGeneration);
    }
}

- (void)closePicker {
    gPickerWindow.hidden = YES;
    gPickerWindow = nil;
    gPickerBundles = nil;
    gPickerFirstPick = nil;
}

// Danh sách các app còn "sống" (controller vẫn hợp lệ), mới mở gần đây lên trước.
- (NSArray<NSString *> *)validCachedBundlesNewestFirst {
    NSMutableArray<NSString *> *result = [NSMutableArray array];
    for (NSString *bundle in gOrder.reverseObjectEnumerator)
        if (gRecords[bundle].valid) [result addObject:bundle];
    return result;
}

// Nút "Chia" giờ mở 1 danh sách các app đã mở trong phiên lái xe (tối đa 6,
// không chỉ 2 app cuối cùng) — chạm chọn app trái, chạm tiếp chọn app phải,
// không cần quay lại Trang chủ mở lại app mỗi lần muốn đổi cặp chia màn.
- (void)openPicker {
    if (gRunning || !gSession) return;
    [self closePicker];

    NSArray<NSString *> *bundles = [self validCachedBundlesNewestFirst];
    if (bundles.count < 2) return;

    gPickerBundles = [bundles mutableCopy];

    CGRect bounds = gSession.coordinateSpace.bounds;
    gPickerWindow = [[UIWindow alloc] initWithWindowScene:gSession];
    gPickerWindow.windowLevel = UIWindowLevelAlert + 85;
    gPickerWindow.frame = CGRectMake(45, 0, MAX(1, bounds.size.width - 45), bounds.size.height);
    gPickerWindow.rootViewController = [UIViewController new];
    UIView *root = gPickerWindow.rootViewController.view;
    root.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.92];

    UILabel *hint = [UILabel new];
    hint.text = @"Chạm chọn app bên trái, rồi chạm app bên phải";
    hint.textColor = UIColor.whiteColor;
    hint.font = [UIFont systemFontOfSize:12];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.frame = CGRectMake(8, 6, root.bounds.size.width - 16, 20);
    hint.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [root addSubview:hint];

    CGFloat rowH = 34, gap = 6, top = 32;
    for (NSUInteger i = 0; i < gPickerBundles.count; i++) {
        UIButton *row = [UIButton buttonWithType:UIButtonTypeSystem];
        row.tag = (NSInteger)i;
        row.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.9];
        row.layer.cornerRadius = 6;
        row.tintColor = UIColor.whiteColor;
        [row setTitle:DPName(gRecords[gPickerBundles[i]]) forState:UIControlStateNormal];
        row.frame = CGRectMake(12, top + i * (rowH + gap), root.bounds.size.width - 24, rowH);
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row addTarget:self action:@selector(pickerTap:) forControlEvents:UIControlEventTouchUpInside];
        [root addSubview:row];
    }

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    [cancel setTitle:@"Huỷ" forState:UIControlStateNormal];
    cancel.tintColor = UIColor.whiteColor;
    cancel.frame = CGRectMake(root.bounds.size.width - 60, 4, 52, 24);
    cancel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [cancel addTarget:self action:@selector(closePicker) forControlEvents:UIControlEventTouchUpInside];
    [root addSubview:cancel];

    gPickerWindow.hidden = NO;
}

- (void)pickerTap:(UIButton *)sender {
    if (!gPickerBundles || sender.tag < 0 || (NSUInteger)sender.tag >= gPickerBundles.count) return;
    NSString *bundle = gPickerBundles[(NSUInteger)sender.tag];

    if (!gPickerFirstPick) {
        gPickerFirstPick = bundle;
        sender.backgroundColor = [UIColor colorWithRed:0.2 green:0.5 blue:0.9 alpha:0.95];
        return;
    }

    if ([gPickerFirstPick isEqualToString:bundle]) return; // không cho chọn trùng 1 app cho cả 2 bên

    NSString *left = gPickerFirstPick, *right = bundle;
    [self closePicker];
    [self startWithLeftBundle:left rightBundle:right];
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
- (void)startWithLeftBundle:(NSString *)leftBundle rightBundle:(NSString *)rightBundle {
    if (gRunning || !gSession || DPDashboard() != gSession) return;
    DPRecord *left = gRecords[leftBundle], *right = gRecords[rightBundle];
    if (!left.valid || !right.valid) {
        DPLog(@"REFUSE invalid record left=%@(%d) right=%@(%d)",
              leftBundle, left.valid, rightBundle, right.valid);
        return;
    }
    DPDumpConnectedScenes(@"start-attempt");
    if (left.controller == right.controller) {
        // Nếu 2 bundle khác nhau nhưng CÙNG 1 controller vật lý, nhiều khả năng
        // CarPlay xếp cả 2 vào chung 1 "vai trò" (ví dụ Navigation) và chỉ cho
        // 1 app thuộc vai trò đó active tại 1 thời điểm — giới hạn tầng OS,
        // không phải lỗi ở logic ghép cặp của tweak.
        DPLog(@"REFUSE same controller=%p left=%@(cat=%@) right=%@(cat=%@) — có thể 2 app cùng 1 vai trò CarPlay (vd Navigation)",
              (__bridge void *)left.controller, leftBundle, left.category, rightBundle, right.category);
        return;
    }
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
    // V6.31: use the whole CarPlay display width instead of starting after the
    // physical 45pt sidebar reservation.  The split window sits above Dashboard, so
    // each pane can receive ~213pt instead of ~191pt.  Client/template safe-area
    // is patched to zero in split mode, so the old sidebar inset is not subtracted
    // again inside each app.
    gSplitWindow.frame = bounds;
    gSplitWindow.windowLevel = UIWindowLevelAlert + 70;
    gSplitWindow.rootViewController = [UIViewController new];
    UIView *root = gSplitWindow.rootViewController.view;
    root.backgroundColor = UIColor.blackColor; // chỉ lấp khe 2pt giữa 2 pane
    gLeftPane = [UIView new]; gRightPane = [UIView new];
    gLeftPane.clipsToBounds = YES; gRightPane.clipsToBounds = YES;
    for (UIView *pane in @[gLeftPane, gRightPane]) {
        pane.layer.cornerRadius = kPaneCornerRadius;
        if (@available(iOS 13.0, *)) pane.layer.cornerCurve = kCACornerCurveContinuous;
        pane.layer.masksToBounds = YES;
    }
    gLeftPane.backgroundColor = UIColor.blackColor;
    gRightPane.backgroundColor = UIColor.blackColor;
    [root addSubview:gLeftPane]; [root addSubview:gRightPane];

    // Không hiện tên app nữa theo yêu cầu — chỉ còn 1 pill Thoát nhỏ.
    gStatus = [UILabel new];
    gStatus.hidden = YES;

    UIButton *exit = DPExitButton();
    [root addSubview:exit];
    // V6.34: không vẽ thanh divider. Chỉ giữ hit-zone trong suốt phủ quanh khe 6pt.
    gDivider = [UIView new];
    gDivider.backgroundColor = UIColor.clearColor;
    gDivider.userInteractionEnabled = YES;
    UIPanGestureRecognizer *dividerPan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(dividerPan:)];
    dividerPan.minimumNumberOfTouches = 1;
    dividerPan.maximumNumberOfTouches = 1;
    [gDivider addGestureRecognizer:dividerPan];
    [root addSubview:gDivider];

    // V6.35 redesigned controls: Home / Apps / Swap are three dark glass circles.
    // The fourth matching circle is Exit at top-right.
    gDockOverlay = [UIView new];
    gDockOverlay.backgroundColor = UIColor.clearColor;
    gDockOverlay.clipsToBounds = NO;
    [gDockOverlay addSubview:DPControlButton(@"house.fill", @"⌂", @"Trang chủ", @selector(dockHome))];
    [gDockOverlay addSubview:DPControlButton(@"square.grid.2x2.fill", @"▦", @"Chọn ứng dụng", @selector(dockApps))];
    [gDockOverlay addSubview:DPControlButton(@"arrow.left.arrow.right", @"↔", @"Đổi vị trí hai ứng dụng", @selector(swap))];
    [root addSubview:gDockOverlay];

    // Any tap in the split surface reveals both left dock and right exit without
    // cancelling the app's own touch. UIApplication sendEvent: below is an extra
    // safety net for touches routed through hosted scenes.
    UITapGestureRecognizer *revealTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(revealControls)];
    revealTap.cancelsTouchesInView = NO;
    revealTap.delaysTouchesBegan = NO;
    revealTap.delaysTouchesEnded = NO;
    [root addGestureRecognizer:revealTap];

    DPLayout(); gSplitWindow.hidden = NO; DPSetControlsVisible(YES, NO); DPScheduleControlsHide(); DPRefreshButton();
    DPDumpDockCandidates();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ if (gRunning) DPDumpDockCandidates(); });
    DPLog(@"START MOVABLE SPLIT ratio=%.3f gap=%.1f left=%@ right=%@ — unscaled scene resize", gSplitRatio, kPaneGap, left.bundle, right.bundle);
    gOwnCall = YES;
    @try {
        for (DPRecord *record in gPair) {
            // V6.36: nếu record NÀY đã sẵn đang active (app còn lại vừa mở
            // trước đó, còn cái này là cái user đang xem ngay trước khi bấm
            // Chia), gọi foreground thêm 1 lần nữa cho NÓ là thừa và có thể
            // gây xáo trộn không cần thiết (mỗi lần foreground là 1 lần yêu
            // cầu hệ thống coi app đó là "app chính", trong khi nó vốn đã
            // là vậy rồi). Chỉ foreground app đang KHÔNG active — đây chính
            // là app cần được "gọi" vào để tham gia màn chia.
            if (DPSceneActive(record)) {
                DPLog(@"START SKIP-FOREGROUND bundle=%@ — đã sẵn active, không gọi lại", record.bundle);
                record.nativeBackgrounded = NO;
                continue;
            }
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
                DPProbeTemplateSurface(record);
            }
            DPLayout();
        } @catch (NSException *e) {
            DPLog(@"PRESENTATION ERROR %@", e.name); gOwnCall = NO; DPStop(@"presentation error"); return;
        }
        gOwnCall = NO;
        // V6.36: kiểm tra nội dung thật ở 1.5s / 2.5s / 3.5s sau khi tạo
        // presentation — 3 lần trống liên tiếp mới cứu hộ (recreate), tránh
        // phản ứng quá sớm lúc app còn đang tải bản đồ bình thường.
        for (NSUInteger i = 1; i <= 4; i++) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + i) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (!gRunning || generation != gGeneration) return;
                for (NSUInteger index = 0; index < gPair.count; index++) {
                    DPV636RecreatePresentationIfBlank(gPair[index], index == 0 ? gLeftPane : gRightPane, generation);
                }
            });
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
    });
}
@end

static void DPRefreshButton(void) {
    NSUInteger validCount = 0;
    for (NSString *bundle in gOrder) if (gRecords[bundle].valid) validCount++;
    BOOL ready = validCount >= 2;
    gButtonWindow.hidden = gRunning || !ready;
}
// Chỉ CHẨN ĐOÁN — quét tên method/property của controller + scene, lọc theo
// từ khoá liên quan tới template/tab bar/layout, để TÌM (không phải đoán mò)
// xem có API nào bắt hệ thống Template (CarPlayTemplateUIHost) vẽ lại UI theo
// kích thước mới hay không. Chỉ chạy 1 lần/app để không spam log.
static BOOL DPTemplateProbeNameLooksUseful(NSString *name) {
    if (!name) return NO;
    NSString *l = name.lowercaseString;
    return [l containsString:@"template"] || [l containsString:@"tabbar"] ||
           [l containsString:@"tab"] || [l containsString:@"layout"] ||
           [l containsString:@"reload"] || [l containsString:@"invalidate"] ||
           [l containsString:@"relayout"] || [l containsString:@"content"] ||
           [l containsString:@"redraw"] || [l containsString:@"update"];
}
static void DPProbeClassSurface(Class cls, NSString *tag) {
    if (!cls || !tag) return;
    DPLog(@"TEMPLATE-PROBE class=%@ super=%@", tag, NSStringFromClass(class_getSuperclass(cls)));
    unsigned int mc = 0;
    Method *methods = class_copyMethodList(cls, &mc);
    for (unsigned int i = 0; i < mc; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        if (DPTemplateProbeNameLooksUseful(name))
            DPLog(@"TEMPLATE-PROBE %@ METHOD %@ argc=%u types=%s", tag, name,
                  method_getNumberOfArguments(methods[i]),
                  method_getTypeEncoding(methods[i]) ?: "?");
    }
    if (methods) free(methods);
}
// GHI CHÚ: đã bỏ 2 hàm gọi trigger/getter không tham số (DPTryZeroArgVoid,
// DPPeekZeroArgObject) — hướng "reason"/"invalidate"/"_updateSceneUI" đã
// chứng minh là ngõ cụt hoặc nguy hiểm (xem log thực tế). Chuyển hẳn sang
// quét ivar thật ở hàm bên dưới.
static void DPTryPokeSceneUI(DPRecord *record) {
    // GHI CHÚ: hàm này từng đào sâu FBSDisplayLayoutElement (soi class,
    // quét ivar tìm instance thật). Log thực tế xác nhận đó là NGÕ CỤT —
    // object này là cơ chế theo dõi UI toàn hệ thống (xuất hiện cho cả
    // lock-screen, Filza...), không phải thứ quyết định kích thước layout
    // thật của app CarPlay. Đã gỡ bỏ toàn bộ nhánh đó, để trống chờ hướng
    // điều tra tiếp theo (xem ghi chú ở %hook UIApplication bên dưới —
    // hướng mới là soi windowScene NGAY LÚC app kết nối lần đầu, thay vì
    // resize sau khi đã kết nối).
    (void)record;
}
static NSMutableSet<NSString *> *gTemplateProbed;
static void DPProbeTemplateSurface(DPRecord *record) {
    if (!record.controller) return;
    if (!gTemplateProbed) gTemplateProbed = [NSMutableSet set];
    if ([gTemplateProbed containsObject:record.bundle]) return;
    [gTemplateProbed addObject:record.bundle];

    BOOL isTemplate = [record.sid containsString:@"CarPlayTemplateUIHost"];
    DPLog(@"========== TEMPLATE-PROBE bundle=%@ isTemplate=%d ==========", record.bundle, isTemplate);

    DPProbeClassSurface([record.controller class],
                        [NSString stringWithFormat:@"controller(%@)", record.bundle]);

    id scene = DPValue(record.controller, @"scene");
    if (scene) DPProbeClassSurface([scene class],
                                   [NSString stringWithFormat:@"scene(%@)", record.bundle]);

    // Presentation view chính là bề mặt render — quét luôn để tìm hàm
    // "reload/invalidate layout" ngay trên chính view đó nếu có.
    if (record.presentation)
        DPProbeClassSurface([record.presentation class],
                            [NSString stringWithFormat:@"presentation(%@)", record.bundle]);

    DPLog(@"========== TEMPLATE-PROBE bundle=%@ END ==========", record.bundle);
}
static void DPDumpConnectedScenes(NSString *tag) {
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        NSString *pid = scene.session.persistentIdentifier;
        NSString *role = scene.session.role;
        BOOL active = scene.activationState == UISceneActivationStateForegroundActive;
        DPLog(@"SCENES[%@] pid=%@ role=%@ class=%@ active=%d",
              tag, pid, role, NSStringFromClass([scene class]), active);
    }
}
static void DPCapture(id controller, id settings) {
    if (gOwnCall || ![settings isKindOfClass:NSDictionary.class]) return;
    // Ignore suspended prewarming. Only retain observed explicit launch settings.
    if (!settings[@"DBActivationSettingLaunchSource"]) return;
    NSString *sid = DPValue(controller, @"sceneID"), *bundle = DPBundle(sid);
    if (!bundle) return;
    NSString *category = DPCategoryToken(sid);
    NSDictionary *copy = [settings copy];
    NSUInteger epoch = gSessionEpoch;
    void (^capture)(void) = ^{
        if (epoch != gSessionEpoch || !gSession || DPDashboard() != gSession) return;
        if (gRunning) return;
        DPRecord *record = [DPRecord new];
        record.controller = controller; record.sid = sid; record.category = category;
        record.bundle = bundle; record.settings = copy;
        record.valid = YES;
        // Nếu bundle này đã có record cũ với category KHÁC, hoặc trùng bundle
        // nhưng khác controller — đáng chú ý, log riêng để đối chiếu sau.
        DPRecord *previous = gRecords[bundle];
        if (previous && previous.controller != controller)
            DPLog(@"CAPTURE-REPLACE bundle=%@ oldController=%p oldCategory=%@ newController=%p newCategory=%@",
                  bundle, (__bridge void *)previous.controller, previous.category,
                  (__bridge void *)controller, category);
        gRecords[bundle] = record;
        [gOrder removeObject:bundle]; [gOrder addObject:bundle];
        while (gOrder.count > kMaxCachedApps) {
            [gRecords removeObjectForKey:gOrder.firstObject]; [gOrder removeObjectAtIndex:0];
        }
        DPLog(@"CAPTURE bundle=%@ category=%@ sid=%@ controller=%p source=%@ suspended=%@ isTemplate=%d", bundle, category, sid,
              (__bridge void *)controller,
              copy[@"DBActivationSettingLaunchSource"], copy[@"DBActivationSettingSuspended"],
              [sid containsString:@"CarPlayTemplateUIHost"]);
        // Dump TOÀN BỘ key trong settings — đang tìm 1 key kiểu frame/display
        // configuration có thể set NGAY LÚC connect, thay vì resize sau khi
        // đã render (cách hiện tại không hiệu quả với app kiểu Template).
        for (NSString *key in copy.allKeys)
            DPLog(@"SETTINGS-DUMP bundle=%@ key=%@ value=%@ class=%@",
                  bundle, key, copy[key], NSStringFromClass([copy[key] class]));
        DPDumpConnectedScenes([NSString stringWithFormat:@"capture:%@", bundle]);
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
        [gControls closePicker];
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
        [gButton addTarget:gControls action:@selector(openPicker) forControlEvents:UIControlEventTouchUpInside];
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
- (void)sceneManager:(id)manager updateForScene:(id)scene appliedWithContext:(id)context {
    NSString *bundle = DPBundle(DPValue(self, @"sceneID"));
    DPRecord *record = bundle ? gRecords[bundle] : nil;
    if (record && record.controller == self) {
        DPLog(@"SCENE-MANAGER-APPLIED ENTER bundle=%@ manager=%@ scene=%@ context=%@ current=%@",
              bundle, DPObjSummary(manager), DPObjSummary(scene), DPObjSummary(context),
              DPObjSummary(DPValue(self, @"currentSceneUpdate")));
        for (NSString *key in @[@"frame", @"bounds", @"geometry", @"settings", @"sceneSettings", @"clientSettings", @"transitionContext"]) {
            id v = DPValue(context, key);
            if (v) DPLog(@"SCENE-MANAGER-CONTEXT bundle=%@ key=%@ value=%@", bundle, key, DPObjSummary(v));
        }
    }
    %orig;
    if (record && record.controller == self) {
        DPLog(@"SCENE-MANAGER-APPLIED EXIT bundle=%@ current=%@",
              bundle, DPObjSummary(DPValue(self, @"currentSceneUpdate")));
    }
}
- (void)sceneManager:(id)manager didDestroyScene:(id)scene {
    NSString *bundle = DPBundle(DPValue(self, @"sceneID"));
    DPRecord *record = bundle ? gRecords[bundle] : nil;
    if (record.controller == self) {
        BOOL wasInPair = gRunning && [gPair containsObject:record];
        if (gPickerWindow) [gControls closePicker];
        if (wasInPair) {
            // Đang hiển thị app này thật — phải dừng ngay, không trì hoãn.
            record.valid = NO;
            DPStop(@"native scene destroyed");
            [gRecords removeObjectForKey:bundle];
            [gOrder removeObject:bundle];
            DPRefreshButton();
        } else {
            // Nhiều app tự huỷ rồi tạo lại controller khi cập nhật UI nội bộ
            // (không thật sự rời CarPlay) — quan sát thấy CAPTURE-REPLACE khá
            // thường xuyên trong log thực tế. Đánh invalid ngay lập tức làm
            // điều kiện "đủ 2 app" nhấp nháy, nút "Chia" ẩn/hiện liên tục.
            // Chờ 1 nhịp xem có bị capture lại (thay thế) không rồi mới gỡ
            // thật khỏi danh sách + refresh nút.
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (gRecords[bundle] == record) {
                    record.valid = NO;
                    [gRecords removeObjectForKey:bundle];
                    [gOrder removeObject:bundle];
                    DPRefreshButton();
                }
            });
        }
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

// V6.25: đây là callback thật của FBScene khi client settings thay đổi.
// V6.24 đã chứng minh host scene.settings.frame = 188.83x240 và FBSceneUpdateContext
// cũng mang frame đó. Giờ ta đo xem "clientSettings" mà process app trao đổi với
// FrontBoard có còn full-width 426.67 hay đã nhận pane width.
%hook FBScene
- (void)client:(id)client didUpdateClientSettings:(id)settings withDiff:(id)diff transitionContext:(id)transitionContext {
    DPRecord *record = DPRecordForSceneObject(self);
    if (record) {
        DPLog(@"CLIENT-SETTINGS ENTER bundle=%@ scene=%@ client=%@ settings=%@ diff=%@ transition=%@",
              record.bundle, DPObjSummary(self), DPObjSummary(client), DPObjSummary(settings),
              DPObjSummary(diff), DPObjSummary(transitionContext));
        DPDumpClientObject(record, @"settings-before", settings);
        DPDumpClientObject(record, @"diff-before", diff);
        DPDumpClientObject(record, @"transition-before", transitionContext);
    }
    %orig;
    if (record) {
        id sceneSettings = DPValue(self, @"settings");
        DPLog(@"CLIENT-SETTINGS EXIT bundle=%@ sceneSettings=%@", record.bundle, DPObjSummary(sceneSettings));
        DPDumpClientObject(record, @"scene-settings-after", sceneSettings);
    }
}
%end

// Presentation context là tầng ngay trước _UIScenePresentationView. Nếu client
// settings đã đúng mà UI vẫn co/crop sai, log này cho biết presentation context
// có còn giữ geometry full-width hay không.
%hook _UIScenePresentationView
- (void)scene:(id)scene didPrepareUpdateWithContext:(id)context {
    DPRecord *record = DPRecordForPresentation(self);
    if (record) {
        DPLog(@"PRESENTATION-PREPARE bundle=%@ scene=%@ context=%@",
              record.bundle, DPObjSummary(scene), DPObjSummary(context));
        DPDumpClientObject(record, @"presentation-prepare-context", context);
    }
    %orig;
}
- (void)_updatePresentationContextFrom:(id)fromContext toContext:(id)toContext {
    DPRecord *record = DPRecordForPresentation(self);
    if (record) {
        DPLog(@"PRESENTATION-CONTEXT bundle=%@ from=%@ to=%@",
              record.bundle, DPObjSummary(fromContext), DPObjSummary(toContext));
        DPDumpClientObject(record, @"presentation-from", fromContext);
        DPDumpClientObject(record, @"presentation-to", toContext);
    }
    %orig;
}
%end

// ĐÃ GỠ BỎ: hook FBSDisplayLayoutElement. Log thực tế cho thấy object này
// xuất hiện cho RẤT NHIỀU thứ không liên quan CarPlay (lock-screen, home-
// screen, passcode, thậm chí app Filza) và frame của Maps/YouTube Music bị
// hệ thống tự đặt lại full-width liên tục, nhiều lần. fillsDisplayBounds
// cũng đã là 0 sẵn từ đầu — không phải cờ cần tắt như từng đoán. Kết luận:
// đây là cơ chế theo dõi UI toàn hệ thống (khả năng phục vụ Siri/context-
// awareness), KHÔNG phải thứ quyết định kích thước layout thật của app
// CarPlay. Ngõ cụt, dừng đào hướng này.

// Chạy BÊN TRONG process của chính app bản đồ (Maps/Google Maps/Vietmap), khác
// hẳn khối hook DBApplicationSceneViewController ở trên (chạy trong CarPlayApp).
// Mục đích: xem chính app đó tự khai báo role/configuration gì khi nó kết nối
// tới scene CarPlay — dữ liệu này quyết định có spoof/redirect được không.
// _connectUIScene:withOptions: là API private phổ biến, có thể không tồn tại
// trên mọi phiên bản iOS — nếu log không thấy dòng APPSIDE-CONNECT nào dù đã
// mở app trên CarPlay, nghĩa là cần probe selector khác, không phải app không
// kết nối.
//
// HƯỚNG MỚI (sau khi FBSDisplayLayoutElement bị loại): resize SAU KHI app đã
// kết nối và tự layout xong không hiệu quả (đã chứng minh qua nhiều bản). Có
// khả năng app CHỈ tự layout đúng nếu biết kích thước NHỎ ngay từ đầu, giống
// hệt cách 1 app tự nhiên khác nhau trên iPhone SE và iPhone Pro Max. Bước
// này log THÊM windowScene.coordinateSpace.bounds và windowScene.screen.bounds
// — đọc TRƯỚC %orig, tức đúng lúc app CHUẨN BỊ nhận biết kích thước, để xem
// hệ thống báo cho app kích thước gì NGAY LÚC KẾT NỐI ĐẦU TIÊN. Nếu số liệu
// ở đây LUÔN LÀ full-width (426.67x240), nghĩa là app học kích thước full
// ngay từ giây đầu tiên — xác nhận hướng "spoof kích thước lúc connect" là
// đúng chỗ cần làm, chứ không phải resize về sau như đang làm.
static __weak UIWindowScene *gAppObservedCarScene = nil;
static CGRect gAppLastBounds = {{0,0},{0,0}};
static void DPAppPollSceneBounds(NSUInteger remaining) {
    if (!gAppProbeEnabled || remaining == 0) return;
    UIWindowScene *ws = gAppObservedCarScene;
    if (ws) {
        @try {
            CGRect coord = ws.coordinateSpace.bounds;
            CGRect screen = ws.screen.bounds;
            if (!CGRectEqualToRect(coord, gAppLastBounds)) {
                gAppLastBounds = coord;
                DPLog(@"APPSIDE-BOUNDS-CHANGED proc=%@ sid=%@ coordBounds=%@ screenBounds=%@",
                      NSBundle.mainBundle.bundleIdentifier, ws.session.persistentIdentifier,
                      NSStringFromCGRect(coord), NSStringFromCGRect(screen));
            }
        } @catch (__unused NSException *e) {}
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        DPAppPollSceneBounds(remaining - 1);
    });
}

static void DPAppScanConnectedScenes(NSUInteger remaining) {
    if (!gAppProbeEnabled || remaining == 0) return;
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            NSString *role = ws.session.role ?: @"";
            NSString *sid = ws.session.persistentIdentifier ?: @"";
            if (![role containsString:@"CarPlay"] && ![sid containsString:@"Car["]) continue;
            CGRect coord = ws.coordinateSpace.bounds;
            CGRect screen = ws.screen.bounds;
            if (gAppObservedCarScene != ws || !CGRectEqualToRect(coord, gAppLastBounds)) {
                gAppObservedCarScene = ws;
                gAppLastBounds = coord;
                DPLog(@"APPSIDE-SCAN proc=%@ sid=%@ role=%@ coordBounds=%@ screenBounds=%@ windows=%lu",
                      NSBundle.mainBundle.bundleIdentifier, sid, role, NSStringFromCGRect(coord),
                      NSStringFromCGRect(screen), (unsigned long)ws.windows.count);
            }
        }
    } @catch (NSException *e) { DPLog(@"APPSIDE-SCAN ERROR %@", e.name); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        DPAppScanConnectedScenes(remaining - 1);
    });
}



static void DPTemplateHostDumpViewTree(UIView *view, NSString *sid, NSUInteger depth, NSUInteger *budget) {
    if (!view || !budget || *budget == 0 || depth > 5) return;
    (*budget)--;
    UIEdgeInsets safe = UIEdgeInsetsZero;
    @try { safe = view.safeAreaInsets; } @catch (__unused NSException *e) {}
    DPLog(@"TEMPLATEHOST-TREE sid=%@ depth=%lu class=%@ frame=%@ bounds=%@ safe={%.1f,%.1f,%.1f,%.1f} hidden=%d alpha=%.2f constraints=%lu",
          sid, (unsigned long)depth, NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
          NSStringFromCGRect(view.bounds), safe.top, safe.left, safe.bottom, safe.right,
          view.hidden, view.alpha, (unsigned long)view.constraints.count);
    if (*budget == 0) return;
    for (UIView *sub in view.subviews) {
        DPTemplateHostDumpViewTree(sub, sid, depth + 1, budget);
        if (*budget == 0) break;
    }
}

static void DPTemplateHostDumpControllerMethods(Class cls) {
    static NSMutableSet *seen; static dispatch_once_t once; dispatch_once(&once, ^{ seen=[NSMutableSet set]; });
    if (!cls) return; NSString *name=NSStringFromClass(cls); if ([seen containsObject:name]) return; [seen addObject:name];
    unsigned int count=0; Method *methods=class_copyMethodList(cls,&count);
    for (unsigned int i=0;i<count;i++) {
        NSString *sel=NSStringFromSelector(method_getName(methods[i])); NSString *l=sel.lowercaseString;
        if ([l containsString:@"layout"] || [l containsString:@"size"] || [l containsString:@"trait"] || [l containsString:@"safe"] || [l containsString:@"content"] || [l containsString:@"frame"] || [l containsString:@"bounds"])
            DPLog(@"TEMPLATEHOST-METHOD class=%@ selector=%@ types=%s", name, sel, method_getTypeEncoding(methods[i]));
    }
    if (methods) free(methods);
}

static void DPTemplateHostApplySafeAreaFix(UIWindowScene *ws, UIWindow *w, UIViewController *root, NSString *sid) {
    if (!ws || !w || !root || !root.view) return;
    if (![NSStringFromClass(root.class) isEqualToString:@"CARTemplateUIApplicationSceneViewController"]) return;
    if (![sid containsString:@":com.apple.CarPlayTemplateUIHost:"]) return;

    @try {
        CGFloat paneW = ws.coordinateSpace.bounds.size.width;
        UIEdgeInsets inherited = root.view.safeAreaInsets;

        // CarPlay's physical display reserves ~45 pt for the global sidebar.  When the
        // application scene is resized to a ~189 pt pane, UIKit keeps propagating that
        // same physical-display left safe-area into EACH pane.  The result is a second
        // 45 pt subtraction (189 -> ~144), which is exactly the squeezed content seen in
        // V6.27.  Reclaim only that inherited left inset for narrow application scenes.
        if (paneW > 0.0 && paneW < 300.0 && inherited.left > 20.0) {
            UIEdgeInsets add = root.additionalSafeAreaInsets;
            CGFloat desiredLeft = -inherited.left;
            if (fabs(add.left - desiredLeft) > 0.5 || fabs(add.top) > 0.5 || fabs(add.right) > 0.5 || fabs(add.bottom) > 0.5) {
                root.additionalSafeAreaInsets = UIEdgeInsetsMake(0.0, desiredLeft, 0.0, 0.0);
                [root.view setNeedsUpdateConstraints];
                [root.view setNeedsLayout];
                [root.view layoutIfNeeded];
                DPLog(@"SAFEAREA-FIX APPLY sid=%@ paneW=%.2f inherited=%@ additional=%@ final=%@",
                      sid, paneW, NSStringFromUIEdgeInsets(inherited),
                      NSStringFromUIEdgeInsets(root.additionalSafeAreaInsets),
                      NSStringFromUIEdgeInsets(root.view.safeAreaInsets));
            }
        } else if (paneW >= 300.0) {
            UIEdgeInsets add = root.additionalSafeAreaInsets;
            if (fabs(add.top) > 0.5 || fabs(add.left) > 0.5 || fabs(add.bottom) > 0.5 || fabs(add.right) > 0.5) {
                root.additionalSafeAreaInsets = UIEdgeInsetsZero;
                [root.view setNeedsUpdateConstraints];
                [root.view setNeedsLayout];
                [root.view layoutIfNeeded];
                DPLog(@"SAFEAREA-FIX RESTORE sid=%@ paneW=%.2f final=%@",
                      sid, paneW, NSStringFromUIEdgeInsets(root.view.safeAreaInsets));
            }
        }
    } @catch (NSException *e) {
        DPLog(@"SAFEAREA-FIX ERROR sid=%@ %@ %@", sid, e.name, e.reason);
    }
}


static void DPTemplateHostVerticalReclaimController(UIViewController *vc, CGFloat paneW, NSString *sid, NSUInteger depth) {
    if (!vc || depth > 8) return;
    @try {
        UIView *view = vc.viewIfLoaded;
        if (view && view.window) {
            UIEdgeInsets safe = view.safeAreaInsets;
            UIEdgeInsets add = vc.additionalSafeAreaInsets;

            // V6.28 fixed the duplicate 45pt LEFT safe-area, but the template content
            // still keeps a ~44pt TOP safe-area for the full-screen CarPlay chrome.
            // In a narrow half-pane this leaves the real content around 180pt tall
            // (e.g. y=52..232) even though the scene itself is 240pt tall.  Reclaim only
            // the inherited TOP inset on nested content controllers.  The actual
            // CPSNavigationBar / UITabBar remains on top, so background/main content can
            // extend behind it instead of being vertically squeezed.
            if (paneW > 0.0 && paneW < 300.0) {
                if (safe.top > 20.0 && add.top > -1.0) {
                    CGFloat desiredTop = -safe.top;
                    vc.additionalSafeAreaInsets = UIEdgeInsetsMake(desiredTop, add.left, add.bottom, add.right);
                    [view setNeedsUpdateConstraints];
                    [view setNeedsLayout];
                    [view layoutIfNeeded];
                    DPLog(@"VERTICAL-RECLAIM APPLY sid=%@ depth=%lu vc=%@ inherited=%@ additional=%@ final=%@ frame=%@",
                          sid, (unsigned long)depth, NSStringFromClass(vc.class), NSStringFromUIEdgeInsets(safe),
                          NSStringFromUIEdgeInsets(vc.additionalSafeAreaInsets), NSStringFromUIEdgeInsets(view.safeAreaInsets),
                          NSStringFromCGRect(view.frame));
                }
            } else if (paneW >= 300.0 && add.top < -0.5) {
                vc.additionalSafeAreaInsets = UIEdgeInsetsMake(0.0, add.left, add.bottom, add.right);
                [view setNeedsUpdateConstraints];
                [view setNeedsLayout];
                [view layoutIfNeeded];
                DPLog(@"VERTICAL-RECLAIM RESTORE sid=%@ depth=%lu vc=%@ final=%@ frame=%@",
                      sid, (unsigned long)depth, NSStringFromClass(vc.class),
                      NSStringFromUIEdgeInsets(view.safeAreaInsets), NSStringFromCGRect(view.frame));
            }
        }

        for (UIViewController *child in vc.childViewControllers) {
            DPTemplateHostVerticalReclaimController(child, paneW, sid, depth + 1);
        }
        UIViewController *presented = vc.presentedViewController;
        if (presented && presented.presentingViewController == vc) {
            DPTemplateHostVerticalReclaimController(presented, paneW, sid, depth + 1);
        }
    } @catch (NSException *e) {
        DPLog(@"VERTICAL-RECLAIM ERROR sid=%@ depth=%lu vc=%@ %@ %@",
              sid, (unsigned long)depth, vc ? NSStringFromClass(vc.class) : @"nil", e.name, e.reason);
    }
}


static void DPTemplateHostPolishNarrowViewTree(UIView *view, NSString *sid, CGFloat paneW, NSUInteger depth) {
    if (!view || depth > 10 || paneW <= 0.0 || paneW >= 300.0) return;
    @try {
        BOOL isYT = [sid containsString:@"com.google.ios.youtubemusic"];
        NSString *cls = NSStringFromClass(view.class);

        // DuoDash-like visual behavior: the narrow pane should use every horizontal
        // point.  Several CarPlay template wrapper views keep margins inherited from
        // the full-width template even after the scene itself has resized.  Clear only
        // wrapper/container margins; do not touch controls or labels individually.
        if ([cls isEqualToString:@"UILayoutContainerView"] ||
            [cls isEqualToString:@"UINavigationTransitionView"] ||
            [cls isEqualToString:@"UIViewControllerWrapperView"] ||
            [cls isEqualToString:@"UITransitionView"]) {
            UIEdgeInsets before = view.layoutMargins;
            if (fabs(before.left) > 0.5 || fabs(before.right) > 0.5) {
                view.preservesSuperviewLayoutMargins = NO;
                view.layoutMargins = UIEdgeInsetsMake(before.top, 0.0, before.bottom, 0.0);
                [view setNeedsLayout];
                DPLog(@"NARROW-MARGINS sid=%@ depth=%lu class=%@ before=%@ after=%@ frame=%@",
                      sid, (unsigned long)depth, cls, NSStringFromUIEdgeInsets(before),
                      NSStringFromUIEdgeInsets(view.layoutMargins), NSStringFromCGRect(view.frame));
            }
        }

        // YouTube Music exposes a vertical scroll indicator in the half-width layout.
        // DuoDash does not show this chrome.  Hide only the indicator; preserve actual
        // scrolling and contentSize so interaction remains native.
        if (isYT && [view isKindOfClass:UIScrollView.class]) {
            UIScrollView *sv = (UIScrollView *)view;
            if (sv.showsVerticalScrollIndicator) {
                sv.showsVerticalScrollIndicator = NO;
                DPLog(@"YT-SCROLLBAR-HIDE sid=%@ depth=%lu class=%@ frame=%@ content=%@ inset=%@",
                      sid, (unsigned long)depth, cls, NSStringFromCGRect(sv.frame),
                      NSStringFromCGSize(sv.contentSize), NSStringFromUIEdgeInsets(sv.contentInset));
            }
            // Remove only horizontal content inset inherited from full-screen chrome.
            UIEdgeInsets ci = sv.contentInset;
            if (fabs(ci.left) > 0.5 || fabs(ci.right) > 0.5) {
                UIEdgeInsets desired = UIEdgeInsetsMake(ci.top, 0.0, ci.bottom, 0.0);
                sv.contentInset = desired;
                sv.scrollIndicatorInsets = desired;
                DPLog(@"YT-CONTENT-INSET sid=%@ depth=%lu class=%@ before=%@ after=%@",
                      sid, (unsigned long)depth, cls, NSStringFromUIEdgeInsets(ci),
                      NSStringFromUIEdgeInsets(sv.contentInset));
            }
        }

        for (UIView *child in view.subviews) {
            DPTemplateHostPolishNarrowViewTree(child, sid, paneW, depth + 1);
        }
    } @catch (NSException *e) {
        DPLog(@"NARROW-POLISH ERROR sid=%@ depth=%lu class=%@ %@ %@",
              sid, (unsigned long)depth, view ? NSStringFromClass(view.class) : @"nil", e.name, e.reason);
    }
}

static void DPProbeTemplateHostHierarchy(UIWindowScene *ws, NSString *tag) {
    if (!ws) return;
    @try {
        NSString *proc = NSBundle.mainBundle.bundleIdentifier ?: @"?";
        NSString *sid = ws.session.persistentIdentifier ?: @"?";
        CGRect coord = ws.coordinateSpace.bounds;
        CGRect screen = ws.screen.bounds;
        DPLog(@"TEMPLATEHOST-SCENE tag=%@ proc=%@ sid=%@ role=%@ coordBounds=%@ screenBounds=%@ windows=%lu",
              tag, proc, sid, ws.session.role, NSStringFromCGRect(coord), NSStringFromCGRect(screen),
              (unsigned long)ws.windows.count);
        NSUInteger wi = 0;
        for (UIWindow *w in ws.windows) {
            UIViewController *root = w.rootViewController;
            DPTemplateHostApplySafeAreaFix(ws, w, root, sid);
            if (root && [NSStringFromClass(root.class) isEqualToString:@"CARTemplateUIApplicationSceneViewController"] &&
                [sid containsString:@":com.apple.CarPlayTemplateUIHost:"]) {
                DPTemplateHostVerticalReclaimController(root, ws.coordinateSpace.bounds.size.width, sid, 0);
                DPTemplateHostPolishNarrowViewTree(root.view, sid, ws.coordinateSpace.bounds.size.width, 0);
            }
            DPLog(@"TEMPLATEHOST-WINDOW tag=%@ sid=%@ idx=%lu class=%@ frame=%@ bounds=%@ root=%@ rootViewFrame=%@",
                  tag, sid, (unsigned long)wi, NSStringFromClass(w.class), NSStringFromCGRect(w.frame),
                  NSStringFromCGRect(w.bounds), root ? NSStringFromClass(root.class) : @"nil",
                  root.view ? NSStringFromCGRect(root.view.frame) : @"nil");
            // Non-destructive relayout poke. Do not force a synthetic frame yet; first see
            // whether TemplateUIHost receives the pane geometry from its UIWindowScene.
            [w setNeedsLayout];
            [w layoutIfNeeded];
            if (root.view) {
                [root.view setNeedsLayout];
                [root.view layoutIfNeeded];
                DPTemplateHostDumpControllerMethods(root.class);
                NSUInteger budget = 80;
                DPTemplateHostDumpViewTree(root.view, sid, 0, &budget);
                DPLog(@"TEMPLATEHOST-TRAITS sid=%@ root=%@ hSize=%ld vSize=%ld style=%ld safe=%@ preferredContentSize=%@",
                      sid, NSStringFromClass(root.class), (long)root.traitCollection.horizontalSizeClass,
                      (long)root.traitCollection.verticalSizeClass, (long)root.traitCollection.userInterfaceStyle,
                      NSStringFromUIEdgeInsets(root.view.safeAreaInsets), NSStringFromCGSize(root.preferredContentSize));
            }
            NSUInteger si = 0;
            for (UIView *v in w.subviews) {
                if (si >= 8) break;
                DPLog(@"TEMPLATEHOST-SUBVIEW tag=%@ sid=%@ w=%lu idx=%lu class=%@ frame=%@ bounds=%@",
                      tag, sid, (unsigned long)wi, (unsigned long)si, NSStringFromClass(v.class),
                      NSStringFromCGRect(v.frame), NSStringFromCGRect(v.bounds));
                si++;
            }
            wi++;
        }
    } @catch (NSException *e) {
        DPLog(@"TEMPLATEHOST-PROBE ERROR %@ %@", e.name, e.reason);
    }
}

static void DPTemplateHostScan(NSUInteger remaining) {
    if (remaining == 0) return;
    if (![NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayTemplateUIHost"]) return;
    @try {
        for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
            if (![scene isKindOfClass:UIWindowScene.class]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            NSString *sid = ws.session.persistentIdentifier ?: @"";
            if (![sid hasPrefix:@"Car["]) continue;
            DPProbeTemplateHostHierarchy(ws, @"scan");
        }
    } @catch (NSException *e) { DPLog(@"TEMPLATEHOST-SCAN ERROR %@", e.name); }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        DPTemplateHostScan(remaining - 1);
    });
}

%hook UIApplication
- (void)sendEvent:(UIEvent *)event {
    // CarPlayApp owns the split window. Reveal controls on the first touch anywhere
    // on the CarPlay surface, while preserving normal event delivery.
    if (gRunning && gSplitWindow && event.type == UIEventTypeTouches) {
        for (UITouch *touch in event.allTouches) {
            if (touch.phase == UITouchPhaseBegan) {
                DPRevealControls();
                break;
            }
        }
    }
    %orig;
}

- (void)_connectUIScene:(UIScene *)scene withOptions:(id)options {
    if (gAppProbeEnabled && [scene isKindOfClass:UIWindowScene.class]) {
        @try {
            UIWindowScene *windowScene = (UIWindowScene *)scene;
            UISceneSession *session = windowScene.session;
            DPLog(@"APPSIDE-CONNECT-PRE proc=%@ sid=%@ role=%@ coordBounds=%@ screenBounds=%@",
                  NSBundle.mainBundle.bundleIdentifier, session.persistentIdentifier, session.role,
                  NSStringFromCGRect(windowScene.coordinateSpace.bounds),
                  NSStringFromCGRect(windowScene.screen.bounds));
        } @catch (NSException *e) { DPLog(@"APPSIDE-CONNECT-PRE ERROR %@", e.reason); }
    }

    %orig;

    if ([NSBundle.mainBundle.bundleIdentifier isEqualToString:@"com.apple.CarPlayTemplateUIHost"] && [scene isKindOfClass:UIWindowScene.class]) {
        DPProbeTemplateHostHierarchy((UIWindowScene *)scene, @"connect-post");
    }

    if (!gAppProbeEnabled || ![scene isKindOfClass:UIWindowScene.class]) return;
    @try {
        UIWindowScene *windowScene = (UIWindowScene *)scene;
        UISceneSession *session = windowScene.session;
        gAppObservedCarScene = windowScene;
        gAppLastBounds = CGRectZero;
        DPAppPollSceneBounds(120);
        DPLog(@"APPSIDE-CONNECT proc=%@ sid=%@ role=%@ configName=%@ configDelegateClass=%@ orientation=%ld coordBounds=%@ screenBounds=%@",
              NSBundle.mainBundle.bundleIdentifier, session.persistentIdentifier, session.role,
              session.configuration.name, session.configuration.delegateClass,
              (long)windowScene.interfaceOrientation,
              NSStringFromCGRect(windowScene.coordinateSpace.bounds),
              NSStringFromCGRect(windowScene.screen.bounds));
    } @catch (NSException *e) { DPLog(@"APPSIDE-CONNECT PROBE ERROR %@", e.reason); }
}
%end
%ctor {
    @autoreleasepool {
        NSString *proc = NSBundle.mainBundle.bundleIdentifier;
        // Nhánh probe: KHÔNG đụng tới bất kỳ global nào của phần host-side
        // (gRecords/gControls/...) — chỉ bật cờ cho hook UIApplication ở trên.
        if ([@[@"com.apple.Maps", @"com.google.Maps", @"vn.vietmap.live", @"com.google.ios.youtubemusic", @"com.apple.CarPlayTemplateUIHost"] containsObject:proc]) {
            gAppProbeEnabled = YES;
            DPLog(@"APPSIDE PROBE ACTIVE proc=%@", proc);
            dispatch_async(dispatch_get_main_queue(), ^{
                DPAppScanConnectedScenes(180);
                if ([proc isEqualToString:@"com.apple.CarPlayTemplateUIHost"]) DPTemplateHostScan(180);
            });
            return;
        }
        if (![proc isEqualToString:@"com.apple.CarPlayApp"]) return;
        gRecords = [NSMutableDictionary dictionary]; gOrder = [NSMutableArray array];
        gControls = [DPControls new];
        dispatch_async(dispatch_get_main_queue(), ^{
            DPLog(@"CTOR MANUAL EXPERIMENT — open two apps, tap Chia; no automatic split");
            DPTick();
        });
    }
}
