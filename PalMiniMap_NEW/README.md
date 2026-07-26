# PalMiniMap 2.0 — native minimap for Palworld

A complete rewrite. No blueprint, **no `.pak`**, no bundled assets — the whole
mod is UE4SS Lua driving UMG, drawing the game's own world map texture and the
game's own icon textures.

## Why it was rewritten

The 1.x line was built on the Paldar blueprint, and every serious bug it ever
had came from two decisions inside that blueprint:

1. **A `SceneCaptureComponent2D` re-rendered the entire world from above, every
   frame**, into a render target. That is a second full render pass running at
   all times — the permanent GPU cost and the camera-movement stutter.
2. **Icons were `StaticMeshComponent`s attached to the actors they marked.**
   That produced the FPS decay (the pal icon array is the one the blueprint
   never rebuilds, so despawned pals left icons behind forever) and both hard
   crashes — v1.2.2 from destroying an icon twice, v1.2.6 from walking icon
   arrays while a fast travel tore down the streaming sublevels underneath.

Version 2 has neither mechanism, so neither class of bug can occur.

## How it works

| concern | 1.x | 2.0 |
|---|---|---|
| terrain | scene capture, every frame | game's `T_WorldMap` texture, one quad |
| icons | `StaticMeshComponent` attached to actors | pooled UMG `Image` widgets |
| icon lifetime | created/destroyed constantly | fixed pool, allocated once, reused |
| update rate | per frame | 10 Hz movement, 0.25 Hz pal scan, 15 s static scan |
| assets shipped | a `.pak` | none |
| packaging | Steam/Nexus `.pak` + Game Pass IoStore triplet | one identical package |

Panning is done by moving a large `Image` inside a clipped `CanvasPanel`, so the
GPU draws exactly one textured quad regardless of zoom. Icons are positioned by
arithmetic on the same transform and culled before any widget is touched.

## Coordinates

The world→map transform is **not guesswork**. It was decoded from the game's own
data table `/Game/Pal/DataTable/WorldMapUIData/DT_WorldMapUIData`
(struct `PalWorldMapUIDataTableRow`):

| region | min (X, Y) | max (X, Y) | span |
|---|---|---|---|
| main island | −1 099 400, −724 400 | 349 400, 724 400 | 1 448 800 |
| second island | 347 351.5, −818 197 | 689 148.5, −476 400 | 341 797 |

Both spans come out as exact squares, which is the self-check that these are the
bounds the square map texture is stretched over.

`worldmap.calibrate()` additionally reads `landScapeRealPositionMin/Max` straight
out of the game's own map widget whenever it happens to be loaded, so the mod
corrects itself if a game update moves the world.

## Controls

| key | action |
|---|---|
| `F1` | megazoom (region view) |
| `F2` | cycle corner |
| `F3` | show / hide |
| `F4` | edit mode — arrows move, `+`/`-` resize |
| `F5` | configuration menu |
| `+` / `-` | zoom |

Same layout as 1.x, deliberately.

## Feature parity with 1.x

Everything the 1.x menu offered, except the options that configured
machinery version 2 no longer has:

| 1.x option | 2.0.1 |
|---|---|
| Enable mod | `enabled` (F3) |
| Minimap opacity | yes |
| Minimap shape (circle/square) | yes — `circular` |
| Autozoom while moving | yes — widens with walk/run/fly speed |
| Rotation lock (north up) | yes — `rotateWithCamera` |
| Lock all icon rotations to north | yes — `lockIconsNorth` |
| Autohide while in base camps | yes — `autohideInBase` |
| Hide collected items | yes — `hideCollected` |
| Show pal positions | yes |
| Only show shiny pals | yes — via `IsRarePal()` |
| Show pal icons while megazoomed | yes — `palsWhileMegazoom` |
| Show NPC humans | yes |
| Show player base camps / enemy camps | yes |
| Show player death locations | yes |
| Show other players | yes |
| Show dungeons / towers | yes |
| Show chests / eggs / notes | yes |
| Show fast travel points | yes |
| Show skillfruit trees | yes |
| Show lifmunk effigies | yes |
| Rescan frequency | yes — one control instead of five |
| Keybinds F1–F5 | yes, same layout |
| Minimap render resolution | **gone** — configured the scene capture |
| Minimap capture LOD bias | **gone** — same reason |
| Edit mode "new size method" | **gone** — `+`/`-` always resize in edit mode |

Two rows are new: **map orientation** (the escape hatch described below)
and a single **rescan interval** replacing 1.x's five separate ones.

## Where the object classes come from

Not guesswork either. Every class scanned was read out of the original
Paldar blueprint's import table — these are literally the classes the 1.x
mod used, so they are known-good on this build:

`PalCharacter` · `PalPlayerCharacter` · `PalNPC` ·
`PalMapObjectTreasureBox` · `PalMapObjectPalEgg` · `PalLevelObjectNote` ·
`PalLevelObjectRelic` · `PalLevelObjectUnlockableFastTravelPoint` ·
`BP_DungeonEntrance_Base_C` · `PalBuildObjectBaseCampPoint` ·
`PalNPCCampSpawnerBase` · `PalBossTower` ·
`PalMapObjectSpawnerMultiItem` · `BP_MapObject_DeathPenaltyChest_C`

2.0.0 scanned the generic `PalMapObject` instead, which is why every wall
and foundation of the player's base showed up as a marker.

Pal species come from the actor name (`BP_<Tribe>_C_<id>` → `<Tribe>`),
which is exactly how the blueprint looked up its icon table, and the tribe
maps straight onto `/Game/Pal/Texture/PalIcon/Normal/T_<Tribe>_icon_normal`
— 137 species icons, nothing shipped.

Settings live in `minimap_settings.json` next to the mod folder. It is plain
JSON owned by this mod — nothing else reads it, so there is no half-written-file
race like the 1.x `Paldar.modconfig.json` had. Writes are atomic anyway.

## Status

**Confirmed in game (2.0.0/2.0.1 runs):** the terrain renders, the world→map
transform is correct, the player marker sits where it should, and the default
axis orientation (north up) is right — the constants decoded from
`DT_WorldMapUIData` are good, so the orientation controls are only an escape
hatch.

**Fixed in 2.0.6 — crash a few seconds into edit mode, plus a scan overhaul:**

The reported failure was:

```
[Lua] [PalMiniMap] edit mode on - arrows move, +/- resize
[UE4SS.EngineTick.LuaModImpl] Hook threw exception:
  "[Lua::Registry::get_function_ref] Ref was not function", removing hook!
[FCallbackGarbageCollector] Freed invalid callbacks!
```

- **Root cause: unsynchronised Lua registry traffic.** Every
  `ExecuteInGameThread` call takes a Lua registry reference (`luaL_ref`) and the
  engine tick releases it (`luaL_unref`) once it has run. That registry is one
  shared, unlocked free list. 2.0.5 had **four** `LoopAsync` timer threads
  (50 ms, 250 ms, 500 ms, 2 s) *plus* the UE4SS input thread all making
  references into it — about 27 a second at idle. When two threads reach the
  free list together they are handed the **same index**; one action is then
  unref'd while the other is still queued, the engine tick reads a slot that no
  longer holds a function, and UE4SS removes its own tick hook. That kills every
  timer in the mod and takes the game with it. Entering edit mode and pressing
  the arrow keys added the input thread to the mix, which is why it reproduced
  there within seconds.
- **The fix is structural, not another guard.** There is now **one** `LoopAsync`,
  and it is the only thread that ever calls `ExecuteInGameThread`. It dispatches
  only when a sub-tick is actually due, so idle cost is one dispatch every 2 s
  instead of 27 a second.
- **Key binds no longer touch the game thread at all.** They append a string to a
  bounded queue — plain Lua, no reflection, no registry reference — and the pump
  drains it. Besides taking the input thread out of the race, this removes the
  re-entrancy hazard of appending to the engine tick's action list from inside a
  callback that tick may itself be dispatching.
- **`+`/`-` in edit mode never resized anything.** `zoomBy` referenced `editMode`
  and `resize` above their `local` declarations, so both resolved to globals —
  i.e. to `nil` — and the branch was dead. Forward-declared.
- **Dragging the window across the screen centre teleported it.** Edit mode was
  nudging an edge-relative coordinate (the default `x = -40`); crossing zero
  flipped its meaning from "40 from the right edge" to "40 from the left edge".
  Edit mode now works in absolute units and converts back to edge-relative for
  the nearer edge on exit, so a saved layout still survives a resolution change.
- **The world scan cost roughly four times less.** Every `FindAllOf` is a full
  walk of the UObject array; 2.0.5 did fourteen of them every four seconds.
  Statics (chests, dungeons, fast travel…) do not move, so they are rescanned on
  a 15 s floor or when the player has actually travelled somewhere new, while
  pals stay on the 4 s tick. The scan radius also follows the zoom actually in
  use instead of always using the 260 000-unit megazoom radius.
- **The point-of-interest budget went to whatever was scanned first.** In a
  chest-heavy area the 48 slots filled with chests and fast travel points and
  dungeons never appeared. Candidates are now distance-sorted, so the budget
  always goes to the nearest markers whatever kind they are.
- **The player was drawn twice, and NPCs were drawn as pals.**
  `PalPlayerCharacter` and `PalNPC` both derive from `PalCharacter`, so
  `FindAllOf("PalCharacter")` returned the local player, every other player and
  every human NPC as well — a duplicate marker sat permanently under the player
  arrow. They are excluded by actor name now.
- **"Max point-of-interest icons" did nothing until a restart** — `needsRebuild`
  only compared the window size, never the icon pool length.
- **F2 always jumped to the top-left first**, because the corner cycle started
  from index 1 regardless of where the saved layout already was.
- **Settings were rewritten on every key press.** Zoom steps and edit-mode
  nudges each did a blocking file write on the game thread; writes are now
  coalesced to at most one a second.
- **The per-frame draw only writes what changed.** 2.0.5 re-sent the map brush,
  and every icon's brush, tint and rotation, ten times a second whether or not
  any of them differed; only position genuinely changes every frame. The draw
  list is pooled too, so ~100 tables a tick no longer go to the collector.
- Resizing (menu slider or `+`/`-` in edit mode) rebuilds immediately instead of
  leaving the minimap missing until the next 2 s maintenance tick.
- The two remaining `FindAllOf` searches that can legitimately find nothing —
  the Esc-menu widget and the map-bounds calibration widget — now back off
  (10 s / 20 s) instead of running a full object-array walk on every tick
  forever.

**Fixed in 2.0.5 — the config window sat off the right-hand edge:**

`GetViewportSize` reports **pixels**, but a UMG `CanvasPanel` positions its
children in **slate units** — pixels divided by the UI's DPI scale. On a 4K
screen Palworld runs a scale of about 2, so centring the window at x = 1570
slate units put it at 3140 real pixels and it hung off the edge with its
controls cut away. The same mistake pushed the minimap's edge-relative corner
presets to x = 3560 slate units — 7120 pixels — i.e. entirely off screen at 4K.

1.x divided by `GetViewportScale` for exactly this reason and the rewrite
dropped it. The division now happens once, inside `viewportSize()`, so
everything downstream (menu geometry, corner presets, edit mode) works in the
units the canvas actually uses. Checked at 4K/scale 2, 4K/scale 1, 1440p/1.33,
1080p/1 and 720p/0.67 — the window lands on screen in every case.

**Fixed in 2.0.4 — the mod did nothing inside a world:**

- **The minimap was built and never shown.** 2.0.2 decided "the game has a
  full-screen UI open" from `pc.bShowMouseCursor`. Palworld leaves that flag
  ON during ordinary gameplay, so the test was true permanently: the widget was
  created, the scans ran (51 pals, 24 chests, 174 fast travel points in the
  log), and every frame immediately hid it again. The heuristic is gone,
  replaced by the actual widget — `WBP_InGameMainMenu` is the Esc menu, and
  asking whether it is in the viewport is exact instead of inferred. It is
  found on the 2 s maintenance tick and only re-checked per frame, so the
  object-array walk never lands on the hot path. A `hideBehindGameUi` switch
  turns the whole behaviour off.
- **The menu was cut off with no scrollbar on the title screen.** Its canvas
  slot used `SetAutoSize(true)`, which sizes the slot to its CONTENT — so the
  `SizeBox` height override was ignored, the `ScrollBox` was never given a
  bounded height, and the window simply grew past the bottom of the screen.
  The slot now has an explicit size, clamped to the viewport and centred.
  Checked from 1024x600 to 3840x2160: it fits every time.
- F5 now logs every press. When the menu did not appear there was no line at
  all, which gave no way to tell "the key never fired" from "it opened
  invisible".

**Fixed in 2.0.3 — crash when opening the menu on the title screen:**

- **Root cause.** The menu cached the `PlayerController` and re-asserted the
  input mode on it four times a second. On the title screen that controller is
  short-lived and is destroyed as the title flow advances, so the next
  `SetInputMode` call landed on freed memory —
  `EXCEPTION_ACCESS_VIOLATION reading 0xffffffffffffffff`, which no `pcall` can
  catch. 1.x had an explicit guard against touching input mode on the
  splash/login/title worlds; the rewrite dropped it. It is back, and the menu
  now resolves the controller fresh on every use instead of holding one.
  Those screens already have a working cursor, so nothing is lost.
- **The stall before the crash.** `guard` used `describe()` as the `xpcall`
  message handler *and* called it again when reporting, so one failure printed
  several nested stack dumps. A single error was writing a few kilobytes of
  traceback.
- **The failure that triggered it:** `menu.build` still called
  `pc:GetViewportSize()` (two OUT parameters) — the 2.0.2 fix was applied to
  `main.lua` only. It raised on every menu open at the title screen. The menu
  now takes the size from `main.lua`'s `UWidgetLayoutLibrary` reader.
- **Edit-mode arrows never worked.** UE4SS names the arrow keys `LEFT_ARROW`,
  `RIGHT_ARROW`, `UP_ARROW`, `DOWN_ARROW`; 2.0.2 used `LEFT`/`RIGHT`/`UP`/`DOWN`,
  which do not exist, so all four binds failed at startup. The log said so on
  every launch — worth reading when something seems inert.

**Fixed in 2.0.2:**

- the minimap drew on top of the game's own menus. It now hides whenever the
  game shows a full-screen UI (detected from the mouse cursor being enabled),
  while staying visible for our own F5 window so changes preview live;
- the F5 menu opened without a usable mouse. Setting the cursor once was not
  enough — Palworld drives its own input state during gameplay and put it
  straight back. The input mode and cursor are now re-asserted on every poll
  tick for as long as the window is open;
- **F2 and F4 appeared to do nothing, and it was one root cause.** Negative
  (edge-relative) coordinates need the viewport size, which was read through
  `APlayerController::GetViewportSize` — two OUT parameters, which does not
  survive reflection reliably. With no size, both axes fell through to the
  `x=40` fallback and all four corner presets collapsed onto the top-left.
  The size now comes from `UWidgetLayoutLibrary::GetViewportSize` (a single
  `FVector2D`), is cached, and `applyLayout` is never called without it;
- edit mode had no visual feedback; it now tints the window while active;
- corner margins are size-independent: a negative coordinate is a margin from
  the edge, so presets survive a size or resolution change;
- update rate and rescan interval are now live. Both loops tick fast and gate
  internally, because `LoopAsync` fixes its interval at registration — before
  this, changing them in the menu did nothing until a restart.

**On "minimap quality":** 1.x had that slider, but what it changed was the
scene capture's render-target resolution, and 2.x has no scene capture — the
terrain is the game's own map texture drawn as one quad, so there is no
resolution to trade away. The real performance knobs are in the new
**Performance** section: update rate, rescan interval and icon budget. Saying
so plainly seemed better than shipping a slider that does nothing.

**Verified without the game:** all eight modules load, 13 keybinds + 4 loops +
1 world hook register, every loop tick and key callback runs without raising,
the menu opens and polls, species parsing returns `Anubis` and
`FlameBuffalo_Ice`, the transform maps corners to corners, and the four corner
presets now resolve to four distinct screen positions both with and without a
viewport size.

**Still needs a real session:**

- whether every scanned class returns objects on a live world. The first scan
  logs one line per class with a count, or says it found nothing.
- the circular shape. A true alpha mask needs a material, which Lua cannot
  author, so the round look is the game's own circular overlay plus a radius
  test on the icons. If the art does not suit, the honest options are shipping
  a mask material or leaving the minimap square.
- whether hiding on `bShowMouseCursor` catches every game UI. It covers the
  Esc menu, inventory and the big map; if some screen does not enable the
  cursor, the minimap would stay visible over it.
