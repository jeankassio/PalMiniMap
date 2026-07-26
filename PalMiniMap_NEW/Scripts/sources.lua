-- =====================================================================
-- sources.lua - what to draw
--
-- HOW A PAL'S SPECIES IS IDENTIFIED (taken from the original blueprint's
-- own bytecode, not guessed): every pal actor is named
--     BP_<Tribe>_C_<uniqueId>          e.g. "BP_Anubis_C_2147481234"
-- The blueprint split that on "BP_" and then on "_C_": the LEFT part is
-- the tribe ("Anubis"), which is exactly the row key of the icon data
-- table, and the RIGHT part is the per-instance id it used for dedupe.
-- The tribe maps straight onto the game's own icon texture:
--     /Game/Pal/Texture/PalIcon/Normal/T_<Tribe>_icon_normal
-- which is how 137 species icons come for free with nothing shipped.
--
-- Map objects are classified the same way - by name - because the actors
-- are blueprints, not the C++ *Model classes. Anything unclassified is
-- SKIPPED rather than drawn: scanning PalMapObject blindly was pulling in
-- every wall and foundation of the player's base (the ring of brackets in
-- the 2.0.0 screenshot). Unknown names are sampled into the log once so
-- the table below can be extended from evidence.
--
-- The exposure split that keeps this crash-safe is unchanged: static
-- marks keep plain numbers and never touch their actor again; dynamic
-- marks re-read the actor, but only ever validate-then-GetActorLocation
-- on the actor itself - never a walk to an attach parent or owner, which
-- is where both 1.x crashes happened.
-- =====================================================================

local guard = require("guard")

local M = {}

local PAL_ICON_FMT = "/Game/Pal/Texture/PalIcon/Normal/T_%s_icon_normal.T_%s_icon_normal"

local ICON = {
    player = "/Game/Pal/Texture/UI/InGame/T_icon_map_player.T_icon_map_player",
    member = "/Game/Pal/Texture/UI/InGame/T_icon_map_member.T_icon_map_member",
    death  = "/Game/Pal/Texture/UI/InGame/T_prt_map_death_1.T_prt_map_death_1",
    poi    = "/Game/Pal/Texture/UI/InGame/T_prt_map_cursor.T_prt_map_cursor",
}

local WHITE   = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 }
local TINT = {
    wild    = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 },
    friend  = { R = 0.65, G = 1.00, B = 0.75, A = 1.0 },
    shiny   = { R = 1.00, G = 0.90, B = 0.35, A = 1.0 },
    player  = { R = 0.40, G = 0.75, B = 1.00, A = 1.0 },
    chest   = { R = 1.00, G = 0.85, B = 0.35, A = 1.0 },
    travel  = { R = 0.55, G = 0.85, B = 1.00, A = 1.0 },
    dungeon = { R = 1.00, G = 0.45, B = 0.45, A = 1.0 },
    camp    = { R = 0.80, G = 0.65, B = 1.00, A = 1.0 },
}

-- name fragment -> category. Checked in order, first hit wins.
local POI_RULES = {
    { match = "FastTravel",  kind = "travel",  cfg = "showFastTravel" },
    { match = "TreasureBox", kind = "chest",   cfg = "showChests"     },
    { match = "ItemChest",   kind = "chest",   cfg = "showChests"     },
    { match = "DungeonEnt",  kind = "dungeon", cfg = "showDungeons"   },
    { match = "Dungeon",     kind = "dungeon", cfg = "showDungeons"   },
    { match = "BaseCamp",    kind = "camp",    cfg = "showBaseCamps"  },
}

local CANDIDATES = {
    pal    = { "PalCharacter" },
    player = { "PalPlayerCharacter" },
    mapobj = { "PalMapObject" },
}

local S = {
    pals = {},        -- { actor=, tribe=, shiny=, friend= }
    players = {},
    static = {},      -- { x, y, kind } - plain numbers only
    lastScan = 0.0,
    reported = {},
    unknownPoi = {},  -- name -> count, sampled for the log
    unknownLogged = false,
}

-- ---------------------------------------------------------------
-- helpers
-- ---------------------------------------------------------------
local function actorLocation(actor)
    if not guard.alive(actor) then return nil end
    local loc = guard.get(function() return actor:K2_GetActorLocation() end)
    if loc == nil then return nil end
    local x = guard.get(function() return loc.X end)
    local y = guard.get(function() return loc.Y end)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end
M.actorLocation = actorLocation

local function actorName(actor)
    local n = guard.get(function() return actor:GetFName():ToString() end)
    if type(n) == "string" and n ~= "" then return n end
    n = guard.get(function() return actor:GetFullName() end)
    if type(n) == "string" then return n end
    return nil
end

-- "BP_Anubis_C_2147481234" -> "Anubis". Also copes with names that carry
-- no BP_ prefix, and with variants like "BP_Anubis_Ice_C_12" (tribe keeps
-- its suffix, which is correct: the icon table has those rows too).
local function tribeOf(name)
    if type(name) ~= "string" then return nil end
    local body = name:match("^BP_(.+)$") or name
    local tribe = body:match("^(.-)_C_%d+$") or body:match("^(.-)_C$") or body
    if tribe == nil or tribe == "" then return nil end
    return tribe
end
M.tribeOf = tribeOf

local function isShiny(actor)
    local comp = guard.get(function() return actor:GetCharacterParameterComponent() end)
    if comp == nil then return false end
    local ind = guard.get(function() return comp.IndividualParameter end)
    if ind == nil then return false end
    local rare = guard.get(function() return ind:IsRarePal() end)
    return rare == true
end

local function isFriend(actor, playerChar)
    if playerChar == nil then return false end
    local f = guard.get(function() return actor:IsFriend(playerChar) end)
    return f == true
end

local function findAll(category)
    local names = CANDIDATES[category]
    if names == nil then return {} end
    for _, name in ipairs(names) do
        local found = guard.get(FindAllOf, name)
        if type(found) == "table" and #found > 0 then
            if not S.reported[category] then
                S.reported[category] = true
                guard.log(string.format("scan: '%s' matched class '%s' (%d objects)",
                                        category, name, #found))
            end
            return found
        end
    end
    if not S.reported[category] then
        S.reported[category] = true
        guard.log(string.format("scan: nothing matched for '%s' (tried %s)",
                                category, table.concat(names, ", ")))
    end
    return {}
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function classifyPoi(name)
    if type(name) ~= "string" then return nil end
    for _, rule in ipairs(POI_RULES) do
        if name:find(rule.match, 1, true) then return rule end
    end
    return nil
end

-- Log a sample of what did NOT classify, once, so the rules above can be
-- extended from real data instead of speculation.
local function noteUnknown(name)
    if S.unknownLogged or name == nil then return end
    local key = name:gsub("_C_%d+$", ""):gsub("_%d+$", "")
    S.unknownPoi[key] = (S.unknownPoi[key] or 0) + 1
end

local function flushUnknown()
    if S.unknownLogged then return end
    local list = {}
    for k, v in pairs(S.unknownPoi) do list[#list + 1] = { k = k, v = v } end
    if #list == 0 then return end
    table.sort(list, function(a, b) return a.v > b.v end)
    local parts = {}
    for i = 1, math.min(#list, 12) do
        parts[#parts + 1] = string.format("%s x%d", list[i].k, list[i].v)
    end
    S.unknownLogged = true
    guard.log("map objects not shown (unclassified, most common first): "
              .. table.concat(parts, ", "))
end

-- ---------------------------------------------------------------
-- scan
-- ---------------------------------------------------------------
function M.scan(cfg, px, py, playerChar)
    local radius = cfg.zoom * 0.75
    local maxD2 = radius * radius

    S.pals = {}
    S.players = {}
    S.static = {}

    if cfg.showPals then
        local all = findAll("pal")
        local near = {}
        for i = 1, #all do
            local a = all[i]
            local x, y = actorLocation(a)
            if x ~= nil then
                local d = dist2(x, y, px, py)
                if d <= maxD2 then near[#near + 1] = { actor = a, d = d } end
            end
        end
        table.sort(near, function(l, r) return l.d < r.d end)
        local budget = cfg.maxPalIcons
        for i = 1, #near do
            if #S.pals >= budget then break end
            local a = near[i].actor
            local shiny = isShiny(a)
            if (not cfg.onlyShinyPals) or shiny then
                S.pals[#S.pals + 1] = {
                    actor  = a,
                    tribe  = tribeOf(actorName(a)),
                    shiny  = shiny,
                    friend = isFriend(a, playerChar),
                }
            end
        end
    end

    if cfg.showPlayers then
        local all = findAll("player")
        for i = 1, #all do S.players[#S.players + 1] = all[i] end
    end

    local wantPoi = cfg.showChests or cfg.showFastTravel
                    or cfg.showDungeons or cfg.showBaseCamps
    if wantPoi then
        local all = findAll("mapobj")
        local budget = cfg.maxPoiIcons
        for i = 1, #all do
            if #S.static >= budget then break end
            local a = all[i]
            local name = actorName(a)
            local rule = classifyPoi(name)
            if rule == nil then
                noteUnknown(name)
            elseif cfg[rule.cfg] then
                local x, y = actorLocation(a)
                if x ~= nil and dist2(x, y, px, py) <= maxD2 then
                    S.static[#S.static + 1] = { x = x, y = y, kind = rule.kind }
                end
            end
        end
        flushUnknown()
    end

    S.lastScan = os.clock()
end

function M.lastScanAt() return S.lastScan end

-- ---------------------------------------------------------------
-- draw list
-- ---------------------------------------------------------------
function M.collect(cfg)
    local marks = {}

    for i = 1, #S.static do
        local s = S.static[i]
        marks[#marks + 1] = {
            x = s.x, y = s.y,
            texture = ICON.poi,
            size = cfg.iconSize,
            tint = TINT[s.kind] or WHITE,
        }
    end

    for i = 1, #S.pals do
        local p = S.pals[i]
        local x, y = actorLocation(p.actor)
        if x ~= nil then
            local tex, tint = ICON.member, TINT.wild
            if p.tribe then
                tex = string.format(PAL_ICON_FMT, p.tribe, p.tribe)
                -- a species portrait is full colour already; tinting it
                -- friend-green just muddies it. Only shiny gets a highlight,
                -- and it also gets the size bump below.
                tint = p.shiny and TINT.shiny or WHITE
            elseif p.friend then
                tint = TINT.friend
            end
            marks[#marks + 1] = {
                x = x, y = y,
                texture = tex,
                fallback = ICON.member,
                size = p.shiny and (cfg.iconSize + 4) or cfg.iconSize,
                tint = tint,
            }
        end
    end

    if cfg.showPlayers then
        for i = 1, #S.players do
            local x, y = actorLocation(S.players[i])
            if x ~= nil then
                marks[#marks + 1] = {
                    x = x, y = y,
                    texture = ICON.member,
                    size = cfg.iconSize,
                    tint = TINT.player,
                }
            end
        end
    end

    return marks
end

function M.forget()
    S.pals = {}
    S.players = {}
    S.static = {}
    S.lastScan = 0.0
end

return M
