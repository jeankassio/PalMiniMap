-- =====================================================================
-- gameui.lua - "is the game showing one of its own screens?"
--
-- The minimap must never sit on top of the Esc menu, the inventory, a
-- chest, the palbox, the world map, a shop or anything else the game
-- opens.
--
-- HISTORY, because three attempts at this have gone wrong:
--
--   2.0.2 inferred it from pc.bShowMouseCursor. PALWORLD LEAVES THAT ON
--         DURING ORDINARY GAMEPLAY, so the minimap was hidden forever.
--         Do not go back to it.
--   2.0.4 replaced it with "is WBP_InGameMainMenu_C in the viewport".
--   2.2.4 still tested only that one class, which is wrong twice over: it
--         is the INVENTORY screen, not the Esc menu (that is
--         WBP_MenuESC_Pause), and naming individual screens can never
--         cover "anything the game opens" - there are 112 of them.
--
-- 2.2.5 tests the BASE CLASSES the game's own modal screens derive from.
-- These were read out of the widget blueprints in Pal-Windows.pak, not
-- guessed:
--
--   PalUserWidgetOverlayUI    carries EscInputHandle / TabInputHandle /
--                             CancelInputHandle - i.e. "a screen that
--                             swallows Esc and Tab". WBP_MenuESC_Pause,
--                             WBP_InGameMainMenu, WBP_ItemChest,
--                             WBP_Map_Base, WBP_ItemShop, +107 more.
--   PalUserWidgetStackableUI  the stacked-window base (it owns the open
--                             and close sounds), used by the palbox and
--                             several sub-windows that are not overlays.
--
-- FindAllOf matches subclasses - the same property the pal scan relies on
-- - so those two names cover every screen at once, and keep covering the
-- ones a future game update adds.
--
-- FAILURE MUST BE SAFE. If some always-on widget turned out to derive
-- from one of these, the minimap would hide forever: the 2.0.2 disaster
-- again. So a class is ARMED only once it has been seen with none of its
-- instances in the viewport. Until a probe has proved it can read "no UI
-- open", it never reports "UI open". A class that is somehow always up
-- therefore costs us that one signal instead of costing us the minimap,
-- and says so in the log.
-- =====================================================================

local guard = require("guard")

local M = {}

local UI_CLASSES   = { "PalUserWidgetOverlayUI", "PalUserWidgetStackableUI" }
local UI_WATCH_MAX = 64      -- instances tracked per class
local UI_RESCAN    = 5.0     -- seconds between FindAllOf top-ups
local UI_POLL      = 0.2     -- seconds between viewport checks
local UI_ARM_WARN  = 30.0    -- complain if a class never reads "closed"

local function rawIsPaused(gs, pc) return gs:IsGamePaused(pc) end
local function rawInViewport(w) return w:IsInViewport() end
local function rawObjectName(o) return o:GetFName():ToString() end

local probes = {}
for i = 1, #UI_CLASSES do
    probes[i] = {
        class = UI_CLASSES[i], widgets = {},
        rescanAt = 0.0, armed = false, warned = false, firstSeen = nil,
    }
end

local openCached = false
local pollAt = 0.0

-- The widgets die with their world, so everything is reset on a transition.
function M.forget()
    for i = 1, #probes do
        local p = probes[i]
        for j = #p.widgets, 1, -1 do p.widgets[j] = nil end
        p.rescanAt, p.armed, p.warned, p.firstSeen = 0.0, false, false, nil
    end
    openCached = false
    pollAt = 0.0
end

-- Top up rather than replace. A screen opened for the first time this
-- session is a widget that did not exist at the last scan, and 2.2.4's
-- "re-collect only once every instance has died" would never pick it up.
local function rescan(p, now)
    if now < p.rescanAt then return end
    p.rescanAt = now + UI_RESCAN

    -- drop the dead first, so the cap cannot fill up with corpses
    local live = 0
    for i = 1, #p.widgets do
        local w = p.widgets[i]
        if guard.alive(w) then live = live + 1; p.widgets[live] = w end
    end
    for i = #p.widgets, live + 1, -1 do p.widgets[i] = nil end

    local found = guard.get(FindAllOf, p.class)
    if type(found) ~= "table" then return end
    for i = 1, #found do
        if #p.widgets >= UI_WATCH_MAX then break end
        local w = found[i]
        if guard.alive(w) then
            -- FindAllOf also hands back the CLASS DEFAULT OBJECT, which is
            -- never in the viewport. Caching one of those was half of why
            -- the 2.0.4 test answered "closed" forever.
            local n = guard.get(rawObjectName, w)
            if tostring(n or ""):sub(1, 9) ~= "Default__" then
                local known = false
                for j = 1, #p.widgets do
                    if rawequal(p.widgets[j], w) then known = true; break end
                end
                if not known then p.widgets[#p.widgets + 1] = w end
            end
        end
    end
end

local function probeOpen(p, now)
    rescan(p, now)
    local open = false
    for i = 1, #p.widgets do
        local w = p.widgets[i]
        if guard.alive(w) and guard.get(rawInViewport, w) == true then
            open = true
            break
        end
    end

    if not open then
        p.armed = true              -- proved it can read "nothing open"
        return false
    end
    if p.armed then return true end

    -- Still unarmed and reading "open": either the player has had a screen
    -- up since the mod loaded, or this class is a bad signal. Say so once.
    p.firstSeen = p.firstSeen or now
    if not p.warned and (now - p.firstSeen) > UI_ARM_WARN then
        p.warned = true
        guard.log(p.class .. " has been in the viewport continuously since the mod "
            .. "loaded, so it is not trusted as a 'game UI is open' signal. The "
            .. "minimap stays visible rather than risk hiding for good.")
    end
    return false
end

local function paused(gs, pc)
    if gs == nil or pc == nil then return false end
    return guard.get(rawIsPaused, gs, pc) == true
end

-- `gs` is UGameplayStatics, `pc` the local PlayerController; either may be
-- nil while the world is not playable.
--
-- Called from the movement tick (10 Hz) but evaluated at UI_POLL, because
-- the viewport test costs one reflection call per tracked widget and this
-- mod's rule is that no pump does work which scales with what is around.
function M.isOpen(cfg, gs, pc)
    if not cfg.hideBehindGameUi then return false end
    -- Solo play pauses for the Esc menu, the map and the inventory, and
    -- that is one cached reflection hop rather than a widget walk. Co-op
    -- does not pause, which is why the widget probes exist at all.
    if paused(gs, pc) then return true end

    local now = os.clock()
    if now < pollAt then return openCached end
    pollAt = now + UI_POLL

    openCached = false
    for i = 1, #probes do
        if probeOpen(probes[i], now) then openCached = true; break end
    end
    return openCached
end

-- test hook
function M.stats()
    local out = {}
    for i = 1, #probes do
        local p = probes[i]
        out[i] = { class = p.class, tracked = #p.widgets, armed = p.armed }
    end
    return out
end

return M
