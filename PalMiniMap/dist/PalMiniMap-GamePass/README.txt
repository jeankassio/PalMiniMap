PalMiniMap - a minimap radar for Palworld 1.0.x  (GAME PASS / WinGDK build)
Based on Paldar by T3R3NC3B.

*** This is the GAME PASS / Microsoft Store (WinGDK) build of the mod. ***
*** For the Steam version use the normal (Win64) download instead.     ***

===================================================================
REQUIREMENTS
===================================================================
- Palworld installed via Xbox app / Game Pass (the WinGDK build).
- UE4SS for Game Pass (WinGDK) must already be installed. This is NOT
  the same UE4SS as the Steam version:
    * Download the UE4SS release that explicitly supports Game Pass /
      Microsoft Store / WinGDK (the "XInput" build).
    * Extract it into:  ...\Palworld\Content\Pal\Binaries\WinGDK
    * Rename  XInput1_3.dll  to  XInput1_4.dll  (required on Game Pass).
  If you don't have UE4SS for WinGDK yet, install it first, then this mod.

===================================================================
INSTALLATION
===================================================================
1. Open your Game Pass Palworld install folder. By default this is:

     C:\XboxGames\Palworld\Content\

   That is the folder that CONTAINS the "Pal" folder.

2. Copy the "Pal" folder from this archive into that folder and let it
   MERGE. Nothing is overwritten - it only adds files.

That's it. The files land here:
  Pal\Content\Paks\LogicMods\PalMiniMap.pak
  Pal\Content\Paks\LogicMods\PalMiniMap.utoc
  Pal\Content\Paks\LogicMods\PalMiniMap.ucas
  Pal\Content\Paks\LogicMods\PalMiniMap\config.lua
  Pal\Binaries\WinGDK\ue4ss\Mods\PalMiniMap\Scripts\main.lua
  Pal\Binaries\WinGDK\ue4ss\Mods\PalMiniMap\Scripts\json.lua
  Pal\Binaries\WinGDK\ue4ss\Mods\PalMiniMap\enabled.txt

IMPORTANT: all THREE of PalMiniMap.pak + PalMiniMap.utoc + PalMiniMap.ucas
must be present together. The Game Pass (WinGDK) build uses the IoStore
format, so unlike the Steam version a lone .pak will NOT load the minimap
(the F5 menu would still open, but the map itself never appears).

NOTE: do NOT use the Steam/Win64 build of UE4SS or the Win64 download of
this mod on Game Pass - the WinGDK build only loads mods from the WinGDK
folder shown above.

===================================================================
UNINSTALL
===================================================================
Delete the files listed above (and the two PalMiniMap folders).

===================================================================
WHAT'S NEW IN v1.2.1
===================================================================
- Fixes a crash when loading into the world. The mod could touch the
  minimap actor while it was still initialising, which hard-crashes the
  game; it now waits until the actor is fully ready before touching it.

===================================================================
WHAT'S NEW IN v1.2.0
===================================================================
- In-game menu is now localized (English and Simplified Chinese),
  including the "edit position" overlay.
- Menu controls use the F1-F5 layout; custom keybinds are preserved.
- Minimap opacity and shape apply live, without disturbing other settings.
- More robust around title-screen / world transitions and game shutdown.
- Collected Lifmunk effigies and notes are now removed from the minimap too.

===================================================================
WHAT'S NEW IN v1.1.1
===================================================================
- Reliability: background tasks that error are now logged and skipped
  instead of silently stopping (e.g. "hide collected items" keeps working).
- Performance: cheaper every-frame minimap render (capture LOD bias) to
  help camera-movement stutter. For more FPS, also lower "Minimap quality"
  and turn off icon types you don't need.
- Effigy/note icons are removed once you collect them.

===================================================================
USAGE
===================================================================
- Config menu: open/close with F5 in-game.
- Minimap quality selector (Very Low ... Ultra): lower it if you get
  stutter/freezing - it cuts the minimap's GPU cost.
- "Hide collected items": chests, eggs, notes and lifmunk effigies leave
  the minimap once you collect them (only shows what's still in the world).
- In minimap edit mode (K): move with arrow keys, resize with + / - .
- Fine zoom: press + / - while playing. Z toggles megazoom.
- Settings persist across mod updates (kept in Paldar.modconfig.json,
  auto-created on first run, backed up next to the scripts).
