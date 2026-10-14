// Features.mm — ESP / Aim / FOV — offsets from user dump.cs
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

extern UIView* Astral_SecureRoot;

struct Vec3 { float x, y, z; };

static inline float vlen(Vec3 v) { return sqrtf(v.x*v.x+v.y*v.y+v.z*v.z); }
static inline Vec3  vsub(Vec3 a, Vec3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
static inline Vec3  vadd(Vec3 a, Vec3 b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
static inline Vec3  vmul(Vec3 v, float s) { return {v.x*s, v.y*s, v.z*s}; }
static inline Vec3  vnorm(Vec3 v) { float l=vlen(v); return l<1e-6f?Vec3{0,0,1}:Vec3{v.x/l,v.y/l,v.z/l}; }
static inline float vdist(Vec3 a, Vec3 b) { return vlen(vsub(a,b)); }

// ── Unity base ───────────────────────────────────────────────────────────────
static uintptr_t g_unity = 0;
static uintptr_t unity_base() {
    if (g_unity) return g_unity;
    uint32_t n = _dyld_image_count();
    for (uint32_t i = 0; i < n; i++) {
        const char* nm = _dyld_get_image_name(i);
        if (nm && strstr(nm, "UnityFramework")) {
            g_unity = (uintptr_t)_dyld_get_image_header(i);
            break;
        }
    }
    return g_unity;
}
template<typename Fn> static Fn R(uint64_t off) { return (Fn)(unity_base() + off); }

static bool alive(void* o) {
    if (!o || ((uintptr_t)o & 7)) return false;
    return *(void**)((char*)o + 0x10) != nullptr; // m_CachedPtr
}

// Injected / direct from dump
static Vec3 get_pos(void* tr) {
    Vec3 o{};
    if (!tr || !unity_base()) return o;
    using F = void(*)(void*, Vec3*);
    R<F>(Offsets::Transform_get_position_Injected)(tr, &o);
    return o;
}
static void* main_cam() {
    if (!unity_base()) return nullptr;
    using F = void*(*)();
    return R<F>(Offsets::Camera_get_main)();
}
static void* get_tr(void* comp) {
    if (!comp || !unity_base()) return nullptr;
    using F = void*(*)(void*);
    return R<F>(Offsets::Component_get_transform)(comp);
}
static void* pc_tr(void* pc) {
    if (!pc) return nullptr;
    void* t = *(void**)((char*)pc + Offsets::PC_transform);
    if (t && alive(t)) return t;
    return get_tr(pc);
}
static Vec3 w2s(void* cam, Vec3 w) {
    Vec3 o{};
    if (!cam || !unity_base()) return o;
    using F = void(*)(void*, Vec3*, int, Vec3*);
    R<F>(Offsets::Camera_WorldToScreenPoint_Inj)(cam, &w, 2, &o);
    if (o.z == 0 && o.x == 0 && o.y == 0)
        R<F>(Offsets::Camera_WorldToScreenPoint_Inj)(cam, &w, 0, &o);
    return o;
}
static void look_at(void* tr, Vec3 pt) {
    if (!tr || !unity_base()) return;
    Vec3 up{0,1,0};
    using F = void(*)(void*, Vec3*, Vec3*);
    R<F>(Offsets::Transform_Internal_LookAt_Inj)(tr, &pt, &up);
}

// ── Player list ──────────────────────────────────────────────────────────────
struct PSnap {
    void* obj; void* tr; Vec3 pos;
    float hp; int team; bool local; bool dead;
    char name[32]; char weapon[24]; int ammo;
};
static std::mutex g_mtx;
static std::vector<PSnap> g_list;
static int g_ctr = 0;

static int team_of(void* pc) {
    if (!pc) return -1;
    return (int)*(uint8_t*)((char*)pc + Offsets::PC_team);
}

static void read_str(void* strObj, char* out, size_t n) {
    out[0]=0; if (!strObj||n==0) return;
    int32_t len = *(int32_t*)((char*)strObj + 0x10);
    if (len<=0||len>48) return;
    auto* ch = (const uint16_t*)((char*)strObj + 0x14);
    size_t i=0;
    for (int32_t k=0;k<len && i+1<n;k++) {
        uint16_t c=ch[k]; out[i++] = (c<128)?(char)c:'?';
    }
    out[i]=0;
}

static void fill_nick(void* pc, char* out, size_t n) {
    snprintf(out, n, "Enemy");
    if (!alive(pc)) return;
    void* pp = *(void**)((char*)pc + Offsets::PC_photonPlayer);
    if (!alive(pp)) return;
    void* s = *(void**)((char*)pp + Offsets::PP_nameField);
    if (s) { char tmp[32]; read_str(s, tmp, sizeof(tmp)); if (tmp[0]) snprintf(out,n,"%s",tmp); }
}

static std::vector<void*> collect_players() {
    std::vector<void*> out;
    auto& api = IL2CPP();
    if (!api.ready && !api.init()) return out;

    Il2CppClass* pcK = api.find_class("Axlebolt.Standoff.Player", "PlayerController");
    if (!pcK) pcK = api.find_class("", "PlayerController");
    if (!pcK) pcK = api.find_class("Assembly-CSharp", "PlayerController");
    if (!pcK) return out;

    // Build System.Type for PlayerController
    if (!api.class_get_type || !api.type_get_object) return out;
    const Il2CppType* ty = api.class_get_type(pcK);
    if (!ty) return out;
    Il2CppObject* typeObj = api.type_get_object(ty);
    if (!typeObj) return out;

    auto push_arr = [&](Il2CppObject* arrObj) {
        if (!arrObj) return;
        auto* a = (Il2CppArraySimple*)arrObj;
        uintptr_t n = a->max_length;
        if (api.array_length) n = api.array_length(arrObj);
        if (n > 64) n = 64;
        void** items = &a->vector[0];
        for (uintptr_t i = 0; i < n; i++) {
            void* o = items[i];
            if (alive(o)) out.push_back(o);
        }
    };

    // Path A: Object.FindObjectsOfType(Type, true) via IL2CPP invoke
    Il2CppClass* objK = api.find_class("UnityEngine", "Object");
    if (objK) {
        const MethodInfo* fot2 = api.find_method(objK, "FindObjectsOfType", 2);
        const MethodInfo* fot1 = api.find_method(objK, "FindObjectsOfType", 1);
        void* exc = nullptr;
        if (fot2) {
            // includeInactive = true as bool in arg — for value types pass pointer
            bool inc = true;
            void* args[2] = { typeObj, &inc };
            Il2CppObject* arr = api.runtime_invoke(fot2, nullptr, args, &exc);
            if (!exc) push_arr(arr);
        }
        if (out.empty() && fot1) {
            exc = nullptr;
            void* args[1] = { typeObj };
            Il2CppObject* arr = api.runtime_invoke(fot1, nullptr, args, &exc);
            if (!exc) push_arr(arr);
        }
    }
    if (!out.empty()) return out;

    // Path B: direct RVA Object.FindObjectsOfType(Type, bool) 0x331EBF8
    if (unity_base()) {
        using fot_t = void*(*)(void* type, bool includeInactive);
        void* arr = R<fot_t>(0x331EBF8)(typeObj, true);
        if (arr) push_arr((Il2CppObject*)arr);
    }
    if (!out.empty()) return out;

    // Path C: Resources.FindObjectsOfTypeAll 0x3318364
    if (unity_base()) {
        using fot_t = void*(*)(void* type);
        void* arr = R<fot_t>(0x3318364)(typeObj);
        if (arr) push_arr((Il2CppObject*)arr);
    }
    if (!out.empty()) return out;

    // Path D: PlayerManager
    Il2CppClass* pmK = api.find_class("Axlebolt.Standoff.Player", "PlayerManager");
    if (!pmK) return out;
    Il2CppObject* inst = nullptr;
    // LazySingleton<object> getter RVA 0x2467A28 is generic — use method name
    for (const char* gn : {"get_HGGHFBCAGEEGBDH", "GHAFGAACAEHABEF", "get_Instance"}) {
        const MethodInfo* m = api.find_method(pmK, gn, 0);
        if (!m) continue;
        void* exc = nullptr;
        inst = api.runtime_invoke(m, nullptr, nullptr, &exc);
        if (!exc && alive(inst)) break;
        inst = nullptr;
    }
    // Direct: get_CEADFCHEEGGGDHC at 0x1627FFC needs instance
    if (alive(inst)) {
        void* la = *(void**)((char*)inst + Offsets::PM_localA);
        void* lb = *(void**)((char*)inst + Offsets::PM_localB);
        if (alive(la)) out.push_back(la);
        if (alive(lb) && lb != la) out.push_back(lb);

        using geths_t = void*(*)(void*);
        void* hs = nullptr;
        if (unity_base())
            hs = R<geths_t>(0x1627FFC)(inst); // get_CEADFCHEEGGGDHC
        if (!alive(hs))
            hs = *(void**)((char*)inst + Offsets::PM_hashset);
        if (alive(hs)) {
            // HashSet: _slots often at 0x18, count at 0x20
            void* slots = *(void**)((char*)hs + 0x18);
            if (!slots) slots = *(void**)((char*)hs + 0x10);
            if (slots) {
                auto* a = (Il2CppArraySimple*)slots;
                uintptr_t n = a->max_length;
                if (n > 0 && n <= 512) {
                    uint8_t* base = (uint8_t*)&a->vector[0];
                    for (uintptr_t i = 0; i < n && out.size() < 32; i++) {
                        void* val = *(void**)(base + i * 16 + 8);
                        if (!alive(val)) continue;
                        bool d = false;
                        for (void* e : out) if (e == val) { d = true; break; }
                        if (!d) out.push_back(val);
                    }
                }
            }
        }
    }
    return out;
}

static void refresh(void* camTr) {
    std::vector<PSnap> tmp;
    if (!camTr || !alive(camTr)) {
        std::lock_guard<std::mutex> lk(g_mtx); g_list.swap(tmp); return;
    }
    auto raw = collect_players();
    Vec3 cpos = get_pos(camTr);
    void* local = nullptr; float best = 1e9f;
    for (void* pc : raw) {
        void* tr = pc_tr(pc); if (!tr||!alive(tr)) continue;
        float d = vdist(get_pos(tr), cpos);
        if (d < best) { best=d; local=pc; }
    }
    if (best > 20.f) local = nullptr;

    for (void* pc : raw) {
        if (!alive(pc)) continue;
        void* tr = pc_tr(pc); if (!tr||!alive(tr)) continue;
        Vec3 p = get_pos(tr);
        if (p.x!=p.x || fabsf(p.x)>1e5f) continue;
        PSnap s{};
        s.obj=pc; s.tr=tr; s.pos=p;
        s.team=team_of(pc); s.local=(pc==local);
        s.hp=100.f; s.dead=false; s.ammo=-1;
        fill_nick(pc, s.name, sizeof(s.name));
        s.weapon[0]=0;
        void* wry = *(void**)((char*)pc + Offsets::PC_weaponry);
        if (alive(wry)) {
            void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
            if (alive(wc)) {
                void* ns = *(void**)((char*)wc + Offsets::WCtrl_nameStr);
                if (ns) read_str(ns, s.weapon, sizeof(s.weapon));
                int am = *(int*)((char*)wc + Offsets::WCtrl_intA);
                if (am>=0 && am<400) s.ammo=am;
            }
        }
        tmp.push_back(s);
    }
    std::lock_guard<std::mutex> lk(g_mtx); g_list.swap(tmp);
}

// ── ESP view ─────────────────────────────────────────────────────────────────
@interface ESPView : UIView @end
static ESPView* g_esp = nil;

@implementation ESPView
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 2 || H < 2) return;

    // FOV always when enabled
    if (g_fovDraw.load()) {
        CGFloat cx=W*0.5f, cy=H*0.5f;
        CGFloat side = W<H?W:H;
        CGFloat r = side * (0.04f + (g_fov.load()/30.f)*0.20f);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.25 green:0.65 blue:1 alpha:0.95].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(cx-r, cy-r, r*2, r*2));
        CGContextSetLineWidth(ctx, 1.2);
        CGContextMoveToPoint(ctx, cx-6, cy); CGContextAddLineToPoint(ctx, cx+6, cy);
        CGContextMoveToPoint(ctx, cx, cy-6); CGContextAddLineToPoint(ctx, cx, cy+6);
        CGContextStrokePath(ctx);
    }

    bool box=g_espBox.load(), skel=g_espSkel.load(), name=g_espName.load();
    bool hp=g_espHP.load(), weap=g_espWeapon.load(), dist=g_espDist.load();
    if (!box && !skel && !name && !hp && !weap && !dist) return;

    void* cam = main_cam();
    if (!cam || !alive(cam)) return;
    void* camTr = get_tr(cam);
    Vec3 cpos = camTr ? get_pos(camTr) : Vec3{};

    int localTeam = -1;
    std::vector<PSnap> snap;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        snap = g_list;
        for (auto& s : snap) if (s.local) localTeam = s.team;
    }

    for (auto& p : snap) {
        if (p.local || p.dead) continue;
        if (g_espTeam.load() && localTeam>=0 && p.team==localTeam) continue;

        Vec3 feet = p.pos;
        Vec3 head = vadd(p.pos, {0, 1.75f, 0});
        Vec3 sf = w2s(cam, feet);
        Vec3 sh = w2s(cam, head);
        // behind camera
        if (sf.z < 0.1f && sh.z < 0.1f) continue;

        // Unity screen y is bottom-up
        CGFloat fy = H - sf.y, hy = H - sh.y;
        CGFloat fx = sf.x, hx = sh.x;
        CGFloat top = fminf(fy, hy), bot = fmaxf(fy, hy);
        CGFloat hgt = bot - top;
        if (hgt < 4) hgt = 40;
        CGFloat mid = (fx+hx)*0.5f;
        CGFloat wid = hgt * 0.45f;
        CGFloat left = mid - wid*0.5f;

        UIColor* col = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:0.95];

        if (box) {
            CGContextSetStrokeColorWithColor(ctx, col.CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, CGRectMake(left, top, wid, hgt));
        }
        if (skel) {
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:0.9].CGColor);
            CGContextSetLineWidth(ctx, 1.2);
            CGContextMoveToPoint(ctx, hx, hy);
            CGContextAddLineToPoint(ctx, fx, fy);
            CGContextStrokePath(ctx);
            // head dot
            CGContextSetFillColorWithColor(ctx, col.CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(hx-3, hy-3, 6, 6));
        }
        if (hp) {
            CGFloat pct = fmaxf(0, fminf(1, p.hp/100.f));
            CGFloat bh = hgt * pct;
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.1 green:0.9 blue:0.3 alpha:0.9].CGColor);
            CGContextFillRect(ctx, CGRectMake(left-5, bot-bh, 3, bh));
        }
        if (name || dist || weap) {
            NSMutableString* lab = [NSMutableString string];
            if (name) [lab appendFormat:@"%s", p.name];
            if (dist) {
                float d = vdist(p.pos, cpos);
                if (lab.length) [lab appendString:@" "];
                [lab appendFormat:@"%.0fm", d];
            }
            if (weap && p.weapon[0]) {
                if (lab.length) [lab appendString:@"\n"];
                [lab appendFormat:@"%s", p.weapon];
                if (p.ammo>=0) [lab appendFormat:@" %d", p.ammo];
            }
            if (lab.length) {
                NSDictionary* attrs = @{
                    NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                    NSForegroundColorAttributeName: [UIColor colorWithRed:0.7 green:0.4 blue:1 alpha:1]
                };
                [lab drawAtPoint:CGPointMake(left, top-14) withAttributes:attrs];
            }
        }
    }
}
@end

void Astral_EnsureFOVOverlay(UIWindow* win) {
    if (!win) return;
    UIView* host = win.rootViewController.view ?: (UIView*)win;
    UIView* root = Astral_SecureRoot ?: host;
    CGRect b = host.bounds;
    if (b.size.width < 2) b = win.bounds;
    b.origin = CGPointZero;
    if (!g_esp) {
        g_esp = [[ESPView alloc] initWithFrame:b];
        g_esp.userInteractionEnabled = NO;
        g_esp.opaque = NO;
        g_esp.backgroundColor = UIColor.clearColor;
        g_esp.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        [root addSubview:g_esp];
    } else {
        g_esp.frame = b;
        g_esp.userInteractionEnabled = NO;
        if (g_esp.superview != root) {
            [g_esp removeFromSuperview];
            [root addSubview:g_esp];
        }
    }
}

// ── Aim ──────────────────────────────────────────────────────────────────────
static void run_aim(void* cam, void* camTr) {
    if (!g_aimbot.load() && !g_silent.load()) return;
    if (!cam || !camTr) return;
    Vec3 cpos = get_pos(camTr);
    float maxR = 5.f + g_fov.load() * 2.f; // soft distance gate

    void* bestTr = nullptr; Vec3 bestBone{}; float best = 1e9f;
    int localTeam = -1;
    std::vector<PSnap> snap;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        snap = g_list;
        for (auto& s: snap) if (s.local) localTeam = s.team;
    }
    for (auto& p : snap) {
        if (p.local || p.dead) continue;
        if (g_espTeam.load() && localTeam>=0 && p.team==localTeam) continue;
        Vec3 bone = vadd(p.pos, {0, 1.55f, 0});
        float d = vdist(bone, cpos);
        if (d < best) { best=d; bestTr=p.tr; bestBone=bone; }
    }
    if (!bestTr || best > 80.f) return;

    if (g_aimbot.load()) {
        float sm = fmaxf(1.f, g_smooth.load());
        Vec3 cur = cpos;
        // smooth: look toward point between current forward target and bone
        Vec3 target = bestBone;
        // simple: look_at each frame with slight lag via mixing positions
        static Vec3 smTarget = bestBone;
        smTarget.x += (target.x - smTarget.x) / sm;
        smTarget.y += (target.y - smTarget.y) / sm;
        smTarget.z += (target.z - smTarget.z) / sm;
        look_at(camTr, smTarget);
    }
}

void Astral_FeaturesTick() {
    if (g_esp) {
        UIView* root = g_esp.superview;
        if (root) {
            CGRect b = root.bounds;
            if (b.size.width < 2) b = UIScreen.mainScreen.bounds;
            b.origin = CGPointZero;
            g_esp.frame = b;
        }
        [g_esp setNeedsDisplay];
    }

    bool wantEsp = g_espBox.load()||g_espSkel.load()||g_espName.load()
                ||g_espHP.load()||g_espWeapon.load()||g_espDist.load()||g_fovDraw.load();
    bool wantAim = g_aimbot.load()||g_silent.load();
    if (!wantEsp && !wantAim) return;
    if (!unity_base()) return;

    void* cam = main_cam();
    if (!alive(cam)) return;
    void* camTr = get_tr(cam);
    if (!alive(camTr)) return;

    if (++g_ctr >= 15) {
        g_ctr = 0;
        refresh(camTr);
    }
    if (wantAim) run_aim(cam, camTr);
}
