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
    if (!ok_ptr(pc) || !unity_base()) return false;
    void* pv = *(void**)((char*)pc + Offsets::PC_photonView);
    if (!ok_ptr(pv)) return false;
    using F = bool (*)(void*);
    return R<F>(Offsets::PhotonView_get_isMine)(pv);
}

static void refresh(void* camTr) {
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
        s.hp = read_hp01(pc);
        s.armor = -1.f;
        s.ammo = -1;
        s.ammoMax = -1;
        s.weapon[0] = 0;
        void* wry = *(void**)((char*)pc + Offsets::PC_weaponry);
        if (ok_ptr(wry)) {
            void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
            if (!ok_ptr(wc) && unity_base()) {
                using F = void* (*)(void*);
                wc = R<F>(0x162E58C)(wry);
            }
            if (ok_ptr(wc)) {
                void* ns = *(void**)((char*)wc + 0x58);
                if (ok_ptr(ns)) read_str(ns, s.weapon, sizeof(s.weapon));
                // BHEHACCGBBGGBCH @ 0xE0 / 0xE8 — current & reserve/capacity
                // struct: int max@0x10, int cur@0x14 (after object header)
                auto readAmmoObj = [](void* ao, int* cur, int* mx) {
                    if (!ok_ptr(ao)) return;
                    int a = *(int*)((char*)ao + 0x14);
                    int b = *(int*)((char*)ao + 0x10);
                    if (a >= 0 && a <= 200) *cur = a;
                    if (b >= 0 && b <= 200) *mx = b;
                    // sometimes short property path: value in low 16 bits at 0x14
                    if (*cur < 0) {
                        short sh = *(short*)((char*)ao + 0x14);
                        if (sh >= 0 && sh <= 200) *cur = sh;
                    }
                };
                void* aObj0 = *(void**)((char*)wc + 0xE0);
                void* aObj1 = *(void**)((char*)wc + 0xE8);
                readAmmoObj(aObj0, &s.ammo, &s.ammoMax);
                if (s.ammoMax < 0) readAmmoObj(aObj1, &s.ammoMax, &s.ammoMax);
                // if still empty try ints 0xD8/0xDC as cur only
                if (s.ammo < 0) {
                    int a0 = *(int*)((char*)wc + 0xD8);
                    if (a0 >= 0 && a0 <= 200) s.ammo = a0;
                }
            }
        }
        void* hit = *(void**)((char*)pc + Offsets::PC_hitController);
        if (ok_ptr(hit)) {
            float v = *(float*)((char*)hit + 0xD4);
            if (v == v && v >= 0.f && v <= 100.f) s.armor = v;
        }
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

    // --- world: planted bomb + flying grenades ---
    std::vector<WorldSnap> wtmp;
    auto& api = IL2CPP();
    if (api.ready || api.init()) {
        auto collectType = [&](const char* ns, const char* name, auto handler) {
            Il2CppClass* k = api.find_class(ns, name);
            if (!k) k = api.find_class("", name);
            if (!k || !api.class_get_type || !api.type_get_object) return;
            const Il2CppType* ty = api.class_get_type(k);
            Il2CppObject* typeObj = ty ? api.type_get_object(ty) : nullptr;
            if (!typeObj) return;
            std::vector<void*> arr;
            Il2CppClass* objK = api.find_class("UnityEngine", "Object");
            if (objK) {
                const MethodInfo* fot = api.find_method(objK, "FindObjectsOfType", 1);
                if (fot) {
                    void* exc = nullptr;
                    void* args[1] = { typeObj };
                    Il2CppObject* a = api.runtime_invoke(fot, nullptr, args, &exc);
                    if (!exc) push_array(a, arr, api);
                }
            }
            for (void* o : arr) handler(o);
        };

        collectType("Axlebolt.Standoff.Inventory.Grenade", "DroppedGrenadeController",
                    [&](void* o) {
            // Transform FAFCFFABDEEBFAH — try get_tr
            void* tr = get_tr(o);
            if (!ok_ptr(tr)) {
                // field scan common transform slots
                for (size_t off : {0x18ul, 0x20ul, 0x28ul, 0x30ul}) {
                    void* t = *(void**)((char*)o + off);
                    if (ok_ptr(t)) { tr = t; break; }
                }
            }
            if (!ok_ptr(tr)) return;
            Vec3 pos = get_pos(tr);
            if (pos.x != pos.x) return;
            WorldSnap w{};
            w.pos = pos;
            w.timer = -1.f;
            // GrenadeParameters @ various — name from parameters string if any
            snprintf(w.label, sizeof(w.label), "GRENADE");
            void* gp = *(void**)((char*)o + 0x18); // often parameters
            if (ok_ptr(gp)) {
                // try name field on parameters
                void* ns = *(void**)((char*)gp + 0x10);
                char tmpn[24]{};
                if (ok_ptr(ns)) read_str(ns, tmpn, sizeof(tmpn));
                if (tmpn[0]) snprintf(w.label, sizeof(w.label), "%s", tmpn);
            }
            wtmp.push_back(w);
        });

        collectType("Axlebolt.Standoff.Inventory.Bomb", "PlantedBombController",
                    [&](void* o) {
            void* tr = *(void**)((char*)o + 0x30); // CEHBGAFBGBCFCAC
            if (!ok_ptr(tr)) tr = *(void**)((char*)o + 0xB0);
            if (!ok_ptr(tr)) tr = get_tr(o);
            if (!ok_ptr(tr)) return;
            Vec3 pos = get_pos(tr);
            if (pos.x != pos.x) return;
            WorldSnap w{};
            w.pos = pos;
            // float remaining @ 0xA8, double plant time @ 0xA0
            float rem = *(float*)((char*)o + 0xA8);
            if (!(rem == rem) || rem < 0.f || rem > 120.f) {
                double plant = *(double*)((char*)o + 0xA0);
                // fallback: 40s default CS-like if we only have plant stamp — skip
                rem = -1.f;
                (void)plant;
            }
            w.timer = rem;
            if (rem >= 0.f)
                snprintf(w.label, sizeof(w.label), "BOMB %.0fs", rem);
            else
                snprintf(w.label, sizeof(w.label), "BOMB");
            wtmp.push_back(w);
        });

        // also try without namespace
        if (wtmp.empty()) {
            collectType("", "PlantedBombController", [&](void* o) {
                void* tr = *(void**)((char*)o + 0x30);
                if (!ok_ptr(tr)) tr = get_tr(o);
                if (!ok_ptr(tr)) return;
                Vec3 pos = get_pos(tr);
                if (pos.x != pos.x) return;
                WorldSnap w{};
                w.pos = pos;
                float rem = *(float*)((char*)o + 0xA8);
                w.timer = (rem == rem && rem >= 0.f && rem <= 120.f) ? rem : -1.f;
                if (w.timer >= 0.f) snprintf(w.label, sizeof(w.label), "BOMB %.0fs", w.timer);
                else snprintf(w.label, sizeof(w.label), "BOMB");
                wtmp.push_back(w);
            });
        }
    }

    std::lock_guard<std::mutex> lk(g_mtx);
    g_list.swap(tmp);
    g_world.swap(wtmp);
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
        if (hgt < 10.f) hgt = 36.f;
        CGFloat mid  = (fx + hx) * 0.5f;
        CGFloat wid  = hgt * 0.45f;
        CGFloat left = mid - wid * 0.5f;
        CGFloat corner = fmaxf(6.f, hgt * 0.22f);

        UIColor* col = [UIColor colorWithRed:0.15 green:0.55 blue:1 alpha:1];

        if (box) {
            CGContextSetStrokeColorWithColor(ctx, col.CGColor);
            CGContextSetLineWidth(ctx, 1.8);
            draw_corner(ctx, left, top, wid, hgt, corner);
        }
        if (skel) {
            // head marker only — no vertical line through box
            CGContextSetFillColorWithColor(ctx, col.CGColor);
            CGContextFillEllipseInRect(ctx, CGRectMake(hx - 3, hy - 3, 6, 6));
        }
        if (hpOn) {
            CGFloat barH = hgt;
            CGFloat barW = 3.f;
            CGFloat bx = left - 6.f;
            CGFloat hp = p.hp >= 0.f ? p.hp : 1.f;
            CGContextSetFillColorWithColor(ctx, [UIColor colorWithWhite:0 alpha:0.45].CGColor);
            CGContextFillRect(ctx, CGRectMake(bx, top, barW, barH));
            UIColor* hc = hp > 0.5f ? [UIColor colorWithRed:0.2 green:0.9 blue:0.3 alpha:1]
                         : hp > 0.25f ? [UIColor colorWithRed:0.95 green:0.75 blue:0.1 alpha:1]
                         : [UIColor colorWithRed:0.95 green:0.2 blue:0.15 alpha:1];
            CGContextSetFillColorWithColor(ctx, hc.CGColor);
            CGFloat fill = barH * hp;
            CGContextFillRect(ctx, CGRectMake(bx, top + (barH - fill), barW, fill));
        }
        if (nameOn || distOn || g_espWeapon.load()) {
            NSMutableString* lab = [NSMutableString stringWithUTF8String:p.name];
            if (distOn) {
                float d = vdist(feet, cpos);
                [lab appendFormat:@" %.0fm", d];
            }
            [lab drawAtPoint:CGPointMake(left, top - 13)
              withAttributes:@{
                  NSFontAttributeName: [UIFont boldSystemFontOfSize:11],
                  NSForegroundColorAttributeName: UIColor.whiteColor
              }];
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
                [wpn drawAtPoint:CGPointMake(left, bot + 2)
                  withAttributes:@{
                      NSFontAttributeName: [UIFont systemFontOfSize:10],
                      NSForegroundColorAttributeName: [UIColor colorWithRed:0.85 green:0.85 blue:0.4 alpha:1]
                  }];
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

    // grenades + bomb
    std::vector<WorldSnap> world;
    {
        std::lock_guard<std::mutex> lk(g_mtx);
        world = g_world;
    }
    for (auto& w : world) {
        Vec3 sc = w2s(cam, w.pos);
        if (sc.z < 0.05f) continue;
        CGFloat x = sc.x - 3.f;
        CGFloat y = H - sc.y - 3.f;
        if (x < -40 || x > W + 40 || y < -40 || y > H + 40) continue;
        BOOL isBomb = (strncmp(w.label, "BOMB", 4) == 0);
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

// Safe recoil: only 3 float multipliers on WeaponParameters, absolute, once.
// Never touch nested RecoilParameters* (that crashed).
// Recoil: zero GunController instance floats (runtime), never SO
static void apply_recoil(void* localPc) {
    float pct = g_recoilPct.load();
    if (pct < 1.f || !ok_ptr(localPc)) return;

    void* wry = *(void**)((char*)localPc + Offsets::PC_weaponry);
    if (!ok_ptr(wry)) return;
    void* wc = *(void**)((char*)wry + Offsets::Wry_weaponCtrl);
    if (!ok_ptr(wc) && unity_base()) {
        using F = void* (*)(void*);
        wc = R<F>(0x162E58C)(wry);
    }
    if (!ok_ptr(wc)) return;

    // GunController runtime floats @ 0xD0 / 0xD4 — damp by pct
    float keep = 1.f - pct / 100.f;
    if (keep < 0.f) keep = 0.f;
    @try {
        float* f0 = (float*)((char*)wc + 0xD0);
        float* f1 = (float*)((char*)wc + 0xD4);
        if (*f0 == *f0 && fabsf(*f0) < 50.f) *f0 *= keep;
        if (*f1 == *f1 && fabsf(*f1) < 50.f) *f1 *= keep;
        // also zero common recoil progress ints area carefully
        if (pct >= 90.f) {
            if (*f0 == *f0) *f0 = 0.f;
            if (*f1 == *f1) *f1 = 0.f;
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

        if (!g_aimbot.load()) {
            g_haveSilent = false;
            return;
        }
        if (!ok_ptr(cam) || !ok_ptr(camTr) || !ok_ptr(localPc)) return;

        void* aimCtrl = *(void**)((char*)localPc + Offsets::PC_aimController);
        if (!ok_ptr(aimCtrl)) return;

        void* aimTr = *(void**)((char*)aimCtrl + Offsets::AC_camTransform);
        if (!ok_ptr(aimTr)) {
            // FPSCamera transform @ 0x70
            aimTr = *(void**)((char*)aimCtrl + Offsets::AC_FPSCamera);
        }
        if (!ok_ptr(aimTr)) aimTr = camTr;

        CGSize scr = g_esp ? g_esp.bounds.size : UIScreen.mainScreen.bounds.size;
        float cx = scr.width * 0.5f, cy = scr.height * 0.5f;
        float side = fminf(scr.width, scr.height);
        float fovR = side * (0.05f + g_fov.load() / 30.f * 0.25f);

        Vec3 cpos = get_pos(aimTr);
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

            // visible check for aim only (Linecast no hitInfo — safer)
            if (unity_base()) {
                using LC = bool (*)(Vec3*, Vec3*, int);
                Vec3 from = cpos;
                // slight lift so we don't start inside local collider
                from.y += 0.1f;
                if (R<LC>(0x336E920)(&from, &bone, ~0)) {
                    // blocked by something — skip (wall)
                    // Note: may false-positive on own gun; if aim never locks, comment out
                    continue;
                }
            }

            Vec3 sc = w2s(cam, bone);
            if (sc.z < 0.05f) continue;
            float sx = sc.x - 3.f;
            float sy = (scr.height - sc.y) - 3.f;
            float dx = sx - cx, dy = sy - cy;
            float d2 = sqrtf(dx*dx + dy*dy);
            if (d2 > fovR) continue;
            if (d2 < bestScore) { bestScore = d2; best = bone; have = true; }
        }
        if (!have) {
            g_haveSilent = false;
            return;
        }

        g_silentTarget = best;
        g_haveSilent = true;

        float sm = fmaxf(1.f, g_smooth.load());
        if (g_silent.load()) sm = 1.f;

        static Vec3 smT{};
        static bool ini = false;
        if (!ini) { smT = best; ini = true; }
        smT.x += (best.x - smT.x) / sm;
        smT.y += (best.y - smT.y) / sm;
        smT.z += (best.z - smT.z) / sm;

        Vec3 dir = vnorm(vsub(smT, cpos));
        float yaw   = atan2f(dir.x, dir.z) * 57.2957795f;
        float pitch = -asinf(fmaxf(-1.f, fminf(1.f, dir.y))) * 57.2957795f;
        if (pitch < -85.f) pitch = -85.f;
        if (pitch >  85.f) pitch =  85.f;

        // Write AimController angles (0x164 / 0x168)
        float* aPitch = (float*)((char*)aimCtrl + Offsets::AC_pitch);
        float* aYaw   = (float*)((char*)aimCtrl + Offsets::AC_yaw);
        float curP = *aPitch, curY = *aYaw;
        if (curP == curP && fabsf(curP) < 360.f) {
            *aPitch = g_silent.load() ? pitch : (curP + (pitch - curP) / fmaxf(1.f, sm));
        }
        if (curY == curY && fabsf(curY) < 720.f) {
            float dy = yaw - curY;
            while (dy >  180.f) dy -= 360.f;
            while (dy < -180.f) dy += 360.f;
            *aYaw = g_silent.load() ? yaw : (curY + dy / fmaxf(1.f, sm));
        }

        // Also set euler on camTransform — makes aim actually move view
        // silent still sets it so shots follow; game often reads transform for fire
        if (ok_ptr(aimTr) && unity_base()) {
            Vec3 up{0, 1, 0};
            using Look = void (*)(void*, Vec3*, Vec3*);
            R<Look>(Offsets::Transform_Internal_LookAt_Inj)(aimTr, &smT, &up);
        }
    } @catch (...) {
        g_haveSilent = false;
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

    bool wantEsp = g_espBox.load() || g_espSkel.load() || g_espName.load() || g_espDist.load() || g_espHP.load() || g_espWeapon.load();
    bool wantAim = g_aimbot.load();
    bool wantRec = g_recoilPct.load() > 0.5f;
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
        if (n == 0 || ++g_ctr >= 3) {
            g_ctr = 0;
            refresh(camTr);
        }
    }
    if (wantAim || wantRec) run_aim(cam, camTr);
}
