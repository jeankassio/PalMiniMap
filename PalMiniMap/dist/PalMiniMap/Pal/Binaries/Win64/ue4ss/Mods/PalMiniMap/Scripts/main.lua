-- =====================================================================
-- PalMiniMap - companion script (UE4SS Lua)
--   * Configuration menu: opened/closed with F5 (no title-screen auto-open)
--   * Fine zoom: + / - keys (replaces the broken-in-1.0 scroll wheel)
--   * Icon janitor: prevents the FPS decay / ghost icons inherited from
--     the original Paldar (stale pal icon components piling up)
-- =====================================================================

local UEHelpers = require("UEHelpers")
local json = require("json")

local MENU_KEY = Key.F5           -- menu hotkey (change it here if you want)
local MENU_KEY_NAME = "F5"        -- name shown in the menu header
-- NOTE: the blueprint reads this exact filename; the pak is 100% stock bytecode
local CONFIG_PATH = "../../Content/Paks/LogicMods/Paldar.modconfig.json"
local MOD_CLASS_PATH = "/Game/Mods/Paldar/ModActor"

-- User settings backup outside Paks/ (survives mod updates, which replace
-- or wipe the LogicMods folder). Resolve it from this script because recent
-- Palworld UE4SS installs can be relocated outside Pal/Binaries/Win64.
local function getScriptDirectory()
    if debug == nil or debug.getinfo == nil then return nil end
    local ok, info = pcall(debug.getinfo, 1, "S")
    if not ok or type(info) ~= "table" or type(info.source) ~= "string" then
        return nil
    end
    local source = info.source
    if source:sub(1, 1) == "@" then source = source:sub(2) end
    source = source:gsub("\\", "/")
    return source:match("^(.+)/[^/]+$")
end

local SCRIPT_DIRECTORY = getScriptDirectory()
local BACKUP_PATH = SCRIPT_DIRECTORY and (SCRIPT_DIRECTORY .. "/../user_settings.json")
    or "user_settings.json"

-- Default configuration template: the mod package no longer ships the
-- config file; it is created here on first run and NEVER overwritten by
-- updates. New keys from future versions are merged in while preserving
-- the user's values.
local DEFAULTS_JSON = [==[
{"note":"THIS JSON FILE WAS CREATED USING THE `DekModConfigMenu` MOD FOR PALWORLD! DO NOT MANUALLY EDIT THIS FILE UNLESS YOU KNOW WHAT YOU'RE DOING -- USE THE `DekModConfigMenu` MOD INSTEAD <3","meta":{"game":false,"vers":"1.2.6","auth":"T3R3NC3B","desc":"PalMiniMap (based on Paldar by T3R3NC3B) - a minimap radar that displays live pal positions and more. Updated for Palworld 1.0 By Jean Kassio.","link":{"nexus-mod-id":"879","curse-slug":"blueprint-code-mods/paldar-mini-map-radar","donate":""}},"General Settings":{"type":"header","desc":"Configure general settings."},"Enable mod":{"type":"boolean","desc":"Enable/disable the entire Paldar mod.","init":true,"live":true},"Minimap render resolution":{"type":"integer","desc":"Lower numbers for better performance, at the cost of quality.","flag":"","opts":{"min":32,"max":2048,"step":1},"init":512,"live":512},"Minimap opacity":{"type":"integer","desc":"Adjust transparency of the whole minimap.","flag":"","opts":{"min":1,"max":100,"step":1},"init":100,"live":100},"Minimap shape":{"type":"option","desc":"Change minimap shape to circular or square.","opts":["Circle","Square"],"init":"Square","live":"Square"},"Minimap autozoom while moving":{"type":"boolean","desc":"Auto zoom out minimap to different levels when walking, running & flying.","init":true,"live":true},"Minimap rotation lock":{"type":"boolean","desc":"Lock minimap rotation to north, player icon rotates instead.","init":false,"live":false},"Lock all icon rotations to north":{"type":"boolean","desc":"Locks all icons (excluding pals & NPCs) to be upright (north).","init":false,"live":false},"Autohide minimap while in base camps":{"type":"boolean","desc":"Hide minimap while in player base camps.","init":false,"live":false},"Hide collected items from minimap":{"type":"boolean","desc":"Remove chest, egg, note and lifmunk effigy icons from the minimap once you collect them (they disappear from the world).","init":true,"live":true},"Pal Locations":{"type":"header","desc":"Configure settings for displaying Pals."},"Show pal positions":{"type":"boolean","desc":"Show Pals around the player on the minimap.","init":true,"live":true},"Only show shiny pals":{"type":"boolean","desc":"Only shows shiny Pals around the player on the minimap.","init":false,"live":false},"Show pal icons while megazoomed out":{"type":"boolean","desc":"Keep Pal icons visible on the minimap while in megazoomed out mode.","init":false,"live":false},"NPCs and Points of Interest":{"type":"header","desc":"Customize display settings for NPCs and points of interest."},"Show NPC humans":{"type":"boolean","desc":"Show NPC humans on the minimap.","init":true,"live":true},"Show player base camps":{"type":"boolean","desc":"Show player base camps on the minimap.","init":true,"live":true},"Show player death locations":{"type":"boolean","desc":"Show player death locations on the minimap.","init":true,"live":true},"Show other players":{"type":"boolean","desc":"Show other players around the player on the minimap.","init":true,"live":true},"Show dungeons":{"type":"boolean","desc":"Show dungeon locations on the minimap.","init":true,"live":true},"Chests, Notes, and Other":{"type":"header","desc":"Customize display settings for chests, notes, and other entities."},"Show chests":{"type":"boolean","desc":"Show chests around the player on the minimap.","init":true,"live":true},"Show notes":{"type":"boolean","desc":"Show notes around the player on the minimap.","init":true,"live":true},"Show eggs":{"type":"boolean","desc":"Show eggs around the player on the minimap.","init":true,"live":true},"Show fast travel points":{"type":"boolean","desc":"Show fast travel points on the minimap.","init":true,"live":true},"Show skillfruit trees":{"type":"boolean","desc":"Show skillfruit trees around the player on the minimap.","init":true,"live":true},"Show lifmunk effigies":{"type":"boolean","desc":"Show Lifmunk Effigies around the player on the minimap.","init":false,"live":false},"Scan Frequencies":{"type":"header","desc":"Adjust scanning frequencies for various entities."},"Pal rescan rate":{"type":"integer","desc":"How often the radar will scan for new Pals around the player. In seconds.","flag":"","opts":{"min":1,"max":60,"step":1},"init":5,"live":5},"Players rescan frequency":{"type":"integer","desc":"How often the radar will scan for NEW players (not refresh rate of current players). In seconds.","flag":"","opts":{"min":1,"max":60,"step":1},"init":12,"live":12},"Human NPC rescan frequency":{"type":"integer","desc":"How often the radar will scan for NPC humans around the player on the minimap. In seconds.","flag":"","opts":{"min":1,"max":60,"step":1},"init":19,"live":19},"Chest rescan frequency":{"type":"integer","desc":"How often the radar will scan for chests around the player on the minimap. In seconds.","flag":"","opts":{"min":5,"max":60,"step":1},"init":14,"live":14},"Egg rescan frequency":{"type":"integer","desc":"How often the radar will scan for eggs around the player on the minimap. In seconds.","flag":"","opts":{"min":5,"max":60,"step":1},"init":14,"live":14},"Keybinds":{"type":"header","desc":"Customize keyboard shortcuts."},"Megazoom mode toggle keybind":{"type":"keybind","desc":"Set keybind for megazoom out mode toggle. Hold this key and press + or - to fine-zoom the minimap.","init":{"key":"Z","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"Z","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Cycle default minimap positions keybind":{"type":"keybind","desc":"Set keybind for cycling between default minimap positions.","init":{"key":"L","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"L","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Show/hide minimap toggle keybind":{"type":"keybind","desc":"Show/hide minimap toggle keyboard button.","init":{"key":"H","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"H","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Customize minimap keybind":{"type":"keybind","desc":"Set keybind to enter customization mode - move with arrow keys, resize with + and - keys.","init":{"key":"K","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"K","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Use new minimap edit mode size method":{"type":"boolean","desc":"ON: resize minimap in edit mode with mouse scroll wheel (BROKEN on Palworld 1.0). OFF (default): resize with + and - keys (also 9 and 0).","init":false,"live":false},"Minimap capture LOD bias":{"type":"integer","desc":"Renders the minimap terrain with cheaper detail levels. 1 = original, higher = faster. Barely visible on the small map.","flag":"","opts":{"min":1,"max":8,"step":1},"init":3,"live":3}}
]==]

-- The stock blueprint reads these four keybind entries from the modconfig
-- file. Keep the requested F1-F4 layout in the embedded defaults, while
-- migrating only untouched legacy Z/L/H/K values below so custom bindings
-- remain intact.
local KEYBIND_DEFAULTS = {
    { name = "Megazoom mode toggle keybind", key = "F1", legacy = "Z" },
    { name = "Cycle default minimap positions keybind", key = "F2", legacy = "L" },
    { name = "Show/hide minimap toggle keybind", key = "F3", legacy = "H" },
    { name = "Customize minimap keybind", key = "F4", legacy = "K" },
}

local function makeKeybind(key)
    return { key = key, bShift = false, bCtrl = false, bAlt = false, bCmd = false }
end

local function applyKeybindDefaults(defaults)
    for _, spec in ipairs(KEYBIND_DEFAULTS) do
        local entry = defaults[spec.name]
        if type(entry) == "table" then
            entry.init = makeKeybind(spec.key)
            entry.live = makeKeybind(spec.key)
        end
    end
end

local function isLegacyKeybind(value, legacy)
    return type(value) == "table"
        and value.key == legacy
        and value.bShift ~= true
        and value.bCtrl ~= true
        and value.bAlt ~= true
        and value.bCmd ~= true
end

local function migrateKeybinds(config)
    local changed = false
    for _, spec in ipairs(KEYBIND_DEFAULTS) do
        local entry = config[spec.name]
        if type(entry) == "table" then
            for _, field in ipairs({ "init", "live" }) do
                if isLegacyKeybind(entry[field], spec.legacy) then
                    entry[field] = makeKeybind(spec.key)
                    changed = true
                end
            end
        end
    end
    return changed
end

local ZOOM_STEP = 500.0           -- zoom change per +/- key press
local ZOOM_MIN, ZOOM_MAX = -7500.0, 15000.0
local ICON_SOFT_CAP = 80          -- above this many pal icons, force a reset
local CAMP_RESET_SECONDS = 120    -- periodic icon reset while inside a base camp (increased from 90s)

-- WHY THE PAL ICON ARRAY IS THE ONE THAT LEAKS (verified against the decompiled
-- blueprint in _tools/ModActor.patched.json):
--   * every OTHER icon array is rebuilt from scratch by the blueprint itself --
--     each rescan runs a "destroy every component, then Array_Clear" loop
--     (mapIcon_CHESTS, eggicons, notesIcons, EffigyIcons, NPCHumanIcons,
--     DungeonIcons, deathIcons, mapIcon_PLAYERS, fastTravelPointIcons);
--   * SkillFruitTreeIcons / playerCampIcons / enemyCampIcons are never cleared,
--     but they are only ever filled ONCE (the one-shot StartMultiScan chain), so
--     they cannot grow;
--   * palIconMapSMs / trackedPals / monsterMapIDs are the exception: the pal
--     scan re-runs every few seconds, dedupes with Array_Contains(monsterMapIDs)
--     and only ever calls Array_Remove on the KILLED-OR-CAPTURED path. A pal that
--     simply despawns (wanders off, streaming unload, server cull) leaves its
--     icon component in the array FOREVER.
-- So the array grows for as long as the level stays loaded, and every one of the
-- blueprint's per-frame icon loops (rotation lock, visibility, zoom modes) walks
-- it. That is the reported "lag climbs the longer you stay, a loading-screen
-- teleport resets it" -- a teleport destroys the actor and the array with it.
-- Bounding this array is therefore the whole job of the janitor below.
local COUNT_CHECK_MS = 10000      -- cheap pass: just reads 3 array lengths
local ORPHAN_WALK_EVERY = 9       -- full orphan walk every Nth cheap pass (~90 s)
local CENSUS_SECONDS = 300        -- how often to log the icon census (diagnostics)
-- Anti-churn tuning: earlier builds reset the icon arrays on every janitor
-- pass whenever the counts disagreed. On UE4SS builds where TArray:Empty()
-- is a no-op (some users) the counts never actually change, so the reset
-- fired every 20 s forever -- a mass component destroy that the blueprint
-- immediately rebuilds, i.e. a periodic hitch. These gates stop that.
local COUNT_RESET_COOLDOWN = 30        -- min seconds between desync/overflow resets
local DESYNC_PASSES_BEFORE_RESET = 2   -- ignore a single-pass (mid-rescan) desync
local ACTOR_SCAN_COOLDOWN = 30         -- min seconds between full-UObject actor scans

local NON_GAME_WORLDS = {
    PL_PPSplash = true, PL_Login = true, PL_Title = true,
}

local function log(msg)
    print(string.format("[PalMiniMap] %s\n", msg))
end

-- Run fn, swallowing any error but LOGGING it (so a failure is visible in the
-- UE4SS log instead of silently stopping a feature). Used to wrap every
-- periodic task: one bad pass can never take the loop down, and the next pass
-- runs normally. This is the "if it errors, ignore it and keep going" guard.
local function runGuarded(label, fn)
    local ok, err = pcall(fn)
    if not ok then
        log("ERROR in " .. tostring(label) .. " (ignored, will retry): " .. tostring(err))
    end
    return ok
end

-- ---------------------------------------------------------------
-- Small safety helpers
-- ---------------------------------------------------------------
local function isAlive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
end

-- UE4SS may return a fresh Lua wrapper each time a UObject property is read,
-- so userdata identity is not stable enough for caches. FullName is stable
-- for the lifetime of the world and avoids reapplying expensive widget state
-- every second.
local function objectKey(obj)
    if obj == nil then return nil end
    local ok, name = pcall(function() return obj:GetFullName() end)
    if ok and name ~= nil then return tostring(name) end
    local okn, fname = pcall(function() return obj:GetFName():ToString() end)
    if okn and fname ~= nil then return tostring(fname) end
    return nil
end

local function currentWorldName()
    local ok, w = pcall(UEHelpers.GetWorld)
    if not ok or not isAlive(w) then return nil end
    local okn, name = pcall(function() return w:GetFName():ToString() end)
    if not okn then return nil end
    return name
end

local function arrayNum(arr)
    local ok, n = pcall(function() return arr:GetArrayNum() end)
    if ok and type(n) == "number" then return n end
    local ok2, n2 = pcall(function() return #arr end)
    if ok2 and type(n2) == "number" then return n2 end
    return nil
end

-- ---------------------------------------------------------------
-- ModActor lookup (the minimap blueprint actor)
--
-- FindAllOf walks the entire UObject array (hundreds of thousands of
-- objects in a loaded world), so it MUST NOT run on a timer. We cache
-- the actor and only re-scan when the cache is empty or the cached actor
-- died (world change clears it explicitly).
-- ---------------------------------------------------------------
local cachedActor = nil
local lastActorScan = 0.0   -- throttles FindAllOf when the actor is absent

-- Crash guard: right after a level loads, the minimap blueprint actor is still
-- running its BeginPlay -- its widget, dynamic material and render target do not
-- exist yet. Reading/writing its reflected fields (or its widget's children) in
-- that window can HARD-CRASH the game, and a native crash is NOT catchable by
-- pcall/runGuarded (which is why the log just stopped with no Lua error).
-- So we refuse to hand the actor to anyone until it has had time to settle.
local ACTOR_TOUCH_GRACE = 8.0   -- seconds after a world change before touching it
-- armed from script load too: the 3 s loops can fire before the first world tick
local actorGraceUntil = os.clock() + ACTOR_TOUCH_GRACE

local function findModActor()
    local ok, all = pcall(FindAllOf, "ModActor_C")
    if not ok or not all then return nil end
    for _, actor in ipairs(all) do
        local okc, match = pcall(function()
            return actor:IsValid()
                and string.find(actor:GetClass():GetFullName(), MOD_CLASS_PATH, 1, true) ~= nil
        end)
        if okc and match then return actor end
    end
    return nil
end

local function getModActor()
    -- single choke point: while the freshly spawned actor is still initialising,
    -- nobody (worldTick, janitor, sweeps, menu) gets a reference to it.
    if os.clock() < actorGraceUntil then return nil end
    if isAlive(cachedActor) then return cachedActor end
    -- FindAllOf walks the whole UObject array (a multi-ms game-thread stall).
    -- When the actor genuinely isn't present yet, don't re-scan on every call
    -- (janitor, zoom keys, menu) -- that turned into a hitch every 20 s for
    -- users whose actor never resolved. Retry at most once per cooldown.
    local now = os.clock()
    if (now - lastActorScan) < ACTOR_SCAN_COOLDOWN then return nil end
    lastActorScan = now
    cachedActor = findModActor()
    return cachedActor
end

local applyMinimapVisualSettings
local applyEditModeLocalization

local function pokeModActor()
    local actor = getModActor()
    if actor then
        pcall(function() actor:LoadSettingsFromJson() end)
        if applyMinimapVisualSettings then
            -- LoadSettingsFromJson runs for every menu edit. Let the visual
            -- cache decide whether opacity/shape really changed; forcing this
            -- path rebuilds the render-target binding for unrelated options.
            pcall(applyMinimapVisualSettings, actor, false)
        end
        if applyEditModeLocalization then
            pcall(applyEditModeLocalization, actor, false)
        end
    end
end

-- Live minimap quality: the blueprint captures the top-down scene into
-- `currentTextureTarget` every frame; that render is the dominant GPU cost.
-- The blueprint creates the target once (at spawn, from S_MinimapRenderResolution)
-- and never resizes it, so to change quality live we resize the target here.
-- Safe because we leave the blueprint's every-frame capture untouched: the next
-- frame simply re-renders into the smaller target (no blank map).
local function applyRenderQuality(res)
    local actor = getModActor()
    if not actor then return end
    if type(res) ~= "number" or res < 32 then return end
    res = math.floor(res + 0.5)
    pcall(function()
        local rt = actor.currentTextureTarget
        if rt and rt:IsValid() then
            local krl = StaticFindObject("/Script/Engine.Default__KismetRenderingLibrary")
            krl:ResizeRenderTarget2D(rt, res, res)
            log(string.format("minimap render target resized to %dx%d", res, res))
        end
    end)
end

-- ---------------------------------------------------------------
-- Config: read once, cache in memory (the mod's blueprint reads the
-- same file - concurrent re-reads can hit a partial read)
-- ---------------------------------------------------------------
local configCache = nil
local lastGoodConfig = nil   -- survives a failed re-read so the menu can still open

local function readConfig()
    if configCache then return configCache end
    local f = io.open(CONFIG_PATH, "r")
    if not f then
        log("ERROR: could not open " .. CONFIG_PATH)
        return nil
    end
    local text = f:read("*a")
    f:close()
    local ok, cfg = pcall(json.decode, text)
    if not ok then
        log(string.format("ERROR: failed to decode JSON (len=%d): %s",
                          #tostring(text), tostring(cfg)))
        return nil
    end
    configCache = cfg
    lastGoodConfig = cfg
    return cfg
end

-- read a live boolean option straight from the cached config
local function cfgBool(key, default)
    local cfg = readConfig()
    if cfg then
        local e = cfg[key]
        if type(e) == "table" and type(e.live) == "boolean" then return e.live end
    end
    return default
end

local function cfgNumber(key, default)
    local cfg = readConfig()
    if cfg then
        local e = cfg[key]
        if type(e) == "table" and type(e.live) == "number" then return e.live end
    end
    return default
end

-- Cheaper minimap capture: the stock blueprint renders the whole scene
-- top-down into the minimap EVERY frame (a second full render each frame) --
-- the main source of the long-standing stutter when moving the camera. We
-- can't remove that render (that path blanked the map before), but we can make
-- it cheaper by biasing its mesh LODs: distant/near meshes use lower-detail
-- LODs in the capture only. Barely visible on the small map, no blank risk.
-- The factor comes from the "Minimap capture LOD bias" config entry (plain
-- property write, self-gated: reapplied only when the actor or value changes).
local captureLODAppliedFor = nil
local captureLODAppliedValue = nil

local function applyCaptureLOD(actor)
    if actor == nil or not isAlive(actor) then return end
    local factor = cfgNumber("Minimap capture LOD bias", 2)
    if type(factor) ~= "number" then factor = 2 end
    if factor < 1 then factor = 1 elseif factor > 8 then factor = 8 end
    factor = factor + 0.0
    if captureLODAppliedFor == actor and captureLODAppliedValue == factor then return end
    pcall(function()
        local cap = actor.sceneCaptureCompREF
        if cap and cap:IsValid() then
            cap.LODDistanceFactor = factor
            captureLODAppliedFor = actor
            captureLODAppliedValue = factor
            log(string.format("minimap capture LOD factor set to %.1f (cheaper per-frame render)",
                              factor))
        end
    end)
end

local function writeFileTo(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    -- write can raise (disk full / handle yanked); never let that propagate
    -- into script load or a menu commit
    local ok = pcall(function() f:write(text) end)
    f:close()
    return ok
end

-- The blueprint reads CONFIG_PATH on its own schedule; an in-place write can
-- be observed half-written ("READ SETTINGS FROM JSON FAILED"). Write to a
-- sibling temp file and swap it in so readers only ever see complete JSON.
local function writeFileAtomic(path, text)
    local tmp = path .. ".tmp"
    if not writeFileTo(tmp, text) then
        return writeFileTo(path, text)   -- temp not writable: direct write
    end
    os.remove(path)                      -- Windows rename won't overwrite
    if os.rename(tmp, path) then return true end
    os.remove(tmp)
    return writeFileTo(path, text)
end

local function writeConfig(cfg)
    local ok, text = pcall(json.encode, cfg)
    if not ok then
        log("ERROR: failed to encode JSON: " .. tostring(text))
        return false
    end
    if not writeFileAtomic(CONFIG_PATH, text) then
        log("ERROR: could not write " .. CONFIG_PATH)
        return false
    end
    -- mirror to the backup location so settings survive mod updates
    if not writeFileTo(BACKUP_PATH, text) then
        log("warning: could not write settings backup " .. BACKUP_PATH)
    end
    return true
end

local function readJsonFile(path)
    local f = io.open(path, "r")
    if not f then return nil end
    local text = f:read("*a")
    f:close()
    local ok, cfg = pcall(json.decode, text)
    if ok and type(cfg) == "table" then return cfg end
    return nil
end

-- Options left over from removed experiments (manual capture / capture
-- throttling). Nothing reads them anymore; purge them from existing config
-- files so config tools stop showing dead switches.
local REMOVED_KEYS = {
    "Minimap image quality %",
    "Reduce captures when idle",
    "Minimap capture FPS cap",
}

-- Runs once at startup, before any world (and the mod's blueprint) reads
-- the config file: creates it from defaults on first run, restores it from
-- the backup after a mod update wiped it, and merges in keys added by
-- newer versions without touching the user's values.
local function ensureConfig()
    local okd, defaults = pcall(json.decode, DEFAULTS_JSON)
    if not okd then
        log("ERROR: embedded defaults failed to parse: " .. tostring(defaults))
        return
    end
    applyKeybindDefaults(defaults)
    local cur = readJsonFile(CONFIG_PATH)
    local restored = false
    if cur == nil then
        cur = readJsonFile(BACKUP_PATH)
        if cur ~= nil then
            restored = true
            log("settings file missing - restored from backup")
        end
    end
    local changed = false
    if cur == nil then
        cur = defaults
        changed = true
        log("first run - created default settings file")
    else
        for k, v in pairs(defaults) do
            if cur[k] == nil then
                cur[k] = v
                changed = true
                log("new option added by update: '" .. tostring(k) .. "'")
            end
        end
        for _, k in ipairs(REMOVED_KEYS) do
            if cur[k] ~= nil then
                cur[k] = nil
                changed = true
                log("obsolete option removed: '" .. k .. "'")
            end
        end
        if migrateKeybinds(cur) then
            changed = true
            log("migrated untouched legacy keybinds to F1-F4")
        end
        if type(cur.meta) == "table" and type(defaults.meta) == "table"
           and cur.meta.vers ~= defaults.meta.vers then
            cur.meta.vers = defaults.meta.vers
            changed = true
        end
    end
    configCache = cur
    if changed or restored then
        writeConfig(cur)
    else
        -- keep the backup in sync even when nothing changed
        local oke, text = pcall(json.encode, cur)
        if oke then writeFileTo(BACKUP_PATH, text) end
    end
end

-- The blueprint applies these values only during actor initialization. The
-- config menu can change them later, so refresh both the widget and the
-- actor fields explicitly whenever the live values change or a new world
-- creates a new widget.
local visualActorKey = nil
local visualWidgetKey = nil
local visualActorOpacity = nil
local visualActorSquare = nil
local visualOpacity = nil
local visualSquare = nil

applyMinimapVisualSettings = function(actor, force)
    if actor == nil or not isAlive(actor) then return end
    local cfg = readConfig()
    if not cfg then return end

    local opacityValue = cfgNumber("Minimap opacity", 100)
    if opacityValue < 1 then opacityValue = 1 end
    if opacityValue > 100 then opacityValue = 100 end
    local opacity = opacityValue / 100.0
    local shape = cfg["Minimap shape"]
    local square = type(shape) == "table" and shape.live == "Square"
    local widget = nil
    pcall(function() widget = actor.mapWidget end)
    local actorKey = objectKey(actor)
    local widgetKey = objectKey(widget)
    local actorChanged = actorKey ~= visualActorKey or widgetKey ~= visualWidgetKey

    -- Keep the reflected settings in sync even if the widget is not ready,
    -- but do not write identical reflected values every second.
    if force or actorChanged or visualActorOpacity ~= opacity then
        local ok = pcall(function() actor.S_MinimapOpacity = opacity end)
        if ok then visualActorOpacity = opacity end
    end
    if force or actorChanged or visualActorSquare ~= square then
        local ok = pcall(function() actor.S_SquareMinimap = square end)
        if ok then visualActorSquare = square end
    end

    if widget == nil or not isAlive(widget) then
        visualActorKey, visualWidgetKey = actorKey, widgetKey
        return
    end

    if force or actorChanged or visualOpacity ~= opacity then
        local ok, err = pcall(function() widget:SetMinimapOpacity(opacity) end)
        if ok then
            visualOpacity = opacity
            log(string.format("minimap opacity applied: %d%%", math.floor(opacityValue + 0.5)))
        else
            log("warning: SetMinimapOpacity failed: " .. tostring(err))
        end
    end

    if force or actorChanged or visualSquare ~= square then
        -- setRT dereferences the dynamic material; passing a not-yet-created
        -- one crashes natively (uncatchable), so only call it once it exists.
        local dyn = nil
        pcall(function() dyn = actor.dynMat end)
        if dyn ~= nil and isAlive(dyn) then
            local ok, err = pcall(function() widget:setRT(dyn, square) end)
            if ok then
                visualSquare = square
                log("minimap shape applied: " .. (square and "Square" or "Circle"))
            else
                log("warning: setRT failed: " .. tostring(err))
            end
        end
    end
    visualActorKey, visualWidgetKey = actorKey, widgetKey
end

-- ---------------------------------------------------------------
-- Teleport / streaming guard
--
-- A fast travel keeps the same UWorld: only streaming sublevels are swapped,
-- so worldName never changes, RegisterLoadMapPreHook never fires, and the
-- cached ModActor stays valid. Meanwhile every actor an icon is attached to is
-- destroyed and recreated. Any pass that dereferences an icon's target actor
-- during that window can hit freed memory, and a native access violation is
-- not catchable from Lua -- so instead of trying to survive it, we stay out of
-- it. Two signals, both cheap:
--   * no player pawn -> a loading screen / respawn is in progress;
--   * the pawn moved further between checks than anything in the game can
--     travel -> we just teleported, and the destination is still streaming in.
-- Either one silences the icon passes for TELEPORT_QUIET_SECONDS.
-- ---------------------------------------------------------------
local TELEPORT_QUIET_SECONDS = 12
local TELEPORT_JUMP_UU = 20000        -- 200 m between checks; unreachable normally
local quietUntil = 0.0
local lastPawnX, lastPawnY, lastPawnZ = nil, nil, nil

-- NOT UEHelpers.GetPlayerController(): that runs FindAllOf("PlayerController"),
-- a full walk of the UObject array, on every single call. This gate runs every
-- janitor pass, so it goes straight through UGameplayStatics instead -- one
-- native call, using the minimap actor we already hold as the world context.
local gameplayStatics = nil
local pawnQueryBroken = false

-- Returns pawn, queryWorked. The second value matters: "there is no pawn" and
-- "this build cannot tell me" must not be treated the same, or a reflection
-- failure would silence every icon pass forever instead of just this one.
local function getPlayerPawn(worldContext)
    if not isAlive(worldContext) then return nil, false end
    local pawn = nil
    local ok = pcall(function()
        if gameplayStatics == nil or not gameplayStatics:IsValid() then
            gameplayStatics = StaticFindObject("/Script/Engine.Default__GameplayStatics")
        end
        if gameplayStatics == nil then error("GameplayStatics unavailable") end
        pawn = gameplayStatics:GetPlayerPawn(worldContext, 0)
    end)
    if not ok then
        if not pawnQueryBroken then
            pawnQueryBroken = true
            log("warning: the player pawn cannot be queried on this build; " ..
                "the teleport guard is off and the icon passes run unguarded")
        end
        return nil, false
    end
    if isAlive(pawn) then return pawn, true end
    return nil, true
end

local function beQuiet(reason)
    quietUntil = os.clock() + TELEPORT_QUIET_SECONDS
    if reason then
        log("pausing icon maintenance for " .. TELEPORT_QUIET_SECONDS .. "s: " .. reason)
    end
end

-- Runs on the world tick: watches for the position jump. Kept separate from the
-- gate below so the jump is sampled on a steady cadence.
local function watchForTeleport(worldContext)
    local pawn = getPlayerPawn(worldContext)
    if pawn == nil then
        lastPawnX, lastPawnY, lastPawnZ = nil, nil, nil
        return
    end
    local x, y, z
    local ok = pcall(function()
        local loc = pawn:K2_GetActorLocation()
        x, y, z = loc.X, loc.Y, loc.Z
    end)
    if not ok or type(x) ~= "number" then return end
    if lastPawnX ~= nil then
        local dx, dy, dz = x - lastPawnX, y - lastPawnY, z - lastPawnZ
        if (dx * dx + dy * dy + dz * dz) > (TELEPORT_JUMP_UU * TELEPORT_JUMP_UU) then
            beQuiet("teleport detected")
        end
    end
    lastPawnX, lastPawnY, lastPawnZ = x, y, z
end

-- Gate for anything that dereferences icon components or their target actors.
-- `worldContext` is the minimap actor, which every caller already has.
local function iconWorkAllowed(worldContext)
    if os.clock() < quietUntil then return false end
    local pawn, queryWorked = getPlayerPawn(worldContext)
    if queryWorked and pawn == nil then
        -- genuinely no pawn: loading screen, death respawn, world transition
        beQuiet(nil)
        return false
    end
    return true   -- we have a pawn, or we simply cannot tell
end

-- ---------------------------------------------------------------
-- Icon janitor: destroys orphaned pal icon components and resets the
-- tracking arrays when they desync or grow too large. This is the fix
-- for the "FPS drops after staying in camp" issue from original Paldar.
-- ---------------------------------------------------------------
local emptyUnsupportedWarned = false
local lastCampReset = 0.0
local janitorPassCount = 0
local lastCountReset = 0.0        -- last desync/overflow reset (cooldown gate)
local desyncStreak = 0           -- consecutive passes seen desynced
local countResetsDisabled = false -- set once we learn Empty() can't clear arrays
local worldName = ""             -- current world; updated by the world tick loop.
                                 -- MUST be declared here (above janitorPass /
                                 -- hideCollectedObtainables) so
                                 -- their "NON_GAME_WORLDS[worldName]" guard reads this
                                 -- upvalue and not a nil global.

-- Destroying a component while the blueprint's arrays still reference it is
-- the v1.2.2 use-after-free, so the reset runs in the only safe order:
-- 1) collect the live components into a Lua table, 2) clear the tracking
-- arrays, 3) destroy the collected components ONLY if the arrays really
-- cleared (we still hold references; the blueprint no longer does).
local function collectIconComponents(actor, arrName)
    local comps = {}
    pcall(function()
        actor[arrName]:ForEach(function(_, elem)
            pcall(function()
                local comp = elem:get()
                if comp and comp:IsValid() then
                    comps[#comps + 1] = comp
                end
            end)
        end)
    end)
    return comps
end

-- Empty an array property and PROVE it worked.
--
-- v1.2.4 and earlier only checked that `arr:Empty()` did not raise, which is a
-- much weaker claim than "the array is now empty": on a UE4SS build where
-- Empty() runs but does nothing, the old code went on to destroy every
-- component while the blueprint still held them -- the intermittent
-- "alt-tab and it crashes" report. And on builds where Empty() is missing
-- entirely the call raised, resets were disabled forever, and the pal icon
-- array then grew without any bound at all -- the progressive lag report.
-- Both failure modes now end in an honest, logged answer.
--
-- Returns true  = the array exists and is now empty (safe to destroy)
--         false = the array exists but could not be cleared (destroy NOTHING)
--         nil   = the property is not on this blueprint (ignore it)
local function countOf(actor, name)
    local n = nil
    pcall(function() n = arrayNum(actor[name]) end)
    return n
end

local clearStrategyLogged = false

local function clearArrayVerified(actor, name)
    local before = countOf(actor, name)
    if before == nil then return nil end
    if before == 0 then return true end

    -- 1) the normal path
    local emptyRan = pcall(function() actor[name]:Empty() end)
    if emptyRan and countOf(actor, name) == 0 then
        if not clearStrategyLogged then
            clearStrategyLogged = true
            log("icon arrays are cleared with TArray:Empty()")
        end
        return true
    end

    -- 2) Empty() is missing or is a no-op on this UE4SS build: overwrite the
    --    whole property with an empty array instead. Guarded and verified the
    --    same way -- if it does not take either, we simply never destroy.
    local assignRan = pcall(function() actor[name] = {} end)
    if assignRan and countOf(actor, name) == 0 then
        if not clearStrategyLogged then
            clearStrategyLogged = true
            log("TArray:Empty() does not work on this UE4SS build; " ..
                "icon arrays are cleared by property assignment instead")
        end
        return true
    end

    return false
end

local function resetPalIcons(actor, reason)
    -- Probe with the component array first: while it is untouched every array
    -- is still consistent with the others, so bailing out here is always safe.
    local comps = collectIconComponents(actor, "palIconMapSMs")
    local state = clearArrayVerified(actor, "palIconMapSMs")
    if state ~= true then
        if not emptyUnsupportedWarned then
            emptyUnsupportedWarned = true
            log("WARNING: the pal icon array cannot be cleared on this UE4SS build " ..
                (state == nil and "(property missing)" or "(Empty() and assignment both refused)") ..
                " -- icon resets are disabled because destroying icons the blueprint " ..
                "still references would crash. Orphaned icons are only quiesced, so " ..
                "expect the minimap to get gradually heavier until you fast travel.")
        end
        return false
    end

    -- The pal icon array is gone, so the id/actor arrays MUST go too or the
    -- blueprint will never re-add the pals it thinks it is still tracking.
    clearArrayVerified(actor, "trackedPals")
    clearArrayVerified(actor, "monsterMapIDs")

    local destroyed = 0
    for _, comp in ipairs(comps) do
        local ok = pcall(function()
            if comp:IsValid() then comp:K2_DestroyComponent(actor) end
        end)
        if ok then destroyed = destroyed + 1 end
    end
    log(string.format("pal icon reset (%s): arrays cleared, %d/%d components destroyed",
                      reason, destroyed, #comps))
    return true
end

-- An orphaned icon (attach parent gone) means its world actor despawned: the
-- pal left/died or the collectible was picked up, so the icon must leave the
-- minimap. Hide it, do NOT destroy it: K2_DestroyComponent leaves a dangling
-- entry inside the blueprint's array, and IsValid() keeps returning true until
-- GC runs -- destroying it again on the next pass was the v1.2.2
-- use-after-free hard crash. SetVisibility is idempotent and keeps the arrays
-- consistent; resetPalIcons above still frees pal icons for real because it
-- clears the arrays first. Returns true when it hid something.
-- An icon whose target actor is gone can never be shown or moved meaningfully
-- again, but it stays in the blueprint's array and every per-frame icon loop
-- keeps walking it. Hiding it drops its render proxy; switching its tick off as
-- well makes it as close to free as a component we are not allowed to remove
-- can get. Both writes are idempotent.
local function quiesceComponent(comp)
    pcall(function() comp:SetVisibility(false, true) end)
    pcall(function() comp:SetComponentTickEnabled(false) end)
    pcall(function() comp:SetHiddenInGame(true, true) end)
end

local function hideIfOrphaned(elem)
    local comp = elem:get()
    if not (comp and comp:IsValid()) then return false end
    local parent = comp:GetAttachParent()
    if parent ~= nil and parent:IsValid() then return false end  -- still in world
    local visible = nil
    pcall(function() visible = comp:IsVisible() end)
    if visible == false then return false end   -- already hidden: nothing to do
    quiesceComponent(comp)
    return true
end

-- Every icon array the blueprint maintains. Only used for the periodic census
-- below: if a build ever does grow an array we do not expect, the user's
-- UE4SS.log says so outright instead of us guessing from a lag report.
local ALL_ICON_ARRAYS = {
    "palIconMapSMs", "trackedPals", "monsterMapIDs", "palIconNumbers",
    "mapIcon_CHESTS", "eggicons", "notesIcons", "EffigyIcons",
    "SkillFruitTreeIcons", "fastTravelPointIcons", "DungeonIcons",
    "enemyCampIcons", "playerCampIcons", "NPCHumanIcons", "deathIcons",
    "mapIcon_PLAYERS", "killedOrCaptured",
}

local lastCensus = 0.0

local function logIconCensus(actor)
    local parts, total = {}, 0
    for _, name in ipairs(ALL_ICON_ARRAYS) do
        local n = countOf(actor, name)
        if type(n) == "number" then
            total = total + n
            if n > 0 then parts[#parts + 1] = string.format("%s=%d", name, n) end
        end
    end
    log(string.format("icon census: %d tracked entries | %s", total, table.concat(parts, " ")))
end

-- Cheap pass (every COUNT_CHECK_MS): only reads three array lengths, so it can
-- run often and cap the pal icon array quickly. The expensive part -- walking
-- the array through UE4SS reflection to find orphans -- still runs rarely,
-- because every walk is a chance to dereference an entry the blueprint just
-- destroyed (a native access violation pcall cannot catch).
local function janitorPass()
    if worldName == "" or NON_GAME_WORLDS[worldName] then return end
    local actor = getModActor()
    if not actor then return end

    local n1, n2, n3
    local okn = pcall(function()
        n1 = arrayNum(actor.trackedPals)
        n2 = arrayNum(actor.monsterMapIDs)
        n3 = arrayNum(actor.palIconMapSMs)
    end)
    if not okn or n1 == nil or n2 == nil or n3 == nil then return end

    local now = os.clock()

    if (now - lastCensus) >= CENSUS_SECONDS then
        lastCensus = now
        pcall(logIconCensus, actor)
    end

    local desynced = (n1 ~= n2 or n2 ~= n3)

    if desynced then desyncStreak = desyncStreak + 1 else desyncStreak = 0 end

    -- Reading the array lengths above is safe (no element is dereferenced).
    -- Everything past this point touches the components themselves, so it waits
    -- until the world is settled again.
    if not iconWorkAllowed(actor) then return end

    if not countResetsDisabled then
        local coolOk = (now - lastCountReset) >= COUNT_RESET_COOLDOWN

        if n3 > ICON_SOFT_CAP and coolOk then
            lastCountReset = now
            local cleared = resetPalIcons(actor, string.format("icon count %d > %d", n3, ICON_SOFT_CAP))
            if not cleared then countResetsDisabled = true end
            desyncStreak = 0
            return
        end

        if desynced and desyncStreak >= DESYNC_PASSES_BEFORE_RESET and coolOk then
            lastCountReset = now
            local cleared = resetPalIcons(actor, string.format("desync %d/%d/%d", n1, n2, n3))
            if not cleared then countResetsDisabled = true end
            desyncStreak = 0
            return
        end

        local inCamp = false
        pcall(function() inCamp = actor.currentlyInABaseCamp == true end)
        if inCamp and (now - lastCampReset) > CAMP_RESET_SECONDS and n3 > 0 then
            lastCampReset = now
            lastCountReset = now   -- share the cooldown: never two resets back to back
            if not resetPalIcons(actor, "base camp periodic") then
                countResetsDisabled = true
            end
            return
        end
    end

    janitorPassCount = janitorPassCount + 1
    if n3 > 0 and (janitorPassCount % ORPHAN_WALK_EVERY) == 0 then
        pcall(function()
            actor.palIconMapSMs:ForEach(function(_, elem)
                pcall(hideIfOrphaned, elem)
            end)
        end)
    end
end

-- ---------------------------------------------------------------
-- "Only show what's actually in the world": when a collectible (chest,
-- egg, note, lifmunk effigy) is picked up, its world actor despawns.
-- Each minimap icon is a StaticMeshComponent attached to that actor's
-- root, so a collected item leaves an ORPHANED icon (its attach parent
-- is gone).
--
-- REMOVED IN v1.2.6 -- there used to be a `sweepCollectedIcons()` here, on a
-- 20 s loop, walking eggicons / EffigyIcons / notesIcons / mapIcon_CHESTS to
-- hide those orphans. Two reasons it is gone:
--
--  1. It was redundant. The decompiled blueprint rebuilds all four of those
--     arrays from scratch on every rescan ("destroy every component in a loop,
--     then Array_Clear", every ~14 s per the rescan-frequency settings). A
--     collected item despawns, so the next rescan simply does not re-add its
--     icon. The sweep only made that a few seconds faster.
--  2. It crashed the game. Those icons attach to actors that live in STREAMING
--     sublevels, and a fast travel tears those down wholesale. Walking the
--     arrays during the teardown dereferences components whose target actor is
--     already gone -- a native access violation pcall cannot catch. The
--     "crashed fast travelling between bases" report landed on exactly one of
--     these ticks: last sweep logged at 11:27:12.554, loop period 20 s,
--     EXCEPTION_ACCESS_VIOLATION reading 0x1b at 11:27:32 with a callstack
--     made entirely of UE4SS Lua frames called from the game thread.
--
-- Fast travel is NOT a LoadMap in Palworld -- the UWorld, worldName and our
-- cached ModActor all survive it -- so RegisterLoadMapPreHook never fires and
-- none of the world-change guards below help. That is why this had to go.
-- ---------------------------------------------------------------

-- ---------------------------------------------------------------
-- Collected Lifmunk Effigies and notes: unlike chests and eggs, a
-- collected effigy's or note's actor NEVER despawns (it stays in the
-- world for other players; the game only hides its mesh for you and
-- sets bPickedInClient on the actor). The orphan sweep above can
-- therefore never catch them, so their icons are hidden directly from
-- that flag. Rides the same "Hide collected items from minimap" toggle.
--
-- RELOG: bPickedInClient is only true in the session that picked the
-- item -- after quitting and reloading it reads false again, yet the
-- game itself keeps the collected actor invisible in world (that is why
-- the effigy no longer shows there). So the hidden-in-world state of
-- the actor is the persistent truth, read every pass straight from game
-- state: actor bHidden, or every one of its own static meshes hidden.
-- An uncollected item always has a visible mesh (you can see it in the
-- world), so this cannot hide a live icon. No files, no history.
-- ---------------------------------------------------------------

-- TArray elements can arrive wrapped on some UE4SS builds
local function elemObject(v)
    if v == nil then return nil end
    local ok = pcall(function() return v:IsValid() end)
    if ok then return v end
    local okLower, inner = pcall(function() return v:get() end)
    if okLower and inner ~= nil then return inner end
    return v
end

-- reflected bools can arrive wrapped too; `== true` on the wrapper
-- would read every collected effigy as not collected
local function asBool(value)
    if type(value) == "boolean" then return value end
    if type(value) == "number" then return value ~= 0 end
    if value == nil then return nil end
    local ok, inner = pcall(function() return value:get() end)
    if ok then
        if type(inner) == "boolean" then return inner end
        if type(inner) == "number" then return inner ~= 0 end
    end
    return nil
end

-- icon array -> class-name hint for the actor the icon attaches to
local PERSISTENT_COLLECTIBLES = {
    { iconArray = "EffigyIcons", classHint = "Relic", label = "effigies" },
    { iconArray = "notesIcons",  classHint = "Note",  label = "notes" },
}

local smcClass = nil   -- cached /Script/Engine.StaticMeshComponent class

-- True when the game itself is hiding this actor in the world -- the
-- persistent "already collected" signal that survives relogs. Two forms,
-- depending on how the game hid it: the whole actor (SetActorHiddenInGame ->
-- bHidden) or its own static mesh components (SetVisibility per component).
-- Every read is guarded; any failure just reports "not hidden".
local function actorHiddenInWorld(owner)
    local hidden = nil
    pcall(function() hidden = asBool(owner.bHidden) end)
    if hidden == true then return true end
    local result = false
    pcall(function()
        if smcClass == nil or not smcClass:IsValid() then
            smcClass = StaticFindObject("/Script/Engine.StaticMeshComponent")
        end
        if smcClass == nil then return end
        local comps = owner:K2_GetComponentsByClass(smcClass)
        local n = comps and #comps or 0
        if n == 0 then return end   -- no meshes to judge by: assume visible
        for i = 1, n do
            local c = elemObject(comps[i])
            if c and c:IsValid() and c:IsVisible() then return end
        end
        result = true   -- has meshes and every one of them is hidden
    end)
    return result
end

local function processCollectible(comp, enabled, classHint)
    if not (comp and comp:IsValid()) then return 0, 0 end
    local visible = comp:IsVisible()

    if not enabled then
        if not visible then
            comp:SetVisibility(true, true)
            return 0, 1
        end
        return 0, 0
    end

    if not visible then return 0, 0 end

    local parent = comp:GetAttachParent()
    if parent and parent:IsValid() then
        local owner = parent:GetOwner()
        if owner and owner:IsValid() then
            -- GetName() é brutalmente mais rápido e leve que GetFullName()
            local name = owner:GetClass():GetName()
            if string.find(name, classHint, 1, true) then
                -- picked this session (flag), or picked in a previous session
                -- (the game keeps the actor hidden in world after a relog)
                if asBool(owner.bPickedInClient) == true
                   or actorHiddenInWorld(owner) then
                    comp:SetVisibility(false, true)
                    return 1, 0
                end
            end
        end
    end
    return 0, 0
end

local function hideCollectedObtainables()
    if worldName == "" or NON_GAME_WORLDS[worldName] then return end
    local actor = getModActor()
    if not actor then return end
    -- walks icons AND their target actors: the single deepest dereference chain
    -- in this script, so it never runs while the world is streaming
    if not iconWorkAllowed(actor) then return end
    local enabled = cfgBool("Hide collected items from minimap", true)
    
    for _, entry in ipairs(PERSISTENT_COLLECTIBLES) do
        local hidden, restored = 0, 0
        pcall(function()
            local arr = actor[entry.iconArray]
            local n = arrayNum(arr) or 0
            local classHint = entry.classHint
            for i = 1, n do
                local comp = elemObject(arr[i])
                local ok, h, r = pcall(processCollectible, comp, enabled, classHint)
                if ok then
                    hidden = hidden + (h or 0)
                    restored = restored + (r or 0)
                end
            end
        end)
        if hidden > 0 or restored > 0 then
            log(string.format("collected %s: %d hidden, %d shown", entry.label, hidden, restored))
        end
    end
end

-- ---------------------------------------------------------------
-- Fine zoom with + / - (scroll wheel is dead on Palworld 1.0)
-- ---------------------------------------------------------------
local menuOpen = false  -- declared early; used by zoom guard

local function zoomStep(delta)
    if menuOpen then return end
    local wname = currentWorldName()
    if wname == nil or NON_GAME_WORLDS[wname] then return end
    local actor = getModActor()
    if not actor then return end
    pcall(function()
        local widget = actor.mapWidget
        if widget and widget:IsValid() and widget.editMode then
            return -- edit mode: +/- resize the minimap instead (blueprint side)
        end
        local z = actor.ZoomOffset + delta
        if z < ZOOM_MIN then z = ZOOM_MIN end
        if z > ZOOM_MAX then z = ZOOM_MAX end
        actor.ZoomOffset = z
    end)
end

-- + zooms in (same direction as scroll-up did), - zooms out
local function registerZoomKeys()
    local plusKeys  = { "ADD", "OEM_PLUS" }
    local minusKeys = { "SUBTRACT", "OEM_MINUS" }
    for _, k in ipairs(plusKeys) do
        pcall(function()
            RegisterKeyBind(Key[k], function()
                ExecuteInGameThread(function() zoomStep(-ZOOM_STEP) end)
            end)
        end)
    end
    for _, k in ipairs(minusKeys) do
        pcall(function()
            RegisterKeyBind(Key[k], function()
                ExecuteInGameThread(function() zoomStep(ZOOM_STEP) end)
            end)
        end)
    end
end

-- ---------------------------------------------------------------
-- Menu UI
-- ---------------------------------------------------------------
-- The config keys and option values below are part of the persisted modconfig
-- format, so keep them in English. Only the text rendered by this menu is
-- localized.
local MENU_TEXT = {
    en = {
        subtitle = "Minimap configuration",
        help = "[ %s ] close      [ + / - ] fine zoom      scroll for more",
        footer = "Changes are saved and applied instantly.",
    },
    zh = {
        subtitle = "小地图设置",
        help = "[ %s ] 关闭      [ + / - ] 微调缩放      滚动查看更多",
        footer = "更改会立即保存并应用。",
        ["Very Low"] = "极低",
        ["Low"] = "低",
        ["Medium"] = "中",
        ["High"] = "高",
        ["Ultra"] = "极高",
        ["General Settings"] = "常规设置",
        ["Minimap opacity"] = "小地图不透明度",
        ["Minimap quality"] = "小地图质量",
        ["Minimap Square"] = "方形小地图",
        ["Minimap autozoom while moving"] = "移动时自动缩放小地图",
        ["Minimap rotation lock"] = "锁定小地图朝向",
        ["Lock all icon rotations to north"] = "锁定所有图标朝北",
        ["Autohide minimap while in base camps"] = "进入据点时自动隐藏小地图",
        ["Hide collected items"] = "隐藏已收集物品",
        ["Pal Locations"] = "帕鲁位置",
        ["Show pal positions"] = "显示帕鲁位置",
        ["Only show shiny pals"] = "仅显示闪光帕鲁",
        ["Show pal icons while megazoomed out"] = "超远缩放时显示帕鲁图标",
        ["NPCs and Points of Interest"] = "NPC 与兴趣点",
        ["Show NPC humans"] = "显示人类 NPC",
        ["Show player base camps"] = "显示玩家据点",
        ["Show player death locations"] = "显示玩家死亡位置",
        ["Show other players"] = "显示其他玩家",
        ["Show dungeons"] = "显示地下城",
        ["Chests, Notes, and Other"] = "宝箱、手记与其他",
        ["Show chests"] = "显示宝箱",
        ["Show notes"] = "显示手记",
        ["Show eggs"] = "显示帕鲁蛋",
        ["Show fast travel points"] = "显示快速传送点",
        ["Show skillfruit trees"] = "显示技能果树",
        ["Show lifmunk effigies"] = "显示翠叶鼠雕像",
        ["Keybinds (edit in mod config file)"] = "快捷键（请在 Mod 配置文件中修改）",
        ["Megazoom mode toggle keybind"] = "超远缩放模式切换键",
        ["Cycle default minimap positions keybind"] = "切换小地图预设位置键",
        ["Show/hide minimap toggle keybind"] = "显示/隐藏小地图键",
        ["Customize minimap keybind"] = "小地图自定义模式键",
    },
}

local lastMenuCulture = nil
local detectedMenuLanguage = nil
local languageDetectionWarningLogged = false

local function detectMenuLanguage()
    -- Palworld applies language changes on restart, which reloads this script.
    -- Cache the successful lookup so the one-second maintenance pass does not
    -- call into the internationalization library forever.
    if detectedMenuLanguage ~= nil then return detectedMenuLanguage end
    local culture
    local ok, err = pcall(function()
        local library = StaticFindObject(
            "/Script/Engine.Default__KismetInternationalizationLibrary"
        )
        if not isAlive(library) then
            error("KismetInternationalizationLibrary is unavailable")
        end
        culture = library:GetCurrentLanguage()
        if type(culture) ~= "string" then
            culture = culture:ToString()
        end
        if type(culture) ~= "string" or culture == "" then
            error("GetCurrentLanguage returned no culture")
        end
    end)
    if not ok then
        if not languageDetectionWarningLogged then
            languageDetectionWarningLogged = true
            log("language detection failed; using English: " .. tostring(err))
        end
        return "en"
    end

    local language = culture:sub(1, 2):lower() == "zh" and "zh" or "en"
    detectedMenuLanguage = language
    if culture ~= lastMenuCulture then
        lastMenuCulture = culture
        log(string.format("menu language detected: culture=%s; using=%s", culture, language))
    end
    return language
end

local function menuText(language, key)
    local localized = MENU_TEXT[language]
    return (localized and localized[key]) or MENU_TEXT.en[key] or key
end

local EDIT_MODE_TEXT = {
    en = {
        title = "EDIT POSITION",
        help = "[ move with arrow keys ]\n[ resize with + and - keys ]",
    },
    zh = {
        title = "调整位置",
        help = "[ 使用方向键移动 ]\n[ 使用 + 和 - 调整大小 ]",
    },
}

local editTextWidgetKey = nil
local editTextLanguage = nil

applyEditModeLocalization = function(actor, force)
    if actor == nil or not isAlive(actor) then return end
    local widget = nil
    pcall(function() widget = actor.mapWidget end)
    if widget == nil or not isAlive(widget) then return end
    local language = detectMenuLanguage()
    local widgetKey = objectKey(widget)
    if not force and widgetKey == editTextWidgetKey and language == editTextLanguage then
        return
    end

    local text = EDIT_MODE_TEXT[language] or EDIT_MODE_TEXT.en
    local titleApplied = pcall(function()
        widget.TextBlock_58:SetText(FText(text.title))
    end)
    local helpApplied = pcall(function()
        widget.TextBlock:SetText(FText(text.help))
    end)
    if titleApplied and helpApplied then
        editTextWidgetKey = widgetKey
        editTextLanguage = language
        log("edit-mode instructions localized: " .. language)
    end
end

-- Fixed menu order (modconfig keys). Headers group the options.
-- `label` overrides the text shown; defaults to the key.
-- Minimap "quality" presets: each maps to a render-target resolution. Lower =
-- cheaper GPU (helps stutter/freezing), blurrier map. "High" (512) is the stock
-- Paldar default.
local QUALITY_PRESETS = {
    { name = "Very Low", res = 160 },
    { name = "Low",      res = 256 },
    { name = "Medium",   res = 384 },
    { name = "High",     res = 512 },
    { name = "Ultra",    res = 768 },
}

local MENU_LAYOUT = {
    { header = "General Settings" },
    { key = "Minimap opacity" },
    { key = "Minimap render resolution", label = "Minimap quality", quality = true },
    { key = "Minimap shape", label = "Minimap Square" },
    { key = "Minimap autozoom while moving" },
    { key = "Minimap rotation lock" },
    { key = "Lock all icon rotations to north" },
    { key = "Autohide minimap while in base camps" },
    { key = "Hide collected items from minimap", label = "Hide collected items" },
    { header = "Pal Locations" },
    { key = "Show pal positions" },
    { key = "Only show shiny pals" },
    { key = "Show pal icons while megazoomed out" },
    { header = "NPCs and Points of Interest" },
    { key = "Show NPC humans" },
    { key = "Show player base camps" },
    { key = "Show player death locations" },
    { key = "Show other players" },
    { key = "Show dungeons" },
    { header = "Chests, Notes, and Other" },
    { key = "Show chests" },
    { key = "Show notes" },
    { key = "Show eggs" },
    { key = "Show fast travel points" },
    { key = "Show skillfruit trees" },
    { key = "Show lifmunk effigies" },
    { header = "Keybinds (edit in mod config file)" },
    { key = "Megazoom mode toggle keybind" },
    { key = "Cycle default minimap positions keybind" },
    { key = "Show/hide minimap toggle keybind" },
    { key = "Customize minimap keybind" },
}

local menu = nil          -- current UserWidget
local controls = {}       -- {key=, type=, widget=, last=, committed=}
-- worldName is declared earlier (near the janitor state) so the cleanup passes
-- above can see it; do NOT redeclare it here or it would shadow that upvalue.
local menuWorld = ""      -- world the menu was created in
local lastToggle = 0.0
local flushPendingChanges -- defined with the change-collection code below

local function cls(path) return StaticFindObject(path) end

local function WBL()
    return StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
end

local function newWidget(class, outer)
    return StaticConstructObject(class, outer)
end

-- ---------------------------------------------------------------
-- Menu theme + small UMG styling helpers
-- Everything here is best-effort: each engine write is wrapped in pcall so an
-- unsupported call just leaves the default look instead of breaking the menu.
-- ---------------------------------------------------------------
local UI = {
    panelBg   = { R = 0.020, G = 0.028, B = 0.045, A = 0.94 }, -- window
    headerBg  = { R = 0.055, G = 0.105, B = 0.155, A = 0.98 }, -- title card
    accent    = { R = 0.33,  G = 0.78,  B = 0.96,  A = 1.0 },  -- cyan highlight
    accentDim = { R = 0.16,  G = 0.34,  B = 0.44,  A = 1.0 },  -- slider track
    textMain  = { R = 0.90,  G = 0.93,  B = 0.96,  A = 1.0 },
    textMuted = { R = 0.56,  G = 0.62,  B = 0.70,  A = 1.0 },
}

-- ETextJustify: 0 Left, 1 Center, 2 Right
-- ESlateSizeRule: 0 Automatic, 1 Fill  |  EHAlign: 0 Fill 1 Left 2 Center 3 Right
-- EVAlign: 0 Fill 1 Top 2 Center 3 Bottom
local function setTextColor(w, c)
    pcall(function() w:SetColorAndOpacity({ SpecifiedColor = c, ColorUseRule = 0 }) end)
end

local function fillSlot(slot)
    pcall(function() slot:SetSize({ Value = 1.0, SizeRule = 1 }) end)
end

local function alignSlot(slot, h, v)
    if h then pcall(function() slot:SetHorizontalAlignment(h) end) end
    if v then pcall(function() slot:SetVerticalAlignment(v) end) end
end

local function padSlot(slot, l, t, r, b)
    pcall(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end)
end

local function roundInt(v) return math.floor(v + 0.5) end

local function makeText(tree, txt, size, color, justify, wrap)
    local t = newWidget(cls("/Script/UMG.TextBlock"), tree)
    t:SetText(FText(txt))
    -- smaller font than the 24pt UMG default so rows fit the menu width;
    -- best-effort (skipped silently if the engine rejects the write)
    pcall(function() t.Font.Size = (size or 15) + 0.0 end)
    if wrap ~= false then pcall(function() t:SetAutoWrapText(true) end) end
    if color then setTextColor(t, color) end
    if justify then pcall(function() t:SetJustification(justify) end) end
    return t
end

local function dropMenuRefs()
    menu = nil
    menuOpen = false
    controls = {}
end

-- true if the menu widget is still safe to touch
local function menuUsable()
    if menu == nil then return false end
    if not isAlive(menu) then return false end
    if menuWorld ~= currentWorldName() then return false end
    return true
end

local function buildMenu(pc)
    controls = {}
    local cfg = readConfig()
    if not cfg then return false end
    local language = detectMenuLanguage()

    local world = UEHelpers.GetWorld()
    local widget = WBL():Create(world, cls("/Script/UMG.UserWidget"), pc)
    if not widget or not widget:IsValid() then
        log("ERROR: could not create UserWidget")
        return false
    end
    local tree = widget.WidgetTree

    local canvas = newWidget(cls("/Script/UMG.CanvasPanel"), tree)
    tree.RootWidget = canvas

    -- menu sized to ~30% of the screen width and 85% of its height, in
    -- slate units (viewport pixels divided by the UI scale); falls back to
    -- a fixed size if the viewport can't be measured
    local menuW, menuH = 560.0, 700.0
    pcall(function()
        local sx, sy = pc:GetViewportSize()
        if type(sx) == "number" and type(sy) == "number" and sx > 0 and sy > 0 then
            local scale = 1.0
            pcall(function()
                local wll = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
                local s = wll:GetViewportScale(pc)
                if type(s) == "number" and s > 0.1 then scale = s end
            end)
            menuW = math.max(480.0, (sx / scale) * 0.30)
            menuH = math.max(560.0, (sy / scale) * 0.85)
        end
    end)

    local sizeBox = newWidget(cls("/Script/UMG.SizeBox"), tree)
    sizeBox:SetWidthOverride(menuW)
    sizeBox:SetHeightOverride(menuH)
    local canvasSlot = canvas:AddChild(sizeBox)
    pcall(function() canvasSlot:SetAutoSize(true) end)
    pcall(function() canvasSlot:SetPosition({ X = 40.0, Y = 60.0 }) end)

    local border = newWidget(cls("/Script/UMG.Border"), tree)
    pcall(function() border:SetBrushColor(UI.panelBg) end)
    pcall(function() border:SetPadding({ Left = 14, Top = 12, Right = 14, Bottom = 12 }) end)
    sizeBox:AddChild(border)

    local scroll = newWidget(cls("/Script/UMG.ScrollBox"), tree)
    border:AddChild(scroll)

    -- Title card -----------------------------------------------------------
    local headerBorder = newWidget(cls("/Script/UMG.Border"), tree)
    pcall(function() headerBorder:SetBrushColor(UI.headerBg) end)
    pcall(function() headerBorder:SetPadding({ Left = 14, Top = 10, Right = 14, Bottom = 10 }) end)
    local headerBox = newWidget(cls("/Script/UMG.VerticalBox"), tree)
    headerBorder:AddChild(headerBox)
    headerBox:AddChild(makeText(tree, "PalMiniMap", 24, UI.accent, 0, false))
    headerBox:AddChild(makeText(tree, menuText(language, "subtitle"), 12, UI.textMuted, 0, false))
    headerBox:AddChild(makeText(tree,
        string.format(menuText(language, "help"), MENU_KEY_NAME),
        11, UI.textMuted, 0, false))
    padSlot(scroll:AddChild(headerBorder), 0, 0, 0, 8)

    -- Rows -----------------------------------------------------------------
    for _, item in ipairs(MENU_LAYOUT) do
        if item.header then
            local header = menuText(language, item.header)
            padSlot(scroll:AddChild(makeText(tree, string.upper(header), 13, UI.accent, 0, false)),
                    2, 14, 2, 5)
        else
            local entry = cfg[item.key]
            local label = menuText(language, item.label or item.key)
            if type(entry) == "table" and entry.type then
                if item.quality then
                    -- quality preset slider (maps to render-target resolution)
                    local presets = QUALITY_PRESETS
                    local curRes = (entry.live or entry.init or 512) + 0.0
                    local idx, best = 0, math.huge
                    for i, p in ipairs(presets) do
                        local d = math.abs(p.res - curRes)
                        if d < best then best = d; idx = i - 1 end
                    end
                    local row = newWidget(cls("/Script/UMG.HorizontalBox"), tree)
                    local lblSlot = row:AddChild(makeText(tree, label, 14, UI.textMain, 0))
                    fillSlot(lblSlot); alignSlot(lblSlot, nil, 2)

                    local sbox = newWidget(cls("/Script/UMG.SizeBox"), tree)
                    pcall(function() sbox:SetWidthOverride(140.0) end)
                    pcall(function() sbox:SetHeightOverride(18.0) end)
                    local sld = newWidget(cls("/Script/UMG.Slider"), tree)
                    pcall(function() sld:SetMinValue(0.0) end)
                    pcall(function() sld:SetMaxValue((#presets - 1) + 0.0) end)
                    pcall(function() sld:SetValue(idx + 0.0) end)
                    pcall(function() sld.SliderBarColor = UI.accentDim end)
                    pcall(function() sld.SliderHandleColor = UI.accent end)
                    sbox:AddChild(sld)
                    alignSlot(row:AddChild(sbox), 3, 2)

                    local valTxt = makeText(tree, menuText(language, presets[idx + 1].name),
                                            13, UI.accent, 2, false)
                    local vbox = newWidget(cls("/Script/UMG.SizeBox"), tree)
                    pcall(function() vbox:SetWidthOverride(74.0) end)
                    vbox:AddChild(valTxt)
                    local vSlot = row:AddChild(vbox); padSlot(vSlot, 10, 0, 0, 0); alignSlot(vSlot, 3, 2)

                    padSlot(scroll:AddChild(row), 6, 5, 6, 5)
                    table.insert(controls, { key = item.key, type = "quality",
                                             widget = sld, valueWidget = valTxt,
                                             presets = presets, min = 0, max = #presets - 1,
                                             last = idx, committed = idx,
                                             language = language })
                elseif entry.type == "boolean" or entry.type == "option" then
                    local isOn
                    if entry.type == "option" then isOn = (entry.live == "Square")
                    else isOn = (entry.live == true) end
                    local row = newWidget(cls("/Script/UMG.HorizontalBox"), tree)
                    local lblSlot = row:AddChild(makeText(tree, label, 14, UI.textMain, 0))
                    fillSlot(lblSlot); alignSlot(lblSlot, nil, 2)
                    local cb = newWidget(cls("/Script/UMG.CheckBox"), tree)
                    cb:SetIsChecked(isOn == true)
                    alignSlot(row:AddChild(cb), 3, 2)
                    padSlot(scroll:AddChild(row), 6, 4, 6, 4)
                    table.insert(controls, { key = item.key, type = entry.type,
                                             widget = cb, last = (isOn == true),
                                             committed = (isOn == true) })
                elseif entry.type == "integer" then
                    local mn = (entry.opts and entry.opts.min) or 0
                    local mx = (entry.opts and entry.opts.max) or 9999
                    local val = (entry.live or entry.init or mn) + 0.0
                    local row = newWidget(cls("/Script/UMG.HorizontalBox"), tree)
                    local lblSlot = row:AddChild(makeText(tree, label, 14, UI.textMain, 0))
                    fillSlot(lblSlot); alignSlot(lblSlot, nil, 2)

                    -- slider (replaces the old SpinBox: cleaner, themed)
                    local sbox = newWidget(cls("/Script/UMG.SizeBox"), tree)
                    pcall(function() sbox:SetWidthOverride(168.0) end)
                    pcall(function() sbox:SetHeightOverride(18.0) end)
                    local sld = newWidget(cls("/Script/UMG.Slider"), tree)
                    pcall(function() sld:SetMinValue(mn + 0.0) end)
                    pcall(function() sld:SetMaxValue(mx + 0.0) end)
                    pcall(function() sld:SetValue(val) end)
                    pcall(function() sld.SliderBarColor = UI.accentDim end)
                    pcall(function() sld.SliderHandleColor = UI.accent end)
                    sbox:AddChild(sld)
                    alignSlot(row:AddChild(sbox), 3, 2)

                    -- live value readout
                    local valTxt = makeText(tree, tostring(roundInt(val)), 14, UI.accent, 2, false)
                    local vbox = newWidget(cls("/Script/UMG.SizeBox"), tree)
                    pcall(function() vbox:SetWidthOverride(46.0) end)
                    vbox:AddChild(valTxt)
                    local vSlot = row:AddChild(vbox); padSlot(vSlot, 10, 0, 0, 0); alignSlot(vSlot, 3, 2)

                    padSlot(scroll:AddChild(row), 6, 5, 6, 5)
                    table.insert(controls, { key = item.key, type = "integer",
                                             widget = sld, valueWidget = valTxt,
                                             min = mn, max = mx,
                                             last = roundInt(val), committed = roundInt(val) })
                elseif entry.type == "keybind" then
                    local k = (type(entry.live) == "table" and entry.live.key) or "?"
                    padSlot(scroll:AddChild(makeText(tree, "[ " .. tostring(k) .. " ]   " .. label,
                            13, UI.textMuted, 0)), 14, 3, 6, 3)
                end
            end
        end
    end

    padSlot(scroll:AddChild(makeText(tree, menuText(language, "footer"),
            12, UI.textMuted, 1, false)), 6, 14, 6, 10)

    menu = widget
    return true
end

local function openMenu()
    if menuOpen then return end
    local wname = currentWorldName()
    if wname == nil then
        log("menu not opened: no world yet")
        return
    end
    -- Refuse to open during a world transition -- but only when we actually know
    -- of a different world. worldName is blank before the first world tick and
    -- straight after the LoadMap hook, and the old "must match" test then made
    -- F5 silently do nothing until the tick caught up (or forever, if the tick
    -- never restored it). Adopt the live name instead of dead-ending.
    if worldName == "" then
        worldName = wname
    elseif wname ~= worldName then
        log("menu not opened: world transition in progress")
        return
    end
    -- Re-read the file so edits made outside this menu (another tool writing the
    -- same file) are picked up instead of clobbered on save. If it is momentarily
    -- unreadable, fall back to the values we already have -- losing the menu
    -- entirely over a transient read failure is far worse than stale defaults.
    configCache = nil
    if readConfig() == nil then
        configCache = lastGoodConfig
        if configCache == nil then
            log("menu not opened: settings file unreadable (" .. CONFIG_PATH .. ")")
            return
        end
        log("warning: settings file unreadable; opening the menu with the last known values")
    end

    local okpc, pc = pcall(UEHelpers.GetPlayerController)
    if not okpc or not isAlive(pc) then
        log("no PlayerController; menu not opened")
        return
    end
    local ok, err = pcall(function()
        if not buildMenu(pc) then error("buildMenu failed") end
        menuWorld = wname
        menu:AddToViewport(99)
        if not NON_GAME_WORLDS[wname] then
            pcall(function()
                WBL():SetInputMode_GameAndUIEx(pc, menu, 0, false)
                pc.bShowMouseCursor = true
            end)
        end
    end)
    if ok then
        menuOpen = true
        log("menu opened")
    else
        log("ERROR opening menu: " .. tostring(err))
        -- the failure may have happened after AddToViewport; leaving the widget
        -- on screen with no way to reach it would block every later open
        if menu ~= nil and isAlive(menu) then
            pcall(function() menu:RemoveFromParent() end)
        end
        dropMenuRefs()
    end
end

local function closeMenu()
    if not menuOpen then return end
    -- a slider may still be inside its commit-delay window; save it now so
    -- the change is not lost with the widget
    if flushPendingChanges then
        runGuarded("flushPendingChanges", flushPendingChanges)
    end
    local wasWorld = menuWorld
    if menuUsable() then
        pcall(function() menu:RemoveFromParent() end)
    end
    dropMenuRefs()
    local wname = currentWorldName()
    if wname ~= nil and wname == wasWorld and not NON_GAME_WORLDS[wname] then
        pcall(function()
            local pc = UEHelpers.GetPlayerController()
            if isAlive(pc) then
                WBL():SetInputMode_GameOnly(pc)
                pc.bShowMouseCursor = false
            end
        end)
    end
end

local function toggleMenu()
    -- debounce rapid presses
    if (os.clock() - lastToggle) < 0.35 then return end
    lastToggle = os.clock()
    -- widget silently died (world swap with same name etc.): drop the stale
    -- refs and open a fresh one right away -- the old code swallowed the press
    -- and forced the user to hit the key twice
    if menuOpen and not menuUsable() then
        dropMenuRefs()
    end
    if menuOpen then closeMenu() else openMenu() end
end

-- ---------------------------------------------------------------
-- Applying changes (polled ~4x/s while the menu is open)
-- ---------------------------------------------------------------
local SLIDER_COMMIT_DELAY = 0.4   -- seconds a slider must rest before saving

-- Persist a batch of control values: update the config, write it once, then
-- poke the actor so the blueprint reloads. `entries` is { {c=control, value=} }.
local function applyControlValues(entries)
    if #entries == 0 then return end
    local cfg = readConfig()
    if not cfg then return end
    local palIconResetNeeded = false
    local qualityRes = nil
    for _, ch in ipairs(entries) do
        ch.c.committed = ch.value
        local entry = cfg[ch.c.key]
        if type(entry) == "table" then
            if ch.c.type == "boolean" then
                entry.live = (ch.value == true)
            elseif ch.c.type == "integer" then
                entry.live = ch.value
            elseif ch.c.type == "quality" then
                local p = ch.c.presets and ch.c.presets[ch.value + 1]
                if p then entry.live = p.res; qualityRes = p.res end
            elseif ch.c.type == "option" then
                entry.live = ch.value and "Square" or "Circle"
            end
            log(string.format("option '%s' -> %s", ch.c.key, tostring(entry.live)))
            if ch.c.key == "Show pal positions" then
                palIconResetNeeded = true
            end
        end
    end
    if writeConfig(cfg) then
        pokeModActor()
        if palIconResetNeeded then
            -- toggling this option desyncs the blueprint's tracking arrays
            -- (ids/actors are added before the option check); resync now
            local actor = getModActor()
            if actor then resetPalIcons(actor, "Show pal positions toggled") end
        end
        if qualityRes then
            applyRenderQuality(qualityRes)  -- resize the render target live
        end
    end
end

-- Menu is closing while a slider is still inside its commit-delay window:
-- save the last polled values so the change is not lost with the widget.
flushPendingChanges = function()
    local pending = {}
    for _, c in ipairs(controls) do
        if c.last ~= nil and c.last ~= c.committed then
            pending[#pending + 1] = { c = c, value = c.last }
        end
    end
    applyControlValues(pending)
end

local function collectChanges()
    if not menuOpen then return end
    if not menuUsable() then
        dropMenuRefs()
        return
    end
    local now = os.clock()
    local toCommit = {}
    for _, c in ipairs(controls) do
        local okv, cur = pcall(function()
            if c.type == "integer" or c.type == "quality" then
                local v = roundInt(c.widget:GetValue())
                if c.min and v < c.min then v = c.min end
                if c.max and v > c.max then v = c.max end
                return v
            else
                return c.widget:IsChecked()
            end
        end)
        if okv and cur ~= nil then
            if cur ~= c.last then
                c.last = cur
                c.lastChangedAt = now
                if c.valueWidget then
                    -- keep the readout next to the slider in sync while dragging
                    local txt
                    if c.type == "quality" and c.presets then
                        local p = c.presets[cur + 1]
                        txt = p and menuText(c.language or "en", p.name) or nil
                    elseif c.type == "integer" then
                        txt = tostring(cur)
                    end
                    if txt then pcall(function() c.valueWidget:SetText(FText(txt)) end) end
                end
            end
            -- Saving on every 250 ms poll while a slider was being dragged meant
            -- a config rewrite + backup write + LoadSettingsFromJson (+ render
            -- target resize) four times a second -- a visible hitch. Sliders now
            -- commit only after resting; checkboxes commit immediately.
            local isSlider = (c.type == "integer" or c.type == "quality")
            if cur ~= c.committed
               and (not isSlider or (now - (c.lastChangedAt or 0)) >= SLIDER_COMMIT_DELAY) then
                toCommit[#toCommit + 1] = { c = c, value = cur }
            end
        end
    end
    applyControlValues(toCommit)
end

-- ---------------------------------------------------------------
-- Loops and registration
-- ---------------------------------------------------------------

-- World transitions: the 3 s world tick can lag behind a level change, leaving
-- a short window where a queued sweep touches a dying actor (a native access
-- violation pcall cannot catch). UEngine::LoadMap fires right at the
-- transition, so drop every cached reference immediately and re-arm the
-- BeginPlay grace window. Best-effort: on UE4SS builds without this hook the
-- world tick below still handles it (just later).
pcall(function()
    RegisterLoadMapPreHook(function()
        actorGraceUntil = os.clock() + ACTOR_TOUCH_GRACE
        cachedActor = nil
        worldName = ""
        dropMenuRefs()
    end)
end)

RegisterKeyBind(MENU_KEY, function()
    ExecuteInGameThread(function() pcall(toggleMenu) end)
end)

registerZoomKeys()

LoopAsync(250, function()
    if menuOpen then
        pcall(ExecuteInGameThread, function()
            runGuarded("collectChanges", collectChanges)
        end)
    end
    return false
end)

-- Janitor: cheap count check often, expensive orphan walk every ORPHAN_WALK_EVERY
-- passes. The old build only checked the cap every 30 s, so a busy area could sit
-- three times over the soft cap between passes.
LoopAsync(COUNT_CHECK_MS, function()
    pcall(ExecuteInGameThread, function()
        runGuarded("janitorPass", janitorPass)
    end)
    return false
end)

-- Hides effigies/notes already collected. This is the ONLY remaining pass that
-- walks icon arrays and their target actors (the 20 s orphan sweep that used to
-- sit here was removed in v1.2.6 -- see the long note above processCollectible:
-- it duplicated work the blueprint already does and it was the fast-travel
-- crash). CADENCE MATTERS FOR STABILITY: every walk dereferences entries the
-- blueprint may have destroyed, and a native access violation cannot be caught
-- by pcall, so this stays slow and is gated by iconWorkAllowed().
LoopAsync(23000, function()
    pcall(ExecuteInGameThread, function()
        runGuarded("hideCollectedObtainables", hideCollectedObtainables)
    end)
    return false
end)

-- World tick (3s)
LoopAsync(3000, function()
    pcall(ExecuteInGameThread, function()
        runGuarded("worldTick", function()
            local name = currentWorldName()
            if name == nil then
                -- During shutdown the UWorld can disappear before UE4SS stops its
                -- Lua timers. Drop references without calling into dying UObjects.
                cachedActor = nil
                dropMenuRefs()
                return
            end
            if name ~= worldName then
                -- world changed: the old actor and widget died with it. Clear
                -- every cached reference so nothing stale is ever touched.
                worldName = name
                cachedActor = nil
                -- the new level's actor is mid-BeginPlay: keep everyone off it
                actorGraceUntil = os.clock() + ACTOR_TOUCH_GRACE
                lastActorScan = 0.0          -- allow an immediate re-scan in the new world
                desyncStreak = 0             -- fresh actor -> fresh desync tracking
                captureLODAppliedFor = nil   -- re-apply the capture LOD in the new world
                captureLODAppliedValue = nil
                visualActorKey, visualWidgetKey = nil, nil
                visualActorOpacity, visualActorSquare = nil, nil
                visualOpacity, visualSquare = nil, nil
                editTextWidgetKey, editTextLanguage = nil, nil
                dropMenuRefs()
            elseif menuOpen and not menuUsable() then
                -- same-name world swap (e.g. logout/login): widget is gone
                dropMenuRefs()
            end
            -- Splash/login/title actors are short-lived and can be destroyed while
            -- UE4SS callbacks are still queued; no minimap maintenance is needed there.
            if NON_GAME_WORLDS[name] then return end
            local actor = getModActor()
            if actor then
                -- A fast travel does not change the world, so this tick is the
                -- only place that can notice one: sample the pawn every 3 s and
                -- silence the icon passes when it jumps (or vanishes behind a
                -- loading screen).
                watchForTeleport(actor)
                pcall(function() applyMinimapVisualSettings(actor, false) end)
                pcall(function() applyEditModeLocalization(actor, false) end)
                -- once the minimap actor exists in a real world, make its
                -- every-frame capture cheaper (self-gated: reapplies only when
                -- the actor or the configured LOD bias changes)
                applyCaptureLOD(actor)
            end
            -- Terrain capture is left to the stock blueprint. The config menu is
            -- opened/closed only with F5 (no auto-open on the title screen).
        end)
    end)
    return false
end)

-- Create/restore/merge the settings file at startup, before any world
-- (and the mod's own blueprint) reads it. Also warms the config cache.
ensureConfig()
if configCache then
    log("config ready")
end

log("PalMiniMap loaded - " .. MENU_KEY_NAME .. " opens/closes the menu; " ..
    "+/- fine zoom; icon janitor active")
