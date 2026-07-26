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
| Minimap shape (circle/square) | yes — `circular`, real clipped geometry since 2.0.7 |
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
| Minimap render resolution | **gone** — configured the scene capture; the nearest equivalent is the new *Terrain quality*, which controls mip residency instead |
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

**Fixed in 2.0.8 — no pals on the minimap, and hiding behind the Esc menu:**

- **No pal icons at all, even with "Show pals" on — a 2.0.6 regression.**
  `FindAllOf` matches a class *and everything derived from it*, so
  `FindAllOf("PalCharacter")` also returns the local player, other players and
  NPCs. 2.0.6 subtracted the `PalPlayerCharacter` and `PalNPC` scans from it to
  stop drawing those as pals. That is only correct if those classes are a strict
  **subset** of `PalCharacter` — and on this game build `PalNPC` is not: wild
  pals derive from it too, so the subtraction removed **every pal**.
  Rather than hard-code a class hierarchy that a game update can change, a class
  is now only trusted as an exclusion set if it comes back holding a small part
  of the pal list. One that holds most of it is a superclass, so it is neither
  subtracted from the pals nor drawn as its own marker kind (drawing it would
  duplicate every pal under a generic icon). It says so in the log, once:
  `'PalNPC' matched 202 of 203 PalCharacters - on this build it is a superclass
  of pals, not a separate kind of actor, so it is ignored`.
  A one-line scan summary is logged too, so "no pals nearby" can be told apart
  from "the filter ate them" without guessing.
- **The minimap now really hides behind the Esc menu.** Two earlier attempts at
  this went wrong: 2.0.2 inferred it from `pc.bShowMouseCursor`, which Palworld
  leaves ON during ordinary gameplay (so the minimap was hidden permanently), and
  2.0.4 replaced that with "is `WBP_InGameMainMenu_C` in the viewport" — but that
  class name was a **guess**, and it does not fire. The primary signal is now
  `UGameplayStatics::IsGamePaused`, which is not a guess about asset names at all:
  opening the Esc menu (and the map and inventory screens) pauses a solo game, and
  the call is one cached reflection hop. The widget test is kept as a second
  opinion for co-op, where the game does not pause, and it is searched for on
  every maintenance tick while it has never been found — a 2.0.6 back-off of 10 s
  could miss a widget that only exists while the menu is open.
- **A diagnostic instead of another guess:** F5 → *Troubleshooting* → "Log game UI
  widget names" lists the widget classes currently in the viewport on every
  maintenance tick. Turn it on, open the Esc menu once, and the log says what that
  screen is actually called — which is how the widget fallback gets a real class
  name rather than a third guess. Off by default; it walks the whole object array.

**New in 2.0.7 — a genuinely circular minimap and a terrain quality control:**

- **"Circular shape" now changes the SHAPE.** 2.0.5/2.0.6 drew a round decal on
  top of a square map: the terrain stayed square and the corners still showed.
  Making it really round is harder than it sounds — Slate clips to axis-aligned
  **rectangles**, a real alpha mask needs a material (which cannot be authored
  from Lua), and covering the corners with an opaque colour is not an option
  because outside the circle you must see the *game*, not a black box.
  So the disc is built from horizontal strips: each strip is its own
  `ClipToBounds` canvas, exactly as wide as the circle is at that height, holding
  its own copy of the map quad shifted to line up with its neighbours. The union
  of the strips **is** the disc, and everything outside it was never drawn.
  The strips are spaced by **angle**, not height, so they bunch up where the
  outline actually turns: 31 strips on a 240 px minimap, worst-case radial error
  2.99 px (1.2 %), verified numerically. The game's circular art is still drawn
  on top, but as decoration over the seam rather than as the shape itself.
  Per frame this costs one `SetPosition` per strip; the GPU still only rasterises
  the pixels inside the disc. The shape is baked in at build time, so toggling it
  rebuilds the widget.
- **Terrain quality (F5 → "Terrain quality", 0–3).** The terrain looked soft for
  a concrete reason: the map is the game's own `T_WorldMap` magnified several
  times, and a magnified texture can only be as sharp as the mip that happens to
  be **resident**. Palworld streams its UI textures and nothing asks for the world
  map at full resolution until you open the map screen — so the minimap was
  drawing a low mip. Forcing the mips resident is the whole fix. The setting
  grades it because keeping every pal portrait at full resolution does cost VRAM:
  0 leaves the streamer alone, 1 pins the world map, 2 pins the icons too
  (default), 3 adds trilinear filtering and drops the streaming mip bias.
- **A diagnostic line for whatever quality is left.** On the first draw the log
  reports the terrain texture's real dimensions and how far it is being stretched
  (e.g. `terrain texture 4096x4096; 240 px of minimap shows 62 texels (3.9x
  magnification)`). If it still looks soft after the mips are pinned, the source
  simply is not detailed enough — and the answer is the new `terrainTexture`
  setting pointing at a better asset, not another slider.
- **The minimap no longer goes blank for ten seconds after every load screen or
  fast travel.** The teleport guard only has to keep the mod away from *other*
  actors; the terrain and the player marker are the player's own pawn plus
  arithmetic. It now keeps drawing the map through the quiet window and simply
  shows no markers.
- **Co-op: the minimap could follow the wrong player.** On a host, the object
  array holds a `PlayerController` per connected player and the first one found
  was used. It now prefers `IsLocalPlayerController()`.
- **A safer title-screen guard.** Whether the menu may touch input mode was
  decided from a blocklist of guessed world names; getting that wrong is what
  crashed 2.0.2. It now also requires a player pawn to exist, which the splash,
  login and title flows have none of.
- **Points of interest could be missing right in front of you.** The static scan
  kept everything within the visible radius of the position it ran at, but the
  player may travel 15 000 units before the next one — so a chest just off the
  edge at scan time stayed missing even close up. The static scan now keeps that
  much margin beyond the view, from the same constant as the move trigger.
- **`+`/`-` zoom is multiplicative.** A flat 2 000 units per press took
  **fifty-eight** presses to cross the 4 000–120 000 range, and the same press
  that barely moved the view when zoomed out halved it when zoomed in. A constant
  1.25× ratio feels identical at every level and crosses the range in about
  fifteen. (`zoomStep` is replaced by `zoomFactor`; an old value in a saved
  settings file is ignored, not misread.)
- Smaller ones: a texture that loaded once can be reloaded after a world change
  (the retry counter used to keep counting up towards its permanent give-up
  limit); `effectiveZoom` cannot divide by zero from a hand-edited settings file;
  the "circular" rebuild check records what was *asked* for, so a failed strip
  build cannot make the widget rebuild itself forever.

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
