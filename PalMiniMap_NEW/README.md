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
| `F3` | show / hide |
| `F2` | cycle corner |
| `+` / `-` | zoom |

Settings live in `minimap_settings.json` next to the mod folder. It is plain
JSON owned by this mod — nothing else reads it, so there is no half-written-file
race like the 1.x `Paldar.modconfig.json` had. Writes are atomic anyway.

## Status — read this before shipping

Verified without the game running: all modules load, 6 keybinds + 3 loops + 1
world hook register, every loop tick runs without raising, the widget builds, and
the coordinate transform maps corners to corners and centre to centre.

**Not yet verified in game**, because that needs a running session:

- **Map orientation.** Which world axis runs which way on `T_WorldMap` is a
  convention the data table does not state. The default (`swapXY` on, `flipV` on
  — north up, east right) is the usual UE layout, and any of the eight
  orientations is reachable from the `axis` block in the settings file. If the
  map is mirrored or rotated on first run, that is the knob — no code change.
- **Scan class names.** `PalCharacter`, `PalPlayerCharacter` and `PalMapObject`
  come from the game's type mapping, but the engine may spawn blueprint
  subclasses instead. The first scan logs exactly what it matched (or that it
  matched nothing), so `UE4SS.log` says what to fix.
- **Per-species pal icons.** Currently every pal draws one generic marker. The
  mapping to `/Game/Pal/Texture/PalIcon/Normal/T_<Tribe>_icon_normal` is known
  and is the obvious next step; it needs the tribe name read off the character.
- **POI categories.** Chests, fast travel points, dungeons and camps are all
  found through `PalMapObject` and currently share one marker. Splitting them
  needs the per-object type read, which is the same follow-up.
