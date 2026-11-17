-- Older clients: no modern menus or settings panel. The menus fall back to
-- dropdown menus and the Options page opens as its own window.
local env = dofile(arg[1].."/mock.lua")
MenuUtil, Settings, InterfaceOptions_AddCategory = nil, nil, nil
local built, toggled = {}, false
UIDropDownMenu_CreateInfo = function() return {} end
UIDropDownMenu_AddButton = function(info) built[#built + 1] = info end
UIDropDownMenu_Initialize = function(frame, init) built = {}; init(frame, 1) end
ToggleDropDownMenu = function() toggled = true end
CloseDropDownMenus = function() end
local chunk = assert(loadfile(arg[2]))
chunk("RXPQuestPanel", {})
local driver
for _, f in ipairs(env.frames) do if f.__scripts.OnEvent and f.__scripts.OnUpdate then driver = f end end
local ev = driver.__scripts.OnEvent
ev(driver, "ADDON_LOADED", "RXPQuestPanel")
ev(driver, "PLAYER_LOGIN")
local opt = _G.RXPQuestPanelOptions
assert(rawget(opt, "kind") == "window", "Options page falls back to its own window")
opt:Hide()
SlashCmdList.RXPQUESTPANEL("options")
assert(opt:IsShown(), "/rxpq options shows the window")
local panel = _G.RXPQuestPanelFrame
local function find(root, pred, out)
  out = out or {}
  for _, c in ipairs(root.__children or {}) do if pred(c) then out[#out + 1] = c end find(c, pred, out) end
  return out
end
local gh = find(panel, function(c) local l = rawget(c, "label"); return l and rawget(l, "__text") == "GUIDE" end)[1]
rawset(panel, "lastDrag", -100)
gh.__scripts.OnClick(gh, "RightButton")
assert(toggled and built[1].text == "RXP Quest Panel" and built[1].isTitle, "header menu falls back to a dropdown")
local lock
for _, info in ipairs(built) do if info.text == "Lock position" then lock = info end end
local was = RXPQuestPanelDB.locked
lock.func()
assert(RXPQuestPanelDB.locked == not was, "dropdown item works")
print("fallback OK")
