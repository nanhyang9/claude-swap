# macOS widget: feasibility review

Question: can claude-swap's usage (Claude accounts, and now ChatGPT/Codex) be
shown as a macOS widget — Notification Center, or on the desktop (macOS 14+)?

## Short answer

Yes, but not from Python. A real macOS widget is a WidgetKit extension: SwiftUI
code inside a signed `.app` bundle. claude-swap would need a small native
companion app. There is a much cheaper route (Übersicht) that works today
with no change to claude-swap.

## Option A — native WidgetKit widget

**What it takes**

- A Swift/SwiftUI *Widget Extension* target, embedded in a containing `.app`
  (it can be a tiny app whose only job is to host the widget). Built with Xcode.
- App extensions on macOS run in the App Sandbox. The widget therefore
  **cannot** run `cswap`, read `~/.claude-swap-backup` /
  `~/.local/share/claude-swap`, or read the Keychain items cswap uses.
- So data has to be handed over: something outside the sandbox (the existing
  `cswap menubar` process is the natural writer, since it already refreshes on
  a timer) writes a small JSON snapshot into the App Group container
  (`~/Library/Group Containers/<TEAMID>.<group>/`), and the widget reads it in
  its `TimelineProvider`.
- Widgets do not run continuously. They render a timeline of entries, and
  macOS decides when to reload it within a budget. Reset countdowns can still
  tick live with `Text(date, style: .relative/.timer)`. An immediate reload
  needs `WidgetCenter.reloadTimelines`, which is a Swift API — the Python
  menu bar process can't call it directly, so freshness depends on the
  timeline policy unless the companion app also runs.
- Buttons in widgets (macOS 14+, App Intents) execute in the sandboxed
  extension, so "switch account" from the widget would need a hand-off back to
  an unsandboxed process (URL scheme → companion app → `cswap switch`).

**Cost / risks**

- Signing: a free Apple ID "Personal Team" in Xcode is enough to build and run
  it on your own Mac; distributing it to others needs a paid Developer ID and
  notarization. App Group identifiers are tied to the team.
- Writing into another app's group container from an unrelated process may
  trigger macOS's app-data privacy prompt on recent releases; this needs to be
  tested on the target macOS version before committing to the design.
- A second language/toolchain (Swift + Xcode project) in a Python repo, plus
  CI that only runs on macOS.

**Estimate**: a read-only widget (accounts + 5h/7d bars + ChatGPT section,
reading a snapshot JSON) is a small Swift project; the snapshot writer on the
cswap side is a few dozen lines in `menubar.py`. Interactive switching is a
separate, larger step.

## Option B — Übersicht desktop widget (works now)

[Übersicht](https://tracesof.net/uebersicht/) is a free, open-source app that
renders desktop widgets written in JSX and fed by shell commands. Because it is
not sandboxed it can simply run `cswap … --json`. Drop a file such as the one
below into `~/Library/Application Support/Übersicht/widgets/cswap.jsx`.

> This sample was written against Übersicht's documented widget format
> (`command`, `refreshFrequency`, `className`, `render`) but has not been run
> here. Adjust `CSWAP` to the output of `which cswap` — Übersicht does not use
> your shell's PATH.

```jsx
export const command = `
  CSWAP="$HOME/.local/bin/cswap"
  "$CSWAP" list --json 2>/dev/null
  echo "@@CSWAP@@"
  "$CSWAP" chatgpt --json 2>/dev/null
`;

export const refreshFrequency = 5 * 60 * 1000; // ms

export const className = `
  top: 20px; left: 20px;
  font: 12px -apple-system, sans-serif; color: #fff;
  background: rgba(0, 0, 0, 0.45);
  padding: 10px 14px; border-radius: 10px;
`;

const parse = (text) => {
  try { return JSON.parse(text); } catch (e) { return null; }
};
const pct = (w) => (w ? Math.round(w.pct) + "%" : "–");

export const render = ({ output }) => {
  const parts = (output || "").split("@@CSWAP@@");
  const claude = parse(parts[0]);
  const gpt = parse(parts[1] || "");
  const accounts = (claude && claude.accounts) || [];
  const gptWindows =
    gpt && gpt.limits && gpt.limits.length ? gpt.limits[0].windows : [];
  return (
    <div>
      <b>Claude</b>
      {accounts.map((a) => (
        <div key={a.number}>
          {a.active ? "● " : "○ "}
          {a.alias || a.email}: 5h {pct(a.usage && a.usage.fiveHour)} · 7d{" "}
          {pct(a.usage && a.usage.sevenDay)}
        </div>
      ))}
      {gptWindows.length > 0 && <b>ChatGPT {gpt.plan ? "(" + gpt.plan + ")" : ""}</b>}
      {gptWindows.map((w) => (
        <div key={w.label}>
          {w.label}: {Math.round(w.usedPercent)}%
        </div>
      ))}
    </div>
  );
};
```

`cswap list --json` serves usage from cswap's paced cache, so a widget polling
every few minutes does not add API pressure beyond what the menu bar already
does.

## Option C — the existing menu bar

`cswap menubar` already shows every account (and now the ChatGPT section) one
click away and can run under launchd (`--install-service`). For "always
visible" numbers, its title can show the active account's 5h/7d percentages.

## Recommendation

1. Use **Übersicht** (Option B) if a desktop widget is wanted now — zero
   changes to claude-swap, works with both `list --json` and `chatgpt --json`.
2. Build **WidgetKit** (Option A) only if a native Notification Center /
   desktop widget is a requirement. Start read-only: add a snapshot-JSON writer
   to the menu bar process, verify on the target macOS version that writing
   into the App Group container works without a privacy prompt, then build
   the Swift widget against that file.
