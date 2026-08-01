-- =====================================================================
-- i18n.lua - the F5 menu in the language the game is running in
--
-- EVERY LANGUAGE PALWORLD SHIPS, with English as the base. The list is
-- not a guess: it is the set of cultures in the shipping pak under
-- `Pal/Content/Localization/*/`, which is
--
--     de  en  es  es-MX  fr  id  it  ja  ko  pl  pt-BR  ru  th  tr  vi
--     zh-Hans  zh-Hant
--
-- English needs no table (it is what the LAYOUT is written in), and
-- `es-MX` shares `es` - for fifty-five short UI strings the two do not
-- diverge. Anything else the engine reports falls back to English.
--
-- ---------------------------------------------------------------------
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
-- row. `scratchpad/i18ntest.py` reads the LAYOUT straight out of menu.lua
-- and fails if any language is missing a line, which is what stops this
-- file drifting behind the menu.
--
-- PROPER NOUNS ARE BEST EFFORT. Palworld's own term for a Lucky Pal or a
-- Lifmunk Effigy in Thai or Korean is inside its .locres files, not
-- anywhere this mod can cheaply read, so those few words are translated
-- rather than quoted. They are all in one table each and safe to correct.
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
-- Translations, keyed by the English string exactly as menu.lua writes
-- it. A typo in a key is a missing translation, never a missing row.
-- ---------------------------------------------------------------
local STRINGS = {}

-- Cultures that should use another table. Written out rather than derived
-- so that zh-Hans and zh-Hant can never collapse into each other: they
-- share a base language and are different scripts.
local ALIAS = {
    ["es-MX"] = "es", ["es-419"] = "es",
    ["pt"] = "pt-BR", ["pt-PT"] = "pt-BR",
    ["zh"] = "zh-Hans", ["zh-CN"] = "zh-Hans", ["zh-SG"] = "zh-Hans",
    ["zh-TW"] = "zh-Hant", ["zh-HK"] = "zh-Hant", ["zh-MO"] = "zh-Hant",
}

STRINGS["pt-BR"] = {
    ["Minimap"] = "Minimapa",
    ["Pals"] = "Pals",
    ["People"] = "Pessoas",
    ["Items"] = "Itens",
    ["Points of interest"] = "Pontos de interesse",
    ["Performance"] = "Desempenho",
    ["Troubleshooting"] = "Diagnóstico",
    ["Show minimap"] = "Mostrar minimapa",
    ["Size"] = "Tamanho",
    ["Opacity"] = "Opacidade",
    ["Circular shape"] = "Formato circular",
    ["Live render"] = "Renderização ao vivo",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Ao vivo: 0 iluminado, 1 plano (pode reverter)",
    ["Terrain quality (0 low - 3 sharp)"] = "Qualidade do terreno (0 baixa - 3 nítida)",
    ["Zoom (world units)"] = "Zoom (unidades do mundo)",
    ["Megazoom (F1) range"] = "Alcance do megazoom (F1)",
    ["Auto zoom out while moving"] = "Afastar zoom automaticamente ao se mover",
    ["Rotate with camera"] = "Girar com a câmera",
    ["Keep icons upright"] = "Manter ícones na vertical",
    ["Hide behind the game's menu"] = "Ocultar atrás do menu do jogo",
    ["Hide while in a base camp"] = "Ocultar dentro de um acampamento",
    ["Icon size"] = "Tamanho dos ícones",
    ["Player marker size"] = "Tamanho do marcador do jogador",
    ["Show camera view cone"] = "Mostrar cone de visão da câmera",
    ["View cone opacity"] = "Opacidade do cone de visão",
    ["View cone radius"] = "Raio do cone de visão",
    ["Show pals"] = "Mostrar Pals",
    ["Only shiny pals"] = "Apenas Pals sortudos",
    ["Show pals while megazoomed"] = "Mostrar Pals durante o megazoom",
    ["Max pal icons"] = "Máximo de ícones de Pals",
    ["Show other players"] = "Mostrar outros jogadores",
    ["Show NPC humans"] = "Mostrar NPCs humanos",
    ["Max NPC icons"] = "Máximo de ícones de NPCs",
    ["Max other-player icons"] = "Máximo de ícones de outros jogadores",
    ["Show death locations"] = "Mostrar locais de morte",
    ["Hide collected items"] = "Ocultar itens já coletados",
    ["Show chests"] = "Mostrar baús",
    ["Show eggs"] = "Mostrar ovos",
    ["Show notes"] = "Mostrar anotações",
    ["Show lifmunk effigies"] = "Mostrar efígies de Lifmunk",
    ["Show skillfruit trees"] = "Mostrar árvores de frutas de habilidade",
    ["Show fast travel points"] = "Mostrar pontos de viagem rápida",
    ["Show dungeons"] = "Mostrar masmorras",
    ["Show towers"] = "Mostrar torres",
    ["Show player base camps"] = "Mostrar acampamentos de jogadores",
    ["Show enemy camps"] = "Mostrar acampamentos inimigos",
    ["Show ore / lotus / junk"] = "Mostrar minérios / lótus / sucata",
    ["Show fishing spots"] = "Mostrar pontos de pesca",
    ["Show buried treasure"] = "Mostrar tesouros enterrados",
    ["Re-render terrain every (ms)"] = "Renderizar terreno a cada (ms)",
    ["Camera height above player"] = "Altura da câmera acima do jogador",
    ["Auto: live render up to zoom"] = "Ao vivo até o zoom de",
    ["Update rate (ms, lower = smoother)"] = "Taxa de atualização (ms, menor = mais fluido)",
    ["Rescan world every (ms)"] = "Reescanear o mundo a cada (ms)",
    ["Max point-of-interest icons"] = "Máximo de ícones de pontos de interesse",
    ["Log game UI widget names"] = "Registrar nomes dos widgets do jogo",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] fechar  [F1] megazoom  [F2] canto  [F3] mostrar/ocultar  [F4] editar  [+/-] zoom",
    ["Changes save and apply instantly."] = "As alterações são salvas e aplicadas na hora.",
}

STRINGS["es"] = {
    ["Minimap"] = "Minimapa",
    ["Pals"] = "Pals",
    ["People"] = "Personas",
    ["Items"] = "Objetos",
    ["Points of interest"] = "Puntos de interés",
    ["Performance"] = "Rendimiento",
    ["Troubleshooting"] = "Diagnóstico",
    ["Show minimap"] = "Mostrar minimapa",
    ["Size"] = "Tamaño",
    ["Opacity"] = "Opacidad",
    ["Circular shape"] = "Forma circular",
    ["Live render"] = "Renderizado en vivo",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "En vivo: 0 iluminado, 1 plano (puede revertir)",
    ["Terrain quality (0 low - 3 sharp)"] = "Calidad del terreno (0 baja - 3 nítida)",
    ["Zoom (world units)"] = "Zoom (unidades del mundo)",
    ["Megazoom (F1) range"] = "Alcance del megazoom (F1)",
    ["Auto zoom out while moving"] = "Alejar zoom automáticamente al moverse",
    ["Rotate with camera"] = "Girar con la cámara",
    ["Keep icons upright"] = "Mantener los iconos verticales",
    ["Hide behind the game's menu"] = "Ocultar tras el menú del juego",
    ["Hide while in a base camp"] = "Ocultar dentro de un campamento",
    ["Icon size"] = "Tamaño de los iconos",
    ["Player marker size"] = "Tamaño del marcador del jugador",
    ["Show camera view cone"] = "Mostrar cono de visión de la cámara",
    ["View cone opacity"] = "Opacidad del cono de visión",
    ["View cone radius"] = "Radio del cono de visión",
    ["Show pals"] = "Mostrar Pals",
    ["Only shiny pals"] = "Solo Pals afortunados",
    ["Show pals while megazoomed"] = "Mostrar Pals durante el megazoom",
    ["Max pal icons"] = "Máx. iconos de Pals",
    ["Show other players"] = "Mostrar otros jugadores",
    ["Show NPC humans"] = "Mostrar humanos NPC",
    ["Max NPC icons"] = "Máx. iconos de NPC",
    ["Max other-player icons"] = "Máx. iconos de otros jugadores",
    ["Show death locations"] = "Mostrar lugares de muerte",
    ["Hide collected items"] = "Ocultar objetos ya recogidos",
    ["Show chests"] = "Mostrar cofres",
    ["Show eggs"] = "Mostrar huevos",
    ["Show notes"] = "Mostrar notas",
    ["Show lifmunk effigies"] = "Mostrar efigies de Lifmunk",
    ["Show skillfruit trees"] = "Mostrar árboles de frutas de habilidad",
    ["Show fast travel points"] = "Mostrar puntos de viaje rápido",
    ["Show dungeons"] = "Mostrar mazmorras",
    ["Show towers"] = "Mostrar torres",
    ["Show player base camps"] = "Mostrar campamentos de jugadores",
    ["Show enemy camps"] = "Mostrar campamentos enemigos",
    ["Show ore / lotus / junk"] = "Mostrar mineral / loto / chatarra",
    ["Show fishing spots"] = "Mostrar zonas de pesca",
    ["Show buried treasure"] = "Mostrar tesoros enterrados",
    ["Re-render terrain every (ms)"] = "Renderizar terreno cada (ms)",
    ["Camera height above player"] = "Altura de la cámara sobre el jugador",
    ["Auto: live render up to zoom"] = "En vivo hasta el zoom de",
    ["Update rate (ms, lower = smoother)"] = "Frecuencia de actualización (ms, menor = más fluido)",
    ["Rescan world every (ms)"] = "Reescanear el mundo cada (ms)",
    ["Max point-of-interest icons"] = "Máx. iconos de puntos de interés",
    ["Log game UI widget names"] = "Registrar nombres de widgets del juego",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] cerrar  [F1] megazoom  [F2] esquina  [F3] mostrar/ocultar  [F4] editar  [+/-] zoom",
    ["Changes save and apply instantly."] = "Los cambios se guardan y aplican al instante.",
}

STRINGS["fr"] = {
    ["Minimap"] = "Minicarte",
    ["Pals"] = "Pals",
    ["People"] = "Personnes",
    ["Items"] = "Objets",
    ["Points of interest"] = "Points d'intérêt",
    ["Performance"] = "Performances",
    ["Troubleshooting"] = "Diagnostic",
    ["Show minimap"] = "Afficher la minicarte",
    ["Size"] = "Taille",
    ["Opacity"] = "Opacité",
    ["Circular shape"] = "Forme circulaire",
    ["Live render"] = "Rendu en direct",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Direct : 0 éclairé, 1 plat (peut basculer)",
    ["Terrain quality (0 low - 3 sharp)"] = "Qualité du terrain (0 basse - 3 nette)",
    ["Zoom (world units)"] = "Zoom (unités du monde)",
    ["Megazoom (F1) range"] = "Portée du mégazoom (F1)",
    ["Auto zoom out while moving"] = "Dézoomer automatiquement en mouvement",
    ["Rotate with camera"] = "Pivoter avec la caméra",
    ["Keep icons upright"] = "Garder les icônes droites",
    ["Hide behind the game's menu"] = "Masquer derrière le menu du jeu",
    ["Hide while in a base camp"] = "Masquer dans un camp de base",
    ["Icon size"] = "Taille des icônes",
    ["Player marker size"] = "Taille du marqueur du joueur",
    ["Show camera view cone"] = "Afficher le cône de vision de la caméra",
    ["View cone opacity"] = "Opacité du cône de vision",
    ["View cone radius"] = "Rayon du cône de vision",
    ["Show pals"] = "Afficher les Pals",
    ["Only shiny pals"] = "Uniquement les Pals chanceux",
    ["Show pals while megazoomed"] = "Afficher les Pals en mégazoom",
    ["Max pal icons"] = "Icônes de Pals max.",
    ["Show other players"] = "Afficher les autres joueurs",
    ["Show NPC humans"] = "Afficher les humains PNJ",
    ["Max NPC icons"] = "Icônes de PNJ max.",
    ["Max other-player icons"] = "Icônes d'autres joueurs max.",
    ["Show death locations"] = "Afficher les lieux de mort",
    ["Hide collected items"] = "Masquer les objets déjà ramassés",
    ["Show chests"] = "Afficher les coffres",
    ["Show eggs"] = "Afficher les œufs",
    ["Show notes"] = "Afficher les notes",
    ["Show lifmunk effigies"] = "Afficher les effigies de Lifmunk",
    ["Show skillfruit trees"] = "Afficher les arbres à fruits de compétence",
    ["Show fast travel points"] = "Afficher les points de voyage rapide",
    ["Show dungeons"] = "Afficher les donjons",
    ["Show towers"] = "Afficher les tours",
    ["Show player base camps"] = "Afficher les camps de joueurs",
    ["Show enemy camps"] = "Afficher les camps ennemis",
    ["Show ore / lotus / junk"] = "Afficher minerai / lotus / ferraille",
    ["Show fishing spots"] = "Afficher les coins de pêche",
    ["Show buried treasure"] = "Afficher les trésors enfouis",
    ["Re-render terrain every (ms)"] = "Recalculer le terrain toutes les (ms)",
    ["Camera height above player"] = "Hauteur de la caméra au-dessus du joueur",
    ["Auto: live render up to zoom"] = "Rendu en direct jusqu'au zoom",
    ["Update rate (ms, lower = smoother)"] = "Fréquence de mise à jour (ms, plus bas = plus fluide)",
    ["Rescan world every (ms)"] = "Rescanner le monde toutes les (ms)",
    ["Max point-of-interest icons"] = "Icônes de points d'intérêt max.",
    ["Log game UI widget names"] = "Journaliser les noms des widgets du jeu",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] fermer  [F1] mégazoom  [F2] coin  [F3] afficher/masquer  [F4] éditer  [+/-] zoom",
    ["Changes save and apply instantly."] = "Les modifications sont enregistrées et appliquées aussitôt.",
}

STRINGS["de"] = {
    ["Minimap"] = "Minikarte",
    ["Pals"] = "Pals",
    ["People"] = "Personen",
    ["Items"] = "Gegenstände",
    ["Points of interest"] = "Orte von Interesse",
    ["Performance"] = "Leistung",
    ["Troubleshooting"] = "Fehlerbehebung",
    ["Show minimap"] = "Minikarte anzeigen",
    ["Size"] = "Größe",
    ["Opacity"] = "Deckkraft",
    ["Circular shape"] = "Runde Form",
    ["Live render"] = "Live-Rendering",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Live: 0 beleuchtet, 1 flach (ggf. Rückfall)",
    ["Terrain quality (0 low - 3 sharp)"] = "Geländequalität (0 niedrig - 3 scharf)",
    ["Zoom (world units)"] = "Zoom (Welteinheiten)",
    ["Megazoom (F1) range"] = "Megazoom-Reichweite (F1)",
    ["Auto zoom out while moving"] = "Beim Bewegen automatisch herauszoomen",
    ["Rotate with camera"] = "Mit der Kamera drehen",
    ["Keep icons upright"] = "Symbole aufrecht halten",
    ["Hide behind the game's menu"] = "Hinter dem Spielmenü verbergen",
    ["Hide while in a base camp"] = "Im Basislager verbergen",
    ["Icon size"] = "Symbolgröße",
    ["Player marker size"] = "Größe der Spielermarkierung",
    ["Show camera view cone"] = "Sichtkegel der Kamera anzeigen",
    ["View cone opacity"] = "Deckkraft des Sichtkegels",
    ["View cone radius"] = "Radius des Sichtkegels",
    ["Show pals"] = "Pals anzeigen",
    ["Only shiny pals"] = "Nur Glücks-Pals",
    ["Show pals while megazoomed"] = "Pals beim Megazoom anzeigen",
    ["Max pal icons"] = "Max. Pal-Symbole",
    ["Show other players"] = "Andere Spieler anzeigen",
    ["Show NPC humans"] = "NSC-Menschen anzeigen",
    ["Max NPC icons"] = "Max. NSC-Symbole",
    ["Max other-player icons"] = "Max. Symbole anderer Spieler",
    ["Show death locations"] = "Todesorte anzeigen",
    ["Hide collected items"] = "Eingesammelte Gegenstände ausblenden",
    ["Show chests"] = "Truhen anzeigen",
    ["Show eggs"] = "Eier anzeigen",
    ["Show notes"] = "Notizen anzeigen",
    ["Show lifmunk effigies"] = "Lifmunk-Statuen anzeigen",
    ["Show skillfruit trees"] = "Fähigkeitsfruchtbäume anzeigen",
    ["Show fast travel points"] = "Schnellreisepunkte anzeigen",
    ["Show dungeons"] = "Verliese anzeigen",
    ["Show towers"] = "Türme anzeigen",
    ["Show player base camps"] = "Basislager von Spielern anzeigen",
    ["Show enemy camps"] = "Feindliche Lager anzeigen",
    ["Show ore / lotus / junk"] = "Erz / Lotus / Schrott anzeigen",
    ["Show fishing spots"] = "Angelplätze anzeigen",
    ["Show buried treasure"] = "Vergrabene Schätze anzeigen",
    ["Re-render terrain every (ms)"] = "Gelände neu rendern alle (ms)",
    ["Camera height above player"] = "Kamerahöhe über dem Spieler",
    ["Auto: live render up to zoom"] = "Live-Rendering bis Zoom",
    ["Update rate (ms, lower = smoother)"] = "Aktualisierungsrate (ms, niedriger = flüssiger)",
    ["Rescan world every (ms)"] = "Welt neu scannen alle (ms)",
    ["Max point-of-interest icons"] = "Max. Symbole für Orte",
    ["Log game UI widget names"] = "Widget-Namen der Spiel-UI protokollieren",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] schließen  [F1] Megazoom  [F2] Ecke  [F3] ein/aus  [F4] bearbeiten  [+/-] Zoom",
    ["Changes save and apply instantly."] = "Änderungen werden sofort gespeichert und übernommen.",
}

STRINGS["it"] = {
    ["Minimap"] = "Minimappa",
    ["Pals"] = "Pal",
    ["People"] = "Persone",
    ["Items"] = "Oggetti",
    ["Points of interest"] = "Punti d'interesse",
    ["Performance"] = "Prestazioni",
    ["Troubleshooting"] = "Diagnostica",
    ["Show minimap"] = "Mostra minimappa",
    ["Size"] = "Dimensione",
    ["Opacity"] = "Opacità",
    ["Circular shape"] = "Forma circolare",
    ["Live render"] = "Render dal vivo",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Dal vivo: 0 illuminato, 1 piatto (può tornare indietro)",
    ["Terrain quality (0 low - 3 sharp)"] = "Qualità del terreno (0 bassa - 3 nitida)",
    ["Zoom (world units)"] = "Zoom (unità di mondo)",
    ["Megazoom (F1) range"] = "Portata del megazoom (F1)",
    ["Auto zoom out while moving"] = "Riduci lo zoom automaticamente in movimento",
    ["Rotate with camera"] = "Ruota con la telecamera",
    ["Keep icons upright"] = "Mantieni le icone dritte",
    ["Hide behind the game's menu"] = "Nascondi dietro il menu di gioco",
    ["Hide while in a base camp"] = "Nascondi in un campo base",
    ["Icon size"] = "Dimensione delle icone",
    ["Player marker size"] = "Dimensione dell'indicatore del giocatore",
    ["Show camera view cone"] = "Mostra il cono visivo della telecamera",
    ["View cone opacity"] = "Opacità del cono visivo",
    ["View cone radius"] = "Raggio del cono visivo",
    ["Show pals"] = "Mostra i Pal",
    ["Only shiny pals"] = "Solo Pal fortunati",
    ["Show pals while megazoomed"] = "Mostra i Pal durante il megazoom",
    ["Max pal icons"] = "Max icone dei Pal",
    ["Show other players"] = "Mostra gli altri giocatori",
    ["Show NPC humans"] = "Mostra gli umani PNG",
    ["Max NPC icons"] = "Max icone dei PNG",
    ["Max other-player icons"] = "Max icone di altri giocatori",
    ["Show death locations"] = "Mostra i luoghi di morte",
    ["Hide collected items"] = "Nascondi gli oggetti già raccolti",
    ["Show chests"] = "Mostra i forzieri",
    ["Show eggs"] = "Mostra le uova",
    ["Show notes"] = "Mostra gli appunti",
    ["Show lifmunk effigies"] = "Mostra le effigi di Lifmunk",
    ["Show skillfruit trees"] = "Mostra gli alberi dei frutti abilità",
    ["Show fast travel points"] = "Mostra i punti di viaggio rapido",
    ["Show dungeons"] = "Mostra i dungeon",
    ["Show towers"] = "Mostra le torri",
    ["Show player base camps"] = "Mostra i campi base dei giocatori",
    ["Show enemy camps"] = "Mostra i campi nemici",
    ["Show ore / lotus / junk"] = "Mostra minerali / loto / rottami",
    ["Show fishing spots"] = "Mostra i punti di pesca",
    ["Show buried treasure"] = "Mostra i tesori sepolti",
    ["Re-render terrain every (ms)"] = "Rigenera il terreno ogni (ms)",
    ["Camera height above player"] = "Altezza della telecamera sul giocatore",
    ["Auto: live render up to zoom"] = "Render dal vivo fino allo zoom",
    ["Update rate (ms, lower = smoother)"] = "Frequenza di aggiornamento (ms, più basso = più fluido)",
    ["Rescan world every (ms)"] = "Riscansiona il mondo ogni (ms)",
    ["Max point-of-interest icons"] = "Max icone dei punti d'interesse",
    ["Log game UI widget names"] = "Registra i nomi dei widget dell'interfaccia",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] chiudi  [F1] megazoom  [F2] angolo  [F3] mostra/nascondi  [F4] modifica  [+/-] zoom",
    ["Changes save and apply instantly."] = "Le modifiche vengono salvate e applicate all'istante.",
}

STRINGS["pl"] = {
    ["Minimap"] = "Minimapa",
    ["Pals"] = "Pale",
    ["People"] = "Ludzie",
    ["Items"] = "Przedmioty",
    ["Points of interest"] = "Punkty zainteresowania",
    ["Performance"] = "Wydajność",
    ["Troubleshooting"] = "Diagnostyka",
    ["Show minimap"] = "Pokaż minimapę",
    ["Size"] = "Rozmiar",
    ["Opacity"] = "Krycie",
    ["Circular shape"] = "Okrągły kształt",
    ["Live render"] = "Render na żywo",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Na żywo: 0 oświetlony, 1 płaski (może wrócić)",
    ["Terrain quality (0 low - 3 sharp)"] = "Jakość terenu (0 niska - 3 ostra)",
    ["Zoom (world units)"] = "Przybliżenie (jednostki świata)",
    ["Megazoom (F1) range"] = "Zasięg megazoomu (F1)",
    ["Auto zoom out while moving"] = "Automatyczne oddalanie w ruchu",
    ["Rotate with camera"] = "Obracaj z kamerą",
    ["Keep icons upright"] = "Utrzymuj ikony pionowo",
    ["Hide behind the game's menu"] = "Ukryj za menu gry",
    ["Hide while in a base camp"] = "Ukryj w obozie bazowym",
    ["Icon size"] = "Rozmiar ikon",
    ["Player marker size"] = "Rozmiar znacznika gracza",
    ["Show camera view cone"] = "Pokaż stożek widzenia kamery",
    ["View cone opacity"] = "Krycie stożka widzenia",
    ["View cone radius"] = "Promień stożka widzenia",
    ["Show pals"] = "Pokaż Pale",
    ["Only shiny pals"] = "Tylko szczęśliwe Pale",
    ["Show pals while megazoomed"] = "Pokaż Pale przy megazoomie",
    ["Max pal icons"] = "Maks. ikon Pali",
    ["Show other players"] = "Pokaż innych graczy",
    ["Show NPC humans"] = "Pokaż ludzi NPC",
    ["Max NPC icons"] = "Maks. ikon NPC",
    ["Max other-player icons"] = "Maks. ikon innych graczy",
    ["Show death locations"] = "Pokaż miejsca śmierci",
    ["Hide collected items"] = "Ukryj zebrane przedmioty",
    ["Show chests"] = "Pokaż skrzynie",
    ["Show eggs"] = "Pokaż jaja",
    ["Show notes"] = "Pokaż notatki",
    ["Show lifmunk effigies"] = "Pokaż figurki Lifmunka",
    ["Show skillfruit trees"] = "Pokaż drzewa owoców umiejętności",
    ["Show fast travel points"] = "Pokaż punkty szybkiej podróży",
    ["Show dungeons"] = "Pokaż lochy",
    ["Show towers"] = "Pokaż wieże",
    ["Show player base camps"] = "Pokaż obozy graczy",
    ["Show enemy camps"] = "Pokaż obozy wrogów",
    ["Show ore / lotus / junk"] = "Pokaż rudę / lotos / złom",
    ["Show fishing spots"] = "Pokaż łowiska",
    ["Show buried treasure"] = "Pokaż zakopane skarby",
    ["Re-render terrain every (ms)"] = "Renderuj teren co (ms)",
    ["Camera height above player"] = "Wysokość kamery nad graczem",
    ["Auto: live render up to zoom"] = "Render na żywo do przybliżenia",
    ["Update rate (ms, lower = smoother)"] = "Częstotliwość odświeżania (ms, mniej = płynniej)",
    ["Rescan world every (ms)"] = "Skanuj świat co (ms)",
    ["Max point-of-interest icons"] = "Maks. ikon punktów zainteresowania",
    ["Log game UI widget names"] = "Zapisuj nazwy widgetów interfejsu gry",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] zamknij  [F1] megazoom  [F2] róg  [F3] pokaż/ukryj  [F4] edycja  [+/-] zoom",
    ["Changes save and apply instantly."] = "Zmiany są zapisywane i stosowane natychmiast.",
}

STRINGS["ru"] = {
    ["Minimap"] = "Миникарта",
    ["Pals"] = "Палы",
    ["People"] = "Люди",
    ["Items"] = "Предметы",
    ["Points of interest"] = "Точки интереса",
    ["Performance"] = "Производительность",
    ["Troubleshooting"] = "Диагностика",
    ["Show minimap"] = "Показывать миникарту",
    ["Size"] = "Размер",
    ["Opacity"] = "Непрозрачность",
    ["Circular shape"] = "Круглая форма",
    ["Live render"] = "Рендер в реальном времени",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Рендер: 0 со светом, 1 плоский (может откатиться)",
    ["Terrain quality (0 low - 3 sharp)"] = "Качество ландшафта (0 низкое - 3 чёткое)",
    ["Zoom (world units)"] = "Масштаб (единицы мира)",
    ["Megazoom (F1) range"] = "Дальность мегамасштаба (F1)",
    ["Auto zoom out while moving"] = "Автоотдаление при движении",
    ["Rotate with camera"] = "Вращать вместе с камерой",
    ["Keep icons upright"] = "Держать значки вертикально",
    ["Hide behind the game's menu"] = "Скрывать за меню игры",
    ["Hide while in a base camp"] = "Скрывать в базовом лагере",
    ["Icon size"] = "Размер значков",
    ["Player marker size"] = "Размер маркера игрока",
    ["Show camera view cone"] = "Показывать конус обзора камеры",
    ["View cone opacity"] = "Непрозрачность конуса обзора",
    ["View cone radius"] = "Радиус конуса обзора",
    ["Show pals"] = "Показывать палов",
    ["Only shiny pals"] = "Только удачливые палы",
    ["Show pals while megazoomed"] = "Показывать палов при мегамасштабе",
    ["Max pal icons"] = "Макс. значков палов",
    ["Show other players"] = "Показывать других игроков",
    ["Show NPC humans"] = "Показывать людей-NPC",
    ["Max NPC icons"] = "Макс. значков NPC",
    ["Max other-player icons"] = "Макс. значков других игроков",
    ["Show death locations"] = "Показывать места гибели",
    ["Hide collected items"] = "Скрывать собранные предметы",
    ["Show chests"] = "Показывать сундуки",
    ["Show eggs"] = "Показывать яйца",
    ["Show notes"] = "Показывать записки",
    ["Show lifmunk effigies"] = "Показывать статуэтки Лифмунка",
    ["Show skillfruit trees"] = "Показывать деревья фруктов навыков",
    ["Show fast travel points"] = "Показывать точки быстрого перемещения",
    ["Show dungeons"] = "Показывать подземелья",
    ["Show towers"] = "Показывать башни",
    ["Show player base camps"] = "Показывать лагеря игроков",
    ["Show enemy camps"] = "Показывать вражеские лагеря",
    ["Show ore / lotus / junk"] = "Показывать руду / лотос / хлам",
    ["Show fishing spots"] = "Показывать места рыбалки",
    ["Show buried treasure"] = "Показывать зарытые сокровища",
    ["Re-render terrain every (ms)"] = "Перерисовывать ландшафт каждые (мс)",
    ["Camera height above player"] = "Высота камеры над игроком",
    ["Auto: live render up to zoom"] = "Рендер в реальном времени до масштаба",
    ["Update rate (ms, lower = smoother)"] = "Частота обновления (мс, меньше = плавнее)",
    ["Rescan world every (ms)"] = "Пересканировать мир каждые (мс)",
    ["Max point-of-interest icons"] = "Макс. значков точек интереса",
    ["Log game UI widget names"] = "Записывать имена виджетов интерфейса",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] закрыть  [F1] мегамасштаб  [F2] угол  [F3] показать/скрыть  [F4] правка  [+/-] масштаб",
    ["Changes save and apply instantly."] = "Изменения сохраняются и применяются сразу.",
}

STRINGS["tr"] = {
    ["Minimap"] = "Mini harita",
    ["Pals"] = "Pal'ler",
    ["People"] = "İnsanlar",
    ["Items"] = "Eşyalar",
    ["Points of interest"] = "İlgi noktaları",
    ["Performance"] = "Performans",
    ["Troubleshooting"] = "Sorun giderme",
    ["Show minimap"] = "Mini haritayı göster",
    ["Size"] = "Boyut",
    ["Opacity"] = "Saydamlık",
    ["Circular shape"] = "Dairesel şekil",
    ["Live render"] = "Canlı render",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Canlı: 0 ışıklı, 1 düz (geri dönebilir)",
    ["Terrain quality (0 low - 3 sharp)"] = "Arazi kalitesi (0 düşük - 3 keskin)",
    ["Zoom (world units)"] = "Yakınlaştırma (dünya birimi)",
    ["Megazoom (F1) range"] = "Megazoom menzili (F1)",
    ["Auto zoom out while moving"] = "Hareket ederken otomatik uzaklaş",
    ["Rotate with camera"] = "Kamerayla döndür",
    ["Keep icons upright"] = "Simgeleri dik tut",
    ["Hide behind the game's menu"] = "Oyun menüsünün arkasına gizle",
    ["Hide while in a base camp"] = "Ana kampta gizle",
    ["Icon size"] = "Simge boyutu",
    ["Player marker size"] = "Oyuncu işareti boyutu",
    ["Show camera view cone"] = "Kamera görüş konisini göster",
    ["View cone opacity"] = "Görüş konisi saydamlığı",
    ["View cone radius"] = "Görüş konisi yarıçapı",
    ["Show pals"] = "Pal'leri göster",
    ["Only shiny pals"] = "Sadece şanslı Pal'ler",
    ["Show pals while megazoomed"] = "Megazoom sırasında Pal'leri göster",
    ["Max pal icons"] = "Maks. Pal simgesi",
    ["Show other players"] = "Diğer oyuncuları göster",
    ["Show NPC humans"] = "NPC insanları göster",
    ["Max NPC icons"] = "Maks. NPC simgesi",
    ["Max other-player icons"] = "Maks. diğer oyuncu simgesi",
    ["Show death locations"] = "Ölüm yerlerini göster",
    ["Hide collected items"] = "Toplanmış eşyaları gizle",
    ["Show chests"] = "Sandıkları göster",
    ["Show eggs"] = "Yumurtaları göster",
    ["Show notes"] = "Notları göster",
    ["Show lifmunk effigies"] = "Lifmunk heykelciklerini göster",
    ["Show skillfruit trees"] = "Yetenek meyvesi ağaçlarını göster",
    ["Show fast travel points"] = "Hızlı seyahat noktalarını göster",
    ["Show dungeons"] = "Zindanları göster",
    ["Show towers"] = "Kuleleri göster",
    ["Show player base camps"] = "Oyuncu kamplarını göster",
    ["Show enemy camps"] = "Düşman kamplarını göster",
    ["Show ore / lotus / junk"] = "Cevher / nilüfer / hurda göster",
    ["Show fishing spots"] = "Balık tutma noktalarını göster",
    ["Show buried treasure"] = "Gömülü hazineleri göster",
    ["Re-render terrain every (ms)"] = "Araziyi her (ms) yeniden render et",
    ["Camera height above player"] = "Oyuncunun üstündeki kamera yüksekliği",
    ["Auto: live render up to zoom"] = "Şu yakınlaştırmaya kadar canlı render",
    ["Update rate (ms, lower = smoother)"] = "Güncelleme hızı (ms, düşük = daha akıcı)",
    ["Rescan world every (ms)"] = "Dünyayı her (ms) yeniden tara",
    ["Max point-of-interest icons"] = "Maks. ilgi noktası simgesi",
    ["Log game UI widget names"] = "Oyun arayüzü widget adlarını kaydet",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] kapat  [F1] megazoom  [F2] köşe  [F3] göster/gizle  [F4] düzenle  [+/-] yakınlaştır",
    ["Changes save and apply instantly."] = "Değişiklikler anında kaydedilir ve uygulanır.",
}

STRINGS["id"] = {
    ["Minimap"] = "Minimap",
    ["Pals"] = "Pal",
    ["People"] = "Orang",
    ["Items"] = "Barang",
    ["Points of interest"] = "Titik menarik",
    ["Performance"] = "Performa",
    ["Troubleshooting"] = "Pemecahan masalah",
    ["Show minimap"] = "Tampilkan minimap",
    ["Size"] = "Ukuran",
    ["Opacity"] = "Opasitas",
    ["Circular shape"] = "Bentuk lingkaran",
    ["Live render"] = "Render langsung",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Langsung: 0 bercahaya, 1 datar (bisa kembali)",
    ["Terrain quality (0 low - 3 sharp)"] = "Kualitas medan (0 rendah - 3 tajam)",
    ["Zoom (world units)"] = "Zoom (satuan dunia)",
    ["Megazoom (F1) range"] = "Jangkauan megazoom (F1)",
    ["Auto zoom out while moving"] = "Perkecil otomatis saat bergerak",
    ["Rotate with camera"] = "Putar mengikuti kamera",
    ["Keep icons upright"] = "Jaga ikon tetap tegak",
    ["Hide behind the game's menu"] = "Sembunyikan di balik menu game",
    ["Hide while in a base camp"] = "Sembunyikan saat di base camp",
    ["Icon size"] = "Ukuran ikon",
    ["Player marker size"] = "Ukuran penanda pemain",
    ["Show camera view cone"] = "Tampilkan kerucut pandang kamera",
    ["View cone opacity"] = "Opasitas kerucut pandang",
    ["View cone radius"] = "Radius kerucut pandang",
    ["Show pals"] = "Tampilkan Pal",
    ["Only shiny pals"] = "Hanya Pal beruntung",
    ["Show pals while megazoomed"] = "Tampilkan Pal saat megazoom",
    ["Max pal icons"] = "Maks. ikon Pal",
    ["Show other players"] = "Tampilkan pemain lain",
    ["Show NPC humans"] = "Tampilkan manusia NPC",
    ["Max NPC icons"] = "Maks. ikon NPC",
    ["Max other-player icons"] = "Maks. ikon pemain lain",
    ["Show death locations"] = "Tampilkan lokasi kematian",
    ["Hide collected items"] = "Sembunyikan barang yang sudah diambil",
    ["Show chests"] = "Tampilkan peti",
    ["Show eggs"] = "Tampilkan telur",
    ["Show notes"] = "Tampilkan catatan",
    ["Show lifmunk effigies"] = "Tampilkan patung Lifmunk",
    ["Show skillfruit trees"] = "Tampilkan pohon buah keahlian",
    ["Show fast travel points"] = "Tampilkan titik perjalanan cepat",
    ["Show dungeons"] = "Tampilkan dungeon",
    ["Show towers"] = "Tampilkan menara",
    ["Show player base camps"] = "Tampilkan base camp pemain",
    ["Show enemy camps"] = "Tampilkan kamp musuh",
    ["Show ore / lotus / junk"] = "Tampilkan bijih / teratai / rongsokan",
    ["Show fishing spots"] = "Tampilkan tempat memancing",
    ["Show buried treasure"] = "Tampilkan harta terpendam",
    ["Re-render terrain every (ms)"] = "Render ulang medan setiap (ms)",
    ["Camera height above player"] = "Tinggi kamera di atas pemain",
    ["Auto: live render up to zoom"] = "Render langsung hingga zoom",
    ["Update rate (ms, lower = smoother)"] = "Laju pembaruan (ms, lebih kecil = lebih mulus)",
    ["Rescan world every (ms)"] = "Pindai ulang dunia setiap (ms)",
    ["Max point-of-interest icons"] = "Maks. ikon titik menarik",
    ["Log game UI widget names"] = "Catat nama widget UI game",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] tutup  [F1] megazoom  [F2] sudut  [F3] tampil/sembunyi  [F4] edit  [+/-] zoom",
    ["Changes save and apply instantly."] = "Perubahan langsung disimpan dan diterapkan.",
}

STRINGS["vi"] = {
    ["Minimap"] = "Bản đồ nhỏ",
    ["Pals"] = "Pal",
    ["People"] = "Con người",
    ["Items"] = "Vật phẩm",
    ["Points of interest"] = "Điểm đáng chú ý",
    ["Performance"] = "Hiệu năng",
    ["Troubleshooting"] = "Chẩn đoán",
    ["Show minimap"] = "Hiện bản đồ nhỏ",
    ["Size"] = "Kích thước",
    ["Opacity"] = "Độ mờ",
    ["Circular shape"] = "Dạng hình tròn",
    ["Live render"] = "Kết xuất trực tiếp",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "Trực tiếp: 0 có sáng, 1 phẳng (có thể quay lại)",
    ["Terrain quality (0 low - 3 sharp)"] = "Chất lượng địa hình (0 thấp - 3 sắc nét)",
    ["Zoom (world units)"] = "Thu phóng (đơn vị thế giới)",
    ["Megazoom (F1) range"] = "Phạm vi megazoom (F1)",
    ["Auto zoom out while moving"] = "Tự thu nhỏ khi di chuyển",
    ["Rotate with camera"] = "Xoay theo camera",
    ["Keep icons upright"] = "Giữ biểu tượng thẳng đứng",
    ["Hide behind the game's menu"] = "Ẩn sau menu của game",
    ["Hide while in a base camp"] = "Ẩn khi ở trong căn cứ",
    ["Icon size"] = "Kích thước biểu tượng",
    ["Player marker size"] = "Kích thước dấu người chơi",
    ["Show camera view cone"] = "Hiện nón tầm nhìn của camera",
    ["View cone opacity"] = "Độ mờ của nón tầm nhìn",
    ["View cone radius"] = "Bán kính nón tầm nhìn",
    ["Show pals"] = "Hiện Pal",
    ["Only shiny pals"] = "Chỉ Pal may mắn",
    ["Show pals while megazoomed"] = "Hiện Pal khi megazoom",
    ["Max pal icons"] = "Tối đa biểu tượng Pal",
    ["Show other players"] = "Hiện người chơi khác",
    ["Show NPC humans"] = "Hiện NPC là người",
    ["Max NPC icons"] = "Tối đa biểu tượng NPC",
    ["Max other-player icons"] = "Tối đa biểu tượng người chơi khác",
    ["Show death locations"] = "Hiện nơi tử vong",
    ["Hide collected items"] = "Ẩn vật phẩm đã nhặt",
    ["Show chests"] = "Hiện rương",
    ["Show eggs"] = "Hiện trứng",
    ["Show notes"] = "Hiện ghi chú",
    ["Show lifmunk effigies"] = "Hiện tượng Lifmunk",
    ["Show skillfruit trees"] = "Hiện cây quả kỹ năng",
    ["Show fast travel points"] = "Hiện điểm dịch chuyển nhanh",
    ["Show dungeons"] = "Hiện hầm ngục",
    ["Show towers"] = "Hiện tháp",
    ["Show player base camps"] = "Hiện căn cứ của người chơi",
    ["Show enemy camps"] = "Hiện trại địch",
    ["Show ore / lotus / junk"] = "Hiện quặng / sen / phế liệu",
    ["Show fishing spots"] = "Hiện điểm câu cá",
    ["Show buried treasure"] = "Hiện kho báu chôn giấu",
    ["Re-render terrain every (ms)"] = "Kết xuất lại địa hình mỗi (ms)",
    ["Camera height above player"] = "Độ cao camera trên người chơi",
    ["Auto: live render up to zoom"] = "Kết xuất trực tiếp tới mức thu phóng",
    ["Update rate (ms, lower = smoother)"] = "Tốc độ cập nhật (ms, thấp = mượt hơn)",
    ["Rescan world every (ms)"] = "Quét lại thế giới mỗi (ms)",
    ["Max point-of-interest icons"] = "Tối đa biểu tượng điểm đáng chú ý",
    ["Log game UI widget names"] = "Ghi tên widget giao diện game",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] đóng  [F1] megazoom  [F2] góc  [F3] hiện/ẩn  [F4] chỉnh  [+/-] thu phóng",
    ["Changes save and apply instantly."] = "Thay đổi được lưu và áp dụng ngay.",
}

STRINGS["th"] = {
    ["Minimap"] = "มินิแมป",
    ["Pals"] = "Pal",
    ["People"] = "ผู้คน",
    ["Items"] = "ไอเทม",
    ["Points of interest"] = "จุดที่น่าสนใจ",
    ["Performance"] = "ประสิทธิภาพ",
    ["Troubleshooting"] = "การแก้ปัญหา",
    ["Show minimap"] = "แสดงมินิแมป",
    ["Size"] = "ขนาด",
    ["Opacity"] = "ความทึบ",
    ["Circular shape"] = "รูปทรงวงกลม",
    ["Live render"] = "เรนเดอร์สด",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "สด: 0 มีแสง, 1 แบน (อาจย้อนกลับ)",
    ["Terrain quality (0 low - 3 sharp)"] = "คุณภาพภูมิประเทศ (0 ต่ำ - 3 คมชัด)",
    ["Zoom (world units)"] = "ซูม (หน่วยโลก)",
    ["Megazoom (F1) range"] = "ระยะเมกะซูม (F1)",
    ["Auto zoom out while moving"] = "ซูมออกอัตโนมัติขณะเคลื่อนที่",
    ["Rotate with camera"] = "หมุนตามกล้อง",
    ["Keep icons upright"] = "ให้ไอคอนตั้งตรงเสมอ",
    ["Hide behind the game's menu"] = "ซ่อนเมื่อเปิดเมนูเกม",
    ["Hide while in a base camp"] = "ซ่อนขณะอยู่ในแคมป์",
    ["Icon size"] = "ขนาดไอคอน",
    ["Player marker size"] = "ขนาดเครื่องหมายผู้เล่น",
    ["Show camera view cone"] = "แสดงกรวยมุมมองกล้อง",
    ["View cone opacity"] = "ความทึบของกรวยมุมมอง",
    ["View cone radius"] = "รัศมีกรวยมุมมอง",
    ["Show pals"] = "แสดง Pal",
    ["Only shiny pals"] = "เฉพาะ Pal นำโชค",
    ["Show pals while megazoomed"] = "แสดง Pal ขณะเมกะซูม",
    ["Max pal icons"] = "ไอคอน Pal สูงสุด",
    ["Show other players"] = "แสดงผู้เล่นคนอื่น",
    ["Show NPC humans"] = "แสดง NPC ที่เป็นมนุษย์",
    ["Max NPC icons"] = "ไอคอน NPC สูงสุด",
    ["Max other-player icons"] = "ไอคอนผู้เล่นอื่นสูงสุด",
    ["Show death locations"] = "แสดงจุดที่เสียชีวิต",
    ["Hide collected items"] = "ซ่อนไอเทมที่เก็บแล้ว",
    ["Show chests"] = "แสดงหีบสมบัติ",
    ["Show eggs"] = "แสดงไข่",
    ["Show notes"] = "แสดงบันทึก",
    ["Show lifmunk effigies"] = "แสดงรูปปั้น Lifmunk",
    ["Show skillfruit trees"] = "แสดงต้นผลไม้สกิล",
    ["Show fast travel points"] = "แสดงจุดเดินทางเร็ว",
    ["Show dungeons"] = "แสดงดันเจี้ยน",
    ["Show towers"] = "แสดงหอคอย",
    ["Show player base camps"] = "แสดงแคมป์ของผู้เล่น",
    ["Show enemy camps"] = "แสดงแคมป์ศัตรู",
    ["Show ore / lotus / junk"] = "แสดงแร่ / บัว / เศษของ",
    ["Show fishing spots"] = "แสดงจุดตกปลา",
    ["Show buried treasure"] = "แสดงสมบัติที่ฝังไว้",
    ["Re-render terrain every (ms)"] = "เรนเดอร์ภูมิประเทศใหม่ทุก (มิลลิวินาที)",
    ["Camera height above player"] = "ความสูงกล้องเหนือผู้เล่น",
    ["Auto: live render up to zoom"] = "เรนเดอร์สดจนถึงระดับซูม",
    ["Update rate (ms, lower = smoother)"] = "อัตราอัปเดต (มิลลิวินาที, น้อย = ลื่นขึ้น)",
    ["Rescan world every (ms)"] = "สแกนโลกใหม่ทุก (มิลลิวินาที)",
    ["Max point-of-interest icons"] = "ไอคอนจุดที่น่าสนใจสูงสุด",
    ["Log game UI widget names"] = "บันทึกชื่อวิดเจ็ต UI ของเกม",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] ปิด  [F1] เมกะซูม  [F2] มุม  [F3] แสดง/ซ่อน  [F4] แก้ไข  [+/-] ซูม",
    ["Changes save and apply instantly."] = "การเปลี่ยนแปลงถูกบันทึกและใช้งานทันที",
}

STRINGS["ja"] = {
    ["Minimap"] = "ミニマップ",
    ["Pals"] = "パル",
    ["People"] = "人物",
    ["Items"] = "アイテム",
    ["Points of interest"] = "注目地点",
    ["Performance"] = "パフォーマンス",
    ["Troubleshooting"] = "トラブルシューティング",
    ["Show minimap"] = "ミニマップを表示",
    ["Size"] = "サイズ",
    ["Opacity"] = "不透明度",
    ["Circular shape"] = "円形にする",
    ["Live render"] = "リアルタイム描画",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "描画: 0 光あり, 1 フラット (戻る場合あり)",
    ["Terrain quality (0 low - 3 sharp)"] = "地形の品質 (0 低 - 3 鮮明)",
    ["Zoom (world units)"] = "ズーム (ワールド単位)",
    ["Megazoom (F1) range"] = "メガズームの範囲 (F1)",
    ["Auto zoom out while moving"] = "移動中に自動でズームアウト",
    ["Rotate with camera"] = "カメラに合わせて回転",
    ["Keep icons upright"] = "アイコンを常に上向きに",
    ["Hide behind the game's menu"] = "ゲームのメニュー表示中は隠す",
    ["Hide while in a base camp"] = "拠点にいる間は隠す",
    ["Icon size"] = "アイコンのサイズ",
    ["Player marker size"] = "プレイヤーマーカーのサイズ",
    ["Show camera view cone"] = "カメラの視野コーンを表示",
    ["View cone opacity"] = "視野コーンの不透明度",
    ["View cone radius"] = "視野コーンの半径",
    ["Show pals"] = "パルを表示",
    ["Only shiny pals"] = "レアなパルのみ",
    ["Show pals while megazoomed"] = "メガズーム中もパルを表示",
    ["Max pal icons"] = "パルアイコンの最大数",
    ["Show other players"] = "他のプレイヤーを表示",
    ["Show NPC humans"] = "NPCの人間を表示",
    ["Max NPC icons"] = "NPCアイコンの最大数",
    ["Max other-player icons"] = "他プレイヤーアイコンの最大数",
    ["Show death locations"] = "死亡地点を表示",
    ["Hide collected items"] = "取得済みのアイテムを隠す",
    ["Show chests"] = "宝箱を表示",
    ["Show eggs"] = "卵を表示",
    ["Show notes"] = "メモを表示",
    ["Show lifmunk effigies"] = "リーフモンの像を表示",
    ["Show skillfruit trees"] = "スキルフルーツの木を表示",
    ["Show fast travel points"] = "ファストトラベル地点を表示",
    ["Show dungeons"] = "ダンジョンを表示",
    ["Show towers"] = "タワーを表示",
    ["Show player base camps"] = "プレイヤーの拠点を表示",
    ["Show enemy camps"] = "敵の拠点を表示",
    ["Show ore / lotus / junk"] = "鉱石 / 蓮 / くずを表示",
    ["Show fishing spots"] = "釣りスポットを表示",
    ["Show buried treasure"] = "埋蔵された宝を表示",
    ["Re-render terrain every (ms)"] = "地形を再描画する間隔 (ms)",
    ["Camera height above player"] = "プレイヤーからのカメラの高さ",
    ["Auto: live render up to zoom"] = "このズームまでリアルタイム描画",
    ["Update rate (ms, lower = smoother)"] = "更新間隔 (ms、小さいほど滑らか)",
    ["Rescan world every (ms)"] = "ワールドを再スキャンする間隔 (ms)",
    ["Max point-of-interest icons"] = "注目地点アイコンの最大数",
    ["Log game UI widget names"] = "ゲームUIのウィジェット名を記録",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] 閉じる  [F1] メガズーム  [F2] 位置  [F3] 表示/非表示  [F4] 編集  [+/-] ズーム",
    ["Changes save and apply instantly."] = "変更は即座に保存され反映されます。",
}

STRINGS["ko"] = {
    ["Minimap"] = "미니맵",
    ["Pals"] = "팰",
    ["People"] = "사람",
    ["Items"] = "아이템",
    ["Points of interest"] = "주요 지점",
    ["Performance"] = "성능",
    ["Troubleshooting"] = "문제 해결",
    ["Show minimap"] = "미니맵 표시",
    ["Size"] = "크기",
    ["Opacity"] = "불투명도",
    ["Circular shape"] = "원형 모양",
    ["Live render"] = "실시간 렌더링",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "실시간: 0 조명, 1 평면 (되돌아갈 수 있음)",
    ["Terrain quality (0 low - 3 sharp)"] = "지형 품질 (0 낮음 - 3 선명)",
    ["Zoom (world units)"] = "확대 (월드 단위)",
    ["Megazoom (F1) range"] = "메가줌 범위 (F1)",
    ["Auto zoom out while moving"] = "이동 중 자동 축소",
    ["Rotate with camera"] = "카메라에 따라 회전",
    ["Keep icons upright"] = "아이콘을 항상 위로",
    ["Hide behind the game's menu"] = "게임 메뉴가 열리면 숨기기",
    ["Hide while in a base camp"] = "거점에 있을 때 숨기기",
    ["Icon size"] = "아이콘 크기",
    ["Player marker size"] = "플레이어 표식 크기",
    ["Show camera view cone"] = "카메라 시야 콘 표시",
    ["View cone opacity"] = "시야 콘 불투명도",
    ["View cone radius"] = "시야 콘 반경",
    ["Show pals"] = "팰 표시",
    ["Only shiny pals"] = "행운의 팰만",
    ["Show pals while megazoomed"] = "메가줌 중에도 팰 표시",
    ["Max pal icons"] = "최대 팰 아이콘 수",
    ["Show other players"] = "다른 플레이어 표시",
    ["Show NPC humans"] = "NPC 인간 표시",
    ["Max NPC icons"] = "최대 NPC 아이콘 수",
    ["Max other-player icons"] = "최대 다른 플레이어 아이콘 수",
    ["Show death locations"] = "사망 지점 표시",
    ["Hide collected items"] = "이미 획득한 아이템 숨기기",
    ["Show chests"] = "상자 표시",
    ["Show eggs"] = "알 표시",
    ["Show notes"] = "메모 표시",
    ["Show lifmunk effigies"] = "리프멍크 조각상 표시",
    ["Show skillfruit trees"] = "스킬 과일 나무 표시",
    ["Show fast travel points"] = "빠른 이동 지점 표시",
    ["Show dungeons"] = "던전 표시",
    ["Show towers"] = "타워 표시",
    ["Show player base camps"] = "플레이어 거점 표시",
    ["Show enemy camps"] = "적 거점 표시",
    ["Show ore / lotus / junk"] = "광석 / 연꽃 / 고철 표시",
    ["Show fishing spots"] = "낚시터 표시",
    ["Show buried treasure"] = "묻힌 보물 표시",
    ["Re-render terrain every (ms)"] = "지형 재렌더링 주기 (ms)",
    ["Camera height above player"] = "플레이어 위 카메라 높이",
    ["Auto: live render up to zoom"] = "이 확대까지 실시간 렌더링",
    ["Update rate (ms, lower = smoother)"] = "갱신 주기 (ms, 낮을수록 부드러움)",
    ["Rescan world every (ms)"] = "월드 재검색 주기 (ms)",
    ["Max point-of-interest icons"] = "최대 주요 지점 아이콘 수",
    ["Log game UI widget names"] = "게임 UI 위젯 이름 기록",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] 닫기  [F1] 메가줌  [F2] 모서리  [F3] 표시/숨김  [F4] 편집  [+/-] 확대",
    ["Changes save and apply instantly."] = "변경 사항은 즉시 저장되고 적용됩니다.",
}

STRINGS["zh-Hans"] = {
    ["Minimap"] = "小地图",
    ["Pals"] = "帕鲁",
    ["People"] = "人物",
    ["Items"] = "物品",
    ["Points of interest"] = "兴趣点",
    ["Performance"] = "性能",
    ["Troubleshooting"] = "问题排查",
    ["Show minimap"] = "显示小地图",
    ["Size"] = "尺寸",
    ["Opacity"] = "不透明度",
    ["Circular shape"] = "圆形外观",
    ["Live render"] = "实时渲染",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "实时：0 有光照，1 平面（可能回退）",
    ["Terrain quality (0 low - 3 sharp)"] = "地形质量（0 低 - 3 清晰）",
    ["Zoom (world units)"] = "缩放（世界单位）",
    ["Megazoom (F1) range"] = "超级缩放范围（F1）",
    ["Auto zoom out while moving"] = "移动时自动拉远",
    ["Rotate with camera"] = "随镜头旋转",
    ["Keep icons upright"] = "图标保持朝上",
    ["Hide behind the game's menu"] = "游戏菜单打开时隐藏",
    ["Hide while in a base camp"] = "在据点内时隐藏",
    ["Icon size"] = "图标尺寸",
    ["Player marker size"] = "玩家标记尺寸",
    ["Show camera view cone"] = "显示相机视野扇形",
    ["View cone opacity"] = "视野扇形不透明度",
    ["View cone radius"] = "视野扇形半径",
    ["Show pals"] = "显示帕鲁",
    ["Only shiny pals"] = "仅显示幸运帕鲁",
    ["Show pals while megazoomed"] = "超级缩放时也显示帕鲁",
    ["Max pal icons"] = "帕鲁图标上限",
    ["Show other players"] = "显示其他玩家",
    ["Show NPC humans"] = "显示人类 NPC",
    ["Max NPC icons"] = "NPC 图标上限",
    ["Max other-player icons"] = "其他玩家图标上限",
    ["Show death locations"] = "显示死亡地点",
    ["Hide collected items"] = "隐藏已拾取的物品",
    ["Show chests"] = "显示宝箱",
    ["Show eggs"] = "显示蛋",
    ["Show notes"] = "显示笔记",
    ["Show lifmunk effigies"] = "显示皮皮鸡雕像",
    ["Show skillfruit trees"] = "显示技能果树",
    ["Show fast travel points"] = "显示快速旅行点",
    ["Show dungeons"] = "显示地下城",
    ["Show towers"] = "显示高塔",
    ["Show player base camps"] = "显示玩家据点",
    ["Show enemy camps"] = "显示敌人营地",
    ["Show ore / lotus / junk"] = "显示矿石 / 莲花 / 废品",
    ["Show fishing spots"] = "显示钓鱼点",
    ["Show buried treasure"] = "显示埋藏的宝藏",
    ["Re-render terrain every (ms)"] = "地形重新渲染间隔（毫秒）",
    ["Camera height above player"] = "镜头高于玩家的高度",
    ["Auto: live render up to zoom"] = "实时渲染的缩放上限",
    ["Update rate (ms, lower = smoother)"] = "刷新间隔（毫秒，越小越流畅）",
    ["Rescan world every (ms)"] = "重新扫描世界的间隔（毫秒）",
    ["Max point-of-interest icons"] = "兴趣点图标上限",
    ["Log game UI widget names"] = "记录游戏界面控件名称",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] 关闭  [F1] 超级缩放  [F2] 位置  [F3] 显示/隐藏  [F4] 编辑  [+/-] 缩放",
    ["Changes save and apply instantly."] = "更改会立即保存并生效。",
}

STRINGS["zh-Hant"] = {
    ["Minimap"] = "小地圖",
    ["Pals"] = "帕魯",
    ["People"] = "人物",
    ["Items"] = "物品",
    ["Points of interest"] = "興趣點",
    ["Performance"] = "效能",
    ["Troubleshooting"] = "問題排查",
    ["Show minimap"] = "顯示小地圖",
    ["Size"] = "尺寸",
    ["Opacity"] = "不透明度",
    ["Circular shape"] = "圓形外觀",
    ["Live render"] = "即時渲染",
    ["Live render: 0 lit, 1 flat (may fall back)"] = "即時：0 有光照，1 平面（可能回退）",
    ["Terrain quality (0 low - 3 sharp)"] = "地形品質（0 低 - 3 清晰）",
    ["Zoom (world units)"] = "縮放（世界單位）",
    ["Megazoom (F1) range"] = "超級縮放範圍（F1）",
    ["Auto zoom out while moving"] = "移動時自動拉遠",
    ["Rotate with camera"] = "隨鏡頭旋轉",
    ["Keep icons upright"] = "圖示保持朝上",
    ["Hide behind the game's menu"] = "遊戲選單開啟時隱藏",
    ["Hide while in a base camp"] = "在據點內時隱藏",
    ["Icon size"] = "圖示尺寸",
    ["Player marker size"] = "玩家標記尺寸",
    ["Show camera view cone"] = "顯示鏡頭視野扇形",
    ["View cone opacity"] = "視野扇形不透明度",
    ["View cone radius"] = "視野扇形半徑",
    ["Show pals"] = "顯示帕魯",
    ["Only shiny pals"] = "僅顯示幸運帕魯",
    ["Show pals while megazoomed"] = "超級縮放時也顯示帕魯",
    ["Max pal icons"] = "帕魯圖示上限",
    ["Show other players"] = "顯示其他玩家",
    ["Show NPC humans"] = "顯示人類 NPC",
    ["Max NPC icons"] = "NPC 圖示上限",
    ["Max other-player icons"] = "其他玩家圖示上限",
    ["Show death locations"] = "顯示死亡地點",
    ["Hide collected items"] = "隱藏已拾取的物品",
    ["Show chests"] = "顯示寶箱",
    ["Show eggs"] = "顯示蛋",
    ["Show notes"] = "顯示筆記",
    ["Show lifmunk effigies"] = "顯示皮皮雞雕像",
    ["Show skillfruit trees"] = "顯示技能果樹",
    ["Show fast travel points"] = "顯示快速旅行點",
    ["Show dungeons"] = "顯示地下城",
    ["Show towers"] = "顯示高塔",
    ["Show player base camps"] = "顯示玩家據點",
    ["Show enemy camps"] = "顯示敵人營地",
    ["Show ore / lotus / junk"] = "顯示礦石 / 蓮花 / 廢品",
    ["Show fishing spots"] = "顯示釣魚點",
    ["Show buried treasure"] = "顯示埋藏的寶藏",
    ["Re-render terrain every (ms)"] = "地形重新渲染間隔（毫秒）",
    ["Camera height above player"] = "鏡頭高於玩家的高度",
    ["Auto: live render up to zoom"] = "即時渲染的縮放上限",
    ["Update rate (ms, lower = smoother)"] = "更新間隔（毫秒，越小越流暢）",
    ["Rescan world every (ms)"] = "重新掃描世界的間隔（毫秒）",
    ["Max point-of-interest icons"] = "興趣點圖示上限",
    ["Log game UI widget names"] = "記錄遊戲介面控件名稱",
    ["[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom"] =
        "[F5] 關閉  [F1] 超級縮放  [F2] 位置  [F3] 顯示/隱藏  [F4] 編輯  [+/-] 縮放",
    ["Changes save and apply instantly."] = "變更會立即儲存並生效。",
}

-- ---------------------------------------------------------------
-- Which table to use
-- ---------------------------------------------------------------
local S = { culture = nil, lang = nil, table = nil, probed = false }

-- "zh-Hant" -> zh-Hant, "pt" -> pt-BR, "es-MX" -> es, "fr-CA" -> fr,
-- anything with no table -> nil, meaning English.
--
-- EXACT FIRST, then the alias table, then the base language. Doing the
-- base language first would send zh-Hant to zh-Hans.
local function pick(culture)
    if type(culture) ~= "string" or culture == "" then return nil end
    if STRINGS[culture] ~= nil then return culture end
    local alias = ALIAS[culture]
    if alias ~= nil and STRINGS[alias] ~= nil then return alias end
    local base = string.match(culture, "^(%a+)")
    if base == nil then return nil end
    base = string.lower(base)
    if STRINGS[base] ~= nil then return base end
    alias = ALIAS[base]
    if alias ~= nil and STRINGS[alias] ~= nil then return alias end
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

-- ---------------------------------------------------------------
-- Uppercasing the section headers.
--
-- `string.upper` is byte-wise, so it leaves every multi-byte character
-- alone: "Diagnóstico" comes out "DIAGNóSTICO" and "Миникарта" is not
-- touched at all. Two gsubs fix the two cased scripts this file uses;
-- Japanese, Korean, Chinese and Thai have no case, so they fall through
-- unchanged, which is exactly right.
--
--   Latin-1   U+00E0..U+00FE  ->  0xC3 0xA0..0xBE, uppercase is -0x20
--                                 (0xB7 is the division sign: no case)
--   Cyrillic  а..п  0xD0 0xB0..0xBF  ->  А..П  0xD0 0x90..0x9F
--             р..я  0xD1 0x80..0x8F  ->  Р..Я  0xD0 0xA0..0xAF
--             ё     0xD1 0x91        ->  Ё     0xD0 0x81
-- ---------------------------------------------------------------
function M.upper(s)
    if type(s) ~= "string" then return s end
    s = string.gsub(s, "\209\145", "\208\129")                  -- ё
    s = string.gsub(s, "\208([\176-\191])", function(c)          -- а..п
        return "\208" .. string.char(string.byte(c) - 32)
    end)
    s = string.gsub(s, "\209([\128-\143])", function(c)          -- р..я
        return "\208" .. string.char(string.byte(c) + 32)
    end)
    s = string.gsub(s, "\195([\160-\182\184-\190])", function(c) -- Latin-1
        return "\195" .. string.char(string.byte(c) - 32)
    end)
    -- ASCII ONLY, BY BYTE RANGE, and never `string.upper`. That function is
    -- C's toupper per byte and therefore LOCALE DEPENDENT: on the harness's
    -- Lua it mangled bytes above 0x7F, turning perfectly good Japanese into
    -- invalid UTF-8. `%l` has the same problem. A literal [a-z] cannot.
    return (string.gsub(s, "[a-z]", function(c)
        return string.char(string.byte(c) - 32)
    end))
end

-- test hooks
function M.languages()
    local out = {}
    for k in pairs(STRINGS) do out[#out + 1] = k end
    table.sort(out)
    return out
end
function M.aliases() return ALIAS end
function M.stringsFor(lang) return STRINGS[lang] end

return M
