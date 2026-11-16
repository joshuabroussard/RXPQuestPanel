# RXP Quest Panel

A World of Warcraft addon that hides the RestedXP Guides main window and redraws
the current guide steps, plus your quest log, in one modern panel on the right
side of the screen. The RXP arrow and everything else in RXP stay as they are.

Built for WoW Forever (also loads on Classic Era). Requires RestedXP Guides.

## Install with WowUp

1. In WowUp, pick your WoW Forever installation.
2. Choose **Get Addons**, then **Install from URL**.
3. Paste `https://github.com/joshuabroussard/RXPQuestPanel` and install.

WowUp checks this repository's releases for updates like any other addon.

## Manual install

Download `RXPQuestPanel-v<version>.zip` from the latest release and unzip it into
`Interface\AddOns`, so you get `Interface\AddOns\RXPQuestPanel\RXPQuestPanel.toc`.

See `README.txt` for commands and setup (`/rxpq setup`).

Upgrading from the old RXPUnified addon: delete `Interface\AddOns\RXPUnified`,
or both copies will load.

## Cutting a release

1. Bump `## Version:` in `RXPQuestPanel.toc`.
2. Add a `Changes in <version>` section to `README.txt`.
3. Push to `main`.

The Release workflow lints and tests the addon, builds
`RXPQuestPanel-v<version>.zip` and `release.json`, and publishes the release.
Pushes that don't change the version publish nothing.
