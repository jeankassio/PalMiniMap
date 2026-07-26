-- =====================================================================
-- render.lua - the minimap widget
--
-- THE WHOLE POINT OF VERSION 2, in one paragraph:
--
-- The 1.x mod inherited a SceneCaptureComponent2D that re-rendered the
-- entire world from above into a render target EVERY FRAME - a second full
-- render pass, all the time - and drew its icons as StaticMeshComponents
-- attached to the actors they marked. That design produced every serious
-- bug this mod ever had: the permanent GPU cost, the FPS decay as icon
-- components piled up, and two hard crashes from dereferencing icons whose
-- target actor had been destroyed.
--
-- This file has neither. The background is the game's own world map
-- texture drawn as ONE quad, panned by moving it inside a clipped canvas.
-- The icons are pooled UMG Images positioned by arithmetic. Nothing is
-- ever attached to a world actor, and no reference to one is held across
-- a frame, so an actor dying mid-update is a non-event instead of an
-- access violation. Cost is a handful of widgets, redrawn at 10 Hz.
-- =====================================================================

local guard = require("guard")
local worldmap = require("worldmap")

local M = {}

-- ESlateVisibility: 0 Visible, 1 Collapsed, 2 Hidden, 3 HitTestInvisible
local VIS_SHOW, VIS_HIDE = 3, 1
-- EWidgetClipping: 0 Inherit, 1 ClipToBounds
local CLIP_BOUNDS = 1

local MAP_TEXTURE = "/Game/Pal/Texture/UI/Map/T_WorldMap.T_WorldMap"
local CIRCLE_TEXTURE = "/Game/Pal/Texture/UI/Map/T_prt_map_circle_eff.T_prt_map_circle_eff"
local MAX_TEX_ATTEMPTS = 8

local S = {
    widget = nil, tree = nil,
    frame = nil, frameSlot = nil,
    viewport = nil,
    circleOverlay = nil, circleSlot = nil,
    mapImage = nil, mapSlot = nil,
    playerIcon = nil, playerSlot = nil,
    pool = {},              -- { image=, slot=, inUse= }
    textures = {},          -- asset path -> UTexture2D
    texAttempts = {},
    visible = false,
    builtSize = nil,
    viewW = nil, viewH = nil,
    editMode = false,
    editBorder = nil, editSlot = nil,
}

-- Viewport size, remembered. applyLayout used to be called from build()
-- with no size at all, so a negative (edge-relative) coordinate fell
-- through to the x=40 fallback and ALL FOUR corner presets collapsed onto
-- the top-left -- which is why F2 and F4 looked like they did nothing.
function M.setViewport(w, h)
    if type(w) == "number" and w > 0 and type(h) == "number" and h > 0 then
        S.viewW, S.viewH = w, h
        return true
    end
    return false
end

local function cls(path)
    local obj = guard.get(StaticFindObject, path)
    if obj and guard.alive(obj) then return obj end
    return nil
end

local function construct(classPath, outer)
    local class = cls(classPath)
    if class == nil then return nil end
    return guard.get(StaticConstructObject, class, outer)
end

-- Textures come from the game itself, so nothing ships with the mod. A
-- load can fail on the title screen and start working inside the world,
-- so failure is never treated as permanent.
local function loadTexture(path)
    if path == nil or path == "" then return nil end
    local cached = S.textures[path]
    if cached ~= nil and guard.alive(cached) then return cached end
    local attempts = S.texAttempts[path] or 0
    if attempts >= MAX_TEX_ATTEMPTS then return nil end
    S.texAttempts[path] = attempts + 1
    guard.get(LoadAsset, path)
    local tex = cls(path)
    if tex then S.textures[path] = tex end
    return tex
end
M.loadTexture = loadTexture

local function setVisible(w, on)
    if w == nil then return end
    guard.get(function() w:SetVisibility(on and VIS_SHOW or VIS_HIDE) end)
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

local function place(slot, x, y, w, h)
    if slot == nil then return end
    guard.get(function() slot:SetPosition({ X = x, Y = y }) end)
    if w ~= nil then
        guard.get(function() slot:SetSize({ X = w, Y = h }) end)
    end
end

-- Effective zoom, folding in the two zoom modes 1.x had:
--   * megazoom (F1) replaces the zoom outright;
--   * autozoom widens the view as the player moves faster, so walking is
--     tight and flying shows more ground.
-- `speed` is centimetres per second, straight from the pawn's velocity.
function M.effectiveZoom(cfg, speed)
    if cfg.megazoomActive then return cfg.megazoom end
    local zoom = cfg.zoom
    if cfg.autozoom and type(speed) == "number" then
        local mult = cfg.autozoomWalk
        if speed > 1100 then mult = cfg.autozoomFly
        elseif speed > 450 then mult = cfg.autozoomRun end
        zoom = zoom * mult
    end
    if zoom < cfg.zoomMin then zoom = cfg.zoomMin end
    if zoom > cfg.zoomMax * 4 then zoom = cfg.zoomMax * 4 end
    return zoom
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
    S.mapImage, S.mapSlot = nil, nil
    S.circleOverlay, S.circleSlot = nil, nil
    S.editBorder, S.editSlot = nil, nil
    S.playerIcon, S.playerSlot = nil, nil
    S.pool = {}
    S.visible = false
    S.builtSize = nil
end

function M.build(pc, cfg)
    M.destroy()
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

    -- The frame is the clipped window. Everything inside it is drawn in
    -- frame-local pixels, which is what makes the panning arithmetic
    -- below trivial.
    S.frame = construct("/Script/UMG.CanvasPanel", S.tree)
    if S.frame == nil then M.destroy(); return false end
    S.frameSlot = addToCanvas(root, S.frame)
    guard.get(function() S.frame:SetClipping(CLIP_BOUNDS) end)

    -- backdrop, so the window still reads as a minimap over bright terrain
    local backdrop = construct("/Script/UMG.Border", S.tree)
    if backdrop ~= nil then
        guard.get(function() backdrop:SetBrushColor({ R = 0.02, G = 0.03, B = 0.05, A = 0.55 }) end)
        place(addToCanvas(S.frame, backdrop), 0, 0, size, size)
        setVisible(backdrop, true)
    end

    S.viewport = S.frame

    S.mapImage = construct("/Script/UMG.Image", S.tree)
    if S.mapImage == nil then M.destroy(); return false end
    S.mapSlot = addToCanvas(S.viewport, S.mapImage)
    setVisible(S.mapImage, true)

    -- Circular shape: a real alpha mask needs a material, which we cannot
    -- author from Lua, so the round look comes from the game's own circular
    -- overlay drawn on top. Icons are additionally culled to the inscribed
    -- circle in update(), so the shape is honoured even where the art is
    -- only decorative.
    S.circleOverlay = construct("/Script/UMG.Image", S.tree)
    if S.circleOverlay ~= nil then
        S.circleSlot = addToCanvas(S.viewport, S.circleOverlay)
        guard.get(function() S.circleSlot:SetZOrder(80) end)
        local ctex = loadTexture(CIRCLE_TEXTURE)
        if ctex ~= nil then
            guard.get(function() S.circleOverlay:SetBrushFromTexture(ctex, false) end)
        end
        setVisible(S.circleOverlay, false)
    end

    -- icon pool: allocated once, reused forever. No allocation, no
    -- destruction and no GC churn while playing.
    local poolSize = cfg.maxPalIcons + cfg.maxPoiIcons
    for i = 1, poolSize do
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
        local tex = loadTexture("/Game/Pal/Texture/UI/InGame/T_icon_map_player.T_icon_map_player")
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
    S.visible = true
    M.setEditMode(S.editMode)
    M.applyLayout(cfg)
    guard.log(string.format("minimap built (%dpx, %d icon slots)", size, #S.pool))
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
-- `player` = { x, y, yaw }; `marks` = list of { x, y, texture, size, tint }.
-- Callers pass plain numbers - never UObjects - so nothing here can touch
-- a dying actor.
-- ---------------------------------------------------------------
function M.update(cfg, player, marks)
    if not M.isBuilt() or not S.visible then return end
    if type(player) ~= "table" or type(player.x) ~= "number" then return end

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

    -- background: one quad, moved so the player's point sits at the centre
    local tex = loadTexture(MAP_TEXTURE)
    if tex ~= nil then
        guard.get(function() S.mapImage:SetBrushFromTexture(tex, false) end)
    end
    place(S.mapSlot, half - pu * imagePx, half - pv * imagePx, imagePx, imagePx)

    local rotate = cfg.rotateWithCamera and type(player.yaw) == "number"
    local cosA, sinA = 1.0, 0.0
    if rotate then
        -- rotate the image about the player's own point, not its centre
        guard.get(function()
            S.mapImage:SetRenderTransformPivot({ X = pu, Y = pv })
        end)
        local rad = -player.yaw * math.pi / 180.0
        guard.get(function() S.mapImage:SetRenderTransformAngle(-player.yaw) end)
        cosA, sinA = math.cos(rad), math.sin(rad)
    else
        guard.get(function() S.mapImage:SetRenderTransformAngle(0.0) end)
    end

    -- player marker: always centred, rotated to show facing when the map
    -- itself is not rotating
    if S.playerSlot ~= nil then
        local ps = cfg.playerIconSize
        place(S.playerSlot, half - ps * 0.5, half - ps * 0.5, ps, ps)
        guard.get(function()
            S.playerIcon:SetRenderTransformAngle(rotate and 0.0 or (player.yaw or 0.0))
        end)
    end

    -- circular shape: overlay art plus a real radius test on the icons
    local round = cfg.circular == true
    if S.circleSlot ~= nil then
        place(S.circleSlot, 0, 0, size, size)
        setVisible(S.circleOverlay, round)
    end
    local radius = half - (cfg.iconSize * 0.35)
    local radius2 = radius * radius

    -- icons
    local used = 0
    local limit = #S.pool
    local margin = cfg.iconSize
    for i = 1, #marks do
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
                place(entry.slot, half + dx - isz * 0.5, half + dy - isz * 0.5, isz, isz)
                -- species portraits can fail to resolve (a pal whose icon
                -- asset is not cooked under the expected name); fall back to
                -- the generic marker rather than drawing an empty box
                local mtex = m.texture and loadTexture(m.texture) or nil
                if mtex == nil and m.fallback then
                    mtex = loadTexture(m.fallback)
                end
                if mtex ~= nil then
                    guard.get(function() entry.image:SetBrushFromTexture(mtex, false) end)
                end
                if m.tint ~= nil then
                    guard.get(function() entry.image:SetColorAndOpacity(m.tint) end)
                end
                -- 1.x's "lock all icon rotations to north": the map may spin,
                -- the icons should not
                if rotate then
                    guard.get(function()
                        entry.image:SetRenderTransformAngle(
                            cfg.lockIconsNorth and 0.0 or player.yaw)
                    end)
                end
                if not entry.inUse then
                    setVisible(entry.image, true)
                    entry.inUse = true
                end
            end
        end
    end
    -- retire the rest of the pool without destroying anything
    for i = used + 1, #S.pool do
        local entry = S.pool[i]
        if entry.inUse then
            setVisible(entry.image, false)
            entry.inUse = false
        end
    end
end

function M.needsRebuild(cfg)
    return S.builtSize ~= nil and S.builtSize ~= cfg.size
end

return M
