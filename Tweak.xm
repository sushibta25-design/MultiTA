// DuoPhone V5.0 — CarPlay split screen, chọn app cho từng pane
//
// Thay đổi lớn so với V3.9.x:
//   Bỏ toàn bộ nhánh SpringBoard (V3.3–V3.9.11, ~4000 dòng).
//   Log đã chứng minh CarPlay UI do process CarPlay quản lý qua
//   DBDisplayManager / DBDashboardRootViewController, nên
//   SBSystemShellExternalDisplaySceneManager không bao giờ được tạo
//   cho car display — hook đúng, cài sớm, nhưng không có gì để bắt.
//
// V5.0 làm mọi thứ trong process CarPlay:
//   1. Divider kéo được (đã chạy từ V3).
//   2. Chạm 2 lần vào divider -> mở picker chọn app cho pane trái/phải.
//   3. Probe DBDashboardRootViewController để biết chèn pane vào đâu.
//
// Danh sách app đọc từ:
//   /var/mobile/Library/Caches/DuoPhoneApps.plist
// dạng array các bundle id, ví dụ:
//   <array><string>com.apple.Maps</string><string>com.spotify.client</string></array>
// Không có file -> dùng danh sách mặc định bên dưới.

#import <UIKit/UIKit.h>
#import <objc/runtime.h>

#pragma mark - Hằng số

static NSString *const kTracePath =
    @"/var/mobile/DuoPhoneV5Trace.txt";
static NSString *const kAppListPath =
    @"/var/mobile/Library/Caches/DuoPhoneApps.plist";
static NSString *const kLeftKey  = @"DuoPhoneLeftApp";
static NSString *const kRightKey = @"DuoPhoneRightApp";
static NSString *const kRatioKey = @"DuoPhoneSplitRatio";

static const CGFloat kDividerVisualW = 16.0;
static const CGFloat kDividerGrabW   = 44.0;
static const CGFloat kMinRatio       = 0.30;
static const CGFloat kMaxRatio       = 0.80;
static const CGFloat kCarPlayDockW   = 45.0;

#pragma mark - Trace

static void DPLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);

    NSString *line = [NSString stringWithFormat:@"[%@:%d] %@\n",
                      NSProcessInfo.processInfo.processName ?: @"?",
                      getpid(), msg ?: @""];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];

    NSFileHandle *h = [NSFileHandle fileHandleForWritingAtPath:kTracePath];
    if (!h) { [data writeToFile:kTracePath atomically:YES]; return; }
    @try { [h seekToEndOfFile]; [h writeData:data]; [h closeFile]; }
    @catch (__unused NSException *e) {}
}

static BOOL DPIsCarPlay(void) {
    return [NSBundle.mainBundle.bundleIdentifier
            isEqualToString:@"com.apple.CarPlayApp"];
}

static CGFloat DPClamp(CGFloat v, CGFloat lo, CGFloat hi) {
    return v < lo ? lo : (v > hi ? hi : v);
}

static id DPValue(id obj, NSString *key) {
    if (!obj || !key.length) return nil;
    @try { return [obj valueForKey:key]; }
    @catch (__unused NSException *e) { return nil; }
}

#pragma mark - Trạng thái

static UIWindow *gDividerWindow = nil;
static UIView   *gDividerBar    = nil;
static UIWindow *gPickerWindow  = nil;
static CGFloat   gRatio         = 0.60;
static BOOL      gDragging      = NO;
static CGFloat   gDragStartX    = 0.0;
static BOOL      gProbeDone     = NO;

static NSString *gLeftApp  = nil;
static NSString *gRightApp = nil;

static void DPLayoutDivider(void);
static void DPShowPicker(BOOL forLeftPane);

#pragma mark - Danh sách app

static NSArray<NSString *> *DPAppList(void) {
    NSArray *fromFile = [NSArray arrayWithContentsOfFile:kAppListPath];
    if ([fromFile isKindOfClass:NSArray.class] && fromFile.count)
        return fromFile;

    return @[
        @"com.apple.Maps",
        @"com.apple.Music",
        @"com.apple.MobileSMS",
        @"com.apple.mobilephone",
        @"com.apple.podcasts",
        @"com.spotify.client",
        @"com.google.Maps",
        @"com.google.ios.youtubemusic",
        @"com.waze.iphone",
    ];
}

static NSString *DPDisplayName(NSString *bundleID) {
    // Tên rút gọn cho dễ đọc trên màn hình xe.
    NSArray *parts = [bundleID componentsSeparatedByString:@"."];
    return parts.lastObject ?: bundleID;
}

static void DPLoadPrefs(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;

    if ([d objectForKey:kRatioKey])
        gRatio = DPClamp([d doubleForKey:kRatioKey], kMinRatio, kMaxRatio);

    gLeftApp  = [d stringForKey:kLeftKey];
    gRightApp = [d stringForKey:kRightKey] ?: @"com.apple.Maps";
}

static void DPSavePrefs(void) {
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults;
    [d setDouble:gRatio forKey:kRatioKey];
    if (gLeftApp)  [d setObject:gLeftApp  forKey:kLeftKey];
    if (gRightApp) [d setObject:gRightApp forKey:kRightKey];
}

#pragma mark - Scene CarPlay

static UIWindowScene *DPCarPlayScene(void) {
    UIWindowScene *fallback = nil;

    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;

        NSString *pid = s.session.persistentIdentifier ?: @"";
        if ([pid containsString:@"DBDashboard-Car"])
            return ws;                       // đúng scene dashboard

        if (!fallback) fallback = ws;
    }
    return fallback;
}

#pragma mark - Divider

@interface DPDividerTarget : NSObject
- (void)pan:(UIPanGestureRecognizer *)g;
- (void)doubleTap:(UITapGestureRecognizer *)g;
@end

static DPDividerTarget *gTarget = nil;

@implementation DPDividerTarget

- (void)pan:(UIPanGestureRecognizer *)g {
    UIWindowScene *scene = DPCarPlayScene();
    if (!scene || !gDividerWindow) return;

    CGFloat usableW = MAX(1.0,
        CGRectGetWidth(scene.coordinateSpace.bounds) - kCarPlayDockW);

    if (g.state == UIGestureRecognizerStateBegan) {
        gDragging   = YES;
        gDragStartX = usableW * gRatio;
    }

    if (g.state == UIGestureRecognizerStateBegan ||
        g.state == UIGestureRecognizerStateChanged) {
        CGFloat dx = [g translationInView:gDividerWindow].x;
        gRatio = DPClamp((gDragStartX + dx) / usableW, kMinRatio, kMaxRatio);
        DPLayoutDivider();
    }

    if (g.state == UIGestureRecognizerStateEnded ||
        g.state == UIGestureRecognizerStateCancelled ||
        g.state == UIGestureRecognizerStateFailed) {
        gDragging = NO;
        DPSavePrefs();
        DPLog(@"V5.0 ratio=%.3f", gRatio);
    }
}

- (void)doubleTap:(UITapGestureRecognizer *)g {
    // Chạm 2 lần nửa trên -> chọn app trái; nửa dưới -> app phải.
    CGPoint p = [g locationInView:gDividerWindow];
    BOOL upper = p.y < CGRectGetHeight(gDividerWindow.bounds) * 0.5;
    DPLog(@"V5.0 picker requested pane=%@", upper ? @"LEFT" : @"RIGHT");
    DPShowPicker(upper);
}

@end

static void DPLayoutDivider(void) {
    if (!gDividerWindow) return;

    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    CGRect b = scene.coordinateSpace.bounds;
    CGFloat W = CGRectGetWidth(b), H = CGRectGetHeight(b);
    if (W <= 0 || H <= 0) return;

    CGFloat centerX = kCarPlayDockW + floor((W - kCarPlayDockW) * gRatio);

    [UIView performWithoutAnimation:^{
        gDividerWindow.frame =
            CGRectMake(centerX - kDividerGrabW * 0.5, 0, kDividerGrabW, H);
        gDividerBar.frame =
            CGRectMake((kDividerGrabW - kDividerVisualW) * 0.5, 0,
                       kDividerVisualW, H);
    }];
}

static void DPCreateDivider(void) {
    if (!DPIsCarPlay() || gDividerWindow) return;

    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    gDividerWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gDividerWindow.windowLevel     = UIWindowLevelAlert + 80.0;
    gDividerWindow.backgroundColor = UIColor.clearColor;
    gDividerWindow.rootViewController = [UIViewController new];
    gDividerWindow.rootViewController.view.backgroundColor = UIColor.clearColor;

    gDividerBar = [UIView new];
    gDividerBar.backgroundColor = [UIColor colorWithWhite:0.12 alpha:0.94];
    gDividerBar.layer.cornerRadius = kDividerVisualW * 0.5;
    gDividerBar.layer.shadowColor   = UIColor.blackColor.CGColor;
    gDividerBar.layer.shadowOpacity = 0.5;
    gDividerBar.layer.shadowRadius  = 6.0;
    [gDividerWindow.rootViewController.view addSubview:gDividerBar];

    UILabel *hint = [UILabel new];
    hint.text = @"⇄";
    hint.textColor = UIColor.whiteColor;
    hint.font = [UIFont boldSystemFontOfSize:15.0];
    hint.textAlignment = NSTextAlignmentCenter;
    hint.translatesAutoresizingMaskIntoConstraints = NO;
    [gDividerBar addSubview:hint];
    [NSLayoutConstraint activateConstraints:@[
        [hint.centerXAnchor constraintEqualToAnchor:gDividerBar.centerXAnchor],
        [hint.centerYAnchor constraintEqualToAnchor:gDividerBar.centerYAnchor],
    ]];

    gTarget = [DPDividerTarget new];

    UIPanGestureRecognizer *pan =
        [[UIPanGestureRecognizer alloc] initWithTarget:gTarget
                                                action:@selector(pan:)];
    pan.cancelsTouchesInView = NO;
    [gDividerWindow addGestureRecognizer:pan];

    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:gTarget
                                                action:@selector(doubleTap:)];
    tap.numberOfTapsRequired = 2;
    [gDividerWindow addGestureRecognizer:tap];

    DPLayoutDivider();
    gDividerWindow.hidden = NO;

    DPLog(@"V5.0 divider ready frame=%@ left=%@ right=%@",
          NSStringFromCGRect(gDividerWindow.frame),
          gLeftApp ?: @"(dashboard)", gRightApp ?: @"nil");
}

#pragma mark - Picker chọn app

@interface DPPickerVC : UIViewController
    <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic) BOOL forLeft;
@property (nonatomic, strong) NSArray<NSString *> *apps;
@end

@implementation DPPickerVC

- (void)viewDidLoad {
    [super viewDidLoad];
    self.apps = DPAppList();
    self.view.backgroundColor = [UIColor colorWithWhite:0.0 alpha:0.85];

    UILabel *title = [UILabel new];
    title.text = self.forLeft ? @"App bên trái" : @"App bên phải";
    title.textColor = UIColor.whiteColor;
    title.font = [UIFont boldSystemFontOfSize:16.0];
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:title];

    UITableView *table =
        [[UITableView alloc] initWithFrame:CGRectZero
                                     style:UITableViewStylePlain];
    table.backgroundColor = UIColor.clearColor;
    table.dataSource = self;
    table.delegate = self;
    table.rowHeight = 44.0;
    table.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:table];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    [close setTitle:@"Đóng" forState:UIControlStateNormal];
    [close addTarget:self
              action:@selector(dismissPicker)
    forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:close];

    [NSLayoutConstraint activateConstraints:@[
        [title.topAnchor constraintEqualToAnchor:self.view.topAnchor constant:6],
        [title.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],

        [table.topAnchor constraintEqualToAnchor:title.bottomAnchor constant:4],
        [table.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [table.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor],
        [table.bottomAnchor constraintEqualToAnchor:close.topAnchor],

        [close.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-4],
        [close.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
    ]];
}

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    return (NSInteger)self.apps.count;
}

- (UITableViewCell *)tableView:(UITableView *)tv
         cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *cell =
        [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle
                               reuseIdentifier:nil];
    NSString *bid = self.apps[(NSUInteger)ip.row];
    cell.textLabel.text = DPDisplayName(bid);
    cell.textLabel.textColor = UIColor.whiteColor;
    cell.detailTextLabel.text = bid;
    cell.detailTextLabel.textColor = [UIColor colorWithWhite:0.65 alpha:1.0];
    cell.backgroundColor = UIColor.clearColor;

    NSString *current = self.forLeft ? gLeftApp : gRightApp;
    cell.accessoryType = [bid isEqualToString:current]
        ? UITableViewCellAccessoryCheckmark
        : UITableViewCellAccessoryNone;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)ip {
    NSString *bid = self.apps[(NSUInteger)ip.row];

    if (self.forLeft) gLeftApp = bid;
    else              gRightApp = bid;

    DPSavePrefs();
    DPLog(@"V5.0 chose %@ for %@ pane", bid, self.forLeft ? @"LEFT" : @"RIGHT");

    [tv reloadData];
    [self dismissPicker];
}

- (void)dismissPicker {
    gPickerWindow.hidden = YES;
    gPickerWindow = nil;
}

@end

static void DPShowPicker(BOOL forLeftPane) {
    UIWindowScene *scene = DPCarPlayScene();
    if (!scene) return;

    if (gPickerWindow) { gPickerWindow.hidden = YES; gPickerWindow = nil; }

    CGRect b = scene.coordinateSpace.bounds;

    DPPickerVC *vc = [DPPickerVC new];
    vc.forLeft = forLeftPane;

    gPickerWindow = [[UIWindow alloc] initWithWindowScene:scene];
    gPickerWindow.windowLevel = UIWindowLevelAlert + 90.0;
    gPickerWindow.frame = CGRectMake(kCarPlayDockW, 0,
                                     CGRectGetWidth(b) - kCarPlayDockW,
                                     CGRectGetHeight(b));
    gPickerWindow.rootViewController = vc;
    gPickerWindow.hidden = NO;
}

#pragma mark - Probe DBDashboard (bước còn thiếu)

static void DPDumpView(UIView *v, NSInteger depth, NSString *path) {
    if (!v || depth > 6) return;

    DPLog(@"V5.0 VIEW%@ %@ frame=%@ hidden=%d alpha=%.2f sub=%lu",
          [@"" stringByPaddingToLength:(NSUInteger)depth * 2
                            withString:@" " startingAtIndex:0],
          NSStringFromClass([v class]),
          NSStringFromCGRect(v.frame),
          v.hidden, v.alpha,
          (unsigned long)v.subviews.count);

    for (UIView *c in v.subviews)
        DPDumpView(c, depth + 1,
                   [NSString stringWithFormat:@"%@/%@", path,
                    NSStringFromClass([c class])]);
}

static void DPProbeDashboard(void) {
    if (gProbeDone) return;
    gProbeDone = YES;

    DPLog(@"========== V5.0 DASHBOARD PROBE ==========");

    for (UIScene *s in UIApplication.sharedApplication.connectedScenes) {
        if (![s isKindOfClass:UIWindowScene.class]) continue;
        UIWindowScene *ws = (UIWindowScene *)s;

        NSString *pid = s.session.persistentIdentifier ?: @"";
        DPLog(@"V5.0 SCENE pid=%@ role=%@ windows=%lu",
              pid, s.session.role ?: @"nil",
              (unsigned long)ws.windows.count);

        if (![pid containsString:@"DBDashboard-Car"]) continue;

        for (UIWindow *w in ws.windows) {
            DPLog(@"V5.0 WINDOW %@ frame=%@ level=%.1f root=%@",
                  NSStringFromClass([w class]),
                  NSStringFromCGRect(w.frame), w.windowLevel,
                  w.rootViewController
                    ? NSStringFromClass([w.rootViewController class])
                    : @"nil");

            UIViewController *root = w.rootViewController;
            if (!root) continue;

            // Dump cây view + danh sách child VC của dashboard.
            DPDumpView(root.view, 0, @"root");

            for (UIViewController *child in root.childViewControllers) {
                DPLog(@"V5.0 CHILD VC %@ view=%@ frame=%@",
                      NSStringFromClass([child class]),
                      NSStringFromClass([child.view class]),
                      NSStringFromCGRect(child.view.frame));
            }

            // Các thuộc tính hay dùng để tìm container nội dung.
            for (NSString *k in @[@"contentViewController",
                                  @"dashboardViewController",
                                  @"appViewController",
                                  @"containerView",
                                  @"contentView"]) {
                id v = DPValue(root, k);
                if (v) DPLog(@"V5.0 ROOT.%@ => %@", k, NSStringFromClass([v class]));
            }
        }
    }

    DPLog(@"========== V5.0 DASHBOARD PROBE END ==========");
}

#pragma mark - Vòng lặp

static void DPTick(void) {
    if (!DPIsCarPlay()) return;

    if (!gDividerWindow) DPCreateDivider();
    if (gDividerWindow && !gDragging) DPLayoutDivider();

    if (gDividerWindow && !gProbeDone) {
        static NSUInteger ticks = 0;
        if (++ticks >= 4) DPProbeDashboard();
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 1000 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{ DPTick(); });
}

%ctor {
    @autoreleasepool {
        if (!DPIsCarPlay()) return;

        DPLoadPrefs();
        DPLog(@"CTOR V5.0 bundle=%@ ratio=%.2f",
              NSBundle.mainBundle.bundleIdentifier ?: @"nil", gRatio);

        dispatch_async(dispatch_get_main_queue(), ^{ DPTick(); });
    }
}
