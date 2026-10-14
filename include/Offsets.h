#pragma once
#include <cstdint>

// Exact RVAs from user dump.cs (UnityFramework) — 100% this build
namespace Offsets {

// UnityEngine.Transform
constexpr uint64_t Transform_get_position         = 0x33237F0;
constexpr uint64_t Transform_get_position_Injected= 0x3323850;
constexpr uint64_t Transform_get_forward          = 0x3323DD8;
constexpr uint64_t Transform_LookAt_Vector3       = 0x3324990;
constexpr uint64_t Transform_Internal_LookAt_Inj  = 0x3324A10;

// UnityEngine.Camera
constexpr uint64_t Camera_get_main                = 0x32F3E08;
constexpr uint64_t Camera_WorldToScreenPoint      = 0x32F3A54;
constexpr uint64_t Camera_WorldToScreenPoint_Inj  = 0x32F3740; // eye + out

// UnityEngine.Component
constexpr uint64_t Component_get_transform        = 0x3319A54;

// PlayerController (Axlebolt.Standoff.Player)
constexpr size_t PC_team           = 0x59;
constexpr size_t PC_aimController  = 0x60;
constexpr size_t PC_weaponry       = 0x68;
constexpr size_t PC_hitController  = 0x88;
constexpr size_t PC_transform      = 0xD8;  // CBCBGACGGECGEAA
constexpr size_t PC_photonPlayer   = 0x130;

// PhotonPlayer
constexpr size_t PP_nameField      = 0x18;

// WeaponryController
constexpr size_t Wry_weaponCtrl    = 0x98;

// WeaponController
constexpr size_t WCtrl_nameStr     = 0x58;
constexpr size_t WCtrl_intA        = 0x60;

// PlayerManager
constexpr size_t PM_hashset        = 0x28;
constexpr size_t PM_localA         = 0x68;
constexpr size_t PM_localB         = 0x70;

}
