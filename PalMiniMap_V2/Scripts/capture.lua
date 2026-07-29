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
local SCS_FINAL_COLOR_LDR = 2
local SCS_BASE_COLOR      = 7
-- ECameraProjectionMode
local PROJECTION_ORTHO    = 1
-- ETextureRenderTargetFormat
local RTF_RGBA8           = 2
local RTF_RGBA8_SRGB      = 3
-- EAttachmentRule
local ATTACH_KEEP_RELATIVE = 0

local CAPTURE_CLASS = "/Script/Engine.SceneCaptureComponent2D"
local RENDER_LIB    = "/Script/Engine.Default__KismetRenderingLibrary"

-- THE FORMAT FOLLOWS THE SOURCE, and getting the pair wrong shows up as a
-- washed-out or a crushed minimap rather than as an error.
--   * SCS_BaseColor writes LINEAR values, so the render target should be
--     sRGB: the hardware encodes on write and Slate decodes on read.
--   * SCS_FinalColorLDR has already been through the tonemapper and is
--     sRGB-encoded, so an sRGB target would encode it a second time.
local STYLES = {
    [0] = { source = SCS_BASE_COLOR,      format = RTF_RGBA8_SRGB,
            name = "flat (base colour, no lighting or weather)" },
    [1] = { source = SCS_FINAL_COLOR_LDR, format = RTF_RGBA8,
            name = "lit (the world as the game draws it)" },
}

-- `mapQuality` meant "render target resolution" in 1.x and nothing at all
-- in 2.0-2.2 (there was no render). It means resolution again.
local RESOLUTION = { [0] = 256, [1] = 384, [2] = 512, [3] = 768 }

-- How much wider than the visible minimap the capture is.
--
-- 1.414 is the floor and it is not a taste decision: when the map rotates
-- with the camera, a SQUARE minimap's corners sweep a circle of diameter
-- `zoom * sqrt(2)`, and anything not captured shows as an empty wedge
-- turning with the player. The rest is movement headroom - at 1.55 the
-- image stays valid for about 1500 world units of travel at the default
-- zoom, i.e. comfortably longer than the gap between two captures even
-- when flying.
local OVERSCAN = 1.55

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

    cx = nil, cy = nil,     -- world centre of the last capture
    capW = nil,             -- world units across the last capture
    capturedAt = 0.0,

    route = nil,            -- how the component was created, for the log
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

-- POSITIONING: struct-valued FUNCTION ARGUMENTS are proven on this build
-- (render.lua has passed vector tables to SetPosition since 2.0), struct
-- PROPERTY writes are not. So the camera is placed with a call, and the
-- relative-transform properties below are only belt and braces for the
-- attached case. Two call shapes, because a build that reflects
-- K2_SetWorldLocationAndRotation's out parameter differently still has the
-- two single-axis setters.
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

-- Best effort, and quiet: on the attached route these keep the camera
-- pointing down between the explicit placements above, and on a build
-- where struct property writes do not take, place() is already doing the
-- whole job. Both the member-write and the whole-struct forms are tried
-- because UE4SS builds differ on which one takes.
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
local function rawRGB(c) return c.R, c.G, c.B end
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
        return comp, "AddComponentByClass (attached)"
    end

    -- same call without the attachment: the component is positioned by
    -- hand every capture instead
    comp = guard.get(rawAddComponent, owner, class, true)
    if comp ~= nil and guard.alive(comp) then
        return comp, "AddComponentByClass (unattached)"
    end

    comp = guard.get(StaticConstructObject, class, owner)
    if comp ~= nil and guard.alive(comp) then
        local root = guard.get(rawRoot, owner)
        if root ~= nil and guard.alive(root) then
            guard.get(rawAttach, comp, root)
        end
        return comp, "StaticConstructObject (may not be registered)"
    end

    return nil, "no route constructed a capture component"
end

local function styleFor(cfg)
    local id = tonumber(cfg.captureStyle) or 0
    if STYLES[id] == nil then id = 0 end
    return id, STYLES[id]
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

local function configure(styleId, style, height)
    local comp = S.comp
    guard.get(rawSetManual, comp)
    guard.get(rawSetSource, comp, style.source)
    guard.get(rawSetOrtho, comp, 10000.0)
    guard.get(rawAbsoluteRotation, comp)
    if not pcall(rawRelativeMembers, comp, height) then
        pcall(rawRelativeAssign, comp, height)
    end
    if S.rt ~= nil then guard.get(rawSetTarget, comp, S.rt) end
    S.styleId, S.height = styleId, height
end

-- Let go of everything. Called on a world change, on a quality change, and
-- whenever the component or the target turns out to be dead.
local function release(destroyComponent)
    if destroyComponent and S.comp ~= nil and guard.alive(S.comp) then
        guard.get(rawDestroy, S.comp)
    end
    S.comp, S.rt = nil, nil
    S.rtPx, S.styleId, S.height = nil, nil, nil
    S.cx, S.cy, S.capW = nil, nil, nil
    S.verifyAt, S.blankStreak = nil, 0
    -- A release is a decision to rebuild NOW - a quality change, a
    -- respawn, a dead target. The retry clock exists to space out FAILED
    -- creations and must not make a deliberate rebuild wait ten seconds.
    S.nextTryAt = 0.0
end

-- ---------------------------------------------------------------
-- Is the image real?
--
-- The rule this mod keeps learning: a call shape that returns without an
-- error is not proof it did anything. A capture component that was never
-- registered, or a CaptureSource this build does not resolve, produces a
-- render target full of the clear colour - and from Lua that is
-- indistinguishable from a working capture until somebody looks at the
-- screen.
--
-- So a few seconds after the first capture the target is read back at four
-- spread-out points. If they are all the clear colour twice running, the
-- capture is declared blank, and the caller goes back to the world map
-- texture with a line in the log saying why.
--
-- `ReadRenderTargetPixel` stalls the render thread, so this happens at
-- most twice per session and never on a schedule.
-- ---------------------------------------------------------------
local VERIFY_DELAY = 3.0
local VERIFY_POINTS = { 0.30, 0.45, 0.60, 0.75 }

local function verify(now)
    if S.verified ~= nil or S.verifyAt == nil or now < S.verifyAt then return end
    S.verifyAt = nil
    local lib = renderLib()
    if lib == nil or S.rt == nil or not guard.alive(S.rt) then return end

    local px = S.rtPx or 512
    local lit = false
    for i = 1, #VERIFY_POINTS do
        local at = math.floor(px * VERIFY_POINTS[i])
        local c = guard.get(rawReadPixel, lib, S.rt, at, at)
        if c ~= nil then
            local okc, r, g, b = pcall(rawRGB, c)
            if not okc or type(r) ~= "number" then
                -- the readback itself is unavailable: no opinion, and never
                -- ask again. An unreadable target must not be called blank.
                S.verified = true
                return
            end
            if r > 2 or g > 2 or b > 2 then lit = true; break end
        end
    end

    if lit then
        S.verified = true
        guard.log(string.format(
            "live terrain capture confirmed: %s, %dpx, %s", S.route or "?",
            px, (STYLES[S.styleId] or STYLES[0]).name))
        return
    end

    S.blankStreak = S.blankStreak + 1
    if S.blankStreak < 2 then
        S.verifyAt = now + VERIFY_DELAY   -- a load screen is black too
        return
    end
    S.verified = false
    S.unavailable = true
    guard.log("the live terrain capture renders nothing on this build (created via "
        .. tostring(S.route) .. "); falling back to the game's world map texture. "
        .. "Set 'Map source' to 2 to stop retrying.")
    release(true)
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
    return string.format("%s, %dpx, %d captures, %.2f ms avg / %.2f ms worst",
        tostring(S.route), S.rtPx or 0, S.captures,
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
    release(true)
end

-- A world change: every UObject held here died with it, and a build that
-- refused to create the component during a load screen deserves another
-- go in the new world. Same forgiveness assets.forget() grants.
function M.forget()
    release(false)
    S.tries, S.nextTryAt, S.unavailable = 0, 0.0, false
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
            local rt, why = makeRenderTarget(world, wantPx, style.format)
            if rt == nil then
                guard.log("live terrain capture: " .. tostring(why))
                return false
            end
            S.rt, S.rtPx = rt, wantPx
            S.gen = S.gen + 1
        end
        if S.comp == nil then
            local comp, route = createComponent(pawn)
            if comp == nil then
                guard.log("live terrain capture: " .. tostring(route))
                return false
            end
            S.comp, S.route = comp, route
        end
        configure(styleId, style, height)
        S.tries = 0
        S.cx, S.cy, S.capW = nil, nil, nil
        S.verifyAt = now + VERIFY_DELAY
    elseif styleId ~= S.styleId or height ~= S.height or wantPx ~= S.rtPx then
        -- a setting changed under us without a menu commit (a hand-edited
        -- file, or the defaults moving); rebuild rather than drift
        release(true)
        return false
    end

    verify(now)
    if S.unavailable then return false end

    -- Is a capture due? Three reasons, cheapest test first.
    local capW = zoom * OVERSCAN
    local due = false
    if S.capW == nil then
        due = true
    else
        local interval = (tonumber(cfg.captureIntervalMs) or 250) / 1000.0
        if interval < MIN_INTERVAL then interval = MIN_INTERVAL end
        local age = now - S.capturedAt
        if age >= MIN_INTERVAL then
            if capW ~= S.capW then
                due = true                      -- the zoom changed
            elseif age >= interval then
                -- far enough off centre that the overscan is running out?
                local dx, dy = px - S.cx, py - S.cy
                local slack = capW * 0.04
                if (dx * dx + dy * dy) > (slack * slack) then
                    due = true
                elseif age >= IDLE_REFRESH then
                    due = true
                end
            end
        end
    end
    if not due then return false end

    -- Place it, THEN capture. On the attached route the engine has already
    -- put the component roughly here; this makes it exact, and on the
    -- unattached route it is the only thing that positions the camera at
    -- all. One reflection call per capture, four times a second.
    if not place(S.comp, px, py, pz + height) then return false end
    if capW ~= S.capW then guard.get(rawSetOrtho, S.comp, capW) end

    local started = os.clock()
    local ok = pcall(rawCaptureScene, S.comp)
    local cost = os.clock() - started
    if not ok then return false end

    S.cx, S.cy, S.capW = px, py, capW
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
