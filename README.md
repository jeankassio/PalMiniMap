# PalMiniMap
PalMiniMap — a live minimap radar for Palworld 1.0+
Based on Paldar by T3R3NC3B.

WHAT'S NEW IN v1.2.6
- Fixes the crash when fast travelling between bases. A fast travel does
  not reload the world in Palworld (it swaps streaming sublevels), so
  none of the world-change safeguards fired while every actor a minimap
  icon is attached to was being destroyed. The 20 s sweep that looked for
  collected chest/egg/note/effigy icons walked those icons straight
  through the teardown and eventually read freed memory. Confirmed from
  the crash dump: the fault landed exactly on a sweep tick, reading
  address 0x1b, with a callstack made only of UE4SS Lua frames.
- That sweep is removed. The minimap blueprint already destroys and
  rebuilds all four of those icon lists on every rescan, so collected
  items still disappear on their own; the sweep only made it a few
  seconds faster.
- The remaining icon passes pause for 12 s whenever a teleport or a
  loading screen is detected (pawn missing, or the pawn jumping further
  than anything in the game can travel).
- The player pawn is read with a direct engine call instead of the
  UEHelpers path, which walked the entire UObject array on every call.

WHAT'S NEW IN v1.2.5
- Fixes the FPS decay reported when staying in one area for a long time
  (and the occasional crash on alt-tab that came with it). The pal icon
  array is the only one the blueprint never rebuilds by itself: a pal
  that just despawns leaves its minimap icon behind forever, and every
  per-frame icon loop keeps walking it. The janitor that is supposed to
  cap that array was silently doing nothing on some UE4SS builds - it
  assumed the array had been cleared without ever checking. It now
  verifies the array is really empty, uses a fallback if the engine call
  is unsupported, and only destroys icon components once they are proven
  to be unreferenced (destroying referenced ones was the crash).
- The icon count is now checked every 10 s instead of every 30 s, so a
  busy area can no longer sit far above the cap between passes.
- Orphaned icons that cannot be removed are now fully quiesced (render
  and tick both switched off) instead of merely hidden.
- The config menu no longer refuses to open after a transient hiccup:
  a momentarily unreadable settings file now falls back to the values
  already in memory, a blank world name is adopted instead of dead-ending,
  a failed open cleans up after itself, and every refusal says why in
  UE4SS.log.
- Added a periodic "icon census" line to UE4SS.log listing how many
  entries each icon array holds - please include it in any performance
  report.

WHAT'S NEW IN v1.1.0
- New: collected items now disappear from the minimap. When you pick up
  a chest, egg, note or lifmunk effigy (it despawns from the world), its
  icon is removed a few seconds later, so the minimap only shows what is
  still out there. Toggle: "Hide collected items" in the config menu
  (on by default).

WHAT'S NEW IN v1.0.12
- New "Minimap quality" selector in the config menu (Very Low ... Ultra).
  Lowering it shrinks the minimap's render resolution, which cuts its GPU
  cost - use it if you get stutter/freezing. Applies live.

WHAT'S NEW IN v1.0.11
- The config menu no longer opens by itself on the title screen; it is
  opened and closed only with F5.
- Redesigned menu: cleaner layout, title card, colored section headers,
  and the numeric options now use a slider with a live value readout
  instead of the old spin box.

WHAT'S NEW IN v1.0.10
- Fixes the config menu / features not loading on the Steam Workshop
  version (the UE4SS Lua script was deployed to the wrong path). Manual
  installs were unaffected. The config menu again auto-opens on the
  title screen and with F5 in-game.

WHAT'S NEW IN v1.0.9
- Fixes freezing/stutter reported by some users. Removed the
  experimental minimap scene-capture manipulation (manual capture,
  render-target resizing, visibility toggling) that could stall or
  crash the render path on some setups (notably DirectX 11); terrain
  capture is now left entirely to the game's own blueprint.
- Hardened the pal-icon "janitor" so it no longer resets the icons on
  every pass on UE4SS builds where the array clear is a no-op (this
  caused a recurring hitch). Resets are now rate-limited and ignore
  harmless mid-scan states.
- Throttled the full-object actor scan so it can no longer repeat every
  few seconds when the minimap actor isn't found.

REQUIREMENTS
- Palworld 1.0.x
- UE4SS (Experimental build for Palworld) must already be installed.
  If you don't have it, install UE4SS first, then this mod.

MANUAL INSTALLATION (recommended for Nexus)
1. Open your Palworld install folder. This is the folder that
   CONTAINS the "Pal" folder, for example:

     ...\steamapps\common\Palworld\

2. Copy the "Pal" folder from this archive into that folder and
   let it MERGE. Nothing is overwritten - it only adds files.

That's it. The files land here:
  Pal\Content\Paks\LogicMods\PalMiniMap.pak
  Pal\Content\Paks\LogicMods\Paldar.modconfig.json
  Pal\Content\Paks\LogicMods\PalMiniMap\config.lua
  Pal\Binaries\Win64\ue4ss\Mods\PalMiniMap\Scripts\main.lua
  Pal\Binaries\Win64\ue4ss\Mods\PalMiniMap\Scripts\json.lua
  Pal\Binaries\Win64\ue4ss\Mods\PalMiniMap\enabled.txt

VORTEX
Vortex's Palworld handler only deploys .pak files (into ~mods) and
cannot place the UE4SS Lua menu into ue4ss\Mods. Please install this
mod manually using the steps above. Do NOT install it through Vortex.

UNINSTALL
Delete the six files listed above (and the two PalMiniMap folders).

USAGE
- Config menu opens on the title screen and with F5 in-game.
- In minimap edit mode (K): move with arrow keys, resize with + / - .
- Fine zoom: press + / - while playing. Z toggles megazoom.
- Settings persist across mod updates (kept in Paldar.modconfig.json,
  auto-created on first run, backed up next to the scripts).
