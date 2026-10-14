// Features.mm — ESP (bones) / Aim (angles) / Recoil strength 0-100
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
struct Vec4 { float x, y, z, w; };

static inline float vlen(Vec3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline Vec3  vsub(Vec3 a, Vec3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
static inline Vec3  vmul(Vec3 v, float s) { return {v.x*s, v.y*s, v.z*s}; }
static inline float vdot(Vec3 a, Vec3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static inline Vec3  vnorm(Vec3 v) {
    float l = vlen(v);
    if (l < 1e-6f) return {0, 0, 1};
    return {v.x/l, v.y/l, v.z/l};
}
static inline float vdist(Vec3 a, Vec3 b) { return vlen(vsub(a, b)); }

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
template<typename Fn>
static Fn R(uint64_t o) { return (Fn)(unity_base() + o); }

static bool alive(void* o) {
    if (!o) return false;
    uintptr_t a = (uintptr_t)o;
    // reject obvious junk / misaligned
    if (a < 0x10000 || (a & 0x3) != 0) return false;
    return true;
}

static Vec3 get_pos(void* tr) {
    Vec3 o{};
    if (!tr || !unity_base()) return o;
    using F = void (*)(void*, Vec3*);
    R<F>(Offsets::Transform_get_position_Injected)(tr, &o);
    return o;
}
static void* main_cam() {
    if (!unity_base()) return nullptr;
    using F = void* (*)();
    return R<F>(Offsets::Camera_get_main)();
}
static void* get_tr(void* c) {
    if (!c || !unity_base()) return nullptr;
    using F = void* (*)(void*);
    return R<F>(Offsets::Component_get_transform)(c);
}
static void* pc_tr(void* pc) {
    if (!pc) return nullptr;
    void* t = *(void**)((char*)pc + Offsets::PC_transform);
    if (t && alive(t)) return t;
    return get_tr(pc);
}

// WorldToScreen — on iOS Unity already returns UIKit points (not raw pixels)
static Vec3 w2s(void* cam, Vec3 w) {
    Vec3 o{};
    if (!cam || !unity_base()) return o;
    using F = void (*)(void*, Vec3*, int, Vec3*);
    // MonoOrStereoscopicEye.Mono = 0
    R<F>(Offsets::Camera_WorldToScreenPoint_Inj)(cam, &w, 0, &o);
    return o;
}

// BipedMap on PlayerController: _characterBiped @ 0x30, also 0xA8
// BipedMap.Head @ 0x18, Neck 0x20, Spine1 0x28, Hip 0x78
static void* biped_of(void* pc) {
    if (!alive(pc)) return nullptr;
    void* b = nullptr;
    @try {
        b = *(void**)((char*)pc + 0x30);
        if (alive(b)) return b;
        b = *(void**)((char*)pc + 0xA8);
        if (alive(b)) return b;
    } @catch (...) {}
    return nullptr;
}
static Vec3 bone_pos(void* biped, size_t off, Vec3 fallback) {
    if (!alive(biped)) return fallback;
    @try {
        void* t = *(void**)((char*)biped + off);
        if (!alive(t)) return fallback;
        Vec3 p = get_pos(t);
        if (p.x != p.x || fabsf(p.x) > 1e5f || fabsf(p.y) > 1e5f) return fallback;
        // reject if bone is absurdly far from root fallback
        float dx = p.x - fallback.x, dy = p.y - fallback.y, dz = p.z - fallback.z;
        if (dx*dx + dy*dy + dz*dz > 25.f) return fallback; // >5m from root → junk
        return p;
    } @catch (...) {
        return fallback;
    }
}

struct PSnap {
    void* obj;
    void* tr;
    void* biped;
    Vec3  pos;   // hip / root
    Vec3  head;
    Vec3  neck;
    Vec3  chest;
    int   team;
    bool  local;
    char  name[32];
};
static std::mutex g_mtx;
static std::vector<PSnap> g_list;
static int g_ctr = 0;

static int team_of(void* pc) {
    return pc ? (int)*(uint8_t*)((char*)pc + Offsets::PC_team) : -1;
}

static void read_str(void* strObj, char* out, size_t n) {
    out[0] = 0;
    if (!strObj || n < 2) return;
    int32_t len = *(int32_t*)((char*)strObj + 0x10);
    if (len <= 0 || len > 40) return;
    auto* ch = (const uint16_t*)((char*)strObj + 0x14);
    size_t i = 0;
    for (int32_t k = 0; k < len && i + 1 < n; k++) {
        uint16_t c = ch[k];
        out[i++] = (c < 128) ? (char)c : '?';
    }
    out[i] = 0;
}

static void push_array(void* arrObj, std::vector<void*>& out, Il2CppApi& api) {
    if (!arrObj) return;
    auto* a = (Il2CppArraySimple*)arrObj;
    uintptr_t n = a->max_length;
    if (api.array_length)
        n = api.array_length((Il2CppObject*)arrObj);
    if (n > 48) n = 48;
    for (uintptr_t i = 0; i < n; i++) {
        void* o = a->vector[i];
        if (alive(o)) out.push_back(o);
    }
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

    Il2CppClass* objK = api.find_class("UnityEngine", "Object");
    if (objK) {
        const MethodInfo* fot = api.find_method(objK, "FindObjectsOfType", 1);
        if (fot) {
            void* exc = nullptr;
            void* args[1] = { typeObj };
            Il2CppObject* arr = api.runtime_invoke(fot, nullptr, args, &exc);
            if (!exc) push_array(arr, out, api);
        }
    }
    if (out.empty() && unity_base()) {
        using F = void* (*)(void*, bool);
        push_array(R<F>(0x331EBF8)(typeObj, true), out, api);
    }
    if (out.empty() && unity_base()) {
        using F = void* (*)(void*);
        push_array(R<F>(0x3318364)(typeObj), out, api);
    }
    return out;
}

static bool is_mine(void* pc) {
    if (!pc || !unity_base()) return false;
    @try {
        void* pv = *(void**)((char*)pc + Offsets::PC_photonView);
        if (!alive(pv)) return false;
        using F = bool (*)(void*);
        return R<F>(Offsets::PhotonView_get_isMine)(pv);
    } @catch (...) {
        return false;
    }
}

static void refresh(void* camTr) {
    std::vector<PSnap> tmp;
    if (!camTr || !alive(camTr)) {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_list.swap(tmp);
        return;
    }
    auto raw = collect_players();
    Vec3 cpos = get_pos(camTr);

    int mineCount = 0;
    float bestD = 1e9f;
    size_t bestIdx = 0;

    for (void* pc : raw) {
        void* tr = pc_tr(pc);
        if (!tr || !alive(tr)) continue;
        Vec3 root = get_pos(tr);
        if (root.x != root.x || fabsf(root.x) > 1e5f) continue;

        void* biped = biped_of(pc);
        Vec3 head  = bone_pos(biped, 0x18, {root.x, root.y + 1.65f, root.z});
        Vec3 neck  = bone_pos(biped, 0x20, {root.x, root.y + 1.40f, root.z});
        Vec3 chest = bone_pos(biped, 0x28, {root.x, root.y + 1.10f, root.z});
        Vec3 hip   = bone_pos(biped, 0x78, root);

        PSnap s{};
        s.obj   = pc;
        s.tr    = tr;
        s.biped = biped;
        s.pos   = hip;
        s.head  = head;
        s.neck  = neck;
        s.chest = chest;
        s.team  = team_of(pc);
        s.local = is_mine(pc);
        if (s.local) mineCount++;
        float d = vdist(root, cpos);
        if (d < bestD) { bestD = d; bestIdx = tmp.size(); }
        s.name[0] = 0;
        @try {
            void* pp = *(void**)((char*)pc + Offsets::PC_photonPlayer);
            if (alive(pp)) {
                void* ns = *(void**)((char*)pp + Offsets::PP_nameField);
                if (ns) read_str(ns, s.name, sizeof(s.name));
            }
        } @catch (...) {}
        if (!s.name[0]) snprintf(s.name, sizeof(s.name), "P");
        tmp.push_back(s);
    }
    // if isMine found nobody, mark closest as local (deathcam / edge cases)
    if (mineCount == 0 && !tmp.empty() && bestD < 4.f) {
        tmp[bestIdx].local = true;
    }
    std::lock_guard<std::mutex> lk(g_mtx);
    g_list.swap(tmp);
}

@interface ESPView : UIView @end
static ESPView* g_esp = nil;
UIView* g_esp_view(void) { return g_esp; }

@implementation ESPView
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 2 || H < 2) return;

    if (g_fovDraw.load()) {
        CGFloat cx = W * 0.5f, cy = H * 0.5f;
        CGFloat side = W < H ? W : H;
        CGFloat r = side * (0.04f + g_fov.load() / 30.f * 0.20f);
        CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.2 green:0.6 blue:1 alpha:1].CGColor);
        CGContextSetLineWidth(ctx, 2);
        CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));
    }

    bool box = g_espBox.load();
    bool skel = g_espSkel.load();
    bool nameOn = g_espName.load();
    bool distOn = g_espDist.load();
    if (!box && !skel && !nameOn && !distOn) return;

    void* cam = main_cam();
    if (!alive(cam)) return;
    void* camTr = get_tr(cam);
    Vec3 cpos = camTr ? get_pos(camTr) : Vec3{};

    std::vector<PSnap> snap;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        snap = g_list;
    }

    int localTeam = -1;
    for (auto& s : snap) if (s.local) localTeam = s.team;

    for (auto& p : snap) {
        if (p.local) continue;
        if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

        Vec3 sf = w2s(cam, p.pos);
        Vec3 sh = w2s(cam, p.head);
        // behind camera
        if (sf.z < 0.05f && sh.z < 0.05f) continue;

        // Unity screen Y is bottom-up → flip for UIKit
        CGFloat fy = H - sf.y, hy = H - sh.y;
        CGFloat fx = sf.x, hx = sh.x;
        if ((fx < -80 && hx < -80) || (fx > W + 80 && hx > W + 80)) continue;
        if ((fy < -80 && hy < -80) || (fy > H + 80 && hy > H + 80)) continue;

        CGFloat top = fminf(fy, hy);
        CGFloat bot = fmaxf(fy, hy);
        CGFloat hgt = bot - top;
        if (hgt < 12.f) hgt = 40.f;
        CGFloat mid = (fx + hx) * 0.5f;
        CGFloat wid = hgt * 0.42f;
        CGFloat left = mid - wid * 0.5f;

        UIColor* col = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:1];

        if (box) {
            CGContextSetStrokeColorWithColor(ctx, col.CGColor);
            CGContextSetLineWidth(ctx, 1.6);
            CGContextStrokeRect(ctx, CGRectMake(left, top, wid, hgt));
        }
        if (skel) {
            Vec3 sn = w2s(cam, p.neck);
            Vec3 sc = w2s(cam, p.chest);
            CGFloat ny = H - sn.y, cy = H - sc.y;
            CGContextSetStrokeColorWithColor(ctx, col.CGColor);
            CGContextSetLineWidth(ctx, 1.3);
            CGContextMoveToPoint(ctx, hx, hy);
            CGContextAddLineToPoint(ctx, sn.x, ny);
            CGContextAddLineToPoint(ctx, sc.x, cy);
            CGContextAddLineToPoint(ctx, fx, fy);
            CGContextStrokePath(ctx);
            CGContextFillEllipseInRect(ctx, CGRectMake(hx - 3, hy - 3, 6, 6));
        }
        if (nameOn || distOn) {
            NSMutableString* lab = [NSMutableString stringWithUTF8String:p.name];
            if (distOn) {
                float d = vdist(p.pos, cpos);
                [lab appendFormat:@" %.0fm", d];
            }
            [lab drawAtPoint:CGPointMake(left, top - 14)
              withAttributes:@{
                  NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
                  NSForegroundColorAttributeName: [UIColor whiteColor]
              }];
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

// recoilPct 0 = full recoil, 100 = zero recoil
// set absolute multipliers (never compound)
static void apply_recoil(void* localPc) {
    if (!alive(localPc)) return;
    float pct = g_recoilPct.load();
    if (pct < 0.5f) return;

    void* wry = *(void**)((char*)localPc + Offsets::PC_weaponry);
    if (!alive(wry)) return;
    void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
    if (!alive(wc) && unity_base()) {
        using F = void* (*)(void*);
        wc = R<F>(0x162E58C)(wry);
    }
    if (!alive(wc)) return;

    void* params = *(void**)((char*)wc + Offsets::WC_weaponParams);
    if (!alive(params)) return;

    float mul = 1.f - (pct / 100.f);
    if (mul < 0.f) mul = 0.f;

    auto setf = [&](void* b, size_t o, float v) {
        float* p = (float*)((char*)b + o);
        if (*p == *p && fabsf(*p) < 500.f) *p = v;
    };
    // GunParameters multipliers → absolute
    setf(params, Offsets::GP_recoilMultCrouch, mul);
    setf(params, Offsets::GP_recoilAimMult,    mul);
    setf(params, Offsets::GP_recoilAimCrouch,  mul);

    if (pct >= 95.f) {
        int* rc = (int*)((char*)params + Offsets::GP_recoilControl);
        if (*rc >= 0 && *rc < 10000) *rc = 100;
        void* rp = *(void**)((char*)params + Offsets::GP_recoilParams);
        if (alive(rp)) {
            setf(rp, Offsets::RP_horiz,  0.f);
            setf(rp, Offsets::RP_vert,   0.f);
            setf(rp, Offsets::RP_camDev, 0.f);
        }
    }
}

static void run_aim(void* cam, void* camTr) {
    std::vector<PSnap> snap;
    void* localPc = nullptr;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        snap = g_list;
        for (auto& s : snap) if (s.local) localPc = s.obj;
    }

    apply_recoil(localPc);

    if (!g_aimbot.load()) return;
    if (!alive(cam) || !alive(camTr)) return;

    void* aimCtrl = nullptr;
    if (alive(localPc)) {
        aimCtrl = *(void**)((char*)localPc + Offsets::PC_aimController);
    }
    if (!alive(aimCtrl)) return;

    // aim from camTransform of AimController
    void* aimTr = *(void**)((char*)aimCtrl + Offsets::AC_camTransform);
    if (!alive(aimTr)) aimTr = camTr;

    CGSize scr = g_esp ? g_esp.bounds.size : UIScreen.mainScreen.bounds.size;
    float cx = scr.width * 0.5f, cy = scr.height * 0.5f;
    float side = fminf(scr.width, scr.height);
    float fovR = side * (0.05f + g_fov.load() / 30.f * 0.25f);

    Vec3 cpos = get_pos(aimTr);
    int localTeam = -1;
    for (auto& s : snap) if (s.local) localTeam = s.team;

    Vec3 best{};
    bool have = false;
    float bestScore = 1e9f;

    for (auto& p : snap) {
        if (p.local) continue;
        if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

        Vec3 bone = p.head;
        switch (g_bone.load()) {
            case 1: bone = p.neck;  break;
            case 2: bone = p.chest; break;
            default: bone = p.head; break;
        }

        Vec3 sc = w2s(cam, bone);
        if (sc.z < 0.05f) continue;
        float sx = sc.x;
        float sy = scr.height - sc.y;
        float dx = sx - cx, dy = sy - cy;
        float d2 = sqrtf(dx * dx + dy * dy);
        if (d2 > fovR) continue;
        if (d2 < bestScore) {
            bestScore = d2;
            best = bone;
            have = true;
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
    // Unity FPS: pitch = X rotation, yaw = Y rotation
    float yaw   = atan2f(dir.x, dir.z) * 57.2957795f;
    float pitch = -asinf(fmaxf(-1.f, fminf(1.f, dir.y))) * 57.2957795f;

    // write only into AimController angles — clamp to sane range
    @try {
        float* aPitch = (float*)((char*)aimCtrl + Offsets::AC_pitch);
        float* aYaw   = (float*)((char*)aimCtrl + Offsets::AC_yaw);
        if (pitch < -89.f) pitch = -89.f;
        if (pitch >  89.f) pitch =  89.f;
        if (*aPitch == *aPitch && fabsf(*aPitch) < 360.f) *aPitch = pitch;
        if (*aYaw   == *aYaw   && fabsf(*aYaw)   < 500.f) *aYaw   = yaw;
    } @catch (...) {}
}

void Astral_FeaturesTick() {
    @try {
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
        bool wantAim = g_aimbot.load() || g_recoilPct.load() > 0.5f;
        bool wantFov = g_fovDraw.load();
        if (!wantEsp && !wantAim && !wantFov) return;
        if (!unity_base()) return;

        void* cam = main_cam();
        if (!alive(cam)) return;
        void* camTr = get_tr(cam);
        if (!alive(camTr)) return;

        if (wantEsp || wantAim) {
            size_t n = 0;
            {
                std::lock_guard<std::mutex> lk(g_mtx);
                n = g_list.size();
            }
            if (n == 0 || ++g_ctr >= 8) {
                g_ctr = 0;
                refresh(camTr);
            }
        }
        if (wantAim) run_aim(cam, camTr);
    } @catch (...) {}
}
