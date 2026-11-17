local env = dofile(arg[1].."/mock.lua")
local chunk = assert(loadfile(arg[2]))
chunk("RXPQuestPanel", {})
local driver
for _,f in ipairs(env.frames) do if f.__scripts.OnEvent and f.__scripts.OnUpdate then driver=f end end
assert(driver, "driver frame")
local ev=driver.__scripts.OnEvent
ev(driver,"ADDON_LOADED","RXPQuestPanel")
ev(driver,"PLAYER_LOGIN")
-- First load: setup opens by itself, with a look picker beside the panel
local setupWin = _G.RXPQuestPanelSetup
assert(rawget(_G.RXPQuestPanelFrame, "setup") == true and setupWin.__shown, "first-time setup opens on its own")
rawget(setupWin, "rail").__scripts.OnClick(rawget(setupWin, "rail"))
assert(RXPQuestPanelDB.style == "rail", "setup picks Waypoint Rail")
rawget(setupWin, "blizzard").__scripts.OnClick(rawget(setupWin, "blizzard"))
assert(RXPQuestPanelDB.style == "blizzard", "setup picks Blizzard Native")
rawget(setupWin, "done").__scripts.OnClick(rawget(setupWin, "done"))
assert(RXPQuestPanelDB.setupDone == true and not setupWin.__shown and rawget(_G.RXPQuestPanelFrame, "setup") == false,
       "Done saves and closes setup")
print("first-time setup OK")
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
-- v0.4.2: the setup size is a maximum; the box only draws as tall as its content
driver.__scripts.OnUpdate(driver, 2)
local ch = contentF:GetHeight()
assert(ch < 410 and panel:GetHeight() == math.max(40, ch), "short content draws short, got "..panel:GetHeight())
SlashCmdList.RXPQUESTPANEL("setup"); driver.__scripts.OnUpdate(driver, 2)
assert(panel:GetHeight() == 410, "setup shows the full bounds")
SlashCmdList.RXPQUESTPANEL("setup"); driver.__scripts.OnUpdate(driver, 2)
assert(panel:GetHeight() == math.max(40, ch), "leaving setup shrinks back to content")
print(string.format("max box 320x410, content %d tall", ch))
SlashCmdList.RXPQUESTPANEL("height 100")
driver.__scripts.OnUpdate(driver, 2)
assert(db.boxHeight == 100 and panel:GetHeight() == 100, "tall content is capped at the max and scrolls")
SlashCmdList.RXPQUESTPANEL("auto")
driver.__scripts.OnUpdate(driver, 2)
assert(db.boxHeight == nil and panel:GetHeight() == math.max(40, math.min(contentF:GetHeight(), db.maxHeight)), "auto grows with content again")
-- toggling off mid-setup leaves no overlay behind
SlashCmdList.RXPQUESTPANEL("setup"); SlashCmdList.RXPQUESTPANEL("toggle")
assert(not panel.setup and not overlay.__shown, "toggle off ends setup")
SlashCmdList.RXPQUESTPANEL("toggle")
SlashCmdList.RXPQUESTPANEL("debug")
-- v0.2.1: link lines open RXP's copy-the-link box
local step = RXPFrame.activeSteps[1]
local linkFrame = CreateFrame("Frame", nil, RXPFrame)
local ran = 0
local linkEl = {text="CLICK HERE for a video tutorial", textOnly=true, url="https://example.com/v", tooltip="Click to view the link", frame=linkFrame, step=step}
linkFrame.element = linkEl
linkFrame:SetScript("OnMouseDown", function(self) assert(self == linkFrame); ran = ran + 1 end)
table.insert(step.elements, linkEl)
panel.dirty = true
driver.__scripts.OnUpdate(driver, 2)
local function rowFor(el) return find(panel, function(c) return c.element == el end)[1] end
local lr = rowFor(linkEl)
assert(lr and lr.__mouse and rawget(lr, "onClick"), "link line is clickable")
lr.__scripts.OnClick(lr, "LeftButton")
assert(ran == 1, "click runs RXP's own link handler")
-- RXP's handler gone: falls back to RXP's popup with the url
linkFrame:SetScript("OnMouseDown", nil)
local shown, urlSeen
StaticPopupDialogs = {RXP_Link = {}}
StaticPopup_Show = function(name) shown = name; urlSeen = RXP.url end
lr.__scripts.OnClick(lr, "LeftButton")
assert(shown == "RXP_Link" and urlSeen == "https://example.com/v" and RXP.url == nil, "falls back to RXP_Link popup")
-- no RXP popup either: our own box gets the url
StaticPopupDialogs = {}
local data
StaticPopup_Show = function(name, _, _, d) shown = name; data = d end
lr.__scripts.OnClick(lr, "LeftButton")
assert(shown == "RXPQUESTPANEL_LINK" and data == "https://example.com/v", "own link box")
-- plain text lines stay unclickable
local plain = rowFor(step.elements[1])
assert(plain and rawget(plain, "onClick") == nil and not plain.__mouse, "plain text line has no click")
print("link lines OK")
-- v0.3.0: arrows peek at other steps; RestedXP's step never changes
local steps = RXP.currentGuide.steps
steps[17] = step
steps[16] = {index=16, elements={{text="Fly to Thorium Point", tag="fly", completed=true},
                                  {text="CLICK HERE for a video", textOnly=true, url="https://example.com/16"}}}
steps[15] = {index=15, tip=true, elements={{text="tip"}}}
steps[14] = {index=14, elements={{text="Turn in Hardened Shells", tag="turnin"}}}
steps[18] = {index=18, elements={{text="Get the Kargath Flight Path", tag="fp"}}}
local setCalls = {}
RXP.SetStep = function(n) setCalls[#setCalls+1] = n end
local function arrow(sym) return find(panel, function(c) local t = rawget(c, "t"); return c.__kind=="Button" and t and rawget(t, "__text") == sym end)[1] end
local prev, nxt = arrow("<"), arrow(">")
assert(prev and nxt, "arrow buttons")
local function rowText(txt) return find(panel, function(c) local t = rawget(c, "text"); return type(t) == "table" and rawget(t, "__text") == txt and c.__shown end)[1] end
local function peekLabel()
    local bar = find(panel, function(c) local l = rawget(c, "label"); local st = rawget(c, "state")
        return l and st and c.__shown end)[1]
    return bar and (rawget(bar.label, "__text") .. " " .. rawget(bar.state, "__text")), bar
end
local function isPeek(txt) local l = peekLabel(); return l and l:lower() == txt:lower() end
prev.__scripts.OnClick(prev, "LeftButton")
driver.__scripts.OnUpdate(driver, 2)
assert(#setCalls == 0, "previous doesn't move RestedXP")
assert(isPeek("STEP 16 done"), "peek bar shows step 16")
local link16 = rowText("CLICK HERE for a video")
assert(link16 and rawget(link16, "onClick"), "links clickable while peeking")
local shownUrl
StaticPopupDialogs = {RXP_Link = {}}
StaticPopup_Show = function() shownUrl = RXP.url end
link16.__scripts.OnClick(link16, "LeftButton")
assert(shownUrl == "https://example.com/16", "peek link opens RXP's box")
prev.__scripts.OnClick(prev, "LeftButton")      -- skips tip step 15
driver.__scripts.OnUpdate(driver, 2)
assert(isPeek("STEP 14 done"), "skips steps with nothing to show")
nxt.__scripts.OnClick(nxt, "LeftButton"); nxt.__scripts.OnClick(nxt, "LeftButton")  -- 16, then 17 = current
driver.__scripts.OnUpdate(driver, 2)
assert(not peekLabel() and rowText("Run circles around The Shimmering Flats"), "back on the live view")
nxt.__scripts.OnClick(nxt, "LeftButton")
driver.__scripts.OnUpdate(driver, 2)
assert(isPeek("STEP 18 coming up"), "next peeks ahead")
local _, bar = peekLabel()
assert(rawget(bar.back.t, "__text") == "Back" and rawget(bar.go.t, "__text") == "Go here", "one line with two buttons")
assert(not rowText("Move RestedXP to this step") and not rowText("Back to your step (17)"), "no loose lines")
bar.go.__scripts.OnClick(bar.go, "LeftButton")
assert(setCalls[1] == 18, "jump moves RestedXP on request")
driver.__scripts.OnUpdate(driver, 2)
assert(not peekLabel(), "jump ends the peek")
nxt.__scripts.OnClick(nxt, "LeftButton")
nxt.__scripts.OnClick(nxt, "RightButton")
driver.__scripts.OnUpdate(driver, 2)
assert(not peekLabel(), "right-click returns to current")
prev.__scripts.OnClick(prev, "LeftButton"); driver.__scripts.OnUpdate(driver, 2)
local _, bar2 = peekLabel()
bar2.back.__scripts.OnClick(bar2.back, "LeftButton"); driver.__scripts.OnUpdate(driver, 2)
assert(not peekLabel(), "Back button returns to current")
assert(#setCalls == 1, "only the explicit jump touched RestedXP")
print("peek OK")
-- v0.4.0: quests follow Blizzard's tracking
local function tick() driver.__scripts.OnUpdate(driver, 2) end
tick()
assert(rowText("[30] Hardened Shells"), "tracked quest shown")
assert(not rowText("[45] Deadmire"), "untracked quest hidden")
local more = rowText("2 more not tracked. Click to show them all.")
assert(more, "hint for untracked quests")
AddQuestWatch(4); tick()        -- shift-click in Blizzard's quest log
assert(rowText("[45] Deadmire"), "newly tracked quest appears")
assert(rowText("1 more not tracked. Click to show them all."), "hint count updates")
local dm = rowText("[45] Deadmire")
SHIFT = true; dm.__scripts.OnClick(dm, "LeftButton"); SHIFT = false; tick()
assert(not WATCHED[4] and not rowText("[45] Deadmire"), "shift-click in panel untracks")
more = rowText("2 more not tracked. Click to show them all.")
more.__scripts.OnClick(more, "LeftButton"); tick()
assert(rowText("[45] Deadmire") and rowText("Showing all quests. Click to show only tracked ones."), "show all")
dm = rowText("[45] Deadmire")
SHIFT = true; dm.__scripts.OnClick(dm, "LeftButton"); SHIFT = false; tick()
assert(WATCHED[4], "shift-click tracks from the all view")
SlashCmdList.RXPQUESTPANEL("allquests"); tick()
assert(RXPQuestPanelDB.allQuests == false and rowText("[45] Deadmire") and not rowText("[30] Load Lightening"), "allquests toggles back")
WATCHED = {}; IsQuestWatched = function(i) return WATCHED[i] and 1 or nil end; tick()
assert(rowText("No quests tracked (3 in your log). Click to show them all."), "nothing tracked hint")
print("tracking OK")
-- v0.4.3: RestedXP's flight timer bar moves into the panel under the guide name
SlashCmdList.RXPQUESTPANEL("allquests")
local bc = CreateFrame("Frame", nil, RXPFrame)
local bar = CreateFrame("Frame", nil, UIParent)
local anchoredTo
rawset(bar, "SetPoint", function(self, pt, rel) anchoredTo = rel end)
rawset(bar, "exp", 999)
rawset(bc, "bars", {Kargath = bar})
rawset(RXPFrame, "BarContainer", bc)
local sorted = 0
RXP.SortTimers = function() sorted = sorted + 1; anchoredTo = "rxp spot" end
RXPFrame.BarContainer = bc
local function slot() return find(panel, function(c) return c.__kind == "Frame" and c.placedGen and c.pH == 16 and c.__shown end)[1] end
driver.__scripts.OnUpdate(driver, 2)
local ts = slot()
assert(ts and anchoredTo == ts, "timer bar sits in the panel")
-- RXP re-sorts (a new timer starts or one ends): our hook puts it back
-- (hooks are installed at login, so call the hooked function the way RXP would)
RXP:SortTimers()
assert(sorted == 1, "RXP's own sort still runs")
bar.__shown = false
driver.__scripts.OnUpdate(driver, 2)
assert(not slot(), "no gap left once the flight ends")
print("flight timer OK")
-- Switching looks redraws without errors, and the rail look labels steps in capitals
local chat = {}
local oldPrint = _G.DEFAULT_CHAT_FRAME.AddMessage
_G.DEFAULT_CHAT_FRAME.AddMessage = function(self, m) chat[#chat + 1] = m; return oldPrint(self, m) end
SlashCmdList.RXPQUESTPANEL("style")
assert(RXPQuestPanelDB.style == "rail", "/rxpq style toggles to rail")
driver.__scripts.OnUpdate(driver, 2)
local ghosts = find(panel, function(c) local t = rawget(c, "text")
    return type(t) == "table" and tostring(rawget(t, "__text") or ""):match("^%d+  ") and c.__shown end)
assert(#ghosts <= 1, "rail shows no preview of the next step (only the faded previous one)")
prev.__scripts.OnClick(prev, "LeftButton")
driver.__scripts.OnUpdate(driver, 2)
assert((peekLabel() or ""):match("^STEP %d+"), "rail look labels peeks STEP n")
prev.__scripts.OnClick(prev, "RightButton")
SlashCmdList.RXPQUESTPANEL("style native")
assert(RXPQuestPanelDB.style == "blizzard", "/rxpq style native picks Blizzard")
driver.__scripts.OnUpdate(driver, 2)
SlashCmdList.RXPQUESTPANEL("style bogus")
assert(RXPQuestPanelDB.style == "blizzard", "unknown look leaves the style alone")
SlashCmdList.RXPQUESTPANEL("alpha 0.4")
assert(RXPQuestPanelDB.blizzShade == 0.4, "alpha sets the Blizzard shade")
for _, m in ipairs(chat) do assert(not tostring(m):find("drawing error"), "no drawing error after a look switch: " .. tostring(m)) end
print("look switch OK")
print("ALL OK")
