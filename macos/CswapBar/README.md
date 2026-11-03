# Claude Swap Bar (native macOS menu bar app)

A small SwiftUI menu bar app for claude-swap. Click the icon and a panel opens
with every account's 5-hour / 7-day usage (bars, reset countdowns, per-model
limits), the ChatGPT (Codex) plan usage, and buttons to switch accounts. The
menu bar itself shows the active account's 5h · 7d percentages.

The app is self-contained: `build-app.sh` puts a Python runtime
([python-build-standalone](https://github.com/astral-sh/python-build-standalone),
pinned and checksum-verified) with claude-swap from this checkout inside the
`.app`, and the app drives that copy (`list --json`, `chatgpt --json`,
`switch N`). Credentials, locking and API pacing are claude-swap's own code, so
nothing is reimplemented and **claude-swap does not need to be installed
separately**. Claude Code itself is still needed (it is what you log in with).

## Requirements

- macOS 13 (Ventura) or later
- Xcode or the Xcode Command Line Tools (`xcode-select --install`) to build
- Internet access while building (downloads the ~25 MB Python runtime once,
  then installs claude-swap's dependencies from PyPI)

## Build and install

```bash
cd macos/CswapBar
./build-app.sh --install     # builds, copies to /Applications, launches it
```

`./build-app.sh` alone leaves the app in `build/Claude Swap Bar.app` (about
85 MB). The app is ad-hoc signed, which is enough to run it on the Mac that
built it. To pick up a newer claude-swap, pull and run the script again.

### Using the same claude-swap from a terminal

The bundle contains a `cswap` launcher for its copy. Linking it onto your PATH
keeps the terminal and the app on one version:

```bash
mkdir -p ~/.local/bin
ln -sf "/Applications/Claude Swap Bar.app/Contents/Resources/bin/cswap" ~/.local/bin/cswap
```

If you already have claude-swap installed with uv/pipx, prefer one or the
other: both copies share the same data directory, and two different versions
working on it is not something claude-swap is tested for.

## Using it

- **Click the icon**: the panel opens under it. The active account is
  expanded; click any other account to expand it.
- **Header** (always visible): Refresh, Settings, Quit. Refresh re-reads
  cswap now; Claude usage is still paced by cswap (an account is fetched at
  most every few minutes), ChatGPT usage is fetched again immediately.
- **Add account**: opens Terminal, runs `claude auth login` (sign in in the
  browser with the account to add) and imports the login with `cswap add`.
  The current login is saved first so it is not lost. Claude Code stays
  signed in to the new account; switch back from the list. If Claude Code is
  already signed in to the account, *Import current login* does it without
  Terminal.
- **On an account**: *Switch*, *Sign in again…* (same Terminal flow,
  pre-filled with the account's email, for an expired login) and the trash
  button to remove it from Claude Swap.
- **Switch to best**: moves to the account with the most quota left
  (`cswap switch --strategy best`).
- **Bars** are green under 50%, amber to 75%, orange to 90%, red above; each
  window shows the time left and the reset date and time.

Only full Claude logins show usage: setup-tokens are inference-only (Claude
Code itself reads usage only for tokens with the `user:profile` scope) and API
keys have no plan quota. The app therefore adds accounts by signing in; tokens
and API keys can still be added from the command line with
`cswap setup-token`, and switch like any other account.

The panel re-reads cswap every 60 seconds and ChatGPT every 5 minutes.

## Relation to `cswap menubar`

`cswap menubar` is the Python (rumps) menu bar with a classic drop-down menu
and the background auto-switch engine. This app is a separate, native
alternative with a richer panel. It has no auto-switch engine of its own:
run `cswap auto` (or keep `cswap menubar` with auto-switch on) for that.
Running both menu bar items at once works but shows two icons.
