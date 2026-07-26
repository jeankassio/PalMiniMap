-- =====================================================================
-- PalMiniMap 2.0 - a native minimap for Palworld
--
-- No blueprint, no .pak, no shipped assets. The whole mod is this Lua
-- script driving UMG through UE4SS reflection, drawing the game's own
-- world map texture and the game's own icon textures.
--
-- WHY THAT MATTERS, beyond "no third-party pak":
--   * one identical package for Steam, Nexus and Game Pass - the IoStore
--     conversion the 1.x Game Pass build needed simply does not apply;
--   * nothing to break when the game updates its asset cooking;
--   * no SceneCapture re-rendering the world every frame, which was the
--     permanent GPU cost in 1.x;
--   * no icon components attached to world actors, which was the source
--     of the FPS decay and of both hard crashes.
--
-- Keys:  F5 config menu   F3 show/hide   F2 cycle corner   + / -  zoom
-- =====================================================================

local guard = require("guard")

-- Resolve the folder this script lives in, so the settings file sits next
-- to the mod wherever UE4SS was installed.
local function scriptDirectory()
    if debug == nil or debug.getinfo == nil then return nil end
    local ok, info = pcall(debug.getinfo, 1, "S")
    if not ok or type(info) ~= "table" or type(info.source) ~= "string" then return nil end
    local source = info.source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("\\", "/")
    return source:match("^(.+)/[^/]+$")
end

local SCRIPT_DIR = scriptDirectory()

local function needModule(name)
    local ok, mod = pcall(require, name)
    if ok and mod ~= nil then return mod end
    guard.log("FATAL: could not load required module '" .. name .. "': " .. tostring(mod))
    return nil
end

local config   = needModule("config")
local worldmap = needModule("worldmap")
local render   = needModule("render")
local sources  = needModule("sources")
local menu     = needModule("menu")
if config == nil or worldmap == nil or render == nil or sources == nil or menu == nil then
    guard.log("PalMiniMap is disabled for this session (missing module above).")
    do return end
end

config.setPath((SCRIPT_DIR or ".") .. "/../minimap_settings.json")
local cfg = config.load()
worldmap.setAxis(cfg.axis)

-- ---------------------------------------------------------------
-- Cheap access to the player, without UEHelpers
--
-- UEHelpers.GetPlayerController() runs FindAllOf("PlayerController") - a
-- full walk of the UObject array - on EVERY call. At 10 Hz that would cost
-- more than the entire rest of the mod, so this goes through
-- UGameplayStatics directly and caches the controller.
-- ---------------------------------------------------------------
local gameplayStatics = nil
local cachedPC = nil

local function statics()
    if gameplayStatics == nil or not guard.alive(gameplayStatics) then
        gameplayStatics = guard.get(StaticFindObject,
            "/Script/Engine.Default__GameplayStatics")
    end
    return gameplayStatics
end

local function playerController()
    if guard.alive(cachedPC) then return cachedPC end
    local gs = statics()
    if gs == nil then return nil end
    -- GetPlayerController needs a world context; the cached one is gone, so
    -- fall back to the slow path exactly once to re-seed it.
    local found = guard.get(FindAllOf, "PlayerController")
    if type(found) == "table" then
        for _, pc in ipairs(found) do
            if guard.alive(pc) then cachedPC = pc; return pc end
        end
    end
    return nil
end

local function playerPawn()
    local pc = playerController()
    if pc == nil then return nil end
    local gs = statics()
    if gs == nil then return nil end
    local pawn = guard.get(function() return gs:GetPlayerPawn(pc, 0) end)
    if guard.alive(pawn) then return pawn end
    return nil
end

-- x, y, yaw of the local player, or nil while the world is not playable
local function playerState()
    local pawn = playerPawn()
    if pawn == nil then return nil end
    local x, y = sources.actorLocation(pawn)
    if x == nil then return nil end
    local yaw = 0.0
    local pc = playerController()
    local rot = pc and guard.get(function() return pc:GetControlRotation() end) or nil
    if rot == nil then
        rot = guard.get(function() return pawn:K2_GetActorRotation() end)
    end
    if rot ~= nil then
        local y2 = guard.get(function() return rot.Yaw end)
        if type(y2) == "number" then yaw = y2 end
    end
    -- speed drives autozoom; velocity is centimetres per second
    local speed = 0.0
    local vel = guard.get(function() return pawn:GetVelocity() end)
    if vel ~= nil then
        local vx = guard.get(function() return vel.X end)
        local vy = guard.get(function() return vel.Y end)
        local vz = guard.get(function() return vel.Z end)
        if type(vx) == "number" and type(vy) == "number" then
            speed = math.sqrt(vx * vx + vy * vy + (type(vz) == "number" and vz * vz or 0))
        end
    end
    return { x = x, y = y, yaw = yaw, speed = speed }
end

-- ---------------------------------------------------------------
-- Streaming / teleport guard (carried over from 1.2.6)
--
-- A Palworld fast travel keeps the same UWorld and only swaps streaming
-- sublevels, so no world-change hook fires while every actor around the
-- player is destroyed. Reading actor positions through that is what
-- crashed 1.x. Static marks are already immune (plain numbers), and this
-- keeps the dynamic ones out of the window too.
-- ---------------------------------------------------------------
local QUIET_SECONDS = 10
local TELEPORT_JUMP = 20000
local quietUntil = 0.0
local lastX, lastY = nil, nil

local function beQuiet(reason)
    quietUntil = os.clock() + QUIET_SECONDS
    if reason then guard.log("pausing scans for " .. QUIET_SECONDS .. "s: " .. reason) end
end

local function watchTeleport(p)
    if p == nil then
        lastX, lastY = nil, nil
        beQuiet(nil)
        return
    end
    if lastX ~= nil then
        local dx, dy = p.x - lastX, p.y - lastY
        if (dx * dx + dy * dy) > (TELEPORT_JUMP * TELEPORT_JUMP) then
            sources.forget()
            beQuiet("teleport detected")
        end
    end
    lastX, lastY = p.x, p.y
end

local function settled() return os.clock() >= quietUntil end

-- ---------------------------------------------------------------
-- World tracking: the widget dies with its world and must be rebuilt
-- ---------------------------------------------------------------
local worldName = ""
local NON_GAME_WORLDS = { PL_PPSplash = true, PL_Login = true, PL_Title = true }

local function currentWorldName()
    local pc = playerController()
    if pc == nil then return nil end
    local w = guard.get(function() return pc:GetWorld() end)
    if not guard.alive(w) then return nil end
    local n = guard.get(function() return w:GetFName():ToString() end)
    if n == nil then return nil end
    return tostring(n)
end

local function viewportSize()
    local pc = playerController()
    if pc == nil then return nil, nil end
    local ok, x, y = guard.try("GetViewportSize", function()
        return pc:GetViewportSize()
    end)
    if ok and type(x) == "number" and type(y) == "number" and x > 0 then
        return x, y
    end
    return nil, nil
end

local function ensureWidget()
    if render.isBuilt() and not render.needsRebuild(cfg) then return true end
    local pc = playerController()
    if pc == nil then return false end
    if not render.build(pc, cfg) then return false end
    local vw, vh = viewportSize()
    render.applyLayout(cfg, vw, vh)
    render.setVisible(cfg.enabled)
    return true
end

-- ---------------------------------------------------------------
-- Ticks
-- ---------------------------------------------------------------
local function movementTick()
    if not cfg.enabled then return end
    if not render.isBuilt() then return end
    if not settled() then return end
    local p = playerState()
    if p == nil then return end
    -- 1.x's "autohide minimap while in base camps"
    local hide = cfg.autohideInBase and sources.insideBaseCamp()
    if hide ~= (not render.isVisible()) then
        render.setVisible(not hide)
    end
    if hide then return end
    -- while megazoomed, pal icons are optional (1.x: "show pal icons while
    -- megazoomed out") - they turn into noise at region scale
    local marks = sources.collect(cfg)
    if cfg.megazoomActive and not cfg.palsWhileMegazoom then
        local filtered = {}
        for i = 1, #marks do
            if not marks[i].isPal then filtered[#filtered + 1] = marks[i] end
        end
        marks = filtered
    end
    render.update(cfg, p, marks)
end

local function scanTick()
    if not cfg.enabled then return end
    if not settled() then return end
    local p = playerState()
    if p == nil then return end
    -- the player character doubles as the reference for IsFriend
    sources.scan(cfg, p.x, p.y, playerPawn())
end

local function maintenanceTick()
    local name = currentWorldName()
    if name == nil then
        render.destroy()
        sources.forget()
        cachedPC = nil
        worldName = ""
        return
    end
    if name ~= worldName then
        worldName = name
        render.destroy()
        sources.forget()
        menu.worldChanged(name)   -- the menu widget died with the old world
        lastX, lastY = nil, nil
        beQuiet(nil)
    end
    if NON_GAME_WORLDS[name] then return end

    watchTeleport(playerState())
    ensureWidget()
    worldmap.calibrate()
end

-- ---------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------
local CORNERS = {
    { x = -280, y =  40 },   -- top right
    { x =   40, y =  40 },   -- top left
    { x =   40, y = -280 },  -- bottom left
    { x = -280, y = -280 },  -- bottom right
}
local cornerIndex = 1

local function toggleVisible()
    cfg.enabled = not cfg.enabled
    render.setVisible(cfg.enabled)
    config.save()
    guard.log("minimap " .. (cfg.enabled and "shown" or "hidden"))
end

local function cycleCorner()
    cornerIndex = (cornerIndex % #CORNERS) + 1
    local c = CORNERS[cornerIndex]
    cfg.x, cfg.y = c.x, c.y
    local vw, vh = viewportSize()
    render.applyLayout(cfg, vw, vh)
    config.save()
end

local function zoomBy(delta)
    if menu.isOpen() then return end
    if editMode then
        -- in edit mode +/- resize the window instead, exactly as in 1.x
        resize(delta < 0 and 10 or -10)
        return
    end
    cfg.zoom = config.clamp(cfg.zoom + delta, cfg.zoomMin, cfg.zoomMax)
    config.save()
end

local function toggleMegazoom()
    cfg.megazoomActive = not cfg.megazoomActive
    config.save()
    guard.log("megazoom " .. (cfg.megazoomActive and "on" or "off"))
end

-- Edit mode (1.x F4): arrow keys move the window, +/- resize it.
local editMode = false

local function toggleEditMode()
    editMode = not editMode
    if not editMode then config.save() end
    guard.log("edit mode " .. (editMode and "on - arrows move, +/- resize"
                                        or "off - layout saved"))
end

local function nudge(dx, dy)
    if not editMode then return end
    cfg.x = cfg.x + dx
    cfg.y = cfg.y + dy
    local vw, vh = viewportSize()
    render.applyLayout(cfg, vw, vh)
end

local function resize(delta)
    cfg.size = config.clamp(cfg.size + delta, 120, 480)
    render.destroy()   -- the maintenance tick rebuilds at the new size
end

-- ---------------------------------------------------------------
-- Menu wiring
--
-- Anything the menu changes has to take effect immediately. Most settings
-- are simply read on the next tick, but a size change means the widget was
-- built at the wrong dimensions, and the axis controls have to be pushed
-- into worldmap before the next draw.
-- ---------------------------------------------------------------
menu.onCommit = function(keys)
    local rebuild, relayout = false, false
    for _, key in ipairs(keys) do
        if key == "size" then rebuild = true
        elseif key == "opacity" then relayout = true
        elseif key:sub(1, 5) == "axis." then worldmap.setAxis(cfg.axis)
        elseif key == "enabled" then render.setVisible(cfg.enabled)
        elseif key == "maxPalIcons" then rebuild = true
        elseif key == "showPals" or key == "onlyShinyPals"
            or key == "showChests" or key == "showFastTravel"
            or key == "showDungeons" or key == "showBaseCamps"
            or key == "showPlayers" then
            sources.forget()   -- next scan repopulates with the new filter
        end
    end
    if rebuild then
        render.destroy()       -- the maintenance tick rebuilds at the new size
    elseif relayout then
        local vw, vh = viewportSize()
        render.applyLayout(cfg, vw, vh)
    end
    config.save()
end

local function toggleMenu()
    menu.toggle(playerController(), cfg, worldName)
end

-- ---------------------------------------------------------------
-- Registration - each item on its own, so one failure costs only itself
-- ---------------------------------------------------------------
guard.register("world transition hook", function()
    RegisterLoadMapPreHook(guard.callback("LoadMapPreHook", function()
        render.destroy()
        sources.forget()
        cachedPC = nil
        worldName = ""
        beQuiet(nil)
    end))
end)

local function bind(label, key, fn)
    guard.register(label, function()
        RegisterKeyBind(key, guard.gameThreadCallback(label, fn))
    end)
end

if type(Key) == "table" then
    bind("config menu (F5)", Key.F5, toggleMenu)
    bind("megazoom (F1)", Key.F1, toggleMegazoom)
    bind("toggle minimap (F3)", Key.F3, toggleVisible)
    bind("cycle corner (F2)", Key.F2, cycleCorner)
    bind("edit mode (F4)", Key.F4, toggleEditMode)
    bind("edit move left",  Key.LEFT,  function() nudge(-10, 0) end)
    bind("edit move right", Key.RIGHT, function() nudge(10, 0) end)
    bind("edit move up",    Key.UP,    function() nudge(0, -10) end)
    bind("edit move down",  Key.DOWN,  function() nudge(0, 10) end)
    bind("zoom in (+)", Key.ADD, function() zoomBy(-cfg.zoomStep) end)
    bind("zoom in (=)", Key.OEM_PLUS, function() zoomBy(-cfg.zoomStep) end)
    bind("zoom out (-)", Key.SUBTRACT, function() zoomBy(cfg.zoomStep) end)
    bind("zoom out (_)", Key.OEM_MINUS, function() zoomBy(cfg.zoomStep) end)
else
    guard.log("the UE4SS 'Key' table is missing; keybinds are unavailable")
end

guard.register("movement loop", function()
    LoopAsync(cfg.moveIntervalMs, guard.loopBody("movementTick", movementTick,
        function() return cfg.enabled end))
end)

guard.register("scan loop", function()
    LoopAsync(cfg.scanIntervalMs, guard.loopBody("scanTick", scanTick,
        function() return cfg.enabled end))
end)

guard.register("maintenance loop", function()
    LoopAsync(2000, guard.loopBody("maintenanceTick", maintenanceTick))
end)

-- The menu polls its controls 4x a second, but only while it is open --
-- the check runs on the timer thread, so a closed menu costs nothing.
guard.register("menu poll loop", function()
    LoopAsync(250, guard.loopBody("menuPoll", function() menu.poll(cfg) end,
        function() return menu.isOpen() end))
end)

guard.log("PalMiniMap 2.0.1 loaded - F5 menu, F3 show/hide, F2 corner, +/- zoom")
