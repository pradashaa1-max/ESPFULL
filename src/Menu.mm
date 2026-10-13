// Menu.mm — Astral UI, smooth, RU/EN, colors, stream-hide ON by default
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#include "State.h"
#include <cmath>

extern void Astral_FeaturesTick();
extern void Astral_EnsureFOVOverlay(UIWindow* win);

UIView* Astral_SecureRoot = nil;

// ─── State ───────────────────────────────────────────────────────────────────
std::atomic<bool>  g_aimbot{true};
std::atomic<bool>  g_silent{true};
std::atomic<bool>  g_fovDraw{true};
std::atomic<bool>  g_espBox{true};
std::atomic<bool>  g_espSkel{true};
std::atomic<bool>  g_espName{true};
std::atomic<bool>  g_espHP{true};
std::atomic<bool>  g_espWeapon{true};
std::atomic<bool>  g_espDist{false};
std::atomic<bool>  g_espTeam{true};
std::atomic<bool>  g_noRecoil{false};
std::atomic<bool>  g_hideRec{true};       // ON at launch
std::atomic<bool>  g_menuOpen{true};
std::atomic<float> g_fov{15.f};
std::atomic<float> g_smooth{4.5f};
std::atomic<int>   g_bone{0};
std::atomic<int>   g_lang{0};             // 0 EN 1 RU
std::atomic<uint32_t> g_menuColor{0xFF1E90FF};

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
@interface ACW : UIWindow @end
@implementation ACW
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event {
    UIView* hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    NSString* cls = NSStringFromClass(hit.class);
    if ([cls containsString:@"TextField"] || hit.tag == 0xSEC1) {
        for (UIView* s in hit.subviews) {
            CGPoint p = [hit convertPoint:point toView:s];
            if (!s.hidden && s.userInteractionEnabled && CGRectContainsPoint(s.bounds, p)) {
                UIView* h2 = [s hitTest:p withEvent:event];
                if (h2 && h2 != s) return h2;
            }
        }
        return nil;
    }
    return hit;
}
- (BOOL)canBecomeKeyWindow { return NO; }
@end

@interface ACVC : UIViewController @end
@implementation ACVC
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotate { return YES; }
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.clearColor;
}
@end

// ─── Globals ─────────────────────────────────────────────────────────────────
static ACW*          g_overlay = nil;
static UIView*       g_panel   = nil;
static UIView*       g_fab     = nil;
static UIView*       g_content = nil;
static UIScrollView* g_scroll  = nil;
static CADisplayLink* g_tick   = nil;
static UITextField*  g_secureField = nil;
static int           g_section = 0;
static NSArray<UIButton*>* g_tabBtns = nil;

// ─── Hide recording (secure UITextField trick) ───────────────────────────────
static void applyHideRec(UIView* root) {
    if (!root) return;
    BOOL on = g_hideRec.load();

    auto placeUI = ^(UIView* host) {
        Astral_SecureRoot = on ? host : nil;
        if (g_panel && g_panel.superview != host) {
            [g_panel removeFromSuperview];
            [host addSubview:g_panel];
        }
        if (g_fab && g_fab.superview != host) {
            [g_fab removeFromSuperview];
            [host addSubview:g_fab];
        }
        Astral_EnsureFOVOverlay(g_overlay);
    };

    if (on) {
        if (!g_secureField) {
            g_secureField = [[UITextField alloc] initWithFrame:root.bounds];
            g_secureField.secureTextEntry = YES;
            g_secureField.userInteractionEnabled = YES;
            g_secureField.backgroundColor = UIColor.clearColor;
            g_secureField.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
            [root addSubview:g_secureField];
        }
        UIView* container = g_secureField.subviews.firstObject ?: g_secureField;
        container.userInteractionEnabled = YES;
        container.tag = 0xSEC1;
        UIView* host = [container viewWithTag:0xSEC2];
        if (!host) {
            host = [[UIView alloc] initWithFrame:root.bounds];
            host.tag = 0xSEC2;
            host.backgroundColor = UIColor.clearColor;
            host.userInteractionEnabled = YES;
            host.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
            [container addSubview:host];
        }
        placeUI(host);
        [root bringSubviewToFront:g_secureField];
    } else {
        placeUI(root);
        if (g_secureField) {
            [g_secureField removeFromSuperview];
            g_secureField = nil;
        }
        Astral_SecureRoot = nil;
    }
}

// ─── Row builders ────────────────────────────────────────────────────────────
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

    if (g_section == 0) { // Aim
        add(makeSwitch(L("Aim bot","Аимбот"),
                       L("Automatically aims at enemies","Автоматически наводится на врагов"),
                       g_aimbot.load(), ^(bool v){ g_aimbot=v; }));
        add(makeSwitch(L("Silent","Сайлент"),
                       L("Hides your aim from other players","Скрывает наводку от других"),
                       g_silent.load(), ^(bool v){ g_silent=v; }));
        add(makeSwitch(L("FOV Circle","Круг FOV"),
                       L("Shows the aim range circle","Показывает круг зоны аима"),
                       g_fovDraw.load(), ^(bool v){ g_fovDraw=v; }));
        add(makeSlider(L("FOV","FOV"), g_fov.load(), 1, 30, ^(float v){ g_fov=v; }));
        add(makeSlider(L("Smooth","Плавность"), g_smooth.load(), 1, 15, ^(float v){ g_smooth=v; }));
        add(makeSegment(L("Bone","Кость"),
                        g_lang.load()==1 ? @[@"Голова",@"Шея",@"Грудь"] : @[@"Head",@"Neck",@"Chest"],
                        g_bone.load(), ^(int v){ g_bone=v; }));
    }
    else if (g_section == 1) { // Visuals
        add(makeSwitch(L("Box ESP","Бокс ESP"),
                       L("2D box around players","Рамка вокруг игроков"),
                       g_espBox.load(), ^(bool v){ g_espBox=v; }));
        add(makeSwitch(L("Skeleton","Скелет"),
                       L("Bone lines","Линии костей"),
                       g_espSkel.load(), ^(bool v){ g_espSkel=v; }));
        add(makeSwitch(L("Names","Ники"),
                       L("Player name tags","Никнеймы игроков"),
                       g_espName.load(), ^(bool v){ g_espName=v; }));
        add(makeSwitch(L("Health bar","Здоровье"),
                       L("HP bar + percent","Полоска HP + проценты"),
                       g_espHP.load(), ^(bool v){ g_espHP=v; }));
        add(makeSwitch(L("Weapon","Оружие"),
                       L("Weapon icon under player","Иконка оружия"),
                       g_espWeapon.load(), ^(bool v){ g_espWeapon=v; }));
        add(makeSwitch(L("Distance","Дистанция"),
                       L("Distance in meters","Дистанция в метрах"),
                       g_espDist.load(), ^(bool v){ g_espDist=v; }));
        add(makeSwitch(L("Team check","Свои"),
                       L("Ignore teammates","Игнорировать союзников"),
                       g_espTeam.load(), ^(bool v){ g_espTeam=v; }));
    }
    else if (g_section == 2) { // Misc
        add(makeSwitch(L("No Recoil","Без отдачи"),
                       L("Reduce weapon recoil","Убрать отдачу"),
                       g_noRecoil.load(), ^(bool v){ g_noRecoil=v; }));
        add(makeSwitch(L("Hide from recording","Скрытие записи"),
                       L("Hide menu & ESP on screenshots/record","Скрыть меню и ESP на скринах"),
                       g_hideRec.load(), ^(bool v){
                           g_hideRec=v;
                           UIView* root = g_overlay.rootViewController.view;
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
            ? @[@"Аим", @"Визуалы", @"Разное", @"Конфиг"]
            : @[@"Aim", @"Visuals", @"Misc", @"Config"];
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
    g_panel.hidden = !g_menuOpen.load();

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
    NSArray* titles = @[@"Aim", @"Visuals", @"Misc", @"Config"];
    NSMutableArray* btns = [NSMutableArray array];
    CGFloat tx = 12, ty = 58;
    for (int i = 0; i < 4; i++) {
        UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
        b.frame = CGRectMake(tx, ty, 74, 32);
        [b setTitle:titles[i] forState:UIControlStateNormal];
        [b setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:12 weight:UIFontWeightSemibold];
        b.backgroundColor = (i==0) ? Accent() : C(0.1,0.12,0.2,1);
        b.layer.cornerRadius = 8;
        b.tag = i;
        [b addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
            g_section = (int)a.sender.tag;
            for (UIButton* bb in g_tabBtns)
                bb.backgroundColor = (bb.tag==g_section) ? Accent() : C(0.1,0.12,0.2,1);
            rebuildContent();
        }] forControlEvents:UIControlEventTouchUpInside];
        [g_panel addSubview:b];
        [btns addObject:b];
        tx += 78;
    }
    g_tabBtns = btns;

    // Scroll content
    g_scroll = [[UIScrollView alloc] initWithFrame:CGRectMake(10, 100, 320, ph-110)];
    g_scroll.showsVerticalScrollIndicator = YES;
    g_scroll.alwaysBounceVertical = YES;
    [g_panel addSubview:g_scroll];

    g_content = [[UIView alloc] initWithFrame:CGRectMake(0,0,320,300)];
    [g_scroll addSubview:g_content];

    // Drag
    UIPanGestureRecognizer* pan = [[UIPanGestureRecognizer alloc] initWithTarget:nil action:nil];
    [pan addTarget:[NSBlockOperation blockOperationWithBlock:^{}] action:nil];
    // simple pan via action
    __weak UIView* weakPanel = g_panel;
    [g_panel addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:nil action:nil]];
    // use block-based via UIAction not available for pan — skip, fixed position ok

    [host addSubview:g_panel];
    rebuildContent();
}

static void buildFab(UIView* host) {
    if (g_fab) return;
    g_fab = [[UIView alloc] initWithFrame:CGRectMake(16, 16, 44, 44)];
    g_fab.backgroundColor = Accent();
    g_fab.layer.cornerRadius = 22;
    g_fab.layer.shadowColor = Accent().CGColor;
    g_fab.layer.shadowOpacity = 0.5;
    g_fab.layer.shadowRadius = 8;
    UILabel* star = [[UILabel alloc] initWithFrame:g_fab.bounds];
    star.text = @"✦";
    star.textAlignment = NSTextAlignmentCenter;
    star.font = [UIFont systemFontOfSize:20];
    star.textColor = UIColor.whiteColor;
    [g_fab addSubview:star];
    UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:nil action:nil];
    // toggle via UIButton instead
    UIButton* btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = g_fab.bounds;
    [btn addAction:[UIAction actionWithHandler:^(__kindof UIAction* a) {
        bool open = !g_menuOpen.load();
        g_menuOpen = open;
        [UIView animateWithDuration:0.22 animations:^{
            g_panel.alpha = open ? 1 : 0;
            g_panel.transform = open ? CGAffineTransformIdentity : CGAffineTransformMakeScale(0.92, 0.92);
        } completion:^(BOOL f){ g_panel.hidden = !open; }];
        if (open) g_panel.hidden = NO;
    }] forControlEvents:UIControlEventTouchUpInside];
    [g_fab addSubview:btn];
    [host addSubview:g_fab];
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
+ (void)tryAttach {
    UIWindow* key = nil;
    for (UIScene* sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow* w in ((UIWindowScene*)sc).windows) {
            if (w.isKeyWindow) { key = w; break; }
        }
        if (key) break;
    }
    if (!key) key = UIApplication.sharedApplication.windows.firstObject;
    if (!key) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5*NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self tryAttach]; });
        return;
    }

    if (!g_overlay) {
        g_overlay = [[ACW alloc] initWithFrame:key.bounds];
        g_overlay.windowLevel = UIWindowLevelAlert + 100;
        g_overlay.backgroundColor = UIColor.clearColor;
        g_overlay.rootViewController = [ACVC new];
        g_overlay.hidden = NO;
        // NOT makeKey — game keeps input
    }

    UIView* root = g_overlay.rootViewController.view;
    buildPanel(root);
    buildFab(root);
    applyHideRec(root);   // hide-rec ON from start
    Astral_EnsureFOVOverlay(g_overlay);

    if (!g_tick) {
        g_tick = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick)];
        g_tick.preferredFramesPerSecond = 60;
        [g_tick addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
}
+ (void)onTick {
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
