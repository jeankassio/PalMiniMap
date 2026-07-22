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
  Pal\Content\Paks\LogicMods\PalMiniMap\config.lua
  Pal\Binaries\WinGDK\ue4ss\Mods\PalMiniMap\Scripts\main.lua
  Pal\Binaries\WinGDK\ue4ss\Mods\PalMiniMap\Scripts\json.lua
  Pal\Binaries\WinGDK\ue4ss\Mods\PalMiniMap\enabled.txt

NOTE: do NOT use the Steam/Win64 build of UE4SS or the Win64 download of
this mod on Game Pass - the WinGDK build only loads mods from the WinGDK
folder shown above.

===================================================================
UNINSTALL
===================================================================
Delete the files listed above (and the two PalMiniMap folders).

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
