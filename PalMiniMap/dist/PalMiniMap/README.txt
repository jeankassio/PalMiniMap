PalMiniMap - a minimap radar for Palworld 1.0.x
Based on Paldar by T3R3NC3B.

===================================================================
WHAT'S NEW IN v1.2.7
===================================================================
- Hardening pass: every place the mod can be entered from outside
  (key presses, timers, engine hooks, script load) and every operation
  that can fail (engine calls, file reads/writes, JSON) now runs inside
  an error guard. A failure is written to UE4SS.log and the mod carries
  on instead of the feature dying silently.
- Startup is no longer all-or-nothing. Each keybind, each timer and the
  settings file register independently, so one that fails on your build
  costs only itself - previously anything registered after a failure
  simply never happened, and the mod looked "loaded" with no janitor
  and no menu.
- Menu rows are built one by one: a single option the engine refuses to
  render no longer takes the whole menu down with it.
- Errors are logged with a stack traceback, and a repeating error is
  summarised once a minute instead of filling the log.
- A missing dependency now reports one clear FATAL line instead of
  failing over and over.

  NOTE, honestly: this catches errors raised by Lua. It cannot catch a
  native access violation - when the engine reads memory it already
  freed, the game is gone before any handler runs. Those are avoided by
  the world-change and teleport guards from v1.2.6, not by this.

===================================================================
WHAT'S NEW IN v1.2.6
===================================================================
- Fixes the crash when fast travelling between bases.
  A fast travel does not reload the world in Palworld - it swaps
  streaming sublevels - so the mod's world-change safeguards never
  fired, while every actor a minimap icon is attached to was being
  destroyed underneath it. The 20-second sweep that looked for
  collected chest/egg/note/effigy icons was walking those icons right
  through the teardown and eventually read freed memory.
  That sweep has been removed entirely: the minimap blueprint already
  destroys and rebuilds all four of those icon lists on every rescan,
  so collected items still disappear on their own - the sweep only
  made it a few seconds faster, at the price of the crash.
- The remaining icon passes now pause for 12 seconds whenever a
  teleport or a loading screen is detected (player pawn missing, or
  the pawn jumping further than anything in the game can travel).
- The pawn is read through a direct engine call instead of the helper
  that scans the whole object list on every single call.

===================================================================
WHAT'S NEW IN v1.2.5
===================================================================
- Fixes the FPS decay when you stay in one area for a long time, and the
  occasional crash on alt-tab that came with it.
  Cause: the pal icon list is the only one the minimap blueprint never
  rebuilds by itself. A pal that simply despawns leaves its icon in that
  list forever, and every per-frame icon loop keeps walking it, so the
  cost climbs the longer a level stays loaded (a loading-screen fast
  travel resets it - which is exactly what players reported).
  The janitor that caps that list was silently doing nothing on some
  UE4SS builds: it assumed the list had been cleared without ever
  checking, then destroyed icons the blueprint was still using. It now
  proves the list is empty first, falls back to another method when the
  engine call is unsupported, and only destroys icons once they are
  provably unreferenced.
- The icon count is checked every 10 seconds instead of every 30, so a
  busy area no longer sits far above the cap between passes.
- Icons that cannot be removed are now fully switched off (render and
  tick) instead of only hidden.
- The config menu no longer refuses to open after a transient hiccup, and
  it now writes the reason to UE4SS.log whenever it does refuse.
- New "icon census" line in UE4SS.log every 5 minutes - please include it
  in any performance report.

===================================================================
WHAT'S NEW IN v1.2.2
===================================================================
- Fixes a crash after several minutes of play. When an item was collected
  its minimap icon was destroyed but left behind in the mod's internal
  list, so the same icon was destroyed again every few seconds until the
  game crashed. Collected icons are now hidden instead of destroyed.

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
- Menu controls use the F1-F5 layout; your custom keybinds are kept if
  you changed them.
- Minimap opacity and shape now apply live, without disturbing other
  settings.
- More robust around title-screen / world transitions and game shutdown
  (no more stale-object errors or backup warnings).
- Collected Lifmunk effigies and notes are now removed from the minimap
  too (they stay in the world but are hidden once you pick them up).

===================================================================
WHAT'S NEW IN v1.1.1
===================================================================
- Reliability: if a background task ever errors, it is now logged and
  skipped instead of silently stopping - so features like "hide collected
  items" keep working for the rest of the session.
- Performance: the minimap's every-frame render now uses cheaper detail
  (capture LOD bias), which helps the camera-movement stutter. For more
  FPS, also lower the "Minimap quality" slider and turn off icon types
  you don't need.
- Effigy/note icons are removed once you collect them (community fix).

===================================================================
WHAT'S NEW IN v1.1.0
===================================================================
- New: collected items now disappear from the minimap. When you pick up
  a chest, egg, note or lifmunk effigy (it despawns from the world), its
  icon is removed a few seconds later, so the minimap only shows what is
  still out there. Toggle: "Hide collected items" in the config menu
  (on by default).

===================================================================
WHAT'S NEW IN v1.0.12
===================================================================
- New "Minimap quality" selector in the config menu (Very Low ... Ultra).
  Lowering it shrinks the minimap's render resolution, which cuts its GPU
  cost - use it if you get stutter/freezing. Applies live.

===================================================================
WHAT'S NEW IN v1.0.11
===================================================================
- The config menu no longer opens by itself on the title screen; it is
  opened and closed only with F5.
- Redesigned menu: cleaner layout, title card, colored section headers,
  and the numeric options now use a slider with a live value readout
  instead of the old spin box.

===================================================================
WHAT'S NEW IN v1.0.10
===================================================================
- Fixes the config menu / features not loading on the Steam Workshop
  version (the UE4SS Lua script was deployed to the wrong path). Manual
  installs were unaffected. The config menu again auto-opens on the
  title screen and with F5 in-game.

===================================================================
WHAT'S NEW IN v1.0.9
===================================================================
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

===================================================================
REQUIREMENTS
===================================================================
- Palworld 1.0.x
- UE4SS (Experimental build for Palworld) must already be installed.
  If you don't have it, install UE4SS first, then this mod.

===================================================================
MANUAL INSTALLATION (recommended for Nexus)
===================================================================
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

===================================================================
VORTEX
===================================================================
Vortex's Palworld handler only deploys .pak files (into ~mods) and
cannot place the UE4SS Lua menu into ue4ss\Mods. Please install this
mod manually using the steps above. Do NOT install it through Vortex.

===================================================================
UNINSTALL
===================================================================
Delete the six files listed above (and the two PalMiniMap folders).

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
