// Features.mm — aimbot / silent / ESP (box, skeleton, HP, name, weapon, distance)
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <mach-o/dyld.h>
#include "Offsets.h"
#include "State.h"
#include "Il2Cpp.h"
#include <cmath>
#include <cstdio>
#include <cstring>
#include <cstdint>
#include <vector>
#include <mutex>
#include <algorithm>

extern UIView* Astral_SecureRoot;

// ─── Math ────────────────────────────────────────────────────────────────────
struct Vec3 { float x,y,z; };
struct Vec4 { float x,y,z,w; };

static inline float vlen(Vec3 v){ return sqrtf(v.x*v.x+v.y*v.y+v.z*v.z); }
static inline Vec3  vsub(Vec3 a,Vec3 b){ return {a.x-b.x,a.y-b.y,a.z-b.z}; }
static inline Vec3  vadd(Vec3 a,Vec3 b){ return {a.x+b.x,a.y+b.y,a.z+b.z}; }
static inline Vec3  vmul(Vec3 v,float s){ return {v.x*s,v.y*s,v.z*s}; }
static inline Vec3  vnorm(Vec3 v){ float l=vlen(v); return l<1e-6f?Vec3{0,0,1}:Vec3{v.x/l,v.y/l,v.z/l}; }
static inline float vdot(Vec3 a,Vec3 b){ return a.x*b.x+a.y*b.y+a.z*b.z; }
static inline float vdist(Vec3 a,Vec3 b){ return vlen(vsub(a,b)); }

static Vec4 quat_look(Vec3 from, Vec3 to) {
    Vec3 f = vnorm(vsub(to, from));
    Vec3 up = {0,1,0};
    Vec3 r = vnorm({up.y*f.z - up.z*f.y, up.z*f.x - up.x*f.z, up.x*f.y - up.y*f.x});
    Vec3 u = {f.y*r.z - f.z*r.y, f.z*r.x - f.x*r.z, f.x*r.y - f.y*r.x};
    // rotation matrix → quat
    float t = r.x + u.y + f.z;
    Vec4 q;
    if (t > 0) {
        float s = 0.5f / sqrtf(t+1);
        q.w = 0.25f/s; q.x = (u.z-f.y)*s; q.y = (f.x-r.z)*s; q.z = (r.y-u.x)*s;
    } else if (r.x > u.y && r.x > f.z) {
        float s = 2*sqrtf(1+r.x-u.y-f.z);
        q.w = (u.z-f.y)/s; q.x = 0.25f*s; q.y = (u.x+r.y)/s; q.z = (f.x+r.z)/s;
    } else if (u.y > f.z) {
        float s = 2*sqrtf(1+u.y-r.x-f.z);
        q.w = (f.x-r.z)/s; q.x = (u.x+r.y)/s; q.y = 0.25f*s; q.z = (f.y+u.z)/s;
    } else {
        float s = 2*sqrtf(1+f.z-r.x-u.y);
        q.w = (r.y-u.x)/s; q.x = (f.x+r.z)/s; q.y = (f.y+u.z)/s; q.z = 0.25f*s;
    }
    return q;
}

// ─── Unity base + RVA ────────────────────────────────────────────────────────
static uintptr_t g_unity = 0;
static uintptr_t unity_base() {
    if (g_unity) return g_unity;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* name = _dyld_get_image_name(i);
        if (!name) continue;
        if (strstr(name, "UnityFramework") || strstr(name, "UnityFramework.framework")) {
            g_unity = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    return g_unity;
}
template<typename Fn> static Fn RVA(uint64_t off) {
    return (Fn)(unity_base() + off);
}

using get_position_t    = Vec3  (*)(void*);
using set_rotation_t    = void  (*)(void*, Vec4);
using cam_main_t        = void* (*)();
using world_to_screen_t = Vec3  (*)(void*, Vec3);
using get_transform_t   = void* (*)(void*);
using look_at_t         = void  (*)(void*, Vec3);
using get_forward_t     = Vec3  (*)(void*);

static Vec3 get_pos(void* tr) {
    if (!tr || !unity_base()) return {};
    return RVA<get_position_t>(Offsets::Transform_get_position)(tr);
}
static Vec3 get_fwd(void* tr) {
    if (!tr || !unity_base()) return {0,0,1};
    return RVA<get_forward_t>(Offsets::Transform_get_forward)(tr);
}
static void* main_camera() {
    if (!unity_base()) return nullptr;
    return RVA<cam_main_t>(Offsets::Camera_get_main)();
}
static void* component_transform(void* c) {
    if (!c || !unity_base()) return nullptr;
    return RVA<get_transform_t>(Offsets::Component_get_transform)(c);
}
static Vec3 w2s(void* cam, Vec3 w) {
    if (!cam || !unity_base()) return {};
    return RVA<world_to_screen_t>(Offsets::Camera_WorldToScreenPoint)(cam, w);
}

// ─── Player list (cached, refreshed every N ticks) ───────────────────────────
struct PSnap {
    void* obj;
    void* tr;
    Vec3  pos;
    float hp;
    int   team;
    bool  local;
    bool  dead;
    char  name[32];
    char  weapon[24];
    int   ammo;
};

static std::mutex g_plist_mtx;
static std::vector<PSnap> g_plist;
static int g_refresh_ctr = 0;

static int get_team(void* pc) {
    if (!pc) return -1;
    return (int)*((uint8_t*)pc + Offsets::PC_team);
}

// Il2CppString: length @ +0x10 (int32), chars UTF-16 @ +0x14
static void read_il2cpp_string(void* strObj, char* out, size_t outLen) {
    if (!out || outLen == 0) return;
    out[0] = 0;
    if (!strObj) return;
    int32_t len = *(int32_t*)((char*)strObj + 0x10);
    if (len <= 0 || len > 64) return;
    const uint16_t* chars = (const uint16_t*)((char*)strObj + 0x14);
    size_t n = 0;
    for (int32_t i = 0; i < len && n + 1 < outLen; i++) {
        uint16_t c = chars[i];
        if (c < 128) out[n++] = (char)c;
        else out[n++] = '?';
    }
    out[n] = 0;
}

static void read_nick(void* pc, char* out, size_t outLen) {
    out[0] = 0;
    if (!pc) { snprintf(out, outLen, "Enemy"); return; }
    void* pp = *(void**)((char*)pc + Offsets::PC_photonPlayer);
    if (!pp) { snprintf(out, outLen, "Enemy"); return; }
    void* nameStr = *(void**)((char*)pp + Offsets::PP_nameField);
    if (nameStr) {
        read_il2cpp_string(nameStr, out, outLen);
        if (out[0]) return;
    }
    if (unity_base()) {
        using get_nick_t = void* (*)(void*);
        void* s = RVA<get_nick_t>(Offsets::PhotonPlayer_get_NickName)(pp);
        if (s) {
            read_il2cpp_string(s, out, outLen);
            if (out[0]) return;
        }
    }
    snprintf(out, outLen, "Enemy");
}

static void read_weapon(void* pc, char* out, size_t outLen, int* ammo) {
    out[0] = 0;
    if (ammo) *ammo = -1;
    if (!pc) return;
    void* wry = *(void**)((char*)pc + Offsets::PC_weaponry);
    if (!wry) return;
    void* wctrl = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
    if (!wctrl) return;
    void* wname = *(void**)((char*)wctrl + Offsets::WCtrl_nameStr);
    if (wname) read_il2cpp_string(wname, out, outLen);
    if (ammo) {
        int a = *(int*)((char*)wctrl + Offsets::WCtrl_intA);
        if (a >= 0 && a < 500) *ammo = a;
    }
}

static std::vector<void*> find_players_raw() {
    std::vector<void*> out;
    auto& api = IL2CPP();
    if (!api.ready && !api.init()) return out;
    if (!api.class_get_type || !api.type_get_object) return out;

    Il2CppClass* pcKlass = api.find_class("Axlebolt.Standoff.Player", "PlayerController");
    if (!pcKlass) pcKlass = api.find_class("", "PlayerController");
    if (!pcKlass) pcKlass = api.find_class("Assembly-CSharp", "PlayerController");
    if (!pcKlass) return out;

    Il2CppClass* objKlass = api.find_class("UnityEngine", "Object");
    if (!objKlass) return out;
    const MethodInfo* findMethod = api.find_method(objKlass, "FindObjectsOfType", 1);
    if (!findMethod) return out;

    const Il2CppType* type = api.class_get_type(pcKlass);
    if (!type) return out;
    Il2CppObject* typeObj = api.type_get_object(type);
    if (!typeObj) return out;

    void* args[1] = { typeObj };
    void* exc = nullptr;
    Il2CppObject* arrObj = api.runtime_invoke(findMethod, nullptr, args, &exc);
    if (exc || !arrObj) return out;

    auto* arr = (Il2CppArraySimple*)arrObj;
    uintptr_t len = arr->max_length;
    if (api.array_length) len = api.array_length(arrObj);
    if (len > 64) len = 64;
    for (uintptr_t i = 0; i < len; i++) {
        void* obj = arr->vector[i];
        if (obj) out.push_back(obj);
    }
    return out;
}

static void refresh_players(void* camTr) {
    auto raw = find_players_raw();
    Vec3 camPos = camTr ? get_pos(camTr) : Vec3{};
    void* local = nullptr;
    float bestD = 1e9f;
    for (void* pc : raw) {
        void* tr = component_transform(pc);
        if (!tr) continue;
        float d = vdist(get_pos(tr), camPos);
        if (d < bestD) { bestD = d; local = pc; }
    }
    if (bestD > 8.f) local = nullptr;

    std::vector<PSnap> tmp;
    tmp.reserve(raw.size());
    for (void* pc : raw) {
        void* tr = component_transform(pc);
        if (!tr) continue;
        PSnap s{};
        s.obj   = pc;
        s.tr    = tr;
        s.pos   = get_pos(tr);
        s.team  = get_team(pc);
        s.local = (pc == local);
        s.hp    = 100.f;
        s.dead  = false;
        s.ammo  = -1;
        read_nick(pc, s.name, sizeof(s.name));
        read_weapon(pc, s.weapon, sizeof(s.weapon), &s.ammo);

        void* hit = *(void**)((char*)pc + Offsets::PC_hitController);
        if (hit) {
            for (size_t off = 0x10; off <= 0xE0; off += 4) {
                float h = *(float*)((char*)hit + off);
                if (h > 0.5f && h <= 100.5f) { s.hp = h; break; }
            }
        }
        void* net = *(void**)((char*)pc + 0x98);
        if (net && s.hp >= 99.f) {
            for (size_t off = 0x10; off <= 0x80; off += 4) {
                float h = *(float*)((char*)net + off);
                if (h > 0.5f && h < 100.5f) { s.hp = h; break; }
            }
        }
        s.dead = s.hp <= 0.5f;
        tmp.push_back(s);
    }
    std::lock_guard<std::mutex> lk(g_plist_mtx);
    g_plist.swap(tmp);
}

// ─── ESP drawing view ────────────────────────────────────────────────────────
@interface ESPView : UIView
@property (nonatomic, assign) CGSize scr;
@end

@implementation ESPView
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;

    CGRect bb = self.bounds;
    CGFloat w = CGRectGetWidth(bb);
    CGFloat h = CGRectGetHeight(bb);
    if (w < 2 || h < 2) return;
    CGSize scr = CGSizeMake(w, h);

    // FOV FIRST — always, no dependency on camera/il2cpp
    if (g_fovDraw.load()) {
        CGFloat cx = w * 0.5;
        CGFloat cy = h * 0.5;
        CGFloat shortSide = (w < h) ? w : h;
        CGFloat r = shortSide * (0.04f + (g_fov.load() / 30.f) * 0.20f);
        CGContextSaveGState(ctx);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.95].CGColor);
        CGContextSetLineWidth(ctx, 2.0);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2.0, r * 2.0));
        CGContextSetLineWidth(ctx, 1.2);
        CGContextMoveToPoint(ctx, cx - 6, cy);
        CGContextAddLineToPoint(ctx, cx + 6, cy);
        CGContextMoveToPoint(ctx, cx, cy - 6);
        CGContextAddLineToPoint(ctx, cx, cy + 6);
        CGContextStrokePath(ctx);
        CGContextRestoreGState(ctx);
    }

    void* cam = main_camera();
    if (!cam) return;
    void* camTr = component_transform(cam);
    Vec3 camPos = camTr ? get_pos(camTr) : Vec3{};

    bool box  = g_espBox.load();
    bool skel = g_espSkel.load();
    bool name = g_espName.load();
    bool hp   = g_espHP.load();
    bool weap = g_espWeapon.load();
    bool dist = g_espDist.load();
    bool team = g_espTeam.load();
    if (!box && !skel && !name && !hp && !weap && !dist) return;

    int localTeam = -1;
    {
        std::lock_guard<std::mutex> lk(g_plist_mtx);
        for (auto& s : g_plist) if (s.local) { localTeam = s.team; break; }
    }

    // bone offsets relative to feet (approx Standoff proportions)
    const Vec3 bones[] = {
        {0, 1.70f, 0}, // 0 head
        {0, 1.50f, 0}, // 1 neck
        {0, 1.25f, 0}, // 2 chest
        {0, 0.95f, 0}, // 3 pelvis
        {-0.18f, 1.25f, 0}, // 4 L shoulder
        { 0.18f, 1.25f, 0}, // 5 R shoulder
        {-0.22f, 0.95f, 0}, // 6 L elbow
        { 0.22f, 0.95f, 0}, // 7 R elbow
        {-0.25f, 0.65f, 0}, // 8 L hand
        { 0.25f, 0.65f, 0}, // 9 R hand
        {-0.12f, 0.55f, 0}, // 10 L knee
        { 0.12f, 0.55f, 0}, // 11 R knee
        {-0.12f, 0.05f, 0}, // 12 L foot
        { 0.12f, 0.05f, 0}, // 13 R foot
    };
    const int links[][2] = {
        {0,1},{1,2},{2,3},
        {2,4},{4,6},{6,8},
        {2,5},{5,7},{7,9},
        {3,10},{10,12},
        {3,11},{11,13},
    };

    auto toScreen = [&](Vec3 world, CGPoint& out) -> bool {
        Vec3 s = w2s(cam, world);
        if (s.z < 0.05f) return false;
        out.x = s.x;
        out.y = scr.height - s.y;
        return out.x > -80 && out.x < scr.width+80 && out.y > -80 && out.y < scr.height+80;
    };

    std::lock_guard<std::mutex> lk(g_plist_mtx);
    for (auto& p : g_plist) {
        if (p.local || p.dead) continue;
        if (team && localTeam >= 0 && p.team == localTeam) continue;

        float d = vdist(p.pos, camPos);
        if (d < 0.4f || d > 400.f) continue;

        CGPoint feet, head;
        if (!toScreen(p.pos, feet)) continue;
        if (!toScreen(vadd(p.pos, bones[0]), head)) continue;

        CGFloat h = feet.y - head.y;
        if (h < 8) continue;
        CGFloat w = h * 0.48f;
        CGFloat bx = head.x - w * 0.5f;
        CGFloat by = head.y;

        // ── Box ──
        if (box) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.15 green:0.55 blue:1.0 alpha:0.95].CGColor);
            CGContextSetLineWidth(ctx, 1.6);
            CGContextStrokeRect(ctx, CGRectMake(bx, by, w, h));
        }

        // ── Skeleton ──
        if (skel) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.25 green:0.65 blue:1.0 alpha:0.95].CGColor);
            CGContextSetLineWidth(ctx, 1.3);
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.7 blue:1.0 alpha:1].CGColor);
            CGPoint pts[14];
            bool ok[14] = {};
            for (int i = 0; i < 14; i++)
                ok[i] = toScreen(vadd(p.pos, bones[i]), pts[i]);
            for (auto& ln : links) {
                if (ok[ln[0]] && ok[ln[1]]) {
                    CGContextMoveToPoint(ctx, pts[ln[0]].x, pts[ln[0]].y);
                    CGContextAddLineToPoint(ctx, pts[ln[1]].x, pts[ln[1]].y);
                    CGContextStrokePath(ctx);
                }
            }
            for (int i = 0; i < 14; i++) if (ok[i]) {
                CGContextFillEllipseInRect(ctx, CGRectMake(pts[i].x-2.2, pts[i].y-2.2, 4.4, 4.4));
            }
        }

        // ── Name tag ──
        if (name) {
            NSString* nm = [NSString stringWithUTF8String:p.name];
            NSDictionary* attr = @{
                NSFontAttributeName: [UIFont systemFontOfSize:11 weight:UIFontWeightBold],
                NSForegroundColorAttributeName: UIColor.whiteColor
            };
            CGSize ts = [nm sizeWithAttributes:attr];
            CGFloat nx = head.x - ts.width*0.5f - 6;
            CGFloat ny = head.y - ts.height - 16;
            // purple pill
            UIBezierPath* pill = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(nx, ny, ts.width+12, ts.height+6) cornerRadius:6];
            [[UIColor colorWithRed:0.55 green:0.15 blue:0.85 alpha:0.92] setFill];
            [pill fill];
            [nm drawAtPoint:CGPointMake(nx+6, ny+3) withAttributes:attr];
            // triangle
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.55 green:0.15 blue:0.85 alpha:0.92].CGColor);
            CGContextMoveToPoint(ctx, head.x-5, ny+ts.height+6);
            CGContextAddLineToPoint(ctx, head.x+5, ny+ts.height+6);
            CGContextAddLineToPoint(ctx, head.x, ny+ts.height+12);
            CGContextClosePath(ctx);
            CGContextFillPath(ctx);
        }

        // ── HP bar ──
        if (hp) {
            CGFloat pct = fmaxf(0.f, fminf(1.f, p.hp / 100.f));
            CGFloat barH = h;
            CGFloat barW = 5;
            CGFloat barX = bx - 10;
            CGFloat barY = by;
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0.15 alpha:0.85].CGColor);
            CGContextFillRect(ctx, CGRectMake(barX, barY, barW, barH));
            UIColor* hc = pct > 0.5f ? [UIColor colorWithRed:0.15 green:0.95 blue:0.3 alpha:1]
                         : pct > 0.25f ? [UIColor colorWithRed:1 green:0.8 blue:0.1 alpha:1]
                         : [UIColor colorWithRed:1 green:0.2 blue:0.15 alpha:1];
            CGContextSetFillColorWithColor(ctx, hc.CGColor);
            CGContextFillRect(ctx, CGRectMake(barX, barY + barH*(1-pct), barW, barH*pct));
            // percent text
            NSString* pctStr = [NSString stringWithFormat:@"%.0f%%", pct*100];
            NSDictionary* pa = @{
                NSFontAttributeName: [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: UIColor.whiteColor
            };
            [pctStr drawAtPoint:CGPointMake(barX - 2, barY + barH + 2) withAttributes:pa];
        }

        // ── Weapon icon placeholder + ammo ──
        if (weap) {
            CGFloat wx = head.x - 18;
            CGFloat wy = feet.y + 6;
            // red outline box
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.15 blue:0.15 alpha:0.95].CGColor);
            CGContextSetLineWidth(ctx, 1.4);
            CGContextStrokeRect(ctx, CGRectMake(wx, wy, 36, 16));
            // simple rifle glyph
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.2 blue:0.15 alpha:1].CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextMoveToPoint(ctx, wx+4, wy+8);
            CGContextAddLineToPoint(ctx, wx+28, wy+8);
            CGContextMoveToPoint(ctx, wx+28, wy+8);
            CGContextAddLineToPoint(ctx, wx+32, wy+5);
            CGContextMoveToPoint(ctx, wx+10, wy+8);
            CGContextAddLineToPoint(ctx, wx+10, wy+12);
            CGContextStrokePath(ctx);
            if (p.ammo >= 0) {
                NSString* am = [NSString stringWithFormat:@"%d", p.ammo];
                NSDictionary* aa = @{
                    NSFontAttributeName: [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold],
                    NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.3 blue:0.2 alpha:1]
                };
                [am drawAtPoint:CGPointMake(wx+38, wy+2) withAttributes:aa];
            }
            if (p.weapon[0]) {
                NSString* wn = [NSString stringWithUTF8String:p.weapon];
                NSDictionary* wa = @{
                    NSFontAttributeName: [UIFont systemFontOfSize:9 weight:UIFontWeightMedium],
                    NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.4 blue:0.3 alpha:0.95]
                };
                [wn drawAtPoint:CGPointMake(wx, wy+18) withAttributes:wa];
            }
        }

        // ── Distance ──
        if (dist) {
            NSString* ds = [NSString stringWithFormat:@"%.0fm", d];
            NSDictionary* da = @{
                NSFontAttributeName: [UIFont systemFontOfSize:10 weight:UIFontWeightMedium],
                NSForegroundColorAttributeName: [UIColor colorWithWhite:0.85 alpha:0.9]
            };
            CGSize dsZ = [ds sizeWithAttributes:da];
            [ds drawAtPoint:CGPointMake(head.x - dsZ.width*0.5f, feet.y + (weap ? 24 : 4)) withAttributes:da];
        }
    }
}
@end

static ESPView* g_espView = nil;

void Astral_EnsureFOVOverlay(UIWindow* win) {
    if (!win) return;
    UIView* root = win.rootViewController.view ?: win;
    // FORCE full-window frame in root space — origin always (0,0)
    CGRect b = root.bounds;
    if (b.size.width < 2 || b.size.height < 2) {
        b = win.bounds;
    }
    b.origin = CGPointZero;

    if (!g_espView) {
        g_espView = [[ESPView alloc] initWithFrame:b];
        g_espView.userInteractionEnabled = NO;
        g_espView.backgroundColor = UIColor.clearColor;
        g_espView.opaque = NO;
        g_espView.clearsContextBeforeDrawing = YES;
        g_espView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        g_espView.contentMode = UIViewContentModeRedraw;
        [root insertSubview:g_espView atIndex:0];
    } else {
        g_espView.frame = b;
        g_espView.center = CGPointMake(b.size.width * 0.5, b.size.height * 0.5);
        if (g_espView.superview != root) {
            [g_espView removeFromSuperview];
            [root insertSubview:g_espView atIndex:0];
        }
    }
    // Keep ESP under menu/fab
    [root sendSubviewToBack:g_espView];
}


// ─── Aimbot / Silent ─────────────────────────────────────────────────────────
static Vec3 g_silent_dir{};
static bool g_has_silent = false;

static void run_aim(void* cam, void* camTr, CGSize scr) {
    g_has_silent = false;
    if (!g_aimbot.load() && !g_silent.load()) return;
    if (!cam || !camTr) return;

    Vec3 camPos = get_pos(camTr);
    Vec3 camFwd = get_fwd(camTr);
    float maxFov = g_fov.load();

    void* bestTr = nullptr;
    Vec3  bestBone{};
    float bestAng = maxFov;

    int localTeam = -1;
    {
        std::lock_guard<std::mutex> lk(g_plist_mtx);
        for (auto& s : g_plist) if (s.local) { localTeam = s.team; break; }

        for (auto& p : g_plist) {
            if (p.local || p.dead) continue;
            if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

            int boneIdx = g_bone.load();
            float bh = boneIdx==0 ? 1.65f : boneIdx==1 ? 1.45f : 1.15f;
            Vec3 bone = vadd(p.pos, {0, bh, 0});

            Vec3 dir = vnorm(vsub(bone, camPos));
            float c = fmaxf(-1.f, fminf(1.f, vdot(dir, camFwd)));
            float ang = acosf(c) * 57.2957795f;
            if (ang < bestAng) {
                bestAng = ang;
                bestTr = p.tr;
                bestBone = bone;
            }
        }
    }
    if (!bestTr) return;

    Vec3 dir = vnorm(vsub(bestBone, camPos));

    if (g_silent.load()) {
        // silent: store direction for potential bullet-hook; also soft LookAt
        // so crosshair doesn't visibly snap when only silent is on
        g_silent_dir = dir;
        g_has_silent = true;
        // do NOT rotate camera when silent-only — that's the point of silent
        if (!g_aimbot.load()) return;
    }

    if (g_aimbot.load()) {
        float sm = fmaxf(1.f, g_smooth.load());
        // smooth: blend current forward toward target
        Vec3 cur = camFwd;
        Vec3 tgt = dir;
        float t = 1.f / sm;
        Vec3 blended = vnorm({cur.x+(tgt.x-cur.x)*t, cur.y+(tgt.y-cur.y)*t, cur.z+(tgt.z-cur.z)*t});
        Vec3 lookAt = vadd(camPos, vmul(blended, 10.f));
        // prefer LookAt — more stable than raw quat write on this build
        RVA<look_at_t>(Offsets::Transform_LookAt)(camTr, lookAt);
    }
}

// exported for optional bullet-direction patch
extern "C" bool Astral_GetSilentDir(float* x, float* y, float* z) {
    if (!g_has_silent) return false;
    *x = g_silent_dir.x; *y = g_silent_dir.y; *z = g_silent_dir.z;
    return true;
}

// ─── Frame tick ──────────────────────────────────────────────────────────────
void Astral_FeaturesTick() {
    // Always keep ESP view full-screen + redraw (FOV works even pre-match)
    if (g_espView) {
        UIView* root = g_espView.superview;
        if (root) {
            CGRect b = root.bounds;
            b.origin = CGPointZero;
            if (b.size.width > 2 && b.size.height > 2)
                g_espView.frame = b;
        }
        [g_espView setNeedsDisplay];
    }

    if (!unity_base()) return;

    void* cam = main_camera();
    void* camTr = cam ? component_transform(cam) : nullptr;

    if (++g_refresh_ctr >= 12) {
        g_refresh_ctr = 0;
        refresh_players(camTr);
    }

    CGSize scr = UIScreen.mainScreen.bounds.size;
    if (scr.height > scr.width)
        scr = CGSizeMake(scr.height, scr.width);
    if (g_espView && g_espView.bounds.size.width > 10)
        scr = g_espView.bounds.size;
    run_aim(cam, camTr, scr);
}
