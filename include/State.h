#pragma once
#include <atomic>
#include <cstdint>

// Feature toggles
extern std::atomic<bool>  g_aimbot;
extern std::atomic<bool>  g_silent;
extern std::atomic<bool>  g_aimVisible;  // aim only if visible
extern std::atomic<bool>  g_fovDraw;
extern std::atomic<bool>  g_espBox;
extern std::atomic<bool>  g_espSkel;
extern std::atomic<bool>  g_espName;
extern std::atomic<bool>  g_espHP;
extern std::atomic<bool>  g_espWeapon;
extern std::atomic<bool>  g_espBomb;
extern std::atomic<bool>  g_espGrenade;
extern std::atomic<bool>  g_espDist;
extern std::atomic<bool>  g_espTeam;
extern std::atomic<bool>  g_noRecoil;     // legacy — syncs with recoilPct
extern std::atomic<float> g_recoilPct;    // 0..100 (0=full, 100=zero)
extern std::atomic<bool>  g_hideRec;
extern std::atomic<bool>  g_menuOpen;
extern std::atomic<float> g_fov;
extern std::atomic<float> g_smooth;
extern std::atomic<int>   g_bone;
extern std::atomic<int>   g_lang;
extern std::atomic<uint32_t> g_menuColor;

#ifdef __OBJC__
@class UIView;
extern UIView* Astral_SecureRoot;
#endif

void Astral_SaveConfig(void);
void Astral_LoadConfig(void);
