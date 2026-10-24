// Features.mm — ESP/aim/world (stealth)
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

extern UIView* CoreUI_SecureRoot;

struct Vec3 { float x, y, z; };
struct RayHit {
    float px, py, pz;
    float nx, ny, nz;
    unsigned face;
    float distance;
    void* collider;
    // rest ignored
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
    // iOS userland + aligned; reject tagged/low/kernelish
    if (a < 0x100000000ULL || a > 0x300000000ULL) return false;
    if (a & 0x7) return false;
    return true;
}

template<typename T>
static bool sread(void* base, size_t off, T* out) {
    if (!ok_ptr(base) || !out) return false;
    @try {
        *out = *(T*)((char*)base + off);
        return true;
    } @catch (...) { return false; }
}

static Vec3 get_pos(void* tr) {
    Vec3 o{};
    if (!ok_ptr(tr) || !unity_base()) return o;
    @try {
        using F = void (*)(void*, Vec3*);
        R<F>(Offsets::Transform_get_position_Injected)(tr, &o);
        if (o.x != o.x || o.y != o.y || o.z != o.z) return Vec3{};
    } @catch (...) { return Vec3{}; }
    return o;
}

static void* main_cam() {
    if (!unity_base()) return nullptr;
    @try {
        using F = void* (*)();
        void* c = R<F>(Offsets::Camera_get_main)();
        return ok_ptr(c) ? c : nullptr;
    } @catch (...) { return nullptr; }
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

// Visible: Linecast cam→target. If hit closer than target - blocked.
static bool is_visible(Vec3 from, Vec3 to) {
    if (!unity_base()) return true;
    RayHit hit{};
    // Physics.Linecast(start, end, out hit, layerMask) RVA 0x336EA3C
    using F = bool (*)(Vec3*, Vec3*, RayHit*, int);
    bool blocked = R<F>(0x336EA3C)(&from, &to, &hit, ~0);
    if (!blocked) return true;
    float need = vdist(from, to) - 0.35f;
    return hit.distance >= need;
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
    if (!ok_ptr(pc)) return -1.f;
    @try {
        // NetworkController first (health often replicated here)
        void* net = nullptr;
        if (sread(pc, Offsets::PC_networkController, &net) && ok_ptr(net)) {
            const size_t offs[] = {0x90, 0x94, 0x98, 0x9C, 0xA0, 0xA4, 0x88, 0x8C};
            for (size_t o : offs) {
                int iv = 0;
                if (sread(net, o, &iv) && iv > 0 && iv <= 100)
                    return iv / 100.f;
                float fv = 0.f;
                if (sread(net, o, &fv) && fv == fv && fv > 0.f && fv <= 100.f)
                    return (fv > 1.f) ? fv / 100.f : fv;
            }
        }
        void* hit = nullptr;
        if (sread(pc, Offsets::PC_hitController, &hit) && ok_ptr(hit)) {
            const size_t offs[] = {0xC8, 0xD0, 0xD4, 0xD8, 0x4C, 0x50, 0xB0, 0xB4};
            for (size_t o : offs) {
                float v = 0.f;
                if (!sread(hit, o, &v)) continue;
                if (v == v && v > 1.f && v <= 100.f) return v / 100.f;
                if (v == v && v > 0.f && v <= 1.f) return v;
            }
        }
    } @catch (...) {}
    return -1.f;
}

static float read_armor(void* pc) {
    if (!ok_ptr(pc)) return -1.f;
    @try {
        void* net = nullptr;
        if (!sread(pc, Offsets::PC_networkController, &net) || !ok_ptr(net)) return -1.f;
        const size_t offs[] = {0x94, 0x98, 0x9C, 0xA0, 0xA4, 0xA8};
        for (size_t o : offs) {
            int iv = 0;
            if (sread(net, o, &iv) && iv >= 0 && iv <= 100) {
                // skip if same slot already used as hp-like 100 always
                return (float)iv;
            }
        }
    } @catch (...) {}
    return -1.f;
}

static void read_ammo(void* pc, int* cur, int* mx) {
    if (cur) *cur = -1;
    if (mx) *mx = -1;
    if (!ok_ptr(pc)) return;
    @try {
        void* wry = nullptr;
        if (!sread(pc, Offsets::PC_weaponry, &wry) || !ok_ptr(wry)) return;
        void* wc = nullptr;
        if (!sread(wry, Offsets::Wry_weaponCtrl, &wc) || !ok_ptr(wc)) return;
        // WeaponController: int @ 0x60 often clip; probe neighbors
        const size_t offs[] = {0x60, 0x64, 0x54, 0x5C};
        for (size_t o : offs) {
            int v = 0;
            if (sread(wc, o, &v) && v >= 0 && v <= 200) {
                if (cur && *cur < 0) *cur = v;
                else if (mx && *mx < 0 && v > 0) { *mx = v; break; }
            }
        }
    } @catch (...) {}
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
        return; // keep previous g_list — no flicker
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
        // optional extras — never crash
        @try {
            s.hp = read_hp01(pc);
            s.armor = read_armor(pc);
            read_ammo(pc, &s.ammo, &s.ammoMax);
            void* wry = nullptr;
            if (sread(pc, Offsets::PC_weaponry, &wry) && ok_ptr(wry)) {
                void* wc = nullptr;
                if (sread(wry, Offsets::Wry_weaponCtrl, &wc) && ok_ptr(wc)) {
                    void* ns = nullptr;
                    if (sread(wc, 0x58, &ns) && ok_ptr(ns))
                        read_str(ns, s.weapon, sizeof(s.weapon));
                }
            }
        } @catch (...) {
            s.hp = -1.f; s.armor = -1.f; s.ammo = -1; s.ammoMax = -1;
        }

        void* pp = nullptr;
        if (sread(pc, Offsets::PC_photonPlayer, &pp) && ok_ptr(pp)) {
            void* ns = nullptr;
            if (sread(pp, Offsets::PP_nameField, &ns) && ok_ptr(ns))
                read_str(ns, s.name, sizeof(s.name));
        }
        if (!s.name[0]) snprintf(s.name, sizeof(s.name), "P");
        tmp.push_back(s);
    }
    if (mines == 0 && !tmp.empty() && bestD < 5.f)
        tmp[bestIdx].local = true;

    // Safe bomb/grenade: ONLY get_tr + get_pos. No field reads (0xA8/0x18 crashed on enter).
    std::vector<WorldSnap> wtmp;
    static int world_ctr = 0;
    // only every 15 refreshes, and only if we already have players (match started)
    bool doWorld = (g_espBomb.load() || g_espGrenade.load()) && !tmp.empty() && (++world_ctr >= 25);
    if (doWorld) world_ctr = 0;
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
                                float rem = *(float*)((char*)o + 0xA8);
                                double plant = *(double*)((char*)o + 0xA0);
                                // 0xA8 is remaining OR fuse length
                                if (rem == rem && rem > 0.f && rem <= 60.f) {
                                    w.timer = rem;
                                    snprintf(w.label, sizeof(w.label), "BOMB %.0fs", rem);
                                } else if (plant == plant && plant > 1000.0) {
                                    // network time stamp — show planted marker only
                                    snprintf(w.label, sizeof(w.label), "BOMB");
                                }
                                // also try 0x40 float
                                if (w.timer < 0.f) {
                                    float f40 = *(float*)((char*)o + 0x40);
                                    if (f40 == f40 && f40 > 0.f && f40 <= 60.f) {
                                        w.timer = f40;
                                        snprintf(w.label, sizeof(w.label), "BOMB %.0fs", f40);
                                    }
                                }
                            } @catch (...) {}
                        } else {
                            snprintf(w.label, sizeof(w.label), "GRENADE");
                            @try {
                                // timers only — floats 0..60 on controller; classify smoke/molly by name later
                                for (size_t to : {0x40ul, 0x44ul, 0x48ul, 0x4Cul, 0x50ul, 0xA0ul}) {
                                    float tv = 0.f;
                                    if (sread(o, to, &tv) && tv==tv && tv>0.3f && tv<=60.f) {
                                        w.timer = tv;
                                        break;
                                    }
                                }
                                // soft name from +0x18 params (optional)
                                void* gp = nullptr;
                                if (sread(o, 0x18, &gp) && ok_ptr(gp)) {
                                    for (size_t no : {0x10ul, 0x18ul, 0x20ul}) {
                                        void* ns2 = nullptr;
                                        if (!sread(gp, no, &ns2) || !ok_ptr(ns2)) continue;
                                        char tmpn[20]{};
                                        read_str(ns2, tmpn, sizeof(tmpn));
                                        if (tmpn[0] && strlen(tmpn) < 18) {
                                            snprintf(w.label, sizeof(w.label), "%s", tmpn);
                                            break;
                                        }
                                    }
                                }
                            } @catch (...) {}
                        }
                        wtmp.push_back(w);
                        if (wtmp.size() > 12) break;
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
            if (wtmp.size() < 12)
                collectSafe("", "DroppedGrenadeController", false);
        }
    }

    std::lock_guard<std::mutex> lk(g_mtx);
    // never replace with empty if we already have players (flicker)
    if (!tmp.empty() || g_list.empty())
        g_list.swap(tmp);
    if (doWorld || (!g_espBomb.load() && !g_espGrenade.load())) {
        if (!wtmp.empty() || g_world.empty() || (!g_espBomb.load() && !g_espGrenade.load()))
            g_world.swap(wtmp);
    }
  } @catch (...) {
    // keep last good list — ESP flicker fix
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
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    if (!ctx) return;
    CGFloat W = self.bounds.size.width;
    CGFloat H = self.bounds.size.height;
    if (W < 2 || H < 2) return;

    if (g_fovDraw.load() && (g_aimbot.load() || g_silent.load())) {
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
    bool hpOn = g_espHP.load();
    if (!box && !skel && !nameOn && !distOn && !hpOn) return;

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

        // Snapshot only when aim/silent — live + LookAt made ESP stick to crosshair
        Vec3 feet = p.pos;
        if (!g_aimbot.load() && !g_silent.load() && ok_ptr(p.tr)) {
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

        // ESP style: white box + left green HP (reference shot)
        UIColor* boxCol = [UIColor colorWithWhite:1.0 alpha:0.95];
        UIColor* skelCol = [UIColor colorWithRed:0.25 green:0.85 blue:1.0 alpha:0.9];

        if (box) {
            CGContextSetStrokeColorWithColor(ctx, boxCol.CGColor);
            CGContextSetLineWidth(ctx, 1.5);
            CGContextStrokeRect(ctx, CGRectMake(left, top, wid, hgt));
            // subtle dark fill
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.12].CGColor);
            CGContextFillRect(ctx, CGRectMake(left, top, wid, hgt));
        }
        if (skel) {
            // estimated stick figure from head/feet (no bone dump needed)
            CGFloat mx = (left + left + wid) * 0.5f;
            CGFloat neckY = hy + hgt * 0.08f;
            CGFloat chestY = hy + hgt * 0.22f;
            CGFloat hipY = hy + hgt * 0.48f;
            CGFloat kneeY = hy + hgt * 0.72f;
            CGFloat shW = wid * 0.28f;
            CGFloat hipW = wid * 0.18f;
            CGContextSetStrokeColorWithColor(ctx, skelCol.CGColor);
            CGContextSetLineWidth(ctx, 1.6);
            CGContextSetLineCap(ctx, kCGLineCapRound);
            auto line = [&](CGFloat x1, CGFloat y1, CGFloat x2, CGFloat y2) {
                CGContextMoveToPoint(ctx, x1, y1);
                CGContextAddLineToPoint(ctx, x2, y2);
                CGContextStrokePath(ctx);
            };
            // head
            CGContextSetFillColorWithColor(ctx, skelCol.CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(hx - 4, hy - 4, 8, 8));
            line(mx, hy + 4, mx, neckY);
            line(mx - shW, chestY, mx + shW, chestY); // shoulders
            line(mx, neckY, mx, hipY); // spine
            line(mx - shW, chestY, mx - shW * 1.1f, chestY + hgt * 0.25f); // L arm
            line(mx + shW, chestY, mx + shW * 1.1f, chestY + hgt * 0.25f); // R arm
            line(mx, hipY, mx - hipW, kneeY); line(mx - hipW, kneeY, mx - hipW, fy); // L leg
            line(mx, hipY, mx + hipW, kneeY); line(mx + hipW, kneeY, mx + hipW, fy); // R leg
        }
        if (hpOn && p.hp >= 0.f) {
            CGFloat barH = hgt;
            CGFloat barW = 4.f;
            CGFloat bx = left - 7.f;
            CGFloat hp = p.hp;
            if (hp > 1.f) hp = 1.f;
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
            CGContextFillRect(ctx, CGRectMake(bx, top, barW, barH));
            UIColor* hc = hp > 0.5f ? [UIColor colorWithRed:0.2 green:0.95 blue:0.35 alpha:1]
                         : hp > 0.25f ? [UIColor colorWithRed:0.95 green:0.75 blue:0.1 alpha:1]
                         : [UIColor colorWithRed:0.95 green:0.2 blue:0.15 alpha:1];
            CGContextSetFillColorWithColor(ctx, hc.CGColor);
            CGFloat fill = barH * hp;
            CGContextFillRect(ctx, CGRectMake(bx, top + (barH - fill), barW, fill));
            // armor blue bar
            if (p.armor >= 0.f) {
                CGFloat ar = p.armor;
                if (ar > 100.f) ar = 100.f;
                CGFloat af = barH * (ar / 100.f);
                CGFloat ax = bx - 5.f;
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.5].CGColor);
                CGContextFillRect(ctx, CGRectMake(ax, top, 3.f, barH));
                CGContextSetFillColorWithColor(ctx, [UIColor colorWithRed:0.3 green:0.7 blue:1 alpha:1].CGColor);
                CGContextFillRect(ctx, CGRectMake(ax, top + (barH - af), 3.f, af));
            }
        }
        if (nameOn || distOn || g_espWeapon.load()) {
            NSMutableString* lab = [NSMutableString stringWithUTF8String:p.name];
            if (distOn) {
                float d = vdist(feet, cpos);
                [lab appendFormat:@" %.0fm", d];
            }
            {
                NSDictionary* attrs = @{
                    NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
                    NSForegroundColorAttributeName: UIColor.whiteColor
                };
                CGSize sz = [lab sizeWithAttributes:attrs];
                CGFloat px = mid - sz.width * 0.5f;
                CGFloat py = top - 16;
                // soft shadow for readability
                NSDictionary* shadow = @{
                    NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
                    NSForegroundColorAttributeName: [UIColor colorWithWhite:0 alpha:0.75]
                };
                [lab drawAtPoint:CGPointMake(px + 1, py + 1) withAttributes:shadow];
                [lab drawAtPoint:CGPointMake(px, py) withAttributes:attrs];
            }
            if (g_espWeapon.load() && (p.weapon[0] || p.ammo >= 0)) {
                NSString* wpn;
                if (p.weapon[0] && p.ammo >= 0 && p.ammoMax > 0)
                    wpn = [NSString stringWithFormat:@"%s %d/%d", p.weapon, p.ammo, p.ammoMax];
                else if (p.weapon[0] && p.ammo >= 0)
                    wpn = [NSString stringWithFormat:@"%s %d", p.weapon, p.ammo];
                else if (p.ammo >= 0 && p.ammoMax > 0)
                    wpn = [NSString stringWithFormat:@"%d/%d", p.ammo, p.ammoMax];
                else if (p.weapon[0])
                    wpn = [NSString stringWithFormat:@"%s", p.weapon];
                else
                    wpn = [NSString stringWithFormat:@"%d", p.ammo];
                // weapon under box (SCOUT-style)
                NSDictionary* wattrs = @{
                      NSFontAttributeName: [UIFont boldSystemFontOfSize:10],
                      NSForegroundColorAttributeName: [UIColor colorWithRed:0.95 green:0.95 blue:0.95 alpha:1]
                  };
                CGSize wsz = [wpn sizeWithAttributes:wattrs];
                [wpn drawAtPoint:CGPointMake(mid - wsz.width * 0.5f, bot + 3) withAttributes:wattrs];
            }
            if (p.armor >= 0) {
                NSString* ar = [NSString stringWithFormat:@"A:%.0f", p.armor];
                [ar drawAtPoint:CGPointMake(left + wid + 4, top)
                  withAttributes:@{
                      NSFontAttributeName: [UIFont systemFontOfSize:9],
                      NSForegroundColorAttributeName: [UIColor colorWithRed:0.4 green:0.7 blue:1 alpha:1]
                  }];
            }
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
        // bomb / smoke only — molly ESP removed
        BOOL isSmoke = NO;
        if (!isBomb) {
            const char* L = w.label;
            if (strcasestr(L, "smoke") || strcasestr(L, "Smoke")) isSmoke = YES;
            else continue; // skip molly / other
        }
        UIColor* col = isBomb
            ? [UIColor colorWithRed:1 green:0.25 blue:0.1 alpha:1]
            : [UIColor colorWithRed:0.75 green:0.75 blue:0.8 alpha:1];
        CGContextSetFillColorWithColor(ctx, col.CGColor);
        CGContextFillEllipseInRect(ctx, CGRectMake(x - 6, y - 6, 12, 12));
        // label + timer
        NSString* lab;
        if (w.timer >= 0.f) {
            if (isBomb) lab = [NSString stringWithFormat:@"BOMB %.1fs", w.timer];
            else lab = [NSString stringWithFormat:@"SMOKE %.1fs", w.timer];
        } else {
            if (isBomb) lab = @"BOMB";
            else lab = @"SMOKE";
        }
        NSDictionary* attrs = @{
            NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
            NSForegroundColorAttributeName: col
        };
        CGSize sz = [lab sizeWithAttributes:attrs];
        CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.55].CGColor);
        CGContextFillRect(ctx, CGRectMake(x + 8, y - 10, sz.width + 6, 14));
        [lab drawAtPoint:CGPointMake(x + 11, y - 9) withAttributes:attrs];
    }
    } // bomb/grenade toggles
}
@end

void CoreUI_EnsureFOVOverlay(UIWindow* win) {
    // Prefer secure root when hide-rec ON so ESP is hidden from screenshots/record
    UIView* root = nil;
    if (CoreUI_SecureRoot) root = CoreUI_SecureRoot;
    else if (win) root = win.rootViewController.view ?: (UIView*)win;
    if (!root) return;
    CGRect b = root.bounds;
    if (b.size.width < 2 && win) b = win.bounds;
    if (b.size.width < 2) b = UIScreen.mainScreen.bounds;
    b.origin = CGPointZero;
    if (!g_esp) {
        g_esp = [[ESPView alloc] initWithFrame:b];
        g_esp.userInteractionEnabled = NO;
        g_esp.opaque = NO;
        g_esp.backgroundColor = UIColor.clearColor;
        g_esp.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [root insertSubview:g_esp atIndex:0];
    } else {
        g_esp.frame = b;
        if (g_esp.superview != root) {
            [g_esp removeFromSuperview];
            [root insertSubview:g_esp atIndex:0];
        }
    }
}

// Safe recoil: only 3 float multipliers on WeaponParameters, absolute, once.
// Never touch nested RecoilParameters* (that crashed).
// Recoil: ONLY WeaponParameters multipliers — never GunController floats (those caused rapid fire)
static void apply_recoil(void* localPc) {
    if (!g_noRecoil.load()) return;
    float pct = g_recoilPct.load();
    if (pct < 0.5f) pct = 100.f;
    if (!ok_ptr(localPc) || !unity_base()) return;

    static float lastPct = -999.f;
    static void* lastParams = nullptr;

    @try {
        void* wry = nullptr;
        if (!sread(localPc, Offsets::PC_weaponry, &wry) || !ok_ptr(wry)) return;
        void* wc = nullptr;
        if (!sread(wry, Offsets::Wry_weaponCtrl, &wc) || !ok_ptr(wc)) return;

        void* ns = nullptr;
        char wname[24]{};
        if (sread(wc, 0x58, &ns) && ok_ptr(ns)) read_str(ns, wname, sizeof(wname));
        if (wname[0] && (strstr(wname, "HE") || strstr(wname, "Flash")
            || strstr(wname, "Smoke") || strstr(wname, "Bomb") || strstr(wname, "Grenade")))
            return;

        void* params = nullptr;
        if (!sread(wc, Offsets::WC_weaponParams, &params) || !ok_ptr(params)) return;

        if (params == lastParams && fabsf(pct - lastPct) < 0.5f) return;
        lastParams = params;
        lastPct = pct;

        float mul = 1.f - pct / 100.f;
        if (mul < 0.f) mul = 0.f;
        if (mul > 1.f) mul = 1.f;

        auto setf = [](void* base, size_t off, float v) {
            if (!ok_ptr(base)) return;
            @try { *(float*)((char*)base + off) = v; } @catch (...) {}
        };
        // only known GunParameters multipliers from dump
        setf(params, Offsets::GP_recoilMultCrouch, mul);
        setf(params, Offsets::GP_recoilAimMult, mul);
        setf(params, Offsets::GP_recoilAimCrouch, mul);
        // DO NOT touch RecoilParameters nested pointer — crash source
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

        if (!g_aimbot.load() && !g_silent.load()) { g_haveSilent = false; return; }
        if (!ok_ptr(cam) || !ok_ptr(camTr) || !ok_ptr(localPc)) return;

        void* aimCtrl = nullptr;
        if (!sread(localPc, Offsets::PC_aimController, &aimCtrl) || !ok_ptr(aimCtrl)) return;
        void* aimTr = nullptr;
        if (!sread(aimCtrl, Offsets::AC_camTransform, &aimTr) || !ok_ptr(aimTr)) aimTr = camTr;

        CGSize scr = g_esp ? g_esp.bounds.size : UIScreen.mainScreen.bounds.size;
        float cx = scr.width * 0.5f, cy = scr.height * 0.5f;
        float side = fminf(scr.width, scr.height);
        float fovR = side * (0.05f + g_fov.load() / 30.f * 0.25f);

        Vec3 cpos = get_pos(ok_ptr(aimTr) ? aimTr : camTr);
        int localTeam = -1;
        for (auto& s : snap) if (s.local) localTeam = s.team;

        float boneY = 1.55f;
        switch (g_bone.load()) {
            case 1: boneY = 1.35f; break;
            case 2: boneY = 1.05f; break;
            default: boneY = 1.55f; break;
        }

        Vec3 best{};
        bool have = false;
        float bestScore = 1e9f;

        for (auto& p : snap) {
            if (p.local) continue;
            if (g_espTeam.load() && localTeam >= 0 && p.team == localTeam) continue;

            Vec3 base = p.pos;
            if (ok_ptr(p.tr)) {
                Vec3 live = get_pos(p.tr);
                if (live.x == live.x && fabsf(live.x) < 1e5f) base = live;
            }
            Vec3 bone = {base.x, base.y + boneY, base.z};
            float distTo = vdist(cpos, bone);

            // Physics.Raycast disabled — was crashing; visible uses simple depth for now
            (void)distTo;
            (void)g_aimVisible;

            Vec3 sc = w2s(cam, bone);
            if (sc.z < 0.05f) continue;
            float sx = sc.x - 3.f;
            float sy = (scr.height - sc.y) - 3.f;
            float d2 = sqrtf((sx-cx)*(sx-cx) + (sy-cy)*(sy-cy));
            if (d2 > fovR) continue;
            if (d2 < bestScore) { bestScore = d2; best = bone; have = true; }
        }
        if (!have) { g_haveSilent = false; return; }

        g_silentTarget = best;
        g_haveSilent = true;

        float* aPitch = (float*)((char*)aimCtrl + Offsets::AC_pitch);
        float* aYaw   = (float*)((char*)aimCtrl + Offsets::AC_yaw);
        float curP = *aPitch, curY = *aYaw;
        if (curP != curP || curY != curY) return;
        if (fabsf(curP) > 400.f || fabsf(curY) > 800.f) return;

        if (g_silent.load() && !g_aimbot.load()) {
            // Silent: instant on target — NO smooth, NO LookAt (no visible наводка)
            Vec3 dir = vnorm(vsub(best, cpos));
            float yaw   = atan2f(dir.x, dir.z) * 57.2957795f;
            float pitch = -asinf(fmaxf(-1.f, fminf(1.f, dir.y))) * 57.2957795f;
            pitch = fmaxf(-85.f, fminf(85.f, pitch));
            *aPitch = pitch;
            *aYaw   = yaw;
        } else {
            // Soft aimbot: smooth + optional light LookAt
            float sm = fmaxf(1.f, g_smooth.load());
            static Vec3 smT{};
            static bool ini = false;
            if (!ini) { smT = best; ini = true; }
            smT.x += (best.x - smT.x) / sm;
            smT.y += (best.y - smT.y) / sm;
            smT.z += (best.z - smT.z) / sm;
            Vec3 dir = vnorm(vsub(smT, cpos));
            float yaw   = atan2f(dir.x, dir.z) * 57.2957795f;
            float pitch = -asinf(fmaxf(-1.f, fminf(1.f, dir.y))) * 57.2957795f;
            pitch = fmaxf(-85.f, fminf(85.f, pitch));
            float dy = yaw - curY;
            while (dy >  180.f) dy -= 360.f;
            while (dy < -180.f) dy += 360.f;
            *aPitch = curP + (pitch - curP) / sm;
            *aYaw   = curY + dy / sm;
        }
    } @catch (...) {
        g_haveSilent = false;
    }
}

void CoreUI_FeaturesTick() {
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
