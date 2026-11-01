// Menu.mm — CoreUI stealth (from AstralCheat_fixed 20)
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "State.h"
#include <cmath>
#include <atomic>
#include <cstdint>
#include <cstring>

void CoreUI_RebuildMenu(void);

extern void CoreUI_FeaturesTick();
extern void CoreUI_EnsureFOVOverlay(UIWindow* win);

UIView* CoreUI_SecureRoot = nil;

// ─── State ───────────────────────────────────────────────────────────────────
std::atomic<bool>  g_aimbot{false};
std::atomic<bool>  g_silent{false};
std::atomic<bool>  g_aimVisible{true};
std::atomic<bool>  g_fovDraw{false};
std::atomic<bool>  g_espBox{false};
std::atomic<bool>  g_espSkel{false};
std::atomic<bool>  g_espName{false};
std::atomic<bool>  g_espHP{false};
std::atomic<bool>  g_espWeapon{false};
std::atomic<bool>  g_espBomb{true};
std::atomic<bool>  g_espGrenade{true};
std::atomic<bool>  g_espDist{false};
std::atomic<bool>  g_espTeam{true};
std::atomic<bool>  g_noRecoil{false};
std::atomic<float> g_recoilPct{0.f};
std::atomic<bool>  g_hideRec{true};
std::atomic<bool>  g_menuOpen{false};
std::atomic<float> g_fov{15.f};
std::atomic<float> g_smooth{4.5f};
std::atomic<int>   g_bone{0};
std::atomic<int>   g_lang{0};
std::atomic<uint32_t> g_menuColor{0xFF1E90FF};

// ─── Config persist (XOR-encoded binary in Library/Caches) ───────────────────
// NSUserDefaults больше не используется — ключи cui_* в Preferences plist
// открытым текстом палили чит.

static NSString* CfgPath(void) {
    static NSString* p = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString* c = NSSearchPathForDirectoriesInDomains(NSCachesDirectory,
                                                          NSUserDomainMask, YES).firstObject;
        p = [c stringByAppendingPathComponent:@".k.db"];
    });
    return p;
}
static inline uint32_t CfgK(uint32_t i) { return (i * 2654435761u) ^ 0xA5C3E1D7u; }

void CoreUI_SaveConfig(void) {
    uint32_t b[22] = {0};
    size_t n = 0;
    b[n++] = 0x4D4B4346; // magic "MKCF"
    b[n++] = (uint32_t)g_aimbot.load();
    b[n++] = (uint32_t)g_silent.load();
    b[n++] = (uint32_t)g_aimVisible.load();
    b[n++] = (uint32_t)g_fovDraw.load();
    b[n++] = (uint32_t)g_espBox.load();
    b[n++] = (uint32_t)g_espSkel.load();
    b[n++] = (uint32_t)g_espName.load();
    b[n++] = (uint32_t)g_espHP.load();
    b[n++] = (uint32_t)g_espWeapon.load();
    b[n++] = (uint32_t)g_espBomb.load();
    b[n++] = (uint32_t)g_espGrenade.load();
    b[n++] = (uint32_t)g_espDist.load();
    b[n++] = (uint32_t)g_espTeam.load();
    b[n++] = (uint32_t)g_noRecoil.load();
    b[n++] = (uint32_t)g_hideRec.load();
    { float v = g_recoilPct.load(); uint32_t u; memcpy(&u,&v,4); b[n++] = u; }
    { float v = g_fov.load();       uint32_t u; memcpy(&u,&v,4); b[n++] = u; }
    { float v = g_smooth.load();    uint32_t u; memcpy(&u,&v,4); b[n++] = u; }
    b[n++] = (uint32_t)g_bone.load();
    b[n++] = (uint32_t)g_lang.load();
    b[n++] = g_menuColor.load();
    for (size_t i = 1; i < n; i++) b[i] ^= CfgK((uint32_t)i);
    [[NSData dataWithBytes:b length:n * sizeof(uint32_t)]
        writeToFile:CfgPath() atomically:YES];
}

void CoreUI_LoadConfig(void) {
    NSData* d = [NSData dataWithContentsOfFile:CfgPath()];
    if (!d || d.length < 22 * sizeof(uint32_t)) return;
    const uint32_t* p = (const uint32_t*)d.bytes;
    uint32_t h[22] = {0};
    size_t n = d.length / sizeof(uint32_t);
    if (n > 22) n = 22;
    for (size_t i = 0; i < n; i++) h[i] = p[i] ^ (i ? CfgK((uint32_t)i) : 0);
    if (h[0] != 0x4D4B4346) return;

    g_aimbot.store(h[1] != 0);
    g_silent.store(h[2] != 0);
    g_aimVisible.store(h[3] != 0);
    g_fovDraw.store(h[4] != 0);
    g_espBox.store(h[5] != 0);
    g_espSkel.store(h[6] != 0);
    g_espName.store(h[7] != 0);
    g_espHP.store(h[8] != 0);
    g_espWeapon.store(h[9] != 0);
    g_espBomb.store(h[10] != 0);
    g_espGrenade.store(h[11] != 0);
    g_espDist.store(h[12] != 0);
    g_espTeam.store(h[13] != 0);
    g_noRecoil.store(h[14] != 0);
    g_hideRec.store(h[15] != 0);
    { float v; memcpy(&v, &h[16], 4); if (v >= 0.f && v <= 100.f) g_recoilPct.store(v);
      else if (g_noRecoil.load()) g_recoilPct.store(100.f); }
    { float v; memcpy(&v, &h[17], 4); if (v > 0.5f && v < 40.f) g_fov.store(v); }
    { float v; memcpy(&v, &h[18], 4); if (v >= 1.f && v <= 20.f) g_smooth.store(v); }
    g_bone.store((int)h[19]);
    g_lang.store((int)h[20]);
    if (h[21]) g_menuColor.store(h[21]);
}

// ─── Locale ──────────────────────────────────────────────────────────────────
static NSString* L(const char* en, const char* ru) {
    return g_lang.load() == 1 ? [NSString stringWithUTF8String:ru]
                              : [NSString stringWithUTF8String:en];
}

static UIColor* Accent() {
    return [UIColor colorWithRed:0.86 green:0.15 blue:0.15 alpha:1];
}
static UIColor* AccentGold() {
    return [UIColor colorWithRed:1.0 green:0.78 blue:0.10 alpha:1];
}
static UIColor* C(CGFloat r,CGFloat g,CGFloat b,CGFloat a){
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// ─── Drag ────────────────────────────────────────────────────────────────────
@interface CoreUIDrag : NSObject
+ (void)attach:(UIView*)v;
@end
@implementation CoreUIDrag
+ (void)attach:(UIView*)v {
    if (!v) return;
    for (UIGestureRecognizer* g in v.gestureRecognizers) {
        if ([g isKindOfClass:UIPanGestureRecognizer.class]) return;
    }
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(onPan:)];
    pan.maximumNumberOfTouches = 1;
    [v addGestureRecognizer:pan];
}
+ (void)onPan:(UIPanGestureRecognizer*)pan {
    UIView* v = pan.view;
    if (!v) return;
    CGPoint tr = [pan translationInView:v.superview];
    if (pan.state == UIGestureRecognizerStateBegan || pan.state == UIGestureRecognizerStateChanged) {
        CGPoint c = v.center;
        c.x += tr.x; c.y += tr.y;
        CGRect sb = v.superview.bounds;
        CGFloat hw = v.bounds.size.width * 0.5;
        CGFloat hh = v.bounds.size.height * 0.5;
        c.x = MAX(hw, MIN(sb.size.width - hw, c.x));
        c.y = MAX(hh, MIN(sb.size.height - hh, c.y));
        v.center = c;
        [pan setTranslation:CGPointZero inView:v.superview];
    }
}
@end


@interface SecurePassField : UITextField @end
@implementation SecurePassField
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* h = [super hitTest:point withEvent:event];
    if (!h || h == self) return nil;
    extern UIView* g_panel_ref(void);
    extern UIView* g_fab_ref(void);
    UIView* panel = g_panel_ref();
    UIView* fab = g_fab_ref();
    for (UIView* v = h; v; v = v.superview) {
        if (v == fab || v == panel) return h;
    }
    return nil;
}
- (BOOL)canBecomeFirstResponder { return NO; }
@end


@interface PassThroughView : UIView @end
@implementation PassThroughView
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* h = [super hitTest:point withEvent:event];
    return (h == self) ? nil : h;
}
@end

@interface ACW : UIWindow @end
@implementation ACW
- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        if (@available(iOS 13.0, *))
            self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    return self;
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    extern UIView* g_panel_ref(void);
    extern UIView* g_fab_ref(void);
    UIView* panel = g_panel_ref();
    UIView* fab = g_fab_ref();
    if (fab && !fab.hidden && fab.alpha > 0.01f) {
        CGPoint p = [self convertPoint:point toView:fab];
        if (CGRectContainsPoint(fab.bounds, p)) return YES;
    }
    if (panel && !panel.hidden && panel.alpha > 0.01f) {
        CGPoint p = [self convertPoint:point toView:panel];
        if (CGRectContainsPoint(panel.bounds, p)) return YES;
    }
    return NO;
}
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (![self pointInside:point withEvent:event]) return nil;
    extern UIView* g_panel_ref(void);
    extern UIView* g_fab_ref(void);
    UIView* panel = g_panel_ref();
    UIView* fab = g_fab_ref();
    if (fab && !fab.hidden) {
        CGPoint p = [self convertPoint:point toView:fab];
        if (CGRectContainsPoint(fab.bounds, p)) {
            UIView* h = [fab hitTest:p withEvent:event];
            return h ?: fab;
        }
    }
    if (panel && !panel.hidden && panel.alpha > 0.01f) {
        CGPoint p = [self convertPoint:point toView:panel];
        if (CGRectContainsPoint(panel.bounds, p)) {
            UIView* h = [panel hitTest:p withEvent:event];
            return h ?: panel;
        }
    }
    return nil;
}
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFirstResponder { return NO; }
@end

@interface ACVC : UIViewController @end
@implementation ACVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (BOOL)prefersHomeIndicatorAutoHidden { return NO; }
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures { return UIRectEdgeNone; }
- (BOOL)prefersStatusBarHidden { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
    self.view.userInteractionEnabled = YES;
    if (@available(iOS 13.0, *))
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
}
- (void)loadView {
    PassThroughView* v = [[PassThroughView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    v.backgroundColor = UIColor.clearColor;
    self.view = v;
}
@end

// ─── Globals ─────────────────────────────────────────────────────────────────
static UIWindow*     g_hostWin = nil;
static UIWindow*     g_drawWin = nil;
static UIView*       g_panel   = nil;
static UIView*       g_fab     = nil;
static UIView*       g_content = nil;

UIView* g_panel_ref(void) { return g_panel; }
UIView* g_fab_ref(void) { return g_fab; }

static UIScrollView* g_scroll  = nil;
static CADisplayLink* g_tick   = nil;
static UITextField*  g_secureField = nil;
static int           g_section = 0;
static NSArray<UIButton*>* g_tabBtns = nil;


static CGFloat FC_BottomInset(UIView* v) {
    CGFloat inset = 34.f;
    if (@available(iOS 11.0, *)) {
        if (v.safeAreaInsets.bottom > 1.f) inset = v.safeAreaInsets.bottom;
    }
    return inset;
}

static CGRect FC_DrawFrame(UIWindow* key) {
    CGRect b = key && key.bounds.size.width > 2 ? key.bounds : UIScreen.mainScreen.bounds;
    b.origin = CGPointZero;
    CGFloat bot = 40.f;
    if (@available(iOS 11.0, *)) {
        UIEdgeInsets s = key ? key.safeAreaInsets : UIEdgeInsetsZero;
        if (s.bottom > 1.f) bot = s.bottom + 6.f;
    }
    b.size.height = MAX(1.f, b.size.height - bot);
    return b;
}

static CGRect FC_FrameAboveHome(UIView* host) {
    CGRect b = host.bounds;
    if (b.size.width < 2) b = UIScreen.mainScreen.bounds;
    b.origin = CGPointZero;
    return b;
}


// ─── Hide recording ──────────────────────────────────────────────────────────
static UITextField* FC_SecureTF(void) {
    if (!g_secureField) {
        g_secureField = [[SecurePassField alloc] initWithFrame:CGRectMake(0,0,1,1)];
        g_secureField.secureTextEntry = YES;
        g_secureField.backgroundColor = UIColor.clearColor;
        if (@available(iOS 13.0, *))
            g_secureField.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    g_secureField.secureTextEntry = YES;
    return g_secureField;
}

static UIView* FC_SecureContainer(UIView* root) {
    UITextField* tf = FC_SecureTF();
    CGRect full = UIScreen.mainScreen.bounds;
    full.origin = CGPointZero;
    tf.frame = full;
    tf.secureTextEntry = YES;
    tf.userInteractionEnabled = YES;

    if (tf.superview != root)
        [root insertSubview:tf atIndex:0];
    [tf setNeedsLayout];
    [tf layoutIfNeeded];

    UIView* c = nil;
    for (UIView* v in tf.subviews) {
        NSString* n = NSStringFromClass(v.class);
        if ([n containsString:@"Canvas"] || [n containsString:@"Content"] ||
            [n containsString:@"Text"] || [n containsString:@"Secure"]) {
            c = v; break;
        }
    }
    if (!c && tf.subviews.count)
        c = tf.subviews.firstObject;
    if (!c) return nil;

    c.frame = tf.bounds;
    c.userInteractionEnabled = YES;
    c.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    CoreUI_SecureRoot = c;
    return c;
}

static void FC_MoveInto(UIView* child, UIView* parent) {
    if (!child || !parent) return;
    if (child.superview != parent) {
        CGRect f = child.frame;
        [child removeFromSuperview];
        [parent addSubview:child];
        child.frame = f;
    }
}

static void applyHideRec(UIView* root) {
    if (!root) return;
    BOOL on = g_hideRec.load();
    extern UIView* g_esp_view(void);
    UIView* esp = g_esp_view();

    if (on) {
        UIView* c = FC_SecureContainer(root);
        if (!c) return;
        CGRect scr = UIScreen.mainScreen.bounds;
        scr.origin = CGPointZero;
        if (esp) {
            FC_MoveInto(esp, c);
            esp.frame = scr;
            esp.userInteractionEnabled = NO;
        }
        if (g_fab) {
            FC_MoveInto(g_fab, c);
            [c bringSubviewToFront:g_fab];
            g_fab.hidden = NO;
            g_fab.alpha = 1;
            g_fab.userInteractionEnabled = YES;
        }
        if (g_panel) {
            FC_MoveInto(g_panel, c);
            [c bringSubviewToFront:g_panel];
            g_panel.userInteractionEnabled = YES;
        }
        if (g_secureField)
            [root sendSubviewToBack:g_secureField];
    } else {
        CoreUI_SecureRoot = nil;
        if (esp) {
            FC_MoveInto(esp, root);
            CGRect scr = UIScreen.mainScreen.bounds;
            scr.origin = CGPointZero;
            esp.frame = scr;
        }
        if (g_fab) {
            FC_MoveInto(g_fab, root);
            [root bringSubviewToFront:g_fab];
        }
        if (g_panel) {
            FC_MoveInto(g_panel, root);
            [root bringSubviewToFront:g_panel];
        }
        if (g_secureField) {
            [g_secureField removeFromSuperview];
            g_secureField = nil;
        }
    }
    CoreUI_EnsureFOVOverlay(g_hostWin);
}




static UIView* makeSwitch(NSString* title, NSString* sub, bool on, void(^cb)(bool)) {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0,0,300,54)];
    row.backgroundColor = C(0.06,0.08,0.14,0.95);
    row.layer.cornerRadius = 12;
    row.layer.borderWidth = 1;
    row.layer.borderColor = [Accent() colorWithAlphaComponent:0.35].CGColor;

    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(14,8,200,18)];
    t.text = title; t.textColor = UIColor.whiteColor;
    t.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    [row addSubview:t];

    UILabel* s = [[UILabel alloc] initWithFrame:CGRectMake(14,28,200,16)];
    s.text = sub; s.textColor = C(0.55,0.65,0.8,1);
    s.font = [UIFont systemFontOfSize:11];
    s.tag = 99;
    [row addSubview:s];

    UISwitch* sw = [[UISwitch alloc] initWithFrame:CGRectMake(240,11,51,31)];
    sw.transform = CGAffineTransformMakeScale(0.85, 0.85);
    sw.on = on;
    sw.onTintColor = Accent();
    [sw addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
        cb(((UISwitch*)a.sender).on);
    }] forControlEvents:UIControlEventValueChanged];
    [row addSubview:sw];
    return row;
}

static UIView* makeSlider(NSString* title, float val, float mn, float mx, void(^cb)(float)) {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0,0,300,64)];
    row.backgroundColor = C(0.06,0.08,0.14,0.95);
    row.layer.cornerRadius = 12;
    row.layer.borderWidth = 1;
    row.layer.borderColor = [Accent() colorWithAlphaComponent:0.35].CGColor;

    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(14,6,160,16)];
    t.text = title; t.textColor = C(0.7,0.8,0.95,1);
    t.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [row addSubview:t];

    UILabel* vlab = [[UILabel alloc] initWithFrame:CGRectMake(220,6,66,16)];
    vlab.text = [NSString stringWithFormat:@"%.0f", val];
    vlab.textColor = UIColor.whiteColor;
    vlab.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightBold];
    vlab.textAlignment = NSTextAlignmentRight;
    vlab.tag = 77;
    [row addSubview:vlab];

    UISlider* sl = [[UISlider alloc] initWithFrame:CGRectMake(14,30,272,28)];
    sl.minimumValue = mn; sl.maximumValue = mx; sl.value = val;
    sl.minimumTrackTintColor = Accent();
    sl.maximumTrackTintColor = C(0.2,0.22,0.3,1);
    [sl addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
        float v = ((UISlider*)a.sender).value;
        vlab.text = [NSString stringWithFormat:@"%.0f", v];
        cb(v);
    }] forControlEvents:UIControlEventValueChanged];
    [row addSubview:sl];
    return row;
}

static UIView* makeSegment(NSString* title, NSArray* items, int sel, void(^cb)(int)) {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0,0,300,64)];
    row.backgroundColor = C(0.06,0.08,0.14,0.95);
    row.layer.cornerRadius = 12;
    row.layer.borderWidth = 1;
    row.layer.borderColor = [Accent() colorWithAlphaComponent:0.35].CGColor;

    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(14,6,272,16)];
    t.text = title; t.textColor = C(0.7,0.8,0.95,1);
    t.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [row addSubview:t];

    UISegmentedControl* seg = [[UISegmentedControl alloc] initWithItems:items];
    seg.frame = CGRectMake(14,28,272,28);
    seg.selectedSegmentIndex = sel;
    seg.selectedSegmentTintColor = Accent();
    [seg setTitleTextAttributes:@{NSForegroundColorAttributeName:UIColor.whiteColor} forState:UIControlStateNormal];
    [seg addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
        cb((int)((UISegmentedControl*)a.sender).selectedSegmentIndex);
    }] forControlEvents:UIControlEventValueChanged];
    [row addSubview:seg];
    return row;
}

static UIView* makeColorRow(NSString* title) {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0,0,300,54)];
    row.backgroundColor = C(0.06,0.08,0.14,0.95);
    row.layer.cornerRadius = 12;
    row.layer.borderWidth = 1;
    row.layer.borderColor = [Accent() colorWithAlphaComponent:0.35].CGColor;

    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(14,18,100,18)];
    t.text = title; t.textColor = UIColor.whiteColor;
    t.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [row addSubview:t];

    NSArray* colors = @[
        @0xFF1E90FFu, @0xFF00E5FFu, @0xFF7C4DFFu,
        @0xFFFF2D55u, @0xFF30D158u, @0xFFFF9F0Au
    ];
    CGFloat x = 120;
    for (NSNumber* n in colors) {
        uint32_t col = n.unsignedIntValue;
        UIButton* b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(x, 12, 28, 28);
        b.backgroundColor = [UIColor colorWithRed:((col>>16)&0xFF)/255.f
                                            green:((col>>8)&0xFF)/255.f
                                             blue:(col&0xFF)/255.f alpha:1];
        b.layer.cornerRadius = 14;
        b.layer.borderWidth = 2;
        b.layer.borderColor = UIColor.whiteColor.CGColor;
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
            g_menuColor.store(col);
            extern void CoreUI_RebuildMenu(void);
            CoreUI_RebuildMenu();
        }] forControlEvents:UIControlEventTouchUpInside];
        [row addSubview:b];
        x += 30;
    }
    return row;
}

// ─── Rebuild content for current section ─────────────────────────────────────
static void rebuildContent() {
    if (!g_content) return;
    for (UIView* v in g_content.subviews) [v removeFromSuperview];
    CGFloat y = 10;
    auto add = [&](UIView* row) {
        row.frame = CGRectMake(10, y, 300, row.bounds.size.height);
        [g_content addSubview:row];
        y += row.bounds.size.height + 8;
    };

    if (g_section == 0) { // Aim tab
        add(makeSwitch(L("Aim bot","Аимбот"),
                       L("Soft aim at enemies","Плавный аим"),
                       g_aimbot.load(), ^(bool v){ g_aimbot=v; if(v) g_silent=false; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("FOV Circle","Круг FOV"),
                       L("Show FOV (does not block UI)","FOV без блока UI"),
                       g_fovDraw.load(), ^(bool v){ g_fovDraw=v; CoreUI_SaveConfig(); }));
        add(makeSlider(L("FOV","FOV"), g_fov.load(), 1, 30, ^(float v){ g_fov=v; CoreUI_SaveConfig(); }));
        add(makeSlider(L("Smooth","Плавность"), g_smooth.load(), 1, 20, ^(float v){ g_smooth=v; CoreUI_SaveConfig(); }));
        add(makeSegment(L("Bone","Кость"),
                        @[L("Head","Голова"), L("Neck","Шея"), L("Chest","Грудь")],
                        g_bone.load(), ^(int v){ g_bone=v; CoreUI_SaveConfig(); }));
    }
    else if (g_section == 1) { // Silent tab
        add(makeSwitch(L("Silent aim","Сайлент"),
                       L("Instant aim (separate from soft)","Мгновенный аим"),
                       g_silent.load(), ^(bool v){ g_silent=v; if(v) g_aimbot=false; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("FOV Circle","Круг FOV"),
                       L("Show FOV","Показать FOV"),
                       g_fovDraw.load(), ^(bool v){ g_fovDraw=v; CoreUI_SaveConfig(); }));
        add(makeSlider(L("FOV","FOV"), g_fov.load(), 1, 30, ^(float v){ g_fov=v; CoreUI_SaveConfig(); }));
        add(makeSegment(L("Bone","Кость"),
                        @[L("Head","Голова"), L("Neck","Шея"), L("Chest","Грудь")],
                        g_bone.load(), ^(int v){ g_bone=v; CoreUI_SaveConfig(); }));
    }
    else if (g_section == 2) { // ESP
        add(makeSwitch(L("Box","Бокс"), L("White box","Белый бокс"),
                       g_espBox.load(), ^(bool v){ g_espBox=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Skeleton","Скелет"), L("Bones","Кости"),
                       g_espSkel.load(), ^(bool v){ g_espSkel=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Name","Имя"), L("Player name","Имя игрока"),
                       g_espName.load(), ^(bool v){ g_espName=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("HP / Armor","ХП / Броня"), L("Bars left of box","Полоски слева"),
                       g_espHP.load(), ^(bool v){ g_espHP=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Weapon / Ammo","Оружие / Патроны"), L("Under box","Под боксом"),
                       g_espWeapon.load(), ^(bool v){ g_espWeapon=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Bomb + timer","Бомба + таймер"), L("Planted C4","Плантед C4"),
                       g_espBomb.load(), ^(bool v){ g_espBomb=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Smoke + timer","Смоук + таймер"), L("No molly ESP","Без молика"),
                       g_espGrenade.load(), ^(bool v){ g_espGrenade=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Distance","Дистанция"), L("Meters","Метры"),
                       g_espDist.load(), ^(bool v){ g_espDist=v; CoreUI_SaveConfig(); }));
        add(makeSwitch(L("Team check","Свои"), L("Ignore teammates","Игнор союзников"),
                       g_espTeam.load(), ^(bool v){ g_espTeam=v; CoreUI_SaveConfig(); }));
    }
    else if (g_section == 3) { // Misc
        add(makeSwitch(L("No Recoil","Без отдачи"),
                       L("Safe multipliers only","Только множители"),
                       g_noRecoil.load(), ^(bool v){
                           g_noRecoil=v;
                           if (v && g_recoilPct.load() < 1.f) g_recoilPct.store(100.f);
                           CoreUI_SaveConfig();
                       }));
        add(makeSlider(L("Recoil %","Отдача %"),
                       g_recoilPct.load(), 0, 100, ^(float v){
                           g_recoilPct=v;
                           if (v >= 1.f) g_noRecoil.store(true);
                           CoreUI_SaveConfig();
                       }));
        add(makeSwitch(L("Hide recording","Скрытие записи"),
                       L("FLAG_SECURE menu/ESP","Скрыть на записи"),
                       g_hideRec.load(), ^(bool v){
                           g_hideRec=v; CoreUI_SaveConfig();
                           UIView* root = g_hostWin ? g_hostWin.rootViewController.view : nil;
                           applyHideRec(root);
                       }));
    }
    else { // Config
        add(makeSegment(L("Language","Язык"),
                        @[@"English", @"Русский"],
                        g_lang.load(), ^(int v){
                            g_lang=v;
                            extern void CoreUI_RebuildMenu(void);
                            CoreUI_RebuildMenu();
                        }));
        add(makeColorRow(L("Menu color","Цвет меню")));
        add(makeSwitch(L("Menu open","Меню открыто"),
                       L("Show panel","Показать панель"),
                       g_menuOpen.load(), ^(bool v){
                           g_menuOpen=v;
                           g_panel.hidden = !v;
                       }));
    }

    g_content.frame = CGRectMake(0, 0, 320, y + 10);
    g_scroll.contentSize = CGSizeMake(320, y + 20);
}

void CoreUI_RebuildMenu(void) {
    if (g_tabBtns) {
        NSArray* titles = g_lang.load()==1
            ? @[@"Аим", @"Сайлент", @"ESP", @"Разное", @"Cfg"]
            : @[@"Aim", @"Silent", @"ESP", @"Misc", @"Cfg"];
        for (int i = 0; i < (int)g_tabBtns.count && i < (int)titles.count; i++) {
            [g_tabBtns[i] setTitle:titles[i] forState:UIControlStateNormal];
            g_tabBtns[i].backgroundColor = (i==g_section) ? Accent() : C(0.1,0.12,0.2,1);
        }
    }
    if (g_panel) {
        g_panel.layer.borderColor = [Accent() colorWithAlphaComponent:0.5].CGColor;
    }
    rebuildContent();
}

// ─── Build panel once ────────────────────────────────────────────────────────
static void buildPanel(UIView* host) {
    if (g_panel) return;

    CGFloat pw = 340, ph = 420;
    g_panel = [[UIView alloc] initWithFrame:CGRectMake(16, 50, pw, ph)];
    g_panel.backgroundColor = C(0.05,0.06,0.10,0.97);
    g_panel.layer.cornerRadius = 18;
    g_panel.layer.borderWidth = 1.2;
    g_panel.layer.borderColor = [Accent() colorWithAlphaComponent:0.55].CGColor;
    g_panel.layer.shadowColor = Accent().CGColor;
    g_panel.layer.shadowOpacity = 0.45;
    g_panel.layer.shadowRadius = 20;
    g_panel.clipsToBounds = NO;
    CAGradientLayer* grad = [CAGradientLayer layer];
    grad.frame = CGRectMake(0,0,340,420);
    grad.cornerRadius = 18;
    grad.colors = @[
        (id)[Accent() colorWithAlphaComponent:0.22].CGColor,
        (id)[UIColor colorWithWhite:0.05 alpha:0.95].CGColor,
        (id)[Accent() colorWithAlphaComponent:0.12].CGColor
    ];
    grad.startPoint = CGPointMake(0,0);
    grad.endPoint = CGPointMake(1,1);
    [g_panel.layer insertSublayer:grad atIndex:0];
    CABasicAnimation* sh = [CABasicAnimation animationWithKeyPath:@"locations"];
    sh.fromValue = @[@0.0, @0.35, @0.7];
    sh.toValue = @[@0.3, @0.65, @1.0];
    sh.duration = 3.5;
    sh.autoreverses = YES;
    sh.repeatCount = HUGE_VALF;
    grad.locations = @[@0.0, @0.45, @1.0];
    [grad addAnimation:sh forKey:@"shim"];
    g_panel.hidden = YES;
    g_panel.alpha = 0;

    UILabel* logo = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 28)];
    logo.text = @"mark";
    logo.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    logo.textColor = Accent();
    [g_panel addSubview:logo];
    UILabel* sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 36, 280, 16)];
    sub.text = @"v2.5  ·  beta";
    sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightMedium];
    sub.textColor = [UIColor colorWithWhite:0.7 alpha:1];
    [g_panel addSubview:sub];

    NSArray* titles = @[@"Aim", @"Silent", @"ESP", @"Misc", @"Cfg"];
    NSMutableArray* btns = [NSMutableArray array];
    CGFloat tx = 8, ty = 58;
    for (int i = 0; i < 5; i++) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(tx, ty, 62, 30);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        b.backgroundColor = (i==0) ? Accent() : C(0.1,0.12,0.2,1);
        b.layer.cornerRadius = 8;
        b.tag = i;
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
            g_section = (int)((UIView *)a.sender).tag;
            for (UIButton* bb in g_tabBtns)
                bb.backgroundColor = (bb.tag==g_section) ? Accent() : C(0.1,0.12,0.2,1);
            rebuildContent();
        }] forControlEvents:UIControlEventTouchUpInside];
        [g_panel addSubview:b];
        [btns addObject:b];
        tx += 64;
    }
    g_tabBtns = btns;

    g_scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 100, 320, ph-110)];
    g_scroll.showsVerticalScrollIndicator = YES;
    g_scroll.alwaysBounceVertical = YES;
    [g_panel addSubview:g_scroll];

    g_content = [[UIView alloc] initWithFrame:CGRectMake(0,0,320,300)];
    [g_scroll addSubview:g_content];

    [host addSubview:g_panel];
    [CoreUIDrag attach:g_panel];
    rebuildContent();
}

@interface FabToggle : NSObject
+ (instancetype)shared;
- (void)toggle;
@end
@implementation FabToggle
+ (instancetype)shared {
    static FabToggle* s; static dispatch_once_t o;
    dispatch_once(&o, ^{ s = [FabToggle new]; });
    return s;
}
- (void)toggle {
    extern UIView* g_panel_ref(void);
    bool open = !g_menuOpen.load();
    g_menuOpen = open;
    UIView* panel = g_panel_ref();
    if (!panel) return;
    panel.hidden = NO;
    [panel.superview bringSubviewToFront:panel];
    [UIView animateWithDuration:0.18 animations:^{
        panel.alpha = open ? 1.0 : 0.0;
        panel.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.96, 0.96);
    } completion:^(BOOL finished) {
        if (!open) panel.hidden = YES;
    }];
}
@end

static void buildFab(UIView* host) {
    if (g_fab) return;
    g_fab = [[UIView alloc] initWithFrame:CGRectMake(2, 2, 48, 48)];
    g_fab.backgroundColor = Accent();
    g_fab.layer.cornerRadius = 24;
    g_fab.layer.borderWidth = 2;
    g_fab.layer.borderColor = [UIColor colorWithRed:1 green:0.78 blue:0.1 alpha:1].CGColor;
    g_fab.layer.shadowColor = Accent().CGColor;
    g_fab.layer.shadowOpacity = 0.35;
    g_fab.layer.shadowRadius = 10;
    g_fab.alpha = 1.0;
    g_fab.hidden = NO;
    g_fab.userInteractionEnabled = YES;
    UILabel* star = [[UILabel alloc] initWithFrame:g_fab.bounds];
    star.text = @"M";
    star.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBlack];
    star.textAlignment = NSTextAlignmentCenter;
    star.textColor = UIColor.whiteColor;
    star.userInteractionEnabled = NO;
    [g_fab addSubview:star];
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = g_fab.bounds;
    btn.accessibilityLabel = @"menu";
    [btn addTarget:[FabToggle shared] action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [g_fab addSubview:btn];
    [host addSubview:g_fab];

    @try {
        NSString* doc = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
        NSString* ip = [doc stringByAppendingPathComponent:@"fab_icon.jpeg"];
        UIImage* im = [UIImage imageWithContentsOfFile:ip];
        if (im) {
            for (UIView* s in g_fab.subviews) if ([s isKindOfClass:UILabel.class]) s.hidden = YES;
            UIImageView* iv = [[UIImageView alloc] initWithFrame:CGRectInset(g_fab.bounds, 4, 4)];
            iv.image = im;
            iv.contentMode = UIViewContentModeScaleAspectFill;
            iv.clipsToBounds = YES;
            iv.layer.cornerRadius = 16;
            iv.userInteractionEnabled = NO;
            [g_fab insertSubview:iv atIndex:0];
        }
    } @catch (...) {}

}

// ─── Bootstrap ───────────────────────────────────────────────────────────────
@interface ACH : NSObject @end
@implementation ACH
+ (void)start {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dispatch_async(dispatch_get_main_queue(), ^{
            [self tryAttach];
        });
    });
}
+ (UIWindow*)gameWindow {
    UIWindow* key = nil;
    for (UIScene* sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* w in ((UIWindowScene*)sc).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        key = UIApplication.sharedApplication.keyWindow;
#pragma clang diagnostic pop
    }
    return key;
}

+ (void)tryAttach {
    static dispatch_once_t onceCfg;
    dispatch_once(&onceCfg, ^{ CoreUI_LoadConfig(); });
    UIWindow* key = [self gameWindow];
    if (!key) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self tryAttach]; });
        return;
    }

    if (!g_hostWin || ![g_hostWin isKindOfClass:[ACW class]]) {
        CGRect f = key.bounds;
        if (f.size.width < 2) f = UIScreen.mainScreen.bounds;
        CGFloat bot = 34.f;
        if (@available(iOS 11.0, *)) {
            if (key.safeAreaInsets.bottom > 1.f) bot = key.safeAreaInsets.bottom;
        }
        f.size.height = MAX(1.f, f.size.height - bot);
        ACW* ov = [[ACW alloc] initWithFrame:f];
        ov.windowLevel = UIWindowLevelNormal + 1;
        ov.backgroundColor = UIColor.clearColor;
        if (@available(iOS 13.0, *)) {
            ov.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
            if (key.windowScene) ov.windowScene = key.windowScene;
        }
        ACVC* vc = [ACVC new];
        ov.rootViewController = vc;
        vc.view.backgroundColor = UIColor.clearColor;
        ov.userInteractionEnabled = YES;
        ov.hidden = NO;
        g_hostWin = ov;
    } else {
        if (@available(iOS 13.0, *)) {
            if (key.windowScene) g_hostWin.windowScene = key.windowScene;
        }
        CGRect f = key.bounds.size.width > 2 ? key.bounds : UIScreen.mainScreen.bounds;
        CGFloat bot = 34.f;
        if (@available(iOS 11.0, *)) {
            if (key.safeAreaInsets.bottom > 1.f) bot = key.safeAreaInsets.bottom;
        }
        f.size.height = MAX(1.f, f.size.height - bot);
        g_hostWin.frame = f;
        g_hostWin.hidden = NO;
    }

    UIView* root = g_hostWin.rootViewController.view;
    root.frame = g_hostWin.bounds;
    root.backgroundColor = UIColor.clearColor;

    buildPanel(root);
    buildFab(root);
    if (g_fab) {
        CGFloat W = root.bounds.size.width;
        if (W < 2) W = UIScreen.mainScreen.bounds.size.width;
        g_fab.frame = CGRectMake(MAX(12, W - 60), 50, 48, 48);
        g_fab.hidden = NO;
        g_fab.alpha = 1;
        [root bringSubviewToFront:g_fab];
    }
    applyHideRec(root);
    CoreUI_EnsureFOVOverlay(g_hostWin);
    if (!g_hideRec.load()) {
        if (g_panel) [root bringSubviewToFront:g_panel];
        if (g_fab) [root bringSubviewToFront:g_fab];
    } else if (CoreUI_SecureRoot) {
        if (g_panel) [CoreUI_SecureRoot bringSubviewToFront:g_panel];
        if (g_fab) [CoreUI_SecureRoot bringSubviewToFront:g_fab];
    }

    if (!g_tick) {
        g_tick = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick)];
        g_tick.preferredFramesPerSecond = 60;
        [g_tick addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}

+ (void)onTick {
    UIWindow* key = [self gameWindow];
    if (key && g_hostWin) {
        CGRect b = key.bounds;
        if (b.size.width > 2) {
            CGFloat bot = 34.f;
            if (@available(iOS 11.0, *)) {
                if (key.safeAreaInsets.bottom > 1.f) bot = key.safeAreaInsets.bottom;
            }
            b.size.height = MAX(1.f, b.size.height - bot);
            if (!CGRectEqualToRect(g_hostWin.frame, b)) {
                g_hostWin.frame = b;
                g_hostWin.rootViewController.view.frame = g_hostWin.bounds;
            }
        }
        g_hostWin.hidden = NO;
        if (@available(iOS 13.0, *))
            g_hostWin.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    if (g_hostWin) {
        UIView* root = g_hostWin.rootViewController.view;
        if (g_hideRec.load()) {
            applyHideRec(root);
        } else {
            CoreUI_EnsureFOVOverlay(g_hostWin);
            extern UIView* g_esp_view(void);
            UIView* esp = g_esp_view();
            if (esp) esp.userInteractionEnabled = NO;
            if (g_fab) {
                g_fab.hidden = NO;
                g_fab.alpha = 1;
                if (g_fab.superview != root) [root addSubview:g_fab];
                [root bringSubviewToFront:g_fab];
            }
            if (g_panel) {
                if (g_panel.superview != root) [root addSubview:g_panel];
                [root bringSubviewToFront:g_panel];
            }
        }
    }
    CoreUI_FeaturesTick();
}


@end

static void wipe_docs(void) {
    NSString* home = NSHomeDirectory();
    if (!home) return;
    NSFileManager* fm = [NSFileManager defaultManager];
    for (NSString* n in @[@"Documents/boot.log", @"Documents/sr_host.txt", @"boot.log", @"sr_host.txt"])
        [fm removeItemAtPath:[home stringByAppendingPathComponent:n] error:nil];
    NSString* docs = [home stringByAppendingPathComponent:@"Documents"];
    for (NSString* f in [fm contentsOfDirectoryAtPath:docs error:nil] ?: @[]) {
        if ([f.pathExtension.lowercaseString isEqualToString:@"log"])
            [fm removeItemAtPath:[docs stringByAppendingPathComponent:f] error:nil];
    }
}

__attribute__((constructor))
static void coreui_ctor() {
    // одноразовая чистка старых ключей cui_* в Preferences plist
    NSUserDefaults* ud = [NSUserDefaults standardUserDefaults];
    for (NSString* k in @[@"cui_aimbot",@"cui_silent",@"cui_aimVisible",@"cui_fovDraw",
        @"cui_espBox",@"cui_espSkel",@"cui_espName",@"cui_espHP",@"cui_espWeapon",
        @"cui_espBomb",@"cui_espGrenade",@"cui_espDist",@"cui_espTeam",@"cui_noRecoil",
        @"cui_recoilPct",@"cui_hideRec",@"cui_fov",@"cui_smooth",@"cui_bone",@"cui_lang",
        @"cui_menuColor"]) {
        [ud removeObjectForKey:k];
    }
    [ud synchronize];

    // один проход чистим stale копии от старых сборок
    wipe_docs();

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ACH start];
    });
    // отложенные wipe_docs на 1.2s и 4.0s УБРАНЫ
}
