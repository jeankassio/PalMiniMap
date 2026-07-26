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

-- Viewport size, IN SLATE UNITS.
--
-- This distinction is the whole point. GetViewportSize reports PIXELS, but
-- a UMG CanvasPanel positions its children in slate units, which are
-- pixels divided by the UI's DPI scale. On a 4K screen Palworld runs a
-- scale of about 2, so treating the pixel size as canvas space put the
-- config window at x=1570 slate units - 3140 real pixels - and it hung off
-- the right-hand edge. It also pushed the minimap's edge-relative corners
-- clean off screen.
--
-- 1.x divided by GetViewportScale for exactly this reason; the rewrite
-- dropped it. Everything downstream (menu geometry, corner presets, edit
-- mode) works in slate units, so the division belongs here, once.
--
-- The size itself comes from UWidgetLayoutLibrary::GetViewportSize (a
-- single FVector2D) rather than APlayerController::GetViewportSize (two
-- OUT parameters, which does not survive reflection reliably). The last
-- good value is cached so a momentary failure never resets the layout.
local lastViewW, lastViewH = nil, nil

local function viewportScale(pc, wll)
    local s = guard.get(function() return wll:GetViewportScale(pc) end)
    if type(s) == "number" and s > 0.1 then return s end
    return 1.0
end

local function viewportSize()
    local pc = playerController()
    if pc ~= nil then
        local wll = guard.get(StaticFindObject,
            "/Script/UMG.Default__WidgetLayoutLibrary")
        if wll ~= nil then
            local scale = viewportScale(pc, wll)
            local v = guard.get(function() return wll:GetViewportSize(pc) end)
            if v ~= nil then
                local x = guard.get(function() return v.X end)
                local y = guard.get(function() return v.Y end)
                if type(x) == "number" and x > 0 and type(y) == "number" and y > 0 then
                    lastViewW, lastViewH = x / scale, y / scale
                    return lastViewW, lastViewH
                end
            end
            local ok, px, py = guard.try("GetViewportSize", function()
                return pc:GetViewportSize()
            end)
            if ok and type(px) == "number" and px > 0
               and type(py) == "number" and py > 0 then
                lastViewW, lastViewH = px / scale, py / scale
                return lastViewW, lastViewH
            end
        end
    end
    return lastViewW, lastViewH
end

-- True while the game is showing its own pause/system menu.
--
-- 2.0.2 inferred this from pc.bShowMouseCursor. That was wrong: Palworld
-- leaves the cursor flag ON during ordinary gameplay, so the test was true
-- all the time and the minimap was hidden permanently - it was built, the
-- scans ran, and nothing was ever drawn. Replaced with the actual widget:
-- WBP_InGameMainMenu is the Esc menu, and asking whether it is in the
-- viewport is exact rather than a guess.
--
-- FindAllOf walks the whole UObject array, so it runs on the 2 s
-- maintenance tick only; the per-frame path just re-checks the cached
-- widget, which is a single call.
local GAME_MENU_CLASS = "WBP_InGameMainMenu_C"
local gameMenuWidget = nil

local function refreshGameMenuWidget()
    if guard.alive(gameMenuWidget) then return end
    gameMenuWidget = nil
    local found = guard.get(FindAllOf, GAME_MENU_CLASS)
    if type(found) ~= "table" then return end
    for _, w in ipairs(found) do
        if guard.alive(w) then gameMenuWidget = w; return end
    end
end

local function gameUiOpen()
    if not cfg.hideBehindGameUi then return false end
    if menu.isOpen() then return false end   -- our own window may stay up
    if not guard.alive(gameMenuWidget) then return false end
    return guard.get(function() return gameMenuWidget:IsInViewport() end) == true
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
    -- hide behind the game's own menus, and while inside a base camp if
    -- the user asked for that
    local hide = gameUiOpen()
                 or (cfg.autohideInBase and sources.insideBaseCamp())
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
    refreshGameMenuWidget()
    ensureWidget()
    worldmap.calibrate()
end

-- ---------------------------------------------------------------
-- Controls
-- ---------------------------------------------------------------
-- A negative coordinate is a margin measured from the right/bottom edge,
-- so these presets stay correct at any window size and any resolution.
local CORNERS = {
    { x = -40, y =  40 },   -- top right
    { x =  40, y =  40 },   -- top left
    { x =  40, y = -40 },   -- bottom left
    { x = -40, y = -40 },   -- bottom right
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
    render.setEditMode(editMode)
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

-- The menu gets accessors, never cached objects. Holding a title-screen
-- PlayerController across polls is what crashed 2.0.2: that controller is
-- destroyed as the title flow advances, and the next SetInputMode call
-- landed on freed memory (access violation reading 0xffff...ffff, which
-- no pcall can catch).
menu.env = {
    controller  = playerController,
    viewport    = viewportSize,
    isGameWorld = function()
        return worldName ~= "" and not NON_GAME_WORLDS[worldName]
    end,
}

local function toggleMenu()
    -- logged unconditionally: when the menu did not appear in 2.0.3 there
    -- was no line at all, which left no way to tell "key never fired" from
    -- "opened but invisible"
    guard.log("F5 pressed (world='" .. tostring(worldName) .. "')")
    menu.toggle(cfg, worldName)
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
    -- UE4SS names the arrows *_ARROW; plain LEFT/RIGHT/UP/DOWN do not
    -- exist, so 2.0.2 failed to bind all four (the log said so on every
    -- launch) and edit mode could never be moved.
    bind("edit move left",  Key.LEFT_ARROW,  function() nudge(-10, 0) end)
    bind("edit move right", Key.RIGHT_ARROW, function() nudge(10, 0) end)
    bind("edit move up",    Key.UP_ARROW,    function() nudge(0, -10) end)
    bind("edit move down",  Key.DOWN_ARROW,  function() nudge(0, 10) end)
    bind("zoom in (+)", Key.ADD, function() zoomBy(-cfg.zoomStep) end)
    bind("zoom in (=)", Key.OEM_PLUS, function() zoomBy(-cfg.zoomStep) end)
    bind("zoom out (-)", Key.SUBTRACT, function() zoomBy(cfg.zoomStep) end)
    bind("zoom out (_)", Key.OEM_MINUS, function() zoomBy(cfg.zoomStep) end)
else
    guard.log("the UE4SS 'Key' table is missing; keybinds are unavailable")
end

-- LoopAsync fixes its interval at registration, so both loops tick fast and
-- gate on the configured period internally. That is what makes the update
-- rate and rescan interval in the menu take effect immediately instead of
-- only after a restart.
local lastMove, lastScan = 0.0, 0.0

guard.register("movement loop", function()
    LoopAsync(50, guard.loopBody("movementTick", function()
        local now = os.clock()
        if (now - lastMove) * 1000.0 < (cfg.moveIntervalMs or 100) then return end
        lastMove = now
        movementTick()
    end, function() return cfg.enabled end))
end)

guard.register("scan loop", function()
    LoopAsync(500, guard.loopBody("scanTick", function()
        local now = os.clock()
        if (now - lastScan) * 1000.0 < (cfg.scanIntervalMs or 4000) then return end
        lastScan = now
        scanTick()
    end, function() return cfg.enabled end))
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

guard.log("PalMiniMap 2.0.5 loaded - F1 megazoom, F2 corner, F3 show/hide, F4 edit, F5 menu, +/- zoom")
