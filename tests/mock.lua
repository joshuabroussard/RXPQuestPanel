-- Minimal permissive WoW API mock to smoke-test Core.lua
local frames = {}
local function newObj(kind, parent)
  local o = {__kind=kind, __scripts={}, __children={}, __shown=true, __alpha=1, __mouse=(kind=="Button" or kind=="CheckButton"), __wheel=false, __text="", __points={}, __vscroll=0}
  if parent and parent.__children then table.insert(parent.__children, o) end
  o.__parent = parent
  return setmetatable(o, {__index=function(t,k)
    local m = ({
      SetScript=function(s,n,f) s.__scripts[n]=f end,
      GetScript=function(s,n) return s.__scripts[n] end,
      HookScript=function(s,n,f) local old=s.__scripts[n]; s.__scripts[n]=function(...) if old then old(...) end f(...) end end,
      Show=function(s) local was=s.__shown; s.__shown=true; if not was and s.__scripts.OnShow then s.__scripts.OnShow(s) end end,
      Hide=function(s) local was=s.__shown; s.__shown=false; if was and s.__scripts.OnHide then s.__scripts.OnHide(s) end end,
      IsShown=function(s) return s.__shown end,
      SetShown=function(s,v) if v then s:Show() else s:Hide() end end,
      SetAlpha=function(s,a) s.__alpha=a end, GetAlpha=function(s) return s.__alpha end,
      EnableMouse=function(s,v) s.__mouse=v and true or false end, IsMouseEnabled=function(s) return s.__mouse end,
      EnableMouseWheel=function(s,v) s.__wheel=v and true or false end, IsMouseWheelEnabled=function(s) return s.__wheel end,
      GetChildren=function(s) return unpack(s.__children) end,
      GetNumChildren=function(s) return #s.__children end,
      GetParent=function(s) return s.__parent end,
      SetText=function(s,v) if s.__kind=="FontString" and not rawget(s,"__font") then error("FontString:SetText(): Font not set",2) end s.__text=v or "" end, GetText=function(s) return s.__text end,
      GetStringHeight=function(s) return 14 * (1 + math.floor(#(s.__text or "")/40)) end,
      GetStringWidth=function(s) return 6*#(s.__text or "") end,
      SetFont=function(s,f) if f then s.__font=f return true end return false end, SetFontObject=function(s,o) s.__font=o end,
      SetFrameStrata=function(s,v) s.__strata=v end, GetFrameStrata=function(s) return s.__strata or "MEDIUM" end,
      GetPoint=function(s) return "TOPRIGHT", UIParent, "TOPRIGHT", -24, -250 end,
      GetHeight=function(s) return s.__h or 100 end, SetHeight=function(s,h) s.__h=h end,
      SetSize=function(s,w,h) s.__w=w; s.__h=h end, GetWidth=function(s) return s.__w or 100 end,
      GetVerticalScroll=function(s) return s.__vscroll end, SetVerticalScroll=function(s,v) s.__vscroll=v end,
      GetVerticalScrollRange=function(s) return 0 end,
      IsForbidden=function() return false end, IsProtected=function() return false end,
      GetObjectType=function(s) return s.__kind end,
      Click=function(s) if s.__scripts.OnClick then s.__scripts.OnClick(s,"LeftButton") end end,
      GetOwner=function() return nil end,
      CreateTexture=function(s) return newObj("Texture", s) end,
      CreateFontString=function(s) return newObj("FontString", s) end,
    })[k]
    if m then return m end
    return function() end
  end})
end
CreateFrame=function(kind,name,parent) local f=newObj(kind,parent); if name then _G[name]=f end; frames[#frames+1]=f; return f end
UIParent=newObj("Frame")
GameTooltip=newObj("Frame")
DEFAULT_CHAT_FRAME={AddMessage=function(_,m) print("CHAT:",m) end}
STANDARD_TEXT_FONT="Fonts\\FRIZQT__.TTF"
GetLocale=function() return "enUS" end
BackdropTemplateMixin={}
GetTime=os.clock
C_Timer={After=function(_,f) f() end}
hooksecurefunc=function(t,k,f) local old=t[k]; t[k]=function(...) local r={old(...)}; f(...); return unpack(r) end end
SlashCmdList={}
COMBAT=false
InCombatLockdown=function() return COMBAT end
GetBuildInfo=function() return "1.60.1", "70450", "", 16001 end
GameFontHighlightSmall={}
ObjectiveTrackerFrame=CreateFrame("Frame",nil,UIParent)
ObjectiveTrackerFrame.IsProtected=function() return true end
ObjectiveTrackerFrame.Hide=function(s) if COMBAT then error("ADDON_ACTION_BLOCKED: hid protected tracker in combat") end s.__shown=false end
unpack = unpack or table.unpack
-- quest log
local quests={{"Thousand Needles",nil,nil,true},{"Hardened Shells",30,0,false,nil,nil,nil,1104},{"Load Lightening",30,0,false,nil,1,nil,1176},{"Deadmire",45,0,false,nil,nil,nil,1205}}
GetNumQuestLogEntries=function() return #quests, 3 end
GetQuestLogTitle=function(i) local q=quests[i]; return q[1],q[2],q[3],q[4],q[5],q[6],q[7],q[8] end
GetNumQuestLeaderBoards=function(i) return i==2 and 1 or (i==4 and 1 or 0) end
GetQuestLogLeaderBoard=function(j,i) if i==2 then return "Hardened Tortoise Shell: 4/9","item",false end return "Deadmire's Tooth: 0/1","item",false end
GetQuestDifficultyColor=function(l) return {r=1,g=1,b=0} end
QuestWatchFrame=newObj("Frame")
-- fake RXP
RXPFrame=CreateFrame("Frame","RXPFrame",UIParent)
RXPFrame.CurrentStepFrame=CreateFrame("Frame",nil,RXPFrame)
RXPFrame.BottomFrame=CreateFrame("Frame",nil,RXPFrame)
local tipSF=CreateFrame("Frame",nil,RXPFrame.CurrentStepFrame)
local tipChild=CreateFrame("Button",nil,tipSF)
local sf=CreateFrame("Frame",nil,RXPFrame.CurrentStepFrame); sf:EnableMouse(true)
local elFrame=CreateFrame("Frame",nil,sf); elFrame.button=CreateFrame("CheckButton",nil,elFrame)
local clicked=0
elFrame.button:SetScript("OnClick",function() clicked=clicked+1 end)
local step17={index=17, elements={
  {text="Run circles around The Shimmering Flats", textOnly=true},
  {text="1/10 Hollow Vulture Bone", tag="complete", questId=1176, frame=elFrame, tooltip="tip!"},
  {text="6/6 Salty Scorpid Venom", completed=true, questId=1104},
}}
local tip={tip=true, elements={{text="Be careful!"}}}
tipSF.step=tip; sf.step=step17
RXPFrame.CurrentStepFrame.framePool={sf, tipSF}
RXPFrame.activeSteps={step17, tip}
RXPFrame.CurrentStepFrame.UpdateText=function() end
RXPFrame.BottomFrame.UpdateFrame=function() end
RXPFrame.DropDownMenu=function() print("menu opened") end
RXP={currentGuide={displayname="34-35 Shimmering Flats", group="Dungeon Guide 30-40", steps={}},
  icons={complete="|TInterface/x:0|t"}, locale={Get=function(t) return t end},
  ReplaceNpcIds=function(t) return t end, GetGuideProgress=function() return 17 end,
  SetStep=function(n) print("SetStep",n) end, UpdateStepCompletion=function() end, LoadGuide=function() end,
  ActiveStepElementOnEnter=function(f) assert(f.element) end,
  settings={profile={hideGuideWindow=true}}, v2={IsGuideWindowEnabled=function() return false end}}
for i=1,40 do RXP.currentGuide.steps[i]={} end
return {frames=frames, tipSF=tipSF, tipChild=tipChild, sf=sf, getClicked=function() return clicked end}
