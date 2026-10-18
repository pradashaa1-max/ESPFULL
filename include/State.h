#pragma once
#include <atomic>
#include <cstdint>

// Feature toggles
extern std::atomic<bool>  g_aimbot;
extern std::atomic<bool>  g_silent;
extern std::atomic<bool>  g_fovDraw;
extern std::atomic<bool>  g_espBox;
extern std::atomic<bool>  g_espSkel;
extern std::atomic<bool>  g_espName;
extern std::atomic<bool>  g_espHP;
extern std::atomic<bool>  g_espWeapon;
extern std::atomic<bool>  g_espDist;
extern std::atomic<bool>  g_espTeam;
extern std::atomic<bool>  g_noRecoil;
extern std::atomic<bool>  g_hideRec;      // stream/screenshot hide — OFF by default (avoids permanent home indicator)
extern std::atomic<bool>  g_menuOpen;
extern std::atomic<float> g_fov;          // 1..30
extern std::atomic<float> g_smooth;       // 1..15
extern std::atomic<int>   g_bone;         // 0 head 1 neck 2 chest
extern std::atomic<int>   g_lang;         // 0 EN 1 RU
extern std::atomic<uint32_t> g_menuColor; // ARGB accent

// Shared secure root (menu + ESP live here when hide-rec on)
#ifdef __OBJC__
@class UIView;
extern UIView* CoreUI_SecureRoot;
#endif

// Config persist
void CoreUI_SaveConfig(void);
void CoreUI_LoadConfig(void);
