RXP Quest Panel 0.3.0
=====================
Hides the RestedXP Guides main window and redraws the current guide steps,
plus your whole quest log, in one panel on the right side of the screen.
The RXP arrow, tip/warning box, active targets, item buttons and everything
else in RXP stay as they are.

Install
  1. Close WoW.
  2. Unzip so you get a folder named RXPQuestPanel containing RXPQuestPanel.toc and Core.lua.
  3. Put that folder in World of Warcraft\<your client folder>\Interface\AddOns\
     (_classic_era_ for Classic Era / Anniversary; use the client folder you play from).
  4. Start WoW, and on the character screen click AddOns and make sure
     "RXP Quest Panel" is ticked (tick "Load out of date AddOns" if it's greyed out).

First-time setup (do this once)
  1. Type /rxpq setup. The panel gets a gold outline.
  2. Drag anywhere on it to move it.
  3. Drag either bottom corner to resize it. The size shows at the bottom.
  4. Type /rxpq setup again. The size and spot are saved and the panel is locked.
  The box then stays exactly that size; when there's more to show than fits,
  scroll inside it with the mouse wheel. Run /rxpq setup again any time to change it.

Commands
  /rxpq setup    size and place the box (see above); run again to finish
  /rxpq auto     go back to a box that grows with its content instead of a fixed size
  /rxpq toggle   switch between this panel and the stock RXP window
  /rxpq lock     lock / unlock dragging (drag by the GUIDE or QUESTS header)
  /rxpq reset    move the panel back to its default spot
  /rxpq quests   show / hide the quest section
  /rxpq tracker  hide / show your old quest tracker
  /rxpq scale <0.5-2>   /rxpq width <200-600>   /rxpq height <80-1400>   /rxpq alpha <0-1>
  /rxpq debug    print what the panel sees (client, RXP, panel size/position,
                 which trackers it found, last error) - send this if anything looks off

Panel
  - GUIDE header: click to collapse. Guide name: right-click for RXP's guide menu.
    < and > step back / forward through the guide.
  - Step objectives have a checkbox; clicking it is the same as clicking RXP's own
    skip checkbox. Counts like 4/9 get a small progress bar. Hover for RXP's tooltip.
  - QUESTS: every quest in your log, coloured by difficulty. Quests the current
    guide step uses come first with a blue edge. Click a quest to open it in the log.

Notes
  - Keep RXP's own "Hide Window" setting OFF. RXP pauses the guide while that is on;
    this addon makes the window invisible instead so the guide keeps running.
  - Built for RXP's standard guide window, not the beta "v2" interface.
  - Flight/timer bars that RXP shows in its window footer are hidden along with the window.

Changes in 0.1.1
  - Fixed: the panel never appeared. Its first draw hit a "Font not set" error,
    which left it shown but zero pixels tall.
  - Drawing errors can no longer make the panel vanish. You get a small red box
    and one chat line instead, and /rxpq debug shows the full error.
  - Now also hides Blizzard's "All Objectives" tracker (ObjectiveTrackerFrame),
    which is what WoW Forever uses. In combat it's only made invisible, then
    hidden properly once combat ends, so you don't get blocked-action errors.
  - Panel sits one layer higher (MEDIUM strata), so other frames don't cover it.

Changes in 0.1.2
  - The panel's top edge now stays pinned. It only grows or shrinks downward as
    steps and quests change, including after you drag it somewhere else.
  - It never grows past the bottom of the screen. It scrolls instead (mouse
    wheel), so the screen edge can't push it upward either.

Changes in 0.1.3
  - Fixed: most clicks on the panel did nothing. The panel redraws several times
    a second as RXP updates, and each redraw briefly hid the headers, the < >
    buttons and the checkboxes and switched mouse input off and on, which
    cancels a click in progress. Redraws now leave anything unchanged alone,
    and the panel never redraws while you're holding a mouse button over it.
  - RXP's invisible window is now made click-through even if it holds secure
    buttons (out of combat).

Changes in 0.1.4
  - New /rxpq setup: drag and resize the box once, and it stays that exact size
    and spot (top edge pinned), scrolling inside instead of growing. That keeps
    it from ever running into your other UI.
  - /rxpq auto switches back to the old grow-with-content behaviour.
  - /rxpq height changes the fixed box when you have one; width now goes to 600.
  - /rxpq debug also shows the box mode and size.

Changes in 0.2.0
  - Renamed from RXP Unified to RXP Quest Panel (folder RXPQuestPanel).
    Delete the old Interface\AddOns\RXPUnified folder, or both copies will load.
  - Commands are now /rxpq. The old /rxpu still works.
  - Settings start fresh under the new name, so run /rxpq setup once.
  - Now published on GitHub, so WowUp can install and update it (see README.md).

Changes in 0.2.1
  - Fixed: clicking a link line in the guide (like "CLICK HERE for a video
    tutorial") did nothing. It now opens RestedXP's box with the link selected,
    so you can press Ctrl+C and paste it into your browser.
  - Link lines are shown in blue so you can tell they're clickable.
  - "Click here for the next guide" lines work the same way as in RXP's window.

Changes in 0.3.0
  - The < and > arrows now only change what the panel shows. RestedXP stays
    on your step, so a step can't auto-complete and bounce you back.
  - While you're looking at another step, a blue bar says which step it is.
    Click "Back to your step" or right-click an arrow to return.
  - "Move RestedXP to this step" moves RestedXP there for real.
  - Steps that are only tips are skipped while looking around.
  - Link lines work on any step you're looking at.
