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
-- 2.1.7 ADDS A SECOND RULE, PAID FOR WITH A CRASH:
--
--   AN ACTOR REFERENCE MAY ONLY BE KEPT IF IT ARRIVED AS A FIRST-CLASS
--   UObject. Never store the result of unwrapping something.
--
-- 2.1.5 read PalUtility's monster list, found its elements were not usable
-- objects directly, opened each one with :get() and stored what came out
-- in S.pals - where it is dereferenced ten times a second for the next
-- four seconds. Palworld died with
--     EXCEPTION_ACCESS_VIOLATION reading address 0x0000000400000039
-- which is a garbage pointer, and no Lua guard can catch that: pcall only
-- sees Lua errors, and IsValid() on a recycled object slot can answer yes.
-- A wrapper handed back by UE4SS points into the memory of the call that
-- produced it; reading through it later is undefined, and "later" here was
-- every frame for four seconds.
--
-- So the wrapped case is no longer used at all. See utilityList().
--
-- COST: every FindAllOf is a full walk of the UObject array, and Palworld
-- keeps a lot of objects. 2.0.5 did fourteen of those walks every four
-- seconds, which is the frame-time spike people described as "stutter
-- every few seconds". The scan is now split:
--   * scanDynamic  - pals, players, NPCs. They move, so 4 s (configurable).
--   * stepStatic   - chests, dungeons, fast travel... They do not move, so
--                    one class comes round per scan interval, and each
--                    class is walked a BOUNDED number of actors per
--                    movement tick rather than all at once (see main.lua).
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
-- PalUtility - the game answers these questions itself
--
-- WHERE THIS CAME FROM: the 1.x blueprint's import table (the same source
-- as the class list at the top of this file). It never called
-- GetAllActorsOfClass for characters at all. It called
--
--   /Script/Pal.PalUtility::GetPalMonsters(WorldContext, out TArray)
--   /Script/Pal.PalUtility::GetHumanNPCs(WorldContext, out TArray)
--   /Script/Pal.PalUtility::GetAllPlayerCharacters(WorldContext, out TArray)
--
-- which is why 1.x scanned more cheaply than 2.x did. Three things follow
-- from using them, and all three are wins:
--
--   1. NO UObject-ARRAY WALK. `FindAllOf` walks every UObject in the
--      process; these return a list the game already maintains. That walk,
--      twice per scan tick, was the largest single cost in the mod.
--   2. PAL vs HUMAN IS NO LONGER A GUESS. 2.0.6 subtracted a class and
--      erased every pal; 2.0.8 stopped and drew humans as pals; 2.1.0
--      inferred it from whether a species icon asset existed. The game
--      simply says which is which. The species icon is now only used to
--      pick the picture, never to decide what something is.
--   3. IT IS WORLD-SCOPED. `FindAllOf("PalCharacter")` returns every
--      PalCharacter object in the process, including ones that are not
--      standing in the level - which is why party pals were showing up on
--      the minimap while sitting in the player's team.
--
-- Everything here is best-effort: if PalUtility is missing or its calls do
-- not come back in a shape we can read, the FindAllOf path below is used
-- exactly as before, and which one is in use is logged once.
-- ---------------------------------------------------------------
-- WHY THIS IS SO DEFENSIVE. The first attempt at this (2.1.2) collapsed
-- every possible failure into a silent nil, so the in-game log said only
-- "via FindAllOf" and there was no way to tell whether the CDO was
-- missing, the call had raised, or the return value was in a shape we
-- could not read. It is now probed ONCE, every step is reported, and the
-- working call shape is remembered. One line in UE4SS.log answers it.
--
-- The two things that genuinely vary between UE4SS builds:
--   * whether an `out` parameter has to be passed a placeholder slot, and
--   * what a returned TArray looks like on the Lua side (plain table,
--     userdata with GetArrayNum/GetArrayElement, or ForEach-only).
-- Both are tried rather than assumed.
local UTIL_PATHS = {
    "/Script/Pal.Default__PalUtility",
    "/Script/Pal.PalUtility",
}
local utilObj = nil
local utilState = 0     -- 0 untried, 1 usable, 2 unavailable
local utilShape = nil   -- which call form worked
local utilTries, utilProbes = 0, 0
local UTIL_MAX_TRIES = 3        -- outright failures before giving up
local UTIL_MAX_PROBES = 40      -- "works but empty" retries, ~2.5 min of scans
local utilEmpty, UTIL_MAX_EMPTY = 0, 3
local lastMonsterCount = 0

local monstersBuf, humansBuf, playersBuf = {}, {}, {}

-- The call shapes, in the order they are tried. WHAT THE GAME ACTUALLY
-- SAID (2.1.3's probe, in UE4SS.log):
--
--   GetPalMonsters(ctx)      -> UFunction expected 2 parameters, received 1
--   GetPalMonsters(ctx, out) -> returned nil
--   GetPalMonsters()         -> UFunction expected 2 parameters, received 0
--
-- So the arity is settled: UE4SS wants the `out` slot passed explicitly.
-- What it does NOT do is hand the filled array back as the first return
-- value, which is what 2.1.3 assumed. Two conventions remain, and both are
-- now read: the array can come back as a LATER return value (a void
-- function returns nil first, then its out params), or UE4SS can fill in
-- the very table that was passed. `outSlot` is shared and reused so the
-- caller can look at it afterwards either way.
local outSlot = {}

local function clearSlot()
    for i = #outSlot, 1, -1 do outSlot[i] = nil end
end

local function callCtxOut(util, name, ctx)
    clearSlot()
    return util[name](util, ctx, outSlot)
end
local function callCtx(util, name, ctx) return util[name](util, ctx) end
local function callBare(util, name) return util[name](util) end

local SHAPES = {
    { name = "(ctx, out)", fn = callCtxOut, slot = true },
    { name = "(ctx)",      fn = callCtx },
    { name = "()",         fn = callBare },
}

local function rawArrayNum(arr) return arr:GetArrayNum() end
local function rawArrayAt(arr, i) return arr:GetArrayElement(i) end
local function rawForEach(arr, fn) arr:ForEach(fn) end

-- Fill `out` from whatever shape UE4SS hands back for a TArray out
-- parameter. Returns the count, or nil if the value is not a list at all.
local forEachOut, forEachCount = nil, 0

local function forEachCollect(a, b)
    -- ForEach hands back (index, element) on most builds and (element) on
    -- some; take whichever argument is not a number.
    local elem = b
    if elem == nil or type(elem) == "number" then elem = a end
    if elem ~= nil and type(elem) ~= "number" then
        forEachCount = forEachCount + 1
        forEachOut[forEachCount] = elem
    end
end

-- `describe` is filled in with how the value was read, for the probe log.
-- `unwrapped` guards the one recursion below.
local function toArray(v, out, describe, unwrapped)
    if v == nil then
        if describe then describe[1] = "nil" end
        return nil
    end

    -- GetArrayNum FIRST, before the plain-table case. A UE4SS build that
    -- wraps the array in a Lua table with methods on it would otherwise be
    -- read with `#v` - which is 0, because the elements are behind
    -- GetArrayElement, not in the array part - and the whole list would
    -- silently come back empty.
    local n = guard.get(rawArrayNum, v)
    if type(n) == "number" and n >= 0 then
        local count = 0
        -- GetArrayElement is 1-based on some builds and 0-based on others;
        -- reading both ends and dropping nils covers either without
        -- needing to know which.
        for i = 0, n do
            local e = guard.get(rawArrayAt, v, i)
            if e ~= nil then count = count + 1; out[count] = e end
        end
        for i = #out, count + 1, -1 do out[i] = nil end
        if describe then describe[1] = "TArray:GetArrayNum=" .. n end
        if count > 0 then return count end
        -- an array that reports a size but yields nothing is not usable
        if n == 0 then return 0 end
    end

    if type(v) == "table" then
        local len = #v
        for i = 1, len do out[i] = v[i] end
        for i = #out, len + 1, -1 do out[i] = nil end
        if describe then describe[1] = "lua table" end
        return len
    end

    forEachOut, forEachCount = out, 0
    guard.get(rawForEach, v, forEachCollect)
    local got = forEachCount
    forEachOut = nil
    if got > 0 then
        for i = #out, got + 1, -1 do out[i] = nil end
        if describe then describe[1] = "TArray:ForEach" end
        return got
    end

    -- UE4SS hands some out parameters back wrapped in a RemoteUnrealParam,
    -- which is read with :get(). Same trick asBool() needs for reflected
    -- booleans. One level only.
    if not unwrapped then
        local inner = guard.get(rawUnwrap, v)
        if inner ~= nil and inner ~= v then
            local n2 = toArray(inner, out, describe, true)
            if n2 ~= nil then
                if describe then describe[1] = ":get() -> " .. tostring(describe[1]) end
                return n2
            end
        end
    end

    if describe then describe[1] = type(v) .. " (unreadable)" end
    return nil
end

local function findUtility()
    for i = 1, #UTIL_PATHS do
        local o = guard.get(StaticFindObject, UTIL_PATHS[i])
        -- NOTE: no guard.alive() here. IsValid() is an actor-ish notion and
        -- a class default object is not required to answer it; requiring it
        -- would throw away a perfectly good CDO.
        if o ~= nil then return o, UTIL_PATHS[i] end
    end
    -- Last resort, and independent of how the path string has to be
    -- spelled on this build: FindFirstOf matches by class name and returns
    -- the class default object for a class that has no instances - which
    -- is exactly what a function library is. (The same CDO-first behaviour
    -- that had to be worked around when hunting the Esc menu widget is the
    -- useful case here.)
    local o = guard.get(FindFirstOf, "PalUtility")
    if o ~= nil then return o, "FindFirstOf('PalUtility')" end
    return nil, nil
end

-- Run once. Works out whether PalUtility can be used at all and, if so,
-- which call shape and which array shape to use, and says so in the log.
-- Make ONE call and find the list wherever this build chose to put it:
-- any of the return values, or the out table we handed in. Returns the
-- count and, for the probe's benefit, where it was found; on a raised
-- call it returns nil plus the error text.
local function callAndRead(shape, util, name, ctx, out, describe)
    local ok, a, b, c = pcall(shape.fn, util, name, ctx)
    if not ok then return nil, tostring(a) end

    local n = toArray(a, out, describe)
    if n ~= nil then return n, "1st return" end
    n = toArray(b, out, describe)
    if n ~= nil then return n, "2nd return" end
    n = toArray(c, out, describe)
    if n ~= nil then return n, "3rd return" end
    if shape.slot then
        n = toArray(outSlot, out, describe)
        if n ~= nil then return n, "the out table" end
    end
    return nil, nil
end

-- THE ELEMENTS MUST BE FIRST-CLASS OBJECTS, or this whole path is refused.
--
-- 2.1.5 saw that the elements were not usable directly, opened each with
-- :get() and stored the results. That is what killed the game - see the
-- crash-safety note at the top of this file. A wrapper points into the
-- memory of the call that produced it, S.pals keeps its contents for four
-- seconds, and the draw path reads through them ten times a second.
--
-- Reading such a wrapper immediately, inside the same call, would be
-- defensible. Storing what comes out of it is not, and the actors are
-- needed for exactly that: their position, every frame. So there is no
-- clever middle course here. If the elements do not arrive usable, the
-- object-array scan is used instead - slower, and it has never crashed.
local elementsBad = false

local function elementsUsable(out, n)
    if n == nil or n == 0 then return true end
    if guard.alive(out[1]) then return true end
    if not elementsBad then
        elementsBad = true
        -- say plainly what was rejected and why, so this is never quietly
        -- "fixed" by unwrapping again
        local inner = guard.get(rawUnwrap, out[1])
        local wrapped = inner ~= nil and guard.alive(inner)
        guard.log("PalUtility: its list elements are "
            .. (wrapped and "WRAPPED values, not objects that may be kept"
                        or "not usable objects")
            .. " - refusing to store them (2.1.5 did, and the game died with an access "
            .. "violation four seconds later). Using the object-array scan instead.")
    end
    return false
end

-- Returns "ok" once a call shape has been proven, "empty" when a shape
-- worked but the level currently has no monsters in it, or false when
-- nothing worked.
--
-- AN EMPTY LIST IS NOT PROOF. A wrong call shape and an empty world look
-- exactly alike from here, and committing on an empty result is how the
-- first cut of this ended up drawing no pals at all. So a shape is only
-- adopted once it has actually produced something, and "empty" costs a
-- cheap retry on the next scan rather than a decision.
--
-- `verbose` is true only for the first attempt: enough to diagnose, without
-- writing the same three lines to UE4SS.log once per retry.
local function probeUtility(ctx, verbose)
    local obj, path = findUtility()
    if obj == nil then
        if verbose then
            guard.log("PalUtility: no object at " .. table.concat(UTIL_PATHS, " or "))
        end
        return false
    end

    local describe, sawEmpty = {}, false
    for i = 1, #SHAPES do
        local shape = SHAPES[i]
        describe[1] = nil
        local n, where = callAndRead(shape, obj, "GetPalMonsters", ctx, monstersBuf, describe)
        if n == nil then
            if verbose then
                guard.log(string.format("PalUtility: %s, GetPalMonsters%s %s",
                    path, shape.name,
                    where ~= nil and ("raised: " .. where)
                        or ("gave nothing readable (" .. tostring(describe[1]) .. ")")))
            end
        elseif n > 0 and not elementsUsable(monstersBuf, n) then
            -- The call works; what it hands back is not something we may
            -- keep, so the LISTS are refused. IsDead is kept: it takes an
            -- actor we already own and returns a boolean, so nothing
            -- crosses back that has to outlive the call.
            utilObj = obj
            return false
        elseif n > 0 then
            utilObj, utilShape = obj, shape
            guard.log(string.format(
                "PalUtility: using %s, GetPalMonsters%s -> %s in %s, %d monsters. "
                .. "The game's own lists replace the object-array scan.",
                path, shape.name, tostring(describe[1]), where, n))
            return "ok"
        else
            sawEmpty = true
            if verbose then
                guard.log(string.format(
                    "PalUtility: %s, GetPalMonsters%s -> %s in %s but EMPTY; retrying, because "
                    .. "an empty level and a wrong call shape look the same from here",
                    path, shape.name, tostring(describe[1]), where))
            end
        end
    end
    if sawEmpty then return "empty" end
    return false
end

-- The object itself, for the calls that hand nothing back that has to
-- outlive them (IsDead). Available even when the LIST calls were refused -
-- utilityList gates on utilShape, not on this.
local function utility()
    return utilObj
end

-- Returns the filled buffer and a count, or nil to mean "use FindAllOf".
local function utilityList(name, ctx, out)
    if utilObj == nil or utilShape == nil then return nil end
    local n = callAndRead(utilShape, utilObj, name, ctx, out, nil)
    if not elementsUsable(out, n) then return nil end
    return n
end

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
local baseTribe = {}            -- tribe -> species without its variant suffix,
                                -- or false when it has none
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
local function iconPathFor(tribe)
    local path = pathForTribe[tribe]
    if path == nil then
        path = string.format(PAL_ICON_FMT, tribe, tribe)
        pathForTribe[tribe] = path
    end
    return path
end

local function speciesIcon(tribe)
    if tribe == nil or tribe == "" then return false end
    local hit = iconForTribe[tribe]
    if hit ~= nil then return hit end
    if notAPal[tribe] then return false end

    local exists = assets.probe(iconPathFor(tribe))
    if exists == nil then return nil end        -- still queued
    if exists then
        iconForTribe[tribe] = pathForTribe[tribe]
        iconFormatWorks = true
        return pathForTribe[tribe]
    end

    -- THE EXACT TRIBE HAS NO ICON. That is not the same as "not a pal".
    --
    -- Alpha/boss pals are named BP_<Species>_BOSS_C_<id>, and they reuse
    -- the BASE species portrait - there is no T_FoxMage_BOSS_icon_normal.
    -- 2.1.2 therefore classified every alpha in the world as a human NPC:
    -- the in-game log said, in as many words,
    --   no species icon for: FoxMage_BOSS, VioletFairy_BOSS, Ronin_Boss,
    --   Serpent_BOSS - drawn as NPC humans, not as pals
    -- which is a second, quieter half of "not all pals show on the map".
    --
    -- The full name is still tried FIRST, because some variants genuinely
    -- do have their own row (FlameBuffalo_Ice), and only then is the base
    -- species tried.
    --
    -- ONLY for a _BOSS suffix, though, and deliberately not for any
    -- trailing segment. Dropping the last segment of anything would send
    -- every human tribe on a second wild-goose chase as well
    -- (NPC_Villager -> NPC, NPC_Merchant -> NPC), and each of those costs
    -- three more failed synchronous loads for an asset that was never
    -- going to exist. If some other suffix turns out to reuse the base
    -- portrait, the "no species icon for:" line in the log names it.
    local base = baseTribe[tribe]
    if base == nil then
        base = tribe:match("^(.+)_[Bb][Oo][Ss][Ss]$") or false
        baseTribe[tribe] = base
    end
    if base then
        local baseExists = assets.probe(iconPathFor(base))
        if baseExists == nil then return nil end
        if baseExists then
            iconForTribe[tribe] = pathForTribe[base]
            iconFormatWorks = true
            return pathForTribe[base]
        end
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

-- ---------------------------------------------------------------
-- "Is this pal actually standing in the world?"
--
-- THE BUG THIS EXISTS FOR: pals sitting in the player's TEAM were being
-- drawn on the minimap even though they were not out in the world. A pal
-- in a sphere still has an actor - the game keeps it around rather than
-- destroying and respawning it every time you throw one - it is simply
-- hidden and not participating in the level.
--
-- Two guarded reads, in cost order, and NEITHER may filter on a build that
-- does not expose it: an unreadable property means "no opinion", never
-- "hide it". Getting that backwards is how 2.0.6 emptied the minimap.
--   * bHidden      - the engine's own "this actor is not being rendered".
--   * PalUtility::IsDead - what 1.x used; a caught or knocked-out pal
--     lingers for a moment before the game removes it, and 1.x had a
--     whole setting ("delay remove dead/caught pals") about that window.
-- ---------------------------------------------------------------
local function rawHidden(actor) return actor.bHidden end
local function rawIsDead(util, actor) return util:IsDead(actor) end

local hiddenReadable, deadReadable = nil, nil

local function inWorld(actor)
    if hiddenReadable ~= false then
        local ok, v = pcall(rawHidden, actor)
        if ok then
            hiddenReadable = true
            if asBool(v) == true then return false end
        elseif hiddenReadable == nil then
            hiddenReadable = false
        end
    end

    -- No latching when PalUtility is simply not in use: that is not the
    -- property being unreadable, and bHidden alone still does its job.
    if deadReadable ~= false then
        local util = utility()
        if util ~= nil then
            local ok, v = pcall(rawIsDead, util, actor)
            if ok then
                deadReadable = true
                if asBool(v) == true then return false end
            elseif deadReadable == nil then
                deadReadable = false
            end
        end
    end

    return true
end

-- Collect the in-range subset of `list` into the nearScratch table, in
-- distance order. Shared by the pal pass and the human pass so both get
-- the same nearest-first budgeting.
-- Where the candidates went, so "0 pals drawn" can say WHY. 2.1.4 reported
-- 54 monsters and nothing drawn, with no way to tell whether the actors
-- were unreadable, unnamed, or simply far away.
local nearStats = { noLoc = 0, noName = 0, excluded = 0, farAway = 0 }

local function gatherNear(list, count, px, py, maxD2, excluded, needName)
    local st = nearStats
    st.noLoc, st.noName, st.excluded, st.farAway = 0, 0, 0, 0
    local near, n = nearScratch, 0
    for i = 1, count do
        local a = list[i]
        -- Distance FIRST. The name is only needed for the exclusion set
        -- and the species lookup, and reading it for every actor in the
        -- level - most of them kilometres away - doubled the reflection
        -- cost of the scan.
        local x, y = actorLocation(a)
        if x == nil then
            st.noLoc = st.noLoc + 1
        else
            local d = dist2(x, y, px, py)
            if d > maxD2 then
                st.farAway = st.farAway + 1
            else
                local name, keep = nil, true
                if needName then
                    name = actorName(a)
                    if name == nil then
                        keep = false
                        st.noName = st.noName + 1
                    elseif excluded ~= nil and excluded[name] then
                        keep = false
                        st.excluded = st.excluded + 1
                    end
                end
                if keep then
                    n = n + 1
                    local slot = near[n]
                    if slot == nil then slot = {}; near[n] = slot end
                    slot.actor, slot.name, slot.d = a, name, d
                end
            end
        end
    end
    for i = #near, n + 1, -1 do near[i] = nil end
    table.sort(near, byDistance)
    return near, n
end

local function addPal(cfg, actor, tribe, playerPawn)
    if #S.pals >= cfg.maxPalIcons then return end
    local shiny = isShiny(actor)
    if cfg.onlyShinyPals and not shiny then return end
    local icon = speciesIcon(tribe)
    S.pals[#S.pals + 1] = {
        actor = actor,
        -- resolved ONCE, at scan time. collect() used to string.format
        -- this path for every pal on every frame - 480 throwaway strings
        -- a second at the default settings.
        icon = (type(icon) == "string") and icon or nil,
        shiny = shiny, friend = isFriend(actor, playerPawn),
    }
end

-- The PalUtility path: the game hands us three separate, already-correct
-- lists, so there is nothing to classify and no object array to walk.
local function scanViaUtility(cfg, px, py, maxD2, playerPawn, ctx)
    local nMon = utilityList("GetPalMonsters", ctx, monstersBuf)
    lastMonsterCount = nMon or 0
    if nMon == nil then return false end

    local nHum = utilityList("GetHumanNPCs", ctx, humansBuf) or 0
    local nPly = utilityList("GetAllPlayerCharacters", ctx, playersBuf) or 0

    local selfName = playerPawn ~= nil and actorName(playerPawn) or nil
    local excluded = nil
    if selfName ~= nil then excluded = { [selfName] = true } end

    for i = 1, nPly do
        local a = playersBuf[i]
        local n = actorName(a)
        if n ~= nil then
            excluded = excluded or {}
            excluded[n] = true
            if cfg.showPlayers and n ~= selfName then
                S.players[#S.players + 1] = a
            end
        end
    end

    local skipped, inRange = 0, 0
    local noLoc, noName, farAway = 0, 0, 0
    if cfg.showPals then
        local near, n = gatherNear(monstersBuf, nMon, px, py, maxD2, excluded, true)
        inRange = n
        noLoc, noName, farAway = nearStats.noLoc, nearStats.noName, nearStats.farAway
        for i = 1, n do
            local e = near[i]
            if inWorld(e.actor) then
                addPal(cfg, e.actor, tribeOf(e.name), playerPawn)
            else
                skipped = skipped + 1
            end
        end
        for i = 1, n do near[i].actor = nil end
    end

    if cfg.showNPCs then
        local near, n = gatherNear(humansBuf, nHum, px, py, maxD2, excluded, false)
        local limit = cfg.maxPalIcons
        for i = 1, n do
            if i > limit then break end
            S.npcs[#S.npcs + 1] = near[i].actor
        end
        for i = 1, n do near[i].actor = nil end
    end

    for i = 1, nMon do monstersBuf[i] = nil end
    for i = 1, nHum do humansBuf[i] = nil end
    for i = 1, nPly do playersBuf[i] = nil end

    -- The FULL funnel, not just the ends. 2.1.4 logged "54 pal monsters ->
    -- 0 pals drawn" and there was no way to tell which step ate them.
    if not reportedScan or (cfg.showPals and #S.pals == 0 and nMon > 0) then
        reportedScan = true
        guard.log(string.format(
            "character scan via PalUtility: %d monsters, %d humans, %d players | "
            .. "of the monsters: %d unreadable, %d unnamed, %d out of range, %d in range "
            .. "-> %d drawn, %d not present in the world",
            nMon, nHum, nPly, noLoc, noName, farAway, inRange, #S.pals, skipped))
    end
    return true
end

-- The fallback: one UObject-array walk for characters, one for players,
-- and the species-icon test to tell them apart. This is 2.1.0's path,
-- kept verbatim for builds where PalUtility is not reachable.
local function scanViaFindAll(cfg, px, py, maxD2, playerPawn)
    local rawPals = findAll("PalCharacter", "characters")
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

    if not rejectedClass["PalPlayerCharacter"] then
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
    local near, n = gatherNear(rawPals, palCount, px, py, maxD2, excluded, true)

    -- Nearest first, so the icon budget always goes to what is closest.
    local nPals, nHumans = 0, 0
    for i = 1, n do
        local e = near[i]
        local tribe = tribeOf(e.name)
        local icon = speciesIcon(tribe)
        -- nil  = not probed yet
        -- false + format unproven = we have no basis to filter anything
        local isPal = (icon ~= false) or (not iconFormatWorks)
        if isPal then
            nPals = nPals + 1
            if cfg.showPals and inWorld(e.actor) then
                addPal(cfg, e.actor, tribe, playerPawn)
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
            "character scan via the engine object array: %d PalCharacters, %d players "
            .. "excluded, %d in range -> %d pals, %d humans",
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

function M.scanDynamic(cfg, px, py, zoom, playerPawn)
    local maxD2 = keepRadius2(zoom)

    wipe(S.pals); wipe(S.players); wipe(S.npcs)

    if cfg.showPals or cfg.showNPCs or cfg.showPlayers then
        -- Probed once, at the first scan that has a world context. The CDO
        -- of a native class exists from process start, so there is nothing
        -- to wait for beyond that; a couple of retries only cover a probe
        -- unlucky enough to land mid-load.
        if utilState == 0 and playerPawn ~= nil then
            utilProbes = utilProbes + 1
            local r = probeUtility(playerPawn, utilProbes == 1)
            if r == "ok" then
                utilState = 1
            elseif r == "empty" then
                -- the call works, there is just nothing to see yet; keep
                -- probing (it is one call) rather than deciding
                if utilProbes >= UTIL_MAX_PROBES then
                    utilState = 2
                    guard.log("PalUtility answered, but never returned a single pal monster "
                        .. "over " .. UTIL_MAX_PROBES .. " scans - scanning the object array instead.")
                end
            elseif elementsBad then
                -- not a "maybe next time" failure: it has already said what
                -- it hands back, and that will not change
                utilState = 2
            else
                utilTries = utilTries + 1
                if utilTries >= UTIL_MAX_TRIES then
                    utilState = 2
                    guard.log("PalUtility could not be used on this build - scanning the "
                        .. "object array instead, and telling pals from humans by their "
                        .. "species icon. See the lines above for which step failed.")
                end
            end
        end

        local ok = false
        if utilState == 1 then
            ok = scanViaUtility(cfg, px, py, maxD2, playerPawn, playerPawn) == true
            -- SELF-CHECKING. A faster scan that draws nothing is worse than
            -- a slow one that works, and 2.1.4 shipped exactly that: the
            -- game returned 54 monsters and the minimap stayed empty. So
            -- when the utility path comes back with no pals at all while
            -- the game said there ARE monsters, run the old path too and
            -- compare. If the old path finds pals, the new one is wrong
            -- about something and loses its turn.
            if ok and cfg.showPals and #S.pals == 0 and lastMonsterCount > 0 then
                wipe(S.pals); wipe(S.players); wipe(S.npcs)
                scanViaFindAll(cfg, px, py, maxD2, playerPawn)
                if #S.pals > 0 then
                    ok = true       -- already scanned, do not scan twice
                    utilEmpty = utilEmpty + 1
                    if utilEmpty >= UTIL_MAX_EMPTY then
                        utilState = 2
                        guard.log(string.format(
                            "PalUtility returned monsters but produced no pals %d scans "
                            .. "running, while the object-array scan found some - dropping "
                            .. "it and using the object-array scan from now on.", utilEmpty))
                    end
                end
            else
                utilEmpty = 0
            end
        end
        if not ok then
            scanViaFindAll(cfg, px, py, maxD2, playerPawn)
        end
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
-- Only ONE class is looked at per turn, and the expensive rebuild is
-- deferred until the draw path actually needs fresh static markers.
--
-- 2.1.2 GOES FURTHER, because one class per turn was still not enough.
-- The reported symptom was micro-stutters WHILE WALKING, as new places and
-- items appeared - and that is the shape of this loop: the `FindAllOf` is
-- one cost, but reading a location (and, for collectibles, the "already
-- picked up" flag) off EVERY actor of that class is a reflection call per
-- actor, and the lists grow as the player walks into denser country and
-- the level streams more in. A hundred and twenty chests is a few hundred
-- reflection calls in one pump, every time that kind comes round.
--
-- So the per-kind pass is now RESUMABLE: `stepStatic` does at most
-- ACTORS_PER_STEP actors and returns, and it is driven from the movement
-- tick (10 Hz) rather than the scan tick. A kind of any size is therefore
-- spread over as many 100 ms ticks as it needs, no single pump does more
-- than a bounded amount of reflection, and a big class costs a few extra
-- tenths of a second to finish instead of one visible hitch.
--
-- The cursor holds actor references between ticks, which the rest of this
-- file is careful never to do. It is safe HERE for the same reason the
-- in-scan loop was: `actorLocation` validates before it reads, so an actor
-- destroyed between two steps is skipped rather than dereferenced. The
-- exposure is a few hundred milliseconds, and `M.forget` drops the cursor
-- outright on a teleport or a world change.
--
-- This is only sound because these things do not move: a cache scanned
-- thirty seconds ago is still exactly right, apart from items that have
-- been picked up since - and those go away on that kind's next turn.
-- ---------------------------------------------------------------
local kindCache = {}      -- kind -> { x, y, ... }  positions only
local kindSeen = {}       -- kind -> true once scanned at least once
local rotation = 1

local ACTORS_PER_STEP = 48

-- In-progress pass over one class, or nil between kinds.
--
-- THIS HOLDS ACTOR REFERENCES BETWEEN TICKS, which the rest of this file
-- is careful never to do, so it is deliberately kept short-lived: 48 per
-- step at 10 Hz clears a 480-actor class in one second, and a pass that
-- somehow has not finished within CURSOR_MAX_AGE is abandoned rather than
-- carried any further. `actorLocation` validates before it reads, so an
-- actor destroyed mid-pass is skipped - but validation is not proof (a
-- recycled object slot can answer yes), and the crash that cost 2.1.5
-- came from exactly that family of mistake. Keep the window small.
local CURSOR_MAX_AGE = 3.0
local cursor = nil        -- { spec, all, total, index, list, count, startedAt }

local function wantedKind(cfg, spec)
    if cfg[spec.cfg] == true then return true end
    if spec.kind == "camp" and cfg.autohideInBase then return true end
    return false
end

local function beginKind(spec)
    local all = findAll(spec.class, spec.kind)
    cursor = {
        spec = spec, all = all, total = #all, index = 0,
        list = {}, count = 0,       -- built aside, swapped in when complete
        startedAt = os.clock(),
    }
end

-- Advance the current pass by at most ACTORS_PER_STEP actors. Returns true
-- when the kind is finished and its cache has been replaced.
local function stepKind(cfg)
    local c = cursor
    -- stale pass: the references in it are older than we are willing to
    -- dereference. Drop it; the kind comes round again on its own.
    if (os.clock() - c.startedAt) > CURSOR_MAX_AGE then
        cursor = nil
        return false
    end
    local spec = c.spec
    local list, count = c.list, c.count
    local all = c.all
    local i, stop = c.index, c.index + ACTORS_PER_STEP
    if stop > c.total then stop = c.total end

    while i < stop do
        i = i + 1
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

    c.index, c.count = i, count
    if i < c.total then return false end

    for j = #list, count + 1, -1 do list[j] = nil end
    kindCache[spec.kind] = list
    kindSeen[spec.kind] = true
    cursor = nil
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

-- Called from the MOVEMENT tick, ten times a second, and bounded. Most
-- calls do nothing at all: it only picks up a new kind when one is due,
-- and otherwise advances whichever pass is already running by one step.
--
-- `due` is the scan tick's signal that a full round is wanted (it fires at
-- scanIntervalMs). Between rounds this returns immediately.
function M.stepStatic(cfg, due)
    if cursor ~= nil then
        if stepKind(cfg) then
            S.staticDirty = true
            S.version = S.version + 1
        end
        return
    end
    if not due then return end

    -- Nothing running: retire any kind the user has turned off, then take
    -- the next wanted one. Turning a kind off is pure table work, so all of
    -- them can be retired in one go.
    local changed = false
    local checked = 0
    while checked < #STATIC_KINDS do
        local spec = STATIC_KINDS[rotation]
        rotation = (rotation % #STATIC_KINDS) + 1
        checked = checked + 1
        if wantedKind(cfg, spec) then
            beginKind(spec)
            break
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

-- True while the map is still filling in after a load: main.lua uses it to
-- ask for rounds more often until every wanted kind has been seen once, so
-- the minimap populates quickly instead of one class every four seconds.
function M.staticFilling(cfg)
    for _, spec in ipairs(STATIC_KINDS) do
        if wantedKind(cfg, spec) and not kindSeen[spec.kind] then return true end
    end
    return false
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

-- test hook: what is actually being kept between ticks, so a harness can
-- assert that nothing unwrappable ever lands in here
function M.debugPalActors()
    local out = {}
    for i = 1, #S.pals do out[i] = S.pals[i].actor end
    return out
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
    -- the per-kind caches hold world positions from the OLD level, and the
    -- in-progress pass holds actor references from it
    kindCache, kindSeen, rotation = {}, {}, 1
    cursor = nil
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
