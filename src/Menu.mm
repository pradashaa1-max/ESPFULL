// Menu.mm — Astral UI, smooth, RU/EN, colors, stream-hide ON by default
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "State.h"
#include <cmath>
#include <atomic>
#include <cstdint>

void Astral_RebuildMenu(void);

extern void Astral_FeaturesTick();
extern void Astral_EnsureFOVOverlay(UIWindow* win);

UIView* Astral_SecureRoot = nil;

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
std::atomic<bool>  g_espBomb{false};
std::atomic<bool>  g_espGrenade{false};
std::atomic<bool>  g_espDist{false};
std::atomic<bool>  g_espTeam{true};
std::atomic<bool>  g_noRecoil{false};
std::atomic<float> g_recoilPct{0.f};      // 0=full, 100=zero
std::atomic<bool>  g_hideRec{true};       // ON at launch
std::atomic<bool>  g_menuOpen{false};
std::atomic<float> g_fov{25.f};
std::atomic<float> g_smooth{4.5f};
std::atomic<int>   g_bone{0};
std::atomic<int>   g_lang{0};             // 0 EN 1 RU
std::atomic<uint32_t> g_menuColor{0xFF1E90FF};

// ─── Config persist (NSUserDefaults) ─────────────────────────────────────────
void Astral_SaveConfig(void) {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    [d setBool:g_aimbot.load()   forKey:@"astral_aimbot"];
    [d setBool:g_silent.load()   forKey:@"astral_silent"];
    [d setBool:g_aimVisible.load()forKey:@"astral_aimVisible"];
    [d setBool:g_fovDraw.load()  forKey:@"astral_fovDraw"];
    [d setBool:g_espBox.load()   forKey:@"astral_espBox"];
    [d setBool:g_espSkel.load()  forKey:@"astral_espSkel"];
    [d setBool:g_espName.load()  forKey:@"astral_espName"];
    [d setBool:g_espHP.load()    forKey:@"astral_espHP"];
    [d setBool:g_espWeapon.load()forKey:@"astral_espWeapon"];
    [d setBool:g_espBomb.load()   forKey:@"astral_espBomb"];
    [d setBool:g_espGrenade.load()forKey:@"astral_espGrenade"];
    [d setBool:g_espDist.load()  forKey:@"astral_espDist"];
    [d setBool:g_espTeam.load()  forKey:@"astral_espTeam"];
    [d setBool:g_noRecoil.load() forKey:@"astral_noRecoil"];
    [d setFloat:g_recoilPct.load() forKey:@"astral_recoilPct"];
    [d setBool:g_hideRec.load()  forKey:@"astral_hideRec"];
    [d setFloat:g_fov.load()     forKey:@"astral_fov"];
    [d setFloat:g_smooth.load()  forKey:@"astral_smooth"];
    [d setInteger:g_bone.load()  forKey:@"astral_bone"];
    [d setInteger:g_lang.load()  forKey:@"astral_lang"];
    [d setInteger:(NSInteger)g_menuColor.load() forKey:@"astral_menuColor"];
    [d synchronize];
}

void Astral_LoadConfig(void) {
    NSUserDefaults* d = [NSUserDefaults standardUserDefaults];
    if (![d objectForKey:@"astral_hideRec"]) return; // first launch — keep defaults
    g_aimbot.store([d boolForKey:@"astral_aimbot"]);
    g_silent.store([d boolForKey:@"astral_silent"]);
    if ([d objectForKey:@"astral_aimVisible"]) g_aimVisible.store([d boolForKey:@"astral_aimVisible"]);
    g_fovDraw.store([d boolForKey:@"astral_fovDraw"]);
    g_espBox.store([d boolForKey:@"astral_espBox"]);
    g_espSkel.store([d boolForKey:@"astral_espSkel"]);
    g_espName.store([d boolForKey:@"astral_espName"]);
    g_espHP.store([d boolForKey:@"astral_espHP"]);
    g_espWeapon.store([d boolForKey:@"astral_espWeapon"]);
    g_espBomb.store([d boolForKey:@"astral_espBomb"]);
    g_espGrenade.store([d boolForKey:@"astral_espGrenade"]);
    g_espDist.store([d boolForKey:@"astral_espDist"]);
    g_espTeam.store([d boolForKey:@"astral_espTeam"]);
    g_noRecoil.store([d boolForKey:@"astral_noRecoil"]);
    float rp = [d floatForKey:@"astral_recoilPct"];
    if (rp >= 0.f && rp <= 100.f) g_recoilPct.store(rp);
    else if (g_noRecoil.load()) g_recoilPct.store(100.f);
    g_hideRec.store([d boolForKey:@"astral_hideRec"]);
    float f = [d floatForKey:@"astral_fov"];
    if (f > 0.5f && f < 40.f) g_fov.store(f);
    float sm = [d floatForKey:@"astral_smooth"];
    if (sm >= 1.f && sm <= 20.f) g_smooth.store(sm);
    g_bone.store((int)[d integerForKey:@"astral_bone"]);
    g_lang.store((int)[d integerForKey:@"astral_lang"]);
    NSInteger col = [d integerForKey:@"astral_menuColor"];
    if (col != 0) g_menuColor.store((uint32_t)col);
}

// ─── Locale ──────────────────────────────────────────────────────────────────
static NSString* L(const char* en, const char* ru) {
    return g_lang.load() == 1 ? [NSString stringWithUTF8String:ru]
                              : [NSString stringWithUTF8String:en];
}

static UIColor* Accent() {
    uint32_t c = g_menuColor.load();
    return [UIColor colorWithRed:((c>>16)&0xFF)/255.f
                           green:((c>>8)&0xFF)/255.f
                            blue:(c&0xFF)/255.f
                           alpha:((c>>24)&0xFF)/255.f];
}
static UIColor* C(CGFloat r,CGFloat g,CGFloat b,CGFloat a){
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

// ─── Window that never steals game touches ───────────────────────────────────

// ── Drag ─────────────────────────────────────────────────────────────────────
@interface AstralDrag : NSObject
+ (void)attach:(UIView*)v;
@end
@implementation AstralDrag
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
        // clamp inside superview
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

@interface ACW : UIWindow @end
@implementation ACW
// If touch is NOT on panel/FAB — window is invisible to the system (Google + game work).
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    extern UIView* g_panel_ref(void);
    extern UIView* g_fab_ref(void);
    UIView* panel = g_panel_ref();
    UIView* fab = g_fab_ref();
    if (panel && !panel.hidden && panel.alpha > 0.05f) {
        CGPoint lp = [self convertPoint:point toView:panel];
        if (CGRectContainsPoint(CGRectInset(panel.bounds, -4, -4), lp)) return YES;
    }
    if (fab && !fab.hidden) {
        CGPoint lp = [self convertPoint:point toView:fab];
        // larger hit area so FAB is easy to press
        if (CGRectContainsPoint(CGRectInset(fab.bounds, -12, -12), lp)) return YES;
    }
    return NO;
}
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    if (![self pointInside:point withEvent:event]) return nil;
    extern UIView* g_panel_ref(void);
    extern UIView* g_fab_ref(void);
    UIView* panel = g_panel_ref();
    UIView* fab = g_fab_ref();
    // Prefer FAB button directly
    if (fab && !fab.hidden) {
        CGPoint lp = [self convertPoint:point toView:fab];
        if (CGRectContainsPoint(CGRectInset(fab.bounds, -12, -12), lp)) {
            UIView* h = [fab hitTest:lp withEvent:event];
            if (h) return h;
            return fab;
        }
    }
    if (panel && !panel.hidden && panel.alpha > 0.05f) {
        CGPoint lp = [self convertPoint:point toView:panel];
        if (CGRectContainsPoint(panel.bounds, lp)) {
            UIView* h = [panel hitTest:lp withEvent:event];
            if (h) return h;
            return panel;
        }
    }
    return [super hitTest:point withEvent:event];
}
- (BOOL)canBecomeKeyWindow { return NO; }
- (BOOL)canBecomeFirstResponder { return NO; }
@end

@interface ACVC : UIViewController @end
@implementation ACVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
- (BOOL)shouldAutorotate { return YES; }
- (UIInterfaceOrientation)preferredInterfaceOrientationForPresentation { return UIInterfaceOrientationLandscapeRight; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
}
@end

// ─── Globals ─────────────────────────────────────────────────────────────────
static UIWindow*     g_hostWin = nil;  // GAME key window — no extra overlay
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

// ─── Hide recording (secure UITextField trick) ───────────────────────────────
static void applyHideRec(UIView* root) {
    // Overlay root only. Everything (ESP + FAB + panel) goes inside secure
    // so screen recording / screenshots show black where the cheat UI is.
    if (!root) return;
    BOOL on = g_hideRec.load();

    if (on) {
        if (!g_secureField) {
            g_secureField = [[UITextField alloc] initWithFrame:root.bounds];
            g_secureField.secureTextEntry = YES;
            g_secureField.backgroundColor = UIColor.clearColor;
            g_secureField.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        }
        g_secureField.frame = root.bounds;
        // YES so children (menu/fab) can receive touches; ACW.pointInside still
        // filters to panel/fab only so Google/game are fine.
        g_secureField.userInteractionEnabled = YES;
        if (g_secureField.superview != root)
            [root insertSubview:g_secureField atIndex:0];

        [g_secureField layoutIfNeeded];
        UIView* container = nil;
        for (UIView* s in g_secureField.subviews) {
            if (s.bounds.size.width >= root.bounds.size.width * 0.9) {
                container = s; break;
            }
        }
        if (!container) {
            container = [[UIView alloc] initWithFrame:root.bounds];
            container.backgroundColor = UIColor.clearColor;
            container.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
            [g_secureField addSubview:container];
        }
        container.frame = root.bounds;
        container.userInteractionEnabled = YES;
        Astral_SecureRoot = container;

        // Move panel + FAB + ESP into secure container → hidden on recording
        if (g_panel && g_panel.superview != container) {
            [g_panel removeFromSuperview];
            [container addSubview:g_panel];
        }
        if (g_fab && g_fab.superview != container) {
            [g_fab removeFromSuperview];
            [container addSubview:g_fab];
        }
        extern UIView* g_esp_view(void);
        UIView* esp = g_esp_view();
        if (esp) {
            esp.userInteractionEnabled = NO;
            if (esp.superview != container) {
                [esp removeFromSuperview];
                [container insertSubview:esp atIndex:0];
            }
        }
    } else {
        Astral_SecureRoot = nil;
        // Move chrome back to overlay root
        if (g_panel && g_panel.superview != root) {
            [g_panel removeFromSuperview];
            [root addSubview:g_panel];
        }
        if (g_fab && g_fab.superview != root) {
            [g_fab removeFromSuperview];
            [root addSubview:g_fab];
        }
        extern UIView* g_esp_view(void);
        UIView* esp = g_esp_view();
        if (esp && esp.superview != root) {
            [esp removeFromSuperview];
            [root insertSubview:esp atIndex:0];
        }
        if (g_secureField) {
            [g_secureField removeFromSuperview];
            g_secureField = nil;
        }
    }
    if (g_panel) [g_panel.superview bringSubviewToFront:g_panel];
    if (g_fab)   [g_fab.superview bringSubviewToFront:g_fab];
    Astral_EnsureFOVOverlay(g_hostWin);
}



static UIView* makeHeader(NSString* title) {
    UIView* row = [[UIView alloc] initWithFrame:CGRectMake(0,0,300,28)];
    UILabel* t = [[UILabel alloc] initWithFrame:CGRectMake(4,6,292,18)];
    t.text = title;
    t.textColor = Accent();
    t.font = [UIFont systemFontOfSize:12 weight:UIFontWeightBold];
    [row addSubview:t];
    return row;
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
            // rebuild to refresh accents
            extern void Astral_RebuildMenu(void);
            Astral_RebuildMenu();
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

    if (g_section == 0) { // Aimbot tab
        add(makeHeader(L("—— AIMBOT ——","—— АИМБОТ ——")));
        add(makeSwitch(L("Aimbot","Аимбот"),
                       L("Moves crosshair to enemy","Ведёт прицел на врага"),
                       g_aimbot.load(), ^(bool v){ g_aimbot=v; Astral_SaveConfig(); }));
        add(makeSlider(L("Smooth","Плавность"), g_smooth.load(), 1, 15, ^(float v){
            g_smooth=v; Astral_SaveConfig();
        }));
        add(makeSegment(L("Bone","Кость"),
                        g_lang.load()==1 ? @[@"Голова",@"Шея",@"Грудь"] : @[@"Head",@"Neck",@"Chest"],
                        g_bone.load(), ^(int v){ g_bone=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Visible check","Видимость"),
                       L("Only if enemy visible","Только если враг виден"),
                       g_aimVisible.load(), ^(bool v){ g_aimVisible=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("FOV Circle","Круг FOV"),
                       L("Draw FOV circle","Рисовать круг FOV"),
                       g_fovDraw.load(), ^(bool v){ g_fovDraw=v; Astral_SaveConfig(); }));
        add(makeSlider(L("FOV (30=off)","FOV (30=выкл)"), g_fov.load(), 1, 30, ^(float v){
            g_fov=v; Astral_SaveConfig();
        }));
    }
    else if (g_section == 1) { // Silent tab (like Misc — own window)
        add(makeHeader(L("—— SILENT ——","—— САЙЛЕНТ ——")));
        add(makeSwitch(L("Silent aim","Сайлент аим"),
                       L("Hits without moving crosshair","Попадает без движения прицела"),
                       g_silent.load(), ^(bool v){ g_silent=v; Astral_SaveConfig(); }));
        add(makeSegment(L("Bone","Кость"),
                        g_lang.load()==1 ? @[@"Голова",@"Шея",@"Грудь"] : @[@"Head",@"Neck",@"Chest"],
                        g_bone.load(), ^(int v){ g_bone=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Visible check","Видимость"),
                       L("Only if enemy visible","Только если враг виден"),
                       g_aimVisible.load(), ^(bool v){ g_aimVisible=v; Astral_SaveConfig(); }));
        add(makeSlider(L("FOV (30=off)","FOV (30=выкл)"), g_fov.load(), 1, 30, ^(float v){
            g_fov=v; Astral_SaveConfig();
        }));
    }
    else if (g_section == 2) { // Visuals
        add(makeSwitch(L("Box ESP","Бокс ESP"),
                       L("2D box around players","Рамка вокруг игроков"),
                       g_espBox.load(), ^(bool v){ g_espBox=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Skeleton","Скелет"),
                       L("Bone lines","Линии костей"),
                       g_espSkel.load(), ^(bool v){ g_espSkel=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Names","Ники"),
                       L("Player name tags","Никнеймы игроков"),
                       g_espName.load(), ^(bool v){ g_espName=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Health + Armor","ХП + Армор"),
                       L("Bars with % like mockup","Полоски с % как на макете"),
                       g_espHP.load(), ^(bool v){ g_espHP=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Weapon","Оружие"),
                       L("Weapon + ammo under player","Оружие + патроны"),
                       g_espWeapon.load(), ^(bool v){ g_espWeapon=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Bomb","Бомба"),
                       L("Planted bomb + timer","Бомба + таймер"),
                       g_espBomb.load(), ^(bool v){ g_espBomb=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Grenades","Гранаты"),
                       L("Flying grenades","Летящие гранаты"),
                       g_espGrenade.load(), ^(bool v){ g_espGrenade=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Distance","Дистанция"),
                       L("Distance in meters","Дистанция в метрах"),
                       g_espDist.load(), ^(bool v){ g_espDist=v; Astral_SaveConfig(); }));
        add(makeSwitch(L("Team check","Свои"),
                       L("Ignore teammates","Игнорировать союзников"),
                       g_espTeam.load(), ^(bool v){ g_espTeam=v; Astral_SaveConfig(); }));
    }
    else if (g_section == 3) { // Misc
        add(makeSwitch(L("No Recoil","Без отдачи"),
                       L("Enable recoil control","Включить контроль отдачи"),
                       g_noRecoil.load(), ^(bool v){
                           g_noRecoil=v;
                           if (v && g_recoilPct.load() < 1.f) g_recoilPct.store(100.f);
                           Astral_SaveConfig();
                       }));
        add(makeSlider(L("Recoil %","Отдача %"),
                       g_recoilPct.load(), 0, 100, ^(float v){
                           g_recoilPct=v;
                           if (v >= 1.f) g_noRecoil.store(true);
                           Astral_SaveConfig();
                       }));
        add(makeSwitch(L("Hide from recording","Скрытие записи"),
                       L("Hide menu & ESP on screenshots/record","Скрыть меню и ESP на скринах"),
                       g_hideRec.load(), ^(bool v){
                           g_hideRec=v; Astral_SaveConfig();
                           UIView* root = g_hostWin ? g_hostWin.rootViewController.view : nil;
                           applyHideRec(root);
                       }));
    }
    else { // Config
        add(makeSegment(L("Language","Язык"),
                        @[@"English", @"Русский"],
                        g_lang.load(), ^(int v){
                            g_lang=v;
                            extern void Astral_RebuildMenu(void);
                            Astral_RebuildMenu();
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

void Astral_RebuildMenu(void) {
    // refresh tab titles + accent + content
    if (g_tabBtns) {
        NSArray* titles = g_lang.load()==1
            ? @[@"Аим", @"Сайлент", @"Визуалы", @"Разное", @"Конфиг"]
            : @[@"Aim", @"Silent", @"Visuals", @"Misc", @"Config"];
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
    g_panel.backgroundColor = C(0.04,0.05,0.10,0.96);
    g_panel.layer.cornerRadius = 16;
    g_panel.layer.borderWidth = 1.5;
    g_panel.layer.borderColor = [Accent() colorWithAlphaComponent:0.5].CGColor;
    g_panel.layer.shadowColor = Accent().CGColor;
    g_panel.layer.shadowOpacity = 0.35;
    g_panel.layer.shadowRadius = 16;
    g_panel.clipsToBounds = NO;
    g_panel.hidden = YES; // always start hidden — open via FAB only
    g_panel.alpha = 0;

    // Logo
    UILabel* logo = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, 200, 28)];
    logo.text = @"ASTRAL";
    logo.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBlack];
    logo.textColor = Accent();
    [g_panel addSubview:logo];
    UILabel* sub = [[UILabel alloc] initWithFrame:CGRectMake(16, 36, 120, 14)];
    sub.text = @"CHEATS";
    sub.font = [UIFont systemFontOfSize:11 weight:UIFontWeightBold];
    sub.textColor = C(0.3,0.85,1,1);
    [g_panel addSubview:sub];

    // Tabs
    NSArray* titles = g_lang.load()==1 ? @[@"Аим", @"Сайлент", @"Визуалы", @"Разное", @"Конфиг"] : @[@"Aim", @"Silent", @"Visuals", @"Misc", @"Config"];
    NSMutableArray* btns = [NSMutableArray array];
    CGFloat tx = 12, ty = 58;
    for (int i = 0; i < (int)titles.count; i++) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(tx, ty, 60, 32);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
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

    // Scroll content
    g_scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 100, 320, ph-110)];
    g_scroll.showsVerticalScrollIndicator = YES;
    g_scroll.alwaysBounceVertical = YES;
    [g_panel addSubview:g_scroll];

    g_content = [[UIView alloc] initWithFrame:CGRectMake(0,0,320,300)];
    [g_scroll addSubview:g_content];

    [host addSubview:g_panel];
    [AstralDrag attach:g_panel];
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
    [UIView animateWithDuration:0.2 animations:^{
        panel.alpha = open ? 1.0 : 0.0;
        panel.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL f) {
        if (!open) panel.hidden = YES;
    }];
}
@end

static void buildFab(UIView* host) {
    if (g_fab) return;
    // Visible position: top-right in landscape-ish coords
    CGFloat x = MAX(16, host.bounds.size.width - 70);
    if (x < 20) x = 20;
    g_fab = [[UIView alloc] initWithFrame:CGRectMake(x, 40, 52, 52)];
    g_fab.backgroundColor = Accent();
    g_fab.layer.cornerRadius = 26;
    g_fab.layer.shadowColor = Accent().CGColor;
    g_fab.layer.shadowOpacity = 0.55;
    g_fab.layer.shadowRadius = 10;
    g_fab.userInteractionEnabled = YES;
    UILabel* star = [[UILabel alloc] initWithFrame:g_fab.bounds];
    star.text = @"✦";
    star.textAlignment = NSTextAlignmentCenter;
    star.font = [UIFont systemFontOfSize:24];
    star.textColor = UIColor.whiteColor;
    star.userInteractionEnabled = NO;
    [g_fab addSubview:star];
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = g_fab.bounds;
    btn.accessibilityLabel = @"AstralMenu";
    [btn addTarget:[FabToggle shared] action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
    [g_fab addSubview:btn];
    [host addSubview:g_fab];
    // Drag only after movement — don't kill taps
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:[AstralDrag class] action:@selector(onPan:)];
    pan.maximumNumberOfTouches = 1;
    pan.cancelsTouchesInView = NO;
    [g_fab addGestureRecognizer:pan];
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
    dispatch_once(&onceCfg, ^{ Astral_LoadConfig(); });
    UIWindow* key = [self gameWindow];
    if (!key) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self tryAttach]; });
        return;
    }

    // Separate overlay window — NEVER inject UITextField into Unity/game window
    // (that is what crashes on map load)
    if (!g_hostWin || ![g_hostWin isKindOfClass:[ACW class]]) {
        CGRect f = key.bounds;
        if (f.size.width < 2) f = UIScreen.mainScreen.bounds;
        ACW* ov = [[ACW alloc] initWithFrame:f];
        ov.windowLevel = UIWindowLevelAlert + 50;
        ov.backgroundColor = UIColor.clearColor;
        ov.rootViewController = [ACVC new];
        ov.userInteractionEnabled = YES;
        ov.hidden = NO;
        // do NOT makeKeyAndVisible
        g_hostWin = ov;
    } else {
        g_hostWin.frame = key.bounds;
    }

    UIView* root = g_hostWin.rootViewController.view;
    root.frame = g_hostWin.bounds;
    root.backgroundColor = UIColor.clearColor;

    buildPanel(root);
    buildFab(root);
    applyHideRec(root);   // secure + ESP only inside OVERLAY
    Astral_EnsureFOVOverlay(g_hostWin);

    if (g_panel) [root bringSubviewToFront:g_panel];
    if (g_fab)   [root bringSubviewToFront:g_fab];

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
        if (b.size.width > 2 && !CGRectEqualToRect(g_hostWin.frame, b)) {
            g_hostWin.frame = b;
            g_hostWin.rootViewController.view.frame = g_hostWin.bounds;
        }
    }
    if (g_hostWin) {
        UIView* root = g_hostWin.rootViewController.view;
        // keep secure full-size — interaction MUST stay YES so panel/fab receive touches
        if (g_secureField) {
            g_secureField.frame = root.bounds;
            g_secureField.userInteractionEnabled = YES;
            if (Astral_SecureRoot) {
                Astral_SecureRoot.frame = root.bounds;
                Astral_SecureRoot.userInteractionEnabled = YES;
            }
        }
        // re-home ESP into secure container every tick when hide is on
        if (g_hideRec.load() && Astral_SecureRoot) {
            extern UIView* g_esp_view(void);
            UIView* esp = g_esp_view();
            if (esp && esp.superview != Astral_SecureRoot) {
                [esp removeFromSuperview];
                [Astral_SecureRoot insertSubview:esp atIndex:0];
            }
            if (g_panel && g_panel.superview != Astral_SecureRoot) {
                [g_panel removeFromSuperview];
                [Astral_SecureRoot addSubview:g_panel];
            }
            if (g_fab && g_fab.superview != Astral_SecureRoot) {
                [g_fab removeFromSuperview];
                [Astral_SecureRoot addSubview:g_fab];
            }
        }
        Astral_EnsureFOVOverlay(g_hostWin);
        UIView* front = Astral_SecureRoot ?: root;
        if (g_panel) [front bringSubviewToFront:g_panel];
        if (g_fab)   [front bringSubviewToFront:g_fab];
    }
    Astral_FeaturesTick();
}


@end

__attribute__((constructor))
static void astral_ctor() {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [ACH start];
    });
}
