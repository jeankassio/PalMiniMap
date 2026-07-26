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
    -- placement in viewport pixels; a NEGATIVE value is a margin measured
    -- from the right/bottom edge, so the layout survives a resolution or
    -- size change
    x                  = -40,
    y                  = 40,
    size               = 240,
    opacity            = 0.92,
    circular           = false,

    -- Terrain sharpness. The map is the game's own texture magnified, so
    -- the only thing that decides how sharp it looks is which mip level
    -- the streamer keeps resident - see tuneTexture() in render.lua.
    --   0 leave the streamer alone (lowest VRAM, softest terrain)
    --   1 keep the world map texture fully resident
    --   2 ...and the icon textures too
    --   3 ...plus trilinear filtering and no streaming mip bias
    mapQuality         = 2,
    -- Escape hatch: point this at a different map asset if a game update
    -- ever ships a more detailed one. Empty = the stock T_WorldMap.
    terrainTexture     = "",

    -- how much of the world the window shows, in world units across
    zoom               = 22000,
    zoomMin            = 4000,
    zoomMax            = 120000,
    -- MULTIPLIER per +/- press, not a flat amount: a constant ratio feels
    -- the same whether you are zoomed right in or right out, and crosses
    -- the whole range in about fifteen presses instead of fifty-eight.
    zoomFactor         = 1.25,

    -- megazoom: the F1 "see the whole region" toggle from 1.x
    megazoom           = 260000,
    megazoomActive     = false,
    palsWhileMegazoom  = false,   -- 1.x: "show pal icons while megazoomed out"

    -- autozoom: widen the view as the player moves faster, like 1.x did
    autozoom           = true,
    autozoomWalk       = 1.0,     -- multiplier at walking speed
    autozoomRun        = 1.45,
    autozoomFly        = 2.20,

    rotateWithCamera   = false,   -- false = north is always up
    lockIconsNorth     = true,    -- keep icons upright when the map rotates

    -- hide while the game's own Esc menu is up
    hideBehindGameUi   = true,

    autohideInBase     = false,   -- 1.x: "autohide minimap while in base camps"
    baseCampRadius     = 12000,   -- how close counts as "inside a base camp"

    hideCollected      = true,    -- 1.x: "hide collected items from minimap"

    showPals           = true,
    onlyShinyPals      = false,
    showPlayers        = true,
    showNPCs           = true,
    showChests         = true,
    showEggs           = true,
    showNotes          = true,
    showEffigies       = false,
    showSkillFruit     = true,
    showFastTravel     = true,
    showBaseCamps      = true,
    showEnemyCamps     = true,
    showDungeons       = true,
    showTowers         = true,
    showDeaths         = true,

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
