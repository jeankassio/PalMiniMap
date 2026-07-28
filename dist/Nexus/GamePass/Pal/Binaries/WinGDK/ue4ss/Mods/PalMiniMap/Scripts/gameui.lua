-- =====================================================================
-- gameui.lua - "is the game showing one of its own screens?"
--
-- The minimap must not draw on top of the Esc menu, the inventory, a
-- chest, the palbox, the world map or a shop.
--
-- SEVEN ATTEMPTS. This is the first one built on MEASUREMENT rather than
-- on reasoning about the game, and the measurement is in the repository
-- history: uiprobe.lua logged every candidate signal while the Esc menu,
-- the Tab inventory and a chest were opened and closed. What it showed:
--
--   at rest, walking around   StackableUIWidgets = 1
--   chest open                                  = 2
--   inventory open                              = 2
--   Esc menu open                               = 2, then 3
--
-- SO THE RESTING VALUE IS ONE, NOT ZERO. Every version from 2.2.7 on read
-- the right array and then tested `count > 0`, which is true even with
-- nothing open - so the signal never once read "closed", the arming rule
-- correctly refused to trust it, and the minimap never hid. The bug was
-- never the array. It was the assumption that an idle stack is empty.
--
-- Nothing may assume that resting value either: it is one entry on this
-- build and could be two on the next. So it is LEARNED, from the one
-- moment when it is certain that no screen is open -
--
--     A SCREEN CANNOT BE OPEN WHILE THE CHARACTER IS RUNNING.
--
-- While the player is moving, whatever the stack reads IS the baseline.
-- Standing still, anything above that baseline is a screen. This also
-- makes the whole thing self-healing: if the baseline is ever learned
-- wrong, walking a few metres corrects it, rather than the mod being
-- stuck for the rest of the session.
--
-- WHAT WAS TRIED AND FAILED, so none of it is tried again:
--
--   2.0.2  pc.bShowMouseCursor -> hidden all session. Palworld leaves the
--          cursor ON during ordinary gameplay; the probe confirms it flips
--          on and off for reasons unrelated to menus.
--   2.0.4  "WBP_InGameMainMenu_C in the viewport" - a guessed name.
--   2.2.4  that class for real: it is the INVENTORY, not the Esc menu
--          (WBP_MenuESC_C), and naming screens one at a time cannot cover
--          the 112 this game has.
--   2.2.5  the right base classes, tested with IsInViewport() -> never
--          fired. The probe shows vp=0 for every widget even with a screen
--          up: Palworld's screens are children of its UI layout, and
--          IsInViewport is only true for a widget passed to AddToViewport.
--   2.2.6  the same classes with UWidget::IsVisible() -> hidden all
--          session. That reads a widget's own flag, ignoring its parent
--          layer.
--   2.2.7  StackableUIWidgets, but the array read failed on this build, so
--          the widget fallback took over and behaved like 2.2.6.
--   2.2.8  array read fixed, fallback deleted - but still `> 0`.
--
-- The probe also settles two facts worth keeping: `paused` is FALSE with
-- the Esc menu open (Palworld does not pause), and `IsMoveInputIgnored`
-- stays false throughout, so neither is usable.
-- =====================================================================

local guard = require("guard")

local M = {}

local UI_POLL     = 0.2      -- seconds between checks
local MOVE_MIN    = 25.0     -- cm in one poll that counts as "running"
local TELEPORT    = 20000.0  -- cm in one poll that is a fast travel, not walking
local CAL_WARN    = 60.0     -- complain if it never gets a chance to calibrate

local function rawIsPaused(gs, pc) return gs:IsGamePaused(pc) end
local function rawMyHUD(pc) return pc.MyHUD end
local function rawStack(hud) return hud.StackableUIWidgets end
local function rawArrayNum(a) return a:GetArrayNum() end
local function rawLen(a) return #a end
local function rawForEach(a, fn) a:ForEach(fn) end

-- UE4SS hands a TArray property back in more than one shape depending on
-- the build, and all this needs is a COUNT, so every shape is tried.
-- Returns nil for "not a readable array", which is NOT the same as 0.
-- (2.2.7 only tried GetArrayNum, failed, and silently fell back to the
-- machinery that hid the minimap for a whole session.)
local forEachCount = 0
local function bumpCount() forEachCount = forEachCount + 1 end

local function arrayCount(arr)
    if arr == nil then return nil end
    local n = guard.get(rawArrayNum, arr)
    if type(n) == "number" and n >= 0 then return n end
    -- `#` covers a plain Lua table AND a userdata with __len, and goes
    -- through pcall because a userdata without __len raises.
    n = guard.get(rawLen, arr)
    if type(n) == "number" and n >= 0 then return n end
    -- pcall directly: ForEach returns nothing, so guard.get's nil cannot
    -- be told apart from "no such method", and an empty array would read
    -- as unreadable.
    forEachCount = 0
    if pcall(rawForEach, arr, bumpCount) then return forEachCount end
    return nil
end

-- ---------------------------------------------------------------
local S = {
    baseline   = nil,    -- stack count with nothing open, learned while running
    pending    = nil,    -- candidate baseline, needs to be seen twice
    unreadable = false,  -- logged once
    said       = false,  -- logged the first calibration
    warned     = false,
    startedAt  = nil,
    lastX      = nil,
    lastY      = nil,
    count      = -1,     -- last reading, for the diagnostic
    open       = false,
    pollAt     = 0.0,
}

function M.forget()
    S.baseline, S.pending = nil, nil
    S.unreadable, S.said, S.warned, S.startedAt = false, false, false, nil
    S.lastX, S.lastY = nil, nil
    S.count, S.open, S.pollAt = -1, false, 0.0
end

local function findHUD(pc)
    local hud = pc ~= nil and guard.get(rawMyHUD, pc) or nil
    if guard.alive(hud) then return hud, "PlayerController.MyHUD" end
    -- the way back if this build does not reflect that property; the probe
    -- run took this branch on the title screen and the other in game
    hud = guard.get(FindFirstOf, "PalHUDInGame")
    if guard.alive(hud) then return hud, "FindFirstOf('PalHUDInGame')" end
    return nil, "not found"
end

local function stackCount(pc)
    local hud = findHUD(pc)
    if hud == nil then return nil end
    return arrayCount(guard.get(rawStack, hud))
end

local function paused(gs, pc)
    if gs == nil or pc == nil then return false end
    return guard.get(rawIsPaused, gs, pc) == true
end

-- Distance walked since the last poll, from POSITION rather than velocity.
-- 2.2.7 used the speed main.lua derives from GetVelocity(); on a build
-- where that reflection call fails it stays 0.0 forever and nothing that
-- depends on it can ever fire. The map pans off this position, so it is
-- the one player reading this mod is certain of.
local function stepWalked(px, py)
    if type(px) ~= "number" or type(py) ~= "number" then return 0.0 end
    local dx, dy = 0.0, 0.0
    if S.lastX ~= nil then dx, dy = px - S.lastX, py - S.lastY end
    S.lastX, S.lastY = px, py
    local d2 = dx * dx + dy * dy
    if d2 > TELEPORT * TELEPORT then return 0.0 end   -- fast travel is not walking
    return math.sqrt(d2)
end

-- `gs` is UGameplayStatics, `pc` the local PlayerController; either may be
-- nil while the world is not playable. `px`/`py` are the player's world
-- position, which main.lua already has for this tick.
--
-- Called from the movement tick (10 Hz) but evaluated at UI_POLL.
function M.isOpen(cfg, gs, pc, px, py)
    if not cfg.hideBehindGameUi then return false end
    -- Kept because it costs one cached hop, though the probe run shows
    -- Palworld does NOT pause for the Esc menu, so it never fires in solo
    -- play either.
    if paused(gs, pc) then return true end

    local now = os.clock()
    if now < S.pollAt then return S.open end
    S.pollAt = now + UI_POLL
    S.startedAt = S.startedAt or now

    local moved = stepWalked(px, py)
    local count = stackCount(pc)
    S.count = (count == nil) and -1 or count

    if count == nil then
        -- Nothing to go on. NOT hiding is the only safe answer: three of
        -- the seven attempts hid the minimap for a whole session, and
        -- there is deliberately no widget fallback here any more because
        -- guessing from widgets is what did it twice.
        if not S.unreadable then
            S.unreadable = true
            guard.log("could not read PalHUDInGame.StackableUIWidgets on this build, so "
                .. "the minimap will not hide behind the game's own screens. Everything "
                .. "else works; turn on logGameUiWidgets and report the dump.")
        end
        S.open = false
        return false
    end

    if moved > MOVE_MIN then
        -- RUNNING, so nothing is open, so this reading is the baseline.
        -- Requiring it twice keeps a single odd frame from setting it.
        if S.baseline ~= count then
            if S.pending == count then
                local first = (S.baseline == nil)
                S.baseline = count
                if not S.said or not first then
                    S.said = true
                    guard.log("game UI detection: the screen stack rests at "
                        .. tostring(count) .. " while running, so anything above that "
                        .. "is one of the game's own screens.")
                end
            else
                S.pending = count
            end
        end
        S.open = false
        return false
    end
    S.pending = nil

    if S.baseline == nil then
        -- Not calibrated yet: the player has not moved since the mod
        -- loaded. Never hide on an unproven baseline.
        if not S.warned and (now - S.startedAt) > CAL_WARN then
            S.warned = true
            guard.log("waiting to see the screen stack while you are moving before it "
                .. "can tell a menu from ordinary play; walk around a little.")
        end
        S.open = false
        return false
    end

    S.open = (count > S.baseline)
    return S.open
end

-- Diagnostic for cfg.logGameUiWidgets.
function M.describe(pc)
    local out = {}
    local hud, via = findHUD(pc)
    out[#out + 1] = "HUD via " .. via .. ": " .. tostring(hud)
    if hud ~= nil then
        local arr = guard.get(rawStack, hud)
        out[#out + 1] = "  StackableUIWidgets type=" .. type(arr)
            .. " GetArrayNum=" .. tostring(guard.get(rawArrayNum, arr))
            .. " count=" .. tostring(arrayCount(arr))
    end
    out[#out + 1] = string.format("  baseline=%s last=%d open=%s unreadable=%s",
        tostring(S.baseline), S.count, tostring(S.open), tostring(S.unreadable))
    return table.concat(out, "\n")
end

-- test hook
function M.stats()
    return { baseline = S.baseline, count = S.count, open = S.open,
             unreadable = S.unreadable }
end

return M
