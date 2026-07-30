# PalMiniMap 2.3 — native minimap for Palworld

A complete rewrite. No blueprint, **no `.pak`** — the whole mod is UE4SS Lua
driving UMG. Since **2.3.0** the terrain is a **second, throttled render of the
world from above** ([why](#the-terrain-is-rendered-again-230)), with the game's
own world map texture kept for the zoomed-right-out view. Since 2.2.0 the icons
are shipped as loose PNG in `icons/`, and since 2.2.1 that set is **restyled
art** (rounded, one consistent look) rather than a copy of the game's — so the
files always win over whatever the game has in memory. See
[Why the icons are files](#why-the-icons-are-files-220).

> **`icons/` is authored work.** `tools/extract_icons.py` refuses to overwrite
> an existing PNG; it only fills gaps. `--force` regenerates everything from
> the `.pak` and **destroys the styling**.

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

Version 2 has neither mechanism. **2.3 brings the scene capture back, and only
the scene capture** — throttled to a few renders a second, stopped entirely
while the minimap is hidden, and never every frame. The icons stay pooled UMG
widgets; nothing is attached to a world actor.

## How it works

| concern | 1.x | 2.3 |
|---|---|---|
| terrain | scene capture, **every frame**, always on | scene capture, **≤4/s**, only while visible — plus `T_WorldMap` when zoomed out |
| icons | `StaticMeshComponent` attached to actors | pooled UMG `Image` widgets |
| icon lifetime | created/destroyed constantly | fixed pool, allocated once, reused |
| update rate | per frame | 10 Hz movement, 0.25 Hz pal scan, 15 s static scan |
| assets shipped | a `.pak` | 455 loose PNG icons (3.1 MB), no cooked content |
| icon loading | `LoadAsset` per species | `ImportFileAsTexture2D` from `icons/` |
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

### The menu follows the game's language (2.3.3)

The `F5` menu is drawn in whatever language Palworld itself is set to. **Every
culture the game ships is covered** — the list is not a guess, it is the set of
folders under `Pal/Content/Localization/` in the shipping pak:

```
de  en  es  es-MX  fr  id  it  ja  ko  pl  pt-BR  ru  th  tr  vi  zh-Hans  zh-Hant
```

English is the base and needs no table; `es-MX` shares `es`; anything else the
engine reports falls back to English. That is 15 tables of 55 strings.

The language is **asked, not guessed**: Palworld drives UE's own localisation
system (every string is an `FText`, and `SetCurrentCulture` is in the shipping
exe), so `KismetInternationalizationLibrary.GetCurrentLanguage()` on the CDO is
the answer, with `GetCurrentCulture` / `GetCurrentLocale` behind it and the
winner logged once. All four names were confirmed present in the exe before any
of it was written. The game's *own* `EPalLanguageType` was the obvious first
idea and is a dead end: nothing reachable exposes its live value, its option
lives in a save object rather than a config file, and `GameUserSettings.ini` on
this build has no `[Internationalization] Culture=` line to read either.

Matching is **exact first, then alias, then base language** — doing the base
first would collapse `zh-Hant` into `zh-Hans`, which is a different script.

The lookup key is **the English string itself**, so `menu.lua`'s `LAYOUT` is
untouched and anything with no translation falls back to English instead of
showing a blank row — a new option is at worst untranslated, never broken.
`config.menuLanguage` forces one (`"ja"`, `"en"`) if the detection is ever
wrong; it has no menu row on purpose.

**`string.upper` is not usable here and that is a real bug it caused.** Section
headers are uppercased, and Lua's `string.upper` is C's `toupper` per byte —
locale dependent above 0x7F. On the harness's Lua it **mangled Japanese into
invalid UTF-8**. `i18n.upper` therefore uppercases ASCII by explicit `[a-z]`
byte range and adds two gsubs for the only cased scripts in these tables
(Latin-1 and Cyrillic); Japanese, Korean, Chinese and Thai have no case and
fall through untouched, which is correct. `i18ntest.py` compares *inside Lua*
and returns a boolean, because handing mangled UTF-8 to Python raises and would
crash the control instead of reporting it.

Proper nouns are best effort. Palworld's own wording for a Lucky Pal or a
Lifmunk Effigy lives in its `.locres` files, which this mod cannot cheaply
read, so those few words are translated rather than quoted — they sit in one
table each and are safe to correct.

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
| Autohide while in base camps | yes — `autohideInBase`, from the game's own base check (2.2.4) |
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
| Minimap render resolution | **back in 2.3** — *Terrain quality* is the render target's resolution again (256 / 384 / 512 / 768 px), and still chooses the map texture's mip when that source is in use |
| Minimap capture LOD bias | **gone** — the capture is orthographic and small, so there is nothing to bias |
| Edit mode "new size method" | **gone** — `+`/`-` always resize in edit mode |

Two rows are new: **map orientation** (the escape hatch described below)
and a single **rescan interval** replacing 1.x's five separate ones.

## The terrain is rendered again (2.3.0)

**The problem.** Up to 2.2.20 the terrain was the game's own
`/Game/Pal/Texture/UI/Map/T_WorldMap` drawn as one quad. That texture is a
painting of the main island and nothing else, so:

* **the great tree at the edge of the world** and everything out past the mapped
  bounds had no terrain at all;
* **every dungeon** showed a piece of coastline the player was nowhere near —
  `worldmap.regionFor()` fell back to the main island rather than admit the
  point was off the map.

No coordinate work fixes that. The information is not in the image.

**What replaced it.** `capture.lua` puts a `USceneCaptureComponent2D` on the
player's pawn, pointing straight down through an **orthographic** projection
into a render target, and the minimap draws that. It works wherever the player
can stand, because it is a picture of what is actually there.

### This is the thing 2.0 was written to remove — here is what is different

| | 1.x | 2.3 |
|---|---|---|
| `bCaptureEveryFrame` | **true** (60+ renders/s, forever) | **false**, `CaptureScene()` called by hand |
| minimap hidden | still rendering | nothing captured at all |
| standing still | still rendering | one refresh every 4 s |
| running | still rendering | when the view has slid 4 % of the captured width, at most every `captureIntervalMs` |
| target size | whatever the slider said | 256–768 px square, from *Terrain quality* |
| icons | `StaticMeshComponent` attached to actors | unchanged from 2.x: pooled UMG images |

Ten seconds of running costs about six renders. 1.x would have spent six hundred.

### Three settings, and what they actually do

| setting | meaning |
|---|---|
| **Live render** (`liveTerrain`) | ticked (default) — the terrain is a second, throttled render of the world from above. Unticked — the game's own world map texture, i.e. 2.2 behaviour |
| **Live render style** (`captureStyle`) | `0` lit — `SCS_SceneColorSceneDepth`, the world as it is lit right now, and **the only capture source that comes back opaque**. `1` flat — asks for `SCS_BaseColor` (no lighting at all) and falls back to `0` on any build that renders it at alpha 0, which is stock Palworld |
| **Camera height** (`captureHeight`) | how far above the player the camera sits, default 1500 uu |

**The one thing the checkbox does not override, and it is not a hedge:** the
live render can only show what the game has **streamed in**. Megazoom is 260 000
world units across — more than two kilometres — and most of that is not loaded,
so the capture comes back empty where the painted map shows the whole island. So
above `liveZoomMax` (60 000) the terrain falls back to the texture even with the
box ticked; raise that setting to `megazoom` if you would rather always have the
live render. The exception to the exception: wherever
`worldmap.regionContaining()` says the painted map has no coverage at all, the
live render is used **regardless of zoom**, because a mostly-empty capture still
beats a picture of the wrong place. That last clause is the dungeon case.

### Why the camera is low, and why dungeons work

An orthographic camera does not render what is behind it, so a cave roof or a
building's ceiling above `captureHeight` is simply **not in the picture**, and
the floor the player is standing on is. Orthographic also means the height does
not change the scale — only what gets clipped — so a low camera costs no detail.

### Orientation is not a guess

A capture rotated `(Pitch = -90, Yaw = 0, Roll = 0)` has screen-right = world
**+Y** and screen-up = world **+X**. That is exactly the convention
`worldmap.lua` confirmed in game for the map texture (`toUV` takes u from world
Y and v from -world X), so the live image drops into the coordinate frame the
icons already use. 2.3 went further and put **both** sources and every icon on
one number — `k = size / zoom`, screen pixels per world unit — which is the same
arithmetic the UV path was doing and is correct in a dungeon, where there is no
region to normalise against.

### What could not be carried over from 1.x

1.x's capture component had a baked `ShowFlagSettings` array turning off 32
things (`Lighting`, `Fog`, `DynamicShadows`, `InstancedFoliage`, …) — that is how
it got a flat, daylight map. Show flags are applied by `UpdateShowFlags()`,
which only runs at load/edit time, and the live `FEngineShowFlags` is not a
`UPROPERTY`: **from Lua there is no way to touch them at all.**

`CaptureSource` *is* a `UPROPERTY`, and `SCS_BaseColor` reaches the same place by
a different road — it resolves the GBuffer's base colour, so there is no
lighting, no shadow, no fog and no night in the image. That is `captureStyle` 0.

### The capture worked perfectly and the minimap was blank (2.3.1)

2.3.0 shipped with `CaptureSource = SCS_BaseColor`. In game the component was
created, the target was filled, `verify()` read real colours out of it and the
log said **`live terrain capture confirmed`** — and there was no terrain on the
minimap at all.

Because the scene-capture pixel shader writes

```
SOURCE_MODE_BASE_COLOR  ->  float4(GBuffer.BaseColor, 0)
                                                     ^^^
```

**Alpha zero.** Slate multiplies a brush by its texture's alpha, and UMG
materials cannot be authored from Lua, so a perfectly good picture at alpha 0 is
an invisible minimap. `SCS_SceneColorHDR` is the one mode that deliberately
writes an opacity — `float4(SceneColor.rgb, 1 - SceneColor.a)`, which is 1 over
anything opaque — and it is what 1.x used.

The lesson is the one this mod keeps relearning, one level deeper than last
time: **a call that returned without an error is not proof it did anything
usable, and "there is colour in it" is not proof it can be drawn.** 2.3.0's
verify checked the colours and never looked at the alpha, so it confirmed an
invisible image as working.

**What 2.3.1 does instead.** Each style is an *ordered chain* of sources, and
`verify()` measures **colour and alpha**:

| style | chain |
|---|---|
| `0` flat | `SCS_BaseColor` → `SCS_SceneColorHDR` → `SCS_FinalColorLDR` |
| `1` lit | `SCS_FinalColorLDR` → `SCS_SceneColorHDR` → `SCS_BaseColor` |

| readback | verdict |
|---|---|
| no colour | nothing rendered — retried once (a loading screen is black too), then the next source |
| no alpha | rendered, but nothing Slate will draw — straight to the next source |
| both | latched, and logged **with the pixel it was judged on** |

Format follows the source, not the style, so stepping the chain rebuilds the
render target too: `BaseColor` and `SceneColorHDR` are linear → `RTF_RGBA8_SRGB`;
`FinalColorLDR` is already tonemapped → `RTF_RGBA8`.

Chain exhausted ⇒ the mod says so and falls back to the map texture. The readback
stalls the render thread, so it runs a handful of times at the start of a session
and never on a schedule.

> **Expect `flat` to land on scene colour in practice.** Stock UE5 hard-codes
> alpha 0 for `SCS_BaseColor`, so the unlit look is not reachable from Lua at
> all — the chain is what keeps that from being a blank minimap instead of a
> lit one. The option stays because a future engine or a different source may
> make it work.

### And the other half of the same diagnosis

A brush that was **never applied** looks exactly like a render target that
renders nothing. `SetBrushFromTexture` is typed (`UTexture2D*`) and rejects a
render target, so the live terrain must go through `SetBrushResourceObject`; if
that were refused too, 2.3.0 had no way to say so. `render.lua` now logs which
setter took, once, and if neither will take the target it says so and stops
asking for the live source for the session.

Everything else is logged once too: which `CreateRenderTarget2D` call shape the
build accepted, which route created the component, which call positions it, and
`capture.status()` after 40 captures — average and worst-case milliseconds. That
line is the only way to know whether the second render is affordable on a given
machine.

### Reachability, checked before it was written

Everything this needs was confirmed present in `Palworld-Win64-Shipping.exe` and
in `Palworld.usmap` before a line of it existed: `AddComponentByClass`,
`CaptureScene`, `CreateRenderTarget2D`, `ReadRenderTargetPixel`,
`SetBrushResourceObject`, `K2_SetWorldLocationAndRotation`, and every property on
`SceneCaptureComponent2D` / `SceneCaptureComponent` / `TextureRenderTarget2D`.
`RegisterComponent` is **not** in the exe — it is not a `UFUNCTION` — which is
why `AddComponentByClass` is the creation route: it is the only call that both
constructs and registers.

`SetBrushFromTexture` takes a `UTexture2D` and a render target is not one, so the
live terrain goes on the brush through `SetBrushResourceObject`. The test
harness's fake `SetBrushFromTexture` raises on a render target for exactly this
reason.

### Harness

`scratchpad/capturetest.py` — 39 assertions over `capture.lua` and `render.lua`'s
geometry, with a stubbed clock. The load-bearing pair is
**`mapModeQuadUnchanged` / `mapModeIconUnchanged`**: they recompute 2.2's UV
arithmetic longhand and require the refactored code to put the quad and the icon
in the same place to a hundredth of a pixel. Three controls, each breaking a
named assertion:

| control | what it reverts | fails |
|---|---|---|
| `nothrottle` | capture every tick, i.e. 1.x | `idleThrottled`, `movingThrottled` |
| `noverify` | accept a blank render target | `blankCaught`, `blankLogged`, `stoppedAfterBlank` |
| `noplace` | never position the camera | `cameraHeight`, `cameraLooksDown` |
| `noalpha` | **2.3.0 exactly** — judge the colours, ignore the alpha | `alphaRejectionLogged`, `flatEndsOnSceneColour` |

The fake `ReadRenderTargetPixel` models the real pixel shader — alpha 0 for
`SCS_BaseColor`, 255 for the others — which is what makes `noalpha` reproduce
the reported bug rather than merely fail a check.

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
maps straight onto `/Game/Pal/Texture/PalIcon/Normal/T_<Tribe>_icon_normal`.

**Human NPCs do not follow that convention.** The pairing lives in the game's
own `DT_PalCharacterIconDataTable`, which `tools/extract_icons.py` decodes into
`Scripts/npcicons.lua`. Guessing from names would get several wrong, silently,
in a way that only ever looks like the wrong face on the map.

**2.2.12 fixes two mistakes in the 2.2.2 version of that**, both of which
showed up as *"the merchant is just an arrow"*:

1. **The generated table was filtered to `/PalIcon/NPC/`**, which kept 34 rows
   — only the named "BOSS" humans. A merchant's, villager's or guard's portrait
   is not in that folder; it sits in `PalIcon/Normal` beside the Pals:

   | CharacterID | portrait |
   |---|---|
   | `Male_Trader01` | `T_PalDealer_icon_normal` |
   | `Male_Trader02` | `T_SalesPerson_Green_icon_normal` |
   | `VisitingMerchant` | `T_Female_MobuCitizen_icon_normal` |
   | `Guard_Rifle` | `T_Police_icon_normal` |
   | `BOSS_Hunter_Rifle` | `PalIcon/NPC/T_BOSS_NPC_Hunter` |

   The folder says nothing about human-versus-Pal, so filtering on it was
   simply wrong. All 674 rows are generated now, with the full path, because
   the folder varies per row.

2. **It was keyed by the actor's name.** That works for Pals, whose actor is
   `BP_<CharacterID>_C_<n>`, and can *never* work for humans: the same
   blueprint, `BP_NPC_HumanNormal`, is spawned as a merchant, a villager or a
   guard, so the actor name cannot possibly say which. The lookup now reads the
   game's own **`CharacterID`** at scan time, trying four routes and logging
   which one answered. The first is `GetCharacterParameterComponent()
   .IndividualParameter:GetCharacterID()` — deliberately, because those are the
   same two hops the shiny test already makes on every pal, so it is known safe
   on this build rather than hoped to be.

If no route answers, it falls back to the actor name, which is right for Pals
and wrong for most humans — still better than every human being an arrow.

That lookup is deliberately kept **apart from `speciesIcon`**, which is what
decides pal-versus-human in the first place (a tribe whose species icon exists
*is* a pal). Teaching it about human portraits would make every human answer
"yes, I am a pal" — the 2.0.8 regression, humans eating the pal budget. The
table is consulted only for actors already classified as human, and anyone not
in it keeps the generic marker.

Humans also get an icon budget of their own, `maxNpcIcons` (default 24). Both
alternatives were tried first and are worse: letting them take `maxPalIcons`
too overflows the icon pool, so the draw loop drops whatever was emitted last
— always the NPCs, silently; and *sharing* `maxPalIcons` means anywhere with
48 pals in range shows no people at all, since pals are collected first.
`poolCapacity` sums the budgets, and `needsRebuild` compares that sum, so a
new budget key becomes a rebuild key for free.

**And that sum was missing a term until 2.3.3.** Other players were the one
list with no budget at all, and `poolCapacity` did not count them — while
`collect()` emits them *after* statics and pals but *before* humans. So on a
populated server every extra player pushed an NPC off the end of the pool, by
exactly the mechanism described above, without a word in the log. It survived
this long because in singleplayer the list is always **empty**: the local
player is excluded by name, so there is nothing in it to overflow with. Now
`maxPlayerIcons` (default 16) bounds it and is counted in the pool. The
exclusion bookkeeping stays outside the budget — it is what stops a player
being counted as a pal, and must not depend on whether an icon was spare.

## Friends showed up as human NPCs on a server (2.3.3)

Reported against 2.1.2 on multiplayer: *"with 'show NPC humans' on, my friends
at the base appear as human NPC icons if I have 'show other players' off — and
it seems only some of them are."*

Pal-versus-human is decided by **whether the tribe has a species icon** (2.1.0).
A player's actor name gives a tribe like `PlayerBase`, which of course has no
`T_PlayerBase_icon_normal`, so **any player that is not in the `excluded` set is
classified as a human and drawn as one.** Everything therefore rested on that
one set — built by NAME, from a separate `FindAllOf` — and it silently yields no
exclusions at all if the name read fails, if the player list comes back empty,
or if `usableForExclusion` decides the class looks like a superclass of pals.
"Only some" is the `maxNpcIcons` budget downstream: it is filled nearest-first,
so the closest friends got icons and the rest were dropped entirely.

The fix is **a second, independent test on a different property — the actor's
CLASS.** Class names are *learned*, not hard-coded, because they are blueprints
(`BP_PlayerBase_C`, `BP_Player_Female_C`) that live in the pak rather than the
exe; and the first source of them cannot fail, because the **local player's own
pawn is a player character** and we always have it. Cost is kept off the hot
path: the class is only read for an actor that has already failed the species
test (few) or during the brief window before any icon has resolved, never for
every pal in range.

## Every pal variant wears its own species portrait (2.3.3)

Counted against the shipping pak: **457 Pal blueprints have no
`T_<tribe>_icon_normal` of their own, and 431 of them have a base species that
does.** 2.1.4 fell back to the base species for a `_BOSS` suffix only —
deliberately, since dropping *any* trailing segment would send every human tribe
chasing assets that never existed (`NPC_Villager` → `NPC`). That reached 286 of
the 457. The other **145** — every `_Predator`, `_Normal`, `_Skin001`, `_GYM`,
`_Oilrig`, `_RAID`, `_Quest` and elemental re-skin — failed the species test,
and failing it is exactly what marks an actor as human. They were drawn with the
NPC marker.

2.3.3 keeps 2.1.4's guarantee with a **whitelist of variant suffixes derived by
walking the pak index**, stripped repeatedly (`AmaterasuWolf_Dark_BOSS` needs two
passes). Three things were measured rather than assumed:

- stripping to the **full** base and stopping at the first **intermediate** that
  has an icon resolve identically (430 each), and there is not one case where the
  intermediate wins — so the simpler rule is the correct one;
- of the **674** human CharacterIDs in `npcicons.lua` and the **249** NPC
  blueprints in the pak, **zero** become pals under the new rule, which is the
  2.0.8 regression this whitelist exists to avoid;
- the exact tribe is still probed **first**, because some variants genuinely do
  have their own row (`FlameBuffalo_Ice`) and must keep their own picture.

Twenty-six variants remain unreachable because no base portrait exists anywhere
— `ElecLion` and `DarkMutant` among them, whose rows in the game's own icon data
table point at textures that are not in the pak at all. Nothing can be drawn for
those but the generic marker.

## Hiding behind the game's own screens (2.2.11)

Seven attempts. This is the first one built on **measurement** instead of on
reasoning about the game. `Scripts/uiprobe.lua` is a diagnostic inside the mod
(enabled by `logGameUiWidgets`) that logs every candidate signal whenever any
of them changes. One session with a chest, the Tab inventory and the Esc menu
produced this:

| | at rest / walking | screen open |
|---|---|---|
| `PalHUDInGame.StackableUIWidgets` | **1** | 2 (Esc later 3) |
| CommonUI containers | `Layer_0[1] Layer_1[1]` | `+ Layer_2[1]` |
| `IsGamePaused` | false | **false** — Palworld does not pause |
| `IsInViewport` on every widget | false | **false** |
| `bShowMouseCursor` | flips | flips |

**The resting stack is 1, not 0.** Versions 2.2.7 and 2.2.8 read the right
array and then tested `count > 0` — true with nothing open. The signal
therefore never once read "closed", the safety rule correctly refused to trust
it, and the minimap never hid. The array was never the bug; the assumption
that an idle stack is empty was.

Nothing hard-codes 1 either — it could be 2 on the next patch. The baseline is
**learned**, from the one moment it is certain that nothing is open:

> **A screen cannot be open while the character is running.**

While the player is moving, whatever the stack reads *is* the baseline (adopted
after two consecutive identical readings, so one odd frame can't set it).
Standing still, anything above the baseline is a screen. Movement is measured
from **position**, not `GetVelocity()` — 2.2.7 used velocity and on this build
that call fails, leaving it 0.0 forever so nothing depending on it could fire.

This also makes the whole thing self-healing: a baseline learned wrong is
corrected by walking a few metres, instead of the mod being stuck for the rest
of the session. And until it has been calibrated, it never hides — three of the
seven attempts blacked the minimap out for a whole session, which looks like a
broken mod and is far worse than drawing over a menu.

The count is read through every TArray shape UE4SS might return
(`GetArrayNum`, `#`, `ForEach`); 2.2.7 tried only the first, failed, and
silently fell through to widget-guessing.

### Dead ends, confirmed by the probe rather than argued

- `pc.bShowMouseCursor` — on during ordinary gameplay (2.0.2 hid the minimap
  permanently).
- `IsGamePaused` — **false with the Esc menu open**.
- `IsMoveInputIgnored` — false throughout.
- `IsInViewport()` — false for every widget even with a screen up; Palworld
  builds its screens as *children* of its UI layout.
- `UWidget::IsVisible()` on the modal base classes — reads a widget's own flag
  and ignores its parent layer being collapsed (2.2.6 hid the minimap
  permanently).
- Naming screens one at a time — there are 112, and `WBP_InGameMainMenu_C` is
  the *inventory*; the Esc menu is `WBP_MenuESC_C`.

> The diagnostic itself once crashed the game: it read `DisplayedWidget` and
> called `GetClass():GetFName():ToString()` on it, three dereferences deep into
> a widget still being built behind a loading screen. No Lua error — the log
> just stops, because a native access violation is not something `pcall` can
> catch. **The 2.1.7 rule applies to debug code too:** touch only what came
> back from `FindAllOf`, and gate anything that walks the object array on a
> settled world.

## Eggs looked like a note/effigy (2.2.16)

The compass icon table had `egg`, `note`, `effigy` and `fruit` all pointing at
the same generic texture, `T_icon_compass_ClearCheck` (a plain checkmark),
distinguished only by tint. The base game never marks eggs on its own
compass at all, so there was no dedicated compass asset to reach for.

The egg now uses the game's own **item icon** for an unidentified Pal egg -
`T_itemicon_Material_PalEgg_Unknown`, the grey egg-with-a-question-mark that
means "egg" everywhere else in the game (inventory, hatching UI). Real asset,
right picture, and `tools/extract_icons.py` knows how to regenerate it if
`icons/` is ever rebuilt from scratch.

## Every egg draws its own element (2.2.16)

Eggs were drawing `T_icon_compass_ClearCheck` — the same generic checkmark as
notes, effigies and skillfruit trees, differing only by tint. So an egg looked
like a note, and one egg looked like every other egg.

There was a real reason nothing better was reached for: **the game has no
compass icon for an egg at all**, because Palworld's own compass never marks
eggs. The icons that do exist are the *inventory* ones, which is where the game
shows an egg to the player — and there are twelve, one per element:

| | | |
|---|---|---|
| plain | `T_itemicon_Material_PalEgg` | Fire, Water, Leaf, Electricity, Ice |
| Dark, Dragon, Earth | WorldTree, MutationPal | Unknown (grey `?`) |

The element comes from the actor's **class** name. Wild eggs are
`BP_MapObject_PickupItem_PalEgg[_<Element>]_C`, and `_Base` — the one that
actually derives from the native `PalMapObjectPalEgg` the scan looks for — is
the parent of the eleven variants, so a single `FindAllOf` still returns them
all. It reads the class, not the object name: a level-placed actor's object
name is whatever the designer called it.

The mapping is written out explicitly rather than generated by appending
`_01` to the element, because three of the twelve break that rule (plain,
`MutationPal` and `Unknown` have no suffix) and a generated path that is wrong
lands silently on the slow `LoadAsset` fallback instead of raising.

Two supporting changes:

- **`STATIC_KINDS` gained an optional `iconFor`**, a per-*actor* icon for a
  kind whose members do not all look alike. Only eggs have one; every other
  kind keeps its single `ICON[kind]` and pays no extra reflection. The texture
  is carried through the scan cache, the distance sort and the draw list, and
  is *always* assigned — those entry tables are pooled and reused, so leaving
  it alone would let one kind's texture stick to another's entry.
- **Eggs have no tint any more.** The per-element art is already coloured; the
  old cream tint would flatten fire, water and ice back into one beige blob.

The icons are 256×256 in the pak — larger than the character portraits — so
they go through the same downscale-on-extract path (`needs_downscale`), for the
same reason: an imported texture has one mip, and sampling 256 px of art into
an 18 px marker shimmers as the map moves.

## Settings reset to defaults on restart (2.2.20)

Reported on Nexus against 2.2.14: everything changed in the F5 menu works for
the rest of the session and is back to factory defaults after a restart.

The file on disk was **correct all along** — the save wrote `"showChests":
false` exactly as it should. The *read* threw it away:

```lua
local s = (not SESSION_ONLY[k]) and stored and stored[k] or nil
```

In Lua, when `stored[k]` is `false` that whole chain evaluates to `nil`. The
type check on the next line then rejects it and the **default** is used. So
every toggle the player turned OFF came back on at the next launch, while
numbers and toggles turned ON persisted fine — which is why it looked like a
total reset rather than a partial one.

The line is written out longhand now. It is the same Lua trap that had already
bitten `uiprobe.lua`'s `show()` — `cond and value or fallback` is not a ternary
when `value` can legitimately be `false`.

`tools`-free to reproduce: `scratchpad/configtest.py` drives the real round
trip (change → save to a file → drop the module → load again) and carries the
2.2.14 line as a control, which loses five toggles.

### `minimap_settings.json` must never be packaged

Found while investigating: the player's settings file was being shipped inside
all three distribution packages, carrying the author's own layout (size 450,
position 1430,40, zoom 22000). On Nexus that overwrites the user's settings
every time they extract an update; on the Steam Workshop it can be restored on
any re-sync.

It is removed from the packages and `.gitignore`d, so it cannot be added back
by accident. **The already-published archives still contain it** — they need to
be rebuilt before the next upload.

## Looted chests stayed on the map (2.2.19)

`hideCollected` worked for notes and effigies and did nothing for chests.

The cause is that **there is no single "already taken" flag**, which every
version until now assumed. `bPickedInClient` lives on
`PalLevelObjectObtainable` — the base of notes and effigies *only*. It does
not exist on a chest at all, so reading it there simply raised, the answer
was always "not taken", and looted chests never went away.

A chest keeps its state on its **model**, not on the actor:

```
PalMapObjectTreasureBox (actor) -> .MapObjectModel
                                -> PalMapObjectTreasureBoxModel.bOpened
```

Both confirmed in `Palworld.usmap`. Each kind now names its own reader in
`STATIC_KINDS` (`collected = chestOpened` / `= pickedUp`) instead of sharing
one and hoping. Failing to read still means **"not taken"**, never "taken" —
the other way round would empty the minimap of chests on a build where the
model is unreachable, which is the 2.0.6 mistake in a new place.

Not covered, and deliberately not faked: resource nodes, fishing spots and
buried treasure all *respawn*, and `EPalMapObjectSpawnerState` only has
`Init` / `WaitForLoadingAround` / `Active` — nothing that means "harvested".

## Icon audit: every marker means what it shows (2.2.16 – 2.2.18)

Four kinds — egg, note, effigy and skillfruit — all drew
`T_icon_compass_ClearCheck`, one generic checkmark, and were told apart only
by tint. A note and an effigy were literally the same picture in two colours.

| marker | now | where it came from |
|---|---|---|
| egg | 12 icons, one per element | the game's inventory art, picked by actor class |
| effigy | green Lifmunk statue | `T_itemicon_Relic` |
| skillfruit | skill fruit | `T_itemicon_Consume_SkillCard_Neutral` |
| note | a page | **drawn by `tools/make_note_icon.py`** — see below |
| ore / lotus / forage / junk | pickaxe, lotus, apple, scrap | `T_icon_compass_03 / 13 / 09 / Search_Junk` |
| fishing spot | fishing rod | `T_icon_compass_15` |
| buried treasure | shovel | `T_icon_compass_TreasureMap_01` |

Everything else checked out: player, party member, death, chest, fast travel,
tower, dungeon, base camp and enemy camp were already correct.

**Two search mistakes worth recording**, because both hide assets in a way that
looks like "the game doesn't have one":

- **Seventeen compass icons have no descriptive name** — `T_icon_compass_00`
  through `_16`. Searching by name never finds them. `03` is a pickaxe, `09` an
  apple, `10` an egg, `13` a lotus, `15` a fishing rod. They have to be *looked
  at*.
- **The extraction pattern was case-sensitive**, so `T_icon_Compass_Quest_0`
  and `_1` (capital C) were silently never extracted. The pattern is `(?i)` now.

**Notes are the one marker with no game art at all.** Searched every
`T_icon_compass_*`, `T_icon_Compass_Quest_*`, `T_icon_ItemCategory_*` and the
item icons for note/memo/paper/book/journal/map/scroll/blueprint. The two
nearest — the technology book and the treasure map — are different items *and*
illegible at 18 px. So that one glyph is drawn and shipped, like the circular
frame.

**Coloured art rather than white glyphs, on evidence.** Rendered at the real
18 px marker size over grass, snow and desert: the game's white compass glyphs
have a weak outline and *vanish on snow*. The ones that survive (the checkmark,
for instance) have a dark outline — so the generated note glyph has one too.

### Resource nodes share one scan

Ore, stat-fruit lotuses, forageables and junk are all
`PalMapObjectSpawnerSimple` subclasses, so one `FindAllOf` covers all four and
the class name says which is which. Returning `nil` from a kind's `iconFor`
now **declines** the actor — which is how that scan walks the class it must
(to find ore) while dropping the thousands of stone, wood, log and bone
spawners mixed into it.

`showResources`, `showFishing` and `showTreasureMaps` all default to **off**:
`maxPoiIcons` is shared by distance across every kind, so leaving ore and junk
on would push chests, dungeons and fast travel points off the minimap.

## Pals in their sphere still showed on the minimap (2.2.15)

Reported: a pal travelling with the player but still stored in its sphere -
not deployed, not standing in the world - was drawn on the minimap next to
the pals that actually were out. The existing filter (`inWorld()`, added for
exactly "pals sitting in the team should not be drawn") checked `bHidden` and
`PalUtility::IsDead`, and neither one is true for a partner sitting in its
sphere: it is not hidden and it is not dead, it is simply inactive.

The correct flag is **`bIsPalActiveActor`**, a property on `PalCharacter`
confirmed in the game's own exe (`OnRep_IsPalActiveActor`, `SetActiveActor`,
`SetActiveActorStayVisible` - a deliberate, replicated, maintained flag, not a
side effect of something else). False while stored, whether carried in the
active team or sitting in the Pal Box; true once deployed.

Read alongside the existing two checks, in the same "no opinion, never a
guess" style: an unreadable property means the pal is drawn, not hidden -
getting that backwards on a build that does not expose the property is
exactly how 2.0.6 emptied the minimap for everyone on that build.

## The diagnostic must not outlive the diagnosis (2.2.13)

`logGameUiWidgets` turns on `Scripts/uiprobe.lua`, which walks the whole UObject
array once a second and asks every visible widget for its class name. That is
the right cost for the few minutes it takes to find something and is **felt as
stuttering** if it is left running — which is exactly what happened after it was
used to find the Esc/Tab bug: the F5 menu wrote it to `minimap_settings.json`
like any other option and it was still on two versions later.

Three layers, so it cannot happen again:

- **`config.lua` keeps a `SESSION_ONLY` set.** Those keys are never read from
  the settings file and are stripped on save, so a debug switch cannot follow
  the player into the next session. Any future switch that costs frame time
  belongs there.
- **The probe switches itself off after 5 minutes** and logs why.
- **`main.lua` tests the flag at the call site.** Lua evaluates arguments first,
  so `uiprobe.tick(cfg, statics(), playerController(), ...)` was paying two
  `IsValid` calls ten times a second in every normal session even with the probe
  off.

## "Am I in a base camp?" — ask, don't measure (2.2.4)

The `autohideInBase` option hid the minimap on time but brought it back far
too late: you had to walk most of a screen away from the base first.

The cause was that 2.0–2.2.3 answered the question itself, by measuring the
distance to the nearest `PalBuildObjectBaseCampPoint` and comparing it to
`cfg.baseCampRadius`. **That class carries no radius**, so the number was
invented — 12000 uu, a 120 m bubble, several times the size of a real base.

The game already tracks this exactly:

```
PalPlayerCharacter
  .InsideBaseCampCheckComponent      -- PalInsideBaseCampCheckComponent
    .NowInsideBaseCampID             -- Guid, valid only while inside
```

and that is what 1.x read — `ExecuteUbergraph_ModActor` calls `IsValid_Guid`
on that very property to set its `currentlyInABaseCamp`, which is why the 1.x
autohide released the moment you stepped out. The component uses the base's
real bounds, so there is no radius to tune and nothing to get wrong.

`sources.lua` tries, in order: a reflected `IsInsideBaseCamp()` bool if the
build has one, then the Guid, then the old circle — and **logs which route is
live**, once, so a build where the component is unreadable says so instead of
quietly going back to guessing. If the component has ever answered and then
misses a tick (there is no pawn between a death and a respawn), the last
answer is held rather than letting the circle flip the minimap underneath it.

Two things fall out for free: `baseCampRadius` is now fallback-only (and
dropped to 5000, still an estimate — it just no longer matters), and the
`PalBuildObjectBaseCampPoint` walk is no longer forced by the autohide, so
turning the base-camp *marker* off now genuinely removes a `FindAllOf` from
the scan rotation.

## Why the round minimap is round (2.2.3)

Slate clips to axis-aligned **rectangles** only, so the disc is built from N
horizontal clipped strips. That outline is a staircase, and it was visible:
measured, 24 strips on a 240 px minimap wander **±4 px**.

No strip count fixes it. Optimal (equal-ripple) spacing buys 0.1 px, and
sub-pixel accuracy would need ~150 strips — and each strip is its own Slate
clipping zone, so each is one more draw call **every frame**.

So the outline is not made accurate, it is **covered**.
`icons/T_minimap_frame.png` is a shipped image whose inner edge is a real
supersampled circle, with an opaque bezel 3.8% of the diameter wide — wider
than the strips' worst error. It is drawn above the strips and *below* the
icons, so a marker near the rim is not clipped by the bezel. What the player
sees as the outline is that inner edge, which is exact at any size.

Two details are load-bearing. The strip disc is built 1.8% **smaller** than
the widget, because the union of rectangles bulges slightly past the radius it
approximates and beyond the widget radius is the one place the bezel cannot
reach. And `bandCount`'s floor is 24, not 16, because below that the staircase
grows wider than the bezel.

Getting either number wrong is **silent** — it shows as a notch of terrain on
the rim at some sizes and not others — so `tools/check_frame.py` reproduces
`buildBands` and measures the margin at every size the menu allows (120–480).
`--render` draws the result over a checkerboard so it can be looked at.

The frame replaces the game's own `T_prt_map_circle_eff`: two rings on one
edge is muddy, and stretching that 128 px glow across the whole disc was
washing the terrain out. If the PNG is missing the disc simply keeps its old
faceted outline and says so in the log.

## Why the icons are files (2.2.0)

Up to 2.1.9 every portrait was fetched with `LoadAsset`, and no amount of
throttling made the stutter go away. The reason is that the cost is not the
icon: **`LoadAsset` is a synchronous flush of the engine's async loading
queue**, so it waits for whatever the game itself is streaming at that instant
before it even starts on ours. Riding into town the game streams constantly, so
a 128×128 portrait can block the frame for as long as a level chunk takes. No
budget the mod picks can fix that, because the mod is not the one spending the
time.

So the portraits now ship with the mod as PNG and are loaded with
`UKismetRenderingLibrary::ImportFileAsTexture2D` — confirmed present in the
shipping build. That call reads a loose file, decodes it through IImageWrapper
and builds a **transient** texture: one mip, `NeverStream`. It touches no
package, no async loading queue and no streaming manager, so it cannot queue
behind the game's own IO.

`tools/extract_icons.py` pulls the art out of the game's own `.pak` with
`repak`, unwraps mip 0 of the cooked `FTexturePlatformData`, and writes PNG
named after the **asset's object name** — so
`/Game/…/T_Alpaca_icon_normal.T_Alpaca_icon_normal` becomes
`icons/T_Alpaca_icon_normal.png` and nothing else in the mod needs to know the
route exists. Portraits are downscaled to 64 px on the way out, because a
transient texture has no mip chain and the minimap draws them at 10–40 px;
doing the filtering once at extraction is what the mip chain would have done
every frame.

Four things are load-bearing and easy to break:

* **The shipped file always wins (2.2.1).** Up to 2.2.0 the loader tried
  `StaticFindObject` first, because adopting a texture the game already had
  resident is free. That was right while `icons/` held the game's own art and
  wrong the moment it stopped: the compass and marker icons are exactly the
  ones the game itself loads, so those came out in the original square style
  next to restyled portraits. Being free is not worth being wrong. A resident
  copy is now only used for a path we ship no file for, and the 30-second log
  line **names** every texture that fell back — an unstyled icon otherwise
  looks like a perfectly working icon.
* **Anything without a PNG still takes the old road.** The world map texture
  above all — it is enormous and loaded exactly once, so shipping it would cost
  tens of MB and remove no stutter. If `icons/` is missing, or the engine
  refuses an import, the mod falls back to `LoadAsset` and says so in the log.
* **A transient texture belongs to no package.** The only thing keeping it
  alive is the UMG brush it sits on; once the last icon using it moves on,
  Unreal is free to collect it and leave a dead pointer in the cache. Handing
  that to `SetBrushFromTexture` is an access violation with no Lua error to
  catch. `assets.lua` guards it from both sides — it lets go of anything
  nobody has drawn for 20 s (dropping a *live* reference, which is the safe
  half), and validates what survives once per pump before returning it.
* **`icons/` must deploy beside `Scripts/`, not inside it.** `Info.json`'s
  install rule lists `./icons` without a trailing slash, which copies the
  folder itself; `assets.lua` looks for it at `<script dir>/../icons`.

Settings live in `minimap_settings.json` next to the mod folder. It is plain
JSON owned by this mod — nothing else reads it, so there is no half-written-file
race like the 1.x `Paldar.modconfig.json` had. Writes are atomic anyway.

## Status

**2.3.0 ran in game and drew nothing** — see
[the capture worked perfectly and the minimap was blank](#the-capture-worked-perfectly-and-the-minimap-was-blank-231).
The component, the target, the placement and the readback were all confirmed
correct by the log; the image was at alpha 0. **2.3.1 is the fix and is not yet
confirmed in game.** What to check on the next run:

1. `UE4SS.log` should carry
   `live terrain capture confirmed: ... via <source> [rgba r,g,b,a]`. The source
   named there is the one that survived the chain, and the pixel is what it was
   judged on.
2. `live terrain drawn via SetBrushResourceObject` should be there too. If it
   says `SetBrushFromTexture` instead, or that neither would take the target,
   that is the other half of the problem and the log now names it.
3. If terrain appears but looks washed out or crushed, it is the source /
   render-target format pair — see `SOURCES` at the top of `capture.lua`.

**Confirmed in game (2.0.0/2.0.1 runs):** the terrain renders, the world→map
transform is correct, the player marker sits where it should, and the axis
orientation (north up) is right — the constants decoded from `DT_WorldMapUIData`
are good. Since that is settled, **2.1.1 removes the `axis.*` orientation
settings**: any of the eight combinations other than the confirmed one mirrors or
rotates the entire coordinate transform, so terrain, player marker and every icon
disagree with the world at once and the minimap simply looks broken. A setting
whose only non-default values are bugs is not a setting, so the orientation is a
constant now (`worldmap.toUV`). If a game update ever moves the world, the escape
hatch is `calibrate()`, which reads the live bounds out of the game's own
`WBP_Map_Body_C` widget. An older settings file keeps working — `config.merge`
iterates the defaults, so the retired `axis` block is ignored on load and gone
from the file after the next save.

**Fixed in 2.1.9 — the crash on closing the F5 window, and what the same log settled about
the native scan.**

`UE4SS.log` ended one line after `menu closed`, and the dump said

```
EXCEPTION_ACCESS_VIOLATION reading address 0xffffffffffffffff
```

which is what an `INDEX_NONE` / `-1` index looks like used as an address. Opening the menu
calls `SetInputMode_UIOnlyEx(pc, widget)`, which gives Slate a **focus path into that
widget**. Closing it removed the widget from the viewport *first* and handed input back to
the game afterwards — so in between, Slate held a focus path to a widget that had just been
unparented and was on its way to being collected. Walking that path is a native dereference
no `pcall` can see.

The order is now: hand focus back to the **game** while the widget is still alive and still
parented → make the widget non-focusable and collapsed → only then remove it from the
viewport. The same order is used on the build-failure path, and a world change while the
menu is open now releases the input mode too (otherwise the next world starts in UI-only
with a cursor and no window to justify it). A new harness, `menutest.py`, records the
teardown call sequence and asserts the release happens **before** the removal — the kind of
ordering bug that is invisible in a diff.

**And the same log settled the native-scan question.** `PalObjectCollector`'s array
elements arrive **wrapped on this UE4SS build too** — so the property-vs-out-param
distinction 2.1.8 was built on does not hold here; this build wraps object array elements in
general. 2.1.7's rule caught it and refused the route instead of crashing, which is exactly
what it is for. The practical conclusion for this build: **`FindAllOf` is the only source of
durable actor handles**, so the engine object array is doing the character scan. Both native
list routes stay in the code and take over automatically if a future UE4SS or game build
hands back first-class objects — the log says which route is live.

**Added in 2.1.8 — `PalObjectCollector`, the native route that actually works.**

Found by parsing `Palworld.usmap` (the schema dump in `_tools`) rather than by guessing.
The game keeps its own curated, already-classified character lists:

```
PalObjectCollector.PalCharacter_All      Array<Object>
PalObjectCollector.PalCharacter_NPC      Array<Object>
PalObjectCollector.PalCharacter_Player   Array<Object>
```

and *pals = All − NPC − Player*. This is now the primary scan.

**Why this one is safe where `PalUtility` was not** — which is the entire point. These are
**properties**, not out parameters. A property read goes to memory owned by the object and
hands back first-class `UObject`s, so the references may be kept for the four seconds until
the next scan. `PalUtility`'s out-param array lives in the call frame and is already gone by
the time the table reaches Lua; keeping what came out of it is what killed the game in
2.1.5. The rule from the crash is still enforced here rather than assumed — the elements are
checked, and if they ever arrive unusable this route is refused too.

What it gets us, all at once: **no object-array walk for characters**, the classification is
the game's own rather than anything inferred, and party pals stay off the map (the `bHidden`
/ `IsDead` filter still runs on top). The routes are tried in order —
`PalObjectCollector`, then `PalUtility` if its elements are first-class, then the engine
object array — and the log says which one is in use.

**Fixed in 2.1.7 — the crash. 2.1.5 was storing references it had no right to keep.**

The game died with

```
EXCEPTION_ACCESS_VIOLATION reading address 0x0000000400000039
```

— a garbage pointer, from `Palworld_Win64_Shipping` with no Lua error and nothing in
`UE4SS.log`, because a native access violation kills the process before anything can be
written. The cause is one line that had appeared in the log a few seconds earlier:

```
PalUtility: list elements arrive wrapped - unwrapping with :get()
```

2.1.5 found that `GetPalMonsters`' elements were not usable objects directly, opened each
one with `:get()`, and **stored what came out in `S.pals`** — where the draw path
dereferences it ten times a second for the next four seconds. A wrapper handed back by
UE4SS points into the memory of the call that produced it. Reading through one later is
undefined, and no guard in this mod can catch it: `pcall` only sees Lua errors, and
`IsValid()` on a recycled object slot can answer yes.

So there is now a second crash-safety rule beside the one this mod was built on:

> **An actor reference may only be kept if it arrived as a first-class `UObject`. Never
> store the result of unwrapping something.**

If the list elements do not arrive usable, the whole list path is refused and the
object-array scan takes over — slower, and it has never crashed. `PalUtility::IsDead` is
still used, because it takes an actor we already own and hands back a boolean: nothing
crosses back that has to outlive the call. **On this build that means the `PalUtility`
scan is off and the object-array scan is doing the work.** The 2.1.2 walking-stutter fix,
the 2.1.4 alpha-pal fix and the party-pal filter are all unaffected — none of them depend
on it.

The other place 2.1.2 started keeping actor references between ticks — the resumable static
scan — is tightened rather than removed: 48 actors per step instead of 24 (a 480-actor class
clears in one second), and a pass that has not finished within three seconds is abandoned
instead of carried further.

**Changed in 2.1.6 — edit mode (F4) no longer rebuilds anything.**

Dragging the window around and stepping its size is the one moment the player is looking
straight at the minimap and changing it continuously — and it was the one moment the mod
tore the whole widget down and constructed ~180 of them again, once per size step, plus
again whenever a maintenance tick noticed the built size no longer matched. It flickered on
every press.

None of that is needed to *place* a window. The frame, the backdrop and the edit highlight
are all repositioned by `applyLayout`, and the terrain quad is scaled from `cfg.size` on the
next draw regardless. Only two things are genuinely baked in at build time — the circular
strips and the icon pool length — and those can simply wait.

So while F4 is on, **every rebuild request is remembered instead of run**, including the one
`needsRebuild` would otherwise trigger from a maintenance tick, and they all collapse into a
single rebuild when F4 is pressed again. The window still follows the arrows and `+`/`-`
immediately; what stays still is everything else. Harness: 0 rebuilds across a 20-press
resize burst and 60 nudges while F4 is held, exactly 1 on leaving.

**Fixed in 2.1.5 — `PalUtility` engaged, and then drew nothing at all.** The log said:

```
PalUtility: using /Script/Pal.Default__PalUtility, GetPalMonsters(ctx, out)
  -> lua table in the out table, 54 monsters
character scan via PalUtility: 54 pal monsters, 1 human NPCs, 1 players
  -> 0 pals drawn (0 skipped as not present in the world)
```

54 monsters in, nothing out, and nothing rejected by the in-world filter — so they were
lost in between, with no way to tell where. Three changes, in order of how much they
matter:

* **A faster scan that draws nothing is worse than a slow one that works.** The utility
  path is now **self-checking**: when it produces no pals at all while the game said there
  *are* monsters, the old object-array scan runs for that tick and the two are compared. If
  the old path finds pals, the new one loses its turn — and after three such scans it is
  dropped for the session and says so. The minimap cannot end up empty because of it again.
* **List elements can arrive wrapped.** UE4SS hands some values back inside something that
  has to be opened with `:get()`, and a list of wrappers is indistinguishable from a list of
  dead actors — every one fails `IsValid` and is silently dropped, which is exactly "54
  monsters → 0 drawn". The element form is now decided once from the first element, and
  only ever latched on a positive answer, so an actor that merely happened to die does not
  settle it.
* **The log reports the whole funnel, not just the ends**: `of the monsters: N unreadable,
  N unnamed, N out of range, N in range -> N drawn, N not present in the world`.

**Also fixed: the settings file was being written outside the mod.** It turned up in
`Pal/Binaries/minimap_settings.json`, because UE4SS does not always give a Lua chunk a
*path* for a name — `debug.getinfo().source` can be a bare `main.lua` with no directory in
it — and `(SCRIPT_DIR or ".")` then quietly resolved against the game's working directory.
Candidates are now **checked** by opening a file that must sit beside them rather than
trusted, and `package.path` is used as the second candidate because `require("guard")` has
already proven one of its entries points at this folder. An existing file in the old
location is still read once, so nobody loses their layout.

**Fixed in 2.1.4 — alpha pals were being drawn as human NPCs, and the `PalUtility`
call convention, both straight off the in-game log.**

2.1.3's probe did its job. `UE4SS.log` said, exactly:

```
PalUtility: found at /Script/Pal.Default__PalUtility, but GetPalMonsters(ctx) raised:
  UFunction expected 2 parameters, received 1
PalUtility: found at /Script/Pal.Default__PalUtility, GetPalMonsters(ctx, out) returned nil
no species icon for: FoxMage_BOSS, FunnelCharacter_RaijinDaughter, VioletFairy_BOSS,
  Ronin_Boss, Serpent_BOSS - drawn as NPC humans, not as pals
```

**Alpha pals.** This is the quieter half of "not all pals show on the map", and it is
plainly visible above. Alphas are named `BP_<Species>_BOSS_C_<id>` and reuse the **base**
species portrait — there is no `T_FoxMage_BOSS_icon_normal` — so the icon probe failed and
2.1.2's "a pal is something with a species icon" rule classified every alpha in the world
as a human NPC. The exact tribe is still tried first, because some variants genuinely do
have their own row (`FlameBuffalo_Ice`), and only a `_BOSS` suffix falls back to the base
species. Deliberately *only* `_BOSS`, not any trailing segment: dropping the last segment
of everything would send each human tribe on a second wild-goose chase too
(`NPC_Villager` → `NPC`), and each of those costs three more failed synchronous loads for
an asset that never existed. If some other suffix turns out to share a portrait, the
`no species icon for:` line names it.

**The call convention.** The arity is settled — UE4SS wants the `out` slot passed
explicitly. What it does *not* do is hand the filled array back as the first return value,
which is what 2.1.3 assumed. Three conventions are now all read from a single call: the
array may arrive as a **later** return value (a void function returns `nil` first, then its
out params), UE4SS may fill in **the very table that was passed**, or it may wrap the
result in a `RemoteUnrealParam` that has to be opened with `:get()` — the same wrapper
`asBool` already needs for reflected booleans. The probe now reports which one won, e.g.
`GetPalMonsters(ctx, out) -> lua table in the out table, 30 monsters`.

**Fixed in 2.1.3 — 2.1.2's `PalUtility` switch never actually engaged in game.**

The log said `character scan via FindAllOf` and nothing else, because every way the
lookup could fail collapsed into the same silent `nil`: missing CDO, raised call, and
unreadable return value were indistinguishable. Four concrete faults, all now fixed
and all covered in the harness:

* **The CDO was thrown away by a validity check.** `guard.alive()` calls `IsValid()`,
  which is an actor-ish notion — a class default object is not obliged to answer it.
  Requiring it discarded a perfectly good `PalUtility`.
* **Only one path spelling was tried.** Now `/Script/Pal.Default__PalUtility`, then
  `/Script/Pal.PalUtility`, then `FindFirstOf("PalUtility")` — which matches by class
  name and returns the CDO for a class with no instances, i.e. exactly a function
  library, and does not depend on how the path string has to be spelled on this build.
* **Only one call shape was tried.** Whether an `out` parameter needs a placeholder
  slot varies between UE4SS builds, so `(ctx)`, `(ctx, out)` and `()` are each
  attempted and the working one is remembered.
* **The returned `TArray` was read table-first.** A build that wraps the array in a
  Lua table with methods on it would be measured with `#v` — zero, because the elements
  live behind `GetArrayElement` — and the list would come back silently empty.
  `GetArrayNum` is tried first now, then plain table, then `ForEach`, and
  `GetArrayElement` is read from both 0 and 1 so its base does not have to be known.

Two further rules came out of getting this wrong. **An empty list is not proof a call
shape works** — a wrong shape and an empty level look identical from Lua — so a shape is
only adopted once it has actually produced something, and "empty" costs a cheap retry
instead of a decision. And the whole thing is **probed once and reported**: one line in
`UE4SS.log` now says which path, which call shape, which array shape and how many
monsters, or exactly which step failed.

**Fixed in 2.1.2 — the stutter while walking, and party pals on the map. Both
came out of reading what 1.x actually did:**

The 1.x blueprint's import table is the authority for how the old mod worked
(`_tools/ModActor.patched.json`), and it says something 2.x had never noticed: it
**did not scan for characters at all**. It called the game's own helpers —

```
/Script/Pal.PalUtility::GetPalMonsters(WorldContext, out TArray<PalCharacter>)
/Script/Pal.PalUtility::GetHumanNPCs(WorldContext, out TArray<PalCharacter>)
/Script/Pal.PalUtility::GetAllPlayerCharacters(WorldContext, out TArray)
```

2.x now prefers these, and it settles three separate problems at once:

* **No object-array walk.** `FindAllOf` walks every UObject in the process, and
  the character scan did it twice per tick. These return a list the game already
  maintains. That was the single largest cost in the mod.
* **Pal vs human stops being a guess.** 2.0.6 subtracted a class and erased every
  pal; 2.0.8 stopped subtracting and drew humans as pals; 2.1.0 inferred it from
  whether a species icon asset existed. The game just says which is which. The
  species icon is now only used to pick the *picture*.
* **Party pals stop appearing.** A pal in your team still has an actor — the game
  keeps it rather than destroying and respawning one every throw — and
  `FindAllOf("PalCharacter")` returned it. `GetPalMonsters` is world-scoped, and
  on top of that each pal is checked with `bHidden` and `PalUtility::IsDead`
  (which is what 1.x used, and why it had a "delay remove dead/caught pals"
  setting). Neither check may filter on a build that does not expose it: an
  unreadable property means *no opinion*, never *hide it* — getting that backwards
  is how 2.0.6 emptied the minimap. If `PalUtility` is not reachable at all, the
  2.1.1 scan runs unchanged and says so in the log.

**The walking stutter.** The symptom was specific — micro-hitches *while walking*,
as new places and items appeared — and that is the shape of the static scan. The
`FindAllOf` is one cost, but reading a location off **every** actor of that class
(plus the "already picked up" flag for collectibles) is a reflection call per
actor, and those lists grow as you walk into denser country and the level streams
more in. A hundred and twenty chests is a few hundred reflection calls in a single
pump, every time that class comes round.

So the per-class pass is **resumable**: at most 24 actors per step, driven from the
movement tick (10 Hz) instead of the scan tick, and the scan tick no longer carries
the character scan and a static class in the same pump. A class of any size now
costs a few extra tenths of a second to finish instead of one visible hitch, and no
pump does an unbounded amount of reflection. 1.x reached the same place from the
other direction — it gave each kind its own timer at a different period (pals 5 s,
players 12 s, chests and eggs 14 s, human NPCs 19 s) so two scans essentially never
landed on the same frame. 2.x cannot spend a timer per kind (there is exactly one,
by design — see the threading note), so the separation happens inside the pump.

Measured in the harness: worst case 24 location reads per step instead of 120, zero
object-array walks while a class is in progress, and zero walks at all for
characters.

**Fixed in 2.1.1 — the stutter as each arrow turned into a pal portrait:**

The report was, again, exactly the detail that made it findable: the map comes up
fine, the pals start as generic arrows, **and the game hitches at the moment an
arrow is replaced by that pal's own icon** — so in an area with many pals, where
new species keep walking into range, it hitches continuously.

That points at one call. `LoadAsset` is **synchronous**: it stalls the game thread
while the package is found, read and turned into UObjects, and UE4SS exposes no
asynchronous alternative. The only lever the mod has is *how often it pulls that
one*, and 2.1.0 pulled it far too often, from three places that did not know about
each other:

* `sources.lua` probed every new species with its own `StaticFindObject` +
  `LoadAsset`, up to six per scan, **on the scan tick**;
* `render.lua` then loaded the very same path **again** through a separate queue,
  two per movement tick — twenty a second;
* and when an icon had no texture yet, `render.lua` called `LoadAsset` for the
  fallback marker **from inside the per-icon draw loop** — up to 96 icons, ten
  times a second.

So every pal species cost two synchronous package loads, the second one pointless,
and the draw loop itself could load. That is the hitch, and it is proportional to
how many species are nearby, which is what the player described.

All of it now lives in one new file, `assets.lua`, under four rules:

1. **Nothing on a draw or scan path may block.** `assets.get` and `assets.probe`
   are table lookups; a miss only enqueues the path and returns nil. The icon
   keeps drawing its arrow until the portrait is genuinely in memory, and the
   swap then costs one `SetBrushFromTexture`.
2. **Two stages, because the two operations differ by orders of magnitude.**
   `StaticFindObject` is a hash lookup and touches no disk, so any texture the
   game already has resident is adopted for free, several per pump. Only what is
   genuinely absent reaches the load queue. In the test world this alone takes
   the common case to *zero* loads.
3. **At most one `LoadAsset` per pump, and the mod pays for it.** The call is
   timed and the next one is held off for 40× what the last cost — a 5 ms load
   buys 200 ms of silence. This caps the mod at ~2.5% of wall time inside
   `LoadAsset` on any machine: a slow disk gets a slower fill rate instead of a
   visible stutter, with nothing to tune per system.
4. **Failures back off and then give up** for the session, and are forgiven again
   on a world change, since an asset that cannot be found during a load screen is
   not missing — it was simply not mounted yet.

The pump runs once per movement tick, *after* the draw, so whatever it spends is
spent when the frame's real work is already done.

One related mistake is corrected with it. Quality level 2 used to force every
**icon's** full mip chain resident. Icons are drawn at eighteen pixels, so those
mips were pulled off disk only to be scaled away — and the streaming burst that
followed each newly discovered species was part of the same stutter. Forcing mips
resident is right for the terrain, which is one texture magnified several times
across the window; it is wrong for 137 portraits. Icons are left to the streamer
now, and the setting is kept so existing settings files still load.

**Fixed in 2.1.0 — the freeze while using the settings window, and the pals
that showed as arrows:**

**The freeze.** The report was precise and it is what made this findable: while
checkboxes were being clicked in the F5 window, the mod stopped dead — the menu
would not close, the minimap froze on its last frame, **and the game kept
running**. Nothing else produces exactly that. Both widgets were still in the
viewport, so the engine was fine; only our game-thread work had stopped. That is
what it looks like when UE4SS removes its own `EngineTick` hook after the Lua
registry has been corrupted — the same failure as the 2.0.5 crash, but this time
it did not take the game down with it.

2.0.6 cut the number of threads taking Lua registry references from five to one,
which made it rare. It did not make it impossible, because the remaining race is
not between two timer threads — it is between the **timer thread taking** a
reference (`ExecuteInGameThread` → `luaL_ref`) and the **game thread releasing**
the previous one (`luaL_unref`) as a pump returns. The wider the pump, the wider
that window, and a menu commit is the widest pump there is: it tears the minimap
down and rebuilds a couple of hundred UMG widgets. Meanwhile the 33 ms timer kept
firing straight through it and queuing *more* pumps behind the slow one, each of
which would do the same work again. Four changes, and the first three are
structural:

- **One dispatch in flight at a time.** The timer thread will not take a new
  reference while the game thread is still inside the last pump. This also bounds
  the backlog at one, so a slow pump can no longer cascade.
- **A gap after a pump ends** before the next reference is taken, so the new
  `luaL_ref` cannot land on top of UE4SS's `luaL_unref` for the one that just
  finished. It also recovers on its own if a dispatch is simply dropped, which
  happens across a world transition, instead of deadlocking on the in-flight flag.
- **The key queue is a fixed ring buffer now.** It used to append to a growing
  table and swap in a fresh one on every drain. Both of those **allocate**, and
  the append runs on UE4SS's input thread while the game thread is running our
  pump — and any allocation can advance Lua's incremental collector, which is
  precisely the corruption that surfaces later as "Ref was not function". Every
  slot is preallocated, so a key press writes one existing array entry and one
  number: no allocation, no collector, no race. (Holding an arrow key in edit mode
  is how the original 2.0.5 crash was reproduced. That path is now allocation-free
  end to end.)
- **Rebuilds are coalesced.** A rebuild destroys and reconstructs up to 260
  widgets, and clicking "Circular shape" twice — or holding `+` in edit mode — ran
  one per key press, back to back. One rebuild 250 ms after the first request
  absorbs a whole burst and is not perceptible. Verified: a 20-press resize burst
  now costs **one** rebuild instead of twenty.
- Class-path lookups in `render.lua` and `menu.lua` are memoised. Every one of
  those 260 widgets did its own `StaticFindObject` on the same half-dozen class
  paths, on the game thread, while the player was still clicking.
- The settings window's own polling — forty controls, four times a second — no
  longer builds a closure and an error-label string per control per tick.

If it ever does happen again, the log now says so explicitly instead of going
silent: the timer thread notices that the game thread has not run a pump for
several seconds and prints one line naming the engine tick hook.

**Pals shown as arrows, and not all pals shown.** One cause, and it was the
2.0.8 fix's shadow. 2.0.6 subtracted `FindAllOf("PalNPC")` from
`FindAllOf("PalCharacter")` and erased every pal, because `PalNPC` is a
*superclass* of wild pals on this build. 2.0.8 detected that and stopped
subtracting — which left the **humans in the pal list**, drawn with the generic
member marker (the arrows) and, worse, eating the `maxPalIcons` budget, so real
pals fell off the end of the distance-sorted list.

Neither the class tree nor its inverse is safe to hard-code, so the question is
answered directly instead: **a pal has a species icon.** The tribe comes out of
the actor name and `T_<Tribe>_icon_normal` either exists in the game's content or
it does not. That is a fact about the actor, not about a hierarchy a game update
can rearrange. Everything that resolves is a pal and gets its portrait;
everything that does not is a human and goes to the NPC list, where "Show NPC
humans" controls it.

The guards matter as much as the test, because this is the third attempt at it:

- Until **one** icon has actually resolved, the path format is unproven on this
  build, so nothing is filtered and behaviour is exactly what it was. That is what
  makes this incapable of repeating 2.0.6.
- A negative is never taken on the first try. Palworld streams its assets, so a
  probe during a load screen can come back empty for a species that is perfectly
  real; it takes three scans in a row, at most one probe per tribe per scan, and
  the negatives are dropped again on a world change while the positives are kept.
- Probes are budgeted per scan, so a crowd of unfamiliar actors cannot cause a
  hitch, and the tribes that never resolved are logged once by name.

Two things fall out for free: `FindAllOf("PalNPC")` is gone entirely — a full
UObject-array walk every scan for a result we had already decided to throw away —
and the species icon path is now resolved **once at scan time** instead of being
`string.format`'d for every pal on every frame (about 480 throwaway strings a
second at the default settings).

A related render bug went with it: when neither a marker's texture nor its
fallback resolved, the brush was left alone — so the pool slot kept showing
whatever marker used it last, a chest where a pal should be. An unresolved slot
now stays hidden, and retries on the next update.

**Fixed in 2.0.9 — the Esc menu, and the stuttering:**

**The Esc menu.** The class name was right all along: the v1 blueprint imports
`/Game/Pal/Blueprint/UI/InGameMainMenu/WBP_InGameMainMenu` and tests exactly that
class, which is how v1 hid itself. The bug was on our side, twice over:

- `FindAllOf` also returns the **class default object**,
  `Default__WBP_InGameMainMenu_C`. It comes back first, we cached it, and a CDO
  is never in the viewport — so the test answered "menu closed" forever. Names
  beginning with `Default__` are skipped now.
- Caching **one** instance was wrong anyway: the game may build a fresh menu
  widget each time it opens, leaving the cached one alive but permanently out of
  the viewport. Every live instance is kept, and any one of them being in the
  viewport counts.

`IsGamePaused` stays as a second signal, but it is not the answer on its own —
Palworld does not pause for its menus.

**The stuttering.** Three separate causes, all on the game thread:

- **Garbage, by the hundred-thousand.** The idiom this codebase was written in,
  `guard.get(function() slot:SetPosition({ X = x, Y = y }) end)`, allocates **two**
  objects per call — the closure and the vector table. One update repositions the
  map (or 24 clipped strips), the player marker and up to 96 icons, ten times a
  second, several setters each. Measured in isolation: 19 200 setter calls cost
  **30 KB** of garbage the old way and **0 KB** hoisted, a ~470× difference — and
  that is one setter out of several. Every hot-path read and write is now a
  hoisted top-level function called as `pcall(fn, args)`, with a single shared
  vector table refilled in place (UE4SS copies X/Y out during the call and keeps
  no reference). End to end: **9 bytes per frame** with 96 icons and 24 strips.
- **Eleven full UObject-array walks in a single tick.** `FindAllOf` walks the
  whole object array, and the static scan ran one per class — eleven of them back
  to back. It is now spread across ticks: **one class per scan tick** (three while
  a kind has never been looked at, so the map still fills in quickly after a load),
  with the merged marker list rebuilt every tick from cached positions using no
  reflection at all. Sound because these things do not move. Verified: **1 walk per
  static tick, down from 11.**
  A class already proven to be a superclass of pals is no longer scanned at all,
  which takes the dynamic scan from 3 walks to 2.
- **The pal loop read a name for every pal in the level.** Most of them are
  kilometres away and get thrown out on distance. The distance test now comes
  first and the name is only read for the survivors.

Also: the circular disc uses 24 strips instead of 31. Each strip is its own Slate
clipping zone, and a clipping-zone change breaks batching — so every strip is one
more draw call **every frame**, not every update. A ~4 px outline error costs 24
and is not tellable apart from ~3 px once the game's circular art is over the seam.

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
