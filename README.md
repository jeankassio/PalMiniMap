# PalMiniMap
PalMiniMap — a live minimap radar for Palworld 1.0+
Based on Paldar by T3R3NC3B.

==========================================
WHAT'S NEW IN v1.1.0
==========================================
- New: collected items now disappear from the minimap. When you pick up
  a chest, egg, note or lifmunk effigy (it despawns from the world), its
  icon is removed a few seconds later, so the minimap only shows what is
  still out there. Toggle: "Hide collected items" in the config menu
  (on by default).

==========================================
WHAT'S NEW IN v1.0.12
==========================================
- New "Minimap quality" selector in the config menu (Very Low ... Ultra).
  Lowering it shrinks the minimap's render resolution, which cuts its GPU
  cost - use it if you get stutter/freezing. Applies live.

==========================================
WHAT'S NEW IN v1.0.11
==========================================
- The config menu no longer opens by itself on the title screen; it is
  opened and closed only with F5.
- Redesigned menu: cleaner layout, title card, colored section headers,
  and the numeric options now use a slider with a live value readout
  instead of the old spin box.

=========================================
WHAT'S NEW IN v1.0.10
=========================================
- Fixes the config menu / features not loading on the Steam Workshop
  version (the UE4SS Lua script was deployed to the wrong path). Manual
  installs were unaffected. The config menu again auto-opens on the
  title screen and with F5 in-game.

=========================================
WHAT'S NEW IN v1.0.9
=========================================
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

=======================================
REQUIREMENTS
=======================================
- Palworld 1.0.x
- UE4SS (Experimental build for Palworld) must already be installed.
  If you don't have it, install UE4SS first, then this mod.

=======================================
MANUAL INSTALLATION (recommended for Nexus)
=======================================
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

=====================================
VORTEX
=====================================
Vortex's Palworld handler only deploys .pak files (into ~mods) and
cannot place the UE4SS Lua menu into ue4ss\Mods. Please install this
mod manually using the steps above. Do NOT install it through Vortex.

====================================
UNINSTALL
====================================
Delete the six files listed above (and the two PalMiniMap folders).

====================================
USAGE
====================================
- Config menu opens on the title screen and with F5 in-game.
- In minimap edit mode (K): move with arrow keys, resize with + / - .
- Fine zoom: press + / - while playing. Z toggles megazoom.
- Settings persist across mod updates (kept in Paldar.modconfig.json,
  auto-created on first run, backed up next to the scripts).
