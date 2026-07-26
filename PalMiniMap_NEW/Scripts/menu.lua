-- =====================================================================
-- menu.lua - the F5 configuration window
--
-- Ported from the 1.x menu, which was the part users actually touched.
-- Same interaction model, because it worked: build a UMG window, poll the
-- controls 4x a second, commit checkboxes immediately and sliders only
-- after they have rested (dragging a slider used to rewrite the settings
-- file four times a second - a visible hitch).
--
-- Options that existed in 1.x but describe machinery version 2 no longer
-- has are gone rather than faked: "minimap render resolution" and
-- "capture LOD bias" configured the scene capture, and there is no scene
-- capture any more. Everything else carried over, and the axis controls
-- at the bottom are new - they are the escape hatch if the map texture
-- orientation ever needs correcting without editing code.
-- =====================================================================

local guard = require("guard")

local M = {}

-- Set by main.lua: { controller = fn, viewport = fn, isGameWorld = fn }.
-- Accessors, never cached objects -- see the note on applyInputMode.
M.env = nil

local function controller()
    if M.env == nil or M.env.controller == nil then return nil end
    local pc = guard.get(M.env.controller)
    if guard.alive(pc) then return pc end
    return nil
end

local function inGameWorld()
    if M.env == nil or M.env.isGameWorld == nil then return false end
    return guard.get(M.env.isGameWorld) == true
end

local VIS_SHOW, VIS_HIDE = 0, 1     -- ESlateVisibility Visible / Collapsed
local SLIDER_COMMIT_DELAY = 0.4

local S = {
    widget = nil, tree = nil,
    controls = {},
    open = false,
    world = "",
    -- NOT 0: the debounce compares against os.clock(), which is small right
    -- after the process starts, so a 0 here silently swallows the very first
    -- key press. Start far enough back that the first press always counts.
    lastToggle = -1e9,
}

local UI = {
    panel   = { R = 0.020, G = 0.028, B = 0.045, A = 0.94 },
    header  = { R = 0.055, G = 0.105, B = 0.155, A = 0.98 },
    accent  = { R = 0.33,  G = 0.78,  B = 0.96,  A = 1.0 },
    dim     = { R = 0.16,  G = 0.34,  B = 0.44,  A = 1.0 },
    text    = { R = 0.90,  G = 0.93,  B = 0.96,  A = 1.0 },
    muted   = { R = 0.56,  G = 0.62,  B = 0.70,  A = 1.0 },
}

-- key, label, kind, and for sliders min/max/step
local LAYOUT = {
    { header = "Minimap" },
    { key = "enabled",           label = "Show minimap",             kind = "bool" },
    { key = "size",              label = "Size",                     kind = "int", min = 120, max = 480 },
    { key = "opacity",           label = "Opacity",                  kind = "pct" },
    { key = "circular",          label = "Circular shape",           kind = "bool" },
    { key = "zoom",              label = "Zoom (world units)",       kind = "int", min = 4000, max = 120000, step = 1000 },
    { key = "megazoom",          label = "Megazoom (F1) range",      kind = "int", min = 60000, max = 500000, step = 10000 },
    { key = "autozoom",          label = "Auto zoom out while moving", kind = "bool" },
    { key = "rotateWithCamera",  label = "Rotate with camera",       kind = "bool" },
    { key = "lockIconsNorth",    label = "Keep icons upright",       kind = "bool" },
    { key = "hideBehindGameUi",  label = "Hide behind the game's menu", kind = "bool" },
    { key = "autohideInBase",    label = "Hide while in a base camp", kind = "bool" },
    { key = "iconSize",          label = "Icon size",                kind = "int", min = 10, max = 40 },
    { key = "playerIconSize",    label = "Player marker size",       kind = "int", min = 10, max = 48 },

    { header = "Pals" },
    { key = "showPals",          label = "Show pals",                kind = "bool" },
    { key = "onlyShinyPals",     label = "Only shiny pals",          kind = "bool" },
    { key = "palsWhileMegazoom", label = "Show pals while megazoomed", kind = "bool" },
    { key = "maxPalIcons",       label = "Max pal icons",            kind = "int", min = 8, max = 128 },

    { header = "People" },
    { key = "showPlayers",       label = "Show other players",       kind = "bool" },
    { key = "showNPCs",          label = "Show NPC humans",          kind = "bool" },
    { key = "showDeaths",        label = "Show death locations",     kind = "bool" },

    { header = "Items" },
    { key = "hideCollected",     label = "Hide collected items",     kind = "bool" },
    { key = "showChests",        label = "Show chests",              kind = "bool" },
    { key = "showEggs",          label = "Show eggs",                kind = "bool" },
    { key = "showNotes",         label = "Show notes",               kind = "bool" },
    { key = "showEffigies",      label = "Show lifmunk effigies",    kind = "bool" },
    { key = "showSkillFruit",    label = "Show skillfruit trees",    kind = "bool" },

    { header = "Points of interest" },
    { key = "showFastTravel",    label = "Show fast travel points",  kind = "bool" },
    { key = "showDungeons",      label = "Show dungeons",            kind = "bool" },
    { key = "showTowers",        label = "Show towers",              kind = "bool" },
    { key = "showBaseCamps",     label = "Show player base camps",   kind = "bool" },
    { key = "showEnemyCamps",    label = "Show enemy camps",         kind = "bool" },

    -- 1.x had a "minimap quality" slider, but what it actually changed was
    -- the scene capture's render-target resolution, and there is no scene
    -- capture in 2.x - the terrain is the game's own map texture, drawn as
    -- one quad, so there is no resolution to trade away. These three are
    -- the real performance knobs now: how often the icons are repositioned,
    -- how often the world is rescanned, and how many icons may exist.
    -- 50 ms is the floor on purpose: the single game-thread pump ticks at
    -- 33 ms, so anything below that only adds dispatches without adding
    -- frames. See the threading note at the top of main.lua.
    { header = "Performance" },
    { key = "moveIntervalMs",    label = "Update rate (ms, lower = smoother)", kind = "int", min = 50, max = 500, step = 5 },
    { key = "scanIntervalMs",    label = "Rescan world every (ms)",  kind = "int", min = 1000, max = 20000, step = 500 },
    { key = "maxPoiIcons",       label = "Max point-of-interest icons", kind = "int", min = 8, max = 128 },

    { header = "Map orientation (only if the map looks wrong)" },
    { key = "axis.swapXY",       label = "Swap X / Y",               kind = "bool" },
    { key = "axis.flipH",        label = "Mirror horizontally",      kind = "bool" },
    { key = "axis.flipV",        label = "Mirror vertically",        kind = "bool" },
}

-- ---------------------------------------------------------------
-- config access, including the nested axis.* keys
-- ---------------------------------------------------------------
local function readKey(cfg, key)
    local a, b = key:match("^(%w+)%.(%w+)$")
    if a then
        local t = cfg[a]
        return type(t) == "table" and t[b] or nil
    end
    return cfg[key]
end

local function writeKey(cfg, key, value)
    local a, b = key:match("^(%w+)%.(%w+)$")
    if a then
        if type(cfg[a]) ~= "table" then cfg[a] = {} end
        cfg[a][b] = value
        return
    end
    cfg[key] = value
end

-- ---------------------------------------------------------------
-- small UMG helpers
-- ---------------------------------------------------------------
local function cls(path)
    local o = guard.get(StaticFindObject, path)
    if o and guard.alive(o) then return o end
    return nil
end

local function make(classPath)
    local c = cls(classPath)
    if c == nil then return nil end
    return guard.get(StaticConstructObject, c, S.tree)
end

local function text(str, size, colour, justify)
    local t = make("/Script/UMG.TextBlock")
    if t == nil then return nil end
    guard.get(function() t:SetText(FText(str)) end)
    guard.get(function() t.Font.Size = (size or 14) + 0.0 end)
    if colour then
        guard.get(function()
            t:SetColorAndOpacity({ SpecifiedColor = colour, ColorUseRule = 0 })
        end)
    end
    if justify then guard.get(function() t:SetJustification(justify) end) end
    return t
end

local function pad(slot, l, t, r, b)
    if slot then
        guard.get(function() slot:SetPadding({ Left = l, Top = t, Right = r, Bottom = b }) end)
    end
end

local function fill(slot)
    if slot then guard.get(function() slot:SetSize({ Value = 1.0, SizeRule = 1 }) end) end
end

local function align(slot, h, v)
    if slot == nil then return end
    if h then guard.get(function() slot:SetHorizontalAlignment(h) end) end
    if v then guard.get(function() slot:SetVerticalAlignment(v) end) end
end

local function addRow(scroll, child, t, b)
    local slot = guard.get(function() return scroll:AddChild(child) end)
    pad(slot, 6, t or 4, 6, b or 4)
    return slot
end

-- ---------------------------------------------------------------
-- Input mode
--
-- Setting the cursor once when the window opens was not enough: Palworld
-- drives its own input state during gameplay and puts the cursor straight
-- back, which is why 2.0.1's menu came up with no usable mouse and only
-- became clickable after opening the game's Esc menu. So we assert it on
-- every poll tick (4x a second, two property writes) for as long as the
-- window is open, and hand control back cleanly on close.
-- EMouseLockMode: 0 DoNotLock. UIOnly is the right mode for a modal
-- window; GameAndUI is kept as a fallback for builds without it.
-- ---------------------------------------------------------------
local function applyInputMode(pc, widget)
    if pc == nil or not guard.alive(pc) then return end
    -- NEVER on the splash/login/title screens. Those PlayerControllers are
    -- short-lived and are destroyed as the title flow advances; 2.0.2 held
    -- one and kept calling SetInputMode on it four times a second, which
    -- crashed the game a few seconds after opening the menu there. Those
    -- screens already have a working cursor of their own, so there is
    -- nothing to force anyway. 1.x had this exact guard; dropping it in
    -- the rewrite is what reintroduced the bug.
    if not inGameWorld() then return end
    local wbl = cls("/Script/UMG.Default__WidgetBlueprintLibrary")
    if wbl ~= nil and widget ~= nil then
        local ok = guard.get(function()
            wbl:SetInputMode_UIOnlyEx(pc, widget, 0)
            return true
        end)
        if ok == nil then
            guard.get(function() wbl:SetInputMode_GameAndUIEx(pc, widget, 0, false) end)
        end
    end
    guard.get(function() pc.bShowMouseCursor = true end)
end

local function releaseInputMode(pc)
    if pc == nil or not guard.alive(pc) then return end
    if not inGameWorld() then return end
    local wbl = cls("/Script/UMG.Default__WidgetBlueprintLibrary")
    if wbl ~= nil then
        guard.get(function() wbl:SetInputMode_GameOnly(pc) end)
    end
    guard.get(function() pc.bShowMouseCursor = false end)
end

-- ---------------------------------------------------------------
-- build
-- ---------------------------------------------------------------
local function buildRow(scroll, item, cfg)
    local row = make("/Script/UMG.HorizontalBox")
    if row == nil then return end
    local lbl = text(item.label, 14, UI.text, 0)
    local lblSlot = guard.get(function() return row:AddChild(lbl) end)
    fill(lblSlot); align(lblSlot, nil, 2)

    local value = readKey(cfg, item.key)

    if item.kind == "bool" then
        local cb = make("/Script/UMG.CheckBox")
        if cb == nil then return end
        guard.get(function() cb:SetIsChecked(value == true) end)
        align(guard.get(function() return row:AddChild(cb) end), 3, 2)
        addRow(scroll, row)
        S.controls[#S.controls + 1] = {
            key = item.key, kind = "bool", widget = cb,
            last = (value == true), committed = (value == true),
        }
        return
    end

    -- numeric: slider plus a live readout
    local isPct = item.kind == "pct"
    local mn = isPct and 10 or (item.min or 0)
    local mx = isPct and 100 or (item.max or 100)
    local shown = isPct and math.floor((tonumber(value) or 1) * 100 + 0.5)
                         or math.floor((tonumber(value) or mn) + 0.5)

    local box = make("/Script/UMG.SizeBox")
    local sld = make("/Script/UMG.Slider")
    if box == nil or sld == nil then return end
    guard.get(function() box:SetWidthOverride(170.0) end)
    guard.get(function() box:SetHeightOverride(18.0) end)
    guard.get(function() sld:SetMinValue(mn + 0.0) end)
    guard.get(function() sld:SetMaxValue(mx + 0.0) end)
    guard.get(function() sld:SetValue(shown + 0.0) end)
    guard.get(function() sld.SliderBarColor = UI.dim end)
    guard.get(function() sld.SliderHandleColor = UI.accent end)
    guard.get(function() box:AddChild(sld) end)
    align(guard.get(function() return row:AddChild(box) end), 3, 2)

    local readout = text(tostring(shown), 13, UI.accent, 2)
    local rbox = make("/Script/UMG.SizeBox")
    if rbox ~= nil then
        guard.get(function() rbox:SetWidthOverride(66.0) end)
        guard.get(function() rbox:AddChild(readout) end)
        local rslot = guard.get(function() return row:AddChild(rbox) end)
        pad(rslot, 10, 0, 0, 0); align(rslot, 3, 2)
    end

    addRow(scroll, row, 5, 5)
    S.controls[#S.controls + 1] = {
        key = item.key, kind = isPct and "pct" or "int",
        widget = sld, readout = readout,
        min = mn, max = mx, step = item.step,
        last = shown, committed = shown,
    }
end

function M.build(pc, cfg)
    S.controls = {}
    local wbl = cls("/Script/UMG.Default__WidgetBlueprintLibrary")
    local uw = cls("/Script/UMG.UserWidget")
    if wbl == nil or uw == nil then return false end

    local world = guard.get(function() return pc:GetWorld() end)
    local widget = guard.get(function() return wbl:Create(world, uw, pc) end)
    if not guard.alive(widget) then return false end
    S.widget = widget
    S.tree = guard.get(function() return widget.WidgetTree end)
    if S.tree == nil then return false end

    local canvas = make("/Script/UMG.CanvasPanel")
    if canvas == nil then return false end
    guard.get(function() S.tree.RootWidget = canvas end)

    -- Viewport size comes from main.lua, which reads it through
    -- UWidgetLayoutLibrary. Calling pc:GetViewportSize() here (two OUT
    -- parameters) raised on the title screen and produced a stack dump
    -- every time the menu was opened.
    -- Window geometry. The DPI-scaled viewport is what matters, and Slate
    -- units are what the canvas takes, so `viewport` already returns the
    -- right space. Height is clamped to the screen: the list is long and it
    -- is the ScrollBox's job to page through it.
    local vw, vh = 1280.0, 800.0
    if M.env ~= nil and M.env.viewport ~= nil then
        local _, x, y = guard.try("menu viewport size", M.env.viewport)
        if type(x) == "number" and x > 0 and type(y) == "number" and y > 0 then
            vw, vh = x, y
        end
    end
    local w = math.max(460.0, math.min(vw * 0.34, 700.0))
    local h = math.max(320.0, math.min(vh * 0.80, vh - 100.0))

    local sizeBox = make("/Script/UMG.SizeBox")
    if sizeBox == nil then return false end
    guard.get(function() sizeBox:SetWidthOverride(w) end)
    guard.get(function() sizeBox:SetHeightOverride(h) end)
    local cslot = guard.get(function() return canvas:AddChild(sizeBox) end)
    -- NOT SetAutoSize(true): that sizes the slot to the CONTENT, so the
    -- SizeBox's height override was ignored, the ScrollBox was never given a
    -- bounded height, and the window grew past the bottom of the screen with
    -- nothing to scroll. Fixing the slot size is what makes it scroll.
    guard.get(function() cslot:SetAutoSize(false) end)
    guard.get(function() cslot:SetAlignment({ X = 0.0, Y = 0.0 }) end)
    guard.get(function() cslot:SetSize({ X = w, Y = h }) end)
    -- centred, so it fits at any resolution and any UI scale
    guard.get(function()
        cslot:SetPosition({ X = math.floor((vw - w) * 0.5),
                            Y = math.floor((vh - h) * 0.5) })
    end)

    local border = make("/Script/UMG.Border")
    if border ~= nil then
        guard.get(function() border:SetBrushColor(UI.panel) end)
        guard.get(function() border:SetPadding({ Left = 14, Top = 12, Right = 14, Bottom = 12 }) end)
        guard.get(function() sizeBox:AddChild(border) end)
    end

    local scroll = make("/Script/UMG.ScrollBox")
    if scroll == nil then return false end
    guard.get(function() (border or sizeBox):AddChild(scroll) end)

    local head = make("/Script/UMG.Border")
    if head ~= nil then
        guard.get(function() head:SetBrushColor(UI.header) end)
        guard.get(function() head:SetPadding({ Left = 14, Top = 10, Right = 14, Bottom = 10 }) end)
        local vbox = make("/Script/UMG.VerticalBox")
        if vbox ~= nil then
            guard.get(function() head:AddChild(vbox) end)
            guard.get(function() vbox:AddChild(text("PalMiniMap 2", 24, UI.accent, 0)) end)
            guard.get(function() vbox:AddChild(text("[F5] close  [F1] megazoom  [F2] corner  [F3] show/hide  [F4] edit  [+/-] zoom",
                                                    11, UI.muted, 0)) end)
        end
        pad(guard.get(function() return scroll:AddChild(head) end), 0, 0, 0, 8)
    end

    -- Each row builds inside its own guard: one option the engine refuses
    -- to render must not take the whole menu down with it.
    for _, item in ipairs(LAYOUT) do
        guard.try("menu row '" .. tostring(item.header or item.key) .. "'", function()
            if item.header then
                pad(guard.get(function()
                    return scroll:AddChild(text(string.upper(item.header), 13, UI.accent, 0))
                end), 2, 14, 2, 5)
            else
                buildRow(scroll, item, cfg)
            end
        end)
    end

    pad(guard.get(function()
        return scroll:AddChild(text("Changes save and apply instantly.", 12, UI.muted, 1))
    end), 6, 14, 6, 10)
    return true
end

-- ---------------------------------------------------------------
-- open / close
-- ---------------------------------------------------------------
local function drop()
    S.widget, S.tree = nil, nil
    S.controls = {}
    S.open = false
end

function M.isOpen() return S.open end

function M.usable()
    return S.open and S.widget ~= nil and guard.alive(S.widget)
end

function M.close()
    if not S.open then return end
    if M.onCommit then guard.try("menu flush", function() M.flush() end) end
    if S.widget ~= nil and guard.alive(S.widget) then
        guard.get(function() S.widget:RemoveFromParent() end)
    end
    releaseInputMode(controller())
    drop()
    guard.log("menu closed")
end

function M.open(cfg, worldName)
    if S.open then return end
    -- flush() needs a config even if poll() never got to run (a menu
    -- opened and closed inside one poll interval)
    M.cfg = cfg
    local pc = controller()
    if pc == nil then
        guard.log("menu not opened: no player controller")
        return
    end
    local ok = guard.try("buildMenu", function()
        if not M.build(pc, cfg) then error("could not build the menu widget") end
        guard.get(function() S.widget:AddToViewport(99) end)
        -- the root must hit-test, or clicks fall straight through to the game
        guard.get(function() S.widget:SetVisibility(VIS_SHOW) end)
        guard.get(function() S.widget.bIsFocusable = true end)
        applyInputMode(pc, S.widget)
    end)
    if not ok then
        if S.widget ~= nil and guard.alive(S.widget) then
            guard.get(function() S.widget:RemoveFromParent() end)
        end
        drop()
        return
    end
    S.open = true
    S.world = worldName or ""
    guard.log("menu opened" .. (inGameWorld() and "" or
        " (menu screen: the game's own cursor is used, input mode untouched)"))
end

function M.toggle(cfg, worldName)
    if (os.clock() - S.lastToggle) < 0.3 then return end
    S.lastToggle = os.clock()
    if S.open and not M.usable() then drop() end
    if S.open then M.close() else M.open(cfg, worldName) end
end

function M.worldChanged(worldName)
    if S.open and S.world ~= "" and S.world ~= worldName then drop() end
end

-- ---------------------------------------------------------------
-- polling
--
-- M.onCommit(changedKeys) is set by main.lua and is where the live
-- effects happen (rebuild the widget on a size change, re-lay out on a
-- position change, and so on).
-- ---------------------------------------------------------------
M.onCommit = nil

local function toStored(c, shown)
    if c.kind == "pct" then return shown / 100.0 end
    return shown
end

local function commit(cfg, pending)
    if #pending == 0 then return end
    local keys = {}
    for _, item in ipairs(pending) do
        item.c.committed = item.value
        writeKey(cfg, item.c.key, toStored(item.c, item.value))
        keys[#keys + 1] = item.c.key
    end
    if M.onCommit then
        guard.try("menu onCommit", function() M.onCommit(keys) end)
    end
end

function M.flush()
    local cfg = M.cfg
    if cfg == nil then return end
    local pending = {}
    for _, c in ipairs(S.controls) do
        if c.last ~= nil and c.last ~= c.committed then
            pending[#pending + 1] = { c = c, value = c.last }
        end
    end
    commit(cfg, pending)
end

function M.poll(cfg)
    M.cfg = cfg
    if not S.open then return end
    if not M.usable() then
        releaseInputMode(controller())
        drop()
        return
    end
    -- keep the cursor alive; the game puts it back every frame otherwise
    applyInputMode(controller(), S.widget)
    local now = os.clock()
    local pending = {}
    for _, c in ipairs(S.controls) do
        local ok, cur = guard.try("read control " .. c.key, function()
            if c.kind == "bool" then return c.widget:IsChecked() end
            local v = math.floor(c.widget:GetValue() + 0.5)
            if c.step and c.step > 1 then v = math.floor(v / c.step + 0.5) * c.step end
            if c.min and v < c.min then v = c.min end
            if c.max and v > c.max then v = c.max end
            return v
        end)
        if ok and cur ~= nil then
            if cur ~= c.last then
                c.last = cur
                c.changedAt = now
                if c.readout then
                    guard.get(function() c.readout:SetText(FText(tostring(cur))) end)
                end
            end
            local isSlider = (c.kind ~= "bool")
            if cur ~= c.committed
               and (not isSlider or (now - (c.changedAt or 0)) >= SLIDER_COMMIT_DELAY) then
                pending[#pending + 1] = { c = c, value = cur }
            end
        end
    end
    commit(cfg, pending)
end

return M
