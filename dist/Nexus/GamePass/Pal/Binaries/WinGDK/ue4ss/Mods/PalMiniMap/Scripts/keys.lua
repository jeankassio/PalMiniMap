-- =====================================================================
-- keys.lua - the key bindings, in a plain config.ini the player can edit
--
-- WHY AN INI AND NOT THE F5 MENU. The menu is UMG built from Lua; it has
-- checkboxes and sliders and no way to capture "press the key you want"
-- without hooking input while a widget has focus - which is precisely the
-- kind of input-thread work the threading rule at the top of main.lua
-- forbids. A text file is the honest answer: no new input path, no new
-- widget, and the player can read what the options are.
--
-- The file sits beside `minimap_settings.json`, i.e. next to the mod
-- folder rather than inside `Scripts/`, and it is WRITTEN ON FIRST RUN
-- with the defaults in it, so there is something to edit instead of a
-- format to guess at.
--
-- KEY NAMES ARE UE4SS'S OWN. Whatever is in its global `Key` table works,
-- and that is what makes this future-proof: no table of names to maintain
-- here, and a name that build does not have is reported by name in the
-- log rather than silently ignored. `F1`, `TAB`, `NUM_ONE`, `LEFT_ARROW`,
-- `OEM_PLUS` and so on.
--
-- Modifiers are supported as a `CTRL+`/`ALT+`/`SHIFT+` prefix and are
-- resolved against UE4SS's `ModifierKey` table the same way. If that
-- table is missing, the binding is registered WITHOUT the modifier rather
-- than dropped - a key that works is better than a key that does not.
--
-- NOTHING HERE TOUCHES THE GAME. Parsing happens once at load, on the
-- Lua thread, before any binding is registered; a malformed line costs
-- that one action its custom key and nothing else.
-- =====================================================================

local guard = require("guard")

local M = {}

-- action -> default key names. One action may list several keys; every one
-- of them is bound to it, which is how `+` works on both the numpad and
-- the main row.
local DEFAULTS = {
    menu     = { "F5" },
    megazoom = { "F1" },
    corner   = { "F2" },
    visible  = { "F3" },
    edit     = { "F4" },
    left     = { "LEFT_ARROW" },
    right    = { "RIGHT_ARROW" },
    up       = { "UP_ARROW" },
    down     = { "DOWN_ARROW" },
    zoomIn   = { "ADD", "OEM_PLUS" },
    zoomOut  = { "SUBTRACT", "OEM_MINUS" },
}

-- The order the file is written in, and the label each line gets. A plain
-- pairs() walk would shuffle the file every time it was rewritten.
local ORDER = {
    { "menu",     "open and close the settings menu" },
    { "megazoom", "toggle megazoom (see the whole region)" },
    { "corner",   "move the minimap to the next corner" },
    { "visible",  "show or hide the minimap" },
    { "edit",     "edit mode: arrows move it, zoom keys resize it" },
    { "zoomIn",   "zoom in" },
    { "zoomOut",  "zoom out" },
    { "left",     "edit mode only: move left" },
    { "right",    "edit mode only: move right" },
    { "up",       "edit mode only: move up" },
    { "down",     "edit mode only: move down" },
}

-- lowercase action name -> the canonical one, so the file may be written
-- in any case the player likes.
local ACTION_BY_LOWER = {}
for action in pairs(DEFAULTS) do ACTION_BY_LOWER[action:lower()] = action end

function M.defaults() return DEFAULTS end
function M.order() return ORDER end

-- ---------------------------------------------------------------
-- Writing the file
-- ---------------------------------------------------------------
local function joinNames(list)
    return table.concat(list, ", ")
end

-- Every name in a UE4SS table, sorted, wrapped into comment lines.
--
-- ENUMERATED FROM THE LIVE TABLE rather than typed out here: it is the
-- exact set THIS build accepts, so the file can never advertise a key that
-- would then be rejected, and a UE4SS update that adds keys documents
-- itself. Sorted because `pairs` order would reshuffle the file every time
-- it was written.
local function nameList(tbl, prefix, width)
    if type(tbl) ~= "table" then return { prefix .. "(not available)" } end
    local names = {}
    for name, _ in pairs(tbl) do
        if type(name) == "string" then names[#names + 1] = name end
    end
    if #names == 0 then return { prefix .. "(none)" } end
    table.sort(names)

    local lines, line = {}, nil
    for i = 1, #names do
        if line == nil then
            line = prefix .. names[i]
        elseif #line + 2 + #names[i] > width then
            lines[#lines + 1] = line
            line = prefix .. names[i]
        else
            line = line .. ", " .. names[i]
        end
    end
    if line ~= nil then lines[#lines + 1] = line end
    return lines
end

local function defaultText()
    local out = {
        "; PalMiniMap key bindings.",
        ";",
        "; One action per line. Several keys may be given for one action,",
        "; separated by commas, and each of them will work:",
        ";",
        ";     zoomIn = ADD, OEM_PLUS",
        ";",
        "; A CTRL+, ALT+ or SHIFT+ prefix is allowed:",
        ";",
        ";     menu = CTRL+M",
        ";",
        "; Action names and key names are not case sensitive. A key this",
        "; build does not know is reported in UE4SS.log and that action",
        "; keeps its default, so a typo can never leave you without a key.",
        ";",
        "; Delete this file to get the defaults back.",
        ";",
        "; ------------------------------------------------------------------",
        "; MODIFIERS this build accepts:",
    }
    for _, l in ipairs(nameList(ModifierKey, ";   ", 74)) do out[#out + 1] = l end
    out[#out + 1] = ";"
    out[#out + 1] = "; KEYS this build accepts:"
    for _, l in ipairs(nameList(Key, ";   ", 74)) do out[#out + 1] = l end
    out[#out + 1] = "; ------------------------------------------------------------------"
    out[#out + 1] = ""
    out[#out + 1] = "[keys]"
    for i = 1, #ORDER do
        local action, label = ORDER[i][1], ORDER[i][2]
        out[#out + 1] = string.format("%-9s = %-22s ; %s",
            action, joinNames(DEFAULTS[action]), label)
    end
    out[#out + 1] = ""
    return table.concat(out, "\n")
end

local function fileExists(p)
    local ok, f = pcall(io.open, p, "r")
    if not ok or not f then return false end
    pcall(function() f:close() end)
    return true
end

local function writeIfMissing(path)
    if path == nil or fileExists(path) then return end
    local ok, f = pcall(io.open, path, "w")
    if not ok or not f then
        guard.log("could not create '" .. tostring(path) .. "'; the default "
            .. "keys are still in effect")
        return
    end
    pcall(function() f:write(defaultText()) end)
    pcall(function() f:close() end)
    guard.log("wrote default key bindings to '" .. tostring(path) .. "'")
end

-- ---------------------------------------------------------------
-- Reading it
-- ---------------------------------------------------------------
local function readText(p)
    if p == nil then return nil end
    local ok, f = pcall(io.open, p, "r")
    if not ok or not f then return nil end
    local read, text = pcall(function() return f:read("*a") end)
    pcall(function() f:close() end)
    if not read or type(text) ~= "string" then return nil end
    return text
end

-- "  CTRL+F5  " -> "CTRL", "F5".  Case and spacing are the player's to get
-- wrong, so both are normalised here rather than demanded of them.
local function splitBinding(token)
    token = token:gsub("^%s+", ""):gsub("%s+$", "")
    if token == "" then return nil end
    local mods = {}
    while true do
        local mod, rest = token:match("^([%a]+)%s*%+%s*(.+)$")
        if mod == nil then break end
        mods[#mods + 1] = mod:upper()
        token = rest
    end
    return token:upper(), mods
end

-- Parse `[keys]` into action -> { "F5", ... }. Anything outside that
-- section, and any action that is not one of ours, is ignored: the file is
-- the player's and may grow comments or sections we do not know about.
local function parse(text, report)
    local out = {}
    if text == nil then return out end
    local section = ""
    for raw in (text .. "\n"):gmatch("([^\r\n]*)\r?\n") do
        -- A `for` control variable is const on newer Lua, so the trimmed
        -- copy is its own local rather than an assignment back to `raw`.
        local line = raw:gsub("[;#].*$", "")             -- strip comments
        line = line:gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" then
            local s = line:match("^%[%s*(.-)%s*%]$")
            if s ~= nil then
                section = s:lower()
            elseif section == "keys" then
                local k, v = line:match("^([%w_]+)%s*=%s*(.*)$")
                if k ~= nil then
                    -- Action names are matched without case, like the key
                    -- names below: `zoomIn`, `zoomin` and `ZOOMIN` are one
                    -- thing, and expecting a player to reproduce the camel
                    -- case of an internal identifier is a trap.
                    local canon = ACTION_BY_LOWER[k:lower()]
                    if canon == nil then
                        report("'" .. k .. "' is not a PalMiniMap action; "
                            .. "ignoring that line")
                    else
                        k = canon
                        local list = {}
                        for token in v:gmatch("[^,]+") do
                            list[#list + 1] = token
                        end
                        out[k] = list
                    end
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------
-- Resolving names against UE4SS's tables
-- ---------------------------------------------------------------
local function resolveModifiers(names, report)
    if names == nil or #names == 0 then return nil end
    if type(ModifierKey) ~= "table" then
        report("this UE4SS build has no ModifierKey table, so the modifier "
            .. "was dropped and the plain key was bound instead")
        return nil
    end
    local out = {}
    for i = 1, #names do
        local v = ModifierKey[names[i]]
        if v == nil then
            report("'" .. names[i] .. "' is not a modifier UE4SS knows")
            return nil
        end
        out[#out + 1] = v
    end
    return out
end

-- Returns action -> list of { key = <Key value>, mods = <list|nil>,
-- name = <as written> }, with the defaults filled in for anything the file
-- did not give a usable answer for.
function M.load(path)
    writeIfMissing(path)

    local said = {}
    local function report(msg)
        if said[msg] then return end
        said[msg] = true
        guard.log("config.ini: " .. msg)
    end

    local wanted = parse(readText(path), report)
    local out, customised = {}, 0

    for action, defaultNames in pairs(DEFAULTS) do
        local names = wanted[action]
        local usedDefault = false
        if names == nil or #names == 0 then
            names = defaultNames
            usedDefault = true
        end

        local bindings = {}
        for i = 1, #names do
            local name, mods = splitBinding(names[i])
            if name ~= nil then
                -- `Key` is UE4SS's own table, so any name that build has
                -- works and no list has to be maintained here.
                local value = (type(Key) == "table") and Key[name] or nil
                if value == nil then
                    report("'" .. name .. "' is not a key UE4SS knows, so "
                        .. action .. " keeps its default")
                else
                    bindings[#bindings + 1] = {
                        key = value, name = name,
                        mods = resolveModifiers(mods, report),
                    }
                end
            end
        end

        -- Nothing in the file resolved: fall back rather than leave the
        -- action unbound, which would look like the mod being broken.
        if #bindings == 0 and not usedDefault then
            for i = 1, #defaultNames do
                local value = (type(Key) == "table") and Key[defaultNames[i]] or nil
                if value ~= nil then
                    bindings[#bindings + 1] = { key = value, name = defaultNames[i] }
                end
            end
        elseif not usedDefault then
            customised = customised + 1
        end

        out[action] = bindings
    end

    if customised > 0 then
        guard.log(string.format("config.ini: %d key binding%s customised",
            customised, customised == 1 and "" or "s"))
    end
    return out
end

-- What the keys actually ended up as, for the "loaded" line in the log.
function M.describe(bound)
    local parts = {}
    for i = 1, #ORDER do
        local action = ORDER[i][1]
        local list = bound and bound[action]
        if list ~= nil and list[1] ~= nil then
            parts[#parts + 1] = list[1].name .. " " .. action
        end
    end
    return table.concat(parts, ", ")
end

return M
