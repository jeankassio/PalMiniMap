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
-- The design here:
--
--   1. NOTHING ON A DRAW OR SCAN PATH EVER BLOCKS. `get()` and `probe()`
--      are table lookups. A miss only enqueues the path.
--   2. TWO STAGES, because a name lookup and a package load differ by
--      orders of magnitude. `StaticFindObject` costs a hash lookup and no
--      disk at all, so a texture the game already has resident is adopted
--      for free, several per pump. Only what is genuinely absent reaches
--      the load queue.
--   3. AT MOST ONE `LoadAsset` PER PUMP, and the mod PAYS FOR IT: the
--      call is timed, and the next load is held off for a multiple of
--      what the last one cost. A load that took 5 ms buys 200 ms of
--      silence. This is self-limiting on any machine - a slow disk
--      automatically gets a slower fill rate rather than a stutter - and
--      it needs no tuning per system.
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

-- The load throttle. `COST_MULTIPLIER` is the important number: it is the
-- share of wall time the mod is allowed to spend inside LoadAsset, upside
-- down. 40 means "at most one fortieth", i.e. 2.5%.
local COST_MULTIPLIER = 40
local MIN_GAP = 0.08            -- ceiling of ~12 loads/s even when free
local MAX_GAP = 0.75            -- never sulk for longer than this
local CHEAP_PER_PUMP = 8        -- name lookups, no disk

local cache = {}                -- path -> UTexture2D, resident and validated
local mapish = {}               -- path -> true for the terrain texture
local attempts = {}             -- path -> synchronous loads spent so far
local dueAt = {}                -- path -> earliest next attempt
local gaveUp = {}               -- path -> true once out of attempts
local queued = {}               -- path -> "find" | "load" while in a queue

local findQ, findHead, findTail = {}, 1, 0
local loadQ, loadHead, loadTail = {}, 1, 0

local quality = 0
local nextLoadAt = 0.0
local loadsDone, loadsFailed, adoptedFree = 0, 0, 0
local reportAt, reportedFill = nil, false
local REPORT_AFTER = 30.0       -- long enough to outlast every retry backoff

-- ---------------------------------------------------------------
-- Streaming flags
--
-- WHAT CHANGED IN 2.1.1, and why. The terrain is one texture MAGNIFIED
-- several times across the window, so which mip is resident is the whole
-- difference between sharp and soft - forcing it resident is the fix, and
-- it is one texture.
--
-- Icons are the opposite case and 2.1.0 got them backwards. They are drawn
-- at eighteen pixels. Forcing every pal portrait's full mip chain resident
-- told the streamer to pull megabytes of texels that are then scaled down
-- to nothing - VRAM, and a burst of streaming IO right after the load that
-- the player feels as the same hitch the load itself caused. So icons are
-- left to the streamer, which is already picking the correct (tiny) mip
-- for the size they are drawn at. Quality 3 still asks for trilinear
-- filtering on them, which costs nothing.
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
    tune(path, obj)
end

-- ---------------------------------------------------------------
-- Public, hot-path API. Both of these are O(1) table work and MUST stay
-- that way: they are called for every icon on every movement tick and for
-- every character in every scan.
-- ---------------------------------------------------------------

-- The texture if it is resident, nil otherwise. A miss schedules the work
-- and returns immediately; the caller draws its fallback in the meantime.
function M.get(path)
    if path == nil or path == "" then return nil end
    local tex = cache[path]
    if tex ~= nil then return tex end
    if queued[path] ~= nil or gaveUp[path] then return nil end
    local due = dueAt[path]
    if due ~= nil and os.clock() < due then return nil end
    pushFind(path)
    return nil
end

-- Does this asset EXIST? true / false / nil while the answer is not in
-- yet. Used to tell a pal from a human without touching the class tree -
-- see sources.lua. nil is not a failure, it means "ask again next scan".
function M.probe(path)
    if path == nil or path == "" then return false end
    if cache[path] ~= nil then return true end
    if gaveUp[path] then return false end
    M.get(path)
    return nil
end

-- Deliberately synchronous, for the handful of textures the minimap
-- cannot sensibly be drawn without (the terrain, the player marker, the
-- generic marker every icon falls back to). Called from build(), which is
-- already a heavy one-off, and never from a per-frame path.
function M.loadNow(path, isMap)
    if path == nil or path == "" then return nil end
    if isMap then mapish[path] = true end
    local tex = cache[path]
    if tex ~= nil then return tex end
    local obj = guard.get(StaticFindObject, path)
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
-- thread, and it is the only code in the mod allowed to call LoadAsset
-- outside of a build.
-- ---------------------------------------------------------------
local checkKey = nil

-- Textures can die with their world. A UMG brush keeps its own reference,
-- so this is belt and braces rather than the main line of defence, and a
-- couple of entries per pump is enough to sweep the whole cache in a
-- second or two.
local function revalidate()
    for _ = 1, 2 do
        local k, v = next(cache, checkKey)
        if k == nil then checkKey = nil; return end
        if guard.alive(v) then
            checkKey = k
        else
            cache[k] = nil
            checkKey = nil          -- the traversal key is gone; restart
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
                adopt(path, obj)
                adoptedFree = adoptedFree + 1
            else
                pushLoad(path)      -- needs the expensive stage
            end
            budget = budget - 1
        elseif path ~= nil then
            queued[path] = nil
        end
    end
    if findHead > findTail then findHead, findTail = 1, 0 end
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
    local now = os.clock()
    stageFind()
    stageLoad(now)
    revalidate()
    if reportedFill then return end
    if reportAt == nil then
        if (loadsDone + loadsFailed + adoptedFree) > 0 then
            reportAt = now + REPORT_AFTER
        end
    elseif now >= reportAt then
        reportedFill = true
    end
end
-- ---------------------------------------------------------------
-- Housekeeping
-- ---------------------------------------------------------------
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
-- missing, it was simply not mounted yet.
function M.forget()
    cache = {}
    attempts, dueAt, gaveUp, queued = {}, {}, {}, {}
    findQ, findHead, findTail = {}, 1, 0
    loadQ, loadHead, loadTail = {}, 1, 0
    checkKey = nil
    nextLoadAt = 0.0
    reportAt, reportedFill = nil, false
    loadsDone, loadsFailed, adoptedFree = 0, 0, 0
end

-- test hook: how much work is still outstanding
function M.pending()
    return (findTail - findHead + 1) + (loadTail - loadHead + 1)
end

return M