-- =====================================================================
-- uiprobe.lua - diagnostic ONLY, off unless cfg.logGameUiWidgets is set.
--
-- Six attempts at "is one of the game's own screens open?" have failed,
-- every one of them because a signal was chosen by reasoning about the
-- game rather than by watching it. This module stops the reasoning: it
-- reads EVERY plausible signal at once and logs a line whenever any of
-- them changes, so pressing Tab and Esc in game produces a before/after
-- that says which one actually moves.
--
-- It is deliberately wasteful - a full UObject walk once a second - and
-- must never run in a normal session.
-- =====================================================================

local guard = require("guard")

local M = {}

local SCALAR_EVERY = 0.5     -- cheap property reads
local WIDGET_EVERY = 1.0     -- full object-array walks

-- watched one by one as well as in bulk, because these are the screens
-- the report named: Esc and the Tab inventory
local WATCH_CLASSES = {
    "WBP_MenuESC_C", "WBP_MenuESC_Pause_C", "WBP_InGameMainMenu_C",
    "WBP_ItemChest_C", "WBP_Map_Base_C", "WBP_PalStorageMenu_C",
    "PalUserWidgetOverlayUI", "PalUserWidgetStackableUI",
    "CommonActivatableWidgetContainerBase",
}

local function rawIsPaused(gs, pc) return gs:IsGamePaused(pc) end
local function rawCursor(pc) return pc.bShowMouseCursor end
local function rawMoveIgn(pc) return pc:IsMoveInputIgnored() end
local function rawLookIgn(pc) return pc:IsLookInputIgnored() end
local function rawBuildMenu(pc) return pc.isOpenConstructionMenu end
local function rawMyHUD(pc) return pc.MyHUD end
local function rawStack(h) return h.StackableUIWidgets end
local function rawHudWidgets(h) return h.HUDWidgets end
local function rawWidgetList(c) return c.WidgetList end
local function rawArrayNum(a) return a:GetArrayNum() end
local function rawLen(a) return #a end
local function rawForEach(a, fn) a:ForEach(fn) end
local function rawIsVisible(w) return w:IsVisible() end
local function rawInViewport(w) return w:IsInViewport() end
local function rawObjectName(o) return o:GetFName():ToString() end
local function rawClassName(o) return o:GetClass():GetFName():ToString() end

local forEachCount = 0
local function bump() forEachCount = forEachCount + 1 end

local function count(arr)
    if arr == nil then return nil end
    local n = guard.get(rawArrayNum, arr)
    if type(n) == "number" and n >= 0 then return n end
    n = guard.get(rawLen, arr)
    if type(n) == "number" and n >= 0 then return n end
    forEachCount = 0
    if pcall(rawForEach, arr, bump) then return forEachCount end
    return nil
end

local function rawUnwrap(v) return v:get() end

local function show(v)
    if v == nil then return "?" end
    if type(v) == "boolean" or type(v) == "number" or type(v) == "string" then
        return tostring(v)
    end
    -- A reflected bool can arrive WRAPPED: the first run printed
    -- "buildMenu=TrivialObject: 000001F34D107258" instead of true/false,
    -- and a raw pointer in the log is worse than useless - it changes
    -- every frame, so the "did anything change?" test fires forever.
    local inner = guard.get(rawUnwrap, v)
    if type(inner) == "boolean" or type(inner) == "number" then return tostring(inner) end
    return "obj"
end

-- `cond and guard.get(...) or nil` COLLAPSES A FALSE READING TO NIL, so
-- every boolean that is false would print as "?" - which is exactly the
-- half of each transition this probe exists to see. Read through these
-- instead of the and/or idiom.
local function readFrom(obj, fn)
    if obj == nil then return nil end
    return guard.get(fn, obj)
end

local function readPaused(gs, pc)
    if gs == nil or pc == nil then return nil end
    return guard.get(rawIsPaused, gs, pc)
end

-- The crash happened while a loading screen was still up, with widgets
-- half-built. Nothing here runs until the caller says the world is settled
-- AND that has held for WARMUP seconds.
local WARMUP = 8.0

local S = { scalarAt = 0.0, widgetAt = 0.0, lastScalars = "", visible = {},
            started = false, readyAt = nil }

function M.forget()
    S.scalarAt, S.widgetAt, S.lastScalars, S.started = 0.0, 0.0, "", false
    S.visible, S.readyAt = {}, nil
end

local function hudOf(pc)
    local hud = pc ~= nil and guard.get(rawMyHUD, pc) or nil
    if guard.alive(hud) then return hud, "MyHUD" end
    hud = guard.get(FindFirstOf, "PalHUDInGame")
    if guard.alive(hud) then return hud, "FindFirstOf" end
    return nil, "none"
end

local function scalars(gs, pc)
    local hud, via = hudOf(pc)
    local stack, hudw = nil, nil
    if hud ~= nil then
        stack = count(guard.get(rawStack, hud))
        hudw  = count(guard.get(rawHudWidgets, hud))
    end
    return table.concat({
        "hud=" .. via,
        "STACK=" .. show(stack),
        "hudWidgets=" .. show(hudw),
        "paused=" .. show(readPaused(gs, pc)),
        "cursor=" .. show(readFrom(pc, rawCursor)),
        "moveIgnored=" .. show(readFrom(pc, rawMoveIgn)),
        "lookIgnored=" .. show(readFrom(pc, rawLookIgn)),
        "buildMenu=" .. show(readFrom(pc, rawBuildMenu)),
    }, " ")
end

-- For each watched class: how many instances exist, and how many of them
-- answer IsVisible / IsInViewport. Those two columns are what 2.2.5 and
-- 2.2.6 each bet on and lost, so seeing them move (or not) settles it.
local function classCounts()
    local parts = {}
    for _, cls in ipairs(WATCH_CLASSES) do
        local found = guard.get(FindAllOf, cls)
        if type(found) == "table" then
            local total, vis, vp = 0, 0, 0
            for i = 1, #found do
                local w = found[i]
                if guard.alive(w) then
                    local n = tostring(guard.get(rawObjectName, w) or "")
                    if n:sub(1, 9) ~= "Default__" then
                        total = total + 1
                        if guard.get(rawIsVisible, w) == true then vis = vis + 1 end
                        if guard.get(rawInViewport, w) == true then vp = vp + 1 end
                    end
                end
            end
            if total > 0 then
                parts[#parts + 1] = string.format("%s=%d(vis %d,vp %d)", cls, total, vis, vp)
            end
        end
    end
    return table.concat(parts, " ")
end

-- CommonUI keeps activatable widgets in stacks; Palworld's UI is built on
-- it (GameUIManagerSubsystem / PrimaryGameLayout are in the usmap), so if
-- Esc and Tab are pushed anywhere, it is very likely one of these.
--
-- THIS KILLED THE GAME ONCE, at 19:21:41 on the very first run. The first
-- version also read `DisplayedWidget` and then called
-- GetClass():GetFName():ToString() ON THAT - three dereferences deep into
-- an object obtained from a property read on a widget still being built
-- behind a loading screen. Palworld died with NO Lua error in the log at
-- all; the log simply stops mid-probe, because a native access violation
-- is not something pcall can catch. Same family as the crash that cost
-- 2.1.5, and the same rule applies here even though this is only a
-- diagnostic: TOUCH ONLY WHAT CAME BACK FROM FindAllOf, and never walk
-- from it to something else.
--
-- So the container itself is read (it came straight from FindAllOf, like
-- everything else this mod reads) and its widget list is only COUNTED,
-- never opened.
local function containers()
    local found = guard.get(FindAllOf, "CommonActivatableWidgetContainerBase")
    if type(found) ~= "table" then return "" end
    local parts = {}
    for i = 1, #found do
        local c = found[i]
        if guard.alive(c) then
            local n = tostring(guard.get(rawObjectName, c) or "")
            if n:sub(1, 9) ~= "Default__" then
                local list = count(guard.get(rawWidgetList, c))
                if type(list) == "number" and list > 0 then
                    parts[#parts + 1] = string.format("%s[%d]", n, list)
                end
            end
        end
    end
    if #parts == 0 then return "all empty" end
    return table.concat(parts, " ")
end

-- The single most useful line: which widget classes are visible RIGHT NOW,
-- reported as a diff. Press Tab and whatever appears here is the answer.
local function visibleDiff()
    local found = guard.get(FindAllOf, "UserWidget")
    if type(found) ~= "table" then return nil end
    local now, added = {}, {}
    for i = 1, #found do
        local w = found[i]
        if guard.alive(w) then
            local n = tostring(guard.get(rawObjectName, w) or "")
            if n:sub(1, 9) ~= "Default__" and guard.get(rawIsVisible, w) == true then
                local c = tostring(guard.get(rawClassName, w) or "?")
                if not now[c] then
                    now[c] = true
                    if not S.visible[c] then added[#added + 1] = c end
                end
            end
        end
    end
    local removed = {}
    for c in pairs(S.visible) do if not now[c] then removed[#removed + 1] = c end end
    S.visible = now
    table.sort(added); table.sort(removed)
    return added, removed
end

-- `ready` is the caller's "this is a real, settled gameplay world".
function M.tick(cfg, gs, pc, ready)
    if not cfg.logGameUiWidgets then return end
    local now = os.clock()

    if not ready then S.readyAt = nil; return end
    S.readyAt = S.readyAt or (now + WARMUP)
    if now < S.readyAt then return end

    if not S.started then
        S.started = true
        guard.log("UI PROBE ON. Open the Esc menu, the Tab inventory and a chest; "
            .. "every line below is a change. Turn 'Log game UI widget names' back off "
            .. "in the F5 menu afterwards - this walks the whole object array.")
    end

    if now >= S.scalarAt then
        S.scalarAt = now + SCALAR_EVERY
        local line = scalars(gs, pc)
        if line ~= S.lastScalars then
            S.lastScalars = line
            guard.log("[probe] " .. line)
        end
    end

    if now >= S.widgetAt then
        S.widgetAt = now + WIDGET_EVERY
        local added, removed = visibleDiff()
        if added ~= nil and (#added > 0 or #removed > 0) then
            if #added > 0 then
                guard.log("[probe] +visible: " .. table.concat(added, ", "))
            end
            if #removed > 0 then
                guard.log("[probe] -visible: " .. table.concat(removed, ", "))
            end
            guard.log("[probe]   classes: " .. classCounts())
            local c = containers()
            if c ~= "" then guard.log("[probe]   containers: " .. c) end
        end
    end
end

return M
