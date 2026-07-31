-- =====================================================================
-- render.lua - the minimap widget
--
-- WHAT VERSION 2 KEPT AND WHAT 2.3 GAVE BACK.
--
-- The 1.x mod re-rendered the world from above into a render target EVERY
-- FRAME and drew its icons as StaticMeshComponents attached to the actors
-- they marked. That produced every serious bug the mod ever had: a
-- permanent GPU cost, FPS decay as icon components piled up, and two hard
-- crashes from dereferencing icons whose target actor had been destroyed.
--
-- 2.0 threw both out and drew the game's own world map TEXTURE as one
-- quad. That fixed the crashes and the cost, and it had one flaw nothing
-- could paper over: the texture is a picture of the main island, so the
-- great tree at the edge of the world and the inside of every dungeon had
-- no map at all.
--
-- 2.3 brings the second render back - and ONLY the second render. See
-- capture.lua: it is orthographic, it is throttled to a few frames a
-- second instead of all of them, it stops entirely when the minimap is
-- hidden, and it is one component on the player's own pawn. The icons stay
-- exactly as they were: pooled UMG Images positioned by arithmetic,
-- nothing attached to a world actor, no reference to one held across a
-- frame.
--
-- This file no longer cares which of the two the terrain came from. It is
-- handed a texture, the world point that texture is centred on and how
-- many world units it spans, and the quad arithmetic is the same either
-- way.
--
-- Every setter here goes through reflection, which is not free, so the
-- update path writes only what actually CHANGED. Position is the only
-- property that genuinely changes every frame.
-- =====================================================================

local guard = require("guard")
local worldmap = require("worldmap")
local assets = require("assets")
local capture = require("capture")

local M = {}

-- ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden, 3 HitTestInvisible
local VIS_SHOW, VIS_HIDE = 3, 1
-- EWidgetClipping: 0 Inherit, 1 ClipToBounds
local CLIP_BOUNDS = 1

local MAP_TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
-- Not a game asset: a path this mod owns, so assets.lua resolves it to
-- icons/T_minimap_frame.png and never asks the package loader for it. See
-- tools/make_frame.py, and tools/check_frame.py for why RIM/INSET are these.
local FRAME_TEXTURE = "/PalMiniMap/T_minimap_frame.T_minimap_frame"
local RIM   = 0.038     -- opaque bezel width, fraction of the diameter
local INSET = 0.018     -- how much smaller the strip disc is than the widget
local PLAYER_TEXTURE = "/Game/Pal/Texture/UI/InGame/T_icon_map_player.T_icon_map_player"
local VIEW_CONE_TEXTURE = "/PalMiniMap/T_view_cone.T_view_cone"
-- Duplicated from sources.lua on purpose: this is the marker EVERY icon
-- falls back to while its own portrait is still queued, so build() loads
-- it up front rather than letting the draw loop discover it is missing.
local MEMBER_TEXTURE = "/Game/Pal/Texture/UI/InGame/T_icon_map_member.T_icon_map_member"

local S = {
    widget = nil, tree = nil,
    frame = nil, frameSlot = nil,
    viewport = nil,
    backdrop = nil, backdropSlot = nil,
    rim = nil, rimSlot = nil,
    mapImage = nil, mapSlot = nil, mapPx = nil,
    mapTex = nil, mapTexPath = nil,
    -- Which terrain image the brushes are currently wearing. A number,
    -- not the object: identity on a reflected UObject does not survive a
    -- round trip through UE4SS, so "is this still the same texture" has to
    -- be asked with a counter that only ever changes when the answer is no.
    terrainGen = nil,
    bands = nil,            -- circular mode: list of clipped strips
    viewCone = nil, viewConeSlot = nil,
    viewConeSize = nil, viewConeAngle = nil,
    viewConeOpacity = nil, viewConeShown = nil, viewConeReady = false,
    playerIcon = nil, playerSlot = nil,
    playerSize = nil, playerAngle = nil,
    pool = {},              -- { image=, slot=, inUse=, tex=, tint=, angle=, size= }
    reportedSize = false,
    visible = false,
    builtSize = nil,
    builtPool = nil,
    builtCircular = nil,
    rimSize = nil,
    mapAngle = nil,
    viewW = nil, viewH = nil,
    editMode = false,
    editBorder = nil, editSlot = nil,
}

-- Viewport size, remembered. applyLayout used to be called from build()
-- with no size at all, so a negative (edge-relative) coordinate fell
-- through to the 1920x1080 fallback.
function M.setViewport(w, h)
    if type(w) == "number" and w > 0 and type(h) == "number" and h > 0 then
        S.viewW, S.viewH = w, h
        return true
    end
    return false
end

-- Class lookups are memoised. A rebuild constructs up to 260 widgets and
-- every one of them used to do its own StaticFindObject on the same half
-- dozen class paths - a name lookup through the whole object hierarchy,
-- hundreds of times, on the game thread, while the player was still
-- clicking in the settings window.
local classCache = {}

local function cls(path)
    local hit = classCache[path]
    if hit ~= nil and guard.alive(hit) then return hit end
    local obj = guard.get(StaticFindObject, path)
    if obj and guard.alive(obj) then
        classCache[path] = obj
        return obj
    end
    classCache[path] = nil
    return nil
end

local function construct(classPath, outer)
    local class = cls(classPath)
    if class == nil then return nil end
    return guard.get(StaticConstructObject, class, outer)
end

-- ---------------------------------------------------------------
-- Textures
--
-- All of the loading, caching, throttling and streaming-flag work now
-- lives in assets.lua - see the long note at the top of that file for why
-- it had to be pulled out of here. What is left is which paths this file
-- asks for, and the rule that on a per-frame path it may only ever ASK:
-- `assets.get` never blocks, and returns nil until the texture is in.
-- ---------------------------------------------------------------
-- Which terrain-brush setter took, logged ONCE, and whether NEITHER did.
--
-- DECLARED HERE, ABOVE wantsLive, ON PURPOSE. Lua resolves an undeclared
-- name to a global, so a `local` further down the file would leave
-- `liveBrushBroken` reading as nil in wantsLive with no warning of any
-- kind - the same ordering trap that silently disabled the chest
-- `collected` readers in 2.2.19.
local brushRoute = nil
local liveBrushBroken = false

local function mapTexturePath(cfg)
    local override = cfg and cfg.terrainTexture
    if type(override) == "string" and override ~= "" then return override end
    return MAP_TEXTURE
end

-- ---------------------------------------------------------------
-- WHICH TERRAIN. One checkbox, `liveTerrain`, plus one hard limit.
--
-- THE LIVE RENDER CAN ONLY SHOW WHAT THE GAME HAS STREAMED IN. Zoomed
-- right out - megazoom is 260 000 world units across, more than two
-- kilometres - most of what should be in frame is not loaded, so the
-- capture comes back mostly empty while the painted world map shows the
-- whole island perfectly. Zoomed in, the opposite is true: the capture is
-- current, shows buildings and works in places the texture has never
-- heard of.
--
-- So with the box ticked the live render is used everywhere EXCEPT past
-- `liveZoomMax`, where there would be nothing to see - and it is used
-- past that limit anyway when the player is somewhere the map texture
-- does not cover at all, because there a mostly-empty capture still beats
-- a picture of the wrong place. That case (regionContaining == nil) is
-- every dungeon and the far edges of the world.
-- ---------------------------------------------------------------
local function wantsLive(cfg, x, y, zoom)
    if not cfg.liveTerrain then return false end
    if liveBrushBroken then return false end
    if not capture.available() then return false end
    if worldmap.regionContaining(x, y) == nil then return true end
    return zoom <= (tonumber(cfg.liveZoomMax) or 60000)
end

-- Re-apply the quality setting. Called when the menu changes it, never
-- periodically. It means two different things now and both are handled
-- here: which mip of the map texture is pinned resident, and how big the
-- live render's target is.
function M.applyQuality(cfg)
    assets.setQuality(cfg.mapQuality, mapTexturePath(cfg))
    capture.reconfigure(cfg)
end

-- One-off diagnostic: how big the terrain texture really is, and how far
-- it is being stretched. If the terrain still looks soft after forcing the
-- mips resident, this line is the evidence - the source is simply not
-- detailed enough, and the answer is `terrainTexture` pointing at a better
-- asset, not another setting.
local function reportTextureSize(tex, cfg, imagePx, size)
    if S.reportedSize or tex == nil then return end
    -- bounded retries rather than a one-shot flag: a build without
    -- Blueprint_GetSizeX would otherwise burn a reflection call every
    -- frame forever, and a one-shot flag would give up before the texture
    -- had finished streaming in
    S.sizeTries = (S.sizeTries or 0) + 1
    if S.sizeTries > 5 then S.reportedSize = true; return end
    local sx = guard.get(function() return tex:Blueprint_GetSizeX() end)
    local sy = guard.get(function() return tex:Blueprint_GetSizeY() end)
    if type(sx) ~= "number" or sx <= 0 then return end
    S.reportedSize = true
    -- how many source texels land on the visible part of the minimap
    local texels = sx * (size / imagePx)
    guard.log(string.format(
        "terrain texture %dx%d; %d px of minimap shows %.0f texels (%.1fx magnification, quality %d)",
        math.floor(sx), math.floor(sy or sx), math.floor(size), texels,
        size / math.max(texels, 0.001), cfg.mapQuality or 0))
end

-- ---------------------------------------------------------------
-- Reflection setters, allocation-free
--
-- The obvious way to write these is
--     guard.get(function() slot:SetPosition({ X = x, Y = y }) end)
-- and that allocates TWO garbage objects per call: the closure and the
-- vector table. A single frame repositions the map (or 24 clipped strips),
-- the player marker and up to 96 icons, ten times a second - several
-- thousand throwaway objects a second, all of them collected on the game
-- thread. That was a large part of the 2.0.8 stuttering.
--
-- So: hoisted functions called through pcall(fn, args), and ONE shared
-- vector table refilled in place. UE4SS reads X/Y out of it during the
-- call and does not keep a reference, so reuse is safe.
-- ---------------------------------------------------------------
local VEC = { X = 0.0, Y = 0.0 }

local function rawSetPosition(slot, x, y)
    VEC.X = x; VEC.Y = y
    slot:SetPosition(VEC)
end

local function rawSetSize(slot, w, h)
    VEC.X = w; VEC.Y = h
    slot:SetSize(VEC)
end

local function rawSetPivot(w, x, y)
    VEC.X = x; VEC.Y = y
    w:SetRenderTransformPivot(VEC)
end

local function rawSetAngle(w, a) w:SetRenderTransformAngle(a) end
local function rawSetBrush(w, tex) w:SetBrushFromTexture(tex, false) end
-- A render target is a UTextureRenderTarget2D, NOT a UTexture2D, so
-- SetBrushFromTexture's parameter type rejects it. SetBrushResourceObject
-- takes any UObject and is what the live terrain has to go through; the
-- ordinary texture path keeps the typed setter, which also sets the
-- brush's image size for it.
local function rawSetBrushObject(w, tex) w:SetBrushResourceObject(tex) end

local function setTerrainBrush(w, tex, live)
    if live then
        if pcall(rawSetBrushObject, w, tex) then
            if brushRoute ~= "resource" then
                brushRoute = "resource"
                guard.log("live terrain drawn via SetBrushResourceObject")
            end
            return true
        end
        if pcall(rawSetBrush, w, tex) then
            if brushRoute ~= "texture" then
                brushRoute = "texture"
                guard.log("live terrain drawn via SetBrushFromTexture "
                    .. "(SetBrushResourceObject was refused)")
            end
            return true
        end
        if not liveBrushBroken then
            liveBrushBroken = true
            guard.log("neither SetBrushResourceObject nor SetBrushFromTexture "
                .. "would take the render target, so the live terrain cannot be "
                .. "drawn on this build; using the game's world map texture")
        end
        return false
    end
    if pcall(rawSetBrush, w, tex) then return true end
    return pcall(rawSetBrushObject, w, tex)
end
local function rawSetTint(w, c) w:SetColorAndOpacity(c) end
local function rawSetVisibility(w, v) w:SetVisibility(v) end

local function setVisible(w, on)
    if w == nil then return end
    pcall(rawSetVisibility, w, on and VIS_SHOW or VIS_HIDE)
end

local function addToCanvas(canvas, child)
    local slot = guard.get(function() return canvas:AddChildToCanvas(child) end)
    if slot == nil then
        slot = guard.get(function() return canvas:AddChild(child) end)
    end
    if slot ~= nil then
        guard.get(function() slot:SetAutoSize(false) end)
        guard.get(function() slot:SetAlignment({ X = 0.0, Y = 0.0 }) end)
    end
    return slot
end

local function setPos(slot, x, y)
    if slot == nil then return end
    pcall(rawSetPosition, slot, x, y)
end

local function setSize(slot, w, h)
    if slot == nil then return end
    pcall(rawSetSize, slot, w, h)
end

local function place(slot, x, y, w, h)
    setPos(slot, x, y)
    if w ~= nil then setSize(slot, w, h) end
end

-- Effective zoom, folding in the two zoom modes 1.x had:
--   * megazoom (F1) replaces the zoom outright;
--   * autozoom widens the view as the player moves faster, so walking is
--     tight and flying shows more ground.
-- `speed` is centimetres per second, straight from the pawn's velocity.
function M.effectiveZoom(cfg, speed)
    local zoom
    if cfg.megazoomActive then
        zoom = cfg.megazoom
    else
        zoom = cfg.zoom
        if cfg.autozoom and type(speed) == "number" then
            local mult = cfg.autozoomWalk
            if speed > 1100 then mult = cfg.autozoomFly
            elseif speed > 450 then mult = cfg.autozoomRun end
            zoom = zoom * mult
        end
        if zoom < cfg.zoomMin then zoom = cfg.zoomMin end
        if zoom > cfg.zoomMax * 4 then zoom = cfg.zoomMax * 4 end
    end
    -- a hand-edited settings file must never be able to divide by zero
    if type(zoom) ~= "number" or zoom < 500 then zoom = 500 end
    return zoom
end

-- Every mark kind that has a budget must be counted here, or the pool is too
-- small and the draw loop silently drops whatever came last. This doubles as
-- the rebuild trigger: needsRebuild compares the capacity, so a new budget
-- key becomes a rebuild key for free.
local function poolCapacity(cfg)
    -- Every kind sources.lua can emit has to be counted here, or the draw
    -- loop runs out of pool and drops whatever was emitted LAST without
    -- saying so. Other players were missing from this sum until 2.3.3,
    -- which cost the human NPCs their icons on any populated server.
    return (cfg.maxPalIcons or 48) + (cfg.maxPoiIcons or 48)
         + (cfg.maxNpcIcons or 24) + (cfg.maxPlayerIcons or 16)
end

-- ---------------------------------------------------------------
-- Build / teardown
-- ---------------------------------------------------------------
function M.isBuilt() return S.widget ~= nil and guard.alive(S.widget) end

function M.destroy()
    if S.widget ~= nil and guard.alive(S.widget) then
        guard.get(function() S.widget:RemoveFromParent() end)
    end
    S.widget, S.tree = nil, nil
    S.frame, S.frameSlot, S.viewport = nil, nil, nil
    S.backdrop, S.backdropSlot = nil, nil
    S.mapImage, S.mapSlot, S.mapTex = nil, nil, nil
    S.mapPx, S.mapAngle = nil, nil
    S.terrainGen = nil
    S.bands = nil
    S.rim, S.rimSlot, S.rimSize = nil, nil, nil
    S.editBorder, S.editSlot = nil, nil
    S.viewCone, S.viewConeSlot = nil, nil
    S.viewConeSize, S.viewConeAngle = nil, nil
    S.viewConeOpacity, S.viewConeShown, S.viewConeReady = nil, nil, false
    S.playerIcon, S.playerSlot = nil, nil
    S.playerSize, S.playerAngle = nil, nil
    S.pool = {}
    S.visible = false
    S.builtSize, S.builtPool, S.builtCircular = nil, nil, nil
end

local BACKDROP = { R = 0.02, G = 0.03, B = 0.05, A = 0.55 }
local VIEW_CONE_TINT = { R = 0.28, G = 0.82, B = 1.0, A = 0.22 }

-- ---------------------------------------------------------------
-- The circular shape
--
-- 2.0.5 called itself circular but only drew a round decal ON TOP of a
-- square map, so the terrain stayed square and the corners still showed.
-- Making it genuinely round is harder than it sounds: Slate clips to
-- axis-aligned RECTANGLES, and a real alpha mask needs a material, which
-- cannot be authored from Lua. Covering the corners with an opaque colour
-- is not an option either - outside the circle you must see the GAME, not
-- a black box.
--
-- So the disc is built out of horizontal strips: each strip is its own
-- ClipToBounds canvas, exactly as wide as the circle is at that height,
-- and each holds its own copy of the map quad shifted to line up with its
-- neighbours. The union of the strips IS the disc, and everything outside
-- it was never drawn, so the game shows through.
--
-- The strips are spaced by ANGLE, not by height, which is what makes this
-- affordable: the curvature is concentrated at the top and bottom, so
-- uniform angle steps put thin strips exactly where the outline turns and
-- tall ones down the sides where it barely moves. Each strip is as wide as
-- the circle at its MIDDLE angle - taking the narrower of its two edges
-- instead would collapse the polar strips to nothing and flatten the top
-- and bottom of the disc.
--
-- Honest about the approximation: the worst radial error is about
-- R * pi / (4n) - measured, +-4 px on a 240 px minimap with 24 strips. THE
-- STAIRCASE IS VISIBLE, and 2.2.3 is the admission that no strip count fixes
-- it: optimal (equal-ripple) spacing buys 0.1 px, and sub-pixel would need
-- ~150 strips, each of which is a Slate clipping zone and therefore a draw
-- call EVERY FRAME.
--
-- So the outline is not made accurate, it is COVERED. `icons/
-- T_minimap_frame.png` is a shipped image whose inner edge is a real
-- supersampled circle and whose opaque bezel (RIM) is wider than the error;
-- the strips are inset (INSET) so none of them bulges past its outer edge.
-- What the player sees is the frame's inner edge, which is exact at any
-- size. `tools/check_frame.py` measures the margin across the whole 120-480
-- range the menu allows, because getting this wrong is silent - it shows up
-- as a notch of terrain on the rim at some sizes and not others.
--
-- There is no per-strip backdrop: the map texture is opaque, so the dark
-- backdrop only ever shows outside the map bounds, and in circular mode
-- letting the game show through there is the correct look anyway.
--
-- Cost: the strips are positioned once at build time; per frame it is one
-- SetPosition each, and the GPU still only rasterises the pixels inside
-- the disc.
-- ---------------------------------------------------------------
-- Each strip is its own Slate clipping zone, and a clipping zone change
-- breaks batching - so every strip is one more draw call EVERY frame, not
-- every update. 2.0.7 asked for a ~3 px outline error and got 31 strips;
-- ~4 px costs 24 and is not tellable apart on a minimap once the game's
-- circular art is drawn over the seam.
-- The floor is 24, not 16: below that the staircase gets wider than the
-- frame's bezel and terrain steps out past it. `tools/check_frame.py`
-- reproduces this function and measures the margin at every size the menu
-- allows - change either number there and it will tell you.
local function bandCount(size)
    local n = math.floor(size * 0.10 + 0.5)
    if n < 24 then n = 24 elseif n > 36 then n = 36 end
    return n
end

-- The strips are laid out on a radius slightly SMALLER than the widget
-- (INSET) while staying centred in it. Without that, a strip corner reaches
-- past the widget's own radius - the union of rectangles bulges outside the
-- circle it approximates - and that bulge would sit outside the frame's
-- bezel, which is the one place nothing can cover it.
local function buildBands(size)
    local n = bandCount(size)
    local R = size * 0.5
    local r = R - INSET * size
    S.bands = {}
    for k = 0, n - 1 do
        local t0 = (k / n) * math.pi
        local t1 = ((k + 1) / n) * math.pi
        local y0 = R - r * math.cos(t0)
        local y1 = R - r * math.cos(t1)
        local w = r * math.sin((t0 + t1) * 0.5)
        local h = y1 - y0
        if w > 0.5 and h > 0.5 then
            local panel = construct("/Script/UMG.CanvasPanel", S.tree)
            if panel ~= nil then
                local slot = addToCanvas(S.frame, panel)
                place(slot, R - w, y0, w * 2.0, h)
                guard.get(function() panel:SetClipping(CLIP_BOUNDS) end)
                local img = construct("/Script/UMG.Image", S.tree)
                if img ~= nil then
                    local islot = addToCanvas(panel, img)
                    setVisible(img, true)
                    S.bands[#S.bands + 1] = {
                        image = img, slot = islot,
                        x = R - w, y = y0,        -- strip origin, frame-local
                    }
                end
            end
        end
    end
    if #S.bands == 0 then S.bands = nil end
    return S.bands ~= nil
end

function M.build(pc, cfg)
    M.destroy()
    -- The four textures the minimap cannot be drawn without are fetched
    -- synchronously, HERE, once, while the widget is being constructed
    -- anyway. Everything else - 137 possible species portraits - goes
    -- through the throttled queue and shows the member marker until it
    -- arrives. That split is what keeps the loading cost off the frame.
    assets.setQuality(cfg.mapQuality, mapTexturePath(cfg))
    -- Skipped only when the texture can never be reached: the world map is
    -- tens of megabytes and this is a SYNCHRONOUS load, so paying for it
    -- to draw nothing is the most expensive thing in the whole build. With
    -- the live render on it is still the fallback above `liveZoomMax`, so
    -- it is only genuinely dead weight when that limit is at or past the
    -- furthest the player can zoom.
    local liveOnly = cfg.liveTerrain
        and (tonumber(cfg.liveZoomMax) or 0) >= (tonumber(cfg.megazoom) or 0)
    if not liveOnly then
        assets.loadNow(mapTexturePath(cfg), true)
    end
    assets.loadNow(MEMBER_TEXTURE, false)
    local wbl = cls("/Script/UMG.Default__WidgetBlueprintLibrary")
    local userWidgetClass = cls("/Script/UMG.UserWidget")
    if wbl == nil or userWidgetClass == nil then
        guard.log("UMG is not reachable; the minimap cannot be built")
        return false
    end
    local world = guard.get(function() return pc:GetWorld() end)
    local widget = guard.get(function() return wbl:Create(world, userWidgetClass, pc) end)
    if not guard.alive(widget) then
        guard.log("could not create the minimap widget")
        return false
    end
    S.widget = widget
    S.tree = guard.get(function() return widget.WidgetTree end)
    if S.tree == nil then
        guard.log("minimap widget has no WidgetTree")
        M.destroy()
        return false
    end

    local root = construct("/Script/UMG.CanvasPanel", S.tree)
    if root == nil then M.destroy(); return false end
    guard.get(function() S.tree.RootWidget = root end)

    local size = cfg.size
    local round = cfg.circular == true

    -- The frame is the clipped window. Everything inside it is drawn in
    -- frame-local pixels, which is what makes the panning arithmetic
    -- below trivial.
    S.frame = construct("/Script/UMG.CanvasPanel", S.tree)
    if S.frame == nil then M.destroy(); return false end
    S.frameSlot = addToCanvas(root, S.frame)
    guard.get(function() S.frame:SetClipping(CLIP_BOUNDS) end)
    S.viewport = S.frame

    if round then
        round = buildBands(size)
        if not round then
            guard.log("could not build the circular strips; falling back to square")
        end
    end

    if not round then
        -- square: one backdrop and one map quad
        S.backdrop = construct("/Script/UMG.Border", S.tree)
        if S.backdrop ~= nil then
            guard.get(function() S.backdrop:SetBrushColor(BACKDROP) end)
            -- the slot is kept so applyLayout can follow a size change
            -- without a rebuild - see the edit-mode note in main.lua
            S.backdropSlot = addToCanvas(S.frame, S.backdrop)
            place(S.backdropSlot, 0, 0, size, size)
            setVisible(S.backdrop, true)
        end
        S.mapImage = construct("/Script/UMG.Image", S.tree)
        if S.mapImage == nil then M.destroy(); return false end
        S.mapSlot = addToCanvas(S.viewport, S.mapImage)
        setVisible(S.mapImage, true)
    end

    -- THE FRAME IS WHAT MAKES THE CIRCLE A CIRCLE (2.2.3).
    --
    -- Until now this slot held the game's own `T_prt_map_circle_eff`, which
    -- is a soft rim glow: it decorated the seam between the strips but did
    -- nothing about the staircase underneath, so the outline was visibly
    -- faceted. `icons/T_minimap_frame.png` is a shipped image whose INNER
    -- edge is a real, supersampled circle, and it is wide enough (RIM) to sit
    -- over the whole of the strips' error. What the player sees as the
    -- outline is that inner edge, so it is exact at any size.
    --
    -- It replaces the game's art rather than joining it: two rings on one
    -- edge is muddy, and stretching a 128 px glow across the whole disc was
    -- also washing the terrain out.
    --
    -- Drawn BELOW the icons (z 5) so a marker near the rim is not clipped by
    -- the bezel, and above the strips so the staircase is covered.
    if round then
        S.rim = construct("/Script/UMG.Image", S.tree)
        if S.rim ~= nil then
            S.rimSlot = addToCanvas(S.viewport, S.rim)
            guard.get(function() S.rimSlot:SetZOrder(5) end)
            local ctex = assets.loadNow(FRAME_TEXTURE, false)
            if ctex ~= nil then
                guard.get(function() S.rim:SetBrushFromTexture(ctex, false) end)
                place(S.rimSlot, 0, 0, size, size)
                S.rimSize = size
                setVisible(S.rim, true)
            else
                -- No frame image: the disc is the bare staircase again, which
                -- is how it looked before 2.2.3 - worse, not broken.
                setVisible(S.rim, false)
                guard.log("icons/T_minimap_frame.png is missing, so the round "
                    .. "minimap keeps the stepped outline; run "
                    .. "tools/make_frame.py")
            end
        end
    end

    -- Camera-facing view cone, drawn over the terrain but under every
    -- point-of-interest icon and under the centred player arrow. The image
    -- points upward in its authored orientation; update() gives it exactly
    -- the same angle as the player marker.
    S.viewCone = construct("/Script/UMG.Image", S.tree)
    if S.viewCone ~= nil then
        S.viewConeSlot = addToCanvas(S.viewport, S.viewCone)
        guard.get(function() S.viewConeSlot:SetZOrder(8) end)
        local coneTex = assets.loadNow(VIEW_CONE_TEXTURE, false)
        if coneTex ~= nil then
            S.viewConeReady = true
            guard.get(function() S.viewCone:SetBrushFromTexture(coneTex, false) end)
            setVisible(S.viewCone, false) -- first update applies the setting
        else
            setVisible(S.viewCone, false)
            guard.log("icons/T_view_cone.png is missing; the camera view cone is disabled")
        end
    end

    -- icon pool: allocated once, reused forever. No allocation, no
    -- destruction and no GC churn while playing.
    local capacity = poolCapacity(cfg)
    for _ = 1, capacity do
        local img = construct("/Script/UMG.Image", S.tree)
        if img ~= nil then
            local slot = addToCanvas(S.viewport, img)
            guard.get(function() slot:SetZOrder(10) end)
            setVisible(img, false)
            S.pool[#S.pool + 1] = { image = img, slot = slot, inUse = false }
        end
    end

    -- edit-mode highlight: hidden normally, shown while F4 is active
    S.editBorder = construct("/Script/UMG.Border", S.tree)
    if S.editBorder ~= nil then
        guard.get(function()
            S.editBorder:SetBrushColor({ R = 0.33, G = 0.78, B = 0.96, A = 0.28 })
        end)
        S.editSlot = addToCanvas(S.viewport, S.editBorder)
        guard.get(function() S.editSlot:SetZOrder(90) end)
        place(S.editSlot, 0, 0, size, size)
        setVisible(S.editBorder, false)
    end

    -- the player marker sits on top, always dead centre
    S.playerIcon = construct("/Script/UMG.Image", S.tree)
    if S.playerIcon ~= nil then
        S.playerSlot = addToCanvas(S.viewport, S.playerIcon)
        guard.get(function() S.playerSlot:SetZOrder(50) end)
        local tex = assets.loadNow(PLAYER_TEXTURE, false)
        if tex then
            guard.get(function() S.playerIcon:SetBrushFromTexture(tex, false) end)
        else
            guard.get(function()
                S.playerIcon:SetColorAndOpacity({ R = 0.2, G = 0.9, B = 1.0, A = 1.0 })
            end)
        end
        setVisible(S.playerIcon, true)
    end

    guard.get(function() widget:AddToViewport(0) end)
    -- the whole tree must never take input; a minimap that eats clicks is
    -- worse than no minimap
    guard.get(function() widget:SetVisibility(VIS_SHOW) end)
    guard.get(function() widget:SetRenderOpacity(cfg.opacity) end)

    S.builtSize = size
    S.builtPool = capacity
    -- what was ASKED for, not what succeeded: if the strips could not be
    -- constructed, recording `false` here would make needsRebuild() see a
    -- mismatch on every maintenance tick and rebuild the widget forever
    S.builtCircular = cfg.circular == true
    S.visible = true
    M.setEditMode(S.editMode)
    M.applyLayout(cfg)
    guard.log(string.format("minimap built (%dpx %s, %d icon slots%s)",
        size, round and "circular" or "square", #S.pool,
        round and (", " .. #S.bands .. " strips") or ""))
    return true
end

-- Position/size of the window itself. Negative coordinates count back from
-- the right/bottom edge, which keeps the default placement correct on any
-- resolution.
function M.applyLayout(cfg, viewportW, viewportH)
    if not M.isBuilt() then return end
    M.setViewport(viewportW, viewportH)
    -- 1920x1080 is only the last resort; the corners still land in four
    -- distinct places instead of stacking, and the next tick with a real
    -- viewport size corrects it.
    local vw = S.viewW or 1920
    local vh = S.viewH or 1080
    local size = cfg.size
    local x, y = cfg.x, cfg.y
    if x < 0 then x = vw + x - size end
    if y < 0 then y = vh + y - size end
    -- keep it on screen whatever the settings say
    if x < 0 then x = 0 elseif x > vw - size then x = vw - size end
    if y < 0 then y = 0 elseif y > vh - size then y = vh - size end
    place(S.frameSlot, x, y, size, size)
    if S.backdropSlot ~= nil then place(S.backdropSlot, 0, 0, size, size) end
    if S.editSlot ~= nil then place(S.editSlot, 0, 0, size, size) end
    guard.get(function() S.widget:SetRenderOpacity(cfg.opacity) end)
end

-- Edit mode needs to be obvious, otherwise the arrow keys feel broken.
function M.setEditMode(on)
    S.editMode = on and true or false
    if S.editBorder ~= nil then
        setVisible(S.editBorder, S.editMode)
    end
end

function M.setVisible(on)
    if not M.isBuilt() then return end
    S.visible = on and true or false
    guard.get(function() S.widget:SetVisibility(S.visible and VIS_SHOW or VIS_HIDE) end)
end

function M.isVisible() return S.visible end

-- ---------------------------------------------------------------
-- Per-update drawing
--
-- `player` = { x, y, yaw, bodyYaw, speed }; `yaw` is camera/control
-- direction while `bodyYaw` is the character actor's facing direction.
-- `marks` is sources.collect()'s pooled
-- array and `count` says how much of it is live. Callers pass plain
-- numbers - never UObjects - so nothing here can touch a dying actor.
-- ---------------------------------------------------------------
-- `gen` identifies the image on the brushes: it changes when the terrain
-- switches between the live render and the map texture, and when the live
-- render target is rebuilt at a new resolution. Anything else and the
-- brush is left alone, because re-applying it every frame is a reflection
-- call per strip for no change at all.
local function drawTerrain(tex, gen, live, mapX, mapY, imagePx, pu, pv, rotate, yaw)
    local angle = rotate and -yaw or 0.0

    if S.bands ~= nil then
        for i = 1, #S.bands do
            local b = S.bands[i]
            setPos(b.slot, mapX - b.x, mapY - b.y)
            if b.px ~= imagePx then
                b.px = imagePx
                setSize(b.slot, imagePx, imagePx)
            end
            -- Latch the generation only once the brush actually TOOK. It
            -- used to be written first, so a setter that failed for one
            -- frame left that strip showing the previous image until the
            -- generation happened to change again - and since the strips
            -- are latched independently, that reads as one band of the
            -- disc frozen on old terrain.
            if tex ~= nil and b.gen ~= gen then
                if setTerrainBrush(b.image, tex, live) then b.gen = gen end
            end
            if rotate then
                -- every strip holds the same quad at the same offset, so
                -- the same normalised pivot rotates them all about the
                -- player's point on the map and they stay seamless
                pcall(rawSetPivot, b.image, pu, pv)
            end
            if b.angle ~= angle then
                b.angle = angle
                pcall(rawSetAngle, b.image, angle)
            end
        end
        return tex
    end

    if tex ~= nil and S.terrainGen ~= gen then
        -- as above: only remember the image once it is really on the brush
        if setTerrainBrush(S.mapImage, tex, live) then
            S.terrainGen = gen
            S.mapTex = tex
        end
    end
    setPos(S.mapSlot, mapX, mapY)
    if S.mapPx ~= imagePx then
        S.mapPx = imagePx
        setSize(S.mapSlot, imagePx, imagePx)
    end
    if rotate then
        pcall(rawSetPivot, S.mapImage, pu, pv)
    end
    if S.mapAngle ~= angle then
        S.mapAngle = angle
        pcall(rawSetAngle, S.mapImage, angle)
    end
    return tex
end

function M.update(cfg, player, marks, count)
    if not M.isBuilt() or not S.visible then return end
    if type(player) ~= "table" or type(player.x) ~= "number" then return end
    count = count or 0

    local size = cfg.size
    local half = size * 0.5
    local zoom = M.effectiveZoom(cfg, player.speed)

    -- THE ONE NUMBER EVERYTHING ELSE IS BUILT ON: screen pixels per world
    -- unit. Both terrain sources and every icon are placed with it, so the
    -- two can never disagree about where a point in the world is.
    --
    -- 2.2 went through normalised map UVs to get here, which was the same
    -- arithmetic wearing a coordinate system it did not need - and it
    -- meant every icon depended on the player being inside a mapped
    -- region, so in a dungeon the markers went wherever the fallback
    -- region put them. World deltas are correct everywhere.
    local k = size / zoom

    local rotate = cfg.rotateWithCamera and type(player.yaw) == "number"
    local cosA, sinA = 1.0, 0.0
    if rotate then
        local rad = -player.yaw * math.pi / 180.0
        cosA, sinA = math.cos(rad), math.sin(rad)
    end

    -- ---------------------------------------------------------------
    -- The terrain quad.
    --
    -- Both sources reduce to the same three numbers: a texture, the world
    -- point it is centred on and how many world units it spans. The quad
    -- is then that span in pixels, positioned so its centre lands where
    -- its world centre belongs relative to the player, who is always at
    -- the middle of the window.
    --
    --   live : centre = where the camera was when it last captured, span =
    --          the orthographic width it used. Those lag the player by up
    --          to one capture interval, which is precisely what the
    --          overscan is for - the quad slides under the window and the
    --          picture stays put in the world.
    --   map  : centre = the middle of the region, span = the whole region.
    -- ---------------------------------------------------------------
    local live = wantsLive(cfg, player.x, player.y, zoom)
    local tex, gen, cx, cy, spanWorld
    if live then
        tex = capture.texture()
        cx, cy, spanWorld = capture.centre()
        gen = capture.generation()
    end
    if tex == nil or cx == nil or spanWorld == nil or spanWorld <= 0 then
        live = false
        local region = worldmap.regionFor(player.x, player.y)
        spanWorld = region.maxX - region.minX
        if spanWorld <= 0 then return end
        cx = (region.minX + region.maxX) * 0.5
        cy = (region.minY + region.maxY) * 0.5
        tex = assets.get(mapTexturePath(cfg))
        gen = 0
    end

    local imagePx = spanWorld * k
    -- screen offset of the image's centre from the player: screen X
    -- follows world +Y and screen Y runs against world +X, the orientation
    -- worldmap.lua confirmed in game and capture.lua reproduces by
    -- pointing the camera down with yaw 0
    local ccx = half + (cy - player.y) * k
    local ccy = half - (cx - player.x) * k
    -- where the player sits inside the image, 0..1 - the pivot the whole
    -- quad rotates about when the map turns with the camera
    local pu = 0.5 + (player.y - cy) / spanWorld
    local pv = 0.5 - (player.x - cx) / spanWorld

    drawTerrain(tex, gen, live, ccx - imagePx * 0.5, ccy - imagePx * 0.5,
                imagePx, pu, pv, rotate, player.yaw)
    if not live then reportTextureSize(tex, cfg, imagePx, size) end

    -- View cone follows CAMERA direction. When the map rotates with the
    -- camera it stays pointing up; in north-up mode it rotates to camera
    -- yaw. The player arrow below deliberately uses BODY direction instead.
    -- cone PNG is square and centred, so scaling it keeps the cone
    -- origin exactly at the player position.
    if S.viewCone ~= nil and S.viewConeSlot ~= nil then
        local showCone = cfg.showViewCone == true and S.viewConeReady == true
        if showCone then
            local scale = tonumber(cfg.viewConeSize) or 0.92
            if scale < 0.20 then scale = 0.20 end
            if scale > 1.20 then scale = 1.20 end
            local cs = size * scale
            setPos(S.viewConeSlot, half - cs * 0.5, half - cs * 0.5)
            if S.viewConeSize ~= cs then
                S.viewConeSize = cs
                setSize(S.viewConeSlot, cs, cs)
            end

            local ca = rotate and 0.0 or (player.yaw or 0.0)
            if S.viewConeAngle ~= ca then
                S.viewConeAngle = ca
                pcall(rawSetAngle, S.viewCone, ca)
            end

            local alpha = tonumber(cfg.viewConeOpacity) or 0.22
            if alpha < 0.0 then alpha = 0.0 end
            if alpha > 1.0 then alpha = 1.0 end
            if S.viewConeOpacity ~= alpha then
                S.viewConeOpacity = alpha
                VIEW_CONE_TINT.A = alpha
                pcall(rawSetTint, S.viewCone, VIEW_CONE_TINT)
            end
        end
        if S.viewConeShown ~= showCone then
            S.viewConeShown = showCone
            setVisible(S.viewCone, showCone)
        end
    end

    -- Player marker follows the CHARACTER BODY, independently of the
    -- camera/view cone. In camera-up mode subtract camera yaw because the
    -- terrain has already been rotated by -camera yaw.
    if S.playerSlot ~= nil then
        local ps = cfg.playerIconSize
        setPos(S.playerSlot, half - ps * 0.5, half - ps * 0.5)
        if S.playerSize ~= ps then
            S.playerSize = ps
            setSize(S.playerSlot, ps, ps)
        end
        local bodyYaw = type(player.bodyYaw) == "number"
            and player.bodyYaw or (player.yaw or 0.0)
        local pa = bodyYaw
        if rotate then pa = bodyYaw - (player.yaw or 0.0) end
        -- Keep the value bounded so crossing 0/360 does not accumulate large
        -- angles in the widget transform. The visual direction is unchanged.
        pa = ((pa + 180.0) % 360.0) - 180.0
        if S.playerAngle ~= pa then
            S.playerAngle = pa
            pcall(rawSetAngle, S.playerIcon, pa)
        end
    end

    -- the disc is real geometry now, but icons are still culled to it:
    -- they are drawn in the square frame, not inside the strips
    local round = S.bands ~= nil
    if S.rimSlot ~= nil and S.rimSize ~= size then
        S.rimSize = size
        place(S.rimSlot, 0, 0, size, size)
    end
    local radius = half - (cfg.iconSize * 0.35)
    local radius2 = radius * radius

    -- icons
    local used = 0
    local limit = #S.pool
    local margin = cfg.iconSize
    local iconAngle = (rotate and not cfg.lockIconsNorth) and player.yaw or 0.0
    for i = 1, count do
        if used >= limit then break end
        local m = marks[i]
        -- Straight world delta, in the same frame as the terrain above:
        -- screen X follows world +Y, screen Y runs against world +X. No
        -- map region involved, so a marker in a dungeon lands where it
        -- belongs instead of wherever the fallback region put it.
        if type(m.x) == "number" and type(m.y) == "number" then
            local dx = (m.y - player.y) * k
            local dy = (player.x - m.x) * k
            if rotate then
                dx, dy = dx * cosA - dy * sinA, dx * sinA + dy * cosA
            end
            -- cull anything outside the window before touching a widget
            local inside
            if round then
                inside = (dx * dx + dy * dy) <= radius2
            else
                inside = dx > -half - margin and dx < half + margin
                         and dy > -half - margin and dy < half + margin
            end
            if inside then
                used = used + 1
                local entry = S.pool[used]
                local isz = m.size or cfg.iconSize
                setPos(entry.slot, half + dx - isz * 0.5, half + dy - isz * 0.5)
                if entry.size ~= isz then
                    entry.size = isz
                    setSize(entry.slot, isz, isz)
                end
                -- Species portraits can fail to resolve (a pal whose icon
                -- asset is not cooked under the expected name); fall back
                -- to the generic marker rather than drawing an empty box.
                --
                -- THIS LOOP MUST NOT LOAD ANYTHING. It runs for up to 96
                -- icons ten times a second, and 2.1.0 called LoadAsset from
                -- inside it for the fallback marker - which is the hitch the
                -- player felt as each arrow turned into a portrait.
                -- `assets.get` is a table lookup that schedules the load and
                -- returns nil; the arrow simply stays until the portrait is
                -- actually in memory, and swapping the brush then costs
                -- nothing.
                --
                -- Keyed on what was REQUESTED, so an icon already showing
                -- the right texture costs one table compare.
                local desired = m.texture
                if entry.want ~= desired then
                    entry.want = desired
                    entry.tex = nil
                end

                local brushPath, brushTex = nil, nil
                if desired ~= nil then
                    brushTex = assets.get(desired)
                    if brushTex ~= nil then brushPath = desired end
                end
                if brushTex == nil and m.fallback ~= nil then
                    brushTex = assets.get(m.fallback)
                    if brushTex ~= nil then brushPath = m.fallback end
                end

                if brushTex ~= nil then
                    if entry.tex ~= brushPath then
                        entry.tex = brushPath
                        pcall(rawSetBrush, entry.image, brushTex)
                    end
                else
                    -- NOTHING resolved. Leaving the brush alone showed
                    -- whatever marker last used this pool slot - a chest
                    -- where a pal should be. An empty slot is skipped
                    -- below instead.
                    entry.tex = nil
                end
                if m.tint ~= nil and entry.tint ~= m.tint then
                    entry.tint = m.tint
                    pcall(rawSetTint, entry.image, m.tint)
                end
                -- 1.x's "lock all icon rotations to north": the map may
                -- spin, the icons should not
                if entry.angle ~= iconAngle then
                    entry.angle = iconAngle
                    pcall(rawSetAngle, entry.image, iconAngle)
                end
                -- a slot with no resolved brush stays hidden rather than
                -- showing the previous marker's icon
                local show = entry.tex ~= nil
                if entry.inUse ~= show then
                    setVisible(entry.image, show)
                    entry.inUse = show
                end
            end
        end
    end
    -- retire the rest of the pool without destroying anything
    for i = used + 1, limit do
        local entry = S.pool[i]
        if entry.inUse then
            setVisible(entry.image, false)
            entry.inUse = false
        end
    end
end

-- A size change means the widget was built at the wrong dimensions, a
-- max-icon change means the pool is the wrong length, and the shape is
-- baked in at build time now that it is real geometry rather than a decal.
-- 2.0.5 only checked the size, so "Max point-of-interest icons" did
-- nothing at all until the game was restarted.
function M.needsRebuild(cfg)
    if S.builtSize ~= nil and S.builtSize ~= cfg.size then return true end
    if S.builtPool ~= nil and S.builtPool ~= poolCapacity(cfg) then return true end
    if S.builtCircular ~= nil and S.builtCircular ~= (cfg.circular == true) then
        return true
    end
    return false
end

return M
