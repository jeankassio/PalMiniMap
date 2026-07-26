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
| update rate | per frame | 10 Hz movement, 0.25 Hz scan |
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
