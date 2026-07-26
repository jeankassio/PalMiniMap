-- =====================================================================
-- config.lua - settings, stored next to the script
--
-- Unlike 1.x this file is OURS: no blueprint reads it, so there is no
-- half-written-file race with the game and no DekModConfigMenu schema to
-- honour. Plain table in, plain table out. Writes are still atomic
-- (temp + rename) because the player may alt-tab and edit it by hand.
-- =====================================================================

local guard = require("guard")
local json = require("json")

local M = {}

local DEFAULTS = {
    enabled            = true,
    -- placement, in viewport pixels; negative counts back from the edge
    x                  = -280,
    y                  = 40,
    size               = 240,
    opacity            = 0.92,
    circular           = false,

    -- how much of the world the window shows, in world units across
    zoom               = 22000,
    zoomMin            = 4000,
    zoomMax            = 120000,
    zoomStep           = 2000,

    rotateWithCamera   = false,   -- false = north is always up

    showPals           = true,
    onlyShinyPals      = false,
    showPlayers        = true,
    showNPCs           = false,
    showChests         = true,
    showFastTravel     = true,
    showBaseCamps      = true,
    showDungeons       = true,

    iconSize           = 18,
    playerIconSize     = 22,

    -- refresh rates in milliseconds
    moveIntervalMs     = 100,     -- reposition icons / recentre the map
    scanIntervalMs     = 4000,    -- look for new actors

    maxPalIcons        = 48,
    maxPoiIcons        = 48,

    -- see worldmap.lua: image orientation relative to world axes
    axis               = { swapXY = true, flipH = false, flipV = true },
}

local current = nil
local path = nil

function M.setPath(p) path = p end
function M.defaults() return DEFAULTS end

local function readFileText(p)
    local opened, f = pcall(io.open, p, "r")
    if not opened or not f then return nil end
    local ok, text = pcall(function() return f:read("*a") end)
    pcall(function() f:close() end)
    if not ok or type(text) ~= "string" then return nil end
    return text
end

local function writeFileText(p, text)
    local opened, f = pcall(io.open, p, "w")
    if not opened or not f then return false end
    local ok = pcall(function() f:write(text) end)
    pcall(function() f:close() end)
    return ok
end

-- Merge stored values over the defaults, one level deep, keeping the
-- default whenever the stored value has the wrong type. A hand-edited file
-- with a typo degrades to defaults instead of breaking the mod.
local function merge(stored)
    local out = {}
    for k, v in pairs(DEFAULTS) do
        if type(v) == "table" then
            local t = {}
            for k2, v2 in pairs(v) do t[k2] = v2 end
            local s = stored and stored[k]
            if type(s) == "table" then
                for k2, v2 in pairs(s) do
                    if type(v2) == type(t[k2]) then t[k2] = v2 end
                end
            end
            out[k] = t
        else
            local s = stored and stored[k]
            if type(s) == type(v) then out[k] = s else out[k] = v end
        end
    end
    return out
end

function M.load()
    if current then return current end
    local stored = nil
    if path then
        local text = readFileText(path)
        if text then
            local ok, decoded = pcall(json.decode, text)
            if ok and type(decoded) == "table" then
                stored = decoded
            else
                guard.log("settings file unreadable, using defaults: " .. tostring(decoded))
            end
        end
    end
    current = merge(stored)
    return current
end

function M.get() return current or M.load() end

function M.save()
    if not path or not current then return false end
    local ok, text = pcall(json.encode, current)
    if not ok then
        guard.log("could not encode settings: " .. tostring(text))
        return false
    end
    local tmp = path .. ".tmp"
    if not writeFileText(tmp, text) then
        return writeFileText(path, text)   -- temp not writable: direct write
    end
    pcall(os.remove, path)                 -- Windows rename will not overwrite
    local renameRan, renamed = pcall(os.rename, tmp, path)
    if renameRan and renamed then return true end
    pcall(os.remove, tmp)
    return writeFileText(path, text)
end

function M.set(key, value)
    local cfg = M.get()
    cfg[key] = value
    return cfg
end

-- Clamp helper used by the zoom/size controls
function M.clamp(v, lo, hi)
    if type(v) ~= "number" then return lo end
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

return M
