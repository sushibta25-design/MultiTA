from pathlib import Path

P = Path("TweakV636.xm")
text = P.read_text(encoding="utf-8")

old = '''    DPRecord *left = gRecords[leftBundle], *right = gRecords[rightBundle];
    if (!left.valid || !right.valid) {
        DPLog(@"REFUSE invalid record left=%@(%d) right=%@(%d)",
              leftBundle, left.valid, rightBundle, right.valid);
        return;
    }
'''

new = '''    DPRecord *left = gRecords[leftBundle], *right = gRecords[rightBundle];
    if (!left.valid || !right.valid) {
        // V6.36.1: logs show TemplateUIHost controllers are often destroyed/recreated
        // exactly while the user finishes the second picker tap. V6.36 refused the
        // pair during that tiny gap even though CAPTURE of the replacement followed
        // immediately. Keep the user's bundle choice and wait for fresh records.
        static NSUInteger sRecaptureToken = 0;
        NSUInteger token = ++sRecaptureToken;
        NSString *pendingLeft = [leftBundle copy];
        NSString *pendingRight = [rightBundle copy];
        DPLog(@"WAIT-RECAPTURE begin token=%lu left=%@(%d) right=%@(%d)",
              (unsigned long)token, pendingLeft, left.valid, pendingRight, right.valid);
        __block NSUInteger attempt = 0;
        __block void (^retry)(void) = nil;
        __weak void (^weakRetry)(void);
        retry = ^{
            if (token != sRecaptureToken || gRunning || !gSession || DPDashboard() != gSession) return;
            DPRecord *freshLeft = gRecords[pendingLeft];
            DPRecord *freshRight = gRecords[pendingRight];
            DPLog(@"WAIT-RECAPTURE check token=%lu attempt=%lu left=%d right=%d",
                  (unsigned long)token, (unsigned long)attempt,
                  freshLeft.valid, freshRight.valid);
            if (freshLeft.valid && freshRight.valid) {
                DPLog(@"WAIT-RECAPTURE ready token=%lu attempt=%lu", (unsigned long)token, (unsigned long)attempt);
                ++sRecaptureToken; // cancel any stale scheduled callback from this cycle
                [self startWithLeftBundle:pendingLeft rightBundle:pendingRight];
                return;
            }
            if (++attempt >= 20) {
                DPLog(@"WAIT-RECAPTURE timeout token=%lu left=%@ right=%@", (unsigned long)token, pendingLeft, pendingRight);
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 150 * NSEC_PER_MSEC), dispatch_get_main_queue(), weakRetry);
        };
        weakRetry = retry;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 80 * NSEC_PER_MSEC), dispatch_get_main_queue(), retry);
        return;
    }
'''

if old not in text:
    raise SystemExit("wait-recapture patch failed: invalid-record block not found")
text = text.replace(old, new, 1)
text = text.replace("V6.36-scene-prime", "V6.36.1-recapture-gate")
P.write_text(text, encoding="utf-8")
print("Patched V6.36.1 wait-for-recapture gate")
