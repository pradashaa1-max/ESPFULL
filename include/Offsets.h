#pragma once
#include <cstdint>

// mark (antilose64) — darling
// PlayerController / BipedMap / Weapon / Photon offsets (user dump)

namespace Offsets {

// Unity (keep previous working RVAs unless proven wrong)
constexpr uint64_t Transform_get_position_Injected = 0x27966C4;
constexpr uint64_t Transform_Internal_LookAt_Inj   = 0x2797CF4;
constexpr uint64_t Camera_get_main                 = 0x27663E8;
constexpr uint64_t Camera_WorldToScreenPoint_Inj   = 0x2765BE8;
constexpr uint64_t Component_get_transform         = 0x27685B4;

// PhotonView
constexpr uint64_t PhotonView_get_isMine           = 0x1C15900;

// Hooks RVA (darling)
constexpr uint64_t Hook_LateUpdate                 = 0x1AB09FC;
constexpr uint64_t Hook_GetInputs                  = 0x1ACA798;
constexpr uint64_t Hook_CastHit                    = 0x1917ECC;

// PlayerController
constexpr size_t PC_characterBiped    = 0x30;  // biped_map 0x38→0x30
constexpr size_t PC_team              = 0x49;
constexpr size_t PC_aimController     = 0x50;  // 0x90→0x50
constexpr size_t PC_weaponry          = 0x58;  // 0x98→0x58
constexpr size_t PC_occlusion         = 0x80;  // 0xC0→0x80
constexpr size_t PC_hitController     = 0x78;
constexpr size_t PC_networkController = 0x88;
constexpr size_t PC_movementCtrl      = 0x68;  // bunnyhop movement 0xA8→0x68
constexpr size_t PC_character         = 0xE8;  // ragebot character 0xF0→0xE8
constexpr size_t PC_transform         = 0xC8;
constexpr size_t PC_photonView        = 0x110;
constexpr size_t PC_photonPlayer      = 0x120; // unchanged

// AimController
constexpr size_t AC_cameraHolder = 0x20;  // 0x28→0x20
constexpr size_t AC_FPSCamera    = 0x70;
constexpr size_t AC_camTransform = 0x80;
constexpr size_t AC_aimingData   = 0x90;  // +0xD0→+0x90
constexpr size_t AC_pitch        = 0x164;
constexpr size_t AC_yaw          = 0x168;

// AimingData
constexpr size_t AD_curAimAng    = 0x18;
constexpr size_t AD_curEulerAng  = 0x24;

// BipedMap (all -8 from previous high set)
constexpr size_t Biped_Head      = 0x18;
constexpr size_t Biped_Neck      = 0x20;
constexpr size_t Biped_Spine1    = 0x28;
constexpr size_t Biped_Spine2    = 0x30;
constexpr size_t Biped_LShoulder = 0x38;
constexpr size_t Biped_LUpperarm = 0x40;
constexpr size_t Biped_LForearm  = 0x48;
constexpr size_t Biped_LHand     = 0x50;
constexpr size_t Biped_RShoulder = 0x58;
constexpr size_t Biped_RUpperarm = 0x60;
constexpr size_t Biped_RForearm  = 0x68;
constexpr size_t Biped_RHand     = 0x70;
constexpr size_t Biped_Hip       = 0x78;
constexpr size_t Biped_LThigh    = 0x80;
constexpr size_t Biped_LCalf     = 0x88;
constexpr size_t Biped_LFoot     = 0x90;
constexpr size_t Biped_RThigh    = 0x98;
constexpr size_t Biped_RCalf     = 0xA0;
constexpr size_t Biped_RFoot     = 0xA8;
constexpr size_t Biped_RThumb0   = 0xB0;
constexpr size_t Biped_LThumb0   = 0xB8;
constexpr size_t Biped_RFinger0  = 0xC0;
constexpr size_t Biped_RFinger1  = 0xC8;
constexpr size_t Biped_RFinger2  = 0xD0;
constexpr size_t Biped_RFinger3  = 0xD8;
constexpr size_t Biped_RFinger4  = 0xE0;

// WeaponController
constexpr size_t WC_weaponParams = 0x68;  // 0xB0→0x68
constexpr size_t WC_commands     = 0x78;  // 0x68→0x78
constexpr size_t WCtrl_nameStr   = 0x58;

// WeaponryController
constexpr size_t Wry_weaponCtrl  = 0x90;  // +0x98→+0x90

// GunParameters / params id/name
constexpr size_t GP_id               = 0x18;
constexpr size_t GP_name             = 0x20;
constexpr size_t GP_recoilControl    = 0xA8;
constexpr size_t GP_recoilParams     = 0xB0;
constexpr size_t GP_recoilMultCrouch = 0xD0;
constexpr size_t GP_recoilAimMult    = 0xD8;
constexpr size_t GP_recoilAimCrouch  = 0xE0;

// RecoilParameters
constexpr size_t RP_horiz    = 0x10;
constexpr size_t RP_vert     = 0x14;
constexpr size_t RP_camDev   = 0x48;
constexpr size_t RP_accelDur = 0x50;
constexpr size_t RP_accelStep= 0x54;

// Movement / bunnyhop
constexpr size_t MC_translationParams = 0xA0; // +0x70→+0xA0

// OcclusionController
constexpr size_t OC_setEnabled = 0x28; // 0x30→0x28
constexpr size_t OC_setInArea  = 0x29; // 0x31→0x29

// PlayerManager
constexpr size_t PM_hashset = 0x20; // players dict 0x28→0x20
constexpr size_t PM_localA  = 0x68; // local_player 0x48→0x68
constexpr size_t PM_localB  = 0x70;

// PhotonPlayer
constexpr size_t PP_nameField         = 0x18;
constexpr size_t PP_customProperties  = 0x30;

// Obfuscated → clear names (documentation)
// PhotonNetwork class: "IAJLHEGDFGF" → "PhotonNetwork"
// networkingPeer: "EAPEHLDBELM" → "networkingPeer"
// singleton: "PJKOLPLMLCC" → "BKBGJADMILK"
// SetTPSView → FCPCDDNGEKN | SetFPSView → IEPENODGEFE
// SetVisible → MKJBFJLHOEK

}
