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
-- STILL TO CONFIRM IN GAME: which world axis runs which way on that
-- texture. UE's +X/+Y vs. the image's right/down is a convention, not
-- something the data table states. Every combination is expressible
-- through the `axis` settings below, so fixing it is a config change and
-- never a code change. calibrate() also tries to read the values straight
-- out of the game's own map widget when it happens to be loaded, which
-- keeps this correct across game updates.
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

-- Axis convention, overridable from the settings file.
--   swapXY  : the image's horizontal axis follows world Y instead of world X
--   flipH   : mirror the horizontal axis
--   flipV   : mirror the vertical axis
local axis = { swapXY = true, flipH = false, flipV = true }

function M.setAxis(cfg)
    if type(cfg) ~= "table" then return end
    if type(cfg.swapXY) == "boolean" then axis.swapXY = cfg.swapXY end
    if type(cfg.flipH)  == "boolean" then axis.flipH  = cfg.flipH  end
    if type(cfg.flipV)  == "boolean" then axis.flipV  = cfg.flipV  end
end

function M.getAxis()
    return { swapXY = axis.swapXY, flipH = axis.flipH, flipV = axis.flipV }
end

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
    if axis.swapXY then u, v = v, u end
    if axis.flipH then u = 1.0 - u end
    if axis.flipV then v = 1.0 - v end
    return u, v
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
