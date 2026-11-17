--[[
RXP Quest Panel
Redraws the RestedXP Guides (RXP) main guide window inside one combined
"guide + quests" panel on the right side of the screen, and takes over from
the quest tracker that normally lives there.

How it works, briefly:
  * RXP pauses its whole guide logic (auto-advance, arrow updates, quest
    automation) whenever its main frame is hidden (RXPFrame OnHide sets
    addon.isHidden). So we never Hide() it. Instead we make it fully
    transparent and switch off mouse input on it and its children. RXP keeps
    running exactly as before; only its window disappears.
  * The tip/warning box ("Be careful! ...") is drawn by RXP as a child of the
    main frame, so it is told to ignore the parent's transparency and stays.
  * We read RXP's own live data (RXPFrame.activeSteps, step.elements,
    element.text/completed/skip) and redraw it in our panel. We hook RXP's own
    update functions to know when to redraw, plus a slow safety refresh.
  * Quests come straight from the quest log API, so it works whether the old
    tracker was Blizzard's, Questie's or Kaliel's.
  * /rxpq toggle switches back to the stock RXP window at any time.
]]

local ADDON_NAME = ...
local _G = _G
local CreateFrame, UIParent, GameTooltip = CreateFrame, UIParent, GameTooltip
local floor, max, min, ipairs, pairs, type, tonumber, tostring, pcall, select =
    math.floor, math.max, math.min, ipairs, pairs, type, tonumber, tostring, pcall, select
local strformat = string.format

local BackdropTemplate = _G.BackdropTemplateMixin and "BackdropTemplate" or nil

---------------------------------------------------------------------------
-- Look
---------------------------------------------------------------------------
local locale = _G.GetLocale and _G.GetLocale() or "enUS"
local LATIN = (locale == "enUS" or locale == "enGB" or locale == "deDE" or locale == "frFR"
               or locale == "esES" or locale == "esMX" or locale == "itIT" or locale == "ptBR")
local BODY_FONT = LATIN and "Fonts\\ARIALN.TTF" or _G.STANDARD_TEXT_FONT
local HEAD_FONT = _G.STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
local WHITE = "Interface\\Buttons\\WHITE8X8"
local CHECK_TEX = "Interface\\Buttons\\UI-CheckBox-Check"

local C = {
    bg       = {0.055, 0.063, 0.078},
    border   = {0.20, 0.22, 0.26, 0.9},
    accent   = {1.00, 0.74, 0.26},       -- warm gold
    text     = {0.92, 0.93, 0.95},
    muted    = {0.58, 0.61, 0.66},
    done     = {0.38, 0.86, 0.47},
    fail     = {0.95, 0.35, 0.32},
    link     = {0.45, 0.76, 1.00},       -- clickable link lines
    barBG    = {1, 1, 1, 0.08},
    boxEdge  = {0.42, 0.45, 0.50, 1},
    boxFill  = {0.09, 0.10, 0.12, 1},
    guideTag = {0.30, 0.78, 0.95},       -- marks quests the current step uses
}

-- The two looks. Each one swaps the colors above in place (C is shared by
-- every drawing function), so switching looks is just ApplyTheme + redraw.
local PALETTES = {
    blizzard = {   -- Blizzard Native: like the game's own objective tracker
        bg = {0, 0, 0}, border = {0, 0, 0, 0},
        accent = {1.00, 0.82, 0.00},          -- Blizzard gold (step and quest titles)
        text = {0.92, 0.92, 0.92}, muted = {0.62, 0.62, 0.62},
        done = {0.25, 0.85, 0.31}, fail = {0.95, 0.30, 0.25},
        link = {0.40, 0.73, 1.00}, barBG = {0, 0, 0, 0.75}, barFill = {0.18, 0.54, 0.90},
        boxEdge = {0.45, 0.45, 0.45, 1}, boxFill = {0.06, 0.06, 0.06, 1},
        guideTag = {0.31, 0.84, 1.00}, sticky = {1.00, 0.82, 0.00}, head = {1.00, 0.82, 0.00},
    },
    rail = {       -- Waypoint Rail: smoked glass, every step on one route line
        bg = {0.047, 0.063, 0.098}, border = {1, 1, 1, 0.08},
        accent = {0.95, 0.72, 0.29},
        text = {0.91, 0.93, 0.95}, muted = {0.56, 0.60, 0.66},
        done = {0.35, 0.84, 0.48}, fail = {0.95, 0.35, 0.32},
        link = {0.42, 0.72, 1.00}, barBG = {1, 1, 1, 0.08}, barFill = {0.95, 0.72, 0.29},
        boxEdge = {0.35, 0.39, 0.48, 1}, boxFill = {0.07, 0.09, 0.13, 1},
        guideTag = {0.37, 0.83, 0.91}, sticky = {0.72, 0.65, 1.00}, head = {0.56, 0.60, 0.66},
    },
}
local STYLE_NAMES = {blizzard = "Blizzard Native", rail = "Waypoint Rail"}
local style = "blizzard"
local function IsRail() return style == "rail" end

local PAD = 10          -- inner padding
local RAIL = 20         -- Waypoint Rail: room on the left for the route line
local INDENT = 14       -- element / objective indent
local BOX = 11          -- checkbox size

---------------------------------------------------------------------------
-- Saved settings
---------------------------------------------------------------------------
local DEFAULTS = {
    enabled = true,            -- false = stock RXP window, our panel hidden
    locked = false,
    scale = 1,
    width = 270,
    maxHeight = 560,
    bgAlpha = 0.72,
    showQuests = true,
    hideOtherTrackers = true,  -- hide Blizzard / Questie / Kaliel's tracker
    collapseGuide = false,
    collapseQuests = false,
    allQuests = false,         -- false = only quests WoW is tracking (shift-click in the quest log)
    point = nil,               -- {point, relativePoint, x, y}
    boxHeight = nil,           -- set by /rxpq setup: fixed box height (nil = grow with content)
    setupHinted = false,
    setupDone = false,         -- first-time setup (place, size, pick a look) finished
    style = "blizzard",        -- "blizzard" (Blizzard Native) or "rail" (Waypoint Rail)
    blizzShade = 0,            -- Blizzard Native draws no box; /rxpq alpha adds a dark shade
}

local db

local function InitDB()
    _G.RXPQuestPanelDB = _G.RXPQuestPanelDB or {}
    db = _G.RXPQuestPanelDB
    for k, v in pairs(DEFAULTS) do
        if db[k] == nil then db[k] = v end
    end
end

local function Print(msg, ...)
    if select("#", ...) > 0 then msg = strformat(msg, ...) end
    _G.DEFAULT_CHAT_FRAME:AddMessage("|cffffbd42RXP Quest Panel:|r " .. tostring(msg))
end

local function RXP() return _G.RXP end           -- RXP's addon table (global it exposes)
local function RXPFrame() return _G.RXPFrame end -- RXP's main window

---------------------------------------------------------------------------
-- Main panel
---------------------------------------------------------------------------
local panel = CreateFrame("Frame", "RXPQuestPanelFrame", UIParent, BackdropTemplate)
panel:SetFrameStrata("MEDIUM")
panel:SetFrameLevel(10)
panel:SetSize(270, 60)          -- real size is set on every render; never 0 tall
panel:SetClampedToScreen(true)
panel:SetMovable(true)
panel:SetResizable(true)
if panel.SetResizeBounds then
    panel:SetResizeBounds(200, 80, 600, 1400)
elseif panel.SetMinResize then
    panel:SetMinResize(200, 80)
    panel:SetMaxResize(600, 1400)
end
panel:Hide()

local scroll = CreateFrame("ScrollFrame", nil, panel)
scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 1, -1)
scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -1, 1)
scroll:EnableMouseWheel(true)

local content = CreateFrame("Frame", nil, scroll)
content:SetSize(10, 10)
scroll:SetScrollChild(content)

-- thin scroll position indicator on the right edge
local scrollThumb = panel:CreateTexture(nil, "OVERLAY")
scrollThumb:SetTexture(WHITE)
scrollThumb:SetVertexColor(1, 1, 1, 0.18)
scrollThumb:SetWidth(2)
scrollThumb:Hide()

local function UpdateScrollThumb()
    local range = scroll:GetVerticalScrollRange() or 0
    if range <= 0 then scrollThumb:Hide() return end
    local h = panel:GetHeight()
    local total = h + range
    local thumbH = max(16, h * h / total)
    local pos = (scroll:GetVerticalScroll() or 0) / range
    scrollThumb:ClearAllPoints()
    scrollThumb:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -2, -(2 + pos * (h - thumbH - 4)))
    scrollThumb:SetHeight(thumbH)
    scrollThumb:Show()
end

scroll:SetScript("OnMouseWheel", function(self, delta)
    local range = self:GetVerticalScrollRange() or 0
    local v = (self:GetVerticalScroll() or 0) - delta * 36
    if v < 0 then v = 0 elseif v > range then v = range end
    self:SetVerticalScroll(v)
    UpdateScrollThumb()
end)

local RestorePosition    -- defined below

local function ApplyLook()
    if panel.SetBackdrop then
        panel:SetBackdrop({bgFile = WHITE, edgeFile = WHITE, edgeSize = 1})
        local a = IsRail() and db.bgAlpha or db.blizzShade or 0
        panel:SetBackdropColor(C.bg[1], C.bg[2], C.bg[3], a)
        panel:SetBackdropBorderColor(unpack(C.border))
    end
    if panel:GetScale() ~= db.scale then
        panel:SetScale(db.scale)
        if db.point then RestorePosition() end
    end
    panel:SetWidth(db.width)
end

-- The panel is always anchored by its TOP-RIGHT corner, so its top edge
-- stays put and it only ever grows or shrinks downward. After a drag WoW
-- re-anchors the frame from whatever corner it likes (often CENTER or
-- BOTTOMLEFT), so we convert back to TOPRIGHT straight away.
local function PinTopRight()
    local top, right = panel:GetTop(), panel:GetRight()
    local uTop, uRight = UIParent:GetTop(), UIParent:GetRight()
    if not (top and right and uTop and uRight) then return false end
    local ps, us = panel:GetEffectiveScale(), UIParent:GetEffectiveScale()
    local x = (right * ps - uRight * us) / ps
    local y = (top * ps - uTop * us) / ps
    panel:ClearAllPoints()
    panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", x, y)
    db.point = {"TOPRIGHT", "TOPRIGHT", x, y}
    return true
end

local function SavePosition()
    PinTopRight()
end

RestorePosition = function()
    panel:ClearAllPoints()
    local pt = db.point
    if pt then
        panel:SetPoint(pt[1], UIParent, pt[2], pt[3], pt[4])
        -- positions saved by 0.1.0/0.1.1 may use another corner: convert once
        if pt[1] ~= "TOPRIGHT" or pt[2] ~= "TOPRIGHT" then PinTopRight() end
    else
        -- Roughly where the quest tracker sits, under the minimap.
        panel:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -24, -250)
    end
end

-- Room between the panel's top edge and the bottom of the screen, so the
-- panel scrolls instead of growing past the screen (which would make the
-- screen clamp push it upward).
local function SpaceBelowTop()
    local top, uBottom = panel:GetTop(), UIParent:GetBottom()
    if not (top and uBottom) then return nil end
    local ps, us = panel:GetEffectiveScale(), UIParent:GetEffectiveScale()
    return (top * ps - uBottom * us) / ps - 8
end

---------------------------------------------------------------------------
-- Small widgets
---------------------------------------------------------------------------
-- A FontString with no font throws "Font not set" on SetText, so this must
-- always leave one in place, whatever fonts the client ships.
local function SetFont(fs, font, size, flags)
    if fs.SetShadowOffset then
        fs:SetShadowOffset(1, -1)              -- readable over bright ground with no box behind
        fs:SetShadowColor(0, 0, 0, 0.9)
    end
    if font and fs:SetFont(font, size, flags or "") then return end
    if _G.STANDARD_TEXT_FONT and fs:SetFont(_G.STANDARD_TEXT_FONT, size, flags or "") then return end
    fs:SetFontObject(_G.GameFontHighlightSmall or _G.GameFontNormal)
end

-- Horizontal fade on a texture, across old and new client APIs.
local function Fade(tex, r, g, b, a1, a2)
    tex:SetTexture(WHITE)
    tex:SetVertexColor(1, 1, 1, 1)
    if _G.CreateColor and pcall(tex.SetGradient, tex, "HORIZONTAL",
            _G.CreateColor(r, g, b, a1), _G.CreateColor(r, g, b, a2)) then return end
    if tex.SetGradientAlpha and pcall(tex.SetGradientAlpha, tex, "HORIZONTAL", r, g, b, a1, r, g, b, a2) then return end
    tex:SetVertexColor(r, g, b, (a1 + a2) / 2)
end

local function NewCheck(parent)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(BOX, BOX)
    b.edge = b:CreateTexture(nil, "BACKGROUND")
    b.edge:SetAllPoints()
    b.edge:SetTexture(WHITE)
    b.fill = b:CreateTexture(nil, "BORDER")
    b.fill:SetPoint("TOPLEFT", 1, -1)
    b.fill:SetPoint("BOTTOMRIGHT", -1, 1)
    b.fill:SetTexture(WHITE)
    b.mark = b:CreateTexture(nil, "ARTWORK")
    b.mark:SetPoint("CENTER", 1, 0)
    b.mark:SetSize(BOX + 7, BOX + 7)
    b.mark:SetTexture(CHECK_TEX)
    local hl = b:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetTexture(WHITE)
    hl:SetVertexColor(1, 1, 1, 0.15)
    b.dash = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.dash, HEAD_FONT, 12, "")
    b.dash:SetPoint("CENTER", 0, 0)
    b.dash:SetText("-")
    b.SetState = function(self, checked)
        if not IsRail() then
            -- Blizzard Native: a dash like the game's tracker, a green tick once done
            self.edge:SetVertexColor(0, 0, 0, 0)
            self.fill:SetVertexColor(0, 0, 0, 0)
            self.dash:SetTextColor(unpack(C.text))
            if checked then
                self.mark:SetVertexColor(C.done[1], C.done[2], C.done[3], 1)
                self.mark:Show(); self.dash:Hide()
            else
                self.mark:Hide(); self.dash:Show()
            end
            return
        end
        self.dash:Hide()
        self.mark:SetVertexColor(1, 1, 1, 1)
        if checked then
            self.edge:SetVertexColor(C.done[1], C.done[2], C.done[3], 1)
            self.fill:SetVertexColor(C.done[1] * 0.35, C.done[2] * 0.35, C.done[3] * 0.35, 1)
            self.mark:Show()
        else
            self.edge:SetVertexColor(unpack(C.boxEdge))
            self.fill:SetVertexColor(unpack(C.boxFill))
            self.mark:Hide()
        end
    end
    return b
end

local function NewRow()
    local r = CreateFrame("Button", nil, content)
    r:RegisterForClicks("LeftButtonUp", "RightButtonUp")

    r.hl = r:CreateTexture(nil, "HIGHLIGHT")
    r.hl:SetAllPoints()
    r.hl:SetTexture(WHITE)
    r.hl:SetVertexColor(1, 1, 1, 0.04)

    r.stripe = r:CreateTexture(nil, "ARTWORK")
    r.stripe:SetTexture(WHITE)
    r.stripe:SetWidth(2)
    r.stripe:SetPoint("TOPLEFT", r, "TOPLEFT", -6, -1)
    r.stripe:SetPoint("BOTTOMLEFT", r, "BOTTOMLEFT", -6, 1)

    r.text = r:CreateFontString(nil, "OVERLAY")
    SetFont(r.text, BODY_FONT, 12, "")
    r.text:SetJustifyH("LEFT")
    r.text:SetJustifyV("TOP")
    r.text:SetWordWrap(true)
    if r.text.SetNonSpaceWrap then r.text:SetNonSpaceWrap(true) end

    r.right = r:CreateFontString(nil, "OVERLAY")
    SetFont(r.right, BODY_FONT, 11, "")
    r.right:SetJustifyH("RIGHT")
    r.right:SetPoint("TOPRIGHT", r, "TOPRIGHT", 0, 0)

    r.check = NewCheck(r)
    r.check:SetPoint("TOPLEFT", r, "TOPLEFT", 0, -2)
    r.check:SetScript("OnClick", function(self)
        local row = self:GetParent()
        if row.onCheck then row.onCheck(row) end
    end)
    r.check:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText("Skip / un-skip this objective", 1, 1, 1)
        GameTooltip:Show()
    end)
    r.check:SetScript("OnLeave", function(self)
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)

    r.barEdge = r:CreateTexture(nil, "BORDER")
    r.barEdge:SetTexture(WHITE)
    r.barBG = r:CreateTexture(nil, "ARTWORK")
    r.barBG:SetTexture(WHITE)
    r.bar = r:CreateTexture(nil, "OVERLAY")
    r.bar:SetTexture(WHITE)
    r.pct = r:CreateFontString(nil, "OVERLAY")
    SetFont(r.pct, BODY_FONT, 9, "")
    r.pct:SetPoint("CENTER", r.barBG, "CENTER", 0, 0)
    r.pct:SetTextColor(1, 1, 1)

    -- Waypoint Rail: the step's marker on the route line (a diamond)
    r.nodeBack = r:CreateTexture(nil, "ARTWORK")
    r.nodeBack:SetTexture(WHITE)
    r.node = r:CreateTexture(nil, "OVERLAY")
    r.node:SetTexture(WHITE)
    if r.node.SetRotation then
        pcall(r.node.SetRotation, r.node, math.rad(45))
        pcall(r.nodeBack.SetRotation, r.nodeBack, math.rad(45))
    end

    r:SetScript("OnClick", function(self, button)
        if self.onClick then self.onClick(self, button) end
    end)
    r:SetScript("OnEnter", function(self)
        if self.onEnter then self.onEnter(self) end
    end)
    r:SetScript("OnLeave", function(self)
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
    return r
end

-- Change visibility / mouse state only when it actually differs. A Hide()
-- or EnableMouse(false) in the middle of a click (between mouse-down and
-- mouse-up) cancels the click, and we redraw several times a second, so
-- every redraw has to leave untouched whatever is already right.
local function Vis(obj, on)
    if on then
        if not obj:IsShown() then obj:Show() end
    elseif obj:IsShown() then
        obj:Hide()
    end
end

local function Mouse(frame, on)
    if (frame:IsMouseEnabled() and true or false) ~= (on and true or false) then
        frame:EnableMouse(on and true or false)
    end
end

local rowPool, rowsUsed = {}, 0

local function AcquireRow()
    rowsUsed = rowsUsed + 1
    local r = rowPool[rowsUsed]
    if not r then
        r = NewRow()
        rowPool[rowsUsed] = r
    end
    r.onClick, r.onEnter, r.onCheck, r.element, r.questIndex = nil, nil, nil, nil, nil
    -- what this row should show; applied once at the end of the redraw
    r.wStripe, r.wCheck, r.wBarBG, r.wBar, r.wRight, r.wMouse = false, false, false, false, false, false
    r.wNode, r.wNodeBack, r.wPct, r.wEdge = false, false, false, false
    return r
end

local function FinishRows()
    for i = 1, rowsUsed do
        local r = rowPool[i]
        Vis(r.stripe, r.wStripe)
        Vis(r.check, r.wCheck)
        Vis(r.barBG, r.wBarBG)
        Vis(r.bar, r.wBar)
        Vis(r.right, r.wRight)
        Vis(r.node, r.wNode)
        Vis(r.nodeBack, r.wNodeBack)
        Vis(r.pct, r.wPct)
        Vis(r.barEdge, r.wEdge)
        Mouse(r, r.wMouse)
    end
    for i = rowsUsed + 1, #rowPool do Vis(rowPool[i], false) end
end

---------------------------------------------------------------------------
-- Section headers (persistent, not pooled)
---------------------------------------------------------------------------
local function NewHeader(label)
    local h = CreateFrame("Button", nil, content)
    h:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    h:RegisterForDrag("LeftButton")
    h.bar = h:CreateTexture(nil, "BACKGROUND")       -- Blizzard Native: fading header bar
    h.bar:SetAllPoints(h)
    h.top = h:CreateTexture(nil, "BORDER")           -- and its thin gold top edge
    h.top:SetPoint("TOPLEFT", h, "TOPLEFT", 0, 0)
    h.top:SetPoint("TOPRIGHT", h, "TOPRIGHT", 0, 0)
    h.top:SetHeight(1)
    h.label = h:CreateFontString(nil, "OVERLAY")
    SetFont(h.label, HEAD_FONT, 10, "")
    h.label:SetPoint("LEFT", h, "LEFT", 0, 0)
    h.label:SetTextColor(unpack(C.muted))
    h.label:SetText(label)
    h.plus = h:CreateTexture(nil, "OVERLAY")       -- Blizzard Native: the game's +/- button
    h.plus:SetSize(14, 14)
    h.plus:SetPoint("RIGHT", h, "RIGHT", -2, 0)
    h.arrow = h:CreateFontString(nil, "OVERLAY")
    SetFont(h.arrow, HEAD_FONT, 10, "")
    h.arrow:SetPoint("RIGHT", h, "RIGHT", 0, 0)
    h.arrow:SetTextColor(unpack(C.muted))
    h.line = h:CreateTexture(nil, "ARTWORK")
    h.line:SetTexture(WHITE)
    h.line:SetVertexColor(1, 1, 1, 0.10)
    h.line:SetHeight(1)
    h.line:SetPoint("LEFT", h.label, "RIGHT", 6, 0)
    h.line:SetPoint("RIGHT", h.arrow, "LEFT", -6, 0)
    h:SetScript("OnDragStart", function()
        if db.locked then return end
        panel:StartMoving()
    end)
    h:SetScript("OnDragStop", function()
        panel:StopMovingOrSizing()
        panel.lastDrag = _G.GetTime()
        SavePosition()
    end)
    return h
end

local guideHeader = NewHeader("GUIDE")
local questHeader = NewHeader("QUESTS")

-- Guide title block: guide name, group, step counter, prev / next buttons.
local guideTitle = CreateFrame("Button", nil, content)
guideTitle:RegisterForClicks("LeftButtonUp", "RightButtonUp")
guideTitle:RegisterForDrag("LeftButton")
guideTitle.name = guideTitle:CreateFontString(nil, "OVERLAY")
SetFont(guideTitle.name, HEAD_FONT, 13, "")
guideTitle.name:SetJustifyH("LEFT")
guideTitle.name:SetWordWrap(false)
guideTitle.name:SetPoint("TOPLEFT", guideTitle, "TOPLEFT", 0, 0)
guideTitle.name:SetTextColor(unpack(C.text))
guideTitle.group = guideTitle:CreateFontString(nil, "OVERLAY")
SetFont(guideTitle.group, BODY_FONT, 11, "")
guideTitle.group:SetJustifyH("LEFT")
guideTitle.group:SetWordWrap(false)
guideTitle.group:SetPoint("TOPLEFT", guideTitle.name, "BOTTOMLEFT", 0, -2)
guideTitle.group:SetTextColor(unpack(C.muted))
guideTitle.counter = guideTitle:CreateFontString(nil, "OVERLAY")
SetFont(guideTitle.counter, BODY_FONT, 11, "")
guideTitle.counter:SetTextColor(unpack(C.muted))
guideTitle:SetScript("OnDragStart", guideHeader:GetScript("OnDragStart"))
guideTitle:SetScript("OnDragStop", guideHeader:GetScript("OnDragStop"))
guideTitle:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:SetText("RestedXP guide", 1, 1, 1)
    GameTooltip:AddLine("Right-click: pick a guide / RXP menu", 0.8, 0.8, 0.8)
    if not db.locked then GameTooltip:AddLine("Drag: move this panel", 0.8, 0.8, 0.8) end
    GameTooltip:Show()
end)
guideTitle:SetScript("OnLeave", function(self)
    if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
end)

local function NewNavButton(symbol, tip)
    local b = CreateFrame("Button", nil, guideTitle)
    b:SetSize(16, 16)
    b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    b.page = symbol == "<" and "Interface\\Buttons\\UI-SpellbookIcon-PrevPage" or "Interface\\Buttons\\UI-SpellbookIcon-NextPage"
    b.icon = b:CreateTexture(nil, "ARTWORK")          -- Blizzard Native: round gold page arrows
    b.icon:SetPoint("CENTER", 0, 0)
    b.icon:SetSize(24, 24)
    b.bg = b:CreateTexture(nil, "BACKGROUND")         -- Waypoint Rail: small dark key
    b.bg:SetAllPoints(b)
    b.bg:SetTexture(WHITE)
    b.bg:SetVertexColor(1, 1, 1, 0.06)
    b:SetScript("OnMouseDown", function(self) if not IsRail() then self.icon:SetTexture(self.page .. "-Down") end end)
    b:SetScript("OnMouseUp", function(self) if not IsRail() then self.icon:SetTexture(self.page .. "-Up") end end)
    b.t = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.t, HEAD_FONT, 13, "")
    b.t:SetPoint("CENTER", 0, 1)
    b.t:SetText(symbol)
    b.t:SetTextColor(unpack(C.muted))
    b:SetScript("OnEnter", function(self)
        self.t:SetTextColor(unpack(C.accent))
        if not IsRail() then self.icon:SetVertexColor(1.2, 1.2, 1.2) end
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(tip, 1, 1, 1)
        GameTooltip:Show()
    end)
    b:SetScript("OnLeave", function(self)
        self.t:SetTextColor(unpack(C.muted))
        self.icon:SetVertexColor(1, 1, 1)
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
    return b
end

local nextBtn = NewNavButton(">", "Look at the next step\n|cff9aa0a8RestedXP stays on your step. Right-click: back to current.|r")
nextBtn:SetPoint("TOPRIGHT", guideTitle, "TOPRIGHT", 2, 1)
local prevBtn = NewNavButton("<", "Look at the previous step\n|cff9aa0a8RestedXP stays on your step. Right-click: back to current.|r")
prevBtn:SetPoint("RIGHT", nextBtn, "LEFT", 0, 0)
guideTitle.counter:SetPoint("RIGHT", prevBtn, "LEFT", -2, -1)

-- Waypoint Rail: how far through the guide you are, under the guide name
guideTitle.progBG = guideTitle:CreateTexture(nil, "ARTWORK")
guideTitle.progBG:SetTexture(WHITE)
guideTitle.progBG:SetPoint("BOTTOMLEFT", guideTitle, "BOTTOMLEFT", 0, 0)
guideTitle.progBG:SetPoint("BOTTOMRIGHT", guideTitle, "BOTTOMRIGHT", 0, 0)
guideTitle.progBG:SetHeight(3)
guideTitle.prog = guideTitle:CreateTexture(nil, "OVERLAY")
guideTitle.prog:SetTexture(WHITE)
guideTitle.prog:SetPoint("TOPLEFT", guideTitle.progBG, "TOPLEFT", 0, 0)
guideTitle.prog:SetHeight(3)

-- Waypoint Rail: the route line the steps sit on
local railLine = content:CreateTexture(nil, "BACKGROUND")
railLine:SetTexture(WHITE)
railLine:SetWidth(2)
railLine:Hide()

-- Peek bar: one slim line shown while you look at a step other than your own.
local peekBar = CreateFrame("Frame", nil, content)
peekBar.bg = peekBar:CreateTexture(nil, "BACKGROUND")
peekBar.bg:SetTexture(WHITE)
peekBar.bg:SetAllPoints(peekBar)
peekBar.bg:SetVertexColor(C.link[1], C.link[2], C.link[3], 0.08)
peekBar.stripe = peekBar:CreateTexture(nil, "ARTWORK")
peekBar.stripe:SetTexture(WHITE)
peekBar.stripe:SetVertexColor(C.link[1], C.link[2], C.link[3], 0.9)
peekBar.stripe:SetPoint("TOPLEFT", peekBar, "TOPLEFT", 0, 0)
peekBar.stripe:SetPoint("BOTTOMLEFT", peekBar, "BOTTOMLEFT", 0, 0)
peekBar.stripe:SetWidth(2)
peekBar.label = peekBar:CreateFontString(nil, "OVERLAY")
SetFont(peekBar.label, HEAD_FONT, 10, "")
peekBar.label:SetPoint("LEFT", peekBar, "LEFT", 8, 0)
peekBar.label:SetTextColor(unpack(C.link))
peekBar.state = peekBar:CreateFontString(nil, "OVERLAY")
SetFont(peekBar.state, BODY_FONT, 11, "")
peekBar.state:SetPoint("LEFT", peekBar.label, "RIGHT", 6, 0)
peekBar.state:SetTextColor(unpack(C.muted))

local function NewPillButton(parent, label)
    local b = CreateFrame("Button", nil, parent)
    b:RegisterForClicks("LeftButtonUp")
    b.bg = b:CreateTexture(nil, "ARTWORK")
    b.bg:SetAllPoints(b)
    b.t = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.t, BODY_FONT, 11, "")
    b.t:SetPoint("CENTER", 0, 0)
    b:SetSize(48, 15)
    -- Blizzard Native: the game's red panel button. Waypoint Rail: a soft blue key.
    b.Restyle = function(self, hover)
        if IsRail() then
            self.bg:SetTexture(WHITE)
            self.bg:SetTexCoord(0, 1, 0, 1)
            self.bg:SetVertexColor(C.link[1], C.link[2], C.link[3], hover and 0.34 or 0.16)
            SetFont(self.t, BODY_FONT, 11, "")
            if hover then self.t:SetTextColor(1, 1, 1) else self.t:SetTextColor(unpack(C.link)) end
            self:SetHeight(15)
        else
            self.bg:SetTexture("Interface\\Buttons\\UI-Panel-Button-Up")
            self.bg:SetTexCoord(0, 0.625, 0, 0.6875)
            local v = hover and 1.25 or 1
            self.bg:SetVertexColor(v, v, v, 1)
            SetFont(self.t, HEAD_FONT, 10, "")
            if hover then self.t:SetTextColor(1, 1, 1) else self.t:SetTextColor(1, 0.82, 0) end
            self:SetHeight(18)
        end
    end
    b.t:SetText(label)
    b:SetScript("OnEnter", function(self)
        self:Restyle(true)
        if self.tip then
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(self.tip, 1, 1, 1)
            if self.tip2 then GameTooltip:AddLine(self.tip2, 0.8, 0.8, 0.8, true) end
            GameTooltip:Show()
        end
    end)
    b:SetScript("OnLeave", function(self)
        self:Restyle(false)
        if GameTooltip:GetOwner() == self then GameTooltip:Hide() end
    end)
    return b
end

peekBar.back = NewPillButton(peekBar, "Back")
peekBar.back:SetPoint("RIGHT", peekBar, "RIGHT", -3, 0)
peekBar.go = NewPillButton(peekBar, "Go here")
peekBar.go:SetPoint("RIGHT", peekBar.back, "LEFT", -4, 0)
peekBar.go.tip = "Move RestedXP to this step"

peekBar.go.tip2 = "RestedXP's guide and arrow continue from here."
function peekBar:Restyle()
    if IsRail() then
        self.bg:SetTexture(WHITE)
        self.bg:SetVertexColor(C.link[1], C.link[2], C.link[3], 0.10)
        SetFont(self.label, HEAD_FONT, 10, "")
    else
        Fade(self.bg, 0.08, 0.24, 0.43, 0.85, 0.30)
        SetFont(self.label, HEAD_FONT, 12, "")
    end
    self.stripe:SetVertexColor(C.link[1], C.link[2], C.link[3], 0.9)
    self.label:SetTextColor(IsRail() and C.link[1] or 0.81, IsRail() and C.link[2] or 0.91, IsRail() and C.link[3] or 1)
    self.state:SetTextColor(IsRail() and C.muted[1] or 0.61, IsRail() and C.muted[2] or 0.78, IsRail() and C.muted[3] or 0.93)
    self.back:Restyle(false)
    self.go:Restyle(false)
end

---------------------------------------------------------------------------
-- Reading RXP's data
---------------------------------------------------------------------------
local function StripCodes(t)
    return (t:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|H.-|h(.-)|h", "%1"))
end

local function ParseProgress(t)
    local cur, total = StripCodes(t):match("(%d+)%s*/%s*(%d+)")
    cur, total = tonumber(cur), tonumber(total)
    if cur and total and total >= 2 and total <= 9999 then
        return min(cur, total), total
    end
end

local function ElementText(element)
    local t = element.text
    if type(t) ~= "string" or t == "" or t == " " then
        t = element.rawtext or element.tooltipText    -- steps RXP isn't showing right now
    end
    if type(t) ~= "string" or t == "" or t == " " then return nil end
    local R = RXP()
    if R then
        local L = R.locale and R.locale.Get
        if L then
            local ok, res = pcall(L, t)
            if ok and type(res) == "string" then t = res end
        end
        if R.ReplaceNpcIds then
            local ok, res = pcall(R.ReplaceNpcIds, t)
            if ok and type(res) == "string" then t = res end
        end
        if element.tag then
            local icon = element.icon or (R.icons and R.icons[element.tag])
            if type(icon) == "string" and icon ~= "" then t = icon .. " " .. t end
        end
    end
    return t
end

local function StepVisible(step)
    return step and not step.tip and not step.hidewindow and not step.hidetip
end

local function CurrentStepNumber()
    local R = RXP()
    if R and R.GetGuideProgress then
        local ok, n = pcall(R.GetGuideProgress)
        if ok and tonumber(n) then return tonumber(n) end
    end
    return _G.RXPCData and tonumber(_G.RXPCData.currentStep) or 1
end

local function GuideQuestIds()
    local ids = {}
    local f = RXPFrame()
    local steps = f and f.activeSteps
    if not steps then return ids end
    for _, step in ipairs(steps) do
        for _, element in ipairs(step.elements or {}) do
            local q = tonumber(element.questId)
            if q then ids[q] = true end
        end
    end
    return ids
end

---------------------------------------------------------------------------
-- Hiding RXP's own window (without pausing RXP)
---------------------------------------------------------------------------
local ghosted = setmetatable({}, {__mode = "k"})  -- frame -> {mouse, wheel}
local tipFrames = {}

local function CollectTipFrames()
    for k in pairs(tipFrames) do tipFrames[k] = nil end
    local f = RXPFrame()
    local pool = f and f.CurrentStepFrame and f.CurrentStepFrame.framePool
    if not pool then return end
    for _, sf in ipairs(pool) do
        local isTip = sf.step and sf.step.tip and true or false
        if isTip then tipFrames[sf] = true end
        if sf.SetIgnoreParentAlpha then sf:SetIgnoreParentAlpha(isTip) end
    end
end

local function GhostTree(frame)
    if tipFrames[frame] then return end
    if frame.IsForbidden and frame:IsForbidden() then return end
    -- A frame holding secure buttons counts as protected; its mouse state can
    -- only be changed out of combat. Children are still walked either way.
    local locked = frame.IsProtected and frame:IsProtected() and _G.InCombatLockdown and _G.InCombatLockdown()
    if frame.EnableMouse and not locked then
        if not ghosted[frame] then
            ghosted[frame] = {
                mouse = frame.IsMouseEnabled and frame:IsMouseEnabled() or false,
                wheel = frame.IsMouseWheelEnabled and frame:IsMouseWheelEnabled() or false,
            }
        end
        if frame:IsMouseEnabled() then frame:EnableMouse(false) end
        if frame.EnableMouseWheel and frame.IsMouseWheelEnabled and frame:IsMouseWheelEnabled() then
            frame:EnableMouseWheel(false)
        end
    end
    local n = frame.GetNumChildren and frame:GetNumChildren() or 0
    if n > 0 then
        local kids = {frame:GetChildren()}
        for i = 1, #kids do GhostTree(kids[i]) end
    end
end

local function GhostRXPWindow()
    local f = RXPFrame()
    if not f then return end
    CollectTipFrames()
    if f:GetAlpha() ~= 0 then f:SetAlpha(0) end
    GhostTree(f)
end

local function UnghostRXPWindow()
    local f = RXPFrame()
    if not f then return end
    f:SetAlpha(1)
    for frame, st in pairs(ghosted) do
        if frame.EnableMouse then frame:EnableMouse(st.mouse) end
        if frame.EnableMouseWheel then frame:EnableMouseWheel(st.wheel) end
        ghosted[frame] = nil
    end
    local pool = f.CurrentStepFrame and f.CurrentStepFrame.framePool
    if pool then
        for _, sf in ipairs(pool) do
            if sf.SetIgnoreParentAlpha then sf:SetIgnoreParentAlpha(false) end
        end
    end
    -- Let RXP redraw itself so it re-sets anything that depends on its state.
    if f.CurrentStepFrame and f.CurrentStepFrame.UpdateText then pcall(f.CurrentStepFrame.UpdateText) end
    if f.BottomFrame and f.BottomFrame.UpdateFrame then pcall(f.BottomFrame.UpdateFrame) end
end

---------------------------------------------------------------------------
-- Taking over the old quest tracker
---------------------------------------------------------------------------
local TRACKER_FRAMES = {
    "ObjectiveTrackerFrame", -- Blizzard "All Objectives" tracker (WoW Forever / retail-style)
    "QuestWatchFrame",       -- Blizzard (Classic Era)
    "WatchFrame",            -- Blizzard (Wrath-era clients)
    "Questie_BaseFrame",     -- Questie tracker
    "!KalielsTrackerFrame",  -- Kaliel's Tracker
}
local hookedTrackers = {}
local needsHideAfterCombat = false

local function ShouldHideTrackers()
    return db and db.enabled and db.hideOtherTrackers
end

local function InCombat()
    return _G.InCombatLockdown and _G.InCombatLockdown()
end

-- Blizzard's tracker holds secure quest-item buttons, so hiding it in combat
-- is blocked. In combat we only make it invisible and finish the job after.
local function HideTracker(fr)
    local protected = fr.IsProtected and fr:IsProtected()
    if protected and InCombat() then
        fr:SetAlpha(0)
        needsHideAfterCombat = true
    else
        fr:Hide()
    end
end

local function HideOtherTrackers()
    for _, name in ipairs(TRACKER_FRAMES) do
        local fr = _G[name]
        if type(fr) == "table" and fr.Hide and fr.HookScript then
            if not hookedTrackers[fr] then
                hookedTrackers[fr] = true
                fr:HookScript("OnShow", function(self)
                    if ShouldHideTrackers() then HideTracker(self) end
                end)
            end
            if ShouldHideTrackers() and fr:IsShown() then HideTracker(fr) end
        end
    end
end

local function RestoreOtherTrackers()
    if InCombat() then needsHideAfterCombat = true return end
    for fr in pairs(hookedTrackers) do
        fr:SetAlpha(1)
        fr:Show()
    end
    if _G.QuestWatch_Update then pcall(_G.QuestWatch_Update) end
    if _G.ObjectiveTracker_Update then pcall(_G.ObjectiveTracker_Update) end
end

---------------------------------------------------------------------------
-- Quest log helpers (Classic API, with a modern fallback)
---------------------------------------------------------------------------
local function QuestInfo(i)
    if _G.GetQuestLogTitle then
        local title, level, group, isHeader, isCollapsed, isComplete, _, questID = _G.GetQuestLogTitle(i)
        return title, level, group, isHeader, isCollapsed, isComplete, questID
    end
    local CQ = _G.C_QuestLog
    local info = CQ and CQ.GetInfo and CQ.GetInfo(i)
    if info then
        local complete = CQ.IsComplete and CQ.IsComplete(info.questID) and 1 or nil
        return info.title, info.level, info.suggestedGroup, info.isHeader, info.isCollapsed, complete, info.questID
    end
end

local function NumQuestEntries()
    if _G.GetNumQuestLogEntries then
        local entries, quests = _G.GetNumQuestLogEntries()
        return entries or 0, quests or 0
    end
    local CQ = _G.C_QuestLog
    local n = CQ and CQ.GetNumQuestLogEntries and CQ.GetNumQuestLogEntries() or 0
    return n, n
end

local function DifficultyColor(level)
    if _G.GetQuestDifficultyColor and level then
        local c = _G.GetQuestDifficultyColor(level)
        if c then return c.r, c.g, c.b end
    end
    return C.text[1], C.text[2], C.text[3]
end

-- Blizzard's quest tracking (the "watch" list you shift-click in the quest log).
local function IsWatched(index, questID)
    if _G.IsQuestWatched then return _G.IsQuestWatched(index) and true or false end
    local CQ = _G.C_QuestLog
    if CQ and questID then
        if CQ.GetQuestWatchType then return CQ.GetQuestWatchType(questID) ~= nil end
        if CQ.IsQuestWatched then return CQ.IsQuestWatched(questID) and true or false end
    end
    return true -- no tracking API on this client: treat every quest as tracked
end

local function ToggleWatch(index, questID)
    local CQ = _G.C_QuestLog
    if _G.IsQuestWatched and _G.AddQuestWatch and _G.RemoveQuestWatch then
        if _G.IsQuestWatched(index) then
            _G.RemoveQuestWatch(index)
        else
            local maxW = _G.MAX_WATCHABLE_QUESTS or 5
            if _G.GetNumQuestWatches and _G.GetNumQuestWatches() >= maxW then
                local msg = _G.QUEST_WATCH_TOO_MANY and strformat(_G.QUEST_WATCH_TOO_MANY, maxW)
                            or strformat("You can only track %d quests at a time.", maxW)
                if _G.UIErrorsFrame then _G.UIErrorsFrame:AddMessage(msg, 1, 0.1, 0.1) end
                return
            end
            _G.AddQuestWatch(index)
        end
    elseif CQ and questID and CQ.AddQuestWatch and CQ.RemoveQuestWatch then
        if IsWatched(index, questID) then CQ.RemoveQuestWatch(questID) else CQ.AddQuestWatch(questID) end
    end
end

local function OpenQuestLog(index)
    local qf = _G.QuestLogFrame
    if not qf then
        if _G.ToggleQuestLog then _G.ToggleQuestLog() end
        return
    end
    if not qf:IsShown() then _G.ShowUIPanel(qf) end
    if _G.QuestLog_SetSelection then _G.QuestLog_SetSelection(index) end
    if _G.QuestLog_Update then _G.QuestLog_Update() end
end

---------------------------------------------------------------------------
-- Rendering
---------------------------------------------------------------------------
local y, innerW

local renderGen = 0

-- Re-anchors only when the spot or size changed, so a row under the cursor
-- isn't moved mid-click for nothing.
local function PlaceFrame(frame, x, h)
    local w = innerW - (x - PAD)
    if frame.pX ~= x or frame.pY ~= y or frame.pW ~= w or frame.pH ~= h then
        frame.pX, frame.pY, frame.pW, frame.pH = x, y, w, h
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", content, "TOPLEFT", x, -y)
        frame:SetSize(w, h)
    end
    frame.placedGen = renderGen
    Vis(frame, true)
    y = y + h
end

-- Adds a text row. opts: x, font, size, color, check (nil|true|false),
-- progress {cur,total}, stripe color, gap below.
local function AddTextRow(text, opts)
    local r = AcquireRow()
    local x = opts.x or PAD
    local textX = 0
    if opts.check ~= nil then
        r.check:SetState(opts.check)
        r.wCheck = true
        textX = BOX + 6
    end
    SetFont(r.text, opts.font or BODY_FONT, opts.size or 12, opts.flags)
    if r.textX ~= textX then
        r.textX = textX
        r.text:ClearAllPoints()
        r.text:SetPoint("TOPLEFT", r, "TOPLEFT", textX, 0)
    end
    local rightW = 0
    if opts.rightText then
        SetFont(r.right, BODY_FONT, 11, "")
        r.right:SetText(opts.rightText)
        r.right:SetTextColor(unpack(C.muted))
        r.wRight = true
        rightW = r.right:GetStringWidth() + 6
    end
    local w = innerW - (x - PAD) - textX - rightW
    if opts.rightText == nil and r.right:GetText() ~= "" then r.right:SetText("") end
    r.text:SetWidth(max(20, w))
    r.text:SetText(text)
    local col = opts.color or C.text
    r.text:SetTextColor(col[1], col[2], col[3], col[4] or 1)
    local h = max(opts.check ~= nil and (BOX + 3) or 0, floor(r.text:GetStringHeight() + 0.5) + 2)

    if opts.progress then
        local cur, total = opts.progress[1], opts.progress[2]
        local barW = max(10, w)
        local frac = total > 0 and min(1, cur / total) or 0
        local barH = IsRail() and 3 or 11          -- Blizzard Native: a real status bar with a % in it
        r.barBG:ClearAllPoints()
        r.barBG:SetPoint("TOPLEFT", r, "TOPLEFT", textX, -(h + (IsRail() and 1 or 3)))
        r.barBG:SetSize(barW, barH)
        r.barBG:SetVertexColor(unpack(C.barBG))
        r.wBarBG = true
        if not IsRail() then
            r.barEdge:ClearAllPoints()
            r.barEdge:SetPoint("TOPLEFT", r.barBG, "TOPLEFT", -1, 1)
            r.barEdge:SetPoint("BOTTOMRIGHT", r.barBG, "BOTTOMRIGHT", 1, -1)
            r.barEdge:SetVertexColor(0.30, 0.30, 0.30, 0.9)
            r.wEdge = true
            r.pct:SetText(strformat("%d%%", floor(frac * 100 + 0.5)))
            r.wPct = true
        end
        if frac > 0 then
            r.bar:ClearAllPoints()
            r.bar:SetPoint("TOPLEFT", r.barBG, "TOPLEFT", 0, 0)
            r.bar:SetSize(max(1, barW * frac), barH)
            local bc = frac >= 1 and C.done or C.barFill
            r.bar:SetVertexColor(bc[1], bc[2], bc[3], 0.9)
            r.wBar = true
        end
        h = h + (IsRail() and 6 or 16)
    end

    if opts.node then
        -- a diamond on the route line, RAIL px left of the row
        local n = opts.node
        local size = n.size or 8
        r.node:ClearAllPoints()
        r.node:SetPoint("CENTER", r, "TOPLEFT", -RAIL + 7, -(n.dy or 6))
        r.node:SetSize(size, size)
        r.node:SetVertexColor(n.color[1], n.color[2], n.color[3], 1)
        r.wNode = true
        r.nodeBack:ClearAllPoints()
        r.nodeBack:SetPoint("CENTER", r.node, "CENTER", 0, 0)
        local ring = n.ring
        r.nodeBack:SetSize(size + (ring and 6 or 4), size + (ring and 6 or 4))
        if ring then
            r.nodeBack:SetVertexColor(ring[1], ring[2], ring[3], 0.85)
        else
            r.nodeBack:SetVertexColor(C.bg[1], C.bg[2], C.bg[3], 1)
        end
        r.wNodeBack = true
    end

    if opts.stripe then
        local s = opts.stripe
        r.stripe:SetVertexColor(s[1], s[2], s[3], s[4] or 1)
        r.wStripe = true
    end

    PlaceFrame(r, x, h)
    y = y + (opts.gap or 2)
    return r
end

local function ElementTooltip(row)
    local element = row.element
    if not element then return end
    local R = RXP()
    if R and R.ActiveStepElementOnEnter then
        -- RXP's own tooltip function reads frame.element
        pcall(R.ActiveStepElementOnEnter, row)
    end
end

-- Our own copy of RXP's "copy this link" box, used only if RXP's is missing.
local function ShowLinkBox(url)
    local dialogs = _G.StaticPopupDialogs
    if not (dialogs and _G.StaticPopup_Show) then
        Print("link: %s", url)
        return
    end
    if not dialogs.RXPQUESTPANEL_LINK then
        dialogs.RXPQUESTPANEL_LINK = {
            text = "Press Ctrl+C to copy the link",
            hasEditBox = 1,
            button1 = _G.OKAY or "OK",
            OnShow = function(self, data)
                local box = self.editBox or self.EditBox or (self.GetName and _G[self:GetName() .. "EditBox"])
                local text = data or self.data
                if box and text then
                    box:SetWidth(275)
                    box:SetText(text)
                    box:HighlightText()
                    box:SetFocus()
                end
            end,
            EditBoxOnEscapePressed = function(self) self:GetParent():Hide() end,
            timeout = 0,
            whileDead = 1,
            hideOnEscape = 1,
        }
    end
    _G.StaticPopup_Show("RXPQUESTPANEL_LINK", nil, nil, url)
end

-- Clicking a guide line that RXP makes clickable (a video/web link, or a
-- "click here for the next guide" line). RXP puts the click handler on its
-- own (hidden) line, so we run that same handler; links fall back to a
-- copy box of our own.
local function ElementClick(row, button)
    local element = row.element
    if not element or (button and button ~= "LeftButton") then return end
    local ef = element.frame
    local handler = ef and ef.element == element and ef.GetScript and ef:GetScript("OnMouseDown")
    if handler then
        local ok = pcall(handler, ef, "LeftButton")
        panel.dirty = true
        if ok then return end
    end
    if type(element.url) == "string" and element.url ~= "" then
        local R = RXP()
        if R and _G.StaticPopupDialogs and _G.StaticPopupDialogs.RXP_Link and _G.StaticPopup_Show then
            R.url = element.url
            pcall(_G.StaticPopup_Show, "RXP_Link")
            R.url = nil
        else
            ShowLinkBox(element.url)
        end
    elseif element.next then
        local R = RXP()
        if R and R.functions and type(R.functions.next) == "function" then
            pcall(R.functions.next, {step = element.step, element = element})
            panel.dirty = true
        end
    end
end

local function ToggleElement(row)
    local element = row.element
    if not element then return end
    local rxpButton = element.frame and element.frame.button
    if rxpButton and rxpButton.Click then
        rxpButton:Click()             -- same as clicking RXP's own checkbox
    else
        element.skip = not element.skip
        local R = RXP()
        if R then
            R.updateSteps = true
            if R.UpdateMap then pcall(R.UpdateMap) end
        end
    end
    panel.dirty = true
end

local function RenderHeader(header, collapsed, rightText)
    if IsRail() then
        header.arrow:SetText((rightText and (rightText .. "   ") or "") .. (collapsed and "+" or "-"))
        PlaceFrame(header, PAD, 14)
        y = y + 4
    else
        -- Blizzard Native: a fading bar the width of the panel, gold title, +/- button
        header.plus:SetTexture(collapsed and "Interface\\Buttons\\UI-PlusButton-Up"
                                             or "Interface\\Buttons\\UI-MinusButton-Up")
        header.arrow:SetText(rightText or "")
        PlaceFrame(header, 2, 20)
        y = y + 5
    end
end

-- Restyle the parts that persist between redraws for the current look.
local function ApplyTheme()
    style = (db and PALETTES[db.style or ""]) and db.style or "blizzard"
    for k, v in pairs(PALETTES[style]) do C[k] = v end
    local rail = IsRail()
    for _, h in ipairs({guideHeader, questHeader}) do
        Vis(h.bar, not rail)
        Vis(h.top, not rail)
        Vis(h.plus, not rail)
        Vis(h.line, rail)
        if rail then
            SetFont(h.label, HEAD_FONT, 10, "")
            h.label:SetTextColor(unpack(C.muted))
            h.label:ClearAllPoints(); h.label:SetPoint("LEFT", h, "LEFT", 0, 0)
            SetFont(h.arrow, HEAD_FONT, 10, "")
            h.arrow:ClearAllPoints(); h.arrow:SetPoint("RIGHT", h, "RIGHT", 0, 0)
        else
            Fade(h.bar, 0.16, 0.09, 0.02, 0.92, 0)
            h.top:SetTexture(WHITE)
            h.top:SetVertexColor(1, 0.82, 0, 0.35)
            SetFont(h.label, HEAD_FONT, 13, "")
            h.label:SetTextColor(unpack(C.accent))
            h.label:ClearAllPoints(); h.label:SetPoint("LEFT", h, "LEFT", 8, 0)
            SetFont(h.arrow, BODY_FONT, 11, "")
            h.arrow:ClearAllPoints(); h.arrow:SetPoint("RIGHT", h.plus, "LEFT", -6, 0)
        end
        h.arrow:SetTextColor(unpack(C.muted))
    end
    SetFont(guideTitle.name, HEAD_FONT, rail and 14 or 15, "")
    guideTitle.name:SetTextColor(rail and C.text[1] or 1, rail and C.text[2] or 1, rail and C.text[3] or 1)
    guideTitle.group:SetTextColor(unpack(C.muted))
    for _, b in ipairs({prevBtn, nextBtn}) do
        Vis(b.icon, not rail)
        Vis(b.bg, rail)
        Vis(b.t, rail)
        b:SetSize(rail and 16 or 20, rail and 16 or 20)
        if not rail then b.icon:SetTexture(b.page .. "-Up") end
    end
    prevBtn:ClearAllPoints()
    prevBtn:SetPoint("RIGHT", nextBtn, "LEFT", rail and -2 or 2, 0)
    guideTitle.progBG:SetVertexColor(unpack(C.barBG))
    guideTitle.prog:SetVertexColor(C.accent[1], C.accent[2], C.accent[3], 1)
    railLine:SetVertexColor(1, 1, 1, 0.14)
    if peekBar then peekBar:Restyle() end
    if ApplyLook then ApplyLook() end
end

---------------------------------------------------------------------------
-- Peek: the < > arrows only change which step the panel shows. RestedXP
-- stays on your real step, so a step you're standing in can't auto-complete
-- and bounce you forward again.
---------------------------------------------------------------------------
local peek = {step = nil, guide = nil}

local function StepHasText(step)
    if not step or step.tip or step.hidewindow then return false end
    for _, element in ipairs(step.elements or {}) do
        if ElementText(element) then return true end
    end
    return false
end

local function StopPeek()
    peek.step, peek.guide = nil, nil
    panel.dirty = true
end

-- Move the view one step back (dir -1) or forward (dir 1), skipping steps
-- with nothing to show. Landing on your current step ends the peek.
local function PeekMove(dir)
    local R = RXP()
    local guide = R and R.currentGuide
    if not (guide and guide.steps) then return end
    local cur = CurrentStepNumber()
    local n = (peek.guide == guide and peek.step) or cur
    repeat
        n = n + dir
    until n < 1 or n > #guide.steps or n == cur or StepHasText(guide.steps[n])
    if n < 1 or n > #guide.steps then return end
    if n == cur then
        StopPeek()
    else
        peek.step, peek.guide = n, guide
        panel.dirty = true
    end
end

local function StepX() return IsRail() and (PAD + RAIL) or (PAD + 2) end

local function RenderElements(step, peeking)
    local ex = StepX()
    for _, element in ipairs(step.elements or {}) do
        local text = ElementText(element)
        if text then
            local isDone = (element.completed or element.skip) and true or false
            if peeking and step.index and step.index < CurrentStepNumber() then isDone = true end
            local r
            local clickable = element.textOnly and (element.url or element.next) and true or false
            if element.textOnly then
                r = AddTextRow(text, {x = ex, size = 12,
                                      color = clickable and C.link or C.text, gap = 3})
            else
                local cur2, tot2 = ParseProgress(text)
                r = AddTextRow(text, {
                    x = ex, size = 12,
                    color = isDone and C.muted or C.text,
                    check = isDone,
                    progress = cur2 and {cur2, tot2} or nil,
                    rightText = (cur2 and IsRail()) and strformat("%d%%", floor(min(1, cur2 / tot2) * 100 + 0.5)) or nil,
                    gap = 3,
                })
                if not peeking then r.onCheck = ToggleElement end
            end
            r.element = element
            if type(element.tooltip) == "string" then
                r.wMouse = true
                r.onEnter = ElementTooltip
            end
            if clickable then
                r.wMouse = true
                r.onClick = ElementClick
            end
        end
    end
end

-- One step's title line. kind: "sticky", "current", "done", "ahead", "viewing".
local function StepHeader(title, kind)
    if not IsRail() then
        -- Blizzard Native: gold title in the game's font, like a tracked quest
        return AddTextRow(title, {font = HEAD_FONT, size = 13, color = C.head, gap = 2})
    end
    local col = (kind == "sticky" and C.sticky) or (kind == "current" and C.accent)
                or (kind == "done" and C.done) or (kind == "viewing" and C.link) or C.muted
    local node = {color = col, size = 8, dy = 6}
    if kind == "current" then node.size, node.ring = 9, {C.accent[1] * 0.35, C.accent[2] * 0.35, C.accent[3] * 0.35}
    elseif kind == "viewing" then node.ring = C.link end
    return AddTextRow(title:upper(), {x = PAD + RAIL, font = HEAD_FONT, size = 10, color = col, node = node, gap = 2})
end

-- Waypoint Rail: a one-line preview of the step before or after yours.
-- Clicking it looks at that step (RestedXP stays put).
local function GhostRow(step, dir, done)
    local text
    for _, element in ipairs(step.elements or {}) do
        text = ElementText(element)
        if text then break end
    end
    if not text then return end
    text = StripCodes(text)
    if #text > 42 then text = text:sub(1, 40) .. "..." end
    local r = AddTextRow(strformat("%d  %s", step.index or 0, text), {
        x = PAD + RAIL, size = 11, color = C.muted, gap = 5,
        node = {color = done and C.done or {0.23, 0.27, 0.34}, size = 6, dy = 7},
    })
    r.wMouse = true
    r.onClick = function() PeekMove(dir) end
    r.onEnter = function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:SetText(dir < 0 and "Look at the previous step" or "Look at the next step", 1, 1, 1)
        GameTooltip:AddLine("RestedXP stays on your step.", 0.8, 0.8, 0.8)
        GameTooltip:Show()
    end
end

local railTop
local function RailMark() if IsRail() and not railTop then railTop = y end end
local function RailEnd()
    if not (IsRail() and railTop) then return end
    local h = y - railTop - 6
    if h > 8 then
        railLine:ClearAllPoints()
        railLine:SetPoint("TOPLEFT", content, "TOPLEFT", PAD + 6, -(railTop + 4))
        railLine:SetHeight(h)
        railLine.placedGen = renderGen
    end
end

local function RenderPeek(guide, cur)
    local step = guide.steps[peek.step]
    local title = step.title
    if not title or title == "" then
        title = step.sticky and "Ongoing" or strformat("Step %d", step.index or peek.step)
    end
    peekBar.label:SetText(strformat(IsRail() and "STEP %d" or "Step %d", peek.step))
    peekBar.state:SetText(peek.step < cur and "done" or "coming up")
    peekBar.back.tip = strformat("Back to your step (%d)", cur)
    peekBar.back.tip2 = "Right-click either arrow does the same."
    -- Size the buttons here: text width can read 0 before fonts finish loading.
    peekBar.back:SetWidth(max(38, floor(peekBar.back.t:GetStringWidth() + 14)))
    peekBar.go:SetWidth(max(52, floor(peekBar.go.t:GetStringWidth() + 14)))
    PlaceFrame(peekBar, PAD, 20)
    y = y + 7
    RailMark()
    StepHeader(title, "viewing")
    RenderElements(step, true)
    RailEnd()
    y = y + 5
end

-- Slot for RestedXP's timer bars (the flight timer). RXP draws them where its
-- own window would be; we move them into the panel, under the guide name.
local TIMER_H = 16
local timerSlot = CreateFrame("Frame", nil, content)

local function ShownTimerBars()
    local f = RXPFrame()
    local bc = f and f.BarContainer
    if type(bc) ~= "table" or type(bc.bars) ~= "table" then return nil, nil end
    local list = {}
    for _, bar in pairs(bc.bars) do
        if type(bar) == "table" and bar.IsShown and bar:IsShown() then list[#list + 1] = bar end
    end
    table.sort(list, function(a, b) return (a.exp or 0) > (b.exp or 0) end)
    return bc, list
end

-- Put the bars into the slot. Safe to call any time; does nothing when the
-- slot isn't part of the current layout.
local function AnchorTimers()
    if not (db and db.enabled) or timerSlot.placedGen ~= renderGen or not timerSlot:IsShown() then return end
    local bc, bars = ShownTimerBars()
    if not bc then return end
    bc:ClearAllPoints()
    bc:SetPoint("TOPLEFT", timerSlot, "TOPLEFT", 0, 0)
    bc:SetPoint("BOTTOMRIGHT", timerSlot, "BOTTOMRIGHT", 0, 0)
    local strata, level = panel:GetFrameStrata(), (panel:GetFrameLevel() or 1) + 20
    for i, bar in ipairs(bars) do
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", timerSlot, "TOPLEFT", 0, -(i - 1) * TIMER_H)
        bar:SetPoint("TOPRIGHT", timerSlot, "TOPRIGHT", 0, -(i - 1) * TIMER_H)
        bar:SetHeight(TIMER_H - 2)
        if bar.SetFrameStrata then bar:SetFrameStrata(strata) end
        if bar.SetFrameLevel then bar:SetFrameLevel(level) end
        -- match the look: a gold Blizzard status bar, or the rail's blue
        if IsRail() then
            if bar.SetTexture then pcall(bar.SetTexture, bar, WHITE) end
            if bar.SetColor then pcall(bar.SetColor, bar, C.link[1], C.link[2], C.link[3], 0.85) end
        else
            if bar.SetTexture then pcall(bar.SetTexture, bar, "Interface\\TargetingFrame\\UI-StatusBar") end
            if bar.SetColor then pcall(bar.SetColor, bar, 1, 0.70, 0.10, 1) end
        end
    end
end

local function RenderTimers()
    local _, bars = ShownTimerBars()
    if not bars or #bars == 0 then return end
    PlaceFrame(timerSlot, PAD, #bars * TIMER_H)
    y = y + 6
end

peekBar.back:SetScript("OnClick", function() StopPeek() end)
peekBar.go:SetScript("OnClick", function()
    local R = RXP()
    local n = peek.step
    StopPeek()
    if R and R.SetStep and n then pcall(R.SetStep, n) end
end)

local function RenderGuide()
    local f = RXPFrame()
    local R = RXP()
    local guide = R and R.currentGuide
    RenderHeader(guideHeader, db.collapseGuide)
    if db.collapseGuide then
        RenderTimers()
        return
    end

    if not f or not guide or guide.empty then
        AddTextRow("No guide loaded. Right-click here to pick one.", {color = C.muted, size = 12, gap = 6})
        local r = rowPool[rowsUsed]
        r.wMouse = true
        r.onClick = function() if f and f.DropDownMenu then f.DropDownMenu() end end
        return
    end
    if not f:IsShown() then
        AddTextRow("RestedXP's guide is switched off in RXP.", {color = C.muted, size = 12, gap = 6})
        return
    end

    -- Title block
    local name = guide.displayname or guide.name or "Guide"
    if R.GetGuideName then
        local ok, n = pcall(R.GetGuideName, guide)
        if ok and n then name = n end
    end
    guideTitle.name:SetWidth(innerW - 70)
    guideTitle.name:SetText(name)
    guideTitle.group:SetWidth(innerW - 4)
    guideTitle.group:SetText(guide.group or "")
    local cur = CurrentStepNumber()
    local total = guide.steps and #guide.steps or 0
    if peek.step and (peek.guide ~= guide or peek.step == cur or peek.step < 1 or peek.step > total) then
        peek.step, peek.guide = nil, nil       -- guide changed, or you caught up
    end
    local shownN = peek.step or cur
    guideTitle.counter:SetText(total > 0 and strformat("%d/%d", shownN, total) or "")
    local cc = peek.step and C.link or C.muted
    guideTitle.counter:SetTextColor(cc[1], cc[2], cc[3])
    local th = 17 + ((guide.group and guide.group ~= "") and 13 or 0)
    if IsRail() and total > 0 then
        th = th + 8
        guideTitle.prog:SetWidth(max(1, (innerW) * min(1, cur / total)))
    end
    Vis(guideTitle.progBG, IsRail() and total > 0)
    Vis(guideTitle.prog, IsRail() and total > 0)
    PlaceFrame(guideTitle, PAD, th)
    y = y + 8
    RenderTimers()

    if peek.step then
        RenderPeek(guide, cur)
        return
    end

    -- Active steps (ongoing steps first, then yours). Waypoint Rail also
    -- shows the step before and after yours, on the same route line.
    local shown, ghostedPrev, lastNonSticky = 0, false, nil
    for _, step in ipairs(f.activeSteps or {}) do
        if StepVisible(step) then
            shown = shown + 1
            local title = step.title
            if not title or title == "" then
                title = step.sticky and "Ongoing" or strformat("Step %d", step.index or 0)
            end
            RailMark()
            if IsRail() and not step.sticky and not ghostedPrev then
                ghostedPrev = true
                for i = (step.index or cur) - 1, 1, -1 do
                    if StepHasText(guide.steps[i]) then GhostRow(guide.steps[i], -1, true); break end
                end
            end
            StepHeader(title, step.sticky and "sticky" or "current")
            RenderElements(step, false)
            if not step.sticky then lastNonSticky = step end
            y = y + 5
        end
    end
    if IsRail() and lastNonSticky then
        for i = (lastNonSticky.index or cur) + 1, total do
            if StepHasText(guide.steps[i]) then GhostRow(guide.steps[i], 1, false); break end
        end
    end
    RailEnd()
    if shown == 0 then
        AddTextRow("Waiting for the next step...", {color = C.muted, size = 12, gap = 6})
    end
end

local function RenderQuests()
    local entries, numQuests = NumQuestEntries()
    local maxQuests = _G.MAX_QUESTLOG_QUESTS or 20

    local guideIds = GuideQuestIds()
    local linked, other = {}, {}
    local nTracked, hidden = 0, 0
    for i = 1, entries do
        local title, level, group, isHeader, _, isComplete, questID = QuestInfo(i)
        if title and not isHeader then
            local watched = IsWatched(i, questID)
            if watched then nTracked = nTracked + 1 end
            local q = {index = i, title = title, level = level, group = group,
                       complete = isComplete, id = questID, watched = watched}
            if not watched and not db.allQuests then
                hidden = hidden + 1
            elseif questID and guideIds[questID] then
                linked[#linked + 1] = q
            else
                other[#other + 1] = q
            end
        end
    end

    local count = strformat("%d/%d", numQuests, maxQuests)
    if not db.allQuests then count = strformat("%d tracked, %s", nTracked, count) end
    RenderHeader(questHeader, db.collapseQuests, count)
    if db.collapseQuests then return end

    local function RenderQuest(q, isLinked)
        local r1, g1, b1 = DifficultyColor(q.level)
        if not q.watched then r1, g1, b1 = r1 * 0.6, g1 * 0.6, b1 * 0.6 end
        local lvl = q.level and q.level > 0 and
                        strformat("[%d%s] ", q.level, (tonumber(q.group) or 0) > 0 and "+" or "") or ""
        local r = AddTextRow(lvl .. q.title, {
            font = HEAD_FONT, size = IsRail() and 11 or 13, color = {r1, g1, b1},
            stripe = isLinked and C.guideTag or nil, gap = 1,
        })
        r.wMouse = true
        r.questIndex = q.index
        r.questID = q.id
        r.onClick = function(self)
            if _G.IsShiftKeyDown and _G.IsShiftKeyDown() then
                ToggleWatch(self.questIndex, self.questID)
                panel.dirty = true
            else
                OpenQuestLog(self.questIndex)
            end
        end
        r.onEnter = function(self)
            GameTooltip:SetOwner(self, "ANCHOR_LEFT")
            GameTooltip:SetText(q.title, 1, 1, 1)
            if isLinked then GameTooltip:AddLine("Used by your current guide step", unpack(C.guideTag)) end
            GameTooltip:AddLine("Click: open in quest log", 0.8, 0.8, 0.8)
            GameTooltip:AddLine(q.watched and "Shift-click: stop tracking" or "Shift-click: track", 0.8, 0.8, 0.8)
            GameTooltip:Show()
        end

        if q.complete == 1 then
            AddTextRow("Ready for turn-in", {x = PAD + INDENT, size = 12, color = C.done, gap = 4})
            return
        elseif q.complete == -1 then
            AddTextRow("Failed", {x = PAD + INDENT, size = 12, color = C.fail, gap = 4})
            return
        end
        local nObj = _G.GetNumQuestLeaderBoards and _G.GetNumQuestLeaderBoards(q.index) or 0
        for j = 1, nObj do
            local text, _, finished = _G.GetQuestLogLeaderBoard(j, q.index)
            if text and text ~= "" then
                local cur2, tot2 = ParseProgress(text)
                AddTextRow(IsRail() and text or ("- " .. text), {
                    x = PAD + INDENT, size = 12,
                    color = finished and C.muted or C.text,
                    progress = (cur2 and not finished) and {cur2, tot2} or nil,
                    gap = 1,
                })
            end
        end
        y = y + 4
    end

    for _, q in ipairs(linked) do RenderQuest(q, true) end
    for _, q in ipairs(other) do RenderQuest(q, false) end
    if numQuests == 0 then
        AddTextRow("Quest log is empty.", {color = C.muted, size = 12, gap = 4})
    elseif hidden > 0 then
        local r = AddTextRow(strformat(nTracked == 0 and "No quests tracked (%d in your log). Click to show them all."
                                       or "%d more not tracked. Click to show them all.", hidden),
                             {color = C.muted, size = 11, gap = 4})
        r.wMouse = true
        r.onClick = function() db.allQuests = true; panel.dirty = true end
    elseif db.allQuests and nTracked < numQuests then
        local r = AddTextRow("Showing all quests. Click to show only tracked ones.",
                             {color = C.muted, size = 11, gap = 4})
        r.wMouse = true
        r.onClick = function() db.allQuests = false; panel.dirty = true end
    end
end

-- Shown inside the panel if drawing ever fails, so the panel is never blank.
local errText = panel:CreateFontString(nil, "OVERLAY")
SetFont(errText, BODY_FONT, 12, "")
errText:SetPoint("TOPLEFT", panel, "TOPLEFT", PAD, -PAD)
errText:SetPoint("RIGHT", panel, "RIGHT", -PAD, 0)
errText:SetJustifyH("LEFT")
errText:SetJustifyV("TOP")
errText:SetTextColor(C.fail[1], C.fail[2], C.fail[3])
errText:Hide()

local lastError, errorPrinted

local function RenderInner()
    panel.dirty = false
    if not db or not db.enabled then return end
    if db.point and db.point[1] ~= "TOPRIGHT" then PinTopRight() end
    innerW = db.width - 2 * PAD - 2
    content:SetWidth(db.width - 2)
    rowsUsed = 0
    y = PAD
    renderGen = renderGen + 1
    railTop = nil

    RenderGuide()
    if db.showQuests then
        y = y + 4
        RenderQuests()
    end
    FinishRows()
    for _, fr in ipairs({guideHeader, guideTitle, peekBar, timerSlot, questHeader, railLine}) do
        Vis(fr, fr.placedGen == renderGen)
    end
    AnchorTimers()

    local contentH = y + PAD - 4
    content:SetHeight(contentH)
    -- The panel only draws as tall as its content, growing down from the top.
    -- A size set in /rxpq setup is the most it can take (then it scrolls);
    -- the full box only shows while you're in setup.
    local maxH = db.boxHeight or db.maxHeight
    local h = (panel.setup and db.boxHeight) or min(contentH, maxH)
    local room = SpaceBelowTop()
    if room and room > 60 then h = min(h, room) end
    if panel.sizing then
        h = panel:GetHeight()            -- the user is dragging the corner right now
    else
        h = max(40, h)
        panel:SetHeight(h)
    end
    local range = max(0, contentH - h)
    if (scroll:GetVerticalScroll() or 0) > range then scroll:SetVerticalScroll(range) end
    UpdateScrollThumb()
end

local function Render()
    local ok, err = xpcall(RenderInner, function(e)
        return tostring(e) .. (_G.debugstack and ("\n" .. _G.debugstack(2, 3, 0)) or "")
    end)
    panel.dirty = false
    if ok then
        if errText:IsShown() then errText:Hide(); scroll:Show() end
        lastError = nil
        return
    end
    lastError = err
    -- Fall back to a visible box that says what went wrong.
    scroll:Hide()
    errText:SetText("RXP Quest Panel couldn't draw the guide.\nType /rxpq debug and send the output.")
    errText:Show()
    panel:SetSize(db and db.width or 270, 60)
    if not errorPrinted then
        errorPrinted = true
        local first = tostring(err):match("^[^\n]*") or tostring(err)
        Print("drawing error: %s", first)
    end
end

---------------------------------------------------------------------------
-- Header interactions
---------------------------------------------------------------------------
local function JustDragged()
    return panel.lastDrag and (_G.GetTime() - panel.lastDrag) < 0.3
end

local function HeaderClick(self, button)
    if JustDragged() then return end
    if button == "LeftButton" then
        self.toggle()
        panel.dirty = true
    end
end

guideHeader.toggle = function() db.collapseGuide = not db.collapseGuide end
questHeader.toggle = function() db.collapseQuests = not db.collapseQuests end
guideHeader:SetScript("OnClick", HeaderClick)
questHeader:SetScript("OnClick", HeaderClick)

guideTitle:SetScript("OnClick", function(_, button)
    if JustDragged() then return end
    if button == "RightButton" then
        local f = RXPFrame()
        if f and f.DropDownMenu then f.DropDownMenu() end
    end
end)
nextBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then StopPeek() else PeekMove(1) end
end)
prevBtn:SetScript("OnClick", function(_, button)
    if button == "RightButton" then StopPeek() else PeekMove(-1) end
end)

---------------------------------------------------------------------------
-- Setup mode: size and place the box once (/rxpq setup)
---------------------------------------------------------------------------
local setupOverlay = CreateFrame("Button", nil, panel)
setupOverlay:SetAllPoints(panel)
setupOverlay:SetFrameLevel(50)          -- above every row (panel is level 10)
setupOverlay:EnableMouse(true)
setupOverlay:RegisterForDrag("LeftButton")
setupOverlay:Hide()
do
    local tint = setupOverlay:CreateTexture(nil, "BACKGROUND")
    tint:SetAllPoints(setupOverlay)
    tint:SetTexture(WHITE)
    tint:SetVertexColor(1, 0.82, 0, 0.06)
    local edges = {
        {"TOPLEFT", "TOPRIGHT", nil, 2}, {"BOTTOMLEFT", "BOTTOMRIGHT", nil, 2},
        {"TOPLEFT", "BOTTOMLEFT", 2, nil}, {"TOPRIGHT", "BOTTOMRIGHT", 2, nil},
    }
    for _, e in ipairs(edges) do
        local t = setupOverlay:CreateTexture(nil, "BORDER")
        t:SetTexture(WHITE)
        t:SetVertexColor(1, 0.82, 0, 0.9)
        t:SetPoint(e[1], setupOverlay, e[1], 0, 0)
        t:SetPoint(e[2], setupOverlay, e[2], 0, 0)
        if e[3] then t:SetWidth(e[3]) else t:SetHeight(e[4]) end
    end
end
local setupLabel = setupOverlay:CreateFontString(nil, "OVERLAY")
SetFont(setupLabel, HEAD_FONT, 12, "OUTLINE")
setupLabel:SetPoint("TOP", setupOverlay, "TOP", 0, -6)
setupLabel:SetWidth(180)
setupLabel:SetJustifyH("CENTER")
setupLabel:SetTextColor(1, 0.82, 0)
setupLabel:SetText("Drag to move")
local setupSize = setupOverlay:CreateFontString(nil, "OVERLAY")
SetFont(setupSize, HEAD_FONT, 11, "OUTLINE")
setupSize:SetPoint("BOTTOM", setupOverlay, "BOTTOM", 0, 8)
setupSize:SetTextColor(1, 1, 1)
setupSize:SetText("")

local function ShowSetupSize()
    setupSize:SetText(strformat("%d x %d max", floor(panel:GetWidth() + 0.5), floor(panel:GetHeight() + 0.5)))
end

setupOverlay:SetScript("OnDragStart", function() panel:StartMoving() end)
setupOverlay:SetScript("OnDragStop", function()
    panel:StopMovingOrSizing()
    PinTopRight()
    panel.dirty = true
end)

local function SaveBoxSize()
    local w = max(200, min(600, floor(panel:GetWidth() + 0.5)))
    local h = max(80, min(1400, floor(panel:GetHeight() + 0.5)))
    db.width, db.boxHeight = w, h
end

local function StopSizing()
    if not panel.sizing then return end
    panel:StopMovingOrSizing()
    panel.sizing = false
    SaveBoxSize()
    PinTopRight()                      -- keep the top edge where it is
    ApplyLook()
    ShowSetupSize()
    panel.dirty = true
end

local function NewGrip(corner)
    local g = CreateFrame("Button", nil, setupOverlay)
    g:SetSize(18, 18)
    g:SetFrameLevel(55)
    g:SetPoint(corner, panel, corner, 0, 0)
    g:EnableMouse(true)
    local tex = g:CreateTexture(nil, "OVERLAY")
    tex:SetAllPoints(g)
    tex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    if corner == "BOTTOMLEFT" then tex:SetTexCoord(1, 0, 0, 1) end   -- mirror the grabber
    g:SetScript("OnMouseDown", function()
        panel.sizing = true
        panel:StartSizing(corner)
    end)
    g:SetScript("OnMouseUp", StopSizing)
    g:SetScript("OnHide", StopSizing)
    return g
end
NewGrip("BOTTOMLEFT")
NewGrip("BOTTOMRIGHT")

panel:SetScript("OnSizeChanged", function()
    if not panel.sizing then return end
    -- reflow the rows to the new width while the corner is being dragged
    db.width = max(200, min(600, floor(panel:GetWidth() + 0.5)))
    ShowSetupSize()
    panel.dirty = true
end)

-- The setup window: sits to the left of the panel while you place it,
-- size it and pick a look. The panel itself is the live preview.
local setupWin = CreateFrame("Frame", "RXPQuestPanelSetup", UIParent, BackdropTemplate)
setupWin:SetSize(230, 214)
setupWin:SetFrameStrata("DIALOG")
setupWin:SetClampedToScreen(true)
setupWin:Hide()
if setupWin.SetBackdrop then
    setupWin:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\DialogFrame\\UI-DialogBox-Border",
        tile = true, tileSize = 32, edgeSize = 24,
        insets = {left = 6, right = 6, top = 6, bottom = 6},
    })
end
do
    local function Text(font, size, r, g, b, yOff, msg)
        local fs = setupWin:CreateFontString(nil, "OVERLAY")
        SetFont(fs, font, size, "")
        fs:SetPoint("TOPLEFT", setupWin, "TOPLEFT", 16, yOff)
        fs:SetWidth(198)
        fs:SetJustifyH("LEFT")
        fs:SetTextColor(r, g, b)
        fs:SetText(msg)
        return fs
    end
    Text(HEAD_FONT, 14, 1, 0.82, 0, -16, "RXP Quest Panel setup")
    Text(BODY_FONT, 12, 0.92, 0.92, 0.92, -38,
         "1. Drag the panel where you want it.\n" ..
         "2. Drag a bottom corner to set the most room it can take.\n" ..
         "3. Pick a look:")
    setupWin.sizeText = Text(BODY_FONT, 11, 0.62, 0.62, 0.62, -152, "")
end
local SetStyle   -- defined below
local function NewSetupButton(label, w)
    local b = CreateFrame("Button", nil, setupWin)
    b:SetSize(w, 22)
    b.bg = b:CreateTexture(nil, "BACKGROUND")
    b.bg:SetAllPoints(b)
    b.bg:SetTexture("Interface\\Buttons\\UI-Panel-Button-Up")
    b.bg:SetTexCoord(0, 0.625, 0, 0.6875)
    b.hl = b:CreateTexture(nil, "HIGHLIGHT")
    b.hl:SetAllPoints(b)
    b.hl:SetTexture("Interface\\Buttons\\UI-Panel-Button-Highlight")
    b.hl:SetTexCoord(0, 0.625, 0, 0.6875)
    b.hl:SetBlendMode("ADD")
    b.t = b:CreateFontString(nil, "OVERLAY")
    SetFont(b.t, HEAD_FONT, 11, "")
    b.t:SetPoint("CENTER", 0, 0)
    b.t:SetTextColor(1, 0.82, 0)
    b.t:SetText(label)
    b.SetChosen = function(self, on)
        self.t:SetText((on and "> " or "") .. label .. (on and " <" or ""))
        if on then self.t:SetTextColor(1, 1, 1) else self.t:SetTextColor(1, 0.82, 0) end
    end
    return b
end
setupWin.blizzard = NewSetupButton("Blizzard Native", 198)
setupWin.blizzard:SetPoint("TOPLEFT", setupWin, "TOPLEFT", 16, -96)
setupWin.blizzard:SetScript("OnClick", function() SetStyle("blizzard") end)
setupWin.rail = NewSetupButton("Waypoint Rail", 198)
setupWin.rail:SetPoint("TOPLEFT", setupWin.blizzard, "BOTTOMLEFT", 0, -4)
setupWin.rail:SetScript("OnClick", function() SetStyle("rail") end)
setupWin.done = NewSetupButton("Done", 90)
setupWin.done:SetPoint("BOTTOMRIGHT", setupWin, "BOTTOMRIGHT", -14, 14)

local function UpdateSetupWin()
    setupWin.blizzard:SetChosen(style == "blizzard")
    setupWin.rail:SetChosen(style == "rail")
    setupWin.sizeText:SetText(strformat("Most room: %d x %d. The box only draws as tall as what's in it.",
                                        db.width or 0, db.boxHeight or 0))
    setupWin:ClearAllPoints()
    setupWin:SetPoint("TOPRIGHT", panel, "TOPLEFT", -12, 0)
end

local function SetSetupMode(on)
    panel.setup = on and true or false
    if on then
        if not db.boxHeight then
            db.boxHeight = max(160, floor(panel:GetHeight() + 0.5))
        end
        setupOverlay:Show()
        ShowSetupSize()
        UpdateSetupWin()
        setupWin:Show()
    else
        StopSizing()
        setupOverlay:Hide()
        setupWin:Hide()
        PinTopRight()
        db.locked = true
        db.setupDone = true
    end
    panel.dirty = true
end

SetStyle = function(name)
    if not PALETTES[name] then return false end
    db.style = name
    ApplyTheme()
    if panel.setup == true then UpdateSetupWin() end
    panel.dirty = true
    panel.ghostDirty = true
    return true
end

local function FinishSetup()
    SetSetupMode(false)
    Print("setup saved: %s look, %d wide, up to %d tall. /rxpq setup changes it later.",
          STYLE_NAMES[style], db.width, db.boxHeight or 0)
end
setupWin.done:SetScript("OnClick", FinishSetup)

---------------------------------------------------------------------------
-- Enable / disable
---------------------------------------------------------------------------
local function Apply()
    if db.enabled then
        ApplyLook()
        if panel:GetHeight() < 20 then panel:SetHeight(60) end
        if not panel:GetPoint(1) then RestorePosition() end
        panel:Show()
        pcall(GhostRXPWindow)
        pcall(HideOtherTrackers)
        Render()
    else
        panel:Hide()
        UnghostRXPWindow()
        RestoreOtherTrackers()
    end
end

local function WarnIfRXPPaused()
    local R = RXP()
    local p = R and R.settings and R.settings.profile
    if p and p.hideGuideWindow then
        Print("RXP's own \"Hide Window\" option is on, and RXP pauses the guide while it's on. " ..
              "Turn it off in RXP's settings; this addon already hides the window for you.")
    end
    if R and R.v2 and R.v2.IsGuideWindowEnabled then
        local ok, v2 = pcall(R.v2.IsGuideWindowEnabled, R.v2)
        if ok and v2 then
            Print("RXP's beta v2 guide window is on. This addon is built for the standard window, " ..
                  "so turn the v2 interface off in RXP's settings for best results.")
        end
    end
end

---------------------------------------------------------------------------
-- Hooks into RXP and update driver
---------------------------------------------------------------------------
local function MarkDirty()
    panel.dirty = true
    panel.ghostDirty = true
end

local hooked = false
local function HookRXP()
    if hooked then return end
    local R, f = RXP(), RXPFrame()
    if not (R and f) then return end
    hooked = true
    if type(R.SetStep) == "function" then hooksecurefunc(R, "SetStep", MarkDirty) end
    if type(R.UpdateStepCompletion) == "function" then hooksecurefunc(R, "UpdateStepCompletion", MarkDirty) end
    if f.CurrentStepFrame and type(f.CurrentStepFrame.UpdateText) == "function" then
        hooksecurefunc(f.CurrentStepFrame, "UpdateText", MarkDirty)
    end
    if f.BottomFrame and type(f.BottomFrame.UpdateFrame) == "function" then
        hooksecurefunc(f.BottomFrame, "UpdateFrame", MarkDirty)
    end
    if type(R.LoadGuide) == "function" then hooksecurefunc(R, "LoadGuide", MarkDirty) end
    -- RXP re-anchors its timer bars whenever one starts or ends: move them back
    -- into the panel straight away, and make room for them on the next redraw.
    if type(R.SortTimers) == "function" then
        hooksecurefunc(R, "SortTimers", function()
            MarkDirty()
            AnchorTimers()
        end)
    end
    -- RXP's own show/hide toggle: follow it
    f:HookScript("OnShow", MarkDirty)
    f:HookScript("OnHide", MarkDirty)
end

local driver = CreateFrame("Frame")
local sinceRender, sinceGhost, sinceSafety = 0, 0, 0
driver:SetScript("OnUpdate", function(_, elapsed)
    if not db or not db.enabled then return end
    sinceRender = sinceRender + elapsed
    sinceGhost = sinceGhost + elapsed
    sinceSafety = sinceSafety + elapsed
    if sinceSafety > 1.5 then          -- slow safety refresh (timers, text RXP changed silently)
        sinceSafety = 0
        panel.dirty = true
    end
    if sinceGhost > 5 then              -- and re-check RXP's hidden window now and then
        panel.ghostDirty = true
    end
    if panel.ghostDirty and sinceGhost > 0.25 then
        sinceGhost = 0
        panel.ghostDirty = false
        GhostRXPWindow()
    end
    if panel.dirty and sinceRender > 0.1 then
        -- Never redraw while a mouse button is held over the panel: wait
        -- until the click has finished, then catch up.
        local held = _G.IsMouseButtonDown and (_G.IsMouseButtonDown("LeftButton") or _G.IsMouseButtonDown("RightButton"))
        if panel.sizing or not (held and panel:IsMouseOver()) then
            sinceRender = 0
            Render()
        end
    end
end)

driver:RegisterEvent("ADDON_LOADED")
driver:RegisterEvent("PLAYER_LOGIN")
driver:RegisterEvent("PLAYER_ENTERING_WORLD")
driver:RegisterEvent("QUEST_LOG_UPDATE")
driver:RegisterEvent("QUEST_WATCH_UPDATE")
driver:RegisterEvent("UNIT_QUEST_LOG_CHANGED")
pcall(driver.RegisterEvent, driver, "QUEST_WATCH_LIST_CHANGED") -- newer clients only
-- Shift-clicking in the quest log changes tracking without a reliable event on old clients.
for _, fn in ipairs({"AddQuestWatch", "RemoveQuestWatch"}) do
    if type(_G[fn]) == "function" then hooksecurefunc(fn, function() panel.dirty = true end) end
    local CQ = _G.C_QuestLog
    if CQ and type(CQ[fn]) == "function" then hooksecurefunc(CQ, fn, function() panel.dirty = true end) end
end
driver:RegisterEvent("PLAYER_REGEN_ENABLED")
driver:SetScript("OnEvent", function(_, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 == ADDON_NAME then
            InitDB()
            HookRXP()
        end
        return
    end
    if not db then return end
    if event == "PLAYER_LOGIN" then
        HookRXP()
        RestorePosition()
        ApplyTheme()
        Apply()
        -- The addon used to be called RXPUnified; two copies would fight over RXP's window.
        local isLoaded = (_G.C_AddOns and _G.C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
        if isLoaded and isLoaded("RXPUnified") then
            Print("the old RXPUnified addon is also loaded. Delete its folder from Interface\\AddOns and /reload.")
        end
        -- First time: walk through place, size and look, with the panel as a live preview.
        if db.enabled and not db.setupDone then
            _G.C_Timer.After(2, function()
                if db.enabled and not db.setupDone and panel.setup ~= true then
                    SetSetupMode(true)
                    Print("welcome! Place the panel, set its size and pick a look, then press Done.")
                end
            end)
        end
    elseif event == "PLAYER_ENTERING_WORLD" then
        _G.C_Timer.After(6, WarnIfRXPPaused)
        if db.enabled then
            -- Other tracker addons build their frames late; catch them too.
            _G.C_Timer.After(3, function() if db.enabled then pcall(HideOtherTrackers); MarkDirty() end end)
            _G.C_Timer.After(10, function() if db.enabled then pcall(HideOtherTrackers); MarkDirty() end end)
            Apply()
        end
    elseif event == "PLAYER_REGEN_ENABLED" then
        if needsHideAfterCombat then
            needsHideAfterCombat = false
            if db.enabled then HideOtherTrackers() else RestoreOtherTrackers() end
        end
    else
        panel.dirty = true
    end
end)

---------------------------------------------------------------------------
-- Slash commands
---------------------------------------------------------------------------
local function Help()
    Print("commands:")
    Print("  /rxpq toggle - switch between this panel and the stock RXP window")
    Print("  /rxpq setup - place the box, set its largest size and pick a look")
    Print("  /rxpq style [blizzard|rail] - switch between the Blizzard Native and Waypoint Rail looks")
    Print("  /rxpq auto - clear the size you set in setup")
    Print("  /rxpq lock - lock or unlock dragging (drag the GUIDE/QUESTS headers)")
    Print("  /rxpq reset - put the panel back in its default spot")
    Print("  /rxpq quests - show or hide the quest section")
    Print("  /rxpq allquests - show every quest, or only tracked ones (shift-click a quest to track it)")
    Print("  /rxpq tracker - hide or show your old quest tracker")
    Print("  /rxpq scale <0.5-2>, /rxpq width <200-600>, /rxpq height <80-1400>, /rxpq alpha <0-1>")
    Print("  /rxpq debug - print what the panel sees (send this if something looks wrong)")
end

local function Debug()
    local R, f = RXP(), RXPFrame()
    local build, _, _, toc = "?", nil, nil, "?"
    if _G.GetBuildInfo then build, _, _, toc = _G.GetBuildInfo() end
    Print("client %s, interface %s, enabled=%s, look=%s, setupDone=%s", tostring(build), tostring(toc),
          tostring(db.enabled), tostring(style), tostring(db.setupDone))
    local okName, gname = pcall(function()
        local g = R and R.currentGuide
        return g and (g.displayname or g.name) or "none"
    end)
    Print("RXP found=%s, window found=%s, guide=%s", tostring(R ~= nil), tostring(f ~= nil),
          okName and tostring(gname) or "unreadable")
    local p, _, rp, x, yy = panel:GetPoint(1)
    Print("panel shown=%s visible=%s size=%dx%d strata=%s point=%s %s %s %s",
          panel:IsShown() and "yes" or "no", panel:IsVisible() and "yes" or "no", floor(panel:GetWidth() + 0.5),
          floor(panel:GetHeight() + 0.5), tostring(panel:GetFrameStrata()), tostring(p), tostring(rp),
          tostring(x and floor(x)), tostring(yy and floor(yy)))
    Print("box: %s", db.boxHeight and strformat("%d wide, up to %d tall (set in setup)", db.width, db.boxHeight)
          or strformat("grows with content, %d wide, up to %d tall", db.width, db.maxHeight))
    local seen = {}
    for _, name in ipairs(TRACKER_FRAMES) do
        local fr = _G[name]
        if type(fr) == "table" and fr.IsShown then
            seen[#seen + 1] = strformat("%s(%s)", name, fr:IsShown() and "shown" or "hidden")
        end
    end
    Print("trackers: %s", #seen > 0 and table.concat(seen, ", ") or "none of the known ones found")
    Print("last error: %s", lastError and (tostring(lastError):match("^[^\n]*")) or "none")
end

_G.SLASH_RXPQUESTPANEL1 = "/rxpq"
_G.SLASH_RXPQUESTPANEL2 = "/rxpu"            -- the old RXP Unified command keeps working
_G.SLASH_RXPQUESTPANEL3 = "/rxpquestpanel"
_G.SlashCmdList.RXPQUESTPANEL = function(msg)
    if not db then return end
    local cmd, arg = (msg or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local num = tonumber(arg)
    if cmd == "toggle" then
        db.enabled = not db.enabled
        if panel.setup and not db.enabled then SetSetupMode(false) end
        Apply()
        if db.enabled then
            Print("on. RXP's window is hidden and redrawn here.")
        else
            Print("off. Stock RXP window is back. If your old quest tracker doesn't reappear, type /reload.")
        end
    elseif cmd == "setup" then
        if not db.enabled then
            Print("the panel is off. Type /rxpq toggle first.")
        elseif panel.setup then
            FinishSetup()
        else
            SetSetupMode(true)
            Print("setup: drag the box to move it, drag a bottom corner to set its largest size, pick a look, then press Done.")
        end
    elseif cmd == "style" then
        local want = arg
        if want == "" then want = (style == "rail") and "blizzard" or "rail" end
        if want == "native" or want == "blizz" then want = "blizzard" end
        if want == "waypoint" then want = "rail" end
        if SetStyle(want) then
            Print("look: %s.", STYLE_NAMES[style])
        else
            Print("unknown look. Use /rxpq style blizzard or /rxpq style rail.")
        end
    elseif cmd == "auto" then
        db.boxHeight = nil
        MarkDirty()
        Print("size limit cleared: the box grows with its content up to %d tall.", db.maxHeight)
    elseif cmd == "lock" then
        db.locked = not db.locked
        Print(db.locked and "locked." or "unlocked: drag a section header to move.")
    elseif cmd == "reset" then
        db.point = nil
        RestorePosition()
        Print("position reset.")
    elseif cmd == "quests" then
        db.showQuests = not db.showQuests
        MarkDirty()
        Print(db.showQuests and "quest section shown." or "quest section hidden.")
    elseif cmd == "allquests" then
        db.allQuests = not db.allQuests
        MarkDirty()
        Print(db.allQuests and "showing every quest in your log."
              or "showing only the quests WoW is tracking (shift-click in the quest log).")
    elseif cmd == "tracker" then
        db.hideOtherTrackers = not db.hideOtherTrackers
        if db.hideOtherTrackers then HideOtherTrackers() else RestoreOtherTrackers() end
        Print(db.hideOtherTrackers and "old quest tracker hidden." or "old quest tracker allowed back (type /reload if it stays hidden).")
    elseif cmd == "scale" and num then
        db.scale = max(0.5, min(2, num)); ApplyLook(); MarkDirty()
    elseif cmd == "width" and num then
        db.width = max(200, min(600, floor(num))); ApplyLook(); MarkDirty()
    elseif cmd == "height" and num then
        if db.boxHeight then
            db.boxHeight = max(80, min(1400, floor(num)))
        else
            db.maxHeight = max(150, min(1200, floor(num)))
        end
        MarkDirty()
    elseif cmd == "debug" then
        Debug()
    elseif cmd == "alpha" and num then
        if IsRail() then db.bgAlpha = max(0, min(1, num)) else db.blizzShade = max(0, min(1, num)) end
        ApplyLook()
    else
        Help()
    end
end
