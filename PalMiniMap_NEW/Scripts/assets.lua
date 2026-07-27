-- =====================================================================
-- assets.lua - the ONE place in the mod that ever loads a texture
--
-- WHY THIS FILE EXISTS (the 2.1.1 stutter).
--
-- `LoadAsset` is SYNCHRONOUS. It stalls the game thread while the package
-- is found, read and its UObjects constructed. There is no async variant
-- exposed to UE4SS Lua, so the only lever the mod has is HOW OFTEN it
-- pulls that lever - and 2.1.0 pulled it far too often, in two places at
-- once:
--
--   * sources.lua probed each new species with its own StaticFindObject +
--     LoadAsset, up to six per scan, ON THE SCAN TICK;
--   * render.lua then loaded the very same path AGAIN through its own
--     queue, two per movement tick - twenty a second - and, when an icon
--     had no texture yet, called LoadAsset for the fallback marker inside
--     the per-icon draw loop.
--
-- So every pal species cost two synchronous package loads, the second one
-- pointless, and in a place with many species the mod issued a steady
-- stream of them for as long as new pals kept walking into range. That is
-- exactly what the player described: the map comes up, the pals are
-- generic arrows, and the game hitches as each arrow turns into a
-- portrait.
--
-- ---------------------------------------------------------------------
-- WHAT CHANGED IN 2.2.0: THE ICONS NO LONGER COME FROM A PACKAGE.
--
-- Throttling LoadAsset made the stutter rarer but could not remove it,
-- because the cost is not really the icon. `LoadAsset` is a synchronous
-- FLUSH of the engine's async loading queue: it waits for whatever the
-- game itself happens to be streaming at that instant before it even
-- starts on ours. Riding into town, the game is streaming constantly, so
-- our tiny 128x128 icon can block the frame for as long as a level chunk
-- takes. No budget the mod can pick fixes that, because the mod is not
-- the one spending the time.
--
-- So the icons are now shipped WITH the mod, as PNG, in `icons/`, and
-- loaded with `UKismetRenderingLibrary::ImportFileAsTexture2D`. That call
-- reads a loose file, decodes it through IImageWrapper and builds a
-- TRANSIENT texture: one mip, `NeverStream`. It touches no package, no
-- async loading queue and no streaming manager, so it cannot queue behind
-- the game's own IO, and a 64x64 portrait decodes in a fraction of a
-- millisecond. `tools/extract_icons.py` pulls them out of the game's own
-- .pak, so they are the same art, at the size the minimap draws them.
--
-- THE PRICE, and it is paid honestly below: a transient texture belongs
-- to no package, so the only thing keeping it alive is the UMG brush it
-- is sitting on. The moment the last icon using it swaps to something
-- else it is garbage, and Unreal will eventually take it - leaving a dead
-- pointer in our cache. Handing THAT to SetBrushFromTexture is an access
-- violation. Two things guard against it, see `M.get` and `evict`.
--
-- Anything with no PNG beside the mod - the world map texture above all,
-- which is enormous and loaded exactly once - still goes through
-- LoadAsset on the old throttle. Nothing regresses if `icons/` is missing
-- or the engine refuses the import; the mod just falls back and logs it.
--
-- ---------------------------------------------------------------------
-- The design here:
--
--   1. NOTHING ON A DRAW OR SCAN PATH EVER BLOCKS. `get()` and `probe()`
--      are table lookups. A miss only enqueues the path.
--   2. THREE STAGES, cheapest first, because they differ by orders of
--      magnitude. `StaticFindObject` costs a hash lookup and no IO at
--      all, so a texture the game already has resident is adopted for
--      free (and comes with its full mip chain). What is missing goes to
--      the PNG importer if we ship one. Only what we do not ship reaches
--      LoadAsset.
--   3. EACH STAGE PAYS FOR ITSELF. The importer gets a slice of game
--      thread per pump and stops when it is spent. LoadAsset gets at most
--      one call per pump and is TIMED: the next one is held off for a
--      multiple of what the last cost, so a load that took 5 ms buys
--      200 ms of silence. Self-limiting on any machine, no tuning.
--   4. FAILURES BACK OFF AND THEN GIVE UP for the session, and are
--      forgiven again on a world change, because an asset that cannot be
--      found during a load screen may exist perfectly well once the world
--      is up.
-- =====================================================================

local guard = require("guard")

local M = {}

-- TextureFilter: 0 Nearest, 1 Bilinear, 2 Trilinear, 3 Default
local TF_TRILINEAR = 2

local MAX_ATTEMPTS = 3          -- synchronous loads before a path is given up
local RETRY_SECONDS = { 0.75, 3.0, 10.0 }

-- The LoadAsset throttle. `COST_MULTIPLIER` is the important number: it is
-- the share of wall time the mod is allowed to spend inside LoadAsset,
-- upside down. 40 means "at most one fortieth", i.e. 2.5%.
local COST_MULTIPLIER = 40
local MIN_GAP = 0.08            -- ceiling of ~12 loads/s even when free
local MAX_GAP = 0.75            -- never sulk for longer than this
local CHEAP_PER_PUMP = 8        -- name lookups, no IO

-- The importer's budget. This one is a plain time slice rather than a gap,
-- because an import is short and, unlike LoadAsset, predictable: it cannot
-- block behind the engine's loader. A millisecond and a half a tick fills a
-- screenful of new species in two or three ticks and is invisible in a frame.
local IMPORT_BUDGET = 0.0015
local IMPORT_LIB = "/Script/Engine.Default__KismetRenderingLibrary"

-- How long a texture may sit in the cache unasked-for before we let go of
-- it. This is the FIRST line of defence for transient textures: an icon
-- nobody has drawn for this long is about to become Unreal's to collect, and
-- it is far safer to drop our own reference while the object is still valid
-- than to discover afterwards that it was taken. Re-importing costs a
-- fraction of a millisecond, so a species that walks back into range pays
-- almost nothing.
local EVICT_AFTER = 20.0

local cache = {}                -- path -> UTexture2D, resident and validated
local pinned = {}               -- path -> true, never evicted (see loadNow)
local mapish = {}               -- path -> true for the terrain texture
local attempts = {}             -- path -> synchronous loads spent so far
local dueAt = {}                -- path -> earliest next attempt
local gaveUp = {}               -- path -> true once out of attempts
local queued = {}               -- path -> "find" | "import" | "load"
local usedAt = {}               -- path -> when it was last asked for
local checkedAt = {}            -- path -> pump serial when last validated

local findQ, findHead, findTail = {}, 1, 0
local importQ, importHead, importTail = {}, 1, 0
local loadQ, loadHead, loadTail = {}, 1, 0

local quality = 0
local nextLoadAt = 0.0
local serial = 0                -- bumped once per pump
local loadsDone, loadsFailed, adoptedFree = 0, 0, 0
local importsDone, importsFailed, collected = 0, 0, 0
local reportAt, reportedFill = nil, false
local REPORT_AFTER = 30.0       -- long enough to outlast every retry backoff

-- ---------------------------------------------------------------
-- The PNG route
--
-- The FILE NAME IS THE KEY, deliberately: the local file for an asset is
-- its object name with .png on it, so
--
--   /Game/Pal/Texture/PalIcon/Normal/T_Alpaca_icon_normal.T_Alpaca_icon_normal
--     -> <mod>/icons/T_Alpaca_icon_normal.png
--
-- Nothing else in the mod has to know this route exists. sources.lua and
-- render.lua still ask for the asset path they always asked for; whether it
-- arrives from a file or from a package is entirely this file's business,
-- and a path with no file beside it simply takes the old road.
-- ---------------------------------------------------------------
local iconDir = nil             -- absolute, no trailing slash; nil disables
local importer = nil
local importState = 0           -- 0 untried, 1 usable, 2 unavailable
local pngPath = {}              -- asset path -> file name, or false for none

local function rawImport(lib, file) return lib:ImportFileAsTexture2D(lib, file) end

local function canOpen(p)
    local ok, f = pcall(io.open, p, "rb")
    if not ok or not f then return false end
    pcall(function() f:close() end)
    return true
end

local function pngFor(path)
    local known = pngPath[path]
    if known ~= nil then return known or nil end
    if iconDir == nil then return nil end
    -- object name: after the last dot if the path carries one, else after
    -- the last slash ("/Game/.../T_WorldMap" has no dot at all).
    local name = path:match("%.([^%.]+)$") or path:match("([^/]+)$")
    local file = name and (iconDir .. "/" .. name .. ".png") or nil
    if file ~= nil and canOpen(file) then
        pngPath[path] = file
        return file
    end
    pngPath[path] = false
    return nil
end

local function ensureImporter()
    if importState ~= 0 then return importState == 1 end
    local lib = guard.get(StaticFindObject, IMPORT_LIB)
    if lib == nil or not guard.alive(lib) then
        importState = 2
        guard.log("KismetRenderingLibrary is not reachable on this build; icons will "
            .. "come from the package loader instead of icons/*.png, which is slower "
            .. "but correct")
        return false
    end
    importer = lib
    importState = 1
    return true
end

-- ---------------------------------------------------------------
-- Streaming flags
--
-- The terrain is one texture MAGNIFIED several times across the window, so
-- which mip is resident is the whole difference between sharp and soft -
-- forcing it resident is the fix, and it is one texture.
--
-- Icons are the opposite case and 2.1.0 got them backwards. They are drawn
-- at eighteen pixels. Forcing every pal portrait's full mip chain resident
-- told the streamer to pull megabytes of texels that are then scaled down
-- to nothing - VRAM, and a burst of streaming IO right after the load that
-- the player feels as the same hitch the load itself caused. So icons are
-- left alone. (Imported icons have one mip and never stream at all, so none
-- of this applies to them; the flags are harmless there.)
-- ---------------------------------------------------------------
local function rawForceResident(tex) tex.bForceMiplevelsToBeResident = true end
local function rawForceGlobal(tex) tex.bGlobalForceMipLevelsToBeResident = true end
local function rawNoBias(tex) tex.bIgnoreStreamingMipBias = true end
local function rawTrilinear(tex) tex.Filter = TF_TRILINEAR end

local function tune(path, tex)
    if tex == nil or quality <= 0 then return end
    if mapish[path] then
        guard.get(rawForceResident, tex)
        guard.get(rawForceGlobal, tex)
        if quality >= 3 then
            guard.get(rawNoBias, tex)
            guard.get(rawTrilinear, tex)
        end
    elseif quality >= 3 then
        guard.get(rawTrilinear, tex)
    end
end

-- ---------------------------------------------------------------
-- Queues
-- ---------------------------------------------------------------
local function pushFind(path)
    findTail = findTail + 1
    findQ[findTail] = path
    queued[path] = "find"
end

local function pushImport(path)
    importTail = importTail + 1
    importQ[importTail] = path
    queued[path] = "import"
end

local function pushLoad(path)
    loadTail = loadTail + 1
    loadQ[loadTail] = path
    queued[path] = "load"
end

local function adopt(path, obj)
    cache[path] = obj
    attempts[path] = nil
    dueAt[path] = nil
    gaveUp[path] = nil
    queued[path] = nil
    checkedAt[path] = serial
    usedAt[path] = os.clock()
    tune(path, obj)
end

-- ---------------------------------------------------------------
-- Public, hot-path API. Both of these are O(1) table work and MUST stay
-- that way: they are called for every icon on every movement tick and for
-- every character in every scan.
-- ---------------------------------------------------------------

-- The texture if it is resident, nil otherwise. A miss schedules the work
-- and returns immediately; the caller draws its fallback in the meantime.
--
-- THE VALIDITY CHECK is the second line of defence described at the top of
-- the file, and the reason this is not a bare table lookup. An imported
-- texture is transient: nothing owns it but the brush it is on, so if every
-- icon using it moved on, Unreal is free to collect it and our cached
-- pointer is dead. Handing a dead UObject to SetBrushFromTexture is an
-- access violation with no Lua error to catch. Checking is cheap and, more
-- importantly, is done ONCE PER PUMP per path rather than once per draw -
-- sixty icons all wanting the same portrait cost one check between them.
function M.get(path)
    if path == nil or path == "" then return nil end
    local tex = cache[path]
    if tex ~= nil then
        if checkedAt[path] == serial then return tex end
        checkedAt[path] = serial
        usedAt[path] = os.clock()
        if guard.alive(tex) then return tex end
        -- collected out from under us: forget it and fetch it again
        cache[path] = nil
        attempts[path] = nil
        collected = collected + 1
    end
    if queued[path] ~= nil or gaveUp[path] then return nil end
    local due = dueAt[path]
    if due ~= nil and os.clock() < due then return nil end
    pushFind(path)
    return nil
end

-- Does this asset EXIST? true / false / nil while the answer is not in
-- yet. Used to tell a pal from a human without touching the class tree -
-- see sources.lua. nil is not a failure, it means "ask again next scan".
--
-- THE FILE IS THE ANSWER, once we have proof of it. `icons/` holds the whole
-- of /Game/Pal/Texture/PalIcon/Normal, which is every path sources.lua can
-- build, so a missing file means the species icon does not exist - not that
-- we should go and ask the package loader three times and wait for it to give
-- up. That mattered: a town full of human NPCs and every alpha's `_BOSS`
-- name were the last things in the mod still spending synchronous loads, and
-- a town is exactly where the player noticed the stutter.
--
-- Guarded by `importsDone > 0` on purpose, in the same spirit as the rule
-- that nothing is filtered until one icon has actually resolved: until an
-- import has really worked we have no evidence `icons/` is there at all, and
-- answering "no such species" for everything would classify every pal in the
-- world as a human. Until then this stays cautious and the old road answers.
function M.probe(path)
    if path == nil or path == "" then return false end
    if gaveUp[path] then return false end
    if cache[path] == nil and importsDone > 0 and iconDir ~= nil
       and pngFor(path) == nil then
        return false
    end
    if M.get(path) ~= nil then return true end
    if gaveUp[path] then return false end
    return nil
end

-- Deliberately synchronous, for the handful of textures the minimap cannot
-- be drawn without (the terrain, the player marker, the generic marker every
-- icon falls back to). Called from build(), which is already a heavy one-off,
-- and never from a per-frame path. These are PINNED: they sit on a permanent
-- brush for the life of the widget, so eviction would only cost a re-fetch.
function M.loadNow(path, isMap)
    if path == nil or path == "" then return nil end
    if isMap then mapish[path] = true end
    pinned[path] = true

    local tex = M.get(path)
    if tex ~= nil then return tex end

    local obj = guard.get(StaticFindObject, path)
    if obj == nil or not guard.alive(obj) then
        local file = pngFor(path)
        if file ~= nil and ensureImporter() then
            obj = guard.get(rawImport, importer, file)
        end
    end
    if obj == nil or not guard.alive(obj) then
        guard.get(LoadAsset, path)
        obj = guard.get(StaticFindObject, path)
    end
    if obj ~= nil and guard.alive(obj) then
        adopt(path, obj)
        return obj
    end
    return nil
end

-- ---------------------------------------------------------------
-- The pump. Called once per movement tick from main.lua, on the game
-- thread, and the only code in the mod allowed to load a texture outside
-- of a build.
-- ---------------------------------------------------------------
local evictKey = nil

-- Let go of what nobody is drawing. See EVICT_AFTER: for a transient
-- texture this is not housekeeping, it is the safe half of the lifetime
-- problem - dropping a live reference we no longer need, rather than
-- inspecting a dead one. A couple of entries per pump sweeps the whole
-- cache in a second or two.
local function evict(now)
    -- `next` throws on a key that is no longer in the table, and M.get drops
    -- entries out from under this traversal when it finds one collected.
    if evictKey ~= nil and cache[evictKey] == nil then evictKey = nil end
    for _ = 1, 2 do
        local k = next(cache, evictKey)
        if k == nil then evictKey = nil; return end
        local last = usedAt[k]
        if pinned[k] or last == nil or (now - last) < EVICT_AFTER then
            evictKey = k
        else
            cache[k] = nil
            usedAt[k] = nil
            checkedAt[k] = nil
            evictKey = nil          -- the traversal key is gone; restart
            return
        end
    end
end

local function stageFind()
    local budget = CHEAP_PER_PUMP
    while budget > 0 and findHead <= findTail do
        local path = findQ[findHead]
        findQ[findHead] = nil
        findHead = findHead + 1
        if path ~= nil and cache[path] == nil then
            local obj = guard.get(StaticFindObject, path)
            if obj ~= nil and guard.alive(obj) then
                adopt(path, obj)            -- already resident: free, and mipped
                adoptedFree = adoptedFree + 1
            elseif pngFor(path) ~= nil then
                pushImport(path)
            else
                pushLoad(path)              -- nothing shipped; the slow road
            end
            budget = budget - 1
        elseif path ~= nil then
            queued[path] = nil
        end
    end
    if findHead > findTail then findHead, findTail = 1, 0 end
end

local function stageImport(now)
    if importHead > importTail then importHead, importTail = 1, 0; return end

    if not ensureImporter() then
        -- No importer on this build: everything waiting here belongs on the
        -- package loader instead. Done once - importState is sticky.
        while importHead <= importTail do
            local path = importQ[importHead]
            importQ[importHead] = nil
            importHead = importHead + 1
            if path ~= nil then pushLoad(path) end
        end
        importHead, importTail = 1, 0
        return
    end

    local deadline = now + IMPORT_BUDGET
    while importHead <= importTail do
        local path = importQ[importHead]
        importQ[importHead] = nil
        importHead = importHead + 1
        if path ~= nil then
            queued[path] = nil
            if cache[path] == nil then
                local file = pngFor(path)
                local tex = nil
                if file ~= nil then tex = guard.get(rawImport, importer, file) end
                if tex ~= nil and guard.alive(tex) then
                    adopt(path, tex)
                    importsDone = importsDone + 1
                else
                    -- The file is there but the engine would not take it.
                    -- Stop offering it and let the package loader try.
                    importsFailed = importsFailed + 1
                    pngPath[path] = false
                    pushLoad(path)
                end
            end
        end
        if os.clock() >= deadline then break end
    end
    if importHead > importTail then importHead, importTail = 1, 0 end
end

local function stageLoad(now)
    if loadHead > loadTail then
        loadHead, loadTail = 1, 0
        return
    end
    if now < nextLoadAt then return end

    local path = loadQ[loadHead]
    loadQ[loadHead] = nil
    loadHead = loadHead + 1
    if loadHead > loadTail then loadHead, loadTail = 1, 0 end
    if path == nil then return end
    queued[path] = nil
    if cache[path] ~= nil then return end

    local n = (attempts[path] or 0) + 1
    attempts[path] = n

    local started = os.clock()
    guard.get(LoadAsset, path)
    local cost = os.clock() - started
    local obj = guard.get(StaticFindObject, path)

    if obj ~= nil and guard.alive(obj) then
        adopt(path, obj)
        loadsDone = loadsDone + 1
    else
        loadsFailed = loadsFailed + 1
        if n >= MAX_ATTEMPTS then
            gaveUp[path] = true
            dueAt[path] = nil
        else
            dueAt[path] = os.clock() + (RETRY_SECONDS[n] or 10.0)
        end
    end

    -- Pay for what that cost. This is the whole throttle: the mod cannot
    -- spend more than 1/COST_MULTIPLIER of wall time inside LoadAsset, so
    -- a slow disk or a huge package slows the fill rate down instead of
    -- turning into a visible hitch every tick.
    local gap = cost * COST_MULTIPLIER
    if gap < MIN_GAP then gap = MIN_GAP elseif gap > MAX_GAP then gap = MAX_GAP end
    nextLoadAt = os.clock() + gap
end

function M.pump()
    serial = serial + 1
    local now = os.clock()
    stageFind()
    stageImport(now)
    stageLoad(now)
    evict(now)

    if reportedFill then return end
    if reportAt == nil then
        if (loadsDone + loadsFailed + adoptedFree + importsDone + importsFailed) > 0 then
            reportAt = now + REPORT_AFTER
        end
    elseif now >= reportAt then
        reportedFill = true
        guard.log(string.format(
            "textures after %ds: %d imported from icons/, %d already resident, "
            .. "%d loaded as packages (%d failed, %d imports refused), %d recovered "
            .. "after collection",
            REPORT_AFTER, importsDone, adoptedFree, loadsDone, loadsFailed,
            importsFailed, collected))
        -- The condition is `importsDone`, not `importState`: the CDO can be
        -- reachable and the CALL still fail, and that failure looks like
        -- perfect health from every other angle. This line is the only way a
        -- player's log tells us the fast route never engaged.
        if importsDone == 0 then
            guard.log("no icon was imported from icons/ - the mod is on the slow "
                .. "package route for every texture. Check that icons/ sits beside "
                .. "the Scripts folder, not inside it.")
        end
    end
end

-- ---------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------

-- Where the shipped PNGs live. Absolute, no trailing slash. main.lua works
-- this out from where the scripts were found; if it could not, this is never
-- called and the mod stays on the package loader.
function M.setIconDir(dir)
    if type(dir) ~= "string" or dir == "" then return end
    iconDir = (dir:gsub("\\", "/"):gsub("/+$", ""))
    pngPath = {}
end

function M.setQuality(level, mapPath)
    quality = tonumber(level) or 0
    if type(mapPath) == "string" and mapPath ~= "" then
        mapish[mapPath] = true
    end
    for path, tex in pairs(cache) do
        if guard.alive(tex) then tune(path, tex) end
    end
end

-- A world change invalidates every UObject we hold, and forgives every
-- failure: an asset that could not be found on the title screen is not
-- missing, it was simply not mounted yet. `pngPath` survives - which files
-- exist on disk does not depend on which world is loaded - and so does the
-- importer, whose CDO outlives every world.
function M.forget()
    cache, pinned = {}, {}
    attempts, dueAt, gaveUp, queued = {}, {}, {}, {}
    usedAt, checkedAt = {}, {}
    findQ, findHead, findTail = {}, 1, 0
    importQ, importHead, importTail = {}, 1, 0
    loadQ, loadHead, loadTail = {}, 1, 0
    evictKey = nil
    nextLoadAt = 0.0
    reportAt, reportedFill = nil, false
    loadsDone, loadsFailed, adoptedFree = 0, 0, 0
    importsDone, importsFailed, collected = 0, 0, 0
end

-- test hook: how much work is still outstanding
function M.pending()
    return (findTail - findHead + 1) + (importTail - importHead + 1)
         + (loadTail - loadHead + 1)
end

-- test hook: where each texture came from
function M.stats()
    return { imported = importsDone, resident = adoptedFree, packages = loadsDone,
             failed = loadsFailed, refused = importsFailed, collected = collected,
             importer = importState }
end

return M
