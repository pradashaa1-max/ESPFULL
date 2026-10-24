
#pragma once
#include <cstdint>

// From YOUR UnityFramework-2 + global-metadata-3.dat (Il2Cpp Metadata 24.4)
namespace Offsets {

constexpr uint64_t Transform_get_position_Injected = 0x27966C4;
constexpr uint64_t Transform_Internal_LookAt_Inj   = 0x2797CF4;
constexpr uint64_t Camera_get_main                 = 0x27663E8;
constexpr uint64_t Camera_WorldToScreenPoint_Inj   = 0x2765BE8;
constexpr uint64_t Component_get_transform         = 0x27685B4;

// PlayerController — THIS dump (not old 0x59/0x60 layout)
constexpr size_t PC_characterBiped    = 0x30;
constexpr size_t PC_team              = 0x49;
constexpr size_t PC_aimController     = 0x50;
constexpr size_t PC_weaponry          = 0x58;
constexpr size_t PC_hitController     = 0x78;
constexpr size_t PC_networkController = 0x88;
constexpr size_t PC_transform         = 0xC8;
constexpr size_t PC_photonView        = 0x110;
constexpr size_t PC_photonPlayer      = 0x120;

constexpr size_t AC_FPSCamera    = 0x70;
constexpr size_t AC_camTransform = 0x80;
constexpr size_t AC_pitch        = 0x164;
constexpr size_t AC_yaw          = 0x168;

constexpr size_t Biped_Head   = 0x18;
constexpr size_t Biped_Neck   = 0x20;
constexpr size_t Biped_Spine1 = 0x28;
constexpr size_t Biped_Hip    = 0x78;

constexpr size_t GP_recoilControl = 0xA8;
constexpr size_t GP_recoilParams  = 0xB0;
constexpr size_t RP_horiz = 0x10;
constexpr size_t RP_vert  = 0x14;

constexpr size_t PM_hashset = 0x28;
constexpr size_t PM_localA  = 0x68;
constexpr size_t PM_localB  = 0x70;

constexpr size_t PP_nameField = 0x18;
constexpr size_t Wry_weaponCtrl = 0x98;
constexpr size_t WCtrl_nameStr  = 0x58;

}
