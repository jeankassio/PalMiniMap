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
-- CRASH SAFETY: static marks (everything that does not move) have their
-- coordinates read ONCE at scan time and are then plain numbers - their
-- actor is never touched again. Only pals, players and NPCs are re-read
-- per frame, and that read is validate-then-GetActorLocation on the actor
-- itself, never a walk to an attach parent or owner, which is where both
-- 1.x crashes actually happened.
--
-- COST: every FindAllOf is a full walk of the UObject array, and Palworld
-- keeps a lot of objects. 2.0.5 did fourteen of those walks every four
-- seconds, which is the frame-time spike people described as "stutter
-- every few seconds". The scan is now split:
--   * scanDynamic  - pals, players, NPCs. They move, so 4 s (configurable).
--   * scanStatic   - chests, dungeons, fast travel... They do not move, so
--                    it runs on a 15 s floor and whenever the player has
--                    actually travelled somewhere new (see main.lua).
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
    static = {},            -- { x, y, kind } sorted by distance at scan time
    camps  = {},            -- { x, y } base camp points, for the autohide
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

local EMPTY = {}    -- shared: callers only ever read it

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
    return EMPTY
end

local function dist2(ax, ay, bx, by)
    local dx, dy = ax - bx, ay - by
    return dx * dx + dy * dy
end

local function byDistance(l, r) return l.d < r.d end

-- How far out to keep things, from the zoom actually in use. 2.0.5 always
-- used max(zoom, megazoom) - i.e. the 260 000 unit megazoom radius even
-- while zoomed all the way in - so every scan sorted and kept hundreds of
-- actors that could never be on screen.
local function keepRadius2(zoom, pad)
    local r = (zoom or 22000) * 0.85
    if r < 8000 then r = 8000 end
    return (r + (pad or 0)) ^ 2
end

-- How far the player may travel before the static list is refreshed, and
-- therefore how much MARGIN the static scan has to keep beyond the visible
-- radius. Without it a chest could sit just off the edge of the view at
-- scan time and still be missing after the player walked right up to it.
-- main.lua uses the same number as its "player moved somewhere new"
-- trigger, so the two can never disagree.
M.STATIC_PAD = 15000

-- ---------------------------------------------------------------
-- dynamic scan: pals, players, NPCs
-- ---------------------------------------------------------------
local nearScratch = {}

function M.scanDynamic(cfg, px, py, zoom, playerPawn)
    local maxD2 = keepRadius2(zoom)

    S.pals, S.players, S.npcs = {}, {}, {}

    -- PalPlayerCharacter and PalNPC both derive from PalCharacter, so a
    -- plain FindAllOf("PalCharacter") returns the local player, every
    -- other player and every human NPC as well. 2.0.5 drew all of them as
    -- pals - which is the duplicate marker sitting permanently under the
    -- player arrow - so they are collected first and then excluded by
    -- name (actor names are unique within a level, and identity comparison
    -- on reflected UObjects is not reliable across calls).
    local excluded = nil
    local function exclude(actor)
        local n = actorName(actor)
        if n ~= nil then
            excluded = excluded or {}
            excluded[n] = true
        end
        return n
    end

    -- The local player is drawn by the centred player marker, so it must
    -- not also come back as an "other player": 2.0.5 stacked a second
    -- icon underneath the arrow, permanently.
    local selfName = playerPawn ~= nil and exclude(playerPawn) or nil

    if cfg.showPlayers or cfg.showPals then
        local all = findAll("PalPlayerCharacter", "players")
        for i = 1, #all do
            local a = all[i]
            local n = exclude(a)
            if cfg.showPlayers and n ~= selfName then
                S.players[#S.players + 1] = a
            end
        end
    end

    if cfg.showNPCs or cfg.showPals then
        local all = findAll("PalNPC", "NPC humans")
        for i = 1, #all do
            local a = all[i]
            exclude(a)
            if cfg.showNPCs then
                local x, y = actorLocation(a)
                if x ~= nil and dist2(x, y, px, py) <= maxD2 then
                    S.npcs[#S.npcs + 1] = a
                end
            end
        end
    end

    if cfg.showPals then
        local all = findAll("PalCharacter", "pals")
        local near, n = nearScratch, 0
        for i = 1, #all do
            local a = all[i]
            local name = actorName(a)
            if name ~= nil and not (excluded and excluded[name]) then
                local x, y = actorLocation(a)
                if x ~= nil then
                    local d = dist2(x, y, px, py)
                    if d <= maxD2 then
                        n = n + 1
                        local slot = near[n]
                        if slot == nil then slot = {}; near[n] = slot end
                        slot.actor, slot.d, slot.name = a, d, name
                    end
                end
            end
        end
        -- table.sort only sees the live prefix
        for i = #near, n + 1, -1 do near[i] = nil end
        table.sort(near, byDistance)
        local limit = cfg.maxPalIcons
        for i = 1, n do
            if #S.pals >= limit then break end
            local a = near[i].actor
            local shiny = isShiny(a)
            if (not cfg.onlyShinyPals) or shiny then
                S.pals[#S.pals + 1] = {
                    actor = a, tribe = tribeOf(near[i].name),
                    shiny = shiny, friend = isFriend(a, playerPawn),
                }
            end
        end
        -- do not keep actor references alive in the scratch table
        for i = 1, n do near[i].actor = nil end
    end

    S.lastScan = os.clock()
end

-- ---------------------------------------------------------------
-- static scan: everything that does not move
-- ---------------------------------------------------------------
local staticScratch = {}

function M.scanStatic(cfg, px, py, zoom)
    local maxD2 = keepRadius2(zoom, M.STATIC_PAD)
    local wantCamps = cfg.showBaseCamps or cfg.autohideInBase

    local found, n = staticScratch, 0
    S.camps = {}

    for _, spec in ipairs(STATIC_KINDS) do
        local wanted = cfg[spec.cfg] == true
        if wanted or (spec.kind == "camp" and wantCamps) then
            local all = findAll(spec.class, spec.kind)
            for i = 1, #all do
                local a = all[i]
                local x, y = actorLocation(a)
                if x ~= nil then
                    if spec.kind == "camp" and wantCamps then
                        S.camps[#S.camps + 1] = { x = x, y = y }
                    end
                    if wanted then
                        local d = dist2(x, y, px, py)
                        if d <= maxD2 then
                            local skip = cfg.hideCollected and spec.collectible
                                         and alreadyCollected(a)
                            if not skip then
                                n = n + 1
                                local slot = found[n]
                                if slot == nil then slot = {}; found[n] = slot end
                                slot.x, slot.y, slot.kind, slot.d = x, y, spec.kind, d
                            end
                        end
                    end
                end
            end
        end
    end

    -- 2.0.5 stopped as soon as maxPoiIcons was reached, in table order, so
    -- a chest-heavy area used the whole budget on chests and fast travel
    -- points and dungeons never appeared at all. Sorting by distance first
    -- means the budget always goes to the nearest markers, whatever kind
    -- they are.
    for i = #found, n + 1, -1 do found[i] = nil end
    table.sort(found, byDistance)

    local limit = math.min(n, cfg.maxPoiIcons)
    local out = {}
    for i = 1, limit do
        out[i] = { x = found[i].x, y = found[i].y, kind = found[i].kind }
    end
    S.static = out
end

-- Base camp proximity is recomputed from the stored camp positions on
-- every dynamic scan: the camps do not move, but the player does.
function M.updateProximity(cfg, px, py)
    if not cfg.autohideInBase then S.campNear = false; return end
    local r2 = cfg.baseCampRadius * cfg.baseCampRadius
    for i = 1, #S.camps do
        if dist2(S.camps[i].x, S.camps[i].y, px, py) <= r2 then
            S.campNear = true
            return
        end
    end
    S.campNear = false
end

function M.insideBaseCamp() return S.campNear end
function M.lastScanAt() return S.lastScan end

-- ---------------------------------------------------------------
-- draw list
--
-- Called at the movement rate (10 Hz by default), so it must not
-- allocate: the mark tables are pooled and refilled in place, and the
-- caller is handed the pool plus a count instead of a fresh array. At 96
-- icons that is ~100 tables saved from the collector every 100 ms.
-- ---------------------------------------------------------------
local markPool = {}

local function emit(n, x, y, tex, size, tint, fallback, isPal)
    n = n + 1
    local m = markPool[n]
    if m == nil then m = {}; markPool[n] = m end
    m.x, m.y = x, y
    m.texture, m.fallback = tex, fallback
    m.size, m.tint, m.isPal = size, tint, isPal
    return n
end

function M.collect(cfg)
    local n = 0
    local isz = cfg.iconSize

    for i = 1, #S.static do
        local s = S.static[i]
        n = emit(n, s.x, s.y, ICON[s.kind] or ICON.member, isz,
                 TINT[s.kind] or WHITE, ICON.member, false)
    end

    -- while megazoomed, pal icons are optional (1.x: "show pal icons while
    -- megazoomed out") - they turn into noise at region scale
    local withPals = not (cfg.megazoomActive and not cfg.palsWhileMegazoom)
    if withPals then
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
                n = emit(n, x, y, tex, p.shiny and (isz + 4) or isz,
                         tint, ICON.member, true)
            end
        end
    end

    for i = 1, #S.players do
        local x, y = actorLocation(S.players[i])
        if x ~= nil then
            n = emit(n, x, y, ICON.member, isz, TINT.player, nil, false)
        end
    end

    for i = 1, #S.npcs do
        local x, y = actorLocation(S.npcs[i])
        if x ~= nil then
            n = emit(n, x, y, ICON.member, isz, TINT.npc, nil, false)
        end
    end

    return markPool, n
end

function M.forget()
    S.pals, S.players, S.npcs = {}, {}, {}
    S.static, S.camps = {}, {}
    S.campNear = false
    S.lastScan = 0.0
    -- drop the actor references the pools would otherwise keep alive
    for i = 1, #nearScratch do nearScratch[i].actor = nil end
end

return M
