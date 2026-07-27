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
local assets = require("assets")

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
    version = 0,            -- bumps when scan data changes
    staticDirty = false,    -- static list needs a rebuild
    staticRebuildAt = 0.0,   -- throttle rebuilds so they do not spike
}

-- ---------------------------------------------------------------
-- reflection helpers
--
-- Every one of these is a hoisted top-level function called through
-- pcall(fn, args) rather than pcall(function() ... end). A scan touches
-- hundreds of actors, and the closure-per-read style these used to be
-- written in allocated three or four garbage objects per actor per read -
-- thousands of them every few seconds, on the game thread. That is what
-- the collector was doing when the frame hitched.
-- ---------------------------------------------------------------
local function rawLocation(actor)
    local loc = actor:K2_GetActorLocation()
    return loc.X, loc.Y
end

local function actorLocation(actor)
    if not guard.alive(actor) then return nil end
    local ok, x, y = pcall(rawLocation, actor)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end
M.actorLocation = actorLocation

local function rawName(actor) return actor:GetFName():ToString() end

local function actorName(actor)
    local ok, n = pcall(rawName, actor)
    if ok and type(n) == "string" and n ~= "" then return n end
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

local function rawShiny(actor)
    return actor:GetCharacterParameterComponent().IndividualParameter:IsRarePal()
end

local function isShiny(actor)
    local ok, v = pcall(rawShiny, actor)
    return ok and v == true
end

local function rawFriend(actor, other) return actor:IsFriend(other) end

local function isFriend(actor, playerChar)
    if playerChar == nil then return false end
    local ok, v = pcall(rawFriend, actor, playerChar)
    return ok and v == true
end

local function rawUnwrap(v) return v:get() end

-- Reflected booleans can arrive wrapped on some UE4SS builds; `== true`
-- on the wrapper would read every collected item as still available.
local function asBool(v)
    if type(v) == "boolean" then return v end
    if type(v) == "number" then return v ~= 0 end
    if v == nil then return nil end
    local ok, inner = pcall(rawUnwrap, v)
    if not ok then return nil end
    if type(inner) == "boolean" then return inner end
    if type(inner) == "number" then return inner ~= 0 end
    return nil
end

local function rawPicked(actor) return actor.bPickedInClient end

-- Only meaningful for notes and effigies: those stay in the world after
-- being taken, with the flag set. Chests and eggs just despawn, so they
-- disappear on their own at the next scan.
local function alreadyCollected(actor)
    local ok, v = pcall(rawPicked, actor)
    if not ok then return false end
    return asBool(v) == true
end

local EMPTY = {}    -- shared: callers only ever read it

local function wipe(t)
    for i = #t, 1, -1 do
        t[i] = nil
    end
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

-- ---------------------------------------------------------------
-- Telling a pal from a human, WITHOUT guessing at the class tree
--
-- THE HISTORY, because two releases got this wrong in opposite ways.
-- 2.0.6 subtracted FindAllOf("PalNPC") from FindAllOf("PalCharacter") to
-- stop drawing NPC humans as pals, and erased EVERY pal: on this build
-- PalNPC is a SUPERCLASS of wild pals, not a sibling class. 2.0.8 noticed
-- that and stopped subtracting - which put the humans back INTO the pal
-- list, where they were drawn with the generic member marker (the arrows
-- the player reported) and, worse, ate the maxPalIcons budget, so real
-- pals fell off the end of the list. Both halves of "not all pals show,
-- some show as arrows" are that one line.
--
-- Neither the class tree nor its inverse is a safe thing to hard-code, so
-- the question is answered directly instead: A PAL HAS A SPECIES ICON.
-- The tribe comes out of the actor name and the icon asset either exists
-- in the game's content or it does not. That is a fact about the actor,
-- not about a hierarchy a game update can rearrange.
--
-- The safety valve is as important as the test: until at least one icon
-- has actually resolved, we do not know the path format is right on this
-- build, so NOTHING is filtered and behaviour is exactly what it was.
-- That is what makes this incapable of repeating 2.0.6.
-- ---------------------------------------------------------------
-- 2.1.1: THIS FUNCTION NO LONGER LOADS ANYTHING. 2.1.0 probed with its own
-- StaticFindObject + LoadAsset, six per scan, on the scan tick - and then
-- render.lua loaded the very same path a second time through its own queue.
-- Both halves are now one throttled queue in assets.lua, and everything
-- here is table work: `assets.probe` answers from its cache, or schedules
-- the work and says "not yet". The species path is also exactly the path
-- the icon will be drawn with, so asking the question warms the cache for
-- the draw - the two are the same request, made once.
local iconForTribe = {}         -- tribe -> asset path. POSITIVE results only,
                                -- and permanent: an asset does not stop existing
local notAPal = {}              -- tribe -> true. Negative results, and they are
                                -- NOT permanent - see below
local pathForTribe = {}         -- tribe -> formatted path, so the scan does not
                                -- string.format the same path every four seconds
local iconFormatWorks = false   -- one resolved icon proves the path format
local noIconNames, noIconCount = {}, 0
local reportedNoIcon = false

-- Returns the icon path for a real pal species, `false` for something that
-- has none (a human), or nil while we have not settled the question.
--
-- A NEGATIVE IS NEVER TAKEN ON THE FIRST TRY. Palworld streams its assets:
-- a probe that runs during a load screen can come back empty for a species
-- that is perfectly real, and caching that permanently would draw that
-- species as a human for the rest of the session. The retry policy lives
-- in assets.lua (three attempts with a growing backoff, all forgiven on a
-- world change) and `nil` here means it has not finished trying. Until it
-- is settled the actor is treated as a pal, which is the pre-2.1.0
-- behaviour and therefore always the safe direction to be wrong.
local function speciesIcon(tribe)
    if tribe == nil or tribe == "" then return false end
    local hit = iconForTribe[tribe]
    if hit ~= nil then return hit end
    if notAPal[tribe] then return false end

    local path = pathForTribe[tribe]
    if path == nil then
        path = string.format(PAL_ICON_FMT, tribe, tribe)
        pathForTribe[tribe] = path
    end

    local exists = assets.probe(path)
    if exists == nil then return nil end        -- still queued
    if exists then
        iconForTribe[tribe] = path
        iconFormatWorks = true
        return path
    end
    notAPal[tribe] = true
    if noIconCount < 12 then
        noIconCount = noIconCount + 1
        noIconNames[noIconCount] = tribe
    end
    return false
end

-- PalPlayerCharacter is still used as an exclusion set - other players are
-- drawn by their own marker and must not also appear as pals. Unlike
-- PalNPC it cannot plausibly be a superclass of pals, but the ratio guard
-- costs nothing and says so in the log if a build ever surprises us.
local EXCLUSION_MAX_SHARE = 0.6
local rejectedClass = {}

local function usableForExclusion(class, count, palCount)
    if count == 0 or palCount < 8 then return true end
    if count <= palCount * EXCLUSION_MAX_SHARE then return true end
    if not rejectedClass[class] then
        rejectedClass[class] = true
        guard.log(string.format(
            "'%s' matched %d of %d PalCharacters - on this build it is a superclass of "
            .. "pals, not a separate kind of actor, so it is ignored", class, count, palCount))
    end
    return false
end

local reportedScan = false

local function addExcluded(excluded, actor)
    local n = actorName(actor)
    if n ~= nil then
        excluded[n] = true
    end
    return n
end

function M.scanDynamic(cfg, px, py, zoom, playerPawn)
    local maxD2 = keepRadius2(zoom)

    wipe(S.pals); wipe(S.players); wipe(S.npcs)

    local wantCharacters = cfg.showPals or cfg.showNPCs
    local rawPals = wantCharacters and findAll("PalCharacter", "characters") or EMPTY
    local palCount = #rawPals

    -- Excluded by actor NAME: names are unique within a level, and
    -- identity comparison on reflected UObjects is not reliable across
    -- calls.
    local excluded = nil

    -- The local player is drawn by the centred player marker, so it must
    -- not also come back as an "other player": 2.0.5 stacked a second
    -- icon underneath the arrow, permanently.
    if playerPawn ~= nil then
        excluded = excluded or {}
    end
    local selfName = playerPawn ~= nil and addExcluded(excluded, playerPawn) or nil
    local nPlayers = 0

    if wantCharacters and not rejectedClass["PalPlayerCharacter"] then
        local all = findAll("PalPlayerCharacter", "players")
        if usableForExclusion("PalPlayerCharacter", #all, palCount) then
            nPlayers = #all
            excluded = excluded or {}
            for i = 1, #all do
                local a = all[i]
                local n = addExcluded(excluded, a)
                if cfg.showPlayers and n ~= selfName then
                    S.players[#S.players + 1] = a
                end
            end
        end
    end

    -- There is no FindAllOf("PalNPC") any more. It was a full walk of the
    -- UObject array every scan for a result we had already decided to
    -- throw away, and the humans it was meant to find come out of the pass
    -- below for free.
    if wantCharacters then
        local near, n = nearScratch, 0
        for i = 1, palCount do
            local a = rawPals[i]
            -- Distance FIRST. The name is only needed for the exclusion
            -- set and the species lookup, and reading it for every actor
            -- in the level - most of them kilometres away - doubled the
            -- reflection cost of the scan.
            local x, y = actorLocation(a)
            if x ~= nil then
                local d = dist2(x, y, px, py)
                if d <= maxD2 then
                    local name = actorName(a)
                    if name ~= nil and not (excluded and excluded[name]) then
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

        -- Nearest first, so the icon budget always goes to what is closest.
        local limit = cfg.maxPalIcons
        local nPals, nHumans = 0, 0
        for i = 1, n do
            local e = near[i]
            local icon = speciesIcon(tribeOf(e.name))
            -- nil  = not probed yet
            -- false + format unproven = we have no basis to filter anything
            local isPal = (icon ~= false) or (not iconFormatWorks)
            if isPal then
                nPals = nPals + 1
                if cfg.showPals and #S.pals < limit then
                    local a = e.actor
                    local shiny = isShiny(a)
                    if (not cfg.onlyShinyPals) or shiny then
                        S.pals[#S.pals + 1] = {
                            actor = a,
                            -- resolved ONCE, at scan time. collect() used to
                            -- string.format this path for every pal on every
                            -- frame - 480 throwaway strings a second at the
                            -- default settings.
                            icon = (type(icon) == "string") and icon or nil,
                            shiny = shiny, friend = isFriend(a, playerPawn),
                        }
                    end
                end
            else
                nHumans = nHumans + 1
                if cfg.showNPCs then S.npcs[#S.npcs + 1] = e.actor end
            end
        end

        -- one line, once: enough to tell "no pals nearby" apart from "the
        -- filter ate them", which is the question this whole thing exists for
        if not reportedScan and palCount > 0 then
            reportedScan = true
            guard.log(string.format(
                "character scan: %d PalCharacters, %d players excluded, %d in range -> %d pals, %d humans",
                palCount, nPlayers, n, nPals, nHumans))
        end
        if not reportedNoIcon and iconFormatWorks and noIconCount > 0 then
            reportedNoIcon = true
            guard.log("no species icon for: " .. table.concat(noIconNames, ", ", 1, noIconCount)
                .. " - drawn as NPC humans, not as pals (turn 'Show NPC humans' off to hide them)")
        end

        -- do not keep actor references alive in the scratch table
        for i = 1, n do near[i].actor = nil end
    end

    S.lastScan = os.clock()
    S.version = S.version + 1
end

-- ---------------------------------------------------------------
-- static scan: everything that does not move
--
-- SPREAD ACROSS TICKS. Every FindAllOf is a full walk of the UObject
-- array, and running eleven of them back to back on the game thread is a
-- frame spike you can feel - it was a large part of the 2.0.8 stuttering.
-- Only ONE class is scanned per call once things have settled (three
-- while a kind has never been looked at, so the map fills in quickly
-- after a load), and the expensive rebuild is deferred until the draw
-- path actually needs fresh static markers.
--
-- This is only sound because these things do not move: a cache scanned
-- thirty seconds ago is still exactly right, apart from items that have
-- been picked up since - and those go away on that kind's next turn.
-- ---------------------------------------------------------------
local kindCache = {}      -- kind -> { x, y, ... }  positions only
local kindSeen = {}       -- kind -> true once scanned at least once
local rotation = 1

local function wantedKind(cfg, spec)
    if cfg[spec.cfg] == true then return true end
    if spec.kind == "camp" and cfg.autohideInBase then return true end
    return false
end

local function scanOneKind(cfg, spec)
    local list = kindCache[spec.kind]
    if list == nil then list = {}; kindCache[spec.kind] = list end

    local all = findAll(spec.class, spec.kind)
    local count = 0
    for i = 1, #all do
        local a = all[i]
        local x, y = actorLocation(a)
        if x ~= nil then
            local skip = cfg.hideCollected and spec.collectible
                         and alreadyCollected(a)
            if not skip then
                count = count + 1
                local p = list[count]          -- reused, not reallocated
                if p == nil then p = {}; list[count] = p end
                p.x, p.y = x, y
            end
        end
    end
    for i = #list, count + 1, -1 do list[i] = nil end
    kindSeen[spec.kind] = true
    return true
end

local staticScratch = {}

-- Rebuild the merged, distance-sorted, capped draw list from the caches.
-- Pure arithmetic over a few hundred entries: no reflection at all.
local function rebuildStatic(cfg, px, py, zoom)
    local maxD2 = keepRadius2(zoom, M.STATIC_PAD)
    local found, n = staticScratch, 0
    local camps = S.camps
    for i = #camps, 1, -1 do camps[i] = nil end

    for _, spec in ipairs(STATIC_KINDS) do
        local list = kindCache[spec.kind]
        if list ~= nil then
            local visible = cfg[spec.cfg] == true
            local isCamp = spec.kind == "camp"
            for i = 1, #list do
                local p = list[i]
                if isCamp and cfg.autohideInBase then
                    camps[#camps + 1] = p
                end
                if visible then
                    local d = dist2(p.x, p.y, px, py)
                    if d <= maxD2 then
                        n = n + 1
                        local slot = found[n]
                        if slot == nil then slot = {}; found[n] = slot end
                        slot.x, slot.y, slot.kind, slot.d = p.x, p.y, spec.kind, d
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
    local out = S.static
    for i = 1, limit do
        local slot = found[i]
        local o = out[i]
        if o == nil then o = {}; out[i] = o end
        o.x, o.y, o.kind = slot.x, slot.y, slot.kind
    end
    for i = #out, limit + 1, -1 do out[i] = nil end
    S.staticDirty = false
    S.staticRebuildAt = os.clock()
end

function M.scanStatic(cfg, px, py, zoom)
    -- three at a time while the map is still filling in after a load,
    -- one at a time from then on
    local budget = 1
    for _, spec in ipairs(STATIC_KINDS) do
        if wantedKind(cfg, spec) and not kindSeen[spec.kind] then budget = 3; break end
    end

    local changed = false
    local checked = 0
    while budget > 0 and checked < #STATIC_KINDS do
        local spec = STATIC_KINDS[rotation]
        rotation = (rotation % #STATIC_KINDS) + 1
        checked = checked + 1
        if wantedKind(cfg, spec) then
            if scanOneKind(cfg, spec) then
                changed = true
            end
            budget = budget - 1
        elseif kindCache[spec.kind] ~= nil then
            kindCache[spec.kind] = nil     -- turned off: drop its markers
            kindSeen[spec.kind] = nil
            changed = true
        end
    end

    if changed then
        S.staticDirty = true
        S.version = S.version + 1
    end
    -- rebuildStatic() is deferred to collect() so this scan stays spread out.
end

-- Base camp proximity is recomputed from the stored camp positions on
-- every dynamic scan: the camps do not move, but the player does.
function M.updateProximity(cfg, px, py)
    if not cfg.autohideInBase then S.campNear = false; return end
    local camps = kindCache.camp or S.camps
    local r2 = cfg.baseCampRadius * cfg.baseCampRadius
    for i = 1, #camps do
        if dist2(camps[i].x, camps[i].y, px, py) <= r2 then
            S.campNear = true
            return
        end
    end
    S.campNear = false
end

function M.insideBaseCamp() return S.campNear end
function M.lastScanAt() return S.lastScan end
function M.version() return S.version end
function M.staticDirty() return S.staticDirty end

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

local STATIC_REBUILD_GAP = 0.75

function M.collect(cfg, px, py, zoom)
    local now = os.clock()
    if S.staticDirty and (S.staticRebuildAt == 0.0 or (now - S.staticRebuildAt) >= STATIC_REBUILD_GAP) then
        rebuildStatic(cfg, px, py, zoom)
    end

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
                if p.icon then
                    -- already a full path, resolved at scan time
                    tex = p.icon
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
    wipe(S.pals); wipe(S.players); wipe(S.npcs)
    wipe(S.static); wipe(S.camps)
    S.campNear = false
    S.lastScan = 0.0
    S.staticDirty = false
    S.staticRebuildAt = 0.0
    S.version = S.version + 1
    -- the per-kind caches hold world positions from the OLD level
    kindCache, kindSeen, rotation = {}, {}, 1
    -- Species icons that RESOLVED are kept - the asset still exists. The
    -- ones that did not are re-decided, so a species first met during a
    -- load screen gets another chance instead of being a "human" forever.
    -- This is free even on a teleport, where nothing has really changed:
    -- assets.lua still remembers which paths it gave up on, so a re-probe
    -- answers `false` again immediately without touching the disk. Only a
    -- genuine world change clears THAT, and main.lua does it there.
    notAPal = {}
    -- drop the actor references the pools would otherwise keep alive
    for i = 1, #nearScratch do nearScratch[i].actor = nil end
end

return M
