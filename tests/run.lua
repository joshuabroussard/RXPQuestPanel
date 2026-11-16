local env = dofile(arg[1].."/mock.lua")
local chunk = assert(loadfile(arg[2]))
chunk("RXPQuestPanel", {})
local driver
for _,f in ipairs(env.frames) do if f.__scripts.OnEvent and f.__scripts.OnUpdate then driver=f end end
assert(driver, "driver frame")
local ev=driver.__scripts.OnEvent
ev(driver,"ADDON_LOADED","RXPQuestPanel")
ev(driver,"PLAYER_LOGIN")
ev(driver,"PLAYER_ENTERING_WORLD", true)
driver.__scripts.OnUpdate(driver, 2)
ev(driver,"QUEST_LOG_UPDATE")
driver.__scripts.OnUpdate(driver, 0.2)
assert(RXPFrame:GetAlpha()==0, "RXP window should be transparent")
assert(RXPFrame:IsShown(), "RXP window must stay shown")
assert(env.sf:IsMouseEnabled()==false, "step frame mouse off")
assert(env.tipChild:IsMouseEnabled()==true, "tip frame keeps mouse")
assert(QuestWatchFrame:IsShown()==false, "blizzard tracker hidden")
-- dump rendered rows
local panel=_G.RXPQuestPanelFrame
assert(panel:IsShown(), "panel shown")
local function dump(o, d)
  for _,c in ipairs(o.__children) do
    if c.__shown and c.__kind=="FontString" and c.__text~="" then print(string.rep(" ",d)..c.__text) end
    dump(c, d+1)
  end
end
-- find check buttons and click the one on the bone row
local function find(o, pred, out) out=out or {}; for _,c in ipairs(o.__children) do if pred(c) then out[#out+1]=c end find(c,pred,out) end return out end
dump(panel,0)
-- click element checkbox: rows whose element has frame
local rows = find(panel, function(c) local e=rawget(c,"element"); return type(e)=="table" and e.frame end)
assert(#rows>=1, "bone row found")
rows[1].check.__scripts.OnClick(rows[1].check)
assert(env.getClicked()==1, "forwarded click to RXP's checkbox")
rows[1].__scripts.OnEnter(rows[1])
SlashCmdList.RXPQUESTPANEL("toggle")
assert(RXPFrame:GetAlpha()==1 and env.sf:IsMouseEnabled()==true, "restored")
assert(not panel:IsShown(), "panel hidden when off")
SlashCmdList.RXPQUESTPANEL("toggle")
SlashCmdList.RXPQUESTPANEL("width 300")
SlashCmdList.RXPQUESTPANEL("")
driver.__scripts.OnUpdate(driver, 0.2)
-- new checks (v0.1.1)
assert(panel:GetHeight() > 20, "panel has a real height")
assert(panel:GetFrameStrata()=="MEDIUM", "strata medium")
assert(ObjectiveTrackerFrame:IsShown()==false, "All Objectives tracker hidden")
-- tracker reshown in combat: only made invisible, no blocked action
COMBAT=true
ObjectiveTrackerFrame.__shown=false
ObjectiveTrackerFrame.__scripts.OnShow(ObjectiveTrackerFrame)
assert(ObjectiveTrackerFrame:GetAlpha()==0, "alpha 0 in combat")
COMBAT=false
ev(driver,"PLAYER_REGEN_ENABLED")
assert(ObjectiveTrackerFrame:IsShown()==false, "hidden after combat")
SlashCmdList.RXPQUESTPANEL("debug")
-- force a drawing error: panel must still show a fallback, not vanish
local realGuide = RXP.currentGuide
RXP.currentGuide = setmetatable({}, {__index=function() error("boom") end})
driver.__scripts.OnUpdate(driver, 2)
assert(panel:IsShown() and panel:GetHeight() >= 40, "fallback panel visible after error")
SlashCmdList.RXPQUESTPANEL("debug")
RXP.currentGuide = realGuide
driver.__scripts.OnUpdate(driver, 2)
assert(panel:GetHeight() > 60, "recovers after error goes away")
-- v0.1.2: top edge pinned, grows down only
local SW, SH = 2560, 1440
UIParent.GetTop=function() return SH end
UIParent.GetRight=function() return SW end
UIParent.GetBottom=function() return 0 end
UIParent.GetEffectiveScale=function() return 1 end
-- pretend a drag left the frame anchored by CENTER at screen pixel (2200, 900)
panel.GetEffectiveScale=function() return 1 end
panel.GetTop=function(s) return 900 + (s.__h or 0)/2 end
panel.GetRight=function(s) return 2200 + (s.__w or 0)/2 end
local setPts = {}
panel.SetPoint=function(s, ...) setPts[#setPts+1] = {...} end
panel.__scripts.OnDragStop = nil
-- drag stop on the header saves position
local hdr = find(panel, function(c) return c.__scripts.OnDragStop ~= nil end)[1]
hdr.__scripts.OnDragStop(hdr)
local last = setPts[#setPts]
assert(last[1]=="TOPRIGHT" and last[3]=="TOPRIGHT", "re-anchored by TOPRIGHT, got "..tostring(last[1]))
print(string.format("pinned TOPRIGHT offset x=%.0f y=%.0f", last[4], last[5]))
-- now pin the real top so height capping can be checked: top at 300 px from bottom
panel.GetTop=function() return 300 end
driver.__scripts.OnUpdate(driver, 2)
assert(panel:GetHeight() <= 292, "height capped to space below the top, got "..panel:GetHeight())
SlashCmdList.RXPQUESTPANEL("scale 1.2")
-- v0.1.3: a redraw with nothing changed must not hide, re-show, re-anchor or
-- toggle mouse on anything (that is what cancelled clicks in game)
driver.__scripts.OnUpdate(driver, 2)   -- settle
local touched = {}
local function spy(o, label)
  for _, m in ipairs({"Hide","EnableMouse","ClearAllPoints"}) do
    local orig = o[m]
    rawset(o, m, function(self, ...) touched[#touched+1] = label..":"..m; return orig(self, ...) end)
  end
end
local clickable = find(panel, function(c) return c.__kind=="Button" and c.__shown end)
for i, b in ipairs(clickable) do spy(b, "button"..i) end
panel.dirty = true
driver.__scripts.OnUpdate(driver, 0.2)
assert(#touched == 0, "redraw touched live buttons: "..table.concat(touched, ", "))
print("idle redraw touched 0 of "..#clickable.." buttons")
-- no redraw while a mouse button is held over the panel
local renders = 0
local realSetHeight = panel.SetHeight
rawset(panel, "SetHeight", function(self, h) renders = renders + 1; return realSetHeight(self, h) end)
IsMouseButtonDown = function() return true end
rawset(panel, "IsMouseOver", function() return true end)
panel.dirty = true
driver.__scripts.OnUpdate(driver, 0.2)
assert(renders == 0, "redrew during a held click")
IsMouseButtonDown = function() return false end
driver.__scripts.OnUpdate(driver, 0.2)
assert(renders == 1, "caught up after the click")
assert(setPts[#setPts][1]=="TOPRIGHT", "scale keeps TOPRIGHT anchor")
-- v0.1.4: one-time setup sizes a fixed box that scrolls inside
local db = RXPQuestPanelDB
rawset(panel, "SetWidth", function(self, w) self.__w = w end)
panel.GetTop=function() return 1300 end
local scrollF = find(panel, function(c) return c.__kind=="ScrollFrame" end)[1]
local contentF = scrollF.__children[1]
SlashCmdList.RXPQUESTPANEL("setup")
assert(panel.setup and db.boxHeight, "setup mode on with a box height")
local overlay = find(panel, function(c) return c.__parent==panel and c.__kind=="Button" and c.__scripts.OnDragStart end)[1]
assert(overlay and overlay.__shown and overlay.__mouse, "setup overlay shown and catches the mouse")
local grips = find(overlay, function(c) return c.__scripts.OnMouseDown ~= nil end)
assert(#grips == 2, "two resize grips, got "..#grips)
-- drag the overlay: moves the panel and re-pins TOPRIGHT
overlay.__scripts.OnDragStart(overlay); overlay.__scripts.OnDragStop(overlay)
assert(setPts[#setPts][1]=="TOPRIGHT", "move in setup keeps TOPRIGHT")
-- resize with the bottom-left grip
grips[1].__scripts.OnMouseDown(grips[1])
assert(panel.sizing, "sizing started")
panel.__w, panel.__h = 320, 410
panel.__scripts.OnSizeChanged(panel)
assert(db.width == 320, "width follows the corner live")
IsMouseButtonDown = function() return true end
panel.dirty = true
renders = 0
driver.__scripts.OnUpdate(driver, 0.2)
assert(not panel.dirty, "reflows while sizing")
assert(renders == 0 and panel:GetHeight() == 410, "doesn't fight the user's drag height")
IsMouseButtonDown = function() return false end
grips[1].__scripts.OnMouseUp(grips[1])
assert(not panel.sizing and db.width == 320 and db.boxHeight == 410, "size saved "..tostring(db.width).."x"..tostring(db.boxHeight))
assert(setPts[#setPts][1]=="TOPRIGHT", "resize keeps TOPRIGHT")
SlashCmdList.RXPQUESTPANEL("setup")
assert(not panel.setup and not overlay.__shown and db.locked, "setup finished, overlay gone, locked")
-- fixed box keeps its size whatever the content
driver.__scripts.OnUpdate(driver, 2)
assert(panel:GetHeight() == 410, "fixed box height, got "..panel:GetHeight())
print(string.format("fixed box 320x410, content %d tall", contentF:GetHeight()))
SlashCmdList.RXPQUESTPANEL("height 300")
driver.__scripts.OnUpdate(driver, 2)
assert(db.boxHeight == 300 and panel:GetHeight() == 300, "height command changes the fixed box")
SlashCmdList.RXPQUESTPANEL("auto")
driver.__scripts.OnUpdate(driver, 2)
assert(db.boxHeight == nil and panel:GetHeight() == math.max(40, math.min(contentF:GetHeight(), db.maxHeight)), "auto grows with content again")
-- toggling off mid-setup leaves no overlay behind
SlashCmdList.RXPQUESTPANEL("setup"); SlashCmdList.RXPQUESTPANEL("toggle")
assert(not panel.setup and not overlay.__shown, "toggle off ends setup")
SlashCmdList.RXPQUESTPANEL("toggle")
SlashCmdList.RXPQUESTPANEL("debug")
print("ALL OK")
