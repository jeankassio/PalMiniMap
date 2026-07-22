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
-- or wipe the LogicMods folder)
local BACKUP_PATH = "ue4ss/Mods/PalMiniMap/user_settings.json"

-- Default configuration template: the mod package no longer ships the
-- config file; it is created here on first run and NEVER overwritten by
-- updates. New keys from future versions are merged in while preserving
-- the user's values.
local DEFAULTS_JSON = [==[
{"note":"THIS JSON FILE WAS CREATED USING THE `DekModConfigMenu` MOD FOR PALWORLD! DO NOT MANUALLY EDIT THIS FILE UNLESS YOU KNOW WHAT YOU'RE DOING -- USE THE `DekModConfigMenu` MOD INSTEAD <3","meta":{"game":false,"vers":"1.1.0","auth":"T3R3NC3B","desc":"PalMiniMap (based on Paldar by T3R3NC3B) - a minimap radar that displays live pal positions and more. Updated for Palworld 1.0 By Jean Kassio.","link":{"nexus-mod-id":"879","curse-slug":"blueprint-code-mods/paldar-mini-map-radar","donate":""}},"General Settings":{"type":"header","desc":"Configure general settings."},"Enable mod":{"type":"boolean","desc":"Enable/disable the entire Paldar mod.","init":true,"live":true},"Minimap render resolution":{"type":"integer","desc":"Lower numbers for better performance, at the cost of quality.","flag":"","opts":{"min":32,"max":2048,"step":1},"init":512,"live":512},"Minimap opacity":{"type":"integer","desc":"Adjust transparency of the whole minimap.","flag":"","opts":{"min":1,"max":100,"step":1},"init":100,"live":100},"Minimap shape":{"type":"option","desc":"Change minimap shape to circular or square.","opts":["Circle","Square"],"init":"Square","live":"Square"},"Minimap image quality %":{"type":"integer","desc":"Resolution of the minimap terrain image, as a percent of the render resolution. Lower = big GPU saving, blurrier map. Applied live.","flag":"","opts":{"min":25,"max":100,"step":5},"init":60,"live":60},"Reduce captures when idle":{"type":"boolean","desc":"Skip re-rendering the minimap terrain while the view is not moving/turning/zooming. Big FPS saver when standing still or in base. No visual change.","init":true,"live":true},"Minimap autozoom while moving":{"type":"boolean","desc":"Auto zoom out minimap to different levels when walking, running & flying.","init":true,"live":true},"Minimap rotation lock":{"type":"boolean","desc":"Lock minimap rotation to north, player icon rotates instead.","init":false,"live":false},"Lock all icon rotations to north":{"type":"boolean","desc":"Locks all icons (excluding pals & NPCs) to be upright (north).","init":false,"live":false},"Autohide minimap while in base camps":{"type":"boolean","desc":"Hide minimap while in player base camps.","init":false,"live":false},"Hide collected items from minimap":{"type":"boolean","desc":"Remove chest, egg, note and lifmunk effigy icons from the minimap once you collect them (they disappear from the world).","init":true,"live":true},"Pal Locations":{"type":"header","desc":"Configure settings for displaying Pals."},"Show pal positions":{"type":"boolean","desc":"Show Pals around the player on the minimap.","init":true,"live":true},"Only show shiny pals":{"type":"boolean","desc":"Only shows shiny Pals around the player on the minimap.","init":false,"live":false},"Show pal icons while megazoomed out":{"type":"boolean","desc":"Keep Pal icons visible on the minimap while in megazoomed out mode.","init":false,"live":false},"NPCs and Points of Interest":{"type":"header","desc":"Customize display settings for NPCs and points of interest."},"Show NPC humans":{"type":"boolean","desc":"Show NPC humans on the minimap.","init":true,"live":true},"Show player base camps":{"type":"boolean","desc":"Show player base camps on the minimap.","init":true,"live":true},"Show player death locations":{"type":"boolean","desc":"Show player death locations on the minimap.","init":true,"live":true},"Show other players":{"type":"boolean","desc":"Show other players around the player on the minimap.","init":true,"live":true},"Show dungeons":{"type":"boolean","desc":"Show dungeon locations on the minimap.","init":true,"live":true},"Chests, Notes, and Other":{"type":"header","desc":"Customize display settings for chests, notes, and other entities."},"Show chests":{"type":"boolean","desc":"Show chests around the player on the minimap.","init":true,"live":true},"Show notes":{"type":"boolean","desc":"Show notes around the player on the minimap.","init":true,"live":true},"Show eggs":{"type":"boolean","desc":"Show eggs around the player on the minimap.","init":true,"live":true},"Show fast travel points":{"type":"boolean","desc":"Show fast travel points on the minimap.","init":true,"live":true},"Show skillfruit trees":{"type":"boolean","desc":"Show skillfruit trees around the player on the minimap.","init":true,"live":true},"Show lifmunk effigies":{"type":"boolean","desc":"Show Lifmunk Effigies around the player on the minimap.","init":false,"live":false},"Scan Frequencies":{"type":"header","desc":"Adjust scanning frequencies for various entities."},"Pal rescan rate":{"type":"integer","desc":"How often the radar will scan for new Pals around the player. In seconds.","flag":"","opts":{"min":1,"max":60,"step":1},"init":5,"live":5},"Players rescan frequency":{"type":"integer","desc":"How often the radar will scan for NEW players (not refresh rate of current players). In seconds.","flag":"","opts":{"min":1,"max":60,"step":1},"init":12,"live":12},"Human NPC rescan frequency":{"type":"integer","desc":"How often the radar will scan for NPC humans around the player on the minimap. In seconds.","flag":"","opts":{"min":1,"max":60,"step":1},"init":19,"live":19},"Chest rescan frequency":{"type":"integer","desc":"How often the radar will scan for chests around the player on the minimap. In seconds.","flag":"","opts":{"min":5,"max":60,"step":1},"init":14,"live":14},"Egg rescan frequency":{"type":"integer","desc":"How often the radar will scan for eggs around the player on the minimap. In seconds.","flag":"","opts":{"min":5,"max":60,"step":1},"init":14,"live":14},"Keybinds":{"type":"header","desc":"Customize keyboard shortcuts."},"Megazoom mode toggle keybind":{"type":"keybind","desc":"Set keybind for megazoom out mode toggle. Hold this key and press + or - to fine-zoom the minimap.","init":{"key":"Z","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"Z","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Cycle default minimap positions keybind":{"type":"keybind","desc":"Set keybind for cycling between default minimap positions.","init":{"key":"L","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"L","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Show/hide minimap toggle keybind":{"type":"keybind","desc":"Show/hide minimap toggle keyboard button.","init":{"key":"H","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"H","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Customize minimap keybind":{"type":"keybind","desc":"Set keybind to enter customization mode - move with arrow keys, resize with + and - keys.","init":{"key":"K","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false},"live":{"key":"K","bShift":false,"bCtrl":false,"bAlt":false,"bCmd":false}},"Use new minimap edit mode size method":{"type":"boolean","desc":"ON: resize minimap in edit mode with mouse scroll wheel (BROKEN on Palworld 1.0). OFF (default): resize with + and - keys (also 9 and 0).","init":false,"live":false},"Minimap capture FPS cap":{"type":"integer","desc":"Max minimap terrain captures per second. Big FPS saver on high-refresh screens. 0 = uncapped (original behavior).","flag":"","opts":{"min":0,"max":120,"step":5},"init":30,"live":30},"Minimap capture LOD bias":{"type":"integer","desc":"Renders the minimap terrain with cheaper detail levels. 1 = original, higher = faster. Barely visible on the small map.","flag":"","opts":{"min":1,"max":8,"step":1},"init":3,"live":3}}
]==]

local ZOOM_STEP = 500.0           -- zoom change per +/- key press
local ZOOM_MIN, ZOOM_MAX = -7500.0, 15000.0
local ICON_SOFT_CAP = 80          -- above this many pal icons, force a reset
local CAMP_RESET_SECONDS = 90     -- periodic icon reset while inside a base camp
local DEFAULT_CAPTURE_FPS = 30    -- fallback when the config entry is absent
local DEFAULT_LOD_BIAS = 3
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

-- ---------------------------------------------------------------
-- Small safety helpers
-- ---------------------------------------------------------------
local function isAlive(obj)
    if obj == nil then return false end
    local ok, valid = pcall(function() return obj:IsValid() end)
    return ok and valid == true
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

local function pokeModActor()
    local actor = getModActor()
    if actor then
        pcall(function() actor:LoadSettingsFromJson() end)
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

local function writeFileTo(path, text)
    local f = io.open(path, "w")
    if not f then return false end
    f:write(text)
    f:close()
    return true
end

local function writeConfig(cfg)
    local ok, text = pcall(json.encode, cfg)
    if not ok then
        log("ERROR: failed to encode JSON: " .. tostring(text))
        return false
    end
    if not writeFileTo(CONFIG_PATH, text) then
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

local function destroyIconComponents(actor)
    local destroyed = 0
    pcall(function()
        actor.palIconMapSMs:ForEach(function(_, elem)
            local okc = pcall(function()
                local comp = elem:get()
                if comp and comp:IsValid() then
                    comp:K2_DestroyComponent(actor)
                end
            end)
            if okc then destroyed = destroyed + 1 end
        end)
    end)
    return destroyed
end

local function resetPalIcons(actor, reason)
    local n = destroyIconComponents(actor)
    local cleared = pcall(function()
        actor.palIconMapSMs:Empty()
        actor.trackedPals:Empty()
        actor.monsterMapIDs:Empty()
    end)
    if not cleared and not emptyUnsupportedWarned then
        emptyUnsupportedWarned = true
        log("note: TArray:Empty() unavailable; icons destroyed but arrays kept " ..
            "(the mod's own cleanup loop will prune them)")
    end
    log(string.format("pal icon reset (%s): %d components destroyed, arrays cleared=%s",
                      reason, n, tostring(cleared)))
    return cleared
end

-- These capture-tracking locals are kept only because the world-change
-- handler still resets them; the capture logic that used them is disabled.
local lastCaptureActive = nil
local captureGen = 0
local captureAppliedFor = nil
local rtSizedFor = nil
local startCaptureLoop
local lastCapX, lastCapY, lastCapZ = nil, nil, nil
local lastCapYaw = nil
local lastCapOrtho = nil
local lastCapTime = 0.0

-- Terrain capture is left ENTIRELY to the stock blueprint, which captures
-- every frame natively (bCaptureEveryFrame defaults to true). Earlier
-- versions tried to throttle the capture, drive it manually, resize the
-- render target and toggle it with visibility — that broke the minimap
-- image (blank map), so all of it is disabled. These stay as no-ops so the
-- existing call sites keep working without further edits.
local function applyRenderTargetQuality(actor) end
local function applyCaptureSettings(actor) end
local function mirrorCaptureToVisibility(wname) end

local function janitorPass()
    local wname = currentWorldName()
    if wname == nil or NON_GAME_WORLDS[wname] then return end
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
    local desynced = (n1 ~= n2 or n2 ~= n3)
    -- Track how long the desync has persisted. A one-pass mismatch is almost
    -- always a benign mid-rescan snapshot (the blueprint appends an id before
    -- its icon), so nuking every icon for it caused needless hitches/flicker.
    if desynced then desyncStreak = desyncStreak + 1 else desyncStreak = 0 end

    -- Count-based resets (desync / overflow) only help when Empty() can truly
    -- clear the arrays. If we've learned it can't on this build, they only
    -- churn (destroy -> blueprint rebuilds -> still desynced), so skip them
    -- entirely and let the orphan sweep below do the real work.
    if not countResetsDisabled then
        local coolOk = (now - lastCountReset) >= COUNT_RESET_COOLDOWN

        -- 1. runaway growth -> reset (unambiguous; icons rebuild within a rescan)
        if n3 > ICON_SOFT_CAP and coolOk then
            lastCountReset = now
            local cleared = resetPalIcons(actor, string.format("icon count %d > %d", n3, ICON_SOFT_CAP))
            if not cleared then countResetsDisabled = true end
            desyncStreak = 0
            return
        end

        -- 2. arrays out of sync -> index-shifted cleanup destroys the wrong
        --    icons and orphans the rest; full reset re-syncs everything. Only
        --    act once the desync has actually persisted (not a transient).
        if desynced and desyncStreak >= DESYNC_PASSES_BEFORE_RESET and coolOk then
            lastCountReset = now
            local cleared = resetPalIcons(actor, string.format("desync %d/%d/%d", n1, n2, n3))
            if not cleared then countResetsDisabled = true end
            desyncStreak = 0
            return
        end
    end

    -- 3. periodic reset while sitting inside a base camp (the reported
    --    FPS-decay scenario); rebuilt automatically by the next rescan
    local inCamp = false
    pcall(function() inCamp = actor.currentlyInABaseCamp == true end)
    if inCamp and (now - lastCampReset) > CAMP_RESET_SECONDS and n3 > 0 then
        lastCampReset = now
        resetPalIcons(actor, "base camp periodic")
        return
    end

    -- 4. orphan sweep: destroy icon planes whose pal mesh is gone
    --    (e.g. pals missing from the icon table are never attached).
    --    This is the only per-element work in the janitor, so run it at
    --    1/3 the rate and only when there is something to look at.
    janitorPassCount = janitorPassCount + 1
    if n3 > 0 and (janitorPassCount % 3) == 0 then
        pcall(function()
            actor.palIconMapSMs:ForEach(function(_, elem)
                pcall(function()
                    local comp = elem:get()
                    if comp and comp:IsValid() then
                        local parent = comp:GetAttachParent()
                        if parent == nil or not parent:IsValid() then
                            comp:K2_DestroyComponent(actor)
                        end
                    end
                end)
            end)
        end)
    end
end

-- ---------------------------------------------------------------
-- "Only show what's actually in the world": when a collectible (chest,
-- egg, note, lifmunk effigy) is picked up, its world actor despawns.
-- Each minimap icon is a StaticMeshComponent attached to that actor's
-- root, so a collected item leaves an ORPHANED icon (its attach parent
-- is gone) -- exactly the condition the pal orphan sweep already cleans.
-- We destroy those orphans across the collectible icon arrays so obtained
-- items disappear from the minimap on their own. No pickup-event hooks
-- needed; this just reflects world truth.
-- NOTE: relies on the item actually despawning when obtained. Types that
-- linger in the world after use are not affected (would need per-type
-- state detection).
-- ---------------------------------------------------------------
local COLLECTIBLE_ICON_ARRAYS = {
    "eggicons", "EffigyIcons", "notesIcons", "mapIcon_CHESTS",
}

local function sweepCollectedIcons()
    local wname = currentWorldName()
    if wname == nil or NON_GAME_WORLDS[wname] then return end
    if not cfgBool("Hide collected items from minimap", true) then return end
    local actor = getModActor()
    if not actor then return end
    for _, arrName in ipairs(COLLECTIBLE_ICON_ARRAYS) do
        local removed = 0
        pcall(function()
            local arr = actor[arrName]
            if not arr then return end
            arr:ForEach(function(_, elem)
                pcall(function()
                    local comp = elem:get()
                    if comp and comp:IsValid() then
                        local parent = comp:GetAttachParent()
                        if parent == nil or not parent:IsValid() then
                            comp:K2_DestroyComponent(actor)
                            removed = removed + 1
                        end
                    end
                end)
            end)
        end)
        if removed > 0 then
            log(string.format("removed %d collected-item icon(s) from '%s'", removed, arrName))
        end
    end
end

-- ---------------------------------------------------------------
-- Collected Lifmunk Effigies and notes: unlike chests and eggs, a
-- collected effigy's or note's actor NEVER despawns (it stays in the
-- world for other players; the game only hides its mesh for you and
-- sets bPickedInClient on the actor). The orphan sweep above can
-- therefore never catch them, so their icons are hidden directly from
-- that flag. Rides the same "Hide collected items from minimap" toggle.
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

local function hideCollectedObtainables()
    local wname = currentWorldName()
    if wname == nil or NON_GAME_WORLDS[wname] then return end
    local actor = getModActor()
    if not actor then return end
    local enabled = cfgBool("Hide collected items from minimap", true)
    for _, entry in ipairs(PERSISTENT_COLLECTIBLES) do
        local hidden, restored = 0, 0
        pcall(function()
            local arr = actor[entry.iconArray]
            local n = arrayNum(arr) or 0
            for i = 1, n do
                pcall(function()
                    local comp = elemObject(arr[i])
                    if not (comp and comp:IsValid()) then return end
                    local visible = nil
                    pcall(function() visible = comp:IsVisible() end)
                    if visible == nil then return end
                    if not enabled then
                        if not visible then
                            comp:SetVisibility(true, true)
                            restored = restored + 1
                        end
                        return
                    end
                    -- already hidden: leave it (icons the blueprint
                    -- recreates on its rescan come back visible and get
                    -- re-hidden on the next pass)
                    if not visible then return end
                    -- only flip when the target is positively identified:
                    -- the attach chain is briefly broken during rescans,
                    -- and treating "can't tell" as an answer causes flicker
                    local target = nil
                    pcall(function()
                        local parent = comp:GetAttachParent()
                        if parent and parent:IsValid() then
                            local owner = parent:GetOwner()
                            if owner and owner:IsValid()
                               and string.find(owner:GetClass():GetFullName(),
                                               entry.classHint, 1, true) then
                                target = owner
                            end
                        end
                    end)
                    if target ~= nil and asBool(target.bPickedInClient) == true then
                        comp:SetVisibility(false, true)
                        hidden = hidden + 1
                    end
                end)
            end
        end)
        if hidden > 0 or restored > 0 then
            log(string.format("collected %s: %d hidden, %d shown",
                              entry.label, hidden, restored))
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
local controls = {}       -- {key=, type=, widget=, last=}
local worldName = ""      -- updated by the 1s world loop
local menuWorld = ""      -- world the menu was created in
local lastToggle = 0.0

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
    headerBox:AddChild(makeText(tree, "Minimap configuration", 12, UI.textMuted, 0, false))
    headerBox:AddChild(makeText(tree,
        "[ " .. MENU_KEY_NAME .. " ] close      [ + / - ] fine zoom      scroll for more",
        11, UI.textMuted, 0, false))
    padSlot(scroll:AddChild(headerBorder), 0, 0, 0, 8)

    -- Rows -----------------------------------------------------------------
    for _, item in ipairs(MENU_LAYOUT) do
        if item.header then
            padSlot(scroll:AddChild(makeText(tree, string.upper(item.header), 13, UI.accent, 0, false)),
                    2, 14, 2, 5)
        else
            local entry = cfg[item.key]
            local label = item.label or item.key
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

                    local valTxt = makeText(tree, presets[idx + 1].name, 13, UI.accent, 2, false)
                    local vbox = newWidget(cls("/Script/UMG.SizeBox"), tree)
                    pcall(function() vbox:SetWidthOverride(74.0) end)
                    vbox:AddChild(valTxt)
                    local vSlot = row:AddChild(vbox); padSlot(vSlot, 10, 0, 0, 0); alignSlot(vSlot, 3, 2)

                    padSlot(scroll:AddChild(row), 6, 5, 6, 5)
                    table.insert(controls, { key = item.key, type = "quality",
                                             widget = sld, valueWidget = valTxt,
                                             presets = presets, min = 0, max = #presets - 1,
                                             last = idx })
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
                                             widget = cb, last = (isOn == true) })
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
                                             min = mn, max = mx, last = roundInt(val) })
                elseif entry.type == "keybind" then
                    local k = (type(entry.live) == "table" and entry.live.key) or "?"
                    padSlot(scroll:AddChild(makeText(tree, "[ " .. tostring(k) .. " ]   " .. label,
                            13, UI.textMuted, 0)), 14, 3, 6, 3)
                end
            end
        end
    end

    padSlot(scroll:AddChild(makeText(tree, "Changes are saved and applied instantly.",
            12, UI.textMuted, 1, false)), 6, 14, 6, 10)

    menu = widget
    return true
end

local function openMenu()
    if menuOpen then return end
    local wname = currentWorldName()
    if wname == nil then return end
    -- refuse to open during world transitions (cached name must agree)
    if wname ~= worldName then return end

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
        dropMenuRefs()
    end
end

local function closeMenu()
    if not menuOpen then return end
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
    -- widget silently died (world swap with same name etc.) -> just reset
    if menuOpen and not menuUsable() then
        dropMenuRefs()
        return
    end
    if menuOpen then closeMenu() else openMenu() end
end

-- ---------------------------------------------------------------
-- Applying changes (polled ~4x/s while the menu is open)
-- ---------------------------------------------------------------
local function collectChanges()
    if not menuOpen then return end
    if not menuUsable() then
        dropMenuRefs()
        return
    end
    local changed = {}
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
        if okv and cur ~= nil and cur ~= c.last then
            c.last = cur
            if c.valueWidget then
                -- keep the readout next to the slider in sync while dragging
                local txt
                if c.type == "quality" and c.presets then
                    local p = c.presets[cur + 1]; txt = p and p.name or nil
                elseif c.type == "integer" then
                    txt = tostring(cur)
                end
                if txt then pcall(function() c.valueWidget:SetText(FText(txt)) end) end
            end
            table.insert(changed, { c = c, value = cur })
        end
    end
    if #changed == 0 then return end

    local cfg = readConfig()
    if not cfg then return end
    local palIconResetNeeded = false
    local captureChanged = false
    local qualityRes = nil
    for _, ch in ipairs(changed) do
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
            if ch.c.key == "Minimap capture FPS cap"
               or ch.c.key == "Minimap capture LOD bias"
               or ch.c.key == "Minimap image quality %"
               or ch.c.key == "Reduce captures when idle" then
                captureChanged = true
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
        if captureChanged then
            local actor = getModActor()
            if actor then applyCaptureSettings(actor) end
        end
        if qualityRes then
            applyRenderQuality(qualityRes)  -- resize the render target live
        end
    end
end

-- ---------------------------------------------------------------
-- Loops and registration
-- ---------------------------------------------------------------
RegisterKeyBind(MENU_KEY, function()
    ExecuteInGameThread(function() pcall(toggleMenu) end)
end)

registerZoomKeys()

LoopAsync(250, function()
    -- cheap pre-check on the async thread: don't even schedule game-thread
    -- work while the menu is closed
    if menuOpen then
        ExecuteInGameThread(function()
            pcall(collectChanges)
        end)
    end
    return false
end)

LoopAsync(20000, function()
    ExecuteInGameThread(function()
        pcall(janitorPass)
    end)
    return false
end)

-- Remove icons of collected/despawned items (chests, eggs, notes, effigies)
-- a few seconds after they leave the world; then hide effigies and notes
-- whose actor persists but is already collected by this player.
LoopAsync(8000, function()
    ExecuteInGameThread(function()
        pcall(sweepCollectedIcons)
        pcall(hideCollectedObtainables)
    end)
    return false
end)

LoopAsync(1000, function()
    ExecuteInGameThread(function()
        local name = currentWorldName()
        if name == nil then return end
        if name ~= worldName then
            -- world changed: the old actor and widget died with it. Clear
            -- every cached reference so nothing stale is ever touched.
            worldName = name
            cachedActor = nil
            lastActorScan = 0.0          -- allow an immediate re-scan in the new world
            desyncStreak = 0             -- fresh actor -> fresh desync tracking
            lastCaptureActive = nil
            captureAppliedFor = nil
            rtSizedFor = nil
            lastCapX, lastCapY, lastCapZ, lastCapYaw, lastCapOrtho = nil, nil, nil, nil, nil
            lastCapTime = 0.0
            captureGen = captureGen + 1  -- stop any orphaned capture loop
            dropMenuRefs()
        elseif menuOpen and not menuUsable() then
            -- same-name world swap (e.g. logout/login): widget is gone
            dropMenuRefs()
        end
        -- Terrain capture is left to the stock blueprint. The config menu is
        -- opened/closed only with F5 (no auto-open on the title screen).
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
