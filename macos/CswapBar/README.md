# Claude Swap Bar (native macOS menu bar app)

A small SwiftUI menu bar app for claude-swap. Click the icon and a panel opens
with every account's 5-hour / 7-day usage (bars, reset countdowns, per-model
limits), the ChatGPT (Codex) plan usage, and buttons to switch accounts. The
menu bar itself shows the active account's 5h · 7d percentages.

It is a front end only: all data and actions go through the `cswap` command
(`cswap list --json`, `cswap chatgpt --json`, `cswap switch N`), so credentials,
locking and API pacing stay in claude-swap. That means **claude-swap must be
installed** (with the ChatGPT command, i.e. a version that has `cswap chatgpt`).

## Requirements

- macOS 13 (Ventura) or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`) for `swift`
- claude-swap installed, e.g. `uv tool install claude-swap`

## Build and install

```bash
cd macos/CswapBar
./build-app.sh --install     # builds, copies to /Applications, launches it
```

`./build-app.sh` alone leaves the app in `build/Claude Swap Bar.app`. The app
is ad-hoc signed, which is enough to run it on the Mac that built it.

## Using it

- **Click the icon**: the panel opens. The active account is expanded; click
  any other account to expand it and switch to it.
- **Switch to best**: moves to the account with the most quota left
  (`cswap switch --strategy best`).
- **Refresh**: re-reads cswap now. Claude usage is still paced by cswap
  (an account is fetched at most every few minutes), ChatGPT usage is
  fetched again immediately.
- **Settings** (gear): show/hide ChatGPT, launch at login, and the path to
  `cswap` if it is not found automatically (it looks in `~/.local/bin`,
  `/opt/homebrew/bin`, `/usr/local/bin`, then asks your login shell).

The panel re-reads cswap every 60 seconds and ChatGPT every 5 minutes.

## Relation to `cswap menubar`

`cswap menubar` is the Python (rumps) menu bar with a classic drop-down menu
and the background auto-switch engine. This app is a separate, native
alternative with a richer panel. It has no auto-switch engine of its own:
run `cswap auto` (or keep `cswap menubar` with auto-switch on) for that.
Running both menu bar items at once works but shows two icons.
