// MultiTA shared keyboard. Included once by Tweak.xm after the scene helpers.
// Session-bound stop-and-wait IPC: a repeated notification cannot duplicate a key.
// Only CarPlay responders with a nonzero host-owned layout target participate.
#import <stdint.h>
#include "TATelex.hpp"

static void TAKBInsertVietnamese(UIView *input, uint32_t scalar) {
    NSString *key=[[NSString alloc] initWithBytes:&scalar length:4 encoding:NSUTF32LittleEndianStringEncoding];
    if (!key) return;
    if (![input conformsToProtocol:@protocol(UITextInput)] || !tatelex::letter(scalar) ||
        ([input respondsToSelector:@selector(isSecureTextEntry)] && [(id<UITextInputTraits>)input isSecureTextEntry])) {
        [(id<UIKeyInput>)input insertText:key]; return;
    }
    id<UITextInput> field=(id<UITextInput>)input;
    UITextRange *selection=field.selectedTextRange;
    if (!selection || !selection.empty || field.markedTextRange) { [(id<UIKeyInput>)input insertText:key]; return; }
    NSInteger offset=[field offsetFromPosition:field.beginningOfDocument toPosition:selection.start];
    UITextPosition *start=[field positionFromPosition:selection.start offset:-MIN(MAX(0,offset),64)];
    UITextRange *prefixRange=start ? [field textRangeFromPosition:start toPosition:selection.start] : nil;
    NSString *prefix=prefixRange ? [field textInRange:prefixRange] : nil;
    NSUInteger index=prefix.length;
    while (index && tatelex::letter([prefix characterAtIndex:index-1])) --index;
    NSString *word=[[prefix substringFromIndex:index] precomposedStringWithCanonicalMapping] ?: @"";
    std::u32string before;
    for (NSUInteger i=0;i<word.length;i++) before.push_back([word characterAtIndex:i]);
    std::u32string after=tatelex::append(before,scalar);
    if (after==before+std::u32string(1,scalar)) { [(id<UIKeyInput>)input insertText:key]; return; }
    NSString *replacement=[[NSString alloc] initWithBytes:after.data() length:after.size()*sizeof(char32_t) encoding:NSUTF32LittleEndianStringEncoding];
    UITextPosition *wordStart=[field positionFromPosition:selection.start offset:-(NSInteger)(prefix.length-index)];
    UITextRange *range=wordStart ? [field textRangeFromPosition:wordStart toPosition:selection.start] : nil;
    if (!range || !replacement) { [(id<UIKeyInput>)input insertText:key]; return; }
    // One native insertion replaces the selected word and triggers the app's
    // normal search/editing path. Never synthesize a series of backspaces.
    field.selectedTextRange=range;
    [(id<UIKeyInput>)input insertText:replacement];
}

static NSString *TAKBName(NSString *bundle, NSString *kind) {
    return [NSString stringWithFormat:@"com.sushibta.multita.kb.%@.%@",bundle,kind];
}
static int TAKBToken(NSString *bundle, NSString *kind) {
    static NSMutableDictionary<NSString *,NSNumber *> *tokens;
    if (!tokens) tokens=[NSMutableDictionary new];
    NSString *name=TAKBName(bundle,kind); NSNumber *old=tokens[name];
    if (old) return old.intValue;
    int token=-1; if (notify_register_check(name.UTF8String,&token)!=NOTIFY_STATUS_OK) return -1;
    tokens[name]=@(token); return token;
}
static uint64_t TAKBRead(NSString *bundle, NSString *kind) {
    int token=TAKBToken(bundle,kind); uint64_t value=0;
    if (token>=0) notify_get_state(token,&value); return value;
}
static void TAKBWrite(NSString *bundle, NSString *kind, uint64_t value) {
    int token=TAKBToken(bundle,kind);
    if (token>=0 && notify_set_state(token,value)==NOTIFY_STATUS_OK) notify_post(TAKBName(bundle,kind).UTF8String);
}
static NSString *TAKBWindowBundle(UIWindow *w) {
    NSString *sid=w.windowScene.session.persistentIdentifier ?: @"";
    if (![sid hasPrefix:@"Car["] && ![w.windowScene.session.role containsString:@"CarPlay"]) return nil;
    NSString *bundle=NSBundle.mainBundle.bundleIdentifier;
    if ([bundle isEqual:@"com.apple.CarPlayTemplateUIHost"]) {
        NSArray *parts=[sid componentsSeparatedByString:@":"];
        if (parts.count!=3) return nil;
        bundle=parts.lastObject;
    }
    if (![TAClientBundles() containsObject:bundle]) return nil;
    int token=TATargetToken(bundle); uint64_t target=0;
    if (token<0 || notify_get_state(token,&target)!=NOTIFY_STATUS_OK || !target) return nil;
    return bundle;
}
static UIView *TAKBFindInput(UIView *view, NSInteger *budget) {
    if (!view || --*budget<0) return nil;
    if (view.isFirstResponder && [view conformsToProtocol:@protocol(UIKeyInput)] &&
        [view respondsToSelector:@selector(insertText:)] && [view respondsToSelector:@selector(deleteBackward)]) return view;
    for (UIView *child in view.subviews) { UIView *found=TAKBFindInput(child,budget); if (found) return found; }
    return nil;
}
static BOOL TAKBCancelTitle(NSString *title) {
    NSString *normalized=[[title stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet] lowercaseString];
    return [@[@"hủy",@"huỷ",@"cancel"] containsObject:normalized ?: @""];
}
static void TAKBFindCancel(UIView *view, UIView *input, CGRect inputRect, NSUInteger depth,
                         NSInteger *budget, NSMutableArray<UIControl *> *matches) {
    if (!view || depth>14 || --*budget<0 || view.hidden || view.alpha<0.01 || !view.userInteractionEnabled) return;
    if ([view isKindOfClass:UIControl.class] && ((UIControl *)view).enabled && ![view isDescendantOfView:input]) {
        UIControl *control=(UIControl *)view;
        NSString *title=[view isKindOfClass:UIButton.class] ? ((UIButton *)view).currentTitle : nil;
        if (!title.length && [view isKindOfClass:UIButton.class]) title=((UIButton *)view).currentAttributedTitle.string;
        CGRect rect=[view convertRect:view.bounds toView:input.window];
        // The cancel control must share the input's search bar row. Never
        // activate a distant Cancel button belonging to navigation or a dialog.
        BOOL sameRow=fabs(CGRectGetMidY(rect)-CGRectGetMidY(inputRect))<=MAX(32,inputRect.size.height);
        if ((TAKBCancelTitle(title) || TAKBCancelTitle(view.accessibilityLabel)) && sameRow &&
            !CGRectIsEmpty(rect) && CGRectIntersectsRect(rect,input.window.bounds) &&
            (control.allControlEvents & (UIControlEventTouchUpInside|UIControlEventPrimaryActionTriggered)))
            [matches addObject:control];
    }
    for (UIView *child in view.subviews) TAKBFindCancel(child,input,inputRect,depth+1,budget,matches);
}
static BOOL TAKBCancelSearch(UIView *input) {
    // Use the search bar's actual cancel callback when it is available.
    for (UIView *view=input;view && view!=input.window;view=view.superview) {
        if (![view isKindOfClass:UISearchBar.class]) continue;
        UISearchBar *bar=(UISearchBar *)view;
        if (bar.showsCancelButton && [bar.delegate respondsToSelector:@selector(searchBarCancelButtonClicked:)]) {
            [bar.delegate searchBarCancelButtonClicked:bar];
            TALog(@"KEYBOARD CANCEL route=searchbar"); return YES;
        }
    }
    // CarPlay template search fields may not be UISearchBar. Invoke their real
    // visible Hủy/Cancel control, restricted to the responder's owning view.
    UIView *scope=nil;
    for (UIResponder *r=input.nextResponder;r;r=r.nextResponder) {
        if ([r isKindOfClass:UIViewController.class]) {
            UIView *v=((UIViewController *)r).viewIfLoaded;
            if (v.window==input.window && [input isDescendantOfView:v]) { scope=v; break; }
        }
    }
    if (!scope) scope=input.superview;
    NSMutableArray<UIControl *> *matches=[NSMutableArray new]; NSInteger budget=350;
    CGRect inputRect=[input convertRect:input.bounds toView:input.window];
    TAKBFindCancel(scope,input,inputRect,0,&budget,matches);
    if (matches.count!=1 || budget<0) {
        TALog(@"KEYBOARD CANCEL unavailable input=%@ scope=%@ matches=%lu",NSStringFromClass(input.class),NSStringFromClass(scope.class),(unsigned long)matches.count);
        return NO;
    }
    UIControl *cancel=matches.firstObject;
    UIControlEvents event=(cancel.allControlEvents & UIControlEventTouchUpInside) ? UIControlEventTouchUpInside : UIControlEventPrimaryActionTriggered;
    [cancel sendActionsForControlEvents:event];
    TALog(@"KEYBOARD CANCEL route=control class=%@",NSStringFromClass(cancel.class));
    return YES;
}
@interface TAKBClientSession : NSObject
@property(nonatomic,weak) UIView *input;
@property(nonatomic,weak) UIWindow *window;
@property(nonatomic) uint32_t nonce;
@property(nonatomic) uint16_t lastSequence;
@property(nonatomic) BOOL dismissed;
@property(nonatomic) NSTimeInterval missingSince;
@property(nonatomic,copy) NSString *preview;
@property(nonatomic) uint32_t previewVersion;
@property(nonatomic) NSUInteger previewChunks;
@end
@implementation TAKBClientSession
@end
static NSMutableDictionary<NSString *,TAKBClientSession *> *TAKBClients;
// Snapshot is a seqlock: odd revision means writing, even means complete.
// Only a bounded tail is mirrored. Editing always stays in the real responder.
static void TAKBPublishPreview(NSString *bundle, TAKBClientSession *s) {
    UIView *input=s.input; if (!s.nonce || !input) return;
    NSString *text=nil;
    if ([input respondsToSelector:@selector(isSecureTextEntry)] && [(id<UITextInputTraits>)input isSecureTextEntry]) text=@"••••";
    else if ([input isKindOfClass:UITextField.class]) text=((UITextField *)input).text ?: @"";
    else if ([input isKindOfClass:UITextView.class]) text=((UITextView *)input).text ?: @"";
    else if ([input conformsToProtocol:@protocol(UITextInput)]) {
        id<UITextInput> field=(id<UITextInput>)input;
        UITextRange *range=[field textRangeFromPosition:field.beginningOfDocument toPosition:field.endOfDocument];
        if (range) text=[field textInRange:range];
    }
    if (!text) return;
    BOOL truncated=text.length>128;
    if (truncated) {
        NSRange first=[text rangeOfComposedCharacterSequenceAtIndex:text.length-128];
        // Skip an entire composed cluster if including it would exceed the budget.
        NSUInteger start=first.location<text.length-128 ? NSMaxRange(first) : first.location;
        text=[@"…" stringByAppendingString:[text substringFromIndex:start]];
        if (text.length>128) text=[text substringFromIndex:1];
    }
    if ([s.preview isEqual:text]) return;
    uint32_t revision=(s.previewVersion+2)&0x3ffffffe;
    if (!revision) revision=2;
    uint64_t prefix=((uint64_t)s.nonce<<40);
    TAKBWrite(bundle,@"preview",prefix|((uint64_t)(revision-1)<<10));
    NSUInteger chunks=(text.length+3)/4;
    for (NSUInteger i=0;i<MAX(chunks,s.previewChunks);i++) {
        uint64_t packed=0;
        for (NSUInteger j=0;j<4 && i*4+j<text.length;j++) packed|=(uint64_t)[text characterAtIndex:i*4+j]<<(16*j);
        int token=TAKBToken(bundle,[NSString stringWithFormat:@"text-%lu",(unsigned long)i]);
        if (token<0 || notify_set_state(token,packed)!=NOTIFY_STATUS_OK) return;
    }
    s.previewVersion=revision; s.previewChunks=chunks; s.preview=text;
    TAKBWrite(bundle,@"preview",prefix|((uint64_t)revision<<10)|(uint64_t)text.length);
}
static void TAKBClearPreview(NSString *bundle, TAKBClientSession *s) {
    TAKBWrite(bundle,@"preview",0);
    for (NSUInteger i=0;i<s.previewChunks;i++) TAKBWrite(bundle,[NSString stringWithFormat:@"text-%lu",(unsigned long)i],0);
    s.preview=nil; s.previewChunks=0;
}
static NSString *TAKBReadPreview(NSString *bundle, uint32_t nonce) {
    uint64_t before=TAKBRead(bundle,@"preview");
    NSUInteger length=(NSUInteger)(before&0x1ff);
    if ((uint32_t)(before>>40)!=nonce || ((before>>10)&1) || length>128) return nil;
    unichar buffer[128]={0};
    for (NSUInteger i=0;i<(length+3)/4;i++) {
        uint64_t packed=TAKBRead(bundle,[NSString stringWithFormat:@"text-%lu",(unsigned long)i]);
        for (NSUInteger j=0;j<4 && i*4+j<length;j++) buffer[i*4+j]=(unichar)(packed>>(16*j));
    }
    if (before!=TAKBRead(bundle,@"preview")) return nil;
    return [NSString stringWithCharacters:buffer length:length];
}
static void TAKBScanClients(void) {
    NSMutableDictionary<NSString *,UIView *> *found=[NSMutableDictionary new];
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)scene).windows) {
            if (w.hidden || w.alpha<0.01) continue;
            NSString *bundle=TAKBWindowBundle(w); if (!bundle) continue;
            NSInteger budget=500; UIView *input=TAKBFindInput(w,&budget);
            if (input) found[bundle]=input;
        }
    }
    for (NSString *bundle in TAKBClients) {
        TAKBClientSession *s=TAKBClients[bundle]; UIView *input=found[bundle];
        if (input && input==s.input && input.window==s.window) {
            s.missingSince=0; TAKBPublishPreview(bundle,s); continue;
        }
        if (!input && s.nonce && !s.dismissed && [TAKBWindowBundle(s.window) isEqual:bundle]) {
            NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
            if (!s.missingSince) s.missingSince=now;
            if (now-s.missingSince<0.9) continue; // search templates can rebuild during typing
        }
        if (!input && !s.nonce) continue;
        if (s.nonce) {
            TAKBClearPreview(bundle,s);
            if (!input) TAKBWrite(bundle,@"focus",0);
        }
        s.missingSince=0; s.preview=nil;
        s.input=input; s.window=input.window; s.lastSequence=0; s.dismissed=NO;
        s.nonce=input ? arc4random_uniform(0xfffffe)+1 : 0;
        if (s.nonce) {
            TAKBPublishPreview(bundle,s);
            TAKBWrite(bundle,@"focus",s.nonce);
            TALog(@"KEYBOARD INPUT bundle=%@ class=%@ scene=%@",bundle,NSStringFromClass(input.class),s.window.windowScene.session.persistentIdentifier);
        }
    }
}
static void TAKBReceive(NSString *bundle) {
    TAKBClientSession *s=TAKBClients[bundle];
    uint64_t command=TAKBRead(bundle,@"command");
    uint32_t nonce=(uint32_t)(command>>40);
    uint16_t sequence=(uint16_t)(command>>24);
    unsigned op=(unsigned)((command>>21)&7);
    uint32_t scalar=(uint32_t)(command&0x1fffff);
    UIView *input=s.input;
    if (!command || !nonce || nonce!=s.nonce || !input.isFirstResponder ||
        input.window!=s.window || ![TAKBWindowBundle(s.window) isEqual:bundle]) return;
    if (sequence==s.lastSequence) { TAKBWrite(bundle,@"ack",command); return; }
    if (sequence!=(uint16_t)(s.lastSequence+1) || s.dismissed) return;
    BOOL accepted=YES;
    if (op==0 && scalar<=0x10ffff && !(scalar>=0xd800 && scalar<=0xdfff)) {
        NSString *text=[[NSString alloc] initWithBytes:&scalar length:sizeof(scalar) encoding:NSUTF32LittleEndianStringEncoding];
        if (text) [(id<UIKeyInput>)input insertText:text]; else accepted=NO;
    } else if (op==4 && scalar<=0x10ffff && !(scalar>=0xd800 && scalar<=0xdfff)) TAKBInsertVietnamese(input,scalar);
    else if (op==1) [(id<UIKeyInput>)input deleteBackward];
    else if (op==2) {
        if ([input isKindOfClass:UITextField.class]) {
            UITextField *field=(UITextField *)input;
            id<UITextFieldDelegate> delegate=field.delegate;
            if ([delegate respondsToSelector:@selector(textFieldShouldReturn:)]) {
                if ([delegate textFieldShouldReturn:field]) [field resignFirstResponder];
            } else [field sendActionsForControlEvents:UIControlEventEditingDidEndOnExit];
        } else [(id<UIKeyInput>)input insertText:@"\n"];
    } else if (op==3) {
        BOOL cancelled=TAKBCancelSearch(input);
        TAKBWrite(bundle,@"cancel-failed",cancelled ? 0 : command);
        if (cancelled) { s.dismissed=YES; [input resignFirstResponder]; }
    }
    else accepted=NO;
    if (accepted) { s.lastSequence=sequence; TAKBPublishPreview(bundle,s); TAKBWrite(bundle,@"ack",command); }
}
static void TAKBInstallClients(void) {
    TAKBClients=[NSMutableDictionary new];
    NSString *process=NSBundle.mainBundle.bundleIdentifier;
    for (NSString *bundle in TAClientBundles()) {
        if (![process isEqual:bundle] && ![process isEqual:@"com.apple.CarPlayTemplateUIHost"]) continue;
        TAKBClients[bundle]=[TAKBClientSession new];
        int token;
        notify_register_dispatch(TAKBName(bundle,@"command").UTF8String,&token,dispatch_get_main_queue(),^(__unused int delivered) { TAKBReceive(bundle); });
    }
    // Poll only this process's CarPlay windows, never UIApplication's global first responder.
    static dispatch_source_t timer;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,0),200*NSEC_PER_MSEC,50*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{ TAKBScanClients(); }); dispatch_resume(timer);
}

@interface TAKBController : UIViewController
@property(nonatomic,copy) NSString *bundle;
@property(nonatomic) uint32_t nonce;
@property(nonatomic) uint16_t sequence;
@property(nonatomic) NSUInteger ownerGeneration;
@property(nonatomic,strong) TARecord *record;
@property(nonatomic,strong) NSMutableArray<NSNumber *> *queue;
@property(nonatomic) uint64_t pending;
@property(nonatomic) NSUInteger retry;
@property(nonatomic) BOOL shifted;
@property(nonatomic) BOOL numbers;
@property(nonatomic) BOOL english;
@property(nonatomic) BOOL stalled;
@property(nonatomic,copy) NSString *shownText;
@property(nonatomic,strong) UILabel *heading;
@property(nonatomic,strong) UIView *panel;
@property(nonatomic,strong) UIButton *closeButton;
@property(nonatomic,strong) NSArray<NSArray<UIButton *> *> *rows;
@property(nonatomic,strong) UIView *variants;
- (void)tick;
- (void)refreshPreview;
@end
static UIWindow *TAKBWindow;
static TAKBController *TAKBHost;
static NSMutableDictionary<NSString *,NSNumber *> *TAKBConsumed;
static BOOL TAKBHostOwnerValid(void) {
    return TAKBHost && running && generation==TAKBHost.ownerGeneration &&
        (slots[0]==TAKBHost.record || slots[1]==TAKBHost.record) &&
        TAKBHost.record.scene==TAValue(TAKBHost.record.controller,@"scene");
}
static BOOL TAKBHostValid(void) {
    return TAKBHostOwnerValid() &&
        TAKBRead(TAKBHost.bundle,@"focus")==TAKBHost.nonce;
}
static void TAKBHostStop(void) {
    if (TAKBHost.bundle) {
        TAKBConsumed[TAKBHost.bundle]=@(TAKBHost.nonce);
        TAKBWrite(TAKBHost.bundle,@"command",0);
    }
    TAKBWindow.hidden=YES; TAKBWindow=nil; TAKBHost=nil;
}
@implementation TAKBController
- (UIButton *)key:(NSString *)label {
    UIButton *b=[UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:label forState:UIControlStateNormal];
    b.accessibilityLabel=label; b.accessibilityIdentifier=label;
    [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    b.backgroundColor=[UIColor colorWithRed:0.26 green:0.46 blue:0.68 alpha:1];
    b.layer.cornerRadius=7; b.titleLabel.font=[UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    b.titleLabel.adjustsFontSizeToFitWidth=YES;
    [b addTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchUpInside];
    if ([@[@"A",@"E",@"I",@"O",@"U",@"Y",@"D"] containsObject:label])
        [b addGestureRecognizer:[[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(accents:)]];
    return b;
}
- (void)loadView {
    self.view=[UIView new]; self.view.backgroundColor=[UIColor colorWithRed:0.025 green:0.10 blue:0.22 alpha:1];
    self.heading=[UILabel new]; self.heading.textColor=UIColor.whiteColor;
    self.heading.font=[UIFont systemFontOfSize:17 weight:UIFontWeightMedium];
    self.heading.lineBreakMode=NSLineBreakByTruncatingHead;
    self.heading.layer.cornerRadius=16; self.heading.layer.borderWidth=1.5;
    BOOL left=slots[0]==self.record;
    self.heading.layer.borderColor=(left ? [UIColor colorWithRed:0 green:0.8 blue:1 alpha:1] : UIColor.orangeColor).CGColor;
    self.heading.text=@"  ⌕  Tìm kiếm";
    self.heading.accessibilityLabel=left ? @"Nội dung nhập bên trái" : @"Nội dung nhập bên phải";
    [self.view addSubview:self.heading];
    self.closeButton=[self key:@"×"]; [self.view addSubview:self.closeButton];
    self.panel=[UIView new]; self.panel.backgroundColor=[UIColor colorWithWhite:0 alpha:0.3];
    self.panel.layer.cornerRadius=15; [self.view addSubview:self.panel];
    [self buildKeys];
    [self refreshPreview];
}
- (void)refreshPreview {
    if (self.stalled) return;
    NSString *text=TAKBReadPreview(self.bundle,self.nonce);
    if (text && ![self.shownText isEqual:text]) {
        self.shownText=text;
        self.heading.text=text.length ? [@"  ⌕  " stringByAppendingString:text] : @"  ⌕  Tìm kiếm";
    }
}
- (void)buildKeys {
    for (UIView *v in self.panel.subviews) [v removeFromSuperview];
    NSArray<NSArray<NSString *> *> *labels=self.numbers ?
        @[@[@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@"0"],
          @[@"-",@"/",@":",@";",@"(",@")",@"₫",@"&",@"@"],
          @[@".",@",",@"?",@"!",@"'",@"\"",@"⌫"],@[@"ABC",self.english ? @"EN" : @"VI",@"Dấu cách",@"Tìm"]] :
        @[@[@"1",@"2",@"3",@"4",@"5",@"6",@"7",@"8",@"9",@"0"],
          @[@"Q",@"W",@"E",@"R",@"T",@"Y",@"U",@"I",@"O",@"P"],
          @[@"A",@"S",@"D",@"F",@"G",@"H",@"J",@"K",@"L"],
          @[@"⇧",@"Z",@"X",@"C",@"V",@"B",@"N",@"M",@"⌫"],@[@"123",self.english ? @"EN" : @"VI",@"Dấu cách",@"Tìm"]];
    NSMutableArray *rows=[NSMutableArray new];
    for (NSArray *row in labels) {
        NSMutableArray *keys=[NSMutableArray new];
        for (NSString *label in row) {
            UIButton *b=[self key:label];
            if (!self.shifted && label.length==1 && [label rangeOfCharacterFromSet:NSCharacterSet.letterCharacterSet].location!=NSNotFound)
                [b setTitle:label.lowercaseString forState:UIControlStateNormal];
            [self.panel addSubview:b]; [keys addObject:b];
        }
        [rows addObject:keys];
    }
    self.rows=rows; [self.view setNeedsLayout];
}
- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    CGFloat w=self.view.bounds.size.width,h=self.view.bounds.size.height;
    // Compact the header/gaps in alphabet mode to make room for the digit row.
    CGFloat margin=self.numbers ? 8 : 6;
    CGFloat top=MIN(self.numbers ? 42 : 36,h*0.2);
    CGFloat gap=MAX(3,MIN(self.numbers ? 7 : 5,w/100));
    self.heading.frame=CGRectMake(margin,margin,MAX(1,w-top-3*margin),top);
    self.closeButton.frame=CGRectMake(w-margin-top,margin,top,top);
    self.panel.frame=CGRectMake(margin,top+2*margin,w-2*margin,MAX(1,h-top-3*margin));
    CGFloat pw=self.panel.bounds.size.width,ph=self.panel.bounds.size.height;
    NSUInteger rowCount=self.rows.count;
    BOOL hasDigitRow=!self.numbers;
    CGFloat digitWeight=0.8;
    CGFloat units=hasDigitRow ? (CGFloat)rowCount-1+digitWeight : (CGFloat)rowCount;
    CGFloat kh=MAX(1,(ph-(rowCount+1)*gap)/MAX(1,units));
    CGFloat kw=MAX(1,(pw-11*gap)/10), y=gap;
    for (NSUInteger r=0;r<rowCount;r++) {
        NSArray<UIButton *> *keys=self.rows[r];
        CGFloat rowHeight=(hasDigitRow && r==0) ? kh*digitWeight : kh;
        if (r==rowCount-1) {
            CGFloat small=(pw-5*gap)*0.15,space=pw-5*gap-3*small;
            keys[0].frame=CGRectMake(gap,y,small,rowHeight);
            keys[1].frame=CGRectMake(2*gap+small,y,small,rowHeight);
            keys[2].frame=CGRectMake(3*gap+2*small,y,space,rowHeight);
            keys[3].frame=CGRectMake(4*gap+2*small+space,y,small,rowHeight);
        } else {
            CGFloat start=(pw-(keys.count*kw+(keys.count-1)*gap))/2;
            for (NSUInteger i=0;i<keys.count;i++) keys[i].frame=CGRectMake(start+i*(kw+gap),y,kw,rowHeight);
        }
        y+=rowHeight+gap;
    }
    self.variants.frame=self.panel.frame;
}
- (void)enqueue:(unsigned)op scalar:(uint32_t)scalar {
    if (self.stalled || !TAKBHostValid() || self.queue.count>=128 || self.sequence==UINT16_MAX) return;
    uint64_t word=((uint64_t)self.nonce<<40)|((uint64_t)++self.sequence<<24)|((uint64_t)op<<21)|scalar;
    [self.queue addObject:@(word)]; if (!self.pending) [self tick];
}
- (void)press:(UIButton *)sender {
    NSString *label=sender.accessibilityIdentifier;
    if ([label isEqual:@"VI"] || [label isEqual:@"EN"]) { self.english=!self.english; [self buildKeys]; return; }
    if ([label isEqual:@"⇧"]) { self.shifted=!self.shifted; [self buildKeys]; return; }
    if ([label isEqual:@"123"] || [label isEqual:@"ABC"]) { self.numbers=!self.numbers; [self buildKeys]; return; }
    if ([label isEqual:@"×"]) { if (self.stalled) TAKBHostStop(); else [self enqueue:3 scalar:0]; return; }
    if ([label isEqual:@"⌫"]) { [self enqueue:1 scalar:0]; return; }
    if ([label isEqual:@"Tìm"]) { [self enqueue:2 scalar:0]; return; }
    NSString *text=[label isEqual:@"Dấu cách"] ? @" " : (self.shifted ? label : label.lowercaseString);
    NSData *data=[text dataUsingEncoding:NSUTF32LittleEndianStringEncoding];
    if (data.length==4) { uint32_t scalar=0; [data getBytes:&scalar length:4]; [self enqueue:self.english ? 0 : 4 scalar:scalar]; }
    [self.variants removeFromSuperview]; self.variants=nil;
}
- (void)accents:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state!=UIGestureRecognizerStateBegan) return;
    NSDictionary *choices=@{@"A":@"a á à ả ã ạ ă ắ ằ ẳ ẵ ặ â ấ ầ ẩ ẫ ậ",@"E":@"e é è ẻ ẽ ẹ ê ế ề ể ễ ệ",
        @"I":@"i í ì ỉ ĩ ị",@"O":@"o ó ò ỏ õ ọ ô ố ồ ổ ỗ ộ ơ ớ ờ ở ỡ ợ",
        @"U":@"u ú ù ủ ũ ụ ư ứ ừ ử ữ ự",@"Y":@"y ý ỳ ỷ ỹ ỵ",@"D":@"d đ"};
    NSString *letters=choices[gesture.view.accessibilityIdentifier]; if (!letters) return;
    [self.variants removeFromSuperview]; self.variants=[UIView new]; self.variants.frame=self.panel.frame;
    self.variants.backgroundColor=self.view.backgroundColor; [self.view addSubview:self.variants];
    NSArray *items=[[letters stringByAppendingString:@" ×"] componentsSeparatedByString:@" "];
    CGFloat w=self.variants.bounds.size.width/6,h=self.variants.bounds.size.height/4;
    for (NSUInteger i=0;i<items.count;i++) {
        UIButton *b=[self key:self.shifted ? [items[i] uppercaseString] : items[i]];
        if ([items[i] isEqual:@"×"]) { [b removeTarget:self action:@selector(press:) forControlEvents:UIControlEventTouchUpInside]; [b addTarget:self action:@selector(closeAccents) forControlEvents:UIControlEventTouchUpInside]; }
        b.frame=CGRectMake((i%6)*w+3,(i/6)*h+3,w-6,h-6); [self.variants addSubview:b];
    }
}
- (void)closeAccents { [self.variants removeFromSuperview]; self.variants=nil; }
- (void)tick {
    if (!TAKBHostValid()) { TAKBHostStop(); return; }
    [self refreshPreview];
    if (self.stalled) return;
    if (!self.pending && self.queue.count) {
        self.pending=self.queue[0].unsignedLongLongValue; self.retry=0;
        TAKBWrite(self.bundle,@"command",self.pending); return;
    }
    if (!self.pending) return;
    if (TAKBRead(self.bundle,@"ack")==self.pending) {
        BOOL close=((self.pending>>21)&7)==3;
        [self.queue removeObjectAtIndex:0]; self.pending=0;
        if (close) {
            if (TAKBRead(self.bundle,@"cancel-failed")==TAKBRead(self.bundle,@"ack")) {
                self.heading.text=@"  Chưa hủy được tìm kiếm trong app này.";
                return;
            }
            TAKBHostStop(); return;
        }
        [self tick]; return;
    }
    if (++self.retry>=15) {
        TALog(@"KEYBOARD ACK TIMEOUT bundle=%@",self.bundle);
        self.stalled=YES; [self.queue removeAllObjects]; self.pending=0;
        TAKBWrite(self.bundle,@"command",0);
        self.heading.text=@"  Ô nhập không phản hồi. Bấm × rồi mở lại.";
        return;
    }
    TAKBWrite(self.bundle,@"command",self.pending);
}
@end
static void TAKBShow(NSString *bundle) {
    uint64_t nonce=TAKBRead(bundle,@"focus");
    if (!running || !nonce || nonce>0xffffff || !splitWindow || TAAttachPending()) return;
    TARecord *r=nil; for (NSInteger i=0;i<2;i++) if ([slots[i].bundle isEqual:bundle]) r=slots[i];
    if (!r || !r.presentation || splitWindow.rootViewController.presentedViewController) return;
    if (TAKBHost && TAKBHost.nonce==nonce && [TAKBHost.bundle isEqual:bundle]) return;
    if ([TAKBConsumed[bundle] unsignedLongLongValue]==nonce) return;
    if (TAKBHostOwnerValid() && TAKBHost.record==r && [TAKBHost.bundle isEqual:bundle]) {
        // A replacement search field owns a NEW session. Drop unsent old keys,
        // but keep the full-screen UI instead of flashing back into a pane.
        TAKBHost.nonce=(uint32_t)nonce; TAKBHost.sequence=0; TAKBHost.pending=0;
        TAKBHost.retry=0; TAKBHost.stalled=NO; TAKBHost.shownText=nil;
        [TAKBHost.queue removeAllObjects]; TAKBWrite(bundle,@"command",0);
        [TAKBHost refreshPreview];
        TALog(@"KEYBOARD REBIND bundle=%@",bundle); return;
    }
    TAKBHostStop();
    TAKBHost=[TAKBController new]; TAKBHost.bundle=bundle; TAKBHost.nonce=(uint32_t)nonce;
    TAKBHost.record=r; TAKBHost.ownerGeneration=generation; TAKBHost.queue=[NSMutableArray new];
    TAKBWindow=[[UIWindow alloc] initWithWindowScene:splitWindow.windowScene];
    TAKBWindow.frame=splitWindow.windowScene.coordinateSpace.bounds;
    TAKBWindow.windowLevel=splitWindow.windowLevel+100;
    TAKBWindow.rootViewController=TAKBHost; TAKBWindow.hidden=NO;
    // Do not makeKeyWindow: the remote input must keep its focus and selection.
    floatingActions.hidden=YES;
    TAHideSideActions();
    TALog(@"KEYBOARD OPEN side=%ld bundle=%@",(long)(slots[0]==r ? 0 : 1),bundle);
}
static void TAKBInstallHost(void) {
    TAKBConsumed=[NSMutableDictionary new];
    for (NSString *bundle in TAClientBundles()) {
        int token;
        notify_register_dispatch(TAKBName(bundle,@"focus").UTF8String,&token,dispatch_get_main_queue(),^(__unused int delivered) {
            TAKBShow(bundle);
            if (TAKBHost && !TAKBHostValid()) TAKBHostStop();
        });
    }
    static dispatch_source_t timer;
    timer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER,0,0,dispatch_get_main_queue());
    dispatch_source_set_timer(timer,dispatch_time(DISPATCH_TIME_NOW,0),150*NSEC_PER_MSEC,20*NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer,^{
        if (running) {
            if (TAKBHost) TAKBShow(TAKBHost.bundle);
            else for (NSInteger i=0;i<2 && !TAKBHost;i++) if (slots[i].bundle) TAKBShow(slots[i].bundle);
        }
        [TAKBHost tick];
    }); dispatch_resume(timer);
}
