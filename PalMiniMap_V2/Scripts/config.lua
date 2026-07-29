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

    -- WHERE THE TERRAIN COMES FROM (2.3.0).
    --   0 auto  - the live render up close, the game's map texture when
    --             zoomed out past `liveZoomMax`, and the live render
    --             wherever the map texture has no coverage at all (every
    --             dungeon, the far edges of the world). See render.lua.
    --   1 live  - always the second render.
    --   2 map   - always the game's world map texture, i.e. 2.0-2.2.
    mapSource          = 0,
    -- Above this zoom, `auto` stops asking for a live render: past a
    -- couple of kilometres across, most of what should be in frame has not
    -- been streamed in, so the capture would show empty ground where the
    -- painted map shows the whole island.
    liveZoomMax        = 60000,

    -- How the live render is taken. Each of these is the FIRST source of a
    -- chain, not a fixed choice: capture.lua measures what came back and
    -- steps to the next one if it cannot be drawn (see the 2.3.1 note in
    -- that file - `SCS_BaseColor` renders at alpha 0 on stock UE5, which
    -- Slate draws as nothing at all).
    --   0 flat - ask for SCS_BaseColor: the world's own colours with no
    --            lighting, so the minimap would read the same at midnight
    --            as at noon. EXPECT THIS TO FALL BACK to scene colour.
    --   1 lit  - ask for SCS_FinalColorLDR: what the game is drawing,
    --            night, weather and all.
    captureStyle       = 0,
    -- How far above the player the camera sits. THIS IS WHAT MAKES CAVES
    -- WORK: an orthographic camera does not render what is behind it, so
    -- the ceiling above this height is simply not in the picture. It does
    -- NOT change the scale - orthographic - only what gets clipped away.
    captureHeight      = 1500,
    -- How often the second render runs, at most. 250 ms is four renders a
    -- second; 1.x did sixty. Raise it if the GPU is the bottleneck.
    captureIntervalMs  = 250,

    -- Terrain sharpness, and it means two things because there are two
    -- terrain sources:
    --   live render - the render target's resolution: 256 / 384 / 512 /
    --                 768 px square for levels 0..3. This is what the
    --                 setting meant in 1.x.
    --   map texture - which mip the streamer keeps resident, since that
    --                 image is magnified several times across the window:
    --                 0 leave the streamer alone (softest), 1-2 keep it
    --                 fully resident, 3 plus trilinear and no mip bias.
    --                 See tune() in assets.lua.
    --
    -- 2 used to force every ICON's full mip chain resident as well. That
    -- was a mistake: icons are drawn at eighteen pixels, so those mips are
    -- pulled off disk only to be scaled away, and the streaming burst that
    -- followed each newly discovered pal species was part of the stutter
    -- 2.1.1 fixes. The level is kept so existing settings files still load.
    mapQuality         = 2,
    -- Escape hatch: point this at a different map asset if a game update
    -- ever ships a more detailed one. Empty = the stock T_WorldMap.
    -- Affects the map-texture source only.
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
    -- debug: list the widget classes in the viewport on every maintenance
    -- tick, so the Esc menu's real class name can be read off the log
    logGameUiWidgets   = false,

    autohideInBase     = false,   -- 1.x: "autohide minimap while in base camps"
    -- FALLBACK ONLY. "Inside a base" normally comes from the player's own
    -- PalInsideBaseCampCheckComponent, which is exact; this circle is used
    -- only if that cannot be read (sources.lua logs which route is live).
    -- PalBuildObjectBaseCampPoint carries no radius, so this is an
    -- estimate - the old 12000 was a 120 m bubble and kept the minimap
    -- hidden long after the player had left.
    baseCampRadius     = 5000,

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

    -- 2.2.18: things the game's own compass marks. All OFF by default -
    -- ore and junk are numerous, and maxPoiIcons is shared by distance
    -- across every kind, so leaving these on would crowd chests, dungeons
    -- and fast travel points off the minimap.
    showResources      = false,   -- ore, stat-fruit lotuses, forage, junk
    showFishing        = false,
    showTreasureMaps   = false,
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
    -- Humans get a budget of their OWN rather than sharing the pal one.
    -- Sharing meant a pal-dense area showed no people at all, and the
    -- alternative - letting both take maxPalIcons - overflows the icon pool
    -- (it is sized from these three) so render dropped whatever was emitted
    -- last, always the NPCs, without saying so. Smaller than the pal budget
    -- because a crowd of villagers is scenery, not information.
    maxNpcIcons        = 24,
}

local current = nil
local path = nil
local legacyPaths = nil

function M.setPath(p) path = p end
function M.defaults() return DEFAULTS end

-- Places an older version may have written the file. Read-only: a save
-- always goes to `path`, so the first save after an upgrade migrates it.
function M.setLegacyPaths(list) legacyPaths = list end

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
--
-- Iterating the DEFAULTS is also what retires a setting cleanly: a key the
-- stored file has and the defaults do not is simply not carried over, so
-- the removed `axis` block in an older settings file is ignored on load and
-- gone from the file after the next save. Nothing has to migrate it.
-- KEYS THAT MUST NOT SURVIVE A SESSION.
--
-- `logGameUiWidgets` turns on uiprobe.lua, which walks the whole UObject
-- array once a second and asks every widget for its class name. That is
-- fine for the few minutes it takes to diagnose something and is felt as
-- stuttering if it is left on - which is exactly what happened: it was
-- switched on to find the Esc/Tab bug, the F5 menu wrote it to the
-- settings file like any other option, and it was still on two versions
-- later. A debug switch that costs frame time must not be able to persist
-- silently, so it is never read from the file and never written to it.
local SESSION_ONLY = { logGameUiWidgets = true }

local function merge(stored)
    local out = {}
    for k, v in pairs(DEFAULTS) do
        -- NEVER `cond and stored and stored[k] or nil` HERE. A stored value
        -- of `false` makes that whole chain evaluate to nil, the type check
        -- below then rejects it, and the DEFAULT is used instead - so every
        -- toggle the player had turned OFF came back on at the next launch,
        -- while numbers and toggles turned ON persisted fine. That is the
        -- "my settings reset themselves" bug, and it is invisible in the
        -- file: the JSON on disk was correct all along, the read threw it
        -- away. Same Lua trap as the one in uiprobe.lua's `show`.
        local s = nil
        if stored ~= nil and not SESSION_ONLY[k] then s = stored[k] end
        if type(v) == "table" then
            local t = {}
            for k2, v2 in pairs(v) do t[k2] = v2 end
            if type(s) == "table" then
                for k2, v2 in pairs(s) do
                    if type(v2) == type(t[k2]) then t[k2] = v2 end
                end
            end
            out[k] = t
        else
            if type(s) == type(v) then out[k] = s else out[k] = v end
        end
    end
    return out
end

local function readSettings(p)
    local text = readFileText(p)
    if text == nil then return nil end
    local ok, decoded = pcall(json.decode, text)
    if ok and type(decoded) == "table" then return decoded end
    guard.log("settings file '" .. tostring(p) .. "' unreadable, ignoring it: "
        .. tostring(decoded))
    return nil
end

function M.load()
    if current then return current end
    local stored = path and readSettings(path) or nil
    if stored == nil and legacyPaths ~= nil then
        for i = 1, #legacyPaths do
            local p = legacyPaths[i]
            if p ~= path then
                stored = readSettings(p)
                if stored ~= nil then
                    guard.log("settings found at '" .. p .. "', which is where an older "
                        .. "version put them; they will be saved beside the mod from now on")
                    break
                end
            end
        end
    end
    current = merge(stored)
    return current
end

function M.get() return current or M.load() end

function M.save()
    if not path or not current then return false end
    -- Session-only keys are stripped on the way out, so a debug switch left
    -- on cannot follow the player into the next session. See SESSION_ONLY.
    local toWrite = current
    for k in pairs(SESSION_ONLY) do
        if current[k] ~= nil then
            toWrite = {}
            for k2, v2 in pairs(current) do
                if not SESSION_ONLY[k2] then toWrite[k2] = v2 end
            end
            break
        end
    end
    local ok, text = pcall(json.encode, toWrite)
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
