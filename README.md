# mark (antilose64)

Private client for **darling**.

- Brand: mark / antilose64
- Target game: darling
- Offsets: PlayerController biped 0x30, aim 0x50, weaponry 0x58, photonPlayer 0x120
- BipedMap head 0x18 … (see include/Offsets.h)
- Hooks: LateUpdate 0x1AB09FC, GetInputs 0x1ACA798, CastHit 0x1917ECC

Build via GitHub Actions / Theos. Inject with TrollFools.

FAB icon: letter **M** (red accent). Replace with custom image in Menu.mm buildFab if needed.
