-- =====================================================================
-- worldmap.lua - world coordinates -> map image coordinates
--
-- WHERE THESE NUMBERS COME FROM (not guesswork):
-- extracted from the game's own data table
--   /Game/Pal/DataTable/WorldMapUIData/DT_WorldMapUIData
-- whose rows use the struct PalWorldMapUIDataTableRow. Each row carries a
-- min and a max world vector. Decoded values:
--
--   region 1 : min (-1099400, -724400)  max ( 349400, 724400)
--   region 2 : min (  347351.5, -818197)  max ( 689148.5, -476400)
--
-- Both spans come out as EXACT squares -- 1448800 x 1448800 and
-- 341797 x 341797 -- which is the self-check that these really are the
-- world bounds the square map texture is stretched over. Region 1 is the
-- main island; region 2 is the smaller late-game island.
--
-- The background image is the game's own /Game/Pal/Texture/UI/Map/T_WorldMap,
-- so nothing has to be shipped and the art always matches the installed
-- game version.
--
-- WHICH WORLD AXIS RUNS WHICH WAY on that texture is a convention, not
-- something the data table states, so 2.0.x carried it as three settings
-- (`axis.swapXY`, `axis.flipH`, `axis.flipV`) in case the shipped guess was
-- wrong. It was not: the orientation below was confirmed in game in the
-- 2.0.0/2.0.1 runs - north is up and markers land where they should.
--
-- 2.1.1 removes the settings. They were the only knobs in the mod that
-- could not be set WRONG-but-harmlessly: any of the eight combinations
-- other than this one silently mirrors or rotates the whole coordinate
-- transform, so the terrain, the player marker and every icon disagree
-- with the world and the minimap looks broken rather than misconfigured.
-- A setting whose only non-default values are bugs is not a setting.
-- The orientation is now a constant, and the escape hatch if a game update
-- ever moves the world is calibrate() below, which reads the bounds
-- straight out of the game's own map widget.
-- =====================================================================

local guard = require("guard")

local M = {}

local REGIONS = {
    {
        name  = "MainWorld",
        minX  = -1099400.0, minY = -724400.0,
        maxX  =   349400.0, maxY =  724400.0,
        texture = "/Game/Pal/Texture/UI/Map/T_WorldMap",
    },
    {
        name  = "SecondIsland",
        minX  = 347351.5, minY = -818197.0,
        maxX  = 689148.5, maxY = -476400.0,
        texture = "/Game/Pal/Texture/UI/Map/T_WorldMap",
    },
}

-- Region whose bounds contain the point; falls back to the main island so
-- the minimap degrades to "slightly wrong" instead of "blank".
function M.regionFor(x, y)
    for _, r in ipairs(REGIONS) do
        if x >= r.minX and x <= r.maxX and y >= r.minY and y <= r.maxY then
            return r
        end
    end
    return REGIONS[1]
end

function M.regions() return REGIONS end

-- world -> normalised map position, both in 0..1, origin at the image's
-- top-left. Returns nil when the inputs are not usable.
function M.toUV(x, y, region)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    region = region or M.regionFor(x, y)
    local spanX = region.maxX - region.minX
    local spanY = region.maxY - region.minY
    if spanX == 0 or spanY == 0 then return nil end

    local u = (x - region.minX) / spanX
    local v = (y - region.minY) / spanY
    -- The confirmed orientation, was `axis = { swapXY = true, flipH = false,
    -- flipV = true }`: the image's horizontal axis follows world Y, and its
    -- vertical axis runs opposite to world X.
    return v, 1.0 - u
end

-- How many normalised units one world unit is worth, for the current
-- region. Used to turn a zoom expressed in metres into image space.
function M.unitsPerWorld(region)
    region = region or REGIONS[1]
    local spanX = region.maxX - region.minX
    if spanX == 0 then return 0 end
    return 1.0 / spanX
end

-- ---------------------------------------------------------------
-- Auto-calibration
--
-- The game's own map widget (WBP_Map_Body_C) keeps the same bounds in
-- `landScapeRealPositionMin` / `landScapeRealPositionMax`. When the player
-- has opened the world map at least once, that widget exists and we can
-- read the live values instead of trusting the numbers above -- which is
-- what keeps this working if a game update moves the world.
-- Best-effort and quiet: the widget usually is NOT loaded, and that is
-- fine, so a failure here is never logged as an error.
-- ---------------------------------------------------------------
-- FindAllOf walks the whole UObject array. The map widget only exists
-- once the player has opened the world map, so on a fresh session this
-- search fails forever - 2.0.5 retried it on every 2 s maintenance tick,
-- i.e. a full object-array walk twice a minute for nothing. Back off to
-- one attempt every 20 s and give up entirely after a few minutes; the
-- shipped bounds are correct anyway, calibration only guards against a
-- future game update moving them.
local CALIBRATE_RETRY = 20.0
local CALIBRATE_TRIES = 12
local calibrated = false
local calibrateTries = 0
local calibrateAt = 0.0

-- A level transition can bring in a different map; allow one more round
-- of attempts when the world changes.
function M.recalibrate()
    calibrated = false
    calibrateTries = 0
    calibrateAt = 0.0
end

local function vecOf(value)
    if value == nil then return nil end
    local x = guard.get(function() return value.X end)
    local y = guard.get(function() return value.Y end)
    if type(x) == "number" and type(y) == "number" then return x, y end
    return nil
end

function M.calibrate()
    if calibrated then return true end
    if calibrateTries >= CALIBRATE_TRIES then return false end
    local now = os.clock()
    if now < calibrateAt then return false end
    calibrateAt = now + CALIBRATE_RETRY
    calibrateTries = calibrateTries + 1
    local widgets = guard.get(FindAllOf, "WBP_Map_Body_C")
    if type(widgets) ~= "table" then return false end
    for _, w in ipairs(widgets) do
        if guard.alive(w) then
            local minX, minY = vecOf(guard.get(function() return w.landScapeRealPositionMin end))
            local maxX, maxY = vecOf(guard.get(function() return w.landScapeRealPositionMax end))
            if minX and maxX and maxX > minX and maxY > minY then
                local r = REGIONS[1]
                if math.abs(r.minX - minX) > 1.0 or math.abs(r.maxX - maxX) > 1.0
                   or math.abs(r.minY - minY) > 1.0 or math.abs(r.maxY - maxY) > 1.0 then
                    guard.log(string.format(
                        "map bounds calibrated from the game: (%.0f, %.0f)..(%.0f, %.0f)",
                        minX, minY, maxX, maxY))
                    r.minX, r.minY, r.maxX, r.maxY = minX, minY, maxX, maxY
                end
                calibrated = true
                return true
            end
        end
    end
    return false
end

return M
