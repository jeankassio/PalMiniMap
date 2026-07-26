-- =====================================================================
-- sources.lua - what to draw
--
-- THE CLASS LIST IS NOT GUESSWORK. Every class below was taken from the
-- import table of the original Paldar blueprint - i.e. these are exactly
-- the classes the 1.x mod scanned, so they are known to be the right ones
-- on this game build. Scanning the generic "PalMapObject" instead (2.0.0)
-- pulled in every wall and foundation of the player's base, which is the
-- ring of stray markers in the 2.0.0 screenshot.
--
-- HOW A PAL'S SPECIES IS IDENTIFIED, also from that blueprint's bytecode:
-- pal actors are named  BP_<Tribe>_C_<uniqueId>  ("BP_Anubis_C_2147481234").
-- Split on "BP_" then on "_C_" and the left part is the tribe, which is
-- both the icon table's row key and the texture name:
--     /Game/Pal/Texture/PalIcon/Normal/T_<Tribe>_icon_normal
-- That is how 137 species icons come for free with nothing shipped.
--
-- CRASH SAFETY, unchanged from 2.0.0: static marks (everything that does
-- not move) have their coordinates read ONCE at scan time and are then
-- plain numbers - their actor is never touched again. Only pals, players
-- and NPCs are re-read per frame, and that read is validate-then-
-- GetActorLocation on the actor itself, never a walk to an attach parent
-- or owner, which is where both 1.x crashes actually happened.
-- =====================================================================

local guard = require("guard")

local M = {}

local UI_IN  = "/Game/Pal/Texture/UI/InGame/"
local PAL_ICON_FMT = "/Game/Pal/Texture/PalIcon/Normal/T_%s_icon_normal.T_%s_icon_normal"

local function ui(name) return UI_IN .. name .. "." .. name end

local ICON = {
    player  = ui("T_icon_map_player"),
    member  = ui("T_icon_map_member"),
    death   = ui("T_prt_map_death_1"),
    chest   = ui("T_icon_compass_Search_Treasure"),
    travel  = ui("T_icon_compass_Teleport"),
    tower   = ui("T_icon_compass_tower"),
    dungeon = ui("T_icon_compass_dungeon"),
    camp    = ui("T_icon_compass_camp"),
    enemy   = ui("T_icon_compass_EnemyCamp"),
    egg     = ui("T_icon_compass_ClearCheck"),
    note    = ui("T_icon_compass_ClearCheck"),
    effigy  = ui("T_icon_compass_ClearCheck"),
    fruit   = ui("T_icon_compass_ClearCheck"),
}

local WHITE = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 }
local TINT = {
    friend  = { R = 0.65, G = 1.00, B = 0.75, A = 1.0 },
    shiny   = { R = 1.00, G = 0.88, B = 0.30, A = 1.0 },
    player  = { R = 0.45, G = 0.78, B = 1.00, A = 1.0 },
    npc     = { R = 0.95, G = 0.85, B = 0.65, A = 1.0 },
    egg     = { R = 1.00, G = 0.95, B = 0.75, A = 1.0 },
    note    = { R = 0.80, G = 0.90, B = 1.00, A = 1.0 },
    effigy  = { R = 0.70, G = 1.00, B = 0.80, A = 1.0 },
    fruit   = { R = 1.00, G = 0.70, B = 0.85, A = 1.0 },
}

-- Static world objects. `collectible` marks the ones that can be picked
-- up: chests and eggs simply despawn, notes and effigies stay in the
-- world with a "already taken" flag, exactly as in 1.x.
local STATIC_KINDS = {
    { cfg = "showChests",     class = "PalMapObjectTreasureBox",                kind = "chest",   collectible = true  },
    { cfg = "showEggs",       class = "PalMapObjectPalEgg",                     kind = "egg",     collectible = true  },
    { cfg = "showNotes",      class = "PalLevelObjectNote",                     kind = "note",    collectible = true  },
    { cfg = "showEffigies",   class = "PalLevelObjectRelic",                    kind = "effigy",  collectible = true  },
    { cfg = "showSkillFruit", class = "PalMapObjectSpawnerMultiItem",           kind = "fruit"    },
    { cfg = "showFastTravel", class = "PalLevelObjectUnlockableFastTravelPoint", kind = "travel"  },
    { cfg = "showDungeons",   class = "BP_DungeonEntrance_Base_C",              kind = "dungeon"  },
    { cfg = "showBaseCamps",  class = "PalBuildObjectBaseCampPoint",            kind = "camp"     },
    { cfg = "showEnemyCamps", class = "PalNPCCampSpawnerBase",                  kind = "enemy"    },
    { cfg = "showTowers",     class = "PalBossTower",                           kind = "tower"    },
    { cfg = "showDeaths",     class = "BP_MapObject_DeathPenaltyChest_C",       kind = "death"    },
}

local S = {
    pals = {}, players = {}, npcs = {},
    static = {},
    lastScan = 0.0,
    reported = {},
    campNear = false,
}

-- ---------------------------------------------------------------
-- reflection helpers
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
    return nil
end

-- "BP_Anubis_C_2147481234" -> "Anubis"; keeps variant suffixes such as
-- "FlameBuffalo_Ice", which are their own rows in the icon table.
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
    return guard.get(function() return ind:IsRarePal() end) == true
end

local function isFriend(actor, playerChar)
    if playerChar == nil then return false end
    return guard.get(function() return actor:IsFriend(playerChar) end) == true
end

-- Reflected booleans can arrive wrapped on some UE4SS builds; `== true`
-- on the wrapper would read every collected item as still available.
local function asBool(v)
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    if v == nil then return nil end
    local inner = guard.get(function() return v:get() end)
    if type(inner) == "boolean" then return inner end
    if type(inner) == "number" then return inner ~= 0 end
    return nil
end

-- Only meaningful for notes and effigies: those stay in the world after
-- being taken, with the flag set. Chests and eggs just despawn, so they
-- disappear on their own at the next scan.
local function alreadyCollected(actor)
    return asBool(guard.get(function() return actor.bPickedInClient end)) == true
end

local function findAll(class, label)
    local found = guard.get(FindAllOf, class)
    if type(found) == "table" and #found > 0 then
        if not S.reported[class] then
            S.reported[class] = true
            guard.log(string.format("scan: %s -> '%s' (%d)", label, class, #found))
        end
        return found
    end
    if not S.reported[class] then
        S.reported[class] = true
        guard.log(string.format("scan: %s -> '%s' found nothing", label, class))
    end
    return {}
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

-- ---------------------------------------------------------------
-- scan
-- ---------------------------------------------------------------
function M.scan(cfg, px, py, playerChar)
    local radius = math.max(cfg.zoom, cfg.megazoom) * 0.75
    local maxD2 = radius * radius

    S.pals, S.players, S.npcs, S.static = {}, {}, {}, {}
    S.campNear = false

    if cfg.showPals then
        local all = findAll("PalCharacter", "pals")
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
        for i = 1, #near do
            if #S.pals >= cfg.maxPalIcons then break end
            local a = near[i].actor
            local shiny = isShiny(a)
            if (not cfg.onlyShinyPals) or shiny then
                S.pals[#S.pals + 1] = {
                    actor = a, tribe = tribeOf(actorName(a)),
                    shiny = shiny, friend = isFriend(a, playerChar),
                }
            end
        end
    end

    if cfg.showPlayers then
        local all = findAll("PalPlayerCharacter", "players")
        for i = 1, #all do S.players[#S.players + 1] = all[i] end
    end

    if cfg.showNPCs then
        local all = findAll("PalNPC", "NPC humans")
        for i = 1, #all do
            local x, y = actorLocation(all[i])
            if x ~= nil and dist2(x, y, px, py) <= maxD2 then
                S.npcs[#S.npcs + 1] = all[i]
            end
        end
    end

    local campRadius2 = cfg.baseCampRadius * cfg.baseCampRadius
    for _, spec in ipairs(STATIC_KINDS) do
        if cfg[spec.cfg] or spec.kind == "camp" then
            local all = findAll(spec.class, spec.kind)
            for i = 1, #all do
                if #S.static >= cfg.maxPoiIcons then break end
                local a = all[i]
                local x, y = actorLocation(a)
                if x ~= nil then
                    local d = dist2(x, y, px, py)
                    if spec.kind == "camp" and d <= campRadius2 then
                        S.campNear = true   -- drives "autohide inside base camps"
                    end
                    if d <= maxD2 and cfg[spec.cfg] then
                        local skip = cfg.hideCollected and spec.collectible
                                     and alreadyCollected(a)
                        if not skip then
                            S.static[#S.static + 1] = { x = x, y = y, kind = spec.kind }
                        end
                    end
                end
            end
        end
    end

    S.lastScan = os.clock()
end

function M.insideBaseCamp() return S.campNear end
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
            texture = ICON[s.kind] or ICON.member,
            size = cfg.iconSize,
            tint = TINT[s.kind] or WHITE,
        }
    end

    for i = 1, #S.pals do
        local p = S.pals[i]
        local x, y = actorLocation(p.actor)
        if x ~= nil then
            local tex, tint = ICON.member, (p.friend and TINT.friend or WHITE)
            if p.tribe then
                tex = string.format(PAL_ICON_FMT, p.tribe, p.tribe)
                -- a species portrait is already full colour; only shiny
                -- gets a highlight (and the size bump below)
                tint = p.shiny and TINT.shiny or WHITE
            elseif p.shiny then
                tint = TINT.shiny
            end
            marks[#marks + 1] = {
                x = x, y = y, texture = tex, fallback = ICON.member,
                size = p.shiny and (cfg.iconSize + 4) or cfg.iconSize,
                tint = tint,
                isPal = true,   -- lets megazoom drop pal icons (1.x option)
            }
        end
    end

    for i = 1, #S.players do
        local x, y = actorLocation(S.players[i])
        if x ~= nil then
            marks[#marks + 1] = { x = x, y = y, texture = ICON.member,
                                  size = cfg.iconSize, tint = TINT.player }
        end
    end

    for i = 1, #S.npcs do
        local x, y = actorLocation(S.npcs[i])
        if x ~= nil then
            marks[#marks + 1] = { x = x, y = y, texture = ICON.member,
                                  size = cfg.iconSize, tint = TINT.npc }
        end
    end

    return marks
end

function M.forget()
    S.pals, S.players, S.npcs, S.static = {}, {}, {}, {}
    S.campNear = false
    S.lastScan = 0.0
end

return M
