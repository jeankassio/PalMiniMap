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

    -- WHERE THE TERRAIN COMES FROM. One checkbox since 2.3.3 - it was a
    -- three-way 0 auto / 1 live / 2 map, which asked the player to
    -- understand a distinction the mod can make for itself.
    --   true  - the second render (capture.lua): the world as it actually
    --           is, from above, including dungeons and everywhere the
    --           painted map has no coverage.
    --   false - the game's own world map texture, i.e. 2.0-2.2 behaviour.
    liveTerrain        = true,
    -- The ONE exception to the checkbox, and it is not a hedge: THE LIVE
    -- RENDER CAN ONLY SHOW WHAT THE GAME HAS STREAMED IN. Megazoom is
    -- 260 000 world units across - over two kilometres - and most of that
    -- is not loaded, so a capture there is mostly empty ground while the
    -- painted map shows the whole island perfectly. Above this zoom the
    -- terrain falls back to the texture even with the box ticked. Raise it
    -- to match `megazoom` if you would rather always have the live render.
    liveZoomMax        = 60000,

    -- How the live render is taken. Each of these is the FIRST source of a
    -- chain, not a fixed choice: capture.lua measures what came back and
    -- steps to the next one if it cannot be drawn (see the long alpha note
    -- in that file).
    --   0 lit  - ask for SCS_SceneColorSceneDepth: the lit world, and the
    --            ONE source that comes back opaque, because it puts scene
    --            depth in the alpha channel where every other source puts
    --            a translucency that is zero over solid ground.
    --   1 flat - ask for SCS_BaseColor first: no lighting at all, so the
    --            minimap would read the same at midnight as at noon. Nicer
    --            when it works, but on stock Palworld it renders at alpha
    --            0 and EXPECT IT TO FALL BACK to the lit source above,
    --            after a few seconds of blank minimap per step.
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

    -- What language the F5 menu is written in. Empty or "auto" asks the
    -- GAME (see i18n.lua) and follows whatever the player set in its own
    -- options; a culture code such as "pt-BR" or "en" forces one. No menu
    -- row on purpose - this is an escape hatch for a build where the
    -- detection answers wrongly, not a setting worth a slider.
    menuLanguage       = "",

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
    showEffigies       = true,
    showSkillFruit     = true,
    showFastTravel     = true,
    showBaseCamps      = true,
    showEnemyCamps     = true,

    -- Things the game's own compass marks. These shipped OFF in 2.2.18 and
    -- are ON now, so the trade-off they were off FOR is live and worth
    -- stating: `maxPoiIcons` is one budget shared by DISTANCE across every
    -- static kind, and ore/forage/junk are numerous, so with these on a
    -- resource-dense area can push chests, dungeons and fast travel points
    -- off the minimap. Raising `maxPoiIcons` is the lever if that happens
    -- (it resizes the icon pool, so it costs a rebuild and some widgets).
    showResources      = true,   -- ore, stat-fruit lotuses, forage, junk
    showFishing        = true,
    showTreasureMaps   = true,
    showDungeons       = true,
    showTowers         = true,
    showDeaths         = true,

    iconSize           = 18,
    playerIconSize     = 22,

    -- Camera-facing sector centred on the player.
    -- Size is a fraction of the minimap diameter; 0.92 reaches 92% of the
    -- minimap radius because the cone starts at the image centre.
    showViewCone       = true,
    viewConeOpacity    = 0.22,
    viewConeSize       = 0.92,

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
    -- Other players. Always 0 in singleplayer (the local player is
    -- excluded by name), which is why this list went unbudgeted until
    -- 2.3.3 - see addPlayer() in sources.lua. Counted in the icon pool
    -- like the other three.
    maxPlayerIcons     = 16,
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

    -- 2.3.3: the three-way `mapSource` became the `liveTerrain` checkbox.
    -- An upgrading player's file still says `mapSource`, and merge() only
    -- looks at keys that are in DEFAULTS, so without this their choice
    -- would silently revert to the default. Only applied when the new key
    -- is absent, so it cannot overwrite a decision made since.
    if stored ~= nil and stored.liveTerrain == nil
       and type(stored.mapSource) == "number" then
        out.liveTerrain = stored.mapSource ~= 2      -- 0 auto / 1 live -> on
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
