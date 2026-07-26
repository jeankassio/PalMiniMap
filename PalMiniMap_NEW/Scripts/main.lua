-- =====================================================================
-- PalMiniMap 2.0.6 - a native minimap for Palworld
--
-- No blueprint, no .pak, no shipped assets. The whole mod is this Lua
-- script driving UMG through UE4SS reflection, drawing the game's own
-- world map texture and the game's own icon textures.
--
-- Keys:  F1 megazoom  F2 corner  F3 show/hide  F4 edit  F5 menu  +/- zoom
--
-- ---------------------------------------------------------------------
-- THREADING - read this before changing anything in this file.
--
-- 2.0.5 crashed with
--     [UE4SS.EngineTick.LuaModImpl] Hook threw exception:
--     "[Lua::Registry::get_function_ref] Ref was not function", removing hook!
-- a few seconds after entering edit mode and pressing the arrow keys.
--
-- Cause: every `ExecuteInGameThread` call takes a Lua registry reference
-- (luaL_ref) and the engine tick releases it (luaL_unref) after running
-- it. The Lua registry is ONE shared, unlocked structure. 2.0.5 had FOUR
-- LoopAsync timer threads (50 ms, 250 ms, 500 ms, 2 s) plus the UE4SS
-- input thread all making refs into it - about 27 a second at idle and
-- more while keys were held. Two threads reaching the registry free list
-- at the same time hand out the SAME index twice; one of the two actions
-- is then unref'd while the other is still queued, and the engine tick
-- reads a slot that no longer holds a function - the error above. UE4SS
-- then removes its own tick hook, so the whole mod stops and the game
-- follows it down.
--
-- The fix is structural, not a guard:
--   * ONE LoopAsync. It is the only thread that ever calls
--     ExecuteInGameThread, so there is nothing to race with the game
--     thread's unref.
--   * It dispatches only when a sub-tick is actually due, so the idle
--     cost is one dispatch every 2 s instead of 27 a second.
--   * KEY BINDS NO LONGER TOUCH THE GAME THREAD AT ALL. They only append
--     a string to a queue - plain Lua, no reflection, no registry ref -
--     and the pump drains that queue on the game thread. Besides taking
--     the input thread out of the race, this removes the re-entrancy
--     risk of appending to the engine tick's action list from inside a
--     callback the engine tick itself may be dispatching.
--
-- So: never call ExecuteInGameThread, LoopAsync or any UObject method
-- from a key bind here. Push an action name and let pump() do it.
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
-- Deferred settings write
--
-- Holding an arrow key in edit mode used to rewrite the settings file on
-- every single press, and so did every zoom step. The file write is
-- blocking IO on the game thread; coalescing it into one write a second
-- removes a hitch nobody should have had to notice.
-- ---------------------------------------------------------------
local SAVE_DELAY = 1.0
local saveAt = nil

local function markDirty()
    local due = os.clock() + SAVE_DELAY
    if saveAt == nil or due < saveAt then saveAt = due end
end

local function flushSave()
    if saveAt ~= nil and os.clock() >= saveAt then
        saveAt = nil
        config.save()
    end
end

-- ---------------------------------------------------------------
-- Cheap access to the player
--
-- UEHelpers.GetPlayerController() runs FindAllOf("PlayerController") - a
-- full walk of the UObject array - on EVERY call. At 10 Hz that would
-- cost more than the entire rest of the mod, so the controller is found
-- once and cached; the pawn is read off it as a property, which is a
-- single reflection read and always current.
--
-- The PAWN is deliberately NOT cached. A cached pawn pointer outlives a
-- respawn or a level stream-out, and IsValid() on freed memory is exactly
-- the read that produced 1.x's uncatchable access violations.
-- ---------------------------------------------------------------
local gameplayStatics = nil
local cachedPC = nil
local pcRetryAt = 0.0

local function statics()
    if gameplayStatics == nil or not guard.alive(gameplayStatics) then
        gameplayStatics = guard.get(StaticFindObject,
            "/Script/Engine.Default__GameplayStatics")
    end
    return gameplayStatics
end

-- The LOCAL controller specifically. On a co-op host the object array
-- holds a PlayerController per connected player, and taking whichever
-- came first would centre the minimap on somebody else's character.
local function isLocal(pc)
    return guard.get(function() return pc:IsLocalPlayerController() end) == true
end

local function findController()
    -- FindFirstOf stops at the first match; FindAllOf walks the whole
    -- object array and builds a table. Only fall back to the slow one.
    if FindFirstOf ~= nil then
        local pc = guard.get(FindFirstOf, "PlayerController")
        if guard.alive(pc) and isLocal(pc) then return pc end
    end
    local found = guard.get(FindAllOf, "PlayerController")
    if type(found) ~= "table" then return nil end
    local fallback = nil
    for i = 1, #found do
        local pc = found[i]
        if guard.alive(pc) then
            if isLocal(pc) then return pc end
            fallback = fallback or pc
        end
    end
    -- a build where IsLocalPlayerController is unavailable still works
    return fallback
end

local function playerController()
    if guard.alive(cachedPC) then return cachedPC end
    cachedPC = nil
    -- do not walk the object array more than once a second while the
    -- world has no controller yet (title screen, loading)
    local now = os.clock()
    if now < pcRetryAt then return nil end
    pcRetryAt = now + 1.0
    cachedPC = findController()
    return cachedPC
end

local function playerPawn()
    local pc = playerController()
    if pc == nil then return nil end
    local pawn = guard.get(function() return pc.Pawn end)
    if guard.alive(pawn) then return pawn end
    pawn = guard.get(function() return pc:K2_GetPawn() end)
    if guard.alive(pawn) then return pawn end
    local gs = statics()
    if gs ~= nil then
        pawn = guard.get(function() return gs:GetPlayerPawn(pc, 0) end)
        if guard.alive(pawn) then return pawn end
    end
    return nil
end

-- x, y, yaw, speed of the local player, or nil while the world is not
-- playable. Computed at most once per pump tick and shared by every
-- sub-tick that needs it.
local function readPlayerState()
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
    return { x = x, y = y, yaw = yaw, speed = speed, pawn = pawn }
end

local frameState = nil   -- player state for the current pump tick

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
-- GetViewportSize reports PIXELS, but a UMG CanvasPanel positions its
-- children in slate units, which are pixels divided by the UI's DPI
-- scale. On a 4K screen Palworld runs a scale of about 2, so treating the
-- pixel size as canvas space puts a window meant for x=1570 at 3140 real
-- pixels, off the right-hand edge. Everything downstream works in slate
-- units, so the division belongs here, once.
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

local function viewportOrDefault()
    local w, h = viewportSize()
    return w or 1920, h or 1080
end

-- True while the game is showing its own pause/system menu.
--
-- HISTORY, because two attempts at this have already gone wrong. 2.0.2
-- inferred it from pc.bShowMouseCursor, which Palworld leaves ON during
-- ordinary gameplay, so the minimap was hidden permanently. 2.0.4
-- replaced that with "is WBP_InGameMainMenu_C in the viewport" - but that
-- class name was a guess, and it does not fire.
--
-- The primary signal is now UGameplayStatics::IsGamePaused, which is not
-- a guess about asset names at all: opening the Esc menu (and the map and
-- inventory screens) pauses a solo game, and the call is one cached
-- reflection hop, cheap enough for the movement tick.
--
-- The widget test is kept as a second opinion, because a co-op session
-- does not pause. It is searched for on every maintenance tick while it
-- has never been found - a menu widget that only exists while the menu is
-- open would be missed entirely by a long back-off - and the search stops
-- once found or after a couple of minutes of never finding it.
local GAME_MENU_CLASS = "WBP_InGameMainMenu_C"
local GAME_MENU_TRIES = 60
local GAME_MENU_SLOW  = 30.0
local gameMenuWidget = nil
local gameMenuTries = 0
local gameMenuRetryAt = 0.0

local function refreshGameMenuWidget()
    if not cfg.hideBehindGameUi then return end
    if guard.alive(gameMenuWidget) then return end
    gameMenuWidget = nil
    if gameMenuTries >= GAME_MENU_TRIES then
        local now = os.clock()
        if now < gameMenuRetryAt then return end
        gameMenuRetryAt = now + GAME_MENU_SLOW
    end
    gameMenuTries = gameMenuTries + 1
    local found = guard.get(FindAllOf, GAME_MENU_CLASS)
    if type(found) ~= "table" then return end
    for i = 1, #found do
        if guard.alive(found[i]) then
            gameMenuWidget = found[i]
            guard.log("found the game's menu widget (" .. GAME_MENU_CLASS .. ")")
            return
        end
    end
end

local function gamePaused()
    local gs = statics()
    local pc = playerController()
    if gs == nil or pc == nil then return false end
    return guard.get(function() return gs:IsGamePaused(pc) end) == true
end

local function gameUiOpen()
    if not cfg.hideBehindGameUi then return false end
    if menu.isOpen() then return false end   -- our own window may stay up
    if gamePaused() then return true end
    if not guard.alive(gameMenuWidget) then return false end
    return guard.get(function() return gameMenuWidget:IsInViewport() end) == true
end

-- Diagnostic for exactly the problem above: with this on, every
-- maintenance tick lists the widget classes currently in the viewport, so
-- opening the Esc menu once tells us what it is really called instead of
-- guessing. Off by default - it walks the whole UObject array and asks
-- every widget for its class name.
local function logViewportWidgets()
    if not cfg.logGameUiWidgets then return end
    local found = guard.get(FindAllOf, "UserWidget")
    if type(found) ~= "table" then return end
    local names, seen = {}, {}
    for i = 1, #found do
        local w = found[i]
        if guard.alive(w)
           and guard.get(function() return w:IsInViewport() end) == true then
            local c = guard.get(function() return w:GetClass():GetFName():ToString() end)
            c = c and tostring(c) or nil
            if c ~= nil and not seen[c] then
                seen[c] = true
                names[#names + 1] = c
            end
        end
    end
    guard.log("widgets in viewport (" .. #names .. "): " .. table.concat(names, ", "))
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

-- Rebuild right now instead of waiting for the next maintenance tick.
-- Used by everything that changes the built geometry (the size slider,
-- +/- in edit mode); without it the minimap vanished for up to two
-- seconds after every single size step.
local function rebuildNow()
    render.destroy()
    ensureWidget()
end

-- ---------------------------------------------------------------
-- Sub-ticks
-- ---------------------------------------------------------------
local NO_MARKS = {}

local function movementTick()
    if not render.isBuilt() then return end
    local p = frameState
    if p == nil then return end
    -- hide behind the game's own menus, and while inside a base camp if
    -- the user asked for that
    local hide = gameUiOpen()
                 or (cfg.autohideInBase and sources.insideBaseCamp())
    if hide == render.isVisible() then
        render.setVisible(not hide)
    end
    if hide then return end
    -- The teleport/streaming guard only has to keep us away from OTHER
    -- actors; the terrain and the player marker are the player's own pawn
    -- and plain arithmetic. 2.0.5 skipped the whole draw, so the minimap
    -- went blank for ten seconds after every load screen and every fast
    -- travel. Now it keeps drawing the map and just shows no markers.
    local marks, count = NO_MARKS, 0
    if settled() then marks, count = sources.collect(cfg) end
    render.update(cfg, p, marks, count)
end

-- Static points of interest do not move, so they are rescanned far less
-- often than pals are: each rescan is a FindAllOf per class - a full walk
-- of the UObject array, eleven of them - and doing that every 4 s was the
-- single most expensive thing the mod did. Now it happens on a slow timer
-- or when the player has actually travelled somewhere new.
local STATIC_MIN_INTERVAL = 15000            -- ms
local STATIC_MOVE_TRIGGER = sources.STATIC_PAD or 15000   -- world units
local lastStaticAt = 0.0
local staticX, staticY = nil, nil

local function scanTick()
    if not settled() then return end
    local p = frameState
    if p == nil then return end
    local zoom = render.effectiveZoom(cfg, p.speed)

    -- the player character doubles as the reference for IsFriend
    sources.scanDynamic(cfg, p.x, p.y, zoom, p.pawn)

    local now = os.clock() * 1000.0
    local moved = true
    if staticX ~= nil then
        local dx, dy = p.x - staticX, p.y - staticY
        moved = (dx * dx + dy * dy) > (STATIC_MOVE_TRIGGER * STATIC_MOVE_TRIGGER)
    end
    local due = (now - lastStaticAt) >= math.max(STATIC_MIN_INTERVAL,
                                                 cfg.scanIntervalMs or 4000)
    if moved or due then
        lastStaticAt = now
        staticX, staticY = p.x, p.y
        sources.scanStatic(cfg, p.x, p.y, zoom)
    end
    sources.updateProximity(cfg, p.x, p.y)
end

local function maintenanceTick()
    local name = currentWorldName()
    if name == nil then
        render.destroy()
        sources.forget()
        cachedPC = nil
        gameMenuWidget = nil
        staticX, staticY = nil, nil
        worldName = ""
        return
    end
    if name ~= worldName then
        worldName = name
        render.destroy()
        sources.forget()
        menu.worldChanged(name)   -- the menu widget died with the old world
        worldmap.recalibrate()
        gameMenuWidget = nil
        gameMenuRetryAt = 0.0
        staticX, staticY = nil, nil
        lastX, lastY = nil, nil
        beQuiet(nil)
    end
    if NON_GAME_WORLDS[name] then return end

    watchTeleport(frameState)
    refreshGameMenuWidget()
    logViewportWidgets()
    ensureWidget()
    worldmap.calibrate()
end

-- ---------------------------------------------------------------
-- Controls
--
-- Forward declarations: `zoomBy` needs `editMode` and `resize`, which are
-- defined below it. Without these two lines both resolved to globals -
-- i.e. to nil - so +/- in edit mode silently fell through to the zoom
-- path and the window could never be resized.
-- ---------------------------------------------------------------
local editMode = false
local resize

-- A negative coordinate is a margin measured from the right/bottom edge,
-- so these presets stay correct at any window size and any resolution.
local CORNERS = {
    { x = -40, y =  40 },   -- top right
    { x =  40, y =  40 },   -- top left
    { x =  40, y = -40 },   -- bottom left
    { x = -40, y = -40 },   -- bottom right
}

-- Start the cycle from wherever the saved layout already is, so the first
-- F2 press moves to the NEXT corner instead of re-selecting the current
-- one (2.0.5 always jumped to top-left first).
local cornerIndex = 0
for i = 1, #CORNERS do
    if cfg.x == CORNERS[i].x and cfg.y == CORNERS[i].y then cornerIndex = i end
end

local function toggleVisible()
    cfg.enabled = not cfg.enabled
    render.setVisible(cfg.enabled)
    markDirty()
    guard.log("minimap " .. (cfg.enabled and "shown" or "hidden"))
end

local function cycleCorner()
    cornerIndex = (cornerIndex % #CORNERS) + 1
    local c = CORNERS[cornerIndex]
    cfg.x, cfg.y = c.x, c.y
    local vw, vh = viewportSize()
    render.applyLayout(cfg, vw, vh)
    markDirty()
end

-- `dir` is -1 to zoom in, +1 to zoom out.
--
-- The step is MULTIPLICATIVE. 2.0.5 added or subtracted a flat 2000 world
-- units, so crossing the 4 000 - 120 000 range took fifty-eight key
-- presses, and the same press that barely moved the view when zoomed out
-- halved it when zoomed in. A constant ratio feels the same at every
-- level and crosses the range in about fifteen.
local function zoomBy(dir)
    if menu.isOpen() then return end
    if editMode then
        -- in edit mode +/- resize the window instead, exactly as in 1.x
        resize(dir < 0 and 10 or -10)
        return
    end
    local factor = config.clamp(cfg.zoomFactor or 1.25, 1.05, 2.0)
    if dir < 0 then factor = 1.0 / factor end
    cfg.zoom = config.clamp(cfg.zoom * factor, cfg.zoomMin, cfg.zoomMax)
    markDirty()
end

local function toggleMegazoom()
    cfg.megazoomActive = not cfg.megazoomActive
    sources.forget()          -- the scan radius changes with the zoom mode
    markDirty()
    guard.log("megazoom " .. (cfg.megazoomActive and "on" or "off"))
end

-- Edit mode (1.x F4): arrow keys move the window, +/- resize it.
--
-- While editing, the position is held in ABSOLUTE slate units. Nudging an
-- edge-relative coordinate (the default x = -40) across zero used to flip
-- its meaning from "40 from the right edge" to "40 from the left edge",
-- so the minimap teleported across the screen mid-drag. On exit the
-- coordinate is converted back to edge-relative for whichever edge it
-- ended up nearer, which is what keeps a saved layout correct after a
-- resolution change.
local function toAbsolute()
    local vw, vh = viewportOrDefault()
    if cfg.x < 0 then cfg.x = vw + cfg.x - cfg.size end
    if cfg.y < 0 then cfg.y = vh + cfg.y - cfg.size end
end

local function toEdgeRelative()
    local vw, vh = viewportOrDefault()
    if cfg.x >= 0 and (cfg.x + cfg.size * 0.5) > vw * 0.5 then
        cfg.x = cfg.x + cfg.size - vw
    end
    if cfg.y >= 0 and (cfg.y + cfg.size * 0.5) > vh * 0.5 then
        cfg.y = cfg.y + cfg.size - vh
    end
end

local function toggleEditMode()
    editMode = not editMode
    if editMode then toAbsolute() else toEdgeRelative() end
    render.setEditMode(editMode)
    local vw, vh = viewportSize()
    render.applyLayout(cfg, vw, vh)
    if not editMode then markDirty() end
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

resize = function(delta)
    cfg.size = config.clamp(cfg.size + delta, 120, 480)
    rebuildNow()
    markDirty()
end

local function toggleMenu()
    -- logged unconditionally: when the menu did not appear in 2.0.3 there
    -- was no line at all, which left no way to tell "key never fired"
    -- from "opened but invisible"
    guard.log("F5 pressed (world='" .. tostring(worldName) .. "')")
    menu.toggle(cfg, worldName)
end

-- ---------------------------------------------------------------
-- Menu wiring
--
-- Anything the menu changes has to take effect immediately. Most settings
-- are simply read on the next tick, but a size change means the widget
-- was built at the wrong dimensions, and the axis controls have to be
-- pushed into worldmap before the next draw.
-- ---------------------------------------------------------------
-- `circular` is here because the disc is real clipped geometry now, not a
-- decal painted over a square map, so the shape is decided at build time.
local REBUILD_KEYS = {
    size = true, maxPalIcons = true, maxPoiIcons = true, circular = true,
}

menu.onCommit = function(keys)
    local rebuild, relayout, rescan = false, false, false
    for _, key in ipairs(keys) do
        if REBUILD_KEYS[key] then
            rebuild = true
            -- the icon caps are applied at scan time, so the new limit
            -- only shows up once the world has been looked at again
            rescan = true
        elseif key == "mapQuality" then
            render.applyQuality(cfg)
        elseif key == "opacity" then relayout = true
        elseif key:sub(1, 5) == "axis." then worldmap.setAxis(cfg.axis)
        elseif key == "enabled" then render.setVisible(cfg.enabled)
        elseif key:sub(1, 4) == "show" or key == "onlyShinyPals"
            or key == "hideCollected" or key == "megazoom"
            or key == "zoom" then
            -- the filter set or the scan radius changed: drop what we
            -- have so the next scan repopulates from scratch
            rescan = true
        end
    end
    if rescan then
        sources.forget()
        staticX, staticY = nil, nil
    end
    if rebuild then
        rebuildNow()
    elseif relayout then
        local vw, vh = viewportSize()
        render.applyLayout(cfg, vw, vh)
    end
    markDirty()
end

-- The menu gets accessors, never cached objects. Holding a title-screen
-- PlayerController across polls is what crashed 2.0.2: that controller is
-- destroyed as the title flow advances, and the next SetInputMode call
-- landed on freed memory (an access violation, which no pcall catches).
menu.env = {
    controller  = playerController,
    viewport    = viewportSize,
    -- The world-name blocklist is a guess at what Palworld calls its
    -- title screens, and getting it wrong reintroduces the 2.0.2 crash
    -- (SetInputMode on a title-screen controller that is about to be
    -- destroyed). "There is a pawn to control" is not a guess: the splash,
    -- login and title flows have none, and a real world always does.
    isGameWorld = function()
        if worldName == "" or NON_GAME_WORLDS[worldName] then return false end
        return playerPawn() ~= nil
    end,
}

-- ---------------------------------------------------------------
-- Key binds -> action queue
--
-- See the threading note at the top of this file: these callbacks run on
-- the UE4SS input thread and must stay pure Lua. Appending a string to a
-- table is the whole of what they are allowed to do.
-- ---------------------------------------------------------------
local ACTIONS = {
    menu      = toggleMenu,
    megazoom  = toggleMegazoom,
    visible   = toggleVisible,
    corner    = cycleCorner,
    edit      = toggleEditMode,
    left      = function() nudge(-10, 0) end,
    right     = function() nudge(10, 0) end,
    up        = function() nudge(0, -10) end,
    down      = function() nudge(0, 10) end,
    zoomIn    = function() zoomBy(-1) end,
    zoomOut   = function() zoomBy(1) end,
}

-- Bounded, so a pump that has stopped for any reason cannot turn a stuck
-- key into unbounded memory growth.
local QUEUE_LIMIT = 32
local queue = {}
local queueCount = 0

local function request(name)
    if queueCount >= QUEUE_LIMIT then return end
    queueCount = queueCount + 1
    queue[queueCount] = name
end

local function drainQueue()
    if queueCount == 0 then return end
    -- swap first: an input-thread append that lands during the drain goes
    -- into the fresh table and is simply handled on the next tick
    local pendingActions, pendingCount = queue, queueCount
    queue, queueCount = {}, 0
    for i = 1, pendingCount do
        local fn = ACTIONS[pendingActions[i]]
        if fn ~= nil then guard.try("action " .. pendingActions[i], fn) end
    end
end

-- ---------------------------------------------------------------
-- The pump - the only place that runs on the game thread
-- ---------------------------------------------------------------
local PUMP_MS   = 33      -- timer resolution; NOT the dispatch rate
local MENU_MS   = 250
local MAINT_MS  = 2000

local lastMove, lastScan, lastMenu, lastMaint = 0.0, 0.0, 0.0, 0.0

-- Evaluated on the TIMER thread, so a tick with nothing to do costs no
-- game-thread dispatch and therefore no registry reference at all. Keep
-- it pure Lua - no reflection, no UObjects.
local function anythingDue()
    if queueCount > 0 then return true end
    if saveAt ~= nil and os.clock() >= saveAt then return true end
    local now = os.clock() * 1000.0
    if (now - lastMaint) >= MAINT_MS then return true end
    if menu.isOpen() and (now - lastMenu) >= MENU_MS then return true end
    if cfg.enabled then
        if (now - lastMove) >= (cfg.moveIntervalMs or 100) then return true end
        if (now - lastScan) >= (cfg.scanIntervalMs or 4000) then return true end
    end
    return false
end

local function pump()
    drainQueue()

    local now = os.clock() * 1000.0
    local wantMaint = (now - lastMaint) >= MAINT_MS
    local wantMenu  = menu.isOpen() and (now - lastMenu) >= MENU_MS
    local wantScan  = cfg.enabled and (now - lastScan) >= (cfg.scanIntervalMs or 4000)
    local wantMove  = cfg.enabled and (now - lastMove) >= (cfg.moveIntervalMs or 100)

    -- read the player ONCE per tick and share it; every sub-tick below
    -- uses plain numbers off it, and it is dropped again before the tick
    -- returns so no actor reference ever survives to the next one
    if wantMaint or wantScan or wantMove then
        frameState = guard.get(readPlayerState)
    end

    if wantMaint then
        lastMaint = now
        guard.try("maintenanceTick", maintenanceTick)
    end
    if wantMenu then
        lastMenu = now
        guard.try("menuPoll", function() menu.poll(cfg) end)
    end
    if wantScan then
        lastScan = now
        guard.try("scanTick", scanTick)
    end
    if wantMove then
        lastMove = now
        guard.try("movementTick", movementTick)
    end

    frameState = nil
    flushSave()
end

-- ---------------------------------------------------------------
-- Registration - each item on its own, so one failure costs only itself
-- ---------------------------------------------------------------
guard.register("world transition hook", function()
    RegisterLoadMapPreHook(guard.callback("LoadMapPreHook", function()
        render.destroy()
        sources.forget()
        cachedPC = nil
        gameMenuWidget = nil
        staticX, staticY = nil, nil
        worldName = ""
        beQuiet(nil)
    end))
end)

local function bind(label, key, action)
    guard.register(label, function()
        RegisterKeyBind(key, guard.callback(label, function() request(action) end))
    end)
end

if type(Key) == "table" then
    bind("config menu (F5)", Key.F5, "menu")
    bind("megazoom (F1)", Key.F1, "megazoom")
    bind("cycle corner (F2)", Key.F2, "corner")
    bind("toggle minimap (F3)", Key.F3, "visible")
    bind("edit mode (F4)", Key.F4, "edit")
    -- UE4SS names the arrows *_ARROW; plain LEFT/RIGHT/UP/DOWN do not
    -- exist, so 2.0.2 failed to bind all four and edit mode could never
    -- be moved.
    bind("edit move left",  Key.LEFT_ARROW,  "left")
    bind("edit move right", Key.RIGHT_ARROW, "right")
    bind("edit move up",    Key.UP_ARROW,    "up")
    bind("edit move down",  Key.DOWN_ARROW,  "down")
    bind("zoom in (+)",  Key.ADD,        "zoomIn")
    bind("zoom in (=)",  Key.OEM_PLUS,   "zoomIn")
    bind("zoom out (-)", Key.SUBTRACT,   "zoomOut")
    bind("zoom out (_)", Key.OEM_MINUS,  "zoomOut")
else
    guard.log("the UE4SS 'Key' table is missing; keybinds are unavailable")
end

-- ONE loop. See the threading note at the top of this file before adding
-- a second one.
guard.register("pump loop", function()
    LoopAsync(PUMP_MS, guard.loopBody("pump", pump, anythingDue))
end)

guard.log("PalMiniMap 2.0.8 loaded - F1 megazoom, F2 corner, F3 show/hide, F4 edit, F5 menu, +/- zoom")
