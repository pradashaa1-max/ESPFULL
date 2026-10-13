#pragma once
#include <cstdint>

// Standoff 2 — UnityFramework (Il2CppDumper, metadata v31)
// RVAs relative to UnityFramework image base. Re-dump after patch.

namespace Offsets {

// UnityEngine.Transform
constexpr uint64_t Transform_get_position      = 0x33237F0;
constexpr uint64_t Transform_set_position      = 0x33238A0;
constexpr uint64_t Transform_get_rotation      = 0x3323ACC;
constexpr uint64_t Transform_set_rotation      = 0x3323B60;
constexpr uint64_t Transform_get_forward       = 0x3323DD8;
constexpr uint64_t Transform_LookAt            = 0x3324990;

// UnityEngine.Camera
constexpr uint64_t Camera_get_main             = 0x32F3E08;
constexpr uint64_t Camera_WorldToScreenPoint   = 0x32F3A54;
constexpr uint64_t Camera_get_fieldOfView      = 0x32F29C8;

// UnityEngine.Component / GameObject
constexpr uint64_t Component_get_transform     = 0x3319A54;
constexpr uint64_t Component_get_gameObject    = 0x3319A94;
constexpr uint64_t GameObject_get_transform    = 0x331A880;

// PlayerController fields (TypeDefIndex 2782)
constexpr size_t PC_mainCameraHolder  = 0x20;
constexpr size_t PC_fpsCameraHolder   = 0x28;
constexpr size_t PC_team              = 0x59;   // Team enum byte
constexpr size_t PC_aimController     = 0x60;   // AimController*
constexpr size_t PC_weaponry          = 0x68;   // WeaponryController*
constexpr size_t PC_movement          = 0x78;
constexpr size_t PC_hitController     = 0x88;   // PlayerHitController*
constexpr size_t PC_characterCtrl     = 0xF0;
constexpr size_t PC_photonView        = 0x120;
constexpr size_t PC_photonPlayer      = 0x130;

// AimController fields (TypeDefIndex 2930)
constexpr size_t AC_sensX             = 0x50;
constexpr size_t AC_sensY             = 0x54;
constexpr size_t AC_fpsCamTr          = 0x70;   // Transform FPSCamera
constexpr size_t AC_camTransform      = 0x80;   // Transform camTransform

// PlayerManager fields (TypeDefIndex 2794)
constexpr size_t PM_dict              = 0x20;   // Dictionary<int,PlayerController>
constexpr size_t PM_hashset           = 0x28;   // HashSet<PlayerController>
constexpr size_t PM_localA            = 0x68;
constexpr size_t PM_localB            = 0x70;

}
