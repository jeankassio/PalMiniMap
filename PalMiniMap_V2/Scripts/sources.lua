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

-- Item icons live under Pal/Content/Others/, a different branch from
-- everything else the mod reads, on the same /Game/ mount point. Used where
-- the game has no compass glyph: eggs, the Lifmunk effigy, skillfruit.
local ITEM_ICON_IN = "/Game/Others/InventoryItemIcon/Texture/"

local function itemIcon(name) return ITEM_ICON_IN .. name .. "." .. name end


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
    -- 2.2.18. The compass sheet has seventeen icons with no descriptive name
    -- at all (T_icon_compass_00..16), which is why a search by name never
    -- turned them up: 03 is a pickaxe, 09 an apple, 13 a lotus, 15 a fishing
    -- rod. Those are the pictures for the resource markers below.
    ore     = ui("T_icon_compass_03"),
    lotus   = ui("T_icon_compass_13"),
    forage  = ui("T_icon_compass_09"),
    junk    = ui("T_icon_compass_Search_Junk"),
    fishing = ui("T_icon_compass_15"),
    dig     = ui("T_icon_compass_TreasureMap_01"),
    -- egg: set below, once the per-element table exists. It is the only
    -- kind whose members do not all share one picture.
    -- Effigy and skillfruit: the game has no compass glyph for either, so
    -- these are its own ITEM icons - the green Lifmunk statue and a skill
    -- fruit. Coloured art rather than a white glyph on purpose: measured at
    -- 18 px over grass, snow and desert, the game's white compass glyphs
    -- have a weak outline and VANISH on snow.
    effigy  = itemIcon("T_itemicon_Relic"),
    fruit   = itemIcon("T_itemicon_Consume_SkillCard_Neutral"),
    -- Notes are the one marker with no game art at all. Searched: every
    -- T_icon_compass_* (including the seventeen numbered ones, which have no
    -- descriptive name and so escape a search by name), T_icon_Compass_Quest_*,
    -- T_icon_ItemCategory_*, and the item icons for note/memo/paper/book/
    -- journal/map/scroll/blueprint. The two nearest, the technology book and
    -- the treasure map, are different items AND unreadable at 18 px. So this
    -- one is drawn by tools/make_note_icon.py and shipped, like the circular
    -- frame - the only marker in the mod that is not the game's own art.
    note    = "/PalMiniMap/T_minimap_note.T_minimap_note",
}

local WHITE = { R = 1.00, G = 1.00, B = 1.00, A = 1.0 }
local TINT = {
    friend  = { R = 0.65, G = 1.00, B = 0.75, A = 1.0 },
    shiny   = { R = 1.00, G = 0.88, B = 0.30, A = 1.0 },
    player  = { R = 0.45, G = 0.78, B = 1.00, A = 1.0 },
    npc     = { R = 0.95, G = 0.85, B = 0.65, A = 1.0 },
    -- NO ENTRY for egg, note, effigy or fruit, deliberately. All four used to
    -- share one generic checkmark and were told apart ONLY by these tints;
    -- now each draws art that means what it is, and tinting coloured art
    -- would flatten it straight back into the beige blobs it came from.
}

-- ---------------------------------------------------------------
-- Egg icons, one per element.
--
-- Every egg used to draw `T_icon_compass_ClearCheck` - the same generic
-- checkmark as notes, effigies and skillfruit, differing only by tint. The
-- reason there was no better choice at hand: THE GAME HAS NO COMPASS ICON
-- FOR AN EGG AT ALL, because its own compass never marks eggs. So these are
-- the INVENTORY icons, which is where the game does show an egg to the
-- player, and they come one per element.
--
-- The element is in the actor's CLASS name. The wild-egg blueprints are
--     BP_MapObject_PickupItem_PalEgg[_<Element>]_C
-- and `_Base` (the one that actually derives from the native
-- PalMapObjectPalEgg the scan looks for) is the parent of the eleven
-- variants, so FindAllOf returns all of them.
--
-- Mapped explicitly rather than by appending "_01" to the element: three of
-- the twelve break that rule (the plain egg, MutationPal and Unknown have
-- no suffix), and a generated path that is wrong lands on the silent
-- LoadAsset fallback rather than an error.
local EGG_ICON = {
    [""]            = itemIcon("T_itemicon_Material_PalEgg"),
    Base            = itemIcon("T_itemicon_Material_PalEgg"),
    Dark            = itemIcon("T_itemicon_Material_PalEgg_Dark_01"),
    Dragon          = itemIcon("T_itemicon_Material_PalEgg_Dragon_01"),
    Earth           = itemIcon("T_itemicon_Material_PalEgg_Earth_01"),
    Electricity     = itemIcon("T_itemicon_Material_PalEgg_Electricity_01"),
    Fire            = itemIcon("T_itemicon_Material_PalEgg_Fire_01"),
    Ice             = itemIcon("T_itemicon_Material_PalEgg_Ice_01"),
    Leaf            = itemIcon("T_itemicon_Material_PalEgg_Leaf_01"),
    MutationPal     = itemIcon("T_itemicon_Material_PalEgg_MutationPal"),
    Water           = itemIcon("T_itemicon_Material_PalEgg_Water_01"),
    WorldTree       = itemIcon("T_itemicon_Material_PalEgg_WorldTree_01"),
}

-- The grey egg with a question mark: the game's own "unidentified egg". The
-- right answer for a class we do not recognise, and it still reads as an egg.
local EGG_UNKNOWN = itemIcon("T_itemicon_Material_PalEgg_Unknown")

-- The kind-wide fallback, used only if the per-actor lookup somehow returns
-- nothing. Before 2.2.16 this was T_icon_compass_ClearCheck, shared with
-- notes/effigies/fruit.
ICON.egg = EGG_UNKNOWN

local function rawClassName(actor) return actor:GetClass():GetFName():ToString() end

local function classNameOf(actor)
    local ok, cls = pcall(rawClassName, actor)
    if ok and type(cls) == "string" and cls ~= "" then return cls end
    return nil
end

-- ---------------------------------------------------------------
-- "IS THIS ACTOR A PLAYER?" - LEARNED FROM THE GAME, NOT ASSUMED (2.3.3)
--
-- THE BUG THIS EXISTS FOR, reported on a multiplayer server against
-- 2.1.2: with "show NPC humans" on and "show other players" OFF, the
-- reporter's friends appeared wearing the human-NPC icon - and only some
-- of them.
--
-- How a player ends up drawn as an NPC: the pal-vs-human test is "does
-- this tribe have a species icon" (2.1.0), and a player's actor name
-- gives a tribe like `PlayerBase` or `Player_Female`, which of course has
-- no `T_<tribe>_icon_normal`. So a player that is not in the `excluded`
-- set is classified HUMAN and drawn as one. Everything therefore rested
-- on that set, which is built by NAME from a separate FindAllOf - and it
-- silently produces no exclusions at all if the name read fails, if the
-- player list comes back empty, or if `usableForExclusion` decides the
-- class looks like a superclass of pals. Any of those and every nearby
-- player becomes an NPC icon. ("Only some" is the `maxNpcIcons` budget
-- downstream: it is filled nearest-first, so the closest friends got the
-- icons and the rest were dropped.)
--
-- A SECOND, INDEPENDENT TEST, on a different property, fixes that: the
-- actor's CLASS. Class is a fact about the actor rather than a hierarchy
-- inference, which is the same reasoning that made the species-icon test
-- the pal/human classifier in the first place.
--
-- The class names are LEARNED rather than hard-coded, because they are
-- blueprints (`BP_PlayerBase_C`, `BP_Player_Female_C`, ...) and live in
-- the pak, not the exe - exactly the kind of naming convention this mod
-- has been bitten by before. Two sources feed the set, and the first one
-- cannot fail: the LOCAL PLAYER'S OWN PAWN is a player character, and we
-- always have it. Every actor the game hands back in a player list is
-- added too, so both genders accumulate on their own.
-- ---------------------------------------------------------------
local playerClasses = {}        -- class name -> true, learned in-session

-- The learned set alone is not quite enough: it only ever contains classes
-- we have SEEN, and if the player list is the thing that failed, the only
-- one seen is the local player's. A second player of the other gender is a
-- different blueprint and would still slip through.
--
-- CHECKED AGAINST THE PAK, not assumed: the only two player pawns in
-- `Pal/Content/Pal/Blueprint/Character/` are `BP_PlayerBase` and
-- `BP_Player_Female`, and no Monster or NPC character blueprint has
-- "Player" in its name at all. (`BP_NPCWeaponGenerator_PlayerGatling` does,
-- but it is a weapon generator - it is not a PalCharacter, so it never
-- reaches this test.) A false positive here costs one missing marker; a
-- false negative is the bug being fixed, so the bias is deliberate.
local PLAYER_CLASS_PATTERNS = { "^BP_Player", "PlayerCharacter" }

local function looksLikePlayerClass(cls)
    for i = 1, #PLAYER_CLASS_PATTERNS do
        if string.find(cls, PLAYER_CLASS_PATTERNS[i]) then return true end
    end
    return false
end

local function notePlayerClass(actor)
    if actor == nil then return nil end
    local cls = classNameOf(actor)
    if cls ~= nil then playerClasses[cls] = true end
    return cls
end

local function isPlayerActor(actor)
    local cls = classNameOf(actor)
    if cls == nil then return false end
    if playerClasses[cls] then return true end
    if looksLikePlayerClass(cls) then
        -- learn it, so the next actor of this class costs one table hit
        playerClasses[cls] = true
        return true
    end
    return false
end
M.isPlayerActor = isPlayerActor

local eggIconFor = {}     -- class name -> texture path, resolved once

local function eggIcon(actor)
    local ok, cls = pcall(rawClassName, actor)
    if not ok or type(cls) ~= "string" then return EGG_UNKNOWN end
    local known = eggIconFor[cls]
    if known ~= nil then return known end

    -- "" for the plain egg, "_Fire" for a fire one, nil if this is some
    -- other class that happens to derive from PalMapObjectPalEgg.
    local body = cls:match("^BP_MapObject_PickupItem_PalEgg(.*)_C$")
    local element = body and (body:match("^_(.+)$") or "") or nil
    local path = element and EGG_ICON[element] or nil
    path = path or EGG_UNKNOWN
    eggIconFor[cls] = path
    return path
end
-- ---------------------------------------------------------------
-- Resource nodes (2.2.18)
--
-- Ore, stat-fruit lotuses, forageables and junk piles are ALL
-- `PalMapObjectSpawnerSimple` subclasses, so one FindAllOf covers the lot
-- and the class name says which is which - the same trick as the eggs:
--
--     BP_PalMapObjectSpawner_RockIron        -> ore
--     BP_PalMapObjectSpawner_Lotus_HP_01_..  -> stat fruit
--     BP_PalMapObjectSpawner_RedBerry        -> forageable
--     BP_PalMapObjectSpawner_Junk_Grass1     -> junk
--
-- ONE kind, four pictures, one toggle. Splitting it into four kinds would
-- mean four full object-array walks for one list the game already keeps
-- together.
--
-- WHAT IS DELIBERATELY NOT MARKED, and why: plain stone, wood, logs and
-- bones. There are thousands of them within minimap range in normal
-- country, and `maxPoiIcons` is shared by distance across every kind - so
-- marking them would push chests, dungeons and fast travel points off the
-- map with rubble. Ore, lotuses and junk are the ones players go looking
-- for. `showResources` also defaults to OFF for the same reason.
local RESOURCE_RULES = {
    -- checked in order; first match wins, so the specific ones come first
    { pat = "Junk",        icon = "junk"   },
    { pat = "Lotus",       icon = "lotus"  },
    { pat = "RockIron",    icon = "ore"    },
    { pat = "RockCopper",  icon = "ore"    },
    { pat = "RockCoal",    icon = "ore"    },
    { pat = "RockQuartz",  icon = "ore"    },
    { pat = "Sulfur",      icon = "ore"    },
    { pat = "Ore",         icon = "ore"    },   -- SkyIslandOre, WorldTreeOre
    { pat = "Crystal",     icon = "ore"    },   -- Crystal, PalCrystal
    { pat = "NightStone",  icon = "ore"    },
    { pat = "Mushroom",    icon = "forage" },
    { pat = "Berry",       icon = "forage" },
    { pat = "Poppy",       icon = "forage" },
    { pat = "AffectionFruit", icon = "forage" },
}

local resourceIconFor = {}    -- class name -> texture, or false for "skip"

local function resourceIcon(actor)
    local ok, cls = pcall(rawClassName, actor)
    if not ok or type(cls) ~= "string" then return nil end
    local known = resourceIconFor[cls]
    if known ~= nil then return known or nil end

    local pick = nil
    for i = 1, #RESOURCE_RULES do
        local r = RESOURCE_RULES[i]
        if cls:find(r.pat, 1, true) then pick = ICON[r.icon]; break end
    end
    -- `false` and not nil: nil means "not resolved yet" to the line above,
    -- so a class we mean to skip has to be remembered as a definite no.
    resourceIconFor[cls] = pick or false
    return pick
end
-- ---------------------------------------------------------------


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

-- Base camp autohide, declared up here because the static scan below has
-- to know whether the camp positions are still needed. See updateProximity.
local campRoute = nil      -- which route answered, logged once when it changes
local campExact = false    -- the player's own component has answered at least once

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

-- Height as well, for the ONE actor that needs it: the live terrain
-- capture has to know how high to put its camera (capture.lua). Kept
-- separate from actorLocation rather than added to it because that one is
-- called for hundreds of actors a scan and every extra field read is paid
-- by all of them.
local function rawLocationZ(actor)
    local loc = actor:K2_GetActorLocation()
    return loc.X, loc.Y, loc.Z
end

function M.actorLocation3(actor)
    if not guard.alive(actor) then return nil end
    local ok, x, y, z = pcall(rawLocationZ, actor)
    if not ok or type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y, (type(z) == "number") and z or 0.0
end

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

-- ---------------------------------------------------------------
-- "Has the player already taken this?"
--
-- THERE IS NO ONE FLAG FOR THIS, which is what 2.2.18 and everything before
-- it assumed. `bPickedInClient` lives on `PalLevelObjectObtainable`, the
-- base of notes and effigies ONLY - it does not exist on a chest at all, so
-- reading it there simply raised and the answer was always "not taken".
-- That is why looted chests stayed on the minimap.
--
-- A chest keeps its `bOpened` on its MODEL, not on the actor:
--
--     PalMapObjectTreasureBox (actor) -> .MapObjectModel
--                                     -> PalMapObjectTreasureBoxModel.bOpened
--
-- Both confirmed in Palworld.usmap. Each kind therefore names its own
-- reader in STATIC_KINDS rather than sharing one and hoping.
--
-- FAILING TO READ MEANS "NOT TAKEN", never "taken". Getting that backwards
-- would empty the minimap of chests on a build where the model is not
-- reachable, which is the 2.0.6 mistake in a new place.
-- ---------------------------------------------------------------
local function rawPicked(actor) return actor.bPickedInClient end
local function rawModel(actor) return actor.MapObjectModel end
local function rawOpened(model) return model.bOpened end
local function rawDisposed(model) return model.bDisposed end

-- Notes and effigies: they stay in the world after being taken, with the
-- flag set on the actor itself.
local function pickedUp(actor)
    local ok, v = pcall(rawPicked, actor)
    if not ok then return false end
    return asBool(v) == true
end

-- EGGS AND OTHER MAP-OBJECT PICKUPS (2.3.5).
--
-- Reported in game: "coletei um ovo, e ele nao sumiu do minimapa."
--
-- `hideCollected` used `pickedUp` for eggs, and `bPickedInClient` lives on
-- `PalLevelObjectObtainable` - the base of Note and Relic ONLY. Checked in
-- the usmap: `PalMapObjectPalEgg` has exactly ONE property,
-- `ParameterComponent`. There is no pickup flag on the actor at all, so the
-- read raised, the answer was always "not taken", and the egg stayed.
--
-- This is the 2.2.19 chest bug in a second hierarchy, and the shape of the
-- fix is the same: THE STATE IS ON THE MODEL, not the actor. A chest has
-- its own `PalMapObjectTreasureBoxModel.bOpened`; an egg's model has no
-- flag of its own, but every map-object model inherits
-- `PalMapObjectConcreteModelBase.bDisposed`, which is what a consumed
-- pickup sets.
--
-- Unreadable still means NOT taken. Inverting that empties the map, which
-- is the 2.0.6 mistake this project keeps having to re-learn.
local function mapObjectGone(actor)
    local ok, model = pcall(rawModel, actor)
    if ok and model ~= nil then
        local got, v = pcall(rawDisposed, model)
        if got then
            local b = asBool(v)
            if b ~= nil and b then return true end
        end
    end
    -- Some pickups really are `PalLevelObjectObtainable`; ask that too
    -- rather than deciding on one reader.
    return pickedUp(actor)
end

-- Chests: looted ones stay in the world too - the lid is just open.
local function chestOpened(actor)
    local ok, model = pcall(rawModel, actor)
    if ok and model ~= nil then
        local got, v = pcall(rawOpened, model)
        if got then
            local b = asBool(v)
            if b ~= nil then return b end
        end
    end
    -- a build that will not give up the model: fall back to the actor flag
    -- rather than deciding on nothing
    return pickedUp(actor)
end

-- Static world objects. `collected` is the kind's own "has this been taken
-- already?" reader - see the block above. There is no single flag for it:
-- a chest keeps its state on its model, a note on the actor.
--
-- `iconFor` is a per-ACTOR icon, for a kind whose members do not all look
-- the same. RETURNING NIL FROM IT SKIPS THE ACTOR - that is how the
-- resource scan drops the rubble it does not want out of a class it has to
-- walk anyway. Kinds without an `iconFor` keep their single ICON[kind] and
-- pay no extra reflection.
local STATIC_KINDS = {
    { cfg = "showChests",     class = "PalMapObjectTreasureBox",                kind = "chest",   collected = chestOpened },
    { cfg = "showEggs",       class = "PalMapObjectPalEgg",                     kind = "egg",     collected = mapObjectGone, iconFor = eggIcon },
    { cfg = "showNotes",      class = "PalLevelObjectNote",                     kind = "note",    collected = pickedUp },
    { cfg = "showEffigies",   class = "PalLevelObjectRelic",                    kind = "effigy",  collected = pickedUp },
    { cfg = "showSkillFruit", class = "PalMapObjectSpawnerMultiItem",           kind = "fruit"    },
    { cfg = "showFastTravel", class = "PalLevelObjectUnlockableFastTravelPoint", kind = "travel"  },
    { cfg = "showDungeons",   class = "BP_DungeonEntrance_Base_C",              kind = "dungeon"  },
    { cfg = "showBaseCamps",  class = "PalBuildObjectBaseCampPoint",            kind = "camp"     },
    { cfg = "showEnemyCamps", class = "PalNPCCampSpawnerBase",                  kind = "enemy"    },
    { cfg = "showTowers",     class = "PalBossTower",                           kind = "tower"    },
    -- 2.2.18: things the game's own compass marks that the minimap did not.
    { cfg = "showResources",  class = "PalMapObjectSpawnerSimple",              kind = "ore",     iconFor = resourceIcon },
    { cfg = "showFishing",    class = "PalFishingSpotArea",                     kind = "fishing"  },
    { cfg = "showTreasureMaps", class = "PalTreasureMapPoint",                  kind = "dig"      },
    { cfg = "showDeaths",     class = "BP_MapObject_DeathPenaltyChest_C",       kind = "death"    },
}

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
        end
        return found
    end
    if not S.reported[class] then
        S.reported[class] = true
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
local badElements = {}

local function elementsUsable(out, n, label)
    if n == nil or n == 0 then return true end
    if guard.alive(out[1]) then return true end
    if not badElements[label] then
        local inner = guard.get(rawUnwrap, out[1])
        badElements[label] = (inner ~= nil and guard.alive(inner)) and "wrapped" or "unreadable"
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
        elseif n > 0 and not elementsUsable(monstersBuf, n, "PalUtility") then
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
    if not elementsUsable(out, n, "PalUtility") then return nil end
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

-- ---------------------------------------------------------------
-- VARIANT SUFFIXES THAT REUSE THE BASE SPECIES PORTRAIT (2.3.3)
--
-- 2.1.4 found that alphas are `BP_<Species>_BOSS_C_<id>` and have no
-- portrait of their own, so it fell back to the base species - but only
-- for a `_BOSS` suffix, deliberately, because dropping ANY trailing
-- segment sends every human tribe on a second chase as well
-- (`NPC_Villager` -> `NPC`) for assets that never existed.
--
-- That was the right instinct and too narrow a list. Counted against the
-- shipping pak: 457 Pal blueprints have no `T_<tribe>_icon_normal` of
-- their own, 431 of them DO have a base species that does, and the
-- `_BOSS`-only rule reaches just 286. The remaining 145 - every
-- `_Predator`, `_Normal`, `_Skin001`, `_GYM`, `_Oilrig`, `_RAID`,
-- `_Quest` and elemental variant - fail the species-icon test, and
-- failing it is precisely what marks an actor as a HUMAN. They were being
-- drawn with the NPC marker.
--
-- A WHITELIST keeps 2.1.4's guarantee: `Villager` is not in it, so no
-- human tribe can start chasing. The suffixes below were derived by
-- walking the pak index, not invented - see the audit in the README.
-- Stripping repeats (bounded), because `AmaterasuWolf_Dark_BOSS` needs
-- two passes to reach `AmaterasuWolf`.
--
-- The EXACT tribe is still probed first, and that ordering is load
-- bearing: some variants really do have their own row (`FlameBuffalo_Ice`),
-- and they must keep their own picture rather than the base one.
-- ---------------------------------------------------------------
local VARIANT_SUFFIX = {}
for _, s in ipairs({
    -- fight/spawn variants
    "BOSS", "Boss", "BOSS2", "Predator", "Normal", "Quest", "Enemy",
    "GYM", "Gym", "Hard", "BossRush", "RAID", "Oilrig", "Police",
    "Summon", "MiddleBoss", "Ring", "otomo",
    -- elemental re-skins; only reached when the exact tribe has no row
    "Fire", "Ice", "Water", "Grass", "Dark", "Electric", "Ground",
    "Neutral", "Dragon", "Flower", "Gold", "Thunder", "Green",
}) do VARIANT_SUFFIX[s] = true end

local function isVariantSuffix(s)
    if VARIANT_SUFFIX[s] then return true end
    -- Skin001 .. Skin004, and any future numbered skin
    return s:match("^Skin%d+$") ~= nil
end

-- "AmaterasuWolf_Dark_BOSS" -> "AmaterasuWolf", or nil when nothing
-- recognisable can be stripped. Bounded so a pathological name cannot
-- loop, and the result is cached by the caller.
local function strippedVariant(tribe)
    local cur = tribe
    for _ = 1, 4 do
        local head, tail = cur:match("^(.+)_([A-Za-z0-9]+)$")
        if head == nil or not isVariantSuffix(tail) then break end
        cur = head
    end
    if cur == tribe then return nil end
    return cur
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
        base = strippedVariant(tribe) or false
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
-- not participating in the level.
--
-- bIsPalActiveActor IS THE FLAG FOR THIS, specifically, and bHidden and
-- IsDead alone do not catch it: a partner sitting in its sphere is neither
-- bHidden nor dead, it is just inactive. The property is replicated with
-- its own OnRep (OnRep_IsPalActiveActor, confirmed in the game's own exe)
-- and toggled by SetActiveActor/SetActiveActorStayVisible - this is a
-- deliberate, maintained flag, not a side effect of something else.
--
-- THREE guarded reads, in cost order, and NONE may filter on a build that
-- does not expose it: an unreadable property means "no opinion", never
-- "hide it". Getting that backwards is how 2.0.6 emptied the minimap.
--   * bIsPalActiveActor - false while sitting in a sphere, whether carried
--     in the active team or sitting in the Pal Box.
--   * bHidden           - the engine's own "this actor is not being
--     rendered", for whatever bIsPalActiveActor does not cover.
--   * PalUtility::IsDead - what 1.x used; a caught or knocked-out pal
--     lingers for a moment before the game removes it, and 1.x had a
--     whole setting ("delay remove dead/caught pals") about that window.
-- ---------------------------------------------------------------
local function rawActiveActor(actor) return actor.bIsPalActiveActor end
local function rawHidden(actor) return actor.bHidden end
local function rawIsDead(util, actor) return util:IsDead(actor) end

local activeReadable, hiddenReadable, deadReadable = nil, nil, nil

local function inWorld(actor)
    if activeReadable ~= false then
        local ok, v = pcall(rawActiveActor, actor)
        if ok then
            activeReadable = true
            local b = asBool(v)
            if b == false then return false end
        elseif activeReadable == nil then
            activeReadable = false
        end
    end

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
    -- property being unreadable, and the other two checks still do their
    -- job without it.
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

-- ---------------------------------------------------------------
-- Human NPC portraits (2.2.2)
--
-- Pals get their icon by CONVENTION: the tribe `Alpaca` uses
-- `T_Alpaca_icon_normal`, and `speciesIcon` builds that path itself. HUMANS
-- DO NOT WORK THAT WAY. The tribe `BOSS_Hunter_Rifle` uses
-- `T_BOSS_NPC_Hunter`; `BOSS_Ninja` uses `T_BOSS_NPC_Male_Ninja`;
-- `BOSS_Scientist_LaserRifle` uses `T_BOSS_NPC_Male_Scientist`. There is no
-- rule to derive - the game keeps the pairing in
-- `DT_PalCharacterIconDataTable`, and `tools/extract_icons.py` decodes that
-- table into `Scripts/npcicons.lua`. Guessing from the names would have got
-- several of these wrong, silently, in a way that only looks like the wrong
-- face on the map.
--
-- WHY THIS IS A SEPARATE LOOKUP AND NOT PART OF `speciesIcon`: speciesIcon is
-- what decides pal-versus-human in the first place - a tribe whose species
-- icon EXISTS is a pal. Teaching it about human portraits would make every
-- human answer "yes, I am a pal", which is precisely the 2.0.8 regression:
-- humans back in the pal list, eating the icon budget so real pals fall off
-- the end. So the two never meet. This table is consulted ONLY for actors the
-- classifier has already called human.
--
-- 2.2.12 FIXES TWO MISTAKES IN THE 2.2.2 VERSION, both of which showed up as
-- "the merchant is just an arrow":
--
--   1. THE TABLE WAS FILTERED TO `/PalIcon/NPC/`, which kept 34 rows - only
--      the named "BOSS" humans. A merchant's, villager's or guard's portrait
--      is NOT in that folder; it sits in PalIcon/Normal beside the Pals:
--          Male_Trader01    -> T_PalDealer_icon_normal
--          VisitingMerchant -> T_Female_MobuCitizen_icon_normal
--          Guard_Rifle      -> T_Police_icon_normal
--      The folder says nothing about human-versus-Pal, so filtering on it was
--      wrong. All 674 rows are generated now, with the full path, because the
--      folder varies per row.
--
--   2. IT WAS KEYED BY THE ACTOR'S NAME. That works for Pals, whose actor is
--      `BP_<CharacterID>_C_<n>`, and NEVER works for humans: one blueprint,
--      `BP_NPC_HumanNormal`, is spawned as a merchant, a villager or a guard,
--      so the actor name cannot possibly say which. The game keys this table
--      by CharacterID, which is a runtime property - see characterIdOf below.
-- ---------------------------------------------------------------
local NPC_ICON = (function()
    local ok, t = pcall(require, "npcicons")
    if ok and type(t) == "table" then return t end
    guard.log("npcicons.lua could not be loaded; human NPCs will all use the "
        .. "generic marker (run tools/extract_icons.py to regenerate it)")
    return {}
end)()

-- The game's own key for "which character is this", which is what the icon
-- table is indexed by. Four routes because none of them is guaranteed on a
-- given UE4SS build; the one that works is remembered and logged once, the
-- same pattern the base camp check uses.
--
-- Route A is deliberately first: it is the SAME two hops the shiny test
-- already makes on every pal (GetCharacterParameterComponent ->
-- IndividualParameter), so it is known safe on this build rather than hoped
-- to be. The later ones walk further, and walking further into a
-- half-constructed actor is what has crashed this mod before.
local function rawCharIdA(actor)
    return actor:GetCharacterParameterComponent().IndividualParameter:GetCharacterID()
end
local function rawCharIdB(actor) return actor:GetCharacterID() end
local function rawCharIdC(actor)
    return actor:GetCharacterParameterComponent().IndividualParameter.SaveParameter.CharacterID
end
local function rawCharIdD(actor) return actor:GetMainMesh().CharacterID end

local CHAR_ID_ROUTES = {
    { name = "IndividualParameter:GetCharacterID()", fn = rawCharIdA },
    { name = "actor:GetCharacterID()",               fn = rawCharIdB },
    { name = "SaveParameter.CharacterID",            fn = rawCharIdC },
    { name = "GetMainMesh().CharacterID",            fn = rawCharIdD },
}
local charIdRoute = nil
local charIdMisses = 0           -- actors no route could answer, for the warning
local CHAR_ID_WARN = 60

local function rawFNameString(v) return v:ToString() end

local function asName(v)
    if type(v) == "string" then return v ~= "" and v or nil end
    if v == nil then return nil end
    local s = guard.get(rawFNameString, v)      -- FName
    if type(s) == "string" and s ~= "" and s ~= "None" then return s end
    return nil
end

local function characterIdOf(actor)
    if actor == nil then return nil end
    if charIdRoute ~= nil then
        return asName(guard.get(charIdRoute.fn, actor))
    end
    for i = 1, #CHAR_ID_ROUTES do
        local r = CHAR_ID_ROUTES[i]
        local id = asName(guard.get(r.fn, actor))
        if id ~= nil then
            charIdRoute = r
            charIdMisses = 0
            guard.log("NPC portraits: character IDs read via " .. r.name)
            return id
        end
    end
    -- KEEP TRYING. A give-up counter was written here first and was wrong:
    -- an actor still spawning answers nothing on any route, and a handful of
    -- those in a row would switch the feature off for the session before the
    -- first NPC that could have answered ever arrived. Four failed pcalls per
    -- human per scan is ~24 a second at the icon budget - nothing next to the
    -- actor scans - so it costs less to keep asking than to be wrong.
    charIdMisses = charIdMisses + 1
    if charIdMisses == CHAR_ID_WARN then
        guard.log("no way to read a character's CharacterID on this build, so human "
            .. "portraits fall back to the actor name - which is right for pals and "
            .. "wrong for most humans. Please report this.")
    end
    return nil
end

-- CharacterID -> full asset path, or false for "no portrait". Resolved once
-- and kept, for the same reason addPal resolves its path at scan time:
-- building it per NPC per frame is throwaway strings on the draw path.
local npcPathFor = {}

local function npcIcon(actor, name)
    local id = characterIdOf(actor)
    -- Fallback for a build where no route answers: the actor name. It is
    -- right for Pals and for the handful of humans whose blueprint happens to
    -- be named after their CharacterID, and wrong for the rest - which is
    -- still better than every human being an arrow.
    if id == nil then id = tribeOf(name) end
    if id == nil then return nil end

    local known = npcPathFor[id]
    if known ~= nil then return known or nil end
    local path = NPC_ICON[id]
    if path == nil then
        npcPathFor[id] = false
        return nil
    end
    npcPathFor[id] = path
    return path
end

-- HUMANS HAVE A BUDGET OF THEIR OWN (`maxNpcIcons`), and the icon pool is
-- sized from it. The two obvious alternatives are both worse, and 2.2.2 tried
-- them in this order:
--
--   * letting NPCs take `maxPalIcons` too overflows the pool, and the draw
--     loop then drops whatever was emitted last - always the NPCs, silently.
--     That was already happening before they had portraits; nobody noticed
--     because every human wore the same generic marker.
--   * making them SHARE `maxPalIcons` is worse still: pals are collected
--     first, so anywhere with 48 pals in range showed no people at all.
--
-- A separate budget is the only one of the three where "show NPC humans"
-- means what it says. It defaults smaller than the pal budget because a
-- crowd of villagers is scenery, not information.
--
-- The list is filled in distance order, so this keeps the nearest.
local playersDrawnAsNpcs, reportedPlayerAsNpc = 0, false

local function addNPC(cfg, actor, name)
    -- A PLAYER IS NEVER AN NPC. This is the backstop for the name-based
    -- exclusion set (see isPlayerActor): it sits in the ONE place all
    -- three scan routes funnel through, so a player cannot wear the human
    -- marker whatever went wrong upstream. It also covers the local
    -- player, whose own arrow would otherwise get an NPC icon stacked
    -- under it - the 2.0.5 double-marker bug, by a different road.
    if isPlayerActor(actor) then
        playersDrawnAsNpcs = playersDrawnAsNpcs + 1
        if not reportedPlayerAsNpc then
            reportedPlayerAsNpc = true
            guard.log("a player reached the NPC list - the name-based exclusion "
                .. "missed it, and the class test caught it. Other players will "
                .. "not be drawn as human NPCs.")
        end
        return
    end
    if #S.npcs >= (cfg.maxNpcIcons or 24) then return end
    S.npcs[#S.npcs + 1] = { actor = actor, icon = npcIcon(actor, name) }
end

-- OTHER PLAYERS NEED A BUDGET LIKE EVERY OTHER KIND (2.3.3).
--
-- This was the one list feeding the draw with no limit on it. render.lua
-- sizes its icon pool from maxPalIcons + maxPoiIcons + maxNpcIcons, and
-- collect() emits statics, then pals, then PLAYERS, then humans - so on a
-- server every player beyond the pool's spare room pushed an NPC off the
-- end, silently, because the draw loop simply stops at `used >= limit`.
-- Exactly the failure mode the maxNpcIcons note below describes, arrived
-- at from the other direction.
--
-- It never showed up in testing because in singleplayer this list is
-- always EMPTY: the local player is excluded by name.
--
-- The caller still records the name in `excluded` whether or not the icon
-- is taken - that bookkeeping is what stops a player being counted as a
-- pal, and it must not depend on a budget.
local function addPlayer(cfg, actor)
    if #S.players >= (cfg.maxPlayerIcons or 16) then return end
    S.players[#S.players + 1] = actor
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

-- ---------------------------------------------------------------
-- PalObjectCollector - the route that finally works
--
-- FOUND BY PARSING Palworld.usmap (the schema dump in _tools), not by
-- guessing. The game keeps its own curated, already-classified lists:
--
--   PalObjectCollector.PalCharacter_All      Array<Object>
--   PalObjectCollector.PalCharacter_NPC      Array<Object>
--   PalObjectCollector.PalCharacter_Player   Array<Object>
--
-- and pals = All minus NPC minus Player. No object-array walk, and the
-- classification is the game's own rather than anything inferred here.
--
-- WHY THIS ONE IS SAFE WHERE PalUtility WAS NOT, which is the whole point:
-- these are PROPERTIES, not out parameters. A property read goes to memory
-- owned by the object and hands back first-class UObjects, so the
-- references may be kept for the four seconds until the next scan.
-- PalUtility's out-param array lives in the call frame and is gone by the
-- time the table reaches Lua - keeping what came out of it is what killed
-- the game in 2.1.5. The rule from the top of this file decides between
-- them, and it is checked here too rather than assumed.
-- ---------------------------------------------------------------
local COLLECTOR_CLASS = "PalObjectCollector"
local collectorObj = nil
local collectorState = 0        -- 0 untried, 1 usable, 2 unavailable
local collectorTries = 0
local COLLECTOR_MAX_TRIES = 6

local allBuf, humanBuf2, playerBuf2 = {}, {}, {}
local exclScratch = {}

local function rawProp(o, name) return o[name] end

-- FindAllOf/FindFirstOf hand back the class default object first, and a
-- CDO's arrays are always empty - the same trap the Esc-menu widget hunt
-- fell into. Skip anything called Default__*.
local function isRealInstance(o)
    if o == nil or not guard.alive(o) then return false end
    local n = actorName(o)
    return n == nil or n:sub(1, 9) ~= "Default__"
end

local function findCollector()
    local o = guard.get(FindFirstOf, COLLECTOR_CLASS)
    if isRealInstance(o) then return o end
    local all = guard.get(FindAllOf, COLLECTOR_CLASS)
    if type(all) == "table" then
        for i = 1, #all do
            if isRealInstance(all[i]) then return all[i] end
        end
    end
    return nil
end

local function collectorList(obj, prop, out)
    local v = guard.get(rawProp, obj, prop)
    local n = toArray(v, out, nil)
    if n == nil then return nil end
    if not elementsUsable(out, n, COLLECTOR_CLASS) then return nil end
    return n
end

local function scanViaCollector(cfg, px, py, maxD2, playerPawn)
    local obj = collectorObj
    if obj == nil or not guard.alive(obj) then return false end

    local nAll = collectorList(obj, "PalCharacter_All", allBuf)
    if nAll == nil then return false end
    local nHum = collectorList(obj, "PalCharacter_NPC", humanBuf2) or 0
    local nPly = collectorList(obj, "PalCharacter_Player", playerBuf2) or 0

    -- Everything that is NOT a pal, by name. Names are unique within a
    -- level; identity comparison on reflected UObjects is not reliable.
    local excluded = exclScratch
    for k in pairs(excluded) do excluded[k] = nil end

    -- The local player's own pawn IS a player character, so this is the
    -- one source of the player class set that can never come back empty.
    notePlayerClass(playerPawn)
    local selfName = playerPawn ~= nil and actorName(playerPawn) or nil
    if selfName ~= nil then excluded[selfName] = true end

    for i = 1, nPly do
        local a = playerBuf2[i]
        notePlayerClass(a)
        local n = actorName(a)
        if n ~= nil then
            excluded[n] = true
            if cfg.showPlayers and n ~= selfName then
                addPlayer(cfg, a)
            end
        end
    end
    for i = 1, nHum do
        local n = actorName(humanBuf2[i])
        if n ~= nil then excluded[n] = true end
    end

    local skipped, inRange = 0, 0
    local noLoc, noName, farAway = 0, 0, 0
    if cfg.showPals then
        local near, n = gatherNear(allBuf, nAll, px, py, maxD2, excluded, true)
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
        -- needName is true now: the portrait lookup is by tribe, and the
        -- tribe comes out of the actor name. One extra reflection read per
        -- NEARBY human, which is a handful - the distance test has already
        -- thrown away everything across the level.
        local near, n = gatherNear(humanBuf2, nHum, px, py, maxD2, nil, true)
        for i = 1, n do addNPC(cfg, near[i].actor, near[i].name) end
        for i = 1, n do near[i].actor = nil end
    end

    lastMonsterCount = nAll
    for i = 1, nAll do allBuf[i] = nil end
    for i = 1, nHum do humanBuf2[i] = nil end
    for i = 1, nPly do playerBuf2[i] = nil end

    if not reportedScan or (cfg.showPals and #S.pals == 0 and nAll > 0) then
        reportedScan = true
        guard.log(string.format(
            "character scan via PalObjectCollector: %d characters, %d humans, %d players | "
            .. "of the pals: %d unreadable, %d unnamed, %d out of range, %d in range "
            .. "-> %d drawn, %d not present in the world",
            nAll, nHum, nPly, noLoc, noName, farAway, inRange, #S.pals, skipped))
    end
    return true
end

-- The PalUtility path: the game hands us three separate, already-correct
-- lists, so there is nothing to classify and no object array to walk.
local function scanViaUtility(cfg, px, py, maxD2, playerPawn, ctx)
    local nMon = utilityList("GetPalMonsters", ctx, monstersBuf)
    lastMonsterCount = nMon or 0
    if nMon == nil then return false end

    local nHum = utilityList("GetHumanNPCs", ctx, humansBuf) or 0
    local nPly = utilityList("GetAllPlayerCharacters", ctx, playersBuf) or 0

    notePlayerClass(playerPawn)
    local selfName = playerPawn ~= nil and actorName(playerPawn) or nil
    local excluded = nil
    if selfName ~= nil then excluded = { [selfName] = true } end

    for i = 1, nPly do
        local a = playersBuf[i]
        notePlayerClass(a)
        local n = actorName(a)
        if n ~= nil then
            excluded = excluded or {}
            excluded[n] = true
            if cfg.showPlayers and n ~= selfName then
                addPlayer(cfg, a)
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
        local near, n = gatherNear(humansBuf, nHum, px, py, maxD2, excluded, true)
        for i = 1, n do addNPC(cfg, near[i].actor, near[i].name) end
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
    notePlayerClass(playerPawn)
    local selfName = playerPawn ~= nil and addExcluded(excluded, playerPawn) or nil
    local nPlayers = 0

    if not rejectedClass["PalPlayerCharacter"] then
        local all = findAll("PalPlayerCharacter", "players")
        if usableForExclusion("PalPlayerCharacter", #all, palCount) then
            nPlayers = #all
            excluded = excluded or {}
            for i = 1, #all do
                local a = all[i]
                notePlayerClass(a)
                local n = addExcluded(excluded, a)
                if cfg.showPlayers and n ~= selfName then
                    addPlayer(cfg, a)
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
    local nPals, nHumans, nLatePlayers = 0, 0, 0
    for i = 1, n do
        local e = near[i]
        local tribe = tribeOf(e.name)
        local icon = speciesIcon(tribe)
        -- nil  = not probed yet
        -- false + format unproven = we have no basis to filter anything
        local isPal = (icon ~= false) or (not iconFormatWorks)
        if isPal then
            -- Until one species icon has resolved, `iconFormatWorks` is
            -- false and EVERYTHING answers "pal" - that is 2.1.0's safety
            -- valve, and it is right, but it means a player would wear a
            -- pal marker for the first scan or two. Rule that out while
            -- the window is open; once the format is proven, a player can
            -- only ever land in the human branch below, and this costs
            -- nothing again.
            if not iconFormatWorks and isPlayerActor(e.actor) then
                nLatePlayers = nLatePlayers + 1
            else
                nPals = nPals + 1
                if cfg.showPals and inWorld(e.actor) then
                    addPal(cfg, e.actor, tribe, playerPawn)
                end
            end
        -- ONLY HERE is the class read paid for. A player the name-based
        -- exclusion missed lands in this branch, because its tribe
        -- (`PlayerBase`) has no species icon - but so does every real
        -- human, and there are far fewer of those nearby than there are
        -- pals. Testing every character instead would put a
        -- GetClass():GetFName():ToString() on each one, which is the kind
        -- of per-actor reflection that scales with how crowded the area is
        -- - the thing that made walking hitch in 2.1.2.
        elseif isPlayerActor(e.actor) then
            nLatePlayers = nLatePlayers + 1
        else
            nHumans = nHumans + 1
            if cfg.showNPCs then addNPC(cfg, e.actor, e.name) end
        end
    end
    nPlayers = nPlayers + nLatePlayers

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
    end

    -- do not keep actor references alive in the scratch table
    for i = 1, n do near[i].actor = nil end
end

function M.scanDynamic(cfg, px, py, zoom, playerPawn)
    local maxD2 = keepRadius2(zoom)

    wipe(S.pals); wipe(S.players); wipe(S.npcs)

    if cfg.showPals or cfg.showNPCs or cfg.showPlayers then
        -- FIRST CHOICE: the game's own already-classified character lists,
        -- read as PROPERTIES so the handles are ours to keep. Looked for
        -- once; the collector is a world object, so a few retries cover a
        -- probe that lands before the world is up.
        if collectorState == 0 then
            collectorTries = collectorTries + 1
            collectorObj = findCollector()
            if collectorObj ~= nil then
                local n = collectorList(collectorObj, "PalCharacter_All", allBuf)
                if n ~= nil then
                    collectorState = 1
                    guard.log(string.format(
                        "using PalObjectCollector: PalCharacter_All/_NPC/_Player are the "
                        .. "game's own classified lists, read as properties (%d characters "
                        .. "right now). No object-array walk, and no guessing which is "
                        .. "which.", n))
                else
                    collectorObj = nil
                    if badElements[COLLECTOR_CLASS] then
                        collectorState = 2
                        collectorTries = COLLECTOR_MAX_TRIES
                    end
                end
                for i = 1, (n or 0) do allBuf[i] = nil end
            end
            if collectorState == 0 and collectorTries >= COLLECTOR_MAX_TRIES then
                collectorState = 2
                guard.log("PalObjectCollector is not readable on this build; trying PalUtility next.")
            end
        end

        if collectorState == 1 then
            if scanViaCollector(cfg, px, py, maxD2, playerPawn) then
                S.lastScan = os.clock()
                S.version = S.version + 1
                return
            end
            -- it worked once and has stopped: the world probably changed
            collectorObj = findCollector()
            if collectorObj == nil then collectorState = 0; collectorTries = 0 end
        end

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
            elseif badElements["PalUtility"] then
                -- not a "maybe next time" failure: it has already said what
                -- it hands back, and that will not change
                utilState = 2
            else
                utilTries = utilTries + 1
                if utilTries >= UTIL_MAX_TRIES then
                    utilState = 2
                    guard.log("PalUtility could not be used on this build - scanning the "
                        .. "object array instead, and telling pals from humans by their "
                        .. "species icon.")
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
-- kind -> { at = os.clock(), x = , y = } of the pass that filled it, or nil
-- if the kind has never been walked in this world.
local kindSeen = {}
local rotation = 1

-- ---------------------------------------------------------------
-- SCAN ONCE, THEN ONLY WHEN SOMETHING COULD HAVE CHANGED (2.3.4)
--
-- Until now the rotation above never stopped: every static kind was walked
-- again, `FindAllOf` and all, every few seconds for the whole session -
-- fifteen full UObject-array walks per round, for lists that had not moved
-- since the last round. Chests do not walk away.
--
-- Two things genuinely change, and they want different answers:
--
--   WHERE things are   changes only when the level streams in something
--                      new, which happens because the player TRAVELLED.
--                      So the trigger is distance, not time.
--   WHETHER a thing is
--   still there        changes when the player opens a chest or picks up
--                      a note, and `collected` is read at scan time, so
--                      only a re-walk clears it. That is the ONE reason a
--                      standing-still player still needs re-scans - and
--                      only for the four kinds that can be collected.
--
-- Hence a short interval for collectible kinds, a long safety net for the
-- rest, and a distance trigger for both. Standing in a base, this takes
-- the static scan from ~15 array walks a minute to zero.
--
-- The alternative - caching the actor and re-reading `collected` off it -
-- would be cheaper still and is deliberately NOT done: it means holding
-- actor references indefinitely, and every native crash this mod has had
-- came from exactly that.
-- ---------------------------------------------------------------
local RESCAN_DISTANCE = 12000.0     -- world units travelled since the pass
local RESCAN_NEAR = 5.0             -- seconds, standing next to one of them
local RESCAN_COLLECTIBLE = 60.0     -- seconds, kinds whose markers can be taken
local RESCAN_SECONDS = 300.0        -- seconds, everything else
-- How close the player has to be to one of a kind's own markers for the
-- collectible re-check to be worth doing at all. You cannot open a chest
-- from across the island, so if none is within reach nothing of that kind
-- can have changed and the walk is pure waste. Generous, because the
-- cached position is where the marker was, not where the player's reach
-- ends, and being late to clear a marker is worse than one extra walk.
local INTERACT_RANGE = 6000.0

-- Is the player near enough to any marker of this kind to have taken one?
local function nearAnyMarker(kind, px, py)
    local list = kindCache[kind]
    if list == nil then return false end
    local r2 = INTERACT_RANGE * INTERACT_RANGE
    for i = 1, #list do
        local p = list[i]
        local dx, dy = px - p.x, py - p.y
        if (dx * dx + dy * dy) <= r2 then return true end
    end
    return false
end

local function kindIsStale(spec, now, px, py)
    local seen = kindSeen[spec.kind]
    if seen == nil then return true end          -- never walked
    local dx, dy = px - seen.x, py - seen.y
    if (dx * dx + dy * dy) > (RESCAN_DISTANCE * RESCAN_DISTANCE) then
        return true                              -- travelled: new chunks
    end
    if spec.collected ~= nil then
        local age = now - seen.at
        -- STANDING ON ONE: check quickly. Whoever just picked an egg up is
        -- still next to where it was, and "coletei um ovo e ele nao sumiu"
        -- is what a slow re-check feels like from the player's side.
        if age >= RESCAN_NEAR and nearAnyMarker(spec.kind, px, py) then
            return true
        end
        -- None within reach, so nothing of this kind can have been taken by
        -- US. Somebody else's pickup on a server is covered by the slower
        -- net below. Skipping fresh kinds made the collectibles come round
        -- far faster than the old fifteen-kind rotation did, so without this
        -- the change traded a saving on the rest for a cost on these -
        -- measured, not assumed: chest walks went from 1.1/min to 2.3/min
        -- while standing still.
        if age >= RESCAN_COLLECTIBLE then return true end
        return false
    end
    return (now - seen.at) >= RESCAN_SECONDS
end

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
    -- The autohide used to force this scan so it had camp positions to
    -- measure a radius against. It now asks the player's own component
    -- instead, so the walk is only needed while that route is unavailable.
    if spec.kind == "camp" and cfg.autohideInBase and not campExact then
        return true
    end
    return false
end

local function beginKind(spec, px, py)
    local all = findAll(spec.class, spec.kind)
    cursor = {
        spec = spec, all = all, total = #all, index = 0,
        list = {}, count = 0,       -- built aside, swapped in when complete
        startedAt = os.clock(),
        -- where the player was when this pass began, stamped onto
        -- kindSeen when it completes
        px = px, py = py,
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
            local skip = cfg.hideCollected and spec.collected ~= nil
                         and spec.collected(a)
            -- A kind with a per-actor icon may also DECLINE an actor by
            -- returning nil - that is how the resource scan walks
            -- PalMapObjectSpawnerSimple (which it must, to find ore) and
            -- still drops the thousands of stone and wood spawners in it.
            local tex = nil
            if not skip and spec.iconFor ~= nil then
                tex = spec.iconFor(a)
                if tex == nil then skip = true end
            end
            if not skip then
                count = count + 1
                local p = list[count]          -- reused, not reallocated
                if p == nil then p = {}; list[count] = p end
                p.x, p.y = x, y
                -- ALWAYS assigned, never left alone: `p` is a reused table,
                -- so a texture set by a previous pass over a different kind
                -- would otherwise stick to an entry that has no business
                -- carrying one.
                p.tex = tex
            end
        end
    end

    c.index, c.count = i, count
    if i < c.total then return false end

    for j = #list, count + 1, -1 do list[j] = nil end
    kindCache[spec.kind] = list
    -- Remember WHEN and WHERE this pass ran, not just that it did:
    -- kindIsStale() needs both to decide the kind is worth walking again.
    kindSeen[spec.kind] = { at = os.clock(), x = c.px, y = c.py }
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
                if isCamp and cfg.autohideInBase and not campExact then
                    camps[#camps + 1] = p
                end
                if visible then
                    local d = dist2(p.x, p.y, px, py)
                    if d <= maxD2 then
                        n = n + 1
                        local slot = found[n]
                        if slot == nil then slot = {}; found[n] = slot end
                        slot.x, slot.y, slot.kind, slot.d = p.x, p.y, spec.kind, d
                        slot.tex = p.tex        -- nil for every kind but eggs
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
        o.x, o.y, o.kind, o.tex = slot.x, slot.y, slot.kind, slot.tex
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
function M.stepStatic(cfg, due, px, py)
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
    local now = os.clock()
    -- Without a player position there is nothing to measure travel against,
    -- so fall back to the kind's own position, which makes the first pass
    -- happen and later ones wait for the timer.
    px = tonumber(px) or 0.0
    py = tonumber(py) or 0.0
    while checked < #STATIC_KINDS do
        local spec = STATIC_KINDS[rotation]
        rotation = (rotation % #STATIC_KINDS) + 1
        checked = checked + 1
        if wantedKind(cfg, spec) then
            -- THE WHOLE POINT: a kind that was walked recently and near
            -- here is skipped entirely, so a standing player costs no
            -- object-array walks at all.
            if kindIsStale(spec, now, px, py) then
                beginKind(spec, px, py)
                break
            end
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
        if wantedKind(cfg, spec) and kindSeen[spec.kind] == nil then return true end
    end
    return false
end

-- ---------------------------------------------------------------
-- "is the player inside a base camp?" - for the autohide
--
-- ASK THE GAME. It already tracks this exactly, and the answer it keeps
-- is the base's REAL shape and size:
--
--   PalPlayerCharacter
--     .InsideBaseCampCheckComponent      (PalInsideBaseCampCheckComponent)
--       .NowInsideBaseCampID             (Guid - valid only while inside)
--
-- That is not a guess either: it is exactly what the 1.x blueprint read
-- (ExecuteUbergraph_ModActor calls IsValid_Guid on that very property to
-- set its `currentlyInABaseCamp`), which is why the 1.x autohide turned
-- back off the moment you stepped out of the base.
--
-- 2.0-2.2.3 measured a circle around every PalBuildObjectBaseCampPoint
-- instead, and PalBuildObjectBaseCampPoint carries no radius at all, so
-- the radius was a made-up constant - 12000 uu, i.e. a 120 m bubble,
-- several times a real base. That is the "I have to walk very far away
-- before the minimap comes back" bug: the map hid on time and unhid far
-- too late.
--
-- The circle survives only as a fallback for a UE4SS build that cannot
-- read the component, and `campRoute` is logged once so the log says
-- which one is actually in use rather than leaving it a mystery.
-- ---------------------------------------------------------------
local function rawCampComponent(pawn) return pawn.InsideBaseCampCheckComponent end
local function rawCampFlag(comp) return comp:IsInsideBaseCamp() end
local function rawCampID(comp) return comp.NowInsideBaseCampID end
local function rawGuidWords(g) return g.A, g.B, g.C, g.D end

local function noteRoute(name)
    if campRoute == name then return end
    campRoute = name
    guard.log("base camp detection: " .. name)
end

-- FGuid::IsValid() is "any of the four words is non-zero". Returns nil for
-- "could not read it", which is NOT the same as "not in a base".
local function guidIsSet(id)
    local ok, a, b, c, d = pcall(rawGuidWords, id)
    if ok and type(a) == "number" then
        return a ~= 0 or b ~= 0 or c ~= 0 or d ~= 0
    end
    -- Some UE4SS builds hand a struct back as an opaque value whose only
    -- readable form is its text. A zero Guid prints as all zeros and
    -- dashes, so any other hex digit means it is set.
    local s = guard.get(tostring, id)
    if type(s) ~= "string" then return nil end
    local hex = s:match("[%x%-]+")
    if hex == nil or #hex < 32 then return nil end
    return hex:match("[1-9a-fA-F]") ~= nil
end

-- nil = "the game did not answer this tick", not "outside".
local function insideByComponent(pawn)
    if pawn == nil then return nil end
    local comp = guard.get(rawCampComponent, pawn)
    if not guard.alive(comp) then return nil end

    -- A plain bool, if this build reflects one: cheaper and needs no
    -- struct reading at all.
    local flag = asBool(guard.get(rawCampFlag, comp))
    if flag ~= nil then
        noteRoute("IsInsideBaseCamp()")
        return flag
    end

    local id = guard.get(rawCampID, comp)
    if id == nil then return nil end
    local set = guidIsSet(id)
    if set ~= nil then
        noteRoute("NowInsideBaseCampID")
        return set
    end
    return nil
end

-- Called from the movement tick and from the scan tick.
function M.updateProximity(cfg, px, py, pawn)
    if not cfg.autohideInBase then S.campNear = false; return end

    local exact = insideByComponent(pawn)
    if exact ~= nil then
        campExact = true
        S.campNear = exact
        return
    end

    -- No answer this tick - there is no pawn between a death and a
    -- respawn, for one. If the component has EVER answered, hold the last
    -- answer instead of letting the coarse fallback take over and flip
    -- the minimap underneath it.
    if campExact then return end

    noteRoute("radius fallback (component unreadable)")
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

-- test hook
function M.campRoute() return campRoute end

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
    -- `or WHITE` closes a pooled-entry trap rather than fixing a live bug:
    -- every caller passes a tint today, but render.lua only writes the
    -- tint when it is non-nil, so a future kind that omitted one would
    -- inherit the colour of whatever mark last used that pool slot - the
    -- same way a missing `p.tex` once stuck a stale texture on a chest.
    -- WHITE is a single shared table, so render's identity compare still
    -- costs nothing.
    m.size, m.tint, m.isPal = size, tint or WHITE, isPal
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
        n = emit(n, s.x, s.y, s.tex or ICON[s.kind] or ICON.member, isz,
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
        local e = S.npcs[i]
        local x, y = actorLocation(e.actor)
        if x ~= nil then
            -- A portrait is already full colour, so it is drawn as it is; the
            -- beige tint is for the generic marker, which is a silhouette and
            -- needs the colour to say "person" rather than "pal".
            local tex, tint = ICON.member, TINT.npc
            if e.icon then tex, tint = e.icon, WHITE end
            n = emit(n, x, y, tex, isz, tint, ICON.member, false)
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
    -- the collector is a world object and dies with its world; look it up
    -- again rather than reading through a corpse
    if collectorState == 1 then collectorObj = nil; collectorState = 0; collectorTries = 0 end
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