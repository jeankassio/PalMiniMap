-- =====================================================================
-- PalMiniMap 2.3.6 - a native minimap for Palworld
--
-- No blueprint, no .pak, no cooked content. The whole mod is this Lua
-- script driving UMG through UE4SS reflection. Since 2.3 the terrain is a
-- SECOND, THROTTLED RENDER of the world from above (capture.lua), so it
-- works inside dungeons and at the edges of the world where the game's
-- painted map has nothing; the game's own map texture is still there for
-- the zoomed-right-out view, where too little of the world is streamed in
-- to render.
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
--   * ONE LoopAsync, dispatching only when a sub-tick is actually due, so
--     the idle cost is one dispatch every 2 s instead of 27 a second.
--   * KEY BINDS NO LONGER TOUCH THE GAME THREAD AT ALL. They only append
--     a string to a queue - plain Lua, no reflection, no registry ref -
--     and the pump drains that queue on the game thread. Besides taking
--     the input thread out of the race, this removes the re-entrancy
--     risk of appending to the engine tick's action list from inside a
--     callback the engine tick itself may be dispatching.
--
-- 2.1.0 CORRECTS THE ANALYSIS ABOVE. Cutting it to one timer thread made
-- this rare, and 2.0.6's note claimed there was "nothing left to race
-- with". That was wrong, and the mod froze again while the settings window
-- was being used - same corruption, but this time UE4SS only removed its
-- tick hook instead of taking the game down. The surviving race is not
-- between two timer threads: it is between the TIMER thread taking a
-- reference and the GAME thread releasing the previous one as a pump
-- returns, and it widens with the length of the pump. So, on top of the
-- above (see the dispatcher near the bottom of this file):
--   * at most ONE dispatch outstanding, so a reference is never taken
--     while the game thread is inside our code;
--   * a gap after a pump ENDS before the next reference is taken;
--   * nothing on the input thread or the timer thread may ALLOCATE - an
--     allocation can advance Lua's collector, and two threads collecting
--     in one lua_State is the same corruption by another route. That is
--     why the action queue is a fixed, preallocated ring buffer and why
--     the due-check is pure arithmetic;
--   * expensive work is coalesced rather than run per event, because a
--     long pump is what opens the window in the first place.
--
-- So: never call ExecuteInGameThread, LoopAsync or any UObject method
-- from a key bind here. Push an action name and let pump() do it.
-- =====================================================================

local guard = require("guard")

-- Where this file lives, so the settings sit next to the mod.
--
-- IN GAME THIS USED TO FAIL SILENTLY, and the settings ended up in
-- Pal/Binaries/ - outside the mod entirely, because `(SCRIPT_DIR or ".")`
-- fell through to the game's working directory. UE4SS does not always give
-- the chunk a path for a name, so `debug.getinfo().source` can be a bare
-- "main.lua" with no directory in it at all.
--
-- Every candidate is therefore CHECKED by opening a file that must exist
-- beside it, rather than trusted. The second candidate is package.path,
-- which is authoritative for a different reason: require("guard") has
-- already succeeded by the time anything here runs, so one of its entries
-- provably points at this folder.
local function canOpen(p)
    local ok, f = pcall(io.open, p, "r")
    if not ok or not f then return false end
    pcall(function() f:close() end)
    return true
end

local function looksLikeOurFolder(dir)
    return dir ~= nil and dir ~= "" and canOpen(dir .. "/guard.lua")
end

local function scriptDirectory()
    if debug ~= nil and debug.getinfo ~= nil then
        local ok, info = pcall(debug.getinfo, 1, "S")
        if ok and type(info) == "table" and type(info.source) == "string" then
            local source = info.source
            if source:sub(1, 1) == "@" then source = source:sub(2) end
            source = source:gsub("\\", "/")
            local dir = source:match("^(.+)/[^/]+$")
            if looksLikeOurFolder(dir) then return dir end
        end
    end

    if type(package) == "table" and type(package.path) == "string" then
        for entry in package.path:gmatch("[^;]+") do
            local dir = entry:gsub("\\", "/"):match("^(.*)/%?%.lua$")
            if looksLikeOurFolder(dir) then return dir end
        end
    end

    return nil
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
local assets   = needModule("assets")
local capture  = needModule("capture")
local render   = needModule("render")
local sources  = needModule("sources")
local menu     = needModule("menu")
local gameui   = needModule("gameui")
local uiprobe  = needModule("uiprobe")
local keys     = needModule("keys")
if config == nil or worldmap == nil or assets == nil or capture == nil
   or render == nil or sources == nil or menu == nil or gameui == nil
   or uiprobe == nil or keys == nil then
    guard.log("PalMiniMap is disabled for this session (missing module above).")
    do return end
end

-- The shipped icon PNGs sit beside Scripts/, not inside it. Without a script
-- directory there is nothing to point at, and assets.lua stays on the package
-- loader on its own - see the note it logs half a minute in.
if SCRIPT_DIR ~= nil then
    assets.setIconDir(SCRIPT_DIR .. "/../icons")
end

config.setPath((SCRIPT_DIR or ".") .. "/../minimap_settings.json")
-- config.ini lives beside the settings file, i.e. in the mod folder
-- rather than inside Scripts/, so a player never has to open the
-- script directory to rebind a key.
local KEYS_PATH = (SCRIPT_DIR or ".") .. "/../config.ini"
-- Where the settings landed while scriptDirectory() was returning nil: the
-- game's working directory, i.e. Pal/Binaries. Read from there once so a
-- player's existing layout, zoom and toggles survive the fix; the next save
-- writes to the proper place beside the mod.
config.setLegacyPaths({
    "./../minimap_settings.json",
    "minimap_settings.json",
})
local cfg = config.load()
if SCRIPT_DIR == nil then
    guard.log("could not work out where this script lives; settings will be read and "
        .. "written relative to the game's working directory instead of the mod folder")
end

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

-- Hoisted reflection thunks. See the note in guard.get: passing arguments
-- instead of closing over them is what keeps the 10 Hz path from
-- allocating a fistful of garbage every frame.
local function rawIsLocal(pc) return pc:IsLocalPlayerController() end
local function rawPawnProp(pc) return pc.Pawn end
local function rawGetPawn(pc) return pc:K2_GetPawn() end
local function rawStaticsPawn(gs, pc) return gs:GetPlayerPawn(pc, 0) end
local function rawControlRotation(pc) return pc:GetControlRotation().Yaw end
local function rawActorYaw(pawn) return pawn:K2_GetActorRotation().Yaw end
local function rawVelocity(pawn)
    local v = pawn:GetVelocity()
    return v.X, v.Y, v.Z
end
local function rawInViewport(w) return w:IsInViewport() end
local function rawWorldName(pc) return pc:GetWorld():GetFName():ToString() end
local function rawClassName(o) return o:GetClass():GetFName():ToString() end

-- The LOCAL controller specifically. On a co-op host the object array
-- holds a PlayerController per connected player, and taking whichever
-- came first would centre the minimap on somebody else's character.
local function isLocal(pc)
    return guard.get(rawIsLocal, pc) == true
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
    local pawn = guard.get(rawPawnProp, pc)
    if guard.alive(pawn) then return pawn end
    pawn = guard.get(rawGetPawn, pc)
    if guard.alive(pawn) then return pawn end
    local gs = statics()
    if gs ~= nil then
        pawn = guard.get(rawStaticsPawn, gs, pc)
        if guard.alive(pawn) then return pawn end
    end
    return nil
end

-- x, y, camera yaw, body yaw and speed of the local player, or nil while the world is not 
-- playable. Computed at most once per pump tick and shared by every
-- sub-tick that needs it.
local frameStateBuf = { x = 0, y = 0, z = 0, yaw = 0, bodyYaw = 0, speed = 0, pawn = nil }

local function readPlayerState()
    local pawn = playerPawn()
    if pawn == nil then return nil end
    -- Z is read here for the live terrain capture, which puts its camera a
    -- fixed height above the player; nothing else in the mod uses it.
    local x, y, z = sources.actorLocation3(pawn)
    if x == nil then return nil end
    -- Camera/control yaw drives the terrain rotation and view cone. Actor
    -- yaw is kept separately so the small player arrow shows the character's
    -- body direction, as in Genshin Impact and Wuthering Waves.
    local yaw = 0.0
    local pc = playerController()
    local y2 = pc and guard.get(rawControlRotation, pc) or nil
    if type(y2) ~= "number" then y2 = guard.get(rawActorYaw, pawn) end
    if type(y2) == "number" then yaw = y2 end

    local bodyYaw = guard.get(rawActorYaw, pawn)
    if type(bodyYaw) ~= "number" then bodyYaw = yaw end
    -- speed drives autozoom; velocity is centimetres per second.
    -- pcall directly, not guard.get: guard.get returns only the FIRST
    -- result and this needs three.
    local speed = 0.0
    local ok, vx, vy, vz = pcall(rawVelocity, pawn)
    if ok and type(vx) == "number" and type(vy) == "number" then
        speed = math.sqrt(vx * vx + vy * vy + (type(vz) == "number" and vz * vz or 0))
    end
    -- reused: this table is rebuilt ten times a second and never escapes
    -- the tick that made it
    local st = frameStateBuf
    st.x, st.y, st.z = x, y, z
    st.yaw, st.bodyYaw = yaw, bodyYaw
    st.speed, st.pawn = speed, pawn
    return st
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
            lastDrawSourceVersion = -1
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
    local n = guard.get(rawWorldName, pc)
    if n == nil then return nil end
    return tostring(n)
end

-- "This is a real, playable world."
--
-- The world-name blocklist alone is a GUESS at what Palworld calls its
-- title screens, and getting it wrong reintroduces the 2.0.2 crash
-- (SetInputMode on a title-screen controller about to be destroyed).
-- "There is a pawn to control" is not a guess: the splash, login and title
-- flows have none, and a real world always does. Both are required.
local function inGameWorld()
    if worldName == "" or NON_GAME_WORLDS[worldName] then return false end
    return playerPawn() ~= nil
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

-- Whether the game has one of its own screens up lives in gameui.lua -
-- see the five failed attempts documented there.
--
-- The player POSITION is handed over so gameui can notice a signal that
-- has got stuck: nobody walks twenty metres with a chest open. It is
-- position and not the speed 2.2.7 passed, because speed comes from
-- GetVelocity() and on a build where that reflection call fails it stays
-- 0.0 forever - which is exactly why 2.2.7's watchdog never fired and the
-- minimap stayed hidden for the whole session.
local function gameUiOpen(px, py)
    if menu.isOpen() then return false end   -- our own window may stay up
    return gameui.isOpen(cfg, statics(), playerController(), px, py)
end

local function forgetGameMenu() gameui.forget(); uiprobe.forget() end

-- Diagnostic for exactly the problem above: with this on, every
-- maintenance tick lists the widget classes currently in the viewport, so
-- opening the Esc menu once tells us what it is really called instead of
-- guessing. Off by default - it walks the whole UObject array and asks
-- every widget for its class name.
local function logViewportWidgets()
    if not cfg.logGameUiWidgets then return end
    guard.log("game UI state:\n" .. gameui.describe(playerController()))
    local found = guard.get(FindAllOf, "UserWidget")
    if type(found) ~= "table" then return end
    local names, seen = {}, {}
    for i = 1, #found do
        local w = found[i]
        if guard.alive(w) and guard.get(rawInViewport, w) == true then
            local c = guard.get(rawClassName, w)
            c = c and tostring(c) or nil
            if c ~= nil and not seen[c] then
                seen[c] = true
                names[#names + 1] = c
            end
        end
    end
    guard.log("widgets in viewport (" .. #names .. "): " .. table.concat(names, ", "))
end

-- ---------------------------------------------------------------
-- Edit mode (F4)
--
-- Declared up here, ahead of the rebuild machinery, because that machinery
-- has to honour it: WHILE EDIT MODE IS ON, NOTHING REBUILDS.
--
-- Dragging the window around and stepping its size is the one time the
-- player is looking straight at the minimap and changing it continuously,
-- and it was the one time the mod tore the whole widget down and built ~180
-- of them again - once per size step, plus once more whenever a maintenance
-- tick noticed the built size no longer matched. It flickered on every
-- press. Nothing about a rebuild is needed to place the window: the frame,
-- the backdrop and the edit highlight are all repositioned by applyLayout,
-- and the terrain quad is sized from cfg.size on the next draw anyway.
--
-- So the rebuild is simply remembered and run once, on the way out of edit
-- mode. What is genuinely baked in at build time - the circular strips and
-- the icon pool length - stays as it was until then, which is exactly the
-- "stays still while I am moving it" the player asked for.
-- ---------------------------------------------------------------
local editMode = false
local rebuildAfterEdit = false

local function ensureWidget()
    -- an existing widget is left alone while editing, however stale its
    -- built geometry has become
    if render.isBuilt() and (editMode or not render.needsRebuild(cfg)) then
        return true
    end
    -- NEVER BUILD OUTSIDE A REAL WORLD. A PlayerController exists on the
    -- title screen too, so requiring one was not enough: changing the shape
    -- in the F5 menu there went straight to rebuildNow() -> ensureWidget(),
    -- which happily built a minimap over the main menu with no terrain and
    -- no player in it - a white square. maintenanceTick had the right guard
    -- all along; this path simply did not go through it.
    if not inGameWorld() then return false end
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

-- ...but COALESCED, because a rebuild is by far the most expensive thing
-- this mod ever does on the game thread: it destroys and reconstructs up
-- to 260 UMG widgets. Clicking "Circular shape" twice, or holding +/- in
-- edit mode, used to run one of those per key press or per menu commit,
-- back to back, and that pile-up is what the freeze grew out of. One
-- rebuild 250 ms after the first request absorbs a whole burst and is not
-- perceptible.
local REBUILD_DELAY = 0.25
local rebuildAt = nil

local function requestRebuild()
    -- Deferred wholesale while the player is dragging or resizing: see the
    -- edit-mode note above. toggleEditMode() picks this up on the way out.
    if editMode then
        rebuildAfterEdit = true
        return
    end
    if rebuildAt == nil then rebuildAt = os.clock() + REBUILD_DELAY end
end

-- ---------------------------------------------------------------
-- Sub-ticks
-- ---------------------------------------------------------------
local NO_MARKS = {}

-- Set by the scan tick, consumed by the movement tick: "a new static class
-- may be started now". While the map is still filling in after a load the
-- movement tick sets it itself, so the markers appear in a couple of
-- seconds instead of one class every four.
local staticDue = false

-- IS THE MINIMAP CURRENTLY OFF SCREEN? Set by movementTick, read by pump().
--
-- THE BUG THIS EXISTS FOR (2.3.6), reported against the published build:
-- "the freezes continue even in camp, even though 'Hide the map in camp'
-- is checked... the mod continues scanning and creating a load even when
-- the map isn't displayed."
--
-- That was exactly right. `hide` only ever stopped the DRAW - movementTick
-- returns early - while the character scan, the static scan and the asset
-- pump all sit in pump() beside it and kept running at full price.
-- Measured in the soak harness: two minutes hidden still cost 90 full
-- object-array walks, and the worst hidden pump was 72% of the worst
-- visible one. For a minimap nobody can see.
--
-- Hidden now means idle. What still runs is only what is needed to notice
-- that it should come BACK: reading the player, the base-camp check and
-- the game's screen stack, none of which walk the object array.
local minimapHidden = false

local function movementTick()
    if not render.isBuilt() then return end
    local p = frameState
    if p == nil then return end

    -- Diagnostic, off unless the user turned it on in the F5 menu.
    --
    -- The flag is tested HERE, not just inside tick(): Lua evaluates the
    -- arguments first, so calling it unconditionally paid for statics()
    -- and playerController() - two IsValid calls - ten times a second in
    -- every normal session, for nothing.
    --
    -- The `ready` gate is not optional either: the first version of the
    -- probe ran behind a loading screen, walked the object array and
    -- dereferenced a half-built widget, and Palworld died with no Lua
    -- error at all. Same gate the actor scans use; same hazard.
    if cfg.logGameUiWidgets then
        uiprobe.tick(cfg, statics(), playerController(),
                     settled() and not NON_GAME_WORLDS[worldName])
    end

    -- the pawn carries the component that knows whether we are in a base
    sources.updateProximity(cfg, p.x, p.y, p.pawn)

    -- hide behind the game's own menus, and while inside a base camp if
    -- the user asked for that
    local hide = gameUiOpen(p.x, p.y)
                 or (cfg.autohideInBase and sources.insideBaseCamp())
    if hide == render.isVisible() then
        render.setVisible(not hide)
    end
    minimapHidden = hide and true or false
    if hide then return end

    local zoom = render.effectiveZoom(cfg, p.speed)

    -- THE SECOND RENDER, and note where it sits: AFTER the hide check, so
    -- nothing is rendered while the minimap is not on screen, and before
    -- the "nothing changed" shortcut below, so the world still refreshes
    -- while the player stands still. capture.lua decides whether this tick
    -- is actually one of the few a second that costs anything; when it is
    -- not, this is a handful of arithmetic.
    --
    -- Deliberately NOT behind settled(). That quiet window exists to keep
    -- the mod away from OTHER actors while a fast travel destroys and
    -- rebuilds everything around the player; this touches only our own
    -- component and the player's own pawn, both re-validated every tick.
    -- Gating it would leave the minimap showing a picture of where the
    -- player USED to be for ten seconds after every teleport, which is the
    -- same mistake 2.0.5 made by skipping the whole draw. A teleport is a
    -- huge jump, so the first tick after it re-captures on its own.
    local captured = false
    if cfg.liveTerrain then
        captured = capture.update(cfg, p.pawn, p.x, p.y, p.z, zoom, os.clock())
    end

    local sourceVersion = sources.version()
    local dirty = sources.staticDirty()

    -- If neither the player state nor the source data changed, there is
    -- nothing new to push through render.update(). Skipping the whole path
    -- here removes a lot of idle churn when the minimap is open but the
    -- player is standing still. A fresh capture counts as a change: the
    -- quad has to move to wherever the new image is centred.
    if not dirty and not captured
       and sourceVersion == lastDrawSourceVersion
       and p.x == lastDrawX and p.y == lastDrawY
       and p.yaw == lastDrawYaw and p.bodyYaw == lastDrawBodyYaw
       and p.speed == lastDrawSpeed
       and zoom == lastDrawZoom then
        return
    end

    -- The teleport/streaming guard only has to keep us away from OTHER
    -- actors; the terrain and the player marker are the player's own pawn
    -- and plain arithmetic. 2.0.5 skipped the whole draw, so the minimap
    -- went blank for ten seconds after every load screen and every fast
    -- travel. Now it keeps drawing the map and just shows no markers.
    local marks, count = NO_MARKS, 0
    if settled() then marks, count = sources.collect(cfg, p.x, p.y, zoom) end
    render.update(cfg, p, marks, count)

    lastDrawX, lastDrawY = p.x, p.y
    lastDrawYaw, lastDrawBodyYaw = p.yaw, p.bodyYaw
    lastDrawSpeed, lastDrawZoom = p.speed, zoom
    lastDrawSourceVersion = sourceVersion
end

-- The scan tick is now the DYNAMIC scan only. 2.1.1 ran the character scan
-- and a static class in the same pump, which made one tick in every forty
-- the expensive one - felt as a periodic hitch while walking. The static
-- side is driven from the movement tick instead (see below), a bounded
-- number of actors at a time, so no pump ever carries both.
--
-- 1.x reached the same conclusion by a different route: it gave every kind
-- its own timer at a different period (pals 5 s, players 12 s, chests and
-- eggs 14 s, human NPCs 19 s) so two scans essentially never landed on the
-- same frame. We cannot spend a timer per kind - see the threading note at
-- the top of this file, there is exactly one - so the separation is done
-- in the pump instead.
local function scanTick()
    if not settled() then return end
    local p = frameState
    if p == nil then return end
    local zoom = render.effectiveZoom(cfg, p.speed)

    -- the player character doubles as the reference for IsFriend
    sources.scanDynamic(cfg, p.x, p.y, zoom, p.pawn)
    sources.updateProximity(cfg, p.x, p.y, p.pawn)
    staticDue = true
end

-- One bounded slice of the static scan, on the movement tick. Deliberately
-- OUTSIDE movementTick: that returns early when the minimap is hidden or
-- when nothing moved, and the map filling in must not depend on the player
-- walking around.
local function staticTick()
    if not settled() then return end
    if not staticDue and sources.staticFilling(cfg) then staticDue = true end
    -- The player position is what decides whether a static kind is worth
    -- walking again: things only appear where the level has streamed in
    -- something new, and that happens because we TRAVELLED. Standing still,
    -- stepStatic now does nothing at all for most kinds.
    local p = frameState
    if p ~= nil then
        sources.stepStatic(cfg, staticDue, p.x, p.y)
    else
        sources.stepStatic(cfg, staticDue)
    end
    staticDue = false
end

local function maintenanceTick()
    local name = currentWorldName()
    if name == nil then
        render.destroy()
        sources.forget()
        assets.forget()           -- every UObject we cached died with it
        capture.forget()          -- ...including the capture and its target
        lastDrawSourceVersion = -1
        cachedPC = nil
        forgetGameMenu()
        worldName = ""
        return
    end
    if name ~= worldName then
        worldName = name
        render.destroy()
        sources.forget()
        assets.forget()
        capture.forget()
        lastDrawSourceVersion = -1
        menu.worldChanged(name)   -- the menu widget died with the old world
        worldmap.recalibrate()
        forgetGameMenu()
        lastX, lastY = nil, nil
        beQuiet(nil)
    end
    if NON_GAME_WORLDS[name] then return end

    watchTeleport(frameState)
    ensureWidget()
    worldmap.calibrate()
end

-- ---------------------------------------------------------------
-- Controls
--
-- Forward declaration: `zoomBy` needs `resize`, which is defined below it.
-- Without this line it resolved to a global - i.e. to nil - so +/- in edit
-- mode silently fell through to the zoom path and the window could never
-- be resized. (`editMode` is declared further up, next to the rebuild
-- machinery that has to honour it.)
-- ---------------------------------------------------------------
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
    lastDrawSourceVersion = -1
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
    if not editMode then
        markDirty()
        -- Everything the editing session changed is applied in one go now.
        -- `needsRebuild` is asked as well as the remembered flag, so a size
        -- that was changed from the F5 window while edit mode happened to be
        -- on is not left behind either.
        if rebuildAfterEdit or render.needsRebuild(cfg) then
            rebuildAfterEdit = false
            requestRebuild()
        end
    end
    guard.log("edit mode " .. (editMode and "on - arrows move, +/- resize (the minimap "
                                            .. "stays as it is until you leave)"
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
    -- The window follows the new size immediately - applyLayout moves and
    -- resizes the frame, the backdrop and the edit highlight, and the next
    -- draw scales the terrain from cfg.size. The rebuild that the circular
    -- strips and the icon pool need is what waits for F4 to be released.
    local vw, vh = viewportSize()
    render.applyLayout(cfg, vw, vh)
    requestRebuild()
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
-- are simply read on the next tick, but a size change means the widget was
-- built at the wrong dimensions.
-- ---------------------------------------------------------------
-- `circular` is here because the disc is real clipped geometry now, not a
-- decal painted over a square map, so the shape is decided at build time.
local REBUILD_KEYS = {
    size = true, maxPalIcons = true, maxPoiIcons = true, circular = true,
}

menu.onCommit = function(keys)
    local rebuild, relayout, rescan, redraw = false, false, false, false
    for _, key in ipairs(keys) do
        if REBUILD_KEYS[key] then
            rebuild = true
            -- the icon caps are applied at scan time, so the new limit
            -- only shows up once the world has been looked at again
            rescan = true
        elseif key == "mapQuality" or key == "captureStyle"
            or key == "captureHeight" then
            -- All three change how the second render is set up, so the
            -- render target and the component are rebuilt at the new
            -- settings. applyQuality also still pins the map texture's
            -- mips, which is what this key meant before 2.3.
            render.applyQuality(cfg)
            redraw = true
        elseif key == "liveTerrain" or key == "liveZoomMax" then
            -- Nothing to rebuild - but if the player is standing still,
            -- the draw path would skip the frame that would have shown
            -- them the change.
            --
            -- Unticking it also lets the capture component and its render
            -- target go. They cost nothing per frame once nobody calls
            -- update() (bCaptureEveryFrame is false), but the target is
            -- several megabytes of VRAM held for a feature now switched
            -- off, and destroy() is the only thing that frees it.
            if key == "liveTerrain" and not cfg.liveTerrain then
                capture.destroy()
            end
            redraw = true
        elseif key == "opacity" then relayout = true
        elseif key == "showViewCone" or key == "viewConeOpacity"
            or key == "viewConeSize" then
            -- These are pure draw settings. Force one update even while the
            -- player is standing still so the F5 change is visible at once.
            redraw = true
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
        sources.forget()   -- the per-kind caches rebuild on the next tick
        redraw = true
    end
    -- The draw path skips a tick where nothing about the player or the
    -- world data changed, so anything that only changes how things are
    -- DRAWN has to invalidate that comparison itself.
    if redraw then lastDrawSourceVersion = -1 end
    if rebuild then
        requestRebuild()
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
    -- Same predicate the widget build uses; see inGameWorld().
    isGameWorld = inGameWorld,
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

-- A FIXED RING BUFFER, and that is not a micro-optimisation.
--
-- The previous version appended to a growing table and the drain replaced
-- that table with a fresh one. Both of those ALLOCATE - the append when
-- the array part has to grow, the swap every drain - and the append runs
-- on UE4SS's input thread while the game thread is running our pump. Any
-- allocation can advance Lua's incremental collector, and two threads
-- collecting in one lua_State is precisely the corruption that shows up
-- later as "Ref was not function". Holding an arrow key in edit mode is
-- the fastest way to make it happen, which is exactly how the original
-- crash was reproduced.
--
-- Every slot is preallocated, so the input thread only ever writes an
-- existing array entry and one number: no allocation, no collector, no
-- race. The buffer is bounded, so a stuck key cannot grow anything either.
local QUEUE_LIMIT = 32
local queue = {}
for i = 1, QUEUE_LIMIT do queue[i] = false end
local qWrite, qRead = 0, 0

local function request(name)
    local w = qWrite + 1
    if (w - qRead) > QUEUE_LIMIT then return end   -- full: drop the press
    queue[((w - 1) % QUEUE_LIMIT) + 1] = name
    qWrite = w
end

local function drainQueue()
    while qRead < qWrite do
        qRead = qRead + 1
        local slot = ((qRead - 1) % QUEUE_LIMIT) + 1
        local name = queue[slot]
        queue[slot] = false
        local fn = ACTIONS[name]
        -- the action name doubles as the error label: concatenating one
        -- would allocate on every key press for no benefit
        if fn ~= nil then guard.try(name, fn) end
    end
end

-- ---------------------------------------------------------------
-- The pump - the only place that runs on the game thread
-- ---------------------------------------------------------------
local PUMP_MS   = 33      -- timer resolution; NOT the dispatch rate
local MENU_MS   = 250
local MAINT_MS  = 2000

local lastMove, lastScan, lastMenu, lastMaint = 0.0, 0.0, 0.0, 0.0
local lastDrawX, lastDrawY, lastDrawYaw, lastDrawBodyYaw = nil, nil, nil, nil
local lastDrawSpeed, lastDrawZoom = nil, nil
local lastDrawSourceVersion = -1

-- ---------------------------------------------------------------
-- ONE DISPATCH AT A TIME. This is the 2.1.0 freeze fix.
--
-- The symptom: while checkboxes were being clicked in the settings window,
-- the mod stopped dead - the menu would not close, the minimap froze on
-- its last frame, and the game itself kept running. Nothing else can
-- produce exactly that: both widgets were still in the viewport, so the
-- engine was fine; only our game-thread work had stopped. That is what it
-- looks like when UE4SS removes its own EngineTick hook after the Lua
-- registry has been corrupted - the same failure as the 2.0.5 crash, but
-- without taking the game down with it.
--
-- 2.0.6 cut the number of threads making registry references to one, which
-- made it rare. It did not make it impossible, because the remaining race
-- is between the TIMER thread taking a reference (ExecuteInGameThread ->
-- luaL_ref) and the GAME thread releasing the previous one (luaL_unref)
-- when a pump returns. The wider the pump, the wider that window - and a
-- menu commit is the widest pump there is, because it tears the minimap
-- down and rebuilds a couple of hundred widgets. Meanwhile the 33 ms timer
-- kept firing straight through it and queuing MORE pumps behind the slow
-- one, each of which would do the same work again.
--
-- So the timer thread now:
--   * never has more than one dispatch outstanding (`inFlight`), which
--     both bounds the backlog and means a reference is never taken while
--     the game thread is inside our code;
--   * waits DISPATCH_GAP after a pump ENDS before taking the next
--     reference, so the new luaL_ref cannot land on top of UE4SS's
--     luaL_unref for the one that just finished;
--   * recovers on its own if a dispatch is simply dropped (that happens
--     across a world transition) instead of deadlocking on `inFlight`.
--
-- The predicate below still allocates nothing, deliberately: an allocation
-- here can advance Lua's collector on the timer thread while the game
-- thread is also collecting.
-- ---------------------------------------------------------------
local DISPATCH_GAP     = 0.033   -- seconds between a pump ending and the next ref
local DISPATCH_TIMEOUT = 3.0     -- a dispatch this old was never delivered
local STALL_LIMIT      = 3       -- consecutive losses before we say so

local inFlight = false
local sentAt = 0.0
local endedAt = 0.0
local stalls = 0
local stallReported = false

-- Evaluated on the TIMER thread. Returning true also CLAIMS the dispatch,
-- because the loop body has no other way to tell us it went ahead.
local function anythingDue()
    local now = os.clock()
    if inFlight then
        if (now - sentAt) < DISPATCH_TIMEOUT then return false end
        -- never ran: let go and try once more
        inFlight = false
        stalls = stalls + 1
        if stalls >= STALL_LIMIT and not stallReported then
            stallReported = true
            -- Safe to allocate here: by definition nothing of ours has run
            -- on the game thread for at least nine seconds.
            guard.log("the game thread has not run PalMiniMap's pump for "
                .. tostring(math.floor(now - endedAt)) .. "s - UE4SS has most likely "
                .. "removed its engine tick hook, and the mod cannot recover this "
                .. "session. Please report the UE4SS.log.")
        end
    end
    if (now - endedAt) < DISPATCH_GAP then return false end

    local due = false
    if qWrite ~= qRead then due = true
    elseif saveAt ~= nil and now >= saveAt then due = true
    elseif rebuildAt ~= nil and now >= rebuildAt then due = true
    else
        local ms = now * 1000.0
        if (ms - lastMaint) >= MAINT_MS then due = true
        elseif menu.isOpen() and (ms - lastMenu) >= MENU_MS then due = true
        elseif cfg.enabled then
            if (ms - lastMove) >= (cfg.moveIntervalMs or 100) then due = true
            elseif (ms - lastScan) >= (cfg.scanIntervalMs or 4000) then due = true end
        end
    end
    if not due then return false end
    inFlight, sentAt = true, now
    return true
end

local function pump()
    stalls, stallReported = 0, false
    drainQueue()

    -- Coalesced rebuilds, ahead of everything that reads the widget.
    if rebuildAt ~= nil and os.clock() >= rebuildAt then
        rebuildAt = nil
        guard.try("rebuild", rebuildNow)
    end

    local now = os.clock() * 1000.0
    local wantMaint = (now - lastMaint) >= MAINT_MS
    local wantMenu  = menu.isOpen() and (now - lastMenu) >= MENU_MS
    -- `enabled` is the player's switch; `minimapHidden` is the mod's own,
    -- and both mean the same thing to everything below: there is nothing on
    -- screen, so there is nothing worth scanning for. The movement tick
    -- itself still runs while hidden - it is what notices the screen closed
    -- or the player left the camp - but it returns before any of the work.
    local awake     = cfg.enabled and not minimapHidden
    local wantScan  = awake and (now - lastScan) >= (cfg.scanIntervalMs or 4000)
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
        -- ARGUMENTS, NOT A CLOSURE. This was the only guard.try in the
        -- pump still wrapping its call in a fresh function, which is a
        -- garbage object every poll while the menu is open - the exact
        -- idiom the 2.0.9 stutter work removed everywhere else.
        guard.try("menuPoll", menu.poll, cfg)
    end
    if wantScan then
        lastScan = now
        guard.try("scanTick", scanTick)
    end
    if wantMove then
        lastMove = now
        guard.try("movementTick", movementTick)
        -- ...and everything after it is skipped while hidden. movementTick
        -- has just re-evaluated `minimapHidden`, so this reads the decision
        -- made microseconds ago rather than one tick stale.
        if not minimapHidden then
        -- Both of the following are AFTER the draw and both are bounded.
        -- Between them they are the only reflection-heavy work left off the
        -- scan tick, and neither may grow with how much is around the
        -- player - that is what made walking hitch.
        guard.try("staticTick", staticTick)
        -- The one place in the mod that
        -- is allowed to call LoadAsset, and it is deliberately the last
        -- thing in the tick: whatever it costs is paid once the frame's
        -- real work is already done, and its own throttle (assets.lua)
        -- decides whether it may spend anything at all this time round.
        guard.try("assetPump", assets.pump)
        end
    end

    -- the state buffer is reused, so the pawn reference in it has to be
    -- dropped explicitly or it would outlive the tick that read it
    frameState = nil
    frameStateBuf.pawn = nil
    flushSave()

    -- Release the timer thread LAST. UE4SS unrefs this callback right
    -- after it returns, and DISPATCH_GAP keeps the next ref away from it.
    endedAt = os.clock()
    inFlight = false
end

-- ---------------------------------------------------------------
-- Registration - each item on its own, so one failure costs only itself
-- ---------------------------------------------------------------
guard.register("world transition hook", function()
    RegisterLoadMapPreHook(guard.callback("LoadMapPreHook", function()
        render.destroy()
        sources.forget()
        assets.forget()
        capture.forget()
        lastDrawSourceVersion = -1
        cachedPC = nil
        forgetGameMenu()
        worldName = ""
        beQuiet(nil)
    end))
end)

-- The keys come from config.ini beside the settings file - see keys.lua.
-- The action names are the same strings the queue already carries, so a
-- rebound key changes nothing downstream: the bind still only appends to
-- the ring buffer, exactly as the threading rule requires.
local boundKeys = nil

local function bind(label, binding, action)
    guard.register(label, function()
        local cb = guard.callback(label, function() request(action) end)
        -- Two shapes: with modifiers and without. The modifier form is only
        -- attempted when the player actually asked for one, so a build that
        -- reflects it differently costs nothing to anybody else.
        if binding.mods ~= nil and #binding.mods > 0 then
            local ok = pcall(RegisterKeyBind, binding.key, binding.mods, cb)
            if ok then return end
            guard.log("config.ini: this UE4SS build refused the modifier on "
                .. binding.name .. "; binding the plain key instead")
        end
        RegisterKeyBind(binding.key, cb)
    end)
end

if type(Key) == "table" then
    boundKeys = keys.load(KEYS_PATH)
    for i = 1, #keys.order() do
        local action = keys.order()[i][1]
        local list = boundKeys[action]
        for j = 1, #list do
            bind(action .. " (" .. list[j].name .. ")", list[j], action)
        end
    end
else
    guard.log("the UE4SS 'Key' table is missing; keybinds are unavailable")
end

-- ONE loop. See the threading note at the top of this file before adding
-- a second one.
guard.register("pump loop", function()
    LoopAsync(PUMP_MS, guard.loopBody("pump", pump, anythingDue))
end)

guard.log("PalMiniMap 2.3.6 loaded - " ..
    (boundKeys and keys.describe(boundKeys)
     or "F1 megazoom, F2 corner, F3 show/hide, F4 edit, F5 menu, +/- zoom"))