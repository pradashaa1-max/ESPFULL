// Features.mm — simple reliable ESP + aim (dump offsets)
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

struct Vec3 { float x,y,z; };
struct Vec4 { float x,y,z,w; };

static inline float vlen(Vec3 v){ return sqrtf(v.x*v.x+v.y*v.y+v.z*v.z); }
static inline Vec3  vsub(Vec3 a,Vec3 b){ return {a.x-b.x,a.y-b.y,a.z-b.z}; }
static inline Vec3  vadd(Vec3 a,Vec3 b){ return {a.x+b.x,a.y+b.y,a.z+b.z}; }
static inline Vec3  vmul(Vec3 v,float s){ return {v.x*s,v.y*s,v.z*s}; }
static inline Vec3  vnorm(Vec3 v){ float l=vlen(v); return l<1e-6f?Vec3{0,0,1}:{v.x/l,v.y/l,v.z/l}; }
static inline float vdist(Vec3 a,Vec3 b){ return vlen(vsub(a,b)); }

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
template<typename Fn> static Fn R(uint64_t o){ return (Fn)(unity_base()+o); }

static bool alive(void* o) {
    if (!o || ((uintptr_t)o & 7)) return false;
    return *(void**)((char*)o + 0x10) != nullptr;
}

static Vec3 get_pos(void* tr) {
    Vec3 o{};
    if (!tr || !unity_base()) return o;
    using F = void(*)(void*, Vec3*);
    R<F>(Offsets::Transform_get_position_Injected)(tr, &o);
    return o;
}
static void* main_cam() {
    if (!unity_base()) return nullptr;
    return R<void*(*)()>(Offsets::Camera_get_main)();
}
static void* get_tr(void* c) {
    if (!c || !unity_base()) return nullptr;
    return R<void*(*)(void*)>(Offsets::Component_get_transform)(c);
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
    return o;
}
static void set_rot(void* tr, Vec4 q) {
    if (!tr || !unity_base()) return;
    using F = void(*)(void*, Vec4*);
    R<F>(0x3323EAC)(tr, &q); // set_rotation_Injected
}
static void look_at(void* tr, Vec3 world) {
    if (!tr || !unity_base()) return;
    Vec3 up{0,1,0};
    using F = void(*)(void*, Vec3*, Vec3*);
    R<F>(Offsets::Transform_Internal_LookAt_Inj)(tr, &world, &up);
}

// quat from forward direction
static Vec4 quat_from_dir(Vec3 f) {
    f = vnorm(f);
    Vec3 up{0,1,0};
    if (fabsf(vdot(f, up)) > 0.99f) up = {1,0,0};
    Vec3 r = vnorm({up.y*f.z - up.z*f.y, up.z*f.x - up.x*f.z, up.x*f.y - up.y*f.x});
    Vec3 u = {f.y*r.z - f.z*r.y, f.z*r.x - f.x*r.z, f.x*r.y - f.y*r.x};
    float t = r.x + u.y + f.z;
    Vec4 q;
    if (t > 0) {
        float s = 0.5f / sqrtf(t + 1.f);
        q.w = 0.25f / s; q.x = (u.z - f.y)*s; q.y = (f.x - r.z)*s; q.z = (r.y - u.x)*s;
    } else if (r.x > u.y && r.x > f.z) {
        float s = 2.f * sqrtf(1.f + r.x - u.y - f.z);
        q.w = (u.z - f.y)/s; q.x = 0.25f*s; q.y = (u.x + r.y)/s; q.z = (f.x + r.z)/s;
    } else if (u.y > f.z) {
        float s = 2.f * sqrtf(1.f + u.y - r.x - f.z);
        q.w = (f.x - r.z)/s; q.x = (u.x + r.y)/s; q.y = 0.25f*s; q.z = (f.y + u.z)/s;
    } else {
        float s = 2.f * sqrtf(1.f + f.z - r.x - u.y);
        q.w = (r.y - u.x)/s; q.x = (f.x + r.z)/s; q.y = (f.y + u.z)/s; q.z = 0.25f*s;
    }
    return q;
}

struct PSnap {
    void* obj; void* tr; Vec3 pos;
    int team; bool local;
    char name[32];
};
static std::mutex g_mtx;
static std::vector<PSnap> g_list;
static int g_ctr = 0;

static int team_of(void* pc) {
    return pc ? (int)*(uint8_t*)((char*)pc + Offsets::PC_team) : -1;
}

static void read_str(void* strObj, char* out, size_t n) {
    out[0]=0; if (!strObj||n<2) return;
    int32_t len = *(int32_t*)((char*)strObj + 0x10);
    if (len<=0||len>40) return;
    auto* ch = (const uint16_t*)((char*)strObj + 0x14);
    size_t i=0;
    for (int32_t k=0;k<len && i+1<n;k++) {
        uint16_t c=ch[k]; out[i++] = (c<128)?(char)c:'?';
    }
    out[i]=0;
}

static std::vector<void*> collect_players() {
    std::vector<void*> out;
    auto& api = IL2CPP();
    if (!api.ready && !api.init()) return out;

    Il2CppClass* pcK = api.find_class("Axlebolt.Standoff.Player", "PlayerController");
    if (!pcK) pcK = api.find_class("", "PlayerController");
    if (!pcK) return out;
    if (!api.class_get_type || !api.type_get_object) return out;

    const Il2CppType* ty = api.class_get_type(pcK);
    Il2CppObject* typeObj = ty ? api.type_get_object(ty) : nullptr;
    if (!typeObj) return out;

    auto push = [&](void* arrObj) {
        if (!arrObj) return;
        auto* a = (Il2CppArraySimple*)arrObj;
        uintptr_t n = a->max_length;
        if (api.array_length) n = api.array_length(arrObj);
        if (n > 48) n = 48;
        for (uintptr_t i = 0; i < n; i++) {
            void* o = a->vector[i];
            if (alive(o)) out.push_back(o);
        }
    };

    Il2CppClass* objK = api.find_class("UnityEngine", "Object");
    if (objK) {
        const MethodInfo* fot = api.find_method(objK, "FindObjectsOfType", 1);
        if (fot) {
            void* exc = nullptr;
            void* args[1] = { typeObj };
            push(api.runtime_invoke(fot, nullptr, args, &exc));
        }
    }
    if (out.empty() && unity_base()) {
        using F = void*(*)(void*, bool);
        push(R<F>(0x331EBF8)(typeObj, true));
    }
    if (out.empty() && unity_base()) {
        using F = void*(*)(void*);
        push(R<F>(0x3318364)(typeObj));
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

    // local = closest to camera (no isMine — was unreliable)
    void* local = nullptr;
    float best = 1e9f;
    for (void* pc : raw) {
        void* tr = pc_tr(pc);
        if (!tr || !alive(tr)) continue;
        float d = vdist(get_pos(tr), cpos);
        if (d < best) { best = d; local = pc; }
    }

    for (void* pc : raw) {
        void* tr = pc_tr(pc);
        if (!tr || !alive(tr)) continue;
        Vec3 p = get_pos(tr);
        if (p.x != p.x) continue;
        PSnap s{};
        s.obj = pc; s.tr = tr; s.pos = p;
        s.team = team_of(pc);
        s.local = (pc == local && best < 3.5f);
        s.name[0] = 0;
        void* pp = *(void**)((char*)pc + Offsets::PC_photonPlayer);
        if (alive(pp)) {
            void* ns = *(void**)((char*)pp + Offsets::PP_nameField);
            if (ns) read_str(ns, s.name, sizeof(s.name));
        }
        if (!s.name[0]) snprintf(s.name, sizeof(s.name), "P");
        tmp.push_back(s);
    }
    std::lock_guard<std::mutex> lk(g_mtx);
    g_list.swap(tmp);
}

@interface ESPView : UIView @end
static ESPView* g_esp = nil;

@implementation ESPView
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (W < 2 || H < 2) return;

    if (g_fovDraw.load()) {
        CGFloat cx = W*0.5f, cy = H*0.5f;
        CGFloat side = W < H ? W : H;
        CGFloat r = side * (0.04f + g_fov.load()/30.f * 0.20f);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:1].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(cx-r, cy-r, r*2, r*2));
    }

    bool box = g_espBox.load(), skel = g_espSkel.load(), nameOn = g_espName.load();
    bool distOn = g_espDist.load();
    if (!box && !skel && !nameOn && !distOn) return;

    void* cam = main_cam();
    if (!alive(cam)) return;
    void* camTr = get_tr(cam);
    Vec3 cpos = camTr ? get_pos(camTr) : Vec3{};

    std::vector<PSnap> snap;
    { std::lock_guard<std::mutex> lk(g_mtx); snap = g_list; }

    int localTeam = -1;
    for (auto& s : snap) if (s.local) localTeam = s.team;

    for (auto& p : snap) {
        if (p.local) continue;
        if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

        Vec3 feet = p.pos;
        Vec3 head = {p.pos.x, p.pos.y + 1.7f, p.pos.z};
        Vec3 sf = w2s(cam, feet);
        Vec3 sh = w2s(cam, head);

        // Accept if either point has positive depth
        if (sf.z < 0.05f && sh.z < 0.05f) continue;
        // Also skip if completely off-screen far
        CGFloat fy = H - sf.y, hy = H - sh.y;
        CGFloat fx = sf.x, hx = sh.x;
        if ((fx < -200 && hx < -200) || (fx > W+200 && hx > W+200)) continue;

        CGFloat top = fminf(fy, hy), bot = fmaxf(fy, hy);
        CGFloat hgt = bot - top;
        if (hgt < 8.f) hgt = 50.f;
        CGFloat mid = (fx + hx) * 0.5f;
        CGFloat wid = hgt * 0.5f;
        CGFloat left = mid - wid * 0.5f;

        UIColor* col = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:1];

        if (box) {
            CGContextSetStrokeColorWithColor(ctx, col.CGColor);
            CGContextSetLineWidth(ctx, 1.6);
            CGContextStrokeRect(ctx, CGRectMake(left, top, wid, hgt));
        }
        if (skel) {
            CGContextSetStrokeColorWithColor(ctx, col.CGColor);
            CGContextSetLineWidth(ctx, 1.2);
            CGContextMoveToPoint(ctx, hx, hy);
            CGContextAddLineToPoint(ctx, fx, fy);
            CGContextStrokePath(ctx);
            CGContextFillEllipseInRect(ctx, CGRectMake(hx-3, hy-3, 6, 6));
        }
        if (nameOn || distOn) {
            NSMutableString* lab = [NSMutableString stringWithUTF8String:p.name];
            if (distOn) {
                float d = vdist(p.pos, cpos);
                [lab appendFormat:@" %.0fm", d];
            }
            [lab drawAtPoint:CGPointMake(left, top - 12)
              withAttributes:@{ NSFontAttributeName:[UIFont boldSystemFontOfSize:11],
                                NSForegroundColorAttributeName:[UIColor whiteColor] }];
        }
    }
}
@end

void Astral_EnsureFOVOverlay(UIWindow* win) {
    if (!win) return;
    UIView* host = win.rootViewController.view ?: (UIView*)win;
    UIView* root = Astral_SecureRoot ?: host;
    CGRect b = host.bounds;
    if (b.size.width < 2) b = UIScreen.mainScreen.bounds;
    b.origin = CGPointZero;
    if (!g_esp) {
        g_esp = [[ESPView alloc] initWithFrame:b];
        g_esp.userInteractionEnabled = NO;
        g_esp.opaque = NO;
        g_esp.backgroundColor = UIColor.clearColor;
        g_esp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root addSubview:g_esp];
    } else {
        g_esp.frame = b;
        if (g_esp.superview != root) {
            [g_esp removeFromSuperview];
            [root addSubview:g_esp];
        }
    }
}

static void apply_norecoil(void* localPc) {
    if (!g_noRecoil.load() || !alive(localPc)) return;
    void* wry = *(void**)((char*)localPc + Offsets::PC_weaponry);
    if (!alive(wry)) return;
    void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
    if (!alive(wc)) return;
    auto z = [](void* b, size_t o) {
        float* p = (float*)((char*)b + o);
        if (*p == *p && fabsf(*p) < 500.f) *p = 0.f;
    };
    z(wc, Offsets::WC_recoilMultCrouch);
    z(wc, Offsets::WC_recoilAimMult);
    z(wc, Offsets::WC_recoilAimCrouch);
}

static void run_aim(void* cam, void* camTr) {
    std::vector<PSnap> snap;
    void* localPc = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        snap = g_list;
        for (auto& s : snap) if (s.local) localPc = s.obj;
    }

    if (g_noRecoil.load() && alive(localPc)) {
        void* wry = *(void**)((char*)localPc + Offsets::PC_weaponry);
        if (alive(wry)) {
            // Prefer property path via field 0x98
            void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
            if (!alive(wc) && unity_base()) {
                using F = void*(*)(void*);
                wc = R<F>(0x162E58C)(wry); // get_ADFFFAGDHFAHEBE
            }
            if (alive(wc)) {
                auto z = [](void* b, size_t o) {
                    float* p = (float*)((char*)b + o);
                    if (*p == *p && fabsf(*p) < 500.f) *p = 0.f;
                };
                z(wc, Offsets::WC_recoilMultCrouch);
                z(wc, Offsets::WC_recoilAimMult);
                z(wc, Offsets::WC_recoilAimCrouch);
                // also zero recoil control int as 0
                int* rc = (int*)((char*)wc + Offsets::WC_recoilControl);
                if (*rc >= 0 && *rc < 10000) *rc = 100; // max control
            }
        }
    }

    if (!g_aimbot.load()) return;
    if (!alive(cam) || !alive(camTr)) return;

    void* aimTr = camTr;
    void* aimCtrl = nullptr;
    if (alive(localPc)) {
        aimCtrl = *(void**)((char*)localPc + Offsets::PC_aimController);
        if (alive(aimCtrl)) {
            void* ct = *(void**)((char*)aimCtrl + Offsets::AC_camTransform);
            if (alive(ct)) aimTr = ct;
        }
    }

    CGSize scr = g_esp ? g_esp.bounds.size : UIScreen.mainScreen.bounds.size;
    float cx = scr.width * 0.5f, cy = scr.height * 0.5f;
    // Wide FOV for aim so it always finds someone
    float fovR = fminf(scr.width, scr.height) * 0.45f;
    if (g_fovDraw.load())
        fovR = fminf(scr.width, scr.height) * (0.05f + g_fov.load()/30.f * 0.25f);

    Vec3 best{}; bool have = false; float bestScore = 1e9f;
    Vec3 cpos = get_pos(aimTr);

    for (auto& p : snap) {
        if (p.local) continue;
        Vec3 bone = {p.pos.x, p.pos.y + 1.5f, p.pos.z};
        Vec3 sc = w2s(cam, bone);
        if (sc.z < 0.02f) continue;
        float sx = sc.x, sy = scr.height - sc.y;
        float dx = sx - cx, dy = sy - cy;
        float d2 = sqrtf(dx*dx + dy*dy);
        if (d2 > fovR) continue;
        if (d2 < bestScore) { bestScore = d2; best = bone; have = true; }
    }
    if (!have) {
        // fallback: nearest world enemy regardless of FOV
        for (auto& p : snap) {
            if (p.local) continue;
            float d = vdist(p.pos, cpos);
            if (d < bestScore && d < 60.f) {
                bestScore = d;
                best = {p.pos.x, p.pos.y + 1.5f, p.pos.z};
                have = true;
            }
        }
    }
    if (!have) return;

    float sm = fmaxf(1.f, g_smooth.load());
    static Vec3 smT{};
    static bool ini = false;
    if (!ini) { smT = best; ini = true; }
    smT.x += (best.x - smT.x) / sm;
    smT.y += (best.y - smT.y) / sm;
    smT.z += (best.z - smT.z) / sm;

    Vec3 dir = vnorm(vsub(smT, cpos));
    // euler degrees
    float yaw = atan2f(dir.x, dir.z) * 57.2957795f;
    float pitch = -asinf(fmaxf(-1.f, fminf(1.f, dir.y))) * 57.2957795f;

    // 1) LookAt
    look_at(aimTr, smT);
    set_rot(aimTr, quat_from_dir(dir));

    // 2) AimController angle floats (0x164 / 0x168)
    if (alive(aimCtrl)) {
        float* a0 = (float*)((char*)aimCtrl + 0x164);
        float* a1 = (float*)((char*)aimCtrl + 0x168);
        if (*a0 == *a0 && fabsf(*a0) < 360.f) *a0 = pitch;
        if (*a1 == *a1 && fabsf(*a1) < 360.f) *a1 = yaw;
    }

    if (aimTr != camTr) {
        look_at(camTr, smT);
        set_rot(camTr, quat_from_dir(dir));
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

    bool wantEsp = g_espBox.load() || g_espSkel.load() || g_espName.load() || g_espDist.load();
    bool wantAim = g_aimbot.load() || g_noRecoil.load();
    bool wantFov = g_fovDraw.load();
    if (!wantEsp && !wantAim && !wantFov) return;
    if (!unity_base()) return;

    void* cam = main_cam();
    if (!alive(cam)) return;
    void* camTr = get_tr(cam);
    if (!alive(camTr)) return;

    if (wantEsp || wantAim) {
        size_t n = 0;
        { std::lock_guard<std::mutex> lk(g_mtx); n = g_list.size(); }
        // Aggressive refresh if empty, else every 10 frames
        if (n == 0 || ++g_ctr >= 10) {
            g_ctr = 0;
            refresh(camTr);
        }
    }
    if (wantAim) run_aim(cam, camTr);
}
