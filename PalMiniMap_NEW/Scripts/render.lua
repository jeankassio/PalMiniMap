-- =====================================================================
-- render.lua - the minimap widget
--
-- THE WHOLE POINT OF VERSION 2, in one paragraph:
--
-- The 1.x mod inherited a SceneCaptureComponent2D that re-rendered the
-- entire world from above into a render target EVERY FRAME - a second
-- full render pass, all the time - and drew its icons as
-- StaticMeshComponents attached to the actors they marked. That design
-- produced every serious bug this mod ever had: the permanent GPU cost,
-- the FPS decay as icon components piled up, and two hard crashes from
-- dereferencing icons whose target actor had been destroyed.
--
-- This file has neither. The background is the game's own world map
-- texture drawn as ONE quad, panned by moving it inside a clipped canvas.
-- The icons are pooled UMG Images positioned by arithmetic. Nothing is
-- ever attached to a world actor, and no reference to one is held across
-- a frame, so an actor dying mid-update is a non-event instead of an
-- access violation.
--
-- Every setter here goes through reflection, which is not free, so the
-- update path writes only what actually CHANGED. Position is the only
-- property that genuinely changes every frame.
-- =====================================================================

local guard = require("guard")
local worldmap = require("worldmap")

local M = {}

-- ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden, 3 HitTestInvisible
local VIS_SHOW, VIS_HIDE = 3, 1
-- EWidgetClipping: 0 Inherit, 1 ClipToBounds
local CLIP_BOUNDS = 1
-- TextureFilter: 0 Nearest, 1 Bilinear, 2 Trilinear, 3 Default
local TF_TRILINEAR = 2

local MAP_TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
local CIRCLE_TEXTURE = "/Game/Pal/Texture/UI/Map/T_prt_map_circle_eff.T_prt_map_circle_eff"
local PLAYER_TEXTURE = "/Game/Pal/Texture/UI/InGame/T_icon_map_player.T_icon_map_player"
local MAX_TEX_ATTEMPTS = 8

local S = {
    widget = nil, tree = nil,
    frame = nil, frameSlot = nil,
    viewport = nil,
    backdrop = nil,
    circleOverlay = nil, circleSlot = nil,
    mapImage = nil, mapSlot = nil, mapPx = nil,
    mapTex = nil, mapTexPath = nil,
    bands = nil,            -- circular mode: list of clipped strips
    playerIcon = nil, playerSlot = nil,
    playerSize = nil, playerAngle = nil,
    pool = {},              -- { image=, slot=, inUse=, tex=, tint=, angle=, size= }
    textures = {},          -- asset path -> UTexture2D
    texAttempts = {},
    quality = nil,
    reportedSize = false,
    visible = false,
    builtSize = nil,
    builtPool = nil,
    builtCircular = nil,
    circleSize = nil,
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
-- Texture quality
--
-- WHY THIS EXISTS. The terrain is the game's own T_WorldMap stretched
-- over the whole island, so at any useful zoom it is MAGNIFIED several
-- times - and a magnified texture can only ever be as sharp as the mip
-- that happens to be resident. Palworld streams its UI textures: nothing
-- asks for the world map at full resolution until the player opens the
-- map screen, so the minimap was drawing a low mip. That, not the widget
-- size, is why the terrain looked soft.
--
-- Forcing the mips resident is the whole fix, and it is one property
-- write. `mapQuality` grades it because keeping every pal portrait at
-- full resolution does cost VRAM:
--   0  leave the streamer alone (lowest memory, softest)
--   1  keep the world map texture fully resident
--   2  ...and the icon textures too                     (default)
--   3  ...plus trilinear filtering and no streaming mip bias
-- ---------------------------------------------------------------
local function tuneTexture(tex, level, isMap)
    if tex == nil or level == nil or level <= 0 then return end
    if not isMap and level < 2 then return end
    guard.get(function() tex.bForceMiplevelsToBeResident = true end)
    guard.get(function() tex.bGlobalForceMipLevelsToBeResident = true end)
    if level >= 3 then
        guard.get(function() tex.bIgnoreStreamingMipBias = true end)
        guard.get(function() tex.Filter = TF_TRILINEAR end)
    end
end

local function mapTexturePath(cfg)
    local override = cfg and cfg.terrainTexture
    if type(override) == "string" and override ~= "" then return override end
    return MAP_TEXTURE
end

-- Textures come from the game itself, so nothing ships with the mod. A
-- load can fail on the title screen and start working inside the world,
-- so failure is never treated as permanent.
local function loadTexture(path, level, isMap)
    if path == nil or path == "" then return nil end
    local cached = S.textures[path]
    if cached ~= nil and guard.alive(cached) then return cached end
    local attempts = S.texAttempts[path] or 0
    if attempts >= MAX_TEX_ATTEMPTS then return nil end
    S.texAttempts[path] = attempts + 1
    guard.get(LoadAsset, path)
    local tex = cls(path)
    if tex then
        S.textures[path] = tex
        S.texAttempts[path] = 0    -- a texture that loaded once may be
                                   -- reloaded after a world change
        tuneTexture(tex, level or S.quality, isMap)
    end
    return tex
end
M.loadTexture = loadTexture

-- Re-apply the quality setting to everything already loaded. Called when
-- the menu changes it, never periodically - the flags live on the texture
-- object, so setting them once is enough.
function M.applyQuality(cfg)
    S.quality = cfg.mapQuality
    local mapPath = mapTexturePath(cfg)
    for path, tex in pairs(S.textures) do
        if guard.alive(tex) then tuneTexture(tex, S.quality, path == mapPath) end
    end
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

local function poolCapacity(cfg)
    return (cfg.maxPalIcons or 48) + (cfg.maxPoiIcons or 48)
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
    S.backdrop = nil
    S.mapImage, S.mapSlot, S.mapTex = nil, nil, nil
    S.mapPx, S.mapAngle = nil, nil
    S.bands = nil
    S.circleOverlay, S.circleSlot, S.circleSize = nil, nil, nil
    S.editBorder, S.editSlot = nil, nil
    S.playerIcon, S.playerSlot = nil, nil
    S.playerSize, S.playerAngle = nil, nil
    S.pool = {}
    S.visible = false
    S.builtSize, S.builtPool, S.builtCircular = nil, nil, nil
end

local BACKDROP = { R = 0.02, G = 0.03, B = 0.05, A = 0.55 }

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
-- R * pi / (4n), so the strip count is chosen from the radius to keep that
-- near 3 px (31 strips on a 240 px minimap, 48 on the largest). The
-- outline is a fine staircase rather than a mathematical circle, and the
-- game's own circular overlay is drawn on top of exactly that seam.
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
local function bandCount(size)
    local n = math.floor(size * 0.10 + 0.5)
    if n < 16 then n = 16 elseif n > 36 then n = 36 end
    return n
end

local function buildBands(size)
    local n = bandCount(size)
    local R = size * 0.5
    S.bands = {}
    for k = 0, n - 1 do
        local t0 = (k / n) * math.pi
        local t1 = ((k + 1) / n) * math.pi
        local y0 = R - R * math.cos(t0)
        local y1 = R - R * math.cos(t1)
        local w = R * math.sin((t0 + t1) * 0.5)
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
    S.quality = cfg.mapQuality
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
            place(addToCanvas(S.frame, S.backdrop), 0, 0, size, size)
            setVisible(S.backdrop, true)
        end
        S.mapImage = construct("/Script/UMG.Image", S.tree)
        if S.mapImage == nil then M.destroy(); return false end
        S.mapSlot = addToCanvas(S.viewport, S.mapImage)
        setVisible(S.mapImage, true)
    end

    -- The game's own circular art, drawn over the seam between the strips.
    -- It is decoration now, not the shape itself.
    if round then
        S.circleOverlay = construct("/Script/UMG.Image", S.tree)
        if S.circleOverlay ~= nil then
            S.circleSlot = addToCanvas(S.viewport, S.circleOverlay)
            guard.get(function() S.circleSlot:SetZOrder(80) end)
            local ctex = loadTexture(CIRCLE_TEXTURE, cfg.mapQuality, false)
            if ctex ~= nil then
                guard.get(function() S.circleOverlay:SetBrushFromTexture(ctex, false) end)
                place(S.circleSlot, 0, 0, size, size)
                S.circleSize = size
                setVisible(S.circleOverlay, true)
            else
                setVisible(S.circleOverlay, false)
            end
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
        local tex = loadTexture(PLAYER_TEXTURE, cfg.mapQuality, false)
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
-- `player` = { x, y, yaw, speed }; `marks` is sources.collect()'s pooled
-- array and `count` says how much of it is live. Callers pass plain
-- numbers - never UObjects - so nothing here can touch a dying actor.
-- ---------------------------------------------------------------
local function drawTerrain(cfg, mapX, mapY, imagePx, pu, pv, rotate, yaw)
    local tex = loadTexture(mapTexturePath(cfg), cfg.mapQuality, true)
    local angle = rotate and -yaw or 0.0

    if S.bands ~= nil then
        for i = 1, #S.bands do
            local b = S.bands[i]
            setPos(b.slot, mapX - b.x, mapY - b.y)
            if b.px ~= imagePx then
                b.px = imagePx
                setSize(b.slot, imagePx, imagePx)
            end
            if tex ~= nil and b.tex == nil then
                b.tex = tex
                pcall(rawSetBrush, b.image, tex)
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

    if tex ~= nil and S.mapTex == nil then
        S.mapTex = tex
        pcall(rawSetBrush, S.mapImage, tex)
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
    local region = worldmap.regionFor(player.x, player.y)
    local pu, pv = worldmap.toUV(player.x, player.y, region)
    if pu == nil then return end

    -- world units across the window -> pixels per normalised unit
    local spanWorld = region.maxX - region.minX
    if spanWorld <= 0 then return end
    local zoom = M.effectiveZoom(cfg, player.speed)
    local imagePx = size * (spanWorld / zoom)

    local rotate = cfg.rotateWithCamera and type(player.yaw) == "number"
    local cosA, sinA = 1.0, 0.0
    if rotate then
        local rad = -player.yaw * math.pi / 180.0
        cosA, sinA = math.cos(rad), math.sin(rad)
    end

    -- background: the map quad(s), moved so the player's point is centred
    local tex = drawTerrain(cfg, half - pu * imagePx, half - pv * imagePx,
                            imagePx, pu, pv, rotate, player.yaw)
    reportTextureSize(tex, cfg, imagePx, size)

    -- player marker: always centred, rotated to show facing when the map
    -- itself is not rotating
    if S.playerSlot ~= nil then
        local ps = cfg.playerIconSize
        setPos(S.playerSlot, half - ps * 0.5, half - ps * 0.5)
        if S.playerSize ~= ps then
            S.playerSize = ps
            setSize(S.playerSlot, ps, ps)
        end
        local pa = rotate and 0.0 or (player.yaw or 0.0)
        if S.playerAngle ~= pa then
            S.playerAngle = pa
            pcall(rawSetAngle, S.playerIcon, pa)
        end
    end

    -- the disc is real geometry now, but icons are still culled to it:
    -- they are drawn in the square frame, not inside the strips
    local round = S.bands ~= nil
    if S.circleSlot ~= nil and S.circleSize ~= size then
        S.circleSize = size
        place(S.circleSlot, 0, 0, size, size)
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
        local u, v = worldmap.toUV(m.x, m.y, region)
        if u ~= nil then
            local dx = (u - pu) * imagePx
            local dy = (v - pv) * imagePx
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
                -- Keyed on what was REQUESTED, so an icon that is already
                -- showing the right texture costs one table compare. 2.0.8
                -- called loadTexture for every icon every frame - a table
                -- lookup plus an IsValid pcall per icon, ~1000 a second -
                -- even though the answer had not changed.
                -- `entry.tex == nil` also retries: a texture that was still
                -- streaming in the first time this slot asked for it must
                -- not leave the slot blank for good. loadTexture gives up
                -- after MAX_TEX_ATTEMPTS, so the retry cannot run away.
                if entry.want ~= m.texture or entry.tex == nil then
                    entry.want = m.texture
                    local want = m.texture
                    local mtex = want and loadTexture(want, cfg.mapQuality, false) or nil
                    if mtex == nil and m.fallback then
                        want = m.fallback
                        mtex = loadTexture(want, cfg.mapQuality, false)
                    end
                    if mtex ~= nil then
                        if entry.tex ~= want then
                            entry.tex = want
                            pcall(rawSetBrush, entry.image, mtex)
                        end
                    else
                        -- NOTHING resolved. Leaving the brush alone showed
                        -- whatever marker last used this pool slot - a chest
                        -- where a pal should be. An empty slot is skipped
                        -- below instead.
                        entry.tex = nil
                    end
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
