-- =====================================================================
-- i18n.lua - the F5 menu in the language the game is running in
--
-- HOW THE LANGUAGE IS FOUND, and why it is the engine's answer and not
-- Palworld's own. The game has an `EPalLanguageType` enum (it is in
-- Palworld.usmap, on `PalDebugSetting.EditorPlayTextLanguageType`), but
-- nothing reachable exposes the LIVE value of it, and its option lives in
-- a save object rather than a config file - `GameUserSettings.ini` has no
-- `[Internationalization] Culture=` line on this build, so there is no
-- file to read either.
--
-- What Palworld does do is drive UE's own localisation system: every UI
-- string is an FText and `SetCurrentCulture` is in the shipping exe, so
-- picking a language in the options sets the ENGINE culture. That is a
-- plain static getter with no parameters, which is the cheapest and
-- safest kind of call this mod makes:
--
--     /Script/Engine.Default__KismetInternationalizationLibrary
--         GetCurrentLanguage()   -> "pt-BR"
--         GetCurrentCulture()    -> "pt-BR"
--         GetCurrentLocale()     -> "pt-BR"
--
-- All four names were confirmed present in Palworld-Win64-Shipping.exe
-- before a line of this was written, the same way `CaptureScene` and
-- `CreateRenderTarget2D` were. NOTHING HERE IS GUESSED.
--
-- THE CDO RULE APPLIES (2.1.3): never `guard.alive()` a class default
-- object. `IsValid()` is actor-ish and a CDO need not answer it;
-- requiring it is how the PalUtility route silently never engaged.
--
-- THE LOOKUP KEY IS THE ENGLISH STRING ITSELF. There is no separate set
-- of message IDs to keep in sync, menu.lua's LAYOUT is untouched, and any
-- string with no translation falls back to English automatically - so a
-- new option added to the menu is never a crash, only an untranslated
-- row. Adding a language is one more table below.
-- =====================================================================

local guard = require("guard")

local M = {}

local LIB_PATHS = {
    "/Script/Engine.Default__KismetInternationalizationLibrary",
    "/Script/Engine.KismetInternationalizationLibrary",
}
-- Order matters only in that the first one to answer wins; all three
-- return the same thing on a stock build.
local GETTERS = { "GetCurrentLanguage", "GetCurrentCulture", "GetCurrentLocale" }

-- ---------------------------------------------------------------
-- Translations. Keyed by the English string exactly as menu.lua writes
-- it, so a typo here is a missing translation and never a missing row.
-- ---------------------------------------------------------------
local STRINGS = {}

STRINGS["pt-BR"] = {
    -- headers
    ["Minimap"]                             = "Minimapa",
    ["Pals"]                                = "Pals",
    ["People"]                              = "Pessoas",
    ["Items"]                               = "Itens",
    ["Points of interest"]                  = "Pontos de interesse",
    ["Performance"]                         = "Desempenho",
    ["Troubleshooting"]                     = "Diagnóstico",

    -- minimap
    ["Show minimap"]                        = "Mostrar minimapa",
    ["Size"]                                = "Tamanho",
    ["Opacity"]                             = "Opacidade",
    ["Circular shape"]                      = "Formato circular",
    ["Live render"]                         = "Renderização ao vivo",
    ["Live render: 0 lit, 1 flat (may fall back)"] =
        "Ao vivo: 0 iluminado, 1 plano (pode reverter)",
    ["Terrain quality (0 low - 3 sharp)"]   = "Qualidade do terreno (0 baixa - 3 nítida)",
    ["Zoom (world units)"]                  = "Zoom (unidades do mundo)",
    ["Megazoom (F1) range"]                 = "Alcance do megazoom (F1)",
    ["Auto zoom out while moving"]          = "Afastar zoom automaticamente ao se mover",
    ["Rotate with camera"]                  = "Girar com a câmera",
    ["Keep icons upright"]                  = "Manter ícones na vertical",
    ["Hide behind the game's menu"]         = "Ocultar atrás do menu do jogo",
    ["Hide while in a base camp"]           = "Ocultar dentro de um acampamento",
    ["Icon size"]                           = "Tamanho dos ícones",
    ["Player marker size"]                  = "Tamanho do marcador do jogador",

    -- pals
    ["Show pals"]                           = "Mostrar Pals",
    ["Only shiny pals"]                     = "Apenas Pals sortudos",
    ["Show pals while megazoomed"]          = "Mostrar Pals durante o megazoom",
    ["Max pal icons"]                       = "Máximo de ícones de Pals",

    -- people
    ["Show other players"]                  = "Mostrar outros jogadores",
    ["Show NPC humans"]                     = "Mostrar NPCs humanos",
    ["Max NPC icons"]                       = "Máximo de ícones de NPCs",
    ["Max other-player icons"]              = "Máximo de ícones de outros jogadores",
    ["Show death locations"]                = "Mostrar locais de morte",

    -- items
    ["Hide collected items"]                = "Ocultar itens já coletados",
    ["Show chests"]                         = "Mostrar baús",
    ["Show eggs"]                           = "Mostrar ovos",
    ["Show notes"]                          = "Mostrar anotações",
    ["Show lifmunk effigies"]               = "Mostrar efígies de Lifmunk",
    ["Show skillfruit trees"]               = "Mostrar árvores de frutas de habilidade",

    -- points of interest
    ["Show fast travel points"]             = "Mostrar pontos de viagem rápida",
    ["Show dungeons"]                       = "Mostrar masmorras",
    ["Show towers"]                         = "Mostrar torres",
    ["Show player base camps"]              = "Mostrar acampamentos de jogadores",
    ["Show enemy camps"]                    = "Mostrar acampamentos inimigos",
    ["Show ore / lotus / junk"]             = "Mostrar minérios / lótus / sucata",
    ["Show fishing spots"]                  = "Mostrar pontos de pesca",
    ["Show buried treasure"]                = "Mostrar tesouros enterrados",

    -- performance
    ["Re-render terrain every (ms)"]        = "Renderizar terreno a cada (ms)",
    ["Camera height above player"]          = "Altura da câmera acima do jogador",
    ["Auto: live render up to zoom"]        = "Ao vivo até o zoom de",
    ["Update rate (ms, lower = smoother)"]  = "Taxa de atualização (ms, menor = mais fluido)",
    ["Rescan world every (ms)"]             = "Reescanear o mundo a cada (ms)",
    ["Max point-of-interest icons"]         = "Máximo de ícones de pontos de interesse",

    -- troubleshooting
    ["Log game UI widget names"]            = "Registrar nomes dos widgets do jogo",

    -- chrome
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] fechar  [F1] megazoom  [F2] canto  [F3] mostrar/ocultar  [F4] editar  [+/-] zoom",
    ["Changes save and apply instantly."]   = "As alterações são salvas e aplicadas na hora.",
}

-- ---------------------------------------------------------------
-- Which table to use
-- ---------------------------------------------------------------
local S = { culture = nil, lang = nil, table = nil, probed = false }

-- "pt-BR" -> pt-BR, "pt" -> pt-BR, "pt_PT" -> pt-BR, anything else -> en.
-- Exact match first so a future "pt-PT" entry would win over the prefix.
local function pick(culture)
    if type(culture) ~= "string" or culture == "" then return nil end
    if STRINGS[culture] ~= nil then return culture end
    local base = string.match(culture, "^(%a+)")
    if base == nil then return nil end
    base = string.lower(base)
    if base == "pt" then return "pt-BR" end
    if STRINGS[base] ~= nil then return base end
    return nil                      -- English, which needs no table
end

-- UE4SS hands an FString back as a Lua string on this build, but a build
-- that wraps it would return a table with :get() or a userdata. Read all
-- three rather than assuming, the same way sources.lua reads a TArray.
local function asText(v)
    if type(v) == "string" then return v end
    if type(v) == "userdata" or type(v) == "table" then
        local got = guard.get(function() return v:get() end)
        if type(got) == "string" then return got end
        local s = guard.get(function() return v:ToString() end)
        if type(s) == "string" then return s end
        s = tostring(v)
        if type(s) == "string" and s ~= "" and not string.find(s, ":") then
            return s
        end
    end
    return nil
end

local function findLib()
    for i = 1, #LIB_PATHS do
        -- NOT guard.alive(): this is a CDO and a CDO need not answer
        -- IsValid(). Requiring it is how the 2.1.2 PalUtility route
        -- silently never engaged.
        local lib = guard.get(StaticFindObject, LIB_PATHS[i])
        if lib ~= nil then return lib, LIB_PATHS[i] end
    end
    if FindFirstOf ~= nil then
        local lib = guard.get(FindFirstOf, "KismetInternationalizationLibrary")
        if lib ~= nil then return lib, "FindFirstOf" end
    end
    return nil, nil
end

local function callGetter(lib, name)
    return guard.get(function() return lib[name](lib) end)
end

-- Ask the game once per menu open. Cheap (a name lookup and one static
-- call), and doing it per open rather than per session means changing the
-- language in the game's own options is picked up without a restart.
local function detect()
    local lib, path = findLib()
    if lib == nil then
        if not S.probed then
            S.probed = true
            guard.log("menu language: KismetInternationalizationLibrary is not "
                .. "reachable, so the menu stays in English")
        end
        return nil
    end
    for i = 1, #GETTERS do
        local culture = asText(callGetter(lib, GETTERS[i]))
        if culture ~= nil and culture ~= "" then
            if not S.probed then
                S.probed = true
                guard.log(string.format(
                    "menu language: %s via %s on %s -> %s",
                    culture, GETTERS[i], path,
                    pick(culture) or "English (no translation shipped)"))
            end
            return culture
        end
    end
    if not S.probed then
        S.probed = true
        guard.log("menu language: " .. tostring(path) .. " answered none of "
            .. "GetCurrentLanguage/GetCurrentCulture/GetCurrentLocale, so the "
            .. "menu stays in English")
    end
    return nil
end

-- `override` is config.menuLanguage: "" or "auto" to ask the game, or a
-- culture code to force one. There is no menu row for it on purpose - it
-- is an escape hatch for a build where detection is wrong, not a setting.
function M.refresh(override)
    if type(override) == "string" and override ~= "" and override ~= "auto" then
        S.culture = override
    else
        S.culture = detect()
    end
    S.lang = pick(S.culture)
    S.table = S.lang and STRINGS[S.lang] or nil
    return S.lang
end

function M.language() return S.lang or "en" end

function M.t(s)
    if S.table == nil or type(s) ~= "string" then return s end
    local hit = S.table[s]
    if hit == nil then return s end
    return hit
end

-- string.upper is byte-wise, so it leaves every accented UTF-8 character
-- alone: "Diagnóstico" would come out "DIAGNóSTICO" in the section
-- headers. In UTF-8 the Latin-1 letters are two bytes, 0xC3 followed by
-- 0xA0..0xBE for the lowercase ones, and the uppercase of each is exactly
-- 0x20 lower - so one gsub covers every accent Portuguese uses. 0xB7 is
-- the division sign and has no case, hence the split range.
function M.upper(s)
    if type(s) ~= "string" then return s end
    s = string.gsub(s, "\195([\160-\182\184-\190])", function(c)
        return "\195" .. string.char(string.byte(c) - 32)
    end)
    return string.upper(s)
end

-- test hook
function M.languages()
    local out = { "en" }
    for k in pairs(STRINGS) do out[#out + 1] = k end
    return out
end

return M
