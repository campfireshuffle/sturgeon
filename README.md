# Sturgeon

Stage Manager, the way it should work.

Sturgeon is a menu-bar app that adds four things to macOS Stage Manager:

- **New windows open where you are.** No more windows dropping into a stage of their own.
- **Move windows between stages** from a menu instead of dragging through the strip.
- **Keep the strip on top**, even over a window that covers its edge.
- **Resize the strip** from 40% to 150%.

## Install

```sh
brew install --cask campfireshuffle/tap/sturgeon
```

Open **Sturgeon** from Applications and click **Set up** once. It asks for your administrator
password, installs its background helper, and stays in the menu bar from then on.

## Requirements

- Apple silicon Mac
- macOS 27 or later
- System Integrity Protection disabled (`csrutil status`)

Sturgeon works by adjusting Stage Manager at runtime, which macOS only allows with SIP disabled. It
checks your system before doing anything and tells you if it cannot run.

## Using it

| Control | What it does |
|---|---|
| New windows join the current stage | New windows open beside the stage you are in |
| Keep the strip visible on top | The strip stays above a window that covers its edge |
| Raise strip tiles | Draws the strip above other windows |
| Strip size | Scales the strip tiles |
| Move front window to… | Moves the frontmost window to the stage you pick |

The top of the menu shows whether Sturgeon is active and whether its safety check passes.

If a macOS update changes something Sturgeon relies on, it turns itself off and says so instead of
guessing. Open the menu and run **Doctor** to see the current state.

## Uninstall

```sh
brew uninstall --cask sturgeon
```

That removes the app, its helper and its background service, and restores Stage Manager to stock.
Add `--zap` to remove its cached state as well.

## Learn more

How it works and what it supports: [docs/TECHNICAL.md](docs/TECHNICAL.md).

GPL-3.0 — see [LICENSE](LICENSE).
