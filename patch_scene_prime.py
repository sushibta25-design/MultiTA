from pathlib import Path

SRC = Path("Tweak.xm")
OUT = Path("TweakV636.xm")
text = SRC.read_text(encoding="utf-8")

# Keep the V6.35 UI/geometry implementation intact; change only the lifecycle experiment.
text = text.replace("V6.35-auto-hide-controls", "V6.36-scene-prime")
text = text.replace("// V6.35: redesigned four controls + auto-hide after 1s; any CarPlay touch reveals them.",
                    "// V6.36: scene-prime gate derived from golden Google Maps + Vietmap traces; V6.35 UI/geometry unchanged.")

method_marker = '- (void)startWithLeftBundle:(NSString *)leftBundle rightBundle:(NSString *)rightBundle {'
method_start = text.index(method_marker)
old_start_marker = '    gOwnCall = YES;\n    @try {\n        for (DPRecord *record in gPair) {'
old_start = text.index(old_start_marker, method_start)
method_end = text.index('\n}\n@end', old_start)

replacement = r'''    // V6.36 SCENE PRIME
    // Golden trace sequence was not a fixed-delay success: Google Maps was already resident,
    // YouTube Music had just been used as an intermediate app, then Vietmap was foregrounded,
    // and only after both full CarPlayTemplateUIHost scenes were alive did Duo create views.
    // Reproduce that state deliberately. For Google+Vietmap we prefer:
    // Google -> (cached YouTube Music if available) -> Vietmap -> Google, then poll scene
    // foreground readiness. For all other pairs we prime both normally.
    BOOL (^sceneForeground)(DPRecord *) = ^BOOL(DPRecord *record) {
        if (!record || !record.valid || !record.controller) return NO;
        id scene = DPValue(record.controller, @"scene");
        id settings = DPValue(scene, @"settings");
        id value = DPValue(settings, @"foreground");
        if ([value respondsToSelector:@selector(boolValue)]) return [value boolValue];
        return DPSceneActive(record);
    };

    void (^callForeground)(DPRecord *, NSString *) = ^(DPRecord *record, NSString *tag) {
        if (!record || !record.valid || !record.controller || !gRunning || generation != gGeneration) return;
        SEL foreground = NSSelectorFromString(@"foregroundSceneWithSettings:completion:");
        if (![record.controller respondsToSelector:foreground]) {
            DPLog(@"SCENE-PRIME FOREGROUND-UNSUPPORTED tag=%@ bundle=%@", tag, record.bundle);
            return;
        }
        BOOL previousOwnCall = gOwnCall;
        gOwnCall = YES;
        @try {
            ((void(*)(id,SEL,id,id))objc_msgSend)(record.controller, foreground, record.settings, nil);
            record.nativeBackgrounded = NO;
            DPLog(@"SCENE-PRIME FOREGROUND tag=%@ bundle=%@ sid=%@", tag, record.bundle, record.sid);
        } @catch (NSException *e) {
            DPLog(@"SCENE-PRIME FOREGROUND-ERROR tag=%@ bundle=%@ error=%@", tag, record.bundle, e.name);
        }
        gOwnCall = previousOwnCall;
    };

    void (^createPresentations)(void) = ^{
        if (!gRunning || generation != gGeneration || gPair.count != 2) return;
        BOOL previousOwnCall = gOwnCall;
        gOwnCall = YES;
        @try {
            for (NSUInteger index = 0; index < gPair.count; index++) {
                DPRecord *record = gPair[index];
                record.presentationID = [NSString stringWithFormat:@"com.sushibta.duophone.%lu.%lu", (unsigned long)generation, (unsigned long)index];
                SEL create = NSSelectorFromString(@"presentationViewWithIdentifier:");
                if (![record.controller respondsToSelector:create])
                    @throw [NSException exceptionWithName:@"MissingPresentationAPI" reason:record.bundle userInfo:nil];
                id result = ((id(*)(id,SEL,id))objc_msgSend)(record.controller, create, record.presentationID);
                if (!gRunning || generation != gGeneration) { gOwnCall = previousOwnCall; return; }
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
            DPLog(@"PRESENTATION ERROR %@", e.name);
            gOwnCall = previousOwnCall;
            DPStop(@"presentation error");
            return;
        }
        gOwnCall = previousOwnCall;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 30 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 120 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ DPInspect(generation); });
    };

    // -Warc-retain-cycles canh bao runPrimeStep/pollReady tu tham chieu
    // chinh no - day la kieu block de quy AN TOAN thuong gap (co dieu kien
    // dung ro rang o primeIndex >= prime.count va attempt >= 12), khong
    // phai retain cycle that. Tat dung canh bao nay quanh doan code, khong
    // tat -Werror toan cuc.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-retain-cycles"
    DPRecord *google = nil, *vietmap = nil;
    for (DPRecord *record in gPair) {
        if ([record.bundle isEqualToString:@"com.google.Maps"]) google = record;
        if ([record.bundle isEqualToString:@"vn.vietmap.live"]) vietmap = record;
    }
    BOOL dualMaps = (google && vietmap);
    DPRecord *middle = dualMaps ? gRecords[@"com.google.ios.youtubemusic"] : nil;
    if (!middle.valid || ![DPCategoryToken(middle.sid) isEqual:DPCategoryToken(google.sid)]) middle = nil;

    DPLog(@"SCENE-PRIME BEGIN generation=%lu dualMaps=%d middle=%@ left=%@ right=%@",
          (unsigned long)generation, dualMaps, middle ? middle.bundle : @"none", left.bundle, right.bundle);

    // Build the priming sequence from the exact successful trace when possible.
    NSMutableArray<DPRecord *> *prime = [NSMutableArray array];
    if (dualMaps) {
        [prime addObject:google];
        if (middle) [prime addObject:middle];
        [prime addObject:vietmap];
        [prime addObject:google];
    } else {
        [prime addObjectsFromArray:gPair];
    }

    __block NSUInteger primeIndex = 0;
    __block void (^runPrimeStep)(void) = nil;
    __block void (^pollReady)(NSUInteger) = nil;

    pollReady = ^(NSUInteger attempt) {
        if (!gRunning || generation != gGeneration || gPair.count != 2) return;
        BOOL fg0 = sceneForeground(gPair[0]);
        BOOL fg1 = sceneForeground(gPair[1]);
        BOOL active0 = DPSceneActive(gPair[0]);
        BOOL active1 = DPSceneActive(gPair[1]);
        DPLog(@"SCENE-PRIME CHECK attempt=%lu %@ fg=%d active=%d | %@ fg=%d active=%d",
              (unsigned long)attempt,
              gPair[0].bundle, fg0, active0,
              gPair[1].bundle, fg1, active1);
        if (fg0 && fg1) {
            DPLog(@"SCENE-PRIME READY attempt=%lu", (unsigned long)attempt);
            createPresentations();
            return;
        }
        if (attempt >= 12) {
            // Do not make the feature unusable if this OS build never exposes foreground via KVC.
            // One last re-prime, then create and let RESULT/trace tell us whether the state was good.
            callForeground(gPair[0], @"timeout-left");
            callForeground(gPair[1], @"timeout-right");
            DPLog(@"SCENE-PRIME TIMEOUT fallback-create");
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 180 * NSEC_PER_MSEC), dispatch_get_main_queue(), createPresentations);
            return;
        }
        if (!fg0) callForeground(gPair[0], @"retry-left");
        if (!fg1) callForeground(gPair[1], @"retry-right");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 140 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
            pollReady(attempt + 1);
        });
    };

    runPrimeStep = ^{
        if (!gRunning || generation != gGeneration) return;
        if (primeIndex >= prime.count) {
            DPLog(@"SCENE-PRIME SEQUENCE-DONE steps=%lu", (unsigned long)prime.count);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 160 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
                pollReady(0);
            });
            return;
        }
        DPRecord *record = prime[primeIndex++];
        callForeground(record, [NSString stringWithFormat:@"step-%lu", (unsigned long)primeIndex]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 130 * NSEC_PER_MSEC), dispatch_get_main_queue(), runPrimeStep);
    };
    runPrimeStep();
#pragma clang diagnostic pop'''

text = text[:old_start] + replacement + text[method_end:]

# Sanity guards: fail CI rather than silently building an unpatched source after future edits.
required = [
    "SCENE-PRIME BEGIN",
    "SCENE-PRIME READY",
    "SCENE-PRIME TIMEOUT fallback-create",
    "V6.36-scene-prime",
]
for token in required:
    if token not in text:
        raise SystemExit(f"patch failed, missing token: {token}")
if "dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{\n        if (!gRunning || generation != gGeneration) return;\n        gOwnCall = YES;" in text[method_start:method_start+16000]:
    raise SystemExit("patch failed: old fixed-delay presentation block still present")

OUT.write_text(text, encoding="utf-8")
print(f"Generated {OUT} from {SRC} ({len(text)} bytes)")
