-- =====================================================================
-- capture.lua - the terrain as a SECOND RENDER of the world (2.3.0)
--
-- WHY THIS EXISTS, and why it is not simply 1.x coming back.
--
-- Until 2.2.20 the terrain was the game's own /Game/Pal/Texture/UI/Map/
-- T_WorldMap drawn as one quad. That texture is a picture of the main
-- island and nothing else, so anywhere the artists did not paint - the
-- great tree at the edge of the world, and the inside of every dungeon -
-- the minimap showed either blank ground or, worse, a piece of the island
-- that has no relation to where the player actually is. No amount of
-- coordinate work fixes that: the information is not in the image.
--
-- So the terrain is now rendered. A USceneCaptureComponent2D looks straight
-- down at the player through an ORTHOGRAPHIC projection into a render
-- target, and that render target is what the minimap draws. It works
-- wherever the player can stand, because it is a picture of what is
-- actually there.
--
-- ---------------------------------------------------------------------
-- 1.x DID THIS AND IT WAS THE WORST THING IN THE MOD. THE DIFFERENCE:
--
-- 1.x left `bCaptureEveryFrame` at its default of TRUE. That is a second
-- full scene render EVERY FRAME, forever, whether or not the minimap was
-- even visible - the permanent GPU cost that render.lua's header still
-- complains about. Here:
--
--   * `bCaptureEveryFrame` and `bCaptureOnMovement` are BOTH false and
--     `CaptureScene()` is called by hand, at most `captureIntervalMs`
--     apart (250 ms by default = 4 renders a second, not 60+);
--   * nothing is captured at all while the minimap is hidden, while the
--     game's own menus are up, or while the player is standing still and
--     the last image is still centred on them;
--   * the render target is small - 256 to 768 px square, from the
--     `mapQuality` setting, which is what that slider meant in 1.x too;
--   * the capture is OVERSCANNED (see OVERSCAN) so the minimap can pan and
--     rotate inside the last image, which is what makes 4 Hz look smooth
--     at 10 Hz of movement.
--
-- The other 1.x disaster - StaticMeshComponent icons attached to world
-- actors - is NOT coming back with it. Icons stay pooled UMG images
-- positioned by arithmetic. The only thing this file attaches to an actor
-- is one component on the player's OWN pawn, which is the actor whose life
-- the mod is already tied to.
--
-- ---------------------------------------------------------------------
-- WHAT COULD NOT BE CARRIED OVER FROM 1.x, and what was done instead.
--
-- 1.x's capture component had a baked `ShowFlagSettings` array turning off
-- 32 things (Lighting, Fog, DynamicShadows, InstancedFoliage, ...), which
-- is how it got a flat, always-daylight map. Show flags are applied from
-- that array by `UpdateShowFlags()`, which only runs at load/edit time, and
-- the live `FEngineShowFlags` member is not a UPROPERTY - so from Lua
-- there is no way to touch them at all.
--
-- `CaptureSource` IS a UPROPERTY, and `SCS_BaseColor` gets to the same
-- place by a different road: it resolves the GBuffer's base colour, so
-- there is no lighting, no shadow, no fog and no night in the image. That
-- is the default (`captureStyle` 0). `captureStyle` 1 asks for
-- `SCS_FinalColorLDR` instead - the world as the game actually shows it,
-- night and weather included - for players who want that.
--
-- ---------------------------------------------------------------------
-- ORIENTATION IS NOT A GUESS. A capture rotated (Pitch=-90, Yaw=0, Roll=0)
-- has screen-right = world +Y and screen-up = world +X. worldmap.lua's
-- long-confirmed convention for the map texture is exactly that (`toUV`
-- returns u from world Y and v from -world X), so the live image drops
-- into the same coordinate frame the icons already use and nothing else
-- has to change.
--
-- THE HEIGHT IS WHY DUNGEONS WORK. The camera sits `captureHeight` above
-- the player, not up in the sky: an orthographic camera does not render
-- what is behind it, so a cave roof or a building's ceiling is simply not
-- in the picture, and the floor the player is standing on is. Orthographic
-- also means height does not change the SCALE, only what gets clipped
-- away, so a low camera costs nothing in detail.
-- =====================================================================

local guard = require("guard")

local M = {}

-- ESceneCaptureSource. Order verified against the shipping exe's string
-- table, not assumed.
local SCS_SCENE_COLOR_HDR   = 0
local SCS_FINAL_COLOR_LDR   = 2
local SCS_SCENE_COLOR_DEPTH = 3
local SCS_BASE_COLOR        = 7
-- ECameraProjectionMode
local PROJECTION_ORTHO    = 1
-- ETextureRenderTargetFormat
local RTF_RGBA8           = 2
local RTF_RGBA8_SRGB      = 3
-- EAttachmentRule
local ATTACH_KEEP_RELATIVE = 0

local CAPTURE_CLASS = "/Script/Engine.SceneCaptureComponent2D"
local RENDER_LIB    = "/Script/Engine.Default__KismetRenderingLibrary"

-- ---------------------------------------------------------------
-- THE CAPTURE SOURCE IS PROBED, NOT CHOSEN - and 2.3.1 is why.
--
-- 2.3.0 asked for `SCS_BaseColor` and shipped it. In game the capture
-- worked perfectly - the component was created, the target was filled, the
-- readback found real colours - and the minimap showed NO TERRAIN AT ALL.
--
-- Because the scene-capture pixel shader writes
--
--     SOURCE_MODE_BASE_COLOR   ->  float4(GBuffer.BaseColor, 0)
--                                                          ^^^
--
-- Alpha ZERO. Slate multiplies a brush by its texture's alpha, and UMG
-- materials cannot be authored from Lua, so a fully transparent image is a
-- fully invisible minimap. `SCS_SceneColorHDR` is the one mode that
-- deliberately writes an opacity: `float4(SceneColor.rgb, 1 - SceneColor.a)`,
-- which is 1 over anything opaque - and it is what 1.x used.
--
-- The lesson is the one this mod keeps relearning: A CALL THAT RETURNED
-- WITHOUT AN ERROR IS NOT PROOF IT DID ANYTHING USABLE. 2.3.0's verify()
-- checked the colours and never looked at the alpha, so it confirmed an
-- invisible image as working.
--
-- So each style is now an ORDERED LIST of sources, and verify() measures
-- COLOUR *AND* ALPHA and steps to the next one when what came back cannot
-- be drawn. The winner is logged with the pixel it was judged on.
--
-- ---------------------------------------------------------------------
-- 2.3.2: EVERY SOURCE 2.3.1 TRIED CAME BACK WITH ALPHA ZERO, AND THE
-- ANSWER IS `SCS_SceneColorSceneDepth`. This is the fix, so it is worth
-- being precise about why the other three cannot work:
--
--   BaseColor       float4(GBuffer.BaseColor, 0)          - 0 by definition
--   SceneColorHDR   float4(SceneColor.rgb, 1 - alpha)     - opaque geometry
--                   leaves SceneColor.a at 1, so this is 1 - 1 = 0
--   FinalColorLDR   whatever survives the post-process chain, and alpha
--                   propagation through post is OFF by default in UE5
--
-- Every one of them encodes some flavour of "how TRANSLUCENT is this",
-- which for solid ground is zero. None of them encodes coverage. That is
-- not a wrong-source bug and no fourth guess at the same kind of source
-- would have fixed it.
--
-- `SCS_SceneColorSceneDepth` is different in kind - it writes
--
--     float4(SceneColor.rgb, CalcSceneDepth(uv))
--
-- and scene depth is a distance in CENTIMETRES: the ground is
-- `captureHeight` away, so ~1500. Written into a UNORM8 target that
-- saturates at 1.0, which is exactly what we want and the reason this
-- works - alpha comes out 255 everywhere there is any geometry at all,
-- while the colour channels still carry the real scene colour. The
-- depth's precision is irrelevant here; we are using it purely as an
-- "something is here" bit that the other sources refuse to write.
--
-- The route AROUND the alpha - feeding the target through a material, the
-- way 1.x did on a StaticMesh plane - is a dead end inside UMG and cost
-- three native crashes to establish: a material drawn by Slate must have
-- MaterialDomain = User Interface, `/Paper2D/OpaqueUnlitSpriteMaterial`
-- is a Surface material, and the shader permutation for Slate's vertex
-- factory was therefore never cooked. Slate draws it with a null shader
-- and the render thread dies inside the game with no UE4SS frame on the
-- stack. Material domain is a COMPILE-TIME property, so no amount of
-- Lua fixes it. Do not go back down that road.
--
-- THE FORMAT FOLLOWS THE SOURCE, and getting the pair wrong shows up as a
-- washed-out or a crushed minimap rather than as an error:
--   * BaseColor, SceneColorHDR and SceneColorSceneDepth write LINEAR
--     values, so the target is sRGB - the hardware encodes on write and
--     Slate decodes on read;
--   * FinalColorLDR has already been through the tonemapper and is
--     sRGB-encoded, so an sRGB target would encode it a second time.
-- ---------------------------------------------------------------
local SOURCES = {
    [SCS_SCENE_COLOR_DEPTH] = { format = RTF_RGBA8_SRGB,
        name = "scene colour with depth as alpha (lit; the only source that "
            .. "comes out opaque)" },
    [SCS_BASE_COLOR] = { format = RTF_RGBA8_SRGB,
        name = "base colour (flat: no lighting, shadow, fog or night)" },
    [SCS_SCENE_COLOR_HDR] = { format = RTF_RGBA8_SRGB,
        name = "scene colour (lit, with an opacity - what 1.x used)" },
    [SCS_FINAL_COLOR_LDR] = { format = RTF_RGBA8,
        name = "final colour (lit, tonemapped)" },
}

-- `captureStyle` 0 leads with the source that is KNOWN to come out
-- drawable on this build, because a chain that starts with a measured
-- failure costs the player a blank minimap and a target rebuild per step
-- at the beginning of every session.
--
-- Style 1 still leads with BaseColor for the flat, always-daylight look,
-- since that is genuinely nicer when it works and a build whose post
-- pipeline propagates alpha would deliver it - but it is EXPECTED to fall
-- through to the same place on stock Palworld. It is an opt-in with a
-- known cost, not the default.
local STYLES = {
    [0] = { name = "lit",  chain = { SCS_SCENE_COLOR_DEPTH, SCS_SCENE_COLOR_HDR,
                                     SCS_FINAL_COLOR_LDR, SCS_BASE_COLOR } },
    [1] = { name = "flat", chain = { SCS_BASE_COLOR, SCS_SCENE_COLOR_DEPTH,
                                     SCS_SCENE_COLOR_HDR, SCS_FINAL_COLOR_LDR } },
}

-- `mapQuality` meant "render target resolution" in 1.x and nothing at all
-- in 2.0-2.2 (there was no render). It means resolution again.
local RESOLUTION = { [0] = 256, [1] = 384, [2] = 512, [3] = 768 }

-- ---------------------------------------------------------------
-- THE CAPTURED WINDOW IS WIDER THAN THE VISIBLE ONE, AND IT IS HELD
-- FIXED BETWEEN CAPTURES. That second half is 2.3.2's zoom fix.
--
-- 2.3.1 recomputed `capW = zoom * OVERSCAN` every tick and wrote it to
-- OrthoWidth, and render.lua sizes the quad as `capW * (size / zoom)`.
-- Substitute one into the other:
--
--     imagePx = (zoom * OVERSCAN) * (size / zoom) = OVERSCAN * size
--
-- The zoom CANCELS. The quad was the same number of pixels at every zoom
-- level, so zooming only changed how much world the same on-screen image
-- covered - i.e. its sharpness - which grass does not make visible. That
-- is Jean's "o mapa nao ta seguindo o zoom quando render e live", and it
-- was pure algebra, not a reflection or engine problem.
--
-- The fix: a capture fixes `capW` at the zoom it was taken at, and that
-- number is then CONSTANT until a recapture. `k = size / zoom` keeps
-- moving, so `imagePx = capW * k` moves with it and the terrain zooms -
-- exactly the mechanism the map-texture path always used (its span is the
-- region's, which never changes at all), just refreshed periodically.
--
-- OVERSCAN then has to cover three things at once, and this is why it is
-- 1.75 rather than the 1.414 floor:
--   * rotation - a SQUARE minimap's corners sweep a circle of diameter
--     `zoom * sqrt(2)`, and uncaptured world shows as an empty wedge
--     turning with the player;
--   * zooming OUT since the capture, up to the ceiling computed below;
--   * MOVE_SLACK of drift off the captured centre before we recapture.
-- `zoomCeiling` derives the headroom from those three instead of hard-
-- coding a band, so the invariant cannot silently break if one changes.
-- ---------------------------------------------------------------
local OVERSCAN = 1.75
local SQRT2 = 1.4142135623730951
-- how far off the captured centre the player may drift, as a fraction of
-- the captured width, before the image is refreshed
local MOVE_SLACK = 0.04
-- Zooming IN past this fraction of the captured zoom is not a correctness
-- problem - the image covers more than enough world - but the same render
-- target is being magnified over a smaller window, so it goes soft.
-- Recapture to get the detail back.
local ZOOM_BAND_LOW = 0.65

-- The largest zoom (world units across the visible window) that the last
-- capture can still legitimately cover. Past this there is nothing in the
-- image for the edges of the minimap and it has to be retaken.
local function zoomCeiling(capW, rotate)
    local need = rotate and SQRT2 or 1.0
    -- half the captured width, minus the drift we allow, is the furthest
    -- from centre the image is guaranteed to be valid; the window needs
    -- `zoom / 2 * need` of that.
    return (capW * (0.5 - MOVE_SLACK) * 2.0) / need
end

-- Never capture more often than this however fast the player moves, and
-- re-capture at least this often even when they are standing still (the
-- world still moves: doors, other players' buildings, day and night in lit
-- style).
local MIN_INTERVAL = 0.10
local IDLE_REFRESH = 4.0

-- Creating the component or the render target can fail on a build that
-- reflects any of this differently. Back off, then stop asking: the caller
-- falls back to the world map texture, which is exactly the 2.2 behaviour,
-- so a failure here costs the new capability and nothing else.
local RETRY_SECONDS = 10.0
local MAX_TRIES = 6

local S = {
    comp = nil,             -- our USceneCaptureComponent2D
    rt = nil,               -- the UTextureRenderTarget2D it draws into
    gen = 0,                -- bumped whenever `rt` becomes a different object
    rtPx = nil,             -- resolution the current target was made at
    styleId = nil,          -- style the current component was configured for
    height = nil,           -- captureHeight the component was placed at
    step = 1,               -- how far down the style's source chain we are
    source = nil,           -- the ESceneCaptureSource in use right now

    cx = nil, cy = nil,     -- world centre of the last capture
    capW = nil,             -- world units across the last capture
    capZoom = nil,          -- the visible zoom it was taken at
    orthoW = nil,           -- OrthoWidth currently written on the component
    capturedAt = 0.0,

    route = nil,            -- how the component was created, for the log
    -- Was it created ATTACHED to the pawn? If so the engine carries it and
    -- no per-capture placement call is made - see the long note above
    -- rawSetWorldBoth, and the native crash that call caused.
    attached = false,
    trackChecked = false,   -- has the attachment been proven to follow?
    -- Set only when the attachment demonstrably does NOT follow the pawn on
    -- this build. Session-wide: it is a property of the build, not of one
    -- component, so a rebuild must not make us re-learn it.
    mustPlace = false,
    tries = 0,
    nextTryAt = 0.0,
    unavailable = false,

    captures = 0,
    costTotal = 0.0,
    costWorst = 0.0,
    reported = false,

    verifyAt = nil,         -- when to read the target back (see verify())
    verified = nil,         -- true once we have seen a non-empty image
    blankStreak = 0,
}

-- ---------------------------------------------------------------
-- Hoisted reflection thunks and shared argument tables.
--
-- Same rule as render.lua: `guard.get(function() c.OrthoWidth = w end)`
-- allocates a closure per call. This path runs at most a few times a
-- second rather than per icon, but the rule is cheap to keep and the
-- allocation is on the game thread either way.
-- ---------------------------------------------------------------
local VEC = { X = 0.0, Y = 0.0, Z = 0.0 }
local ROT = { Pitch = -90.0, Yaw = 0.0, Roll = 0.0 }
local CLEAR = { R = 0.0, G = 0.0, B = 0.0, A = 1.0 }
local IDENTITY = {
    Rotation = { X = 0.0, Y = 0.0, Z = 0.0, W = 1.0 },
    Translation = { X = 0.0, Y = 0.0, Z = 0.0 },
    Scale3D = { X = 1.0, Y = 1.0, Z = 1.0 },
}
local NO_HIT = {}

local function rawAddComponent(actor, class, manual)
    return actor:AddComponentByClass(class, manual, IDENTITY, false)
end
local function rawRoot(actor) return actor.RootComponent end
local function rawAttach(comp, parent)
    return comp:K2_AttachToComponent(parent, "None", ATTACH_KEEP_RELATIVE,
        ATTACH_KEEP_RELATIVE, ATTACH_KEEP_RELATIVE, false)
end
local function rawCaptureScene(comp) comp:CaptureScene() end

-- =====================================================================
-- POSITIONING, AND THE NATIVE CRASH IT CAUSED (2.3.4)
--
-- The mod died with EXCEPTION_ACCESS_VIOLATION reading 0x00006e9e00000038
-- after about seventeen minutes in the world. What the log showed, and it
-- showed it 1419 times:
--
--     [push_weakobjectproperty] Operation::Set is not supported
--
-- in bursts of THREE, starting four seconds after "live terrain capture
-- positioned via K2_SetWorldLocationAndRotation" and ending on the very
-- last line before the crash. The gaps between bursts were 0.5-4.0 s,
-- which is exactly this file's capture cadence (MIN_INTERVAL up to
-- IDLE_REFRESH). 1419 / 3 = 473 captures.
--
-- THREE, because that is how many WEAK OBJECT pointers an `FHitResult`
-- carries (its component, its hit actor handle and its physical material).
-- Every K2_SetWorld* function takes an FHitResult as an out parameter, and
-- passing a plain Lua table for it makes UE4SS walk the struct and try to
-- assign each property from that table - which it cannot do for a weak
-- pointer, so it says so and leaves them however it found them. Doing that
-- several times a second for seventeen minutes is the only thing this mod
-- was doing that the engine had no defined answer for.
--
-- There is no variant without the out parameter on this build:
-- `K2_SetWorldLocationAndRotationNoPhysics` is not in the shipping exe at
-- all (checked), and K2_SetWorldLocation / K2_SetWorldRotation /
-- K2_SetRelativeLocation all carry the same FHitResult.
--
-- SO THE CALL IS GONE ON THE ROUTE THAT MATTERS. The component is created
-- with `AddComponentByClass` ATTACHED to the pawn's root, which means the
-- engine already keeps its world transform current every frame - the
-- placement call was re-doing by hand, several times a second, what the
-- attachment does for free. Setting the relative transform ONCE (plus
-- `bAbsoluteRotation`, so the camera keeps pointing down however the pawn
-- turns) is all the attached route ever needed.
--
-- It is not assumed to have worked, because struct PROPERTY writes are not
-- proven on this build the way struct function ARGUMENTS are: after the
-- first capture the component's own world location is read back with
-- `K2_GetComponentLocation` - a plain getter, no out parameter, nothing to
-- marshal - and compared against where the player actually is. If it is
-- not tracking, `S.mustPlace` turns the old call back on for the session
-- and says so in the log. A build that needs it pays the warnings; this
-- one does not pay anything.
--
-- The two call shapes below are kept for the unattached and
-- StaticConstructObject routes, which have no parent to follow and
-- genuinely have to be moved by hand.
-- =====================================================================
local function rawSetWorldBoth(comp, x, y, z)
    VEC.X, VEC.Y, VEC.Z = x, y, z
    comp:K2_SetWorldLocationAndRotation(VEC, ROT, false, NO_HIT, true)
end
local function rawSetWorldSplit(comp, x, y, z)
    VEC.X, VEC.Y, VEC.Z = x, y, z
    comp:K2_SetWorldLocation(VEC, false, NO_HIT, true)
    comp:K2_SetWorldRotation(ROT, false, NO_HIT, true)
end

local PLACE_SHAPES = {
    { fn = rawSetWorldBoth,  name = "K2_SetWorldLocationAndRotation" },
    { fn = rawSetWorldSplit, name = "K2_SetWorldLocation + K2_SetWorldRotation" },
}
local placeShape = nil

local function place(comp, x, y, z)
    if placeShape ~= nil then
        if pcall(placeShape.fn, comp, x, y, z) then return true end
        placeShape = nil
    end
    for i = 1, #PLACE_SHAPES do
        local shape = PLACE_SHAPES[i]
        if pcall(shape.fn, comp, x, y, z) then
            placeShape = shape
            guard.log("live terrain capture positioned via " .. shape.name)
            return true
        end
    end
    return false
end

-- On the attached route these ARE the placement - see the note above - so
-- they are no longer "best effort". Both the member-write and the
-- whole-struct forms are tried because UE4SS builds differ on which one
-- takes, and `trackingWorks()` below decides whether either did.
local function rawRelativeMembers(comp, z)
    local rl = comp.RelativeLocation
    rl.X, rl.Y, rl.Z = 0.0, 0.0, z
    local rr = comp.RelativeRotation
    rr.Pitch, rr.Yaw, rr.Roll = -90.0, 0.0, 0.0
end
local function rawRelativeAssign(comp, z)
    VEC.X, VEC.Y, VEC.Z = 0.0, 0.0, z
    comp.RelativeLocation = VEC
    comp.RelativeRotation = ROT
end
local function rawAbsoluteRotation(comp) comp.bAbsoluteRotation = true end
-- A plain getter returning a struct BY VALUE: nothing to marshal into, so
-- none of the FHitResult problem applies to reading.
local function rawComponentLocation(comp) return comp:K2_GetComponentLocation() end

-- Is the attachment really carrying the camera with the pawn? Called once,
-- after the first capture, and never again unless the component is rebuilt.
-- A generous tolerance on purpose: the question is "is it following the
-- player at all", not "is it exact" - the capture is overscanned and one
-- capture interval of lag is normal and harmless.
local TRACK_TOLERANCE = 3000.0

local function trackingWorks(comp, px, py)
    local loc = guard.get(rawComponentLocation, comp)
    if loc == nil then return nil end                 -- unreadable: no opinion
    local x = guard.get(function() return loc.X end)
    local y = guard.get(function() return loc.Y end)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    local dx, dy = x - px, y - py
    return (dx * dx + dy * dy) <= (TRACK_TOLERANCE * TRACK_TOLERANCE)
end
local function rawSetTarget(comp, rt) comp.TextureTarget = rt end
local function rawSetOrtho(comp, w)
    comp.ProjectionType = PROJECTION_ORTHO
    comp.OrthoWidth = w
end
local function rawSetSource(comp, src) comp.CaptureSource = src end
local function rawSetManual(comp)
    comp.bCaptureEveryFrame = false
    comp.bCaptureOnMovement = false
    comp.bAlwaysPersistRenderingState = true
end
local function rawDestroy(comp) comp:K2_DestroyComponent(comp) end
local function rawReadPixel(lib, rt, x, y) return lib:ReadRenderTargetPixel(lib, rt, x, y) end
local function rawRGBA(c) return c.R, c.G, c.B, c.A end
local function rawWorldOf(actor) return actor:GetWorld() end

local function renderLib()
    local lib = guard.get(StaticFindObject, RENDER_LIB)
    if lib ~= nil and guard.alive(lib) then return lib end
    return nil
end

-- ---------------------------------------------------------------
-- The render target
--
-- CreateRenderTarget2D's signature has grown a parameter or two across
-- engine versions and UE4SS insists on being handed exactly as many as the
-- UFunction declares, so the call is tried widest-first and narrows. The
-- shape that answers is logged once - without that line a build where none
-- of them fit is indistinguishable from a build where the capture renders
-- black.
-- ---------------------------------------------------------------
local function rawCreateRT7(lib, world, px, fmt)
    return lib:CreateRenderTarget2D(world, px, px, fmt, CLEAR, false, false)
end
local function rawCreateRT6(lib, world, px, fmt)
    return lib:CreateRenderTarget2D(world, px, px, fmt, CLEAR, false)
end
local function rawCreateRT5(lib, world, px, fmt)
    return lib:CreateRenderTarget2D(world, px, px, fmt, CLEAR)
end
local function rawCreateRT4(lib, world, px, fmt)
    return lib:CreateRenderTarget2D(world, px, px, fmt)
end

local RT_SHAPES = {
    { fn = rawCreateRT7, name = "7 params" },
    { fn = rawCreateRT6, name = "6 params" },
    { fn = rawCreateRT5, name = "5 params" },
    { fn = rawCreateRT4, name = "4 params" },
}
local rtShape = nil

local function makeRenderTarget(world, px, fmt)
    local lib = renderLib()
    if lib == nil then return nil, "KismetRenderingLibrary is not reachable" end

    if rtShape ~= nil then
        local rt = guard.get(rtShape.fn, lib, world, px, fmt)
        if rt ~= nil and guard.alive(rt) then return rt end
        rtShape = nil        -- it worked once and does not now; re-probe
    end
    for i = 1, #RT_SHAPES do
        local shape = RT_SHAPES[i]
        local rt = guard.get(shape.fn, lib, world, px, fmt)
        if rt ~= nil and guard.alive(rt) then
            rtShape = shape
            guard.log("render target created via CreateRenderTarget2D (" ..
                shape.name .. "), " .. px .. "px")
            return rt
        end
    end
    return nil, "CreateRenderTarget2D refused every call shape"
end

-- ---------------------------------------------------------------
-- The component
--
-- `AddComponentByClass` is the only route on this build that both
-- CONSTRUCTS and REGISTERS a component: `RegisterComponent` is not a
-- UFUNCTION and does not appear in the exe at all, so a component built
-- with StaticConstructObject alone is never handed to the renderer and
-- captures nothing. That route is kept last anyway, because a
-- silently-black minimap and a missing one are told apart by verify()
-- below rather than by hoping.
-- ---------------------------------------------------------------
local function createComponent(owner)
    local class = guard.get(StaticFindObject, CAPTURE_CLASS)
    if class == nil then
        return nil, "the SceneCaptureComponent2D class is not reachable"
    end

    -- attached to the pawn's root, so the engine keeps the transform
    -- current as the player runs around and we do not have to
    local comp = guard.get(rawAddComponent, owner, class, false)
    if comp ~= nil and guard.alive(comp) then
        return comp, "AddComponentByClass (attached)", true
    end

    -- same call without the attachment: the component is positioned by
    -- hand every capture instead
    comp = guard.get(rawAddComponent, owner, class, true)
    if comp ~= nil and guard.alive(comp) then
        return comp, "AddComponentByClass (unattached)", false
    end

    comp = guard.get(StaticConstructObject, class, owner)
    if comp ~= nil and guard.alive(comp) then
        local root = guard.get(rawRoot, owner)
        if root ~= nil and guard.alive(root) then
            guard.get(rawAttach, comp, root)
        end
        -- attached by hand above, but only if the root was reachable;
        -- treat it as unattached so the placement fallback still runs
        return comp, "StaticConstructObject (may not be registered)", false
    end

    return nil, "no route constructed a capture component"
end

local function styleFor(cfg)
    local id = tonumber(cfg.captureStyle) or 0
    if STYLES[id] == nil then id = 0 end
    return id, STYLES[id]
end

-- Which CaptureSource this style is on right now, and what the render
-- target has to be to hold it. `S.step` walks the style's chain as verify()
-- rejects one after another.
local function sourceFor(style)
    local chain = style.chain
    local step = S.step
    if step < 1 then step = 1 end
    if step > #chain then return nil end
    local id = chain[step]
    return id, SOURCES[id]
end

local function resolutionFor(cfg)
    local q = tonumber(cfg.mapQuality) or 2
    return RESOLUTION[q] or 512
end

local function heightFor(cfg)
    local h = tonumber(cfg.captureHeight) or 1500
    if h < 100 then h = 100 elseif h > 60000 then h = 60000 end
    return h
end

local function configure(styleId, style, source, height)
    local comp = S.comp
    guard.get(rawSetManual, comp)
    guard.get(rawSetSource, comp, source)
    guard.get(rawSetOrtho, comp, 10000.0)
    guard.get(rawAbsoluteRotation, comp)
    if not pcall(rawRelativeMembers, comp, height) then
        pcall(rawRelativeAssign, comp, height)
    end
    if S.rt ~= nil then guard.get(rawSetTarget, comp, S.rt) end
    S.styleId, S.height, S.source = styleId, height, source
end

-- Let go of everything. Called on a world change, on a quality change, and
-- whenever the component or the target turns out to be dead.
local function release(destroyComponent)
    if destroyComponent and S.comp ~= nil and guard.alive(S.comp) then
        guard.get(rawDestroy, S.comp)
    end
    S.comp, S.rt = nil, nil
    -- `attached` and `trackChecked` belong to the component that is going
    -- away. `mustPlace` deliberately does NOT reset: it is a fact about
    -- this BUILD, and re-learning it per rebuild would mean another
    -- component's worth of captures pointed at the wrong place.
    S.attached, S.trackChecked = false, false
    S.rtPx, S.styleId, S.height, S.source = nil, nil, nil, nil
    S.cx, S.cy, S.capW, S.capZoom = nil, nil, nil, nil
    -- the component this was written on is going away, so forget it and
    -- force the next capture to write OrthoWidth again
    S.orthoW = nil
    S.verifyAt, S.blankStreak = nil, 0
    -- A release is a decision to rebuild NOW - a quality change, a
    -- respawn, a dead target. The retry clock exists to space out FAILED
    -- creations and must not make a deliberate rebuild wait ten seconds.
    S.nextTryAt = 0.0
end

-- ---------------------------------------------------------------
-- Is the image DRAWABLE?
--
-- Not "did the call succeed" and, since 2.3.1, not "is there colour in it"
-- either. 2.3.0 checked the colours, found them, announced "live terrain
-- capture confirmed" - and the minimap was blank, because
-- `SCS_BaseColor` writes `float4(BaseColor, 0)` and Slate multiplies a
-- brush by its texture's alpha. A perfectly good picture at alpha zero is
-- an invisible one, and from Lua it looks identical to a working capture.
--
-- So a few seconds after the first capture the target is read back at four
-- spread-out points, and BOTH halves are measured:
--
--   no colour  -> nothing rendered (a component that never registered, or
--                 a source this build does not resolve). A load screen is
--                 black too, so this one is retried once before it counts.
--   no alpha   -> rendered, but nothing Slate will draw.
--
-- Either way the style's next source is tried, and the one that answers is
-- logged WITH THE PIXEL IT WAS JUDGED ON - because the next time this goes
-- wrong, that number is the whole diagnosis.
--
-- `ReadRenderTargetPixel` stalls the render thread, so this runs a handful
-- of times at the start of a session and never on a schedule.
-- ---------------------------------------------------------------
local VERIFY_DELAY = 3.0
local VERIFY_POINTS = { 0.30, 0.45, 0.60, 0.75 }
local FLOOR = 2                 -- 8-bit channel value counted as "nothing"

-- Give up on the current source and set up the next one in the chain.
local function stepSource(why, sample)
    local style = STYLES[S.styleId] or STYLES[0]
    local from = SOURCES[S.source]
    guard.log(string.format(
        "live terrain capture: %s %s (%s), trying the next source",
        from and from.name or ("source " .. tostring(S.source)), why, sample))
    S.step = S.step + 1
    S.blankStreak = 0
    if S.step > #style.chain then
        S.verified = false
        S.unavailable = true
        guard.log("no capture source on this build produced an image the "
            .. "minimap can draw (component created via " .. tostring(S.route)
            .. "); falling back to the game's world map texture. Set 'Terrain' "
            .. "to 2 to stop retrying.")
        release(true)
        return
    end
    -- The format follows the source, so the target is rebuilt too.
    release(true)
end

local function verify(now)
    if S.verified ~= nil or S.verifyAt == nil or now < S.verifyAt then return end
    S.verifyAt = nil
    local lib = renderLib()
    if lib == nil or S.rt == nil or not guard.alive(S.rt) then return end

    local px = S.rtPx or 512
    local bestRGB, bestA, sample = -1, -1, "?"
    for i = 1, #VERIFY_POINTS do
        local at = math.floor(px * VERIFY_POINTS[i])
        local c = guard.get(rawReadPixel, lib, S.rt, at, at)
        if c ~= nil then
            local okc, r, g, b, a = pcall(rawRGBA, c)
            if not okc or type(r) ~= "number" then
                -- The readback itself is unavailable on this build: no
                -- opinion, and never ask again. An UNREADABLE target must
                -- not be called blank - that would throw away a capture
                -- that is very probably fine.
                S.verified = true
                guard.log("live terrain capture: the target cannot be read back "
                    .. "on this build, so it is taken on trust")
                return
            end
            if type(a) ~= "number" then a = 255 end     -- no alpha to judge
            local rgb = math.max(r, g, b)
            if rgb > bestRGB or a > bestA then
                sample = string.format("rgba %d,%d,%d,%d", r, g, b, a)
            end
            if rgb > bestRGB then bestRGB = rgb end
            if a > bestA then bestA = a end
            if bestRGB > FLOOR and bestA > FLOOR then break end
        end
    end

    if bestRGB <= FLOOR then
        -- black. A loading screen is black as well, so give it one more go
        -- before blaming the source.
        S.blankStreak = S.blankStreak + 1
        if S.blankStreak < 2 then
            S.verifyAt = now + VERIFY_DELAY
            return
        end
        stepSource("rendered nothing", sample)
        return
    end

    if bestA <= FLOOR then
        stepSource("renders with no alpha, so Slate draws nothing", sample)
        return
    end

    S.verified = true
    local src = SOURCES[S.source]
    guard.log(string.format(
        "live terrain capture confirmed: %s, %dpx, %s style via %s [%s]",
        S.route or "?", px, (STYLES[S.styleId] or STYLES[0]).name,
        src and src.name or tostring(S.source), sample))
end

-- ---------------------------------------------------------------
-- Public
-- ---------------------------------------------------------------

-- The render target, or nil while there is no usable image.
function M.texture()
    if S.rt == nil then return nil end
    if S.verified == false then return nil end
    if not guard.alive(S.rt) then
        -- The target is gone but the component may not be: destroy it too,
        -- or every rebuild leaves another registered scene capture on the
        -- pawn. They capture nothing (bCaptureEveryFrame is false), which
        -- is exactly why a leak here would never announce itself.
        release(true)
        return nil
    end
    return S.rt
end

-- "There is a live image to draw." Deliberately does NOT try to create
-- anything - render.lua asks this on every frame.
function M.available()
    return S.capW ~= nil and M.texture() ~= nil
end

-- Bumped whenever `texture()` starts returning a DIFFERENT object, so
-- render.lua knows to put the new one on its brushes. Comparing the
-- objects themselves is not reliable: identity on reflected UObjects does
-- not survive a round trip through UE4SS.
function M.generation() return S.gen end

-- World centre and world width of the last capture. render.lua turns these
-- into the quad's position and size.
function M.centre() return S.cx, S.cy, S.capW end

function M.status()
    if S.unavailable then return "unavailable" end
    if S.comp == nil then return "not created" end
    if S.verified == false then return "blank" end
    local src = SOURCES[S.source]
    return string.format("%s, %dpx, %s, %d captures, %.2f ms avg / %.2f ms worst",
        tostring(S.route), S.rtPx or 0, src and src.name or "?", S.captures,
        S.captures > 0 and (S.costTotal / S.captures) * 1000.0 or 0.0,
        S.costWorst * 1000.0)
end

-- The quality or the style changed: the target and the component have to
-- be built again at the new settings. Cheap - it happens on a menu commit.
function M.reconfigure(cfg)
    if S.comp == nil then return end
    local px = resolutionFor(cfg)
    local styleId = styleFor(cfg)
    local height = heightFor(cfg)
    if px == S.rtPx and styleId == S.styleId and height == S.height then return end
    if styleId ~= S.styleId then
        -- a different style is a different chain: start it from the top,
        -- and let it be judged again
        S.step, S.verified, S.blankStreak = 1, nil, 0
    end
    release(true)
end

-- A world change: every UObject held here died with it, and a build that
-- refused to create the component during a load screen deserves another
-- go in the new world. Same forgiveness assets.forget() grants.
function M.forget()
    release(false)
    S.tries, S.nextTryAt, S.unavailable = 0, 0.0, false
    S.step = 1
    S.verified, S.blankStreak = nil, 0
    S.captures, S.costTotal, S.costWorst, S.reported = 0, 0.0, 0.0, false
end

function M.destroy()
    release(true)
end

-- ---------------------------------------------------------------
-- The tick
--
-- Called from movementTick with the player state that tick already read.
-- Returns true when a NEW image was captured, so the caller knows the
-- terrain quad has to be repositioned even if nothing else changed.
-- ---------------------------------------------------------------
function M.update(cfg, pawn, px, py, pz, zoom, now)
    if S.unavailable then return false end
    if pawn == nil or not guard.alive(pawn) then return false end
    if type(pz) ~= "number" then return false end

    local wantPx = resolutionFor(cfg)
    local styleId, style = styleFor(cfg)
    local height = heightFor(cfg)
    local sourceId, source = sourceFor(style)
    if source == nil then return false end

    -- the component and the target both die with the pawn or the world
    if S.comp ~= nil and not guard.alive(S.comp) then release(false) end
    if S.rt ~= nil and not guard.alive(S.rt) then release(true) end

    if S.comp == nil or S.rt == nil then
        if now < S.nextTryAt then return false end
        if S.tries >= MAX_TRIES then
            S.unavailable = true
            guard.log("could not build the live terrain capture after "
                .. MAX_TRIES .. " attempts; the minimap will use the game's "
                .. "world map texture instead")
            return false
        end
        S.tries = S.tries + 1
        S.nextTryAt = now + RETRY_SECONDS

        if S.rt == nil then
            local world = guard.get(rawWorldOf, pawn)
            if world == nil then return false end
            local rt, why = makeRenderTarget(world, wantPx, source.format)
            if rt == nil then
                guard.log("live terrain capture: " .. tostring(why))
                return false
            end
            S.rt, S.rtPx = rt, wantPx
            S.gen = S.gen + 1
        end
        if S.comp == nil then
            local comp, route, attached = createComponent(pawn)
            if comp == nil then
                guard.log("live terrain capture: " .. tostring(route))
                return false
            end
            S.comp, S.route, S.attached = comp, route, attached == true
            S.trackChecked = false
        end
        configure(styleId, style, sourceId, height)
        S.tries = 0
        S.cx, S.cy, S.capW, S.capZoom = nil, nil, nil, nil
        S.orthoW = nil
        S.verifyAt = now + VERIFY_DELAY
    elseif styleId ~= S.styleId or height ~= S.height or wantPx ~= S.rtPx
           or sourceId ~= S.source then
        -- a setting changed under us without a menu commit (a hand-edited
        -- file, or the defaults moving); rebuild rather than drift
        release(true)
        return false
    end

    verify(now)
    if S.unavailable then return false end

    -- ---------------------------------------------------------------
    -- IS A CAPTURE DUE? Cheapest test first.
    --
    -- Note what is NOT here any more: "the zoom changed". 2.3.1 recaptured
    -- on any change at all to `zoom * OVERSCAN`, which with autozoom on is
    -- very nearly every tick, and - because it also rewrote OrthoWidth to
    -- match every time - was what made the terrain ignore the zoom
    -- entirely (see the OVERSCAN comment). A capture is now retaken only
    -- when the zoom has moved far enough that the existing image genuinely
    -- cannot serve, and `capW` is left alone in between.
    -- ---------------------------------------------------------------
    local rotate = cfg.rotateWithCamera and true or false
    local due = false
    if S.capW == nil or S.capZoom == nil then
        due = true
    else
        local interval = (tonumber(cfg.captureIntervalMs) or 250) / 1000.0
        if interval < MIN_INTERVAL then interval = MIN_INTERVAL end
        local age = now - S.capturedAt
        if age >= MIN_INTERVAL then
            if zoom > zoomCeiling(S.capW, rotate) then
                due = true              -- zoomed out past what we captured
            elseif zoom < S.capZoom * ZOOM_BAND_LOW then
                due = true              -- zoomed in far enough to go soft
            elseif age >= interval then
                -- far enough off centre that the overscan is running out?
                local dx, dy = px - S.cx, py - S.cy
                local slack = S.capW * MOVE_SLACK
                if (dx * dx + dy * dy) > (slack * slack) then
                    due = true
                elseif age >= IDLE_REFRESH then
                    due = true
                end
            end
        end
    end
    if not due then return false end

    -- The window this capture will cover. Computed HERE, in the branch that
    -- actually captures, and nowhere else - an earlier draft updated the
    -- captured-window fields every tick regardless of whether a capture
    -- happened, which desyncs the centre and span render.lua is told about
    -- from the pixels that are really in the target.
    local capW = zoom * OVERSCAN

    -- THE PLACEMENT CALL ONLY HAPPENS WHEN SOMETHING HAS TO BE MOVED BY
    -- HAND. On the attached route the engine has already carried the
    -- component with the pawn, and calling K2_SetWorldLocationAndRotation
    -- anyway is what killed the game after seventeen minutes - see the
    -- note above rawSetWorldBoth. Unattached routes still need it.
    if S.mustPlace or not S.attached then
        if not place(S.comp, px, py, pz + height) then return false end
    end
    if S.orthoW ~= capW then
        guard.get(rawSetOrtho, S.comp, capW)
        S.orthoW = capW
    end

    local started = os.clock()
    local ok = pcall(rawCaptureScene, S.comp)
    local cost = os.clock() - started
    if not ok then return false end

    -- Did the attachment actually carry it? Asked ONCE per component, right
    -- after its first capture, because a relative-transform property write
    -- that silently did not take would leave the camera at the pawn's feet
    -- looking sideways - a picture verify() would happily accept, since it
    -- only measures colour and alpha.
    if S.attached and not S.mustPlace and not S.trackChecked then
        S.trackChecked = true
        local tracking = trackingWorks(S.comp, px, py)
        if tracking == false then
            S.mustPlace = true
            guard.log("live terrain capture: the attached component is not "
                .. "following the pawn on this build, so it will be positioned "
                .. "by hand each capture. Expect [push_weakobjectproperty] "
                .. "warnings in this log; they come from the engine's hit-result "
                .. "parameter and are why the call is avoided when possible.")
        end
    end

    S.cx, S.cy, S.capW, S.capZoom = px, py, capW, zoom
    S.capturedAt = now
    S.captures = S.captures + 1
    S.costTotal = S.costTotal + cost
    if cost > S.costWorst then S.costWorst = cost end

    -- One line, once, after enough captures to mean something. This is the
    -- number that decides whether the second render is affordable on a
    -- given machine, and there is no other way to see it.
    if not S.reported and S.captures >= 40 then
        S.reported = true
        guard.log("live terrain capture: " .. M.status())
    end
    return true
end

-- test hooks
function M.overscan() return OVERSCAN end
function M.resolutionFor(cfg) return resolutionFor(cfg) end

return M
