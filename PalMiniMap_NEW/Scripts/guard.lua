-- =====================================================================
-- guard.lua - error containment
--
-- Same policy the 1.x line converged on, extracted into a module.
--
-- WHAT THIS CANNOT DO, stated up front: pcall only catches LUA errors. A
-- native access violation - UE4SS reflection dereferencing a UObject the
-- engine already freed - kills the process before any Lua handler runs.
-- The 1.x mod crashed that way twice. Version 2 does not defend against
-- it with guards; it removes the exposure by design: this minimap never
-- attaches anything to world actors and never holds a reference to one
-- across a frame. See render.lua and sources.lua.
-- =====================================================================

local M = {}

local PREFIX = "[PalMiniMap] "

function M.log(msg)
    -- logging must never be the thing that breaks a caller
    pcall(function() print(PREFIX .. tostring(msg) .. "\n") end)
end

local function describe(err)
    if debug ~= nil and type(debug.traceback) == "function" then
        local ok, tb = pcall(debug.traceback, tostring(err), 2)
        if ok and type(tb) == "string" then return tb end
    end
    return tostring(err)
end

-- Repeat suppression: a broken periodic task would otherwise write the same
-- error several times a second and bury the log.
local REPEAT_SECONDS = 60
local state = {}

local function report(label, err)
    label = tostring(label)
    local now = os.clock()
    local st = state[label]
    if st == nil then
        state[label] = { count = 1, lastLogged = now }
        M.log("ERROR in " .. label .. " (handled, continuing): " .. describe(err))
        return
    end
    st.count = st.count + 1
    if (now - st.lastLogged) >= REPEAT_SECONDS then
        M.log(string.format("ERROR in %s (handled, continuing) x%d since last report: %s",
                            label, st.count, tostring(err)))
        st.lastLogged = now
        st.count = 0
    end
end

-- try(label, fn, ...) -> ok, results...
function M.try(label, fn, ...)
    local ok, a, b, c = xpcall(fn, describe, ...)
    if not ok then
        report(label, a)
        return false
    end
    return true, a, b, c
end

-- Quiet variant for reflection reads that are EXPECTED to fail sometimes
-- (a property missing on this build, an object that just died). Returns the
-- value or nil - never logs, because logging these would be noise.
function M.get(fn, ...)
    local ok, v = pcall(fn, ...)
    if ok then return v end
    return nil
end

function M.alive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- Registration helper: each subsystem registers on its own, so one that
-- fails on a given UE4SS build costs only itself.
function M.register(label, fn)
    if not M.try("register " .. label, fn) then
        M.log("'" .. label .. "' is unavailable this session; the rest still runs")
    end
end

-- Engine -> Lua boundary. Hook arguments are dropped on purpose; nothing
-- here uses them.
function M.callback(label, fn)
    return function() M.try(label, fn) end
end

-- Key binds fire on UE4SS's own thread. Anything touching UObjects or UMG
-- has to be handed to the game thread first.
function M.gameThreadCallback(label, fn)
    return function()
        M.try(label .. " (dispatch)", function()
            ExecuteInGameThread(M.callback(label, fn))
        end)
    end
end

-- Periodic loop body. `shouldRun` is evaluated on the TIMER thread, so a
-- sleeping loop costs no game-thread hop at all. Always returns false so
-- UE4SS keeps the timer alive whatever happened.
function M.loopBody(label, fn, shouldRun)
    local dispatchLabel = label .. " (dispatch)"
    return function()
        if shouldRun ~= nil then
            local ok, wanted = M.try(dispatchLabel, shouldRun)
            if not ok or not wanted then return false end
        end
        M.try(dispatchLabel, function()
            ExecuteInGameThread(M.callback(label, fn))
        end)
        return false
    end
end

return M
