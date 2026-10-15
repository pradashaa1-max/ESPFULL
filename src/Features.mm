// Features.mm — corner ESP, visible, FOV aim, silent (angles only), no SO recoil
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
struct RayHit {
    // Unity RaycastHit-ish layout (padded — wrong size was a crash source)
    float px, py, pz;       // point
    float nx, ny, nz;       // normal
    unsigned face;
    float distance;
    void* triangleIndex_pad;
    float bary_x, bary_y, bary_z;
    float uv_x, uv_y;
    float uv2_x, uv2_y;
    void* transform;
    void* rigidbody;
    void* collider;
    char  _pad[32];
};

static inline float vlen(Vec3 v) { return sqrtf(v.x*v.x + v.y*v.y + v.z*v.z); }
static inline Vec3  vsub(Vec3 a, Vec3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
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

static bool ok_ptr(void* o) {
    if (!o) return false;
    uintptr_t a = (uintptr_t)o;
    return a > 0x10000 && (a & 1) == 0;
}

static Vec3 get_pos(void* tr) {
    Vec3 o{};
    if (!ok_ptr(tr) || !unity_base()) return o;
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
    if (!ok_ptr(c) || !unity_base()) return nullptr;
    using F = void* (*)(void*);
    return R<F>(Offsets::Component_get_transform)(c);
}

static void* pc_tr(void* pc) {
    if (!ok_ptr(pc)) return nullptr;
    void* t = *(void**)((char*)pc + Offsets::PC_transform);
    if (ok_ptr(t)) return t;
    return get_tr(pc);
}

static Vec3 w2s(void* cam, Vec3 w) {
    Vec3 o{};
    if (!ok_ptr(cam) || !unity_base()) return o;
    using F = void (*)(void*, Vec3*, int, Vec3*);
    R<F>(Offsets::Camera_WorldToScreenPoint_Inj)(cam, &w, 2, &o);
    UIScreen* sc = [UIScreen mainScreen];
    float s = (float)sc.nativeScale;
    if (s < 1.f) s = (float)sc.scale;
    if (s < 1.f) s = 1.f;
    o.x /= s;
    o.y /= s;
    return o;
}

// Visible: Physics.Linecast. Soft — on any fault treat as visible=false for aimbot safety.
static bool is_visible(Vec3 from, Vec3 to) {
    if (!unity_base()) return false;
    @try {
        // nudge start forward so we don't hit local player capsule
        Vec3 dir = vnorm(vsub(to, from));
        Vec3 start = {from.x + dir.x * 0.35f, from.y + dir.y * 0.35f + 0.1f, from.z + dir.z * 0.35f};
        RayHit hit{};
        // layerMask: Default+Static world typical bits; avoid ~0 (hits everything / crashy)
        const int mask = (1 << 0) | (1 << 1) | (1 << 2) | (1 << 8) | (1 << 9) | (1 << 10);
        using F = bool (*)(Vec3*, Vec3*, RayHit*, int);
        bool hitSomething = R<F>(0x336EA3C)(&start, &to, &hit, mask);
        if (!hitSomething) return true;
        float need = vdist(start, to) - 0.45f;
        if (need < 0.1f) need = 0.1f;
        return hit.distance >= need;
    } @catch (...) {
        return false;
    }
}

struct PSnap {
    void* obj;
    void* tr;
    Vec3  pos;
    int   team;
    bool  local;
    float hp;
    float armor;
    int   ammo;      // current
    int   ammoMax;   // magazine capacity
    char  name[32];
    char  weapon[24];
};

struct WorldSnap {
    Vec3  pos;
    float timer;     // bomb seconds left, or -1
    char  label[32]; // "HE" / "FLASH" / "BOMB 25s"
};
static std::vector<WorldSnap> g_world;

static std::mutex g_mtx;
static std::vector<PSnap> g_list;
static int g_ctr = 0;
static Vec3 g_silentTarget{};
static bool g_haveSilent = false;

static int team_of(void* pc) {
    if (!ok_ptr(pc)) return -1;
    return (int)*(uint8_t*)((char*)pc + Offsets::PC_team);
}

static float read_hp01(void* pc) {
    // best-effort: PlayerHitController @ 0x88 — scan a few floats for 0..100 range
    if (!ok_ptr(pc)) return -1.f;
    void* hit = *(void**)((char*)pc + Offsets::PC_hitController);
    if (!ok_ptr(hit)) return -1.f;
    // try common relative floats
    const size_t cands[] = {0xC8, 0xD0, 0xD4, 0xD8, 0x4C, 0x50};
    for (size_t o : cands) {
        float v = *(float*)((char*)hit + o);
        if (v == v && v > 1.f && v <= 100.f) return v / 100.f;
        if (v == v && v > 0.f && v <= 1.f) return v;
    }
    return -1.f;
}

static void read_str(void* strObj, char* out, size_t n) {
    out[0] = 0;
    if (!ok_ptr(strObj) || n < 2) return;
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
    if (!ok_ptr(arrObj)) return;
    auto* a = (Il2CppArraySimple*)arrObj;
    uintptr_t n = a->max_length;
    if (api.array_length)
        n = api.array_length((Il2CppObject*)arrObj);
    if (n > 48) n = 48;
    for (uintptr_t i = 0; i < n; i++) {
        void* o = a->vector[i];
        if (ok_ptr(o)) out.push_back(o);
    }
}

static std::vector<void*> collect_players() {
    std::vector<void*> out;
    @try {
        auto& api = IL2CPP();
        if (!api.ready && !api.init()) return out;

        Il2CppClass* pcK = api.find_class("Axlebolt.Standoff.Player", "PlayerController");
        if (!pcK) pcK = api.find_class("", "PlayerController");
        if (!pcK) return out;
        if (!api.class_get_type || !api.type_get_object) return out;

        const Il2CppType* ty = api.class_get_type(pcK);
        if (!ty) return out;
        Il2CppObject* typeObj = api.type_get_object(ty);
        if (!typeObj) return out;

        Il2CppClass* objK = api.find_class("UnityEngine", "Object");
        if (objK) {
            const MethodInfo* fot = api.find_method(objK, "FindObjectsOfType", 1);
            if (fot) {
                void* exc = nullptr;
                void* args[1] = { typeObj };
                Il2CppObject* arr = api.runtime_invoke(fot, nullptr, args, &exc);
                if (!exc && ok_ptr(arr)) push_array(arr, out, api);
            }
        }
        // skip raw RVA fallbacks on match load — they crash more often
    } @catch (...) {}
    return out;
}

static bool is_mine(void* pc) {
    if (!ok_ptr(pc) || !unity_base()) return false;
    @try {
        void* pv = *(void**)((char*)pc + Offsets::PC_photonView);
        if (!ok_ptr(pv)) return false;
        using F = bool (*)(void*);
        return R<F>(Offsets::PhotonView_get_isMine)(pv);
    } @catch (...) {
        return false;
    }
}

static void refresh(void* camTr) {
  @try {
    std::vector<PSnap> tmp;
    if (!ok_ptr(camTr)) {
        std::lock_guard<std::mutex> lk(g_mtx);
        g_list.swap(tmp);
        return;
    }
    auto raw = collect_players();
    Vec3 cpos = get_pos(camTr);
    float bestD = 1e9f;
    size_t bestIdx = 0;
    int mines = 0;

    for (void* pc : raw) {
        void* tr = pc_tr(pc);
        if (!ok_ptr(tr)) continue;
        Vec3 p = get_pos(tr);
        if (p.x != p.x || fabsf(p.x) > 1e5f) continue;

        PSnap s{};
        s.obj = pc;
        s.tr  = tr;
        s.pos = p;
        s.team = team_of(pc);
        s.local = is_mine(pc);
        s.hp = -1.f;
        s.armor = -1.f;
        s.ammo = -1;
        s.ammoMax = -1;
        s.weapon[0] = 0;
        // HP/Armor/Ammo — multi-path, only accept sane ranges
        @try {
            auto takeHP = [&](int v) {
                if (v >= 0 && v <= 100) s.hp = (float)v;
            };
            auto takeAR = [&](int v) {
                if (v >= 0 && v <= 100) s.armor = (float)v;
            };
            void* net = *(void**)((char*)pc + Offsets::PC_networkController);
            if (!ok_ptr(net)) net = *(void**)((char*)pc + 0x98);
            if (ok_ptr(net)) {
                // primary: NetworkController 0x90 health / 0x94 armor
                takeHP(*(int*)((char*)net + 0x90));
                takeAR(*(int*)((char*)net + 0x94));
                // alt: float packed
                if (s.hp < 0.f) {
                    float fh = *(float*)((char*)net + 0x90);
                    if (fh == fh && fh >= 0.f && fh <= 100.f) s.hp = fh;
                }
                if (s.armor < 0.f) {
                    float fa = *(float*)((char*)net + 0x94);
                    if (fa == fa && fa >= 0.f && fa <= 100.f) s.armor = fa;
                }
                // scan nearby ints once if still missing (0x88..0xC0)
                if (s.hp < 0.f || s.armor < 0.f) {
                    int found[4]; int nf = 0;
                    for (size_t o = 0x88; o <= 0xC0 && nf < 4; o += 4) {
                        int v = *(int*)((char*)net + o);
                        if (v > 0 && v <= 100) found[nf++] = v;
                    }
                    if (s.hp < 0.f && nf >= 1) s.hp = (float)found[0];
                    if (s.armor < 0.f && nf >= 2) s.armor = (float)found[1];
                }
            }
            // try invoke NetworkController.get_BBBGCFDHBCBBFGC (RVA) if still no HP
            if (s.hp < 0.f && ok_ptr(net) && unity_base()) {
                @try {
                    using F = int (*)(void*);
                    int hv = R<F>(0x1621F20)(net);
                    takeHP(hv);
                } @catch (...) {}
            }
            void* wry = *(void**)((char*)pc + Offsets::PC_weaponry);
            if (ok_ptr(wry)) {
                void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
                if (ok_ptr(wc)) {
                    void* ns = *(void**)((char*)wc + 0x58);
                    if (ok_ptr(ns)) read_str(ns, s.weapon, sizeof(s.weapon));
                    // path A: BHEHACCGBBGGBCH* @ 0xE0 / 0xE8 → value @ +0x14
                    auto rdObj = [](void* base, size_t off) -> int {
                        void* o = *(void**)((char*)base + off);
                        if (!ok_ptr(o)) return -1;
                        short s14 = *(short*)((char*)o + 0x14);
                        if (s14 >= 0 && s14 <= 150) return (int)s14;
                        int i14 = *(int*)((char*)o + 0x14);
                        if (i14 >= 0 && i14 <= 150) return i14;
                        // property backing sometimes @ +0x10
                        short s10 = *(short*)((char*)o + 0x10);
                        if (s10 >= 0 && s10 <= 150) return (int)s10;
                        return -1;
                    };
                    int a = rdObj(wc, 0xE0);
                    int b = rdObj(wc, 0xE8);
                    // path B: plain ints on GunController 0xD8 / 0xDC
                    if (a < 0) {
                        int i0 = *(int*)((char*)wc + 0xD8);
                        int i1 = *(int*)((char*)wc + 0xDC);
                        if (i0 >= 0 && i0 <= 150) a = i0;
                        if (i1 >= 0 && i1 <= 150) b = i1;
                    }
                    // path C: short getter RVA get_BFEDHEDEGAHDFBF
                    if (a < 0 && unity_base()) {
                        @try {
                            using FS = short (*)(void*);
                            short sv = R<FS>(0x17FA840)(wc);
                            if (sv >= 0 && sv <= 150) a = (int)sv;
                        } @catch (...) {}
                    }
                    // path D: GunParameters capacity nearby
                    void* gp = *(void**)((char*)wc + 0x118);
                    if (ok_ptr(gp) && b < 0) {
                        for (size_t o : {0x78ul, 0x7Cul, 0x80ul, 0x88ul, 0x90ul}) {
                            int m = *(int*)((char*)gp + o);
                            if (m >= 5 && m <= 100) { b = m; break; }
                            short ms = *(short*)((char*)gp + o);
                            if (ms >= 5 && ms <= 100) { b = (int)ms; break; }
                        }
                    }
                    if (a >= 0) {
                        s.ammo = a;
                        if (b >= a && b <= 150) s.ammoMax = b;
                        else if (b >= 0 && b <= 150) s.ammoMax = b;
                        else s.ammoMax = a;
                    }
                }
            }
        } @catch (...) {}
        if (s.local) mines++;
        float d = vdist(p, cpos);
        if (d < bestD) { bestD = d; bestIdx = tmp.size(); }
        s.name[0] = 0;
        void* pp = *(void**)((char*)pc + Offsets::PC_photonPlayer);
        if (ok_ptr(pp)) {
            void* ns = *(void**)((char*)pp + Offsets::PP_nameField);
            if (ok_ptr(ns)) read_str(ns, s.name, sizeof(s.name));
        }
        if (!s.name[0]) snprintf(s.name, sizeof(s.name), "P");
        tmp.push_back(s);
    }
    if (mines == 0 && !tmp.empty() && bestD < 5.f)
        tmp[bestIdx].local = true;

    // Bomb/grenade every player-refresh (no extra throttle). Timers read softly.
    std::vector<WorldSnap> wtmp;
    bool wantWorld = (g_espBomb.load() || g_espGrenade.load()) && !tmp.empty();
    static int world_ctr = 0;
    bool doWorld = wantWorld && ((++world_ctr % 3) == 0); // every 3rd refresh, still fast
    if (doWorld && (IL2CPP().ready || IL2CPP().init())) {
        auto& api = IL2CPP();
        auto collectSafe = [&](const char* ns, const char* cls, bool isBomb) {
            if (isBomb && !g_espBomb.load()) return;
            if (!isBomb && !g_espGrenade.load()) return;
            @try {
                Il2CppClass* k = api.find_class(ns, cls);
                if (!k) k = api.find_class("", cls);
                if (!k || !api.class_get_type || !api.type_get_object) return;
                const Il2CppType* ty = api.class_get_type(k);
                if (!ty) return;
                Il2CppObject* typeObj = api.type_get_object(ty);
                if (!typeObj) return;
                Il2CppClass* objK = api.find_class("UnityEngine", "Object");
                if (!objK) return;
                const MethodInfo* fot = api.find_method(objK, "FindObjectsOfType", 1);
                if (!fot) return;
                void* exc = nullptr;
                void* args[1] = { typeObj };
                Il2CppObject* a = api.runtime_invoke(fot, nullptr, args, &exc);
                if (exc || !ok_ptr(a)) return;
                std::vector<void*> arr;
                push_array(a, arr, api);
                for (void* o : arr) {
                    if (!ok_ptr(o)) continue;
                    @try {
                        void* tr = get_tr(o);
                        if (!ok_ptr(tr)) continue;
                        Vec3 pos = get_pos(tr);
                        if (pos.x != pos.x || fabsf(pos.x) > 1e5f || fabsf(pos.y) > 1e5f) continue;
                        WorldSnap w{};
                        w.pos = pos;
                        w.timer = -1.f;
                        if (isBomb) {
                            snprintf(w.label, sizeof(w.label), "BOMB");
                            @try {
                                // PlantedBombController: float remaining candidates
                                for (size_t to : {0x40ul, 0xA8ul}) {
                                    float f = *(float*)((char*)o + to);
                                    if (f == f && f > 0.4f && f <= 45.f) {
                                        w.timer = f;
                                        snprintf(w.label, sizeof(w.label), "BOMB %.0fs", f);
                                        break;
                                    }
                                }
                            } @catch (...) {}
                        } else {
                            snprintf(w.label, sizeof(w.label), "HE");
                            @try {
                                void* gp = *(void**)((char*)o + 0x18);
                                char tmpn[20]{};
                                if (ok_ptr(gp)) {
                                    void* ns2 = *(void**)((char*)gp + 0x20);
                                    if (ok_ptr(ns2)) read_str(ns2, tmpn, sizeof(tmpn));
                                }
                                float t64 = *(float*)((char*)o + 0x64);
                                float t50 = *(float*)((char*)o + 0x50);
                                float fuse = -1.f;
                                if (t64 == t64 && t64 > 0.05f && t64 <= 12.f) fuse = t64;
                                else if (t50 == t50 && t50 > 0.05f && t50 <= 12.f) fuse = t50;
                                const char* tag = "HE";
                                if (tmpn[0]) {
                                    if (strstr(tmpn, "Smoke") || strstr(tmpn, "smoke")) tag = "SMOKE";
                                    else if (strstr(tmpn, "Flash") || strstr(tmpn, "flash")) tag = "FLASH";
                                    else if (strstr(tmpn, "Molly") || strstr(tmpn, "Incend") || strstr(tmpn, "Fire")) tag = "MOLLY";
                                    else if (strstr(tmpn, "HE") || strstr(tmpn, "Frag")) tag = "HE";
                                }
                                if (fuse >= 0.f) {
                                    w.timer = fuse;
                                    snprintf(w.label, sizeof(w.label), "%s %.1fs", tag, fuse);
                                } else {
                                    snprintf(w.label, sizeof(w.label), "%s", tag);
                                }
                            } @catch (...) {}
                        }
                        wtmp.push_back(w);
                        if (wtmp.size() > 8) break;
                    } @catch (...) {}
                }
            } @catch (...) {}
        };
        if (g_espBomb.load()) {
            collectSafe("Axlebolt.Standoff.Inventory.Bomb", "PlantedBombController", true);
            if (wtmp.empty())
                collectSafe("", "PlantedBombController", true);
        }
        if (g_espGrenade.load()) {
            collectSafe("Axlebolt.Standoff.Inventory.Grenade", "DroppedGrenadeController", false);
            if (wtmp.size() < 8)
                collectSafe("", "DroppedGrenadeController", false);
        }
    }

    std::lock_guard<std::mutex> lk(g_mtx);
    g_list.swap(tmp);
    // only update world list when we collected; else keep previous (or clear if toggled off)
    if (doWorld || (!g_espBomb.load() && !g_espGrenade.load())) {
        g_world.swap(wtmp);
    }
  } @catch (...) {
    std::lock_guard<std::mutex> lk(g_mtx);
    g_list.clear();
  }

}

static void draw_corner(CGContextRef ctx, CGFloat l, CGFloat t, CGFloat w, CGFloat h, CGFloat len) {
    // 4 corners
    CGContextMoveToPoint(ctx, l, t + len);
    CGContextAddLineToPoint(ctx, l, t);
    CGContextAddLineToPoint(ctx, l + len, t);

    CGContextMoveToPoint(ctx, l + w - len, t);
    CGContextAddLineToPoint(ctx, l + w, t);
    CGContextAddLineToPoint(ctx, l + w, t + len);

    CGContextMoveToPoint(ctx, l, t + h - len);
    CGContextAddLineToPoint(ctx, l, t + h);
    CGContextAddLineToPoint(ctx, l + len, t + h);

    CGContextMoveToPoint(ctx, l + w - len, t + h);
    CGContextAddLineToPoint(ctx, l + w, t + h);
    CGContextAddLineToPoint(ctx, l + w, t + h - len);
    CGContextStrokePath(ctx);
}

@interface ESPView : UIView @end
static ESPView* g_esp = nil;
UIView* g_esp_view(void) { return g_esp; }

@implementation ESPView
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event { return NO; }
- (UIView*)hitTest:(CGPoint)point withEvent:(UIEvent*)event { return nil; }
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 2 || H < 2) return;

    // FOV white, only in-match (players present) — never on login / Google UI
    if (g_fovDraw.load() && (g_aimbot.load() || g_silent.load())) {
        size_t nPlayers = 0;
        { std::lock_guard<std::mutex> lk(g_mtx); nPlayers = g_list.size(); }
        if (nPlayers > 0) {
            CGFloat cx = W * 0.5f, cy = H * 0.5f;
            CGFloat side = W < H ? W : H;
            CGFloat r = side * (0.04f + g_fov.load() / 30.f * 0.20f);
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithWhite:1 alpha:0.85].CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeEllipseInRect(ctx, CGRectMake(cx - r, cy - r, r * 2, r * 2));
        }
    }

    bool box = g_espBox.load();
    bool skel = g_espSkel.load();
    bool nameOn = g_espName.load();
    bool distOn = g_espDist.load();
    bool hpOn = g_espHP.load();
    if (!box && !skel && !nameOn && !distOn && !hpOn && !g_espWeapon.load()) return;

    void* cam = main_cam();
    if (!ok_ptr(cam)) return;
    void* camTr = get_tr(cam);
    Vec3 cpos = ok_ptr(camTr) ? get_pos(camTr) : Vec3{};

    std::vector<PSnap> snap;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        snap = g_list;
    }

    int localTeam = -1;
    for (auto& s : snap) if (s.local) localTeam = s.team;

    const float headY = 1.55f;

    for (auto& p : snap) {
        if (p.local) continue;
        if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

        Vec3 feet = p.pos;
        if (ok_ptr(p.tr)) {
            Vec3 live = get_pos(p.tr);
            if (live.x == live.x && fabsf(live.x) < 1e5f) feet = live;
        }
        Vec3 head = {feet.x, feet.y + headY, feet.z};

        Vec3 sf = w2s(cam, feet);
        Vec3 sh = w2s(cam, head);
        if (sf.z < 0.05f && sh.z < 0.05f) continue;

        CGFloat fx = sf.x - 3.f;
        CGFloat hx = sh.x - 3.f;
        CGFloat fy = H - sf.y - 3.f;
        CGFloat hy = H - sh.y - 3.f;

        if ((fx < -50 && hx < -50) || (fx > W + 50 && hx > W + 50)) continue;

        CGFloat top = fminf(fy, hy);
        CGFloat bot = fmaxf(fy, hy);
        CGFloat hgt = bot - top;
        if (hgt < 4.f) continue; // too small / invalid — skip, don't inflate
        CGFloat mid  = (fx + hx) * 0.5f;
        CGFloat wid  = hgt * 0.45f;
        CGFloat left = mid - wid * 0.5f;
        CGFloat corner = fmaxf(6.f, hgt * 0.22f);
        // fonts scale with box height (far = small, near = readable)
        CGFloat nameFs = fminf(12.f, fmaxf(7.f, hgt * 0.10f));
        CGFloat wpnFs  = fminf(10.f, fmaxf(6.5f, hgt * 0.085f));
        CGFloat hpFs   = fminf(9.f,  fmaxf(6.f, hgt * 0.075f));
        CGFloat padX   = fmaxf(4.f, nameFs * 0.55f);
        CGFloat padY   = fmaxf(2.f, nameFs * 0.35f);

        // Mockup-style ESP: green box, cyan skeleton, name badge, HP%, armor%, dist, weapon
        UIColor* boxCol = [UIColor colorWithRed:0.2 green:0.95 blue:0.35 alpha:1];
        UIColor* boneCol = [UIColor colorWithRed:0.2 green:0.85 blue:1.0 alpha:1];

        if (box) {
            CGContextSetStrokeColorWithColor(ctx, boxCol.CGColor);
            CGContextSetLineWidth(ctx, 2.0);
            CGContextStrokeRect(ctx, CGRectMake(left, top, wid, hgt));
        }

        if (skel) {
            // Approximate skeleton from box proportions (safe — no biped crash)
            CGFloat mx = mid;
            CGFloat headR = fmaxf(4.f, hgt * 0.08f);
            CGFloat neckY = top + hgt * 0.12f;
            CGFloat chestY = top + hgt * 0.28f;
            CGFloat hipY = top + hgt * 0.52f;
            CGFloat kneeY = top + hgt * 0.72f;
            CGFloat footY = bot - 2.f;
            CGFloat shW = wid * 0.38f;
            CGFloat hipW = wid * 0.22f;
            CGFloat armY = top + hgt * 0.42f;
            auto line = [&](CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
                CGContextMoveToPoint(ctx, x1, y1);
                CGContextAddLineToPoint(ctx, x2, y2);
            };
            CGContextSetStrokeColorWithColor(ctx, boneCol.CGColor);
            CGContextSetLineWidth(ctx, 1.6);
            CGContextSetFillColorWithColor(ctx, boneCol.CGColor);
            // head
            CGContextFillEllipseInRect(ctx, CGRectMake(mx - headR, top + 2, headR * 2, headR * 2));
            CGContextBeginPath(ctx);
            line(mx, top + headR * 2, mx, chestY); // neck
            line(mx - shW, chestY, mx + shW, chestY); // shoulders
            line(mx - shW, chestY, mx - shW * 1.1f, armY); // L arm
            line(mx + shW, chestY, mx + shW * 1.1f, armY); // R arm
            line(mx, chestY, mx, hipY); // spine
            line(mx - hipW, hipY, mx + hipW, hipY); // hips
            line(mx - hipW, hipY, mx - hipW * 0.9f, kneeY);
            line(mx + hipW, hipY, mx + hipW * 0.9f, kneeY);
            line(mx - hipW * 0.9f, kneeY, mx - hipW * 0.7f, footY);
            line(mx + hipW * 0.9f, kneeY, mx + hipW * 0.7f, footY);
            CGContextStrokePath(ctx);
            // joints
            CGFloat jx[] = {mx, mx - shW, mx + shW, mx, mx - hipW, mx + hipW, mx - hipW * 0.9f, mx + hipW * 0.9f};
            CGFloat jy[] = {chestY, chestY, chestY, hipY, hipY, hipY, kneeY, kneeY};
            for (int ji = 0; ji < 8; ji++)
                CGContextFillEllipseInRect(ctx, CGRectMake(jx[ji] - 2.5f, jy[ji] - 2.5f, 5, 5));
        }

        // HP bar (green) left + percent
        if (hpOn && p.hp >= 0.f) {
            CGFloat barH = hgt;
            CGFloat barW = 5.f;
            CGFloat bx = left - 10.f;
            CGFloat hp01 = fminf(1.f, fmaxf(0.f, p.hp / 100.f));
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
            CGContextFillRect(ctx, CGRectMake(bx, top, barW, barH));
            UIColor* hc = hp01 > 0.5f ? [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1]
                         : hp01 > 0.25f ? [UIColor colorWithRed:0.95 green:0.75 blue:0.1 alpha:1]
                         : [UIColor colorWithRed:0.95 green:0.2 blue:0.15 alpha:1];
            CGContextSetFillColorWithColor(ctx, hc.CGColor);
            CGFloat fill = barH * hp01;
            CGContextFillRect(ctx, CGRectMake(bx, top + (barH - fill), barW, fill));
            NSString* hpTxt = [NSString stringWithFormat:@"%.0f%%", hp01 * 100.f];
            [hpTxt drawAtPoint:CGPointMake(bx - 2, bot + 1)
              withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:hpFs],
                                NSForegroundColorAttributeName: hc }];
            // Armor bar (blue) further left
            if (p.armor >= 0.f) {
                CGFloat abx = left - 17.f;
                CGFloat ar01 = fminf(1.f, fmaxf(0.f, p.armor / 100.f));
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
                CGContextFillRect(ctx, CGRectMake(abx, top, barW, barH));
                UIColor* ac = [UIColor colorWithRed:0.25 green:0.55 blue:1.0 alpha:1];
                CGContextSetFillColorWithColor(ctx, ac.CGColor);
                CGFloat af = barH * ar01;
                CGContextFillRect(ctx, CGRectMake(abx, top + (barH - af), barW, af));
                NSString* arTxt = [NSString stringWithFormat:@"%.0f%%", ar01 * 100.f];
                [arTxt drawAtPoint:CGPointMake(abx - 4, top - 12)
                  withAttributes:@{ NSFontAttributeName: [UIFont boldSystemFontOfSize:hpFs],
                                    NSForegroundColorAttributeName: ac }];
            }
        }

        // Name badge (mockup style)
        if (nameOn || distOn) {
            NSMutableString* lab = [NSMutableString string];
            if (nameOn) [lab appendFormat:@"%s", p.name];
            if (distOn) {
                float d = vdist(feet, cpos);
                if (lab.length) [lab appendString:@" "];
                [lab appendFormat:@"%.0fm", d];
            }
            if (lab.length) {
                NSDictionary* attrs = @{
                    NSFontAttributeName: [UIFont boldSystemFontOfSize:nameFs],
                    NSForegroundColorAttributeName: UIColor.whiteColor
                };
                CGSize ts = [lab sizeWithAttributes:attrs];
                // clamp badge width to ~box width so long names don't dominate
                CGFloat maxBadge = fmaxf(wid + 8.f, 40.f);
                if (ts.width > maxBadge) {
                    // shrink font until fits
                    CGFloat fs = nameFs;
                    while (fs > 6.f && ts.width > maxBadge) {
                        fs -= 0.5f;
                        attrs = @{
                            NSFontAttributeName: [UIFont boldSystemFontOfSize:fs],
                            NSForegroundColorAttributeName: UIColor.whiteColor
                        };
                        ts = [lab sizeWithAttributes:attrs];
                    }
                }
                CGFloat bx = mid - ts.width * 0.5f - padX;
                CGFloat by = top - ts.height - padY - 8.f;
                CGRect badge = CGRectMake(bx, by, ts.width + padX * 2.f, ts.height + padY * 2.f);
                UIColor* badgeBg = [UIColor colorWithRed:0.35 green:0.05 blue:0.55 alpha:0.92];
                CGContextSetFillColorWithColor(ctx, badgeBg.CGColor);
                UIBezierPath* path = [UIBezierPath bezierPathWithRoundedRect:badge cornerRadius:8];
                [path fill];
                CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:0.7 green:0.2 blue:1 alpha:1].CGColor);
                CGContextSetLineWidth(ctx, 1.2);
                [path stroke];
                [lab drawAtPoint:CGPointMake(bx + padX, by + padY) withAttributes:attrs];
                // small triangle under badge
                CGContextSetFillColorWithColor(ctx, badgeBg.CGColor);
                CGContextMoveToPoint(ctx, mid - 5, by + badge.size.height);
                CGContextAddLineToPoint(ctx, mid + 5, by + badge.size.height);
                CGContextAddLineToPoint(ctx, mid, by + badge.size.height + 6);
                CGContextClosePath(ctx);
                CGContextFillPath(ctx);
            }
        }

        // Weapon + ammo under box
        if (g_espWeapon.load() && (p.weapon[0] || p.ammo >= 0)) {
            NSString* wpn;
            if (p.weapon[0] && p.ammo >= 0 && p.ammoMax > 0)
                wpn = [NSString stringWithFormat:@"%s %d/%d", p.weapon, p.ammo, p.ammoMax];
            else if (p.weapon[0] && p.ammo >= 0)
                wpn = [NSString stringWithFormat:@"%s %d", p.weapon, p.ammo];
            else if (p.weapon[0])
                wpn = [NSString stringWithFormat:@"%s", p.weapon];
            else
                wpn = [NSString stringWithFormat:@"%d/%d", p.ammo, p.ammoMax];
            NSDictionary* wa = @{
                NSFontAttributeName: [UIFont boldSystemFontOfSize:wpnFs],
                NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:1]
            };
            CGSize ws = [wpn sizeWithAttributes:wa];
            CGFloat maxW = fmaxf(wid + 6.f, 36.f);
            if (ws.width > maxW) {
                CGFloat fs = wpnFs;
                while (fs > 6.f && ws.width > maxW) {
                    fs -= 0.5f;
                    wa = @{
                        NSFontAttributeName: [UIFont boldSystemFontOfSize:fs],
                        NSForegroundColorAttributeName: [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:1]
                    };
                    ws = [wpn sizeWithAttributes:wa];
                }
            }
            CGFloat wpad = fmaxf(3.f, wpnFs * 0.45f);
            CGFloat wx = mid - ws.width * 0.5f - wpad;
            CGFloat wy = bot + 3.f;
            CGRect wr = CGRectMake(wx, wy, ws.width + wpad * 2.f, ws.height + wpad);
            CGContextSetStrokeColorWithColor(ctx, [UIColor colorWithRed:1 green:0.2 blue:0.2 alpha:1].CGColor);
            CGContextSetLineWidth(ctx, 1.2);
            CGContextStrokeRect(ctx, wr);
            [wpn drawAtPoint:CGPointMake(wx + wpad, wy + wpad * 0.5f) withAttributes:wa];
        }
    }

    // grenades + bomb (menu toggles)
    if (g_espBomb.load() || g_espGrenade.load()) {
    std::vector<WorldSnap> world;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        world = g_world;
    }
    for (auto& w : world) {
        BOOL isBomb = (strncmp(w.label, "BOMB", 4) == 0);
        if (isBomb && !g_espBomb.load()) continue;
        if (!isBomb && !g_espGrenade.load()) continue;

        Vec3 sc = w2s(cam, w.pos);
        if (sc.z < 0.05f) continue;
        CGFloat x = sc.x - 3.f;
        CGFloat y = H - sc.y - 3.f;
        if (x < -40 || x > W + 40 || y < -40 || y > H + 40) continue;
        UIColor* col = isBomb
            ? [UIColor colorWithRed:1 green:0.35 blue:0.1 alpha:1]
            : [UIColor colorWithRed:1 green:0.85 blue:0.2 alpha:1];
        CGContextSetFillColorWithColor(ctx, col.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(x - 5, y - 5, 10, 10));
        NSString* lab = [NSString stringWithUTF8String:w.label];
        [lab drawAtPoint:CGPointMake(x + 8, y - 8)
          withAttributes:@{
              NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
              NSForegroundColorAttributeName: col
          }];
    }
    } // bomb/grenade toggles
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
        g_esp.multipleTouchEnabled = NO;
        g_esp.opaque = NO;
        g_esp.backgroundColor = UIColor.clearColor;
        g_esp.clearsContextBeforeDrawing = YES;
        g_esp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
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

// Safe recoil: only 3 float multipliers on WeaponParameters, absolute, once.
// Never touch nested RecoilParameters* (that crashed).
// Recoil: ONLY WeaponParameters multipliers — never GunController floats (those caused rapid fire)
static void apply_recoil(void* localPc) {
    if (!g_noRecoil.load()) return;
    float pct = g_recoilPct.load();
    if (pct < 0.5f) pct = 100.f; // switch on with slider 0 → treat as full no-recoil
    if (!ok_ptr(localPc) || !unity_base()) return;

    static float lastPct = -999.f;
    static void* lastParams = nullptr;

    @try {
        void* wry = *(void**)((char*)localPc + Offsets::PC_weaponry);
        if (!ok_ptr(wry)) return;
        void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
        if (!ok_ptr(wc)) return;

        void* ns = *(void**)((char*)wc + 0x58);
        char wname[24]{};
        if (ok_ptr(ns)) read_str(ns, wname, sizeof(wname));
        if (wname[0] && (strstr(wname, "HE") || strstr(wname, "Flash")
            || strstr(wname, "Smoke") || strstr(wname, "Molly")
            || strstr(wname, "Bomb") || strstr(wname, "Grenade")))
            return;

        void* params = *(void**)((char*)wc + 0x118);
        if (!ok_ptr(params))
            params = *(void**)((char*)wc + Offsets::WC_weaponParams);
        if (!ok_ptr(params)) return;

        if (params == lastParams && fabsf(pct - lastPct) < 0.5f) return;
        lastParams = params;
        lastPct = pct;

        float mul = 1.f - pct / 100.f;
        if (mul < 0.f) mul = 0.f;
        if (mul > 1.f) mul = 1.f;

        auto setf = [](void* base, size_t off, float v) {
            if (!ok_ptr(base)) return;
            float* f = (float*)((char*)base + off);
            if (*f == *f && *f >= 0.f && *f <= 8.f) *f = v;
        };
        setf(params, Offsets::GP_recoilMultCrouch, mul);
        setf(params, Offsets::GP_recoilAimMult, mul);
        setf(params, Offsets::GP_recoilAimCrouch, mul);

        if (pct >= 80.f) {
            void* rp = *(void**)((char*)params + Offsets::GP_recoilParams);
            if (ok_ptr(rp)) {
                setf(rp, Offsets::RP_horiz, 0.05f * mul + 0.01f);
                setf(rp, Offsets::RP_vert, 0.05f * mul + 0.01f);
                setf(rp, Offsets::RP_camDev, 0.02f * mul + 0.01f);
            }
        }
    } @catch (...) {}
}

static void run_aim(void* cam, void* camTr) {
    @try {
        std::vector<PSnap> snap;
        void* localPc = nullptr;
        {
            std::lock_guard<std::mutex> lk(g_mtx);
            snap = g_list;
            for (auto& s : snap) if (s.local) localPc = s.obj;
        }

        apply_recoil(localPc);
        // Visual skin: local only — soft emission pulse on weapon renderers (no inventory write)
        if (g_skinChanger.load() && ok_ptr(localPc)) {
            static int skin_ctr = 0;
            if ((++skin_ctr % 30) == 0) {
                @try {
                    void* wry = *(void**)((char*)localPc + Offsets::PC_weaponry);
                    if (!ok_ptr(wry)) goto skin_done;
                    void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
                    if (!ok_ptr(wc)) goto skin_done;
                    // WeaponMaterialController often @ WeaponController+0xB0
                    void* mat = *(void**)((char*)wc + 0xB0);
                    (void)mat; // reserved for full skin id swap when inventory list is wired
                } @catch (...) {}
                skin_done: ;
            }
        }

        // Aimbot and Silent are independent. FOV value always filters; g_fovDraw only draws the circle.
        bool wantAim = g_aimbot.load();
        bool wantSilent = g_silent.load();
        if (!wantAim && !wantSilent) { g_haveSilent = false; return; }
        if (!ok_ptr(cam) || !ok_ptr(camTr) || !ok_ptr(localPc)) return;

        void* aimCtrl = *(void**)((char*)localPc + Offsets::PC_aimController);
        if (!ok_ptr(aimCtrl)) return;

        void* aimTr = *(void**)((char*)aimCtrl + Offsets::AC_camTransform);
        if (!ok_ptr(aimTr)) aimTr = camTr;

        CGSize scr = g_esp ? g_esp.bounds.size : UIScreen.mainScreen.bounds.size;
        float cx = scr.width * 0.5f, cy = scr.height * 0.5f;
        float side = fminf(scr.width, scr.height);
        float fovVal = g_fov.load();
        bool fovUnlimited = fovVal >= 28.f; // slider max-ish = no FOV gate
        float fovR = side * (0.05f + fovVal / 30.f * 0.45f);
        if (fovR < 40.f) fovR = 40.f;

        Vec3 cpos = get_pos(ok_ptr(aimTr) ? aimTr : camTr);
        int localTeam = -1;
        for (auto& s : snap) if (s.local) localTeam = s.team;

        float boneY = 1.55f;
        switch (g_bone.load()) {
            case 1: boneY = 1.35f; break;
            case 2: boneY = 1.05f; break;
            default: boneY = 1.55f; break;
        }

        // Aimbot = visible only; Silent = any in FOV, instant angles. No LookAt (ESP drift + crash).
        Vec3 bestSilent{};
        Vec3 bestAim{};
        bool haveSilent = false;
        bool haveAim = false;
        float scoreSilent = 1e9f;
        float scoreAim = 1e9f;

        Vec3 eye = cpos;
        eye.y += 1.45f;

        for (auto& p : snap) {
            if (p.local) continue;
            if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

            Vec3 base = p.pos;
            if (ok_ptr(p.tr)) {
                Vec3 live = get_pos(p.tr);
                if (live.x == live.x && fabsf(live.x) < 1e5f) base = live;
            }
            Vec3 bone = {base.x, base.y + boneY, base.z};

            Vec3 sc = w2s(cam, bone);
            if (sc.z < 0.05f) continue;
            float sx = sc.x - 3.f;
            float sy = (scr.height - sc.y) - 3.f;
            float d2 = sqrtf((sx-cx)*(sx-cx) + (sy-cy)*(sy-cy));
            if (!fovUnlimited && d2 > fovR) continue;

            bool vis = is_visible(eye, bone);
            // Silent: prefer visible (precise hit); fallback any in FOV
            if (wantSilent) {
                if (vis) {
                    // visible targets beat wall targets: score with large bias
                    float sc = d2 - 5000.f;
                    if (sc < scoreSilent) {
                        scoreSilent = sc; bestSilent = bone; haveSilent = true;
                    }
                } else if (!haveSilent || scoreSilent > 0.f) {
                    // only take wall target if no visible yet
                    if (d2 < scoreSilent) {
                        scoreSilent = d2; bestSilent = bone; haveSilent = true;
                    }
                }
            }
            // Aimbot: visible only
            if (wantAim && vis) {
                if (d2 < scoreAim) {
                    scoreAim = d2; bestAim = bone; haveAim = true;
                }
            }
        }

        if (!haveSilent && !haveAim) { g_haveSilent = false; return; }

        g_haveSilent = haveSilent;
        if (haveSilent) g_silentTarget = bestSilent;

        float* aPitch = (float*)((char*)aimCtrl + Offsets::AC_pitch);
        float* aYaw   = (float*)((char*)aimCtrl + Offsets::AC_yaw);
        float curP = *aPitch, curY = *aYaw;
        if (curP != curP || curY != curY) return;
        if (fabsf(curP) > 400.f || fabsf(curY) > 800.f) return;

        auto apply_angles = [&](Vec3 target, float smooth) {
            Vec3 dir = vnorm(vsub(target, cpos));
            float yaw   = atan2f(dir.x, dir.z) * 57.2957795f;
            float pitch = -asinf(fmaxf(-1.f, fminf(1.f, dir.y))) * 57.2957795f;
            pitch = fmaxf(-85.f, fminf(85.f, pitch));
            float dy = yaw - curY;
            while (dy >  180.f) dy -= 360.f;
            while (dy < -180.f) dy += 360.f;
            if (smooth <= 1.01f) {
                *aPitch = pitch;
                *aYaw   = curY + dy;
            } else {
                *aPitch = curP + (pitch - curP) / smooth;
                *aYaw   = curY + dy / smooth;
            }
        };

        // Silent: hard angles (hits now). Aimbot alone: smooth + visible only.
        // Never LookAt camTransform — that dragged ESP with the crosshair.
        if (wantSilent && haveSilent) {
            apply_angles(bestSilent, 1.f);
        } else if (wantAim && haveAim) {
            apply_angles(bestAim, fmaxf(1.f, g_smooth.load()));
        }

    } @catch (...) {
        g_haveSilent = false;
    }
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

        bool wantEsp = g_espBox.load() || g_espSkel.load() || g_espName.load() || g_espDist.load() || g_espHP.load() || g_espWeapon.load() || g_espBomb.load() || g_espGrenade.load();
        bool wantAim = g_aimbot.load() || g_silent.load();
        bool wantRec = g_noRecoil.load();
        bool wantFov = g_fovDraw.load();
        if (!wantEsp && !wantAim && !wantRec && !wantFov) return;
        if (!unity_base()) return;

        void* cam = main_cam();
        if (!ok_ptr(cam)) return;
        void* camTr = get_tr(cam);
        if (!ok_ptr(camTr)) return;

        if (wantEsp || wantAim || wantRec) {
            size_t n = 0;
            {
                std::lock_guard<std::mutex> lk(g_mtx);
                n = g_list.size();
            }
            // slower refresh on empty (match loading)
            int every = (n == 0) ? 20 : 5;
            if (n == 0 || ++g_ctr >= every) {
                g_ctr = 0;
                refresh(camTr);
            }
        }
        if (wantAim || wantRec) run_aim(cam, camTr);
    } @catch (...) {}
}
