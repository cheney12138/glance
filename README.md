<div align="center">
  <img src="docs/assets/icon.png" width="112" alt="Glance">
  <h1>Glance</h1>
  <p><b>A window-level app switcher for macOS.</b><br>
  Only the display your pointer is on. Only the window you pick.</p>
</div>

---

## Overview

Glance replaces the app-level model of <kbd>⌘</kbd><kbd>Tab</kbd> with windows.

Hold the trigger and a strip of running apps appears on the display where your pointer is.
The windows of the selected app are laid out in a tray below it, as live previews. Picking a
window raises **that window** — the app does not simply come forward with whichever window it
would have preferred.

Everything stays on the machine and stays quiet. Previews are captured when windows change,
never on a timer. The panel dismisses instantly on every exit path. Glance contains no
networking code.

## Highlights

- **Window level, not app level.** Every card is a real window; confirming focuses it directly.
- **Single-display scope.** Only the windows of the display under your pointer — with several
  monitors, the switcher never mixes them.
- **Live previews, event-driven.** Previews refresh when the window inventory changes or an app
  becomes active. No polling, no idle timers.
- **Stale entries are filtered out.** The inventory is cross-checked, so ghost windows
  (a closed browser window the system still reports) never show up as empty cards.
- **Window actions without leaving the switcher.** Quit, close, minimize, fullscreen and hide
  are handled in place — the panel stays open, and the order of the strip does not jump around.
- **Hold to navigate, release to confirm.** Or turn on *Keep the panel open* to click and act
  at leisure.
- **Yields to screenshot tools.** While a screen-capture session is active, navigation keys
  belong to the capture tool, not to Glance.
- **Optional <kbd>⌘</kbd><kbd>Tab</kbd> takeover.** Off by default; the trigger is
  <kbd>⌥</kbd><kbd>Tab</kbd> unless you ask for more.
- **Quiet by design.** No bounce, no ripple, no confirmation flourish. Motion follows the
  system *Reduce Motion* setting, with an explicit override if you want the full animation.

## Requirements

- macOS 14 or later.
- Building from source: Xcode 26 or later. A free Apple ID (Personal Team) is enough —
  no paid developer account.

## Build and run

```bash
git clone https://github.com/cheney12138/Glance.git
cd Glance
open Glance.xcodeproj          # then ⌘R
```

**Sign once, or macOS re-asks for permissions after every build.** Permissions are anchored to
the signing certificate; with no team, Xcode falls back to ad-hoc signing, whose hash changes
on each build.

1. Xcode ▸ Settings ▸ Accounts ▸ `+` ▸ sign in with a free Apple ID.
2. Project ▸ **Glance** target ▸ Signing & Capabilities ▸ Team ▸ select your Personal Team.

Checks:

```bash
swift test --package-path Packages/GlanceCore   # pure-core unit tests
swift Tools/check-architecture.swift            # module boundary check
```

## Permissions

| Permission | Used for | Without it |
|---|---|---|
| **Accessibility** | Reading the window list and focusing the selected window | Glance cannot switch at all |
| **Screen Recording** | Capturing window previews | No window previews |

Grant both in **System Settings ▸ Privacy & Security**. If the state gets confused (for example
after re-signing), reset and restart the app:

```bash
tccutil reset Accessibility com.cheney12138.macswitcher
tccutil reset ScreenCapture  com.cheney12138.macswitcher
```

## Using Glance

The trigger defaults to <kbd>⌥</kbd><kbd>Tab</kbd> and is configurable in Settings. Hold it,
then:

| Keys | Action |
|---|---|
| <kbd>Tab</kbd> / <kbd>⇧</kbd><kbd>Tab</kbd> | Next / previous app |
| <kbd>←</kbd> / <kbd>→</kbd> | Next / previous window of the selected app |
| <kbd>&#96;</kbd> | Cycle windows of the selected app (optional, off by default) |
| <kbd>↩</kbd> | Open the selected window |
| <kbd>Esc</kbd> | Dismiss without switching |
| <kbd>Q</kbd> / <kbd>W</kbd> / <kbd>M</kbd> | Quit app / close window / minimize window |
| <kbd>F</kbd> / <kbd>H</kbd> | Toggle fullscreen / hide app |
| Release the trigger | Open the selected window |

Mouse works throughout: move the pointer onto a card to select it, click to open it, click
outside the panel to dismiss.

## Preferences

| Group | Setting | Effect |
|---|---|---|
| Appearance | **Color appearance** | System / light / dark, applied to the panel and the settings window |
| | **Icon spacing** | Distance between the selected icon and its neighbours |
| Startup & behavior | **Launch at login** | Start Glance automatically |
| | **Keep the panel open** | Off: releasing the trigger confirms and closes |
| Motion | **Reduce Motion** | Read-out of the system setting |
| | **Always animate** | Ignore *Reduce Motion* and play the full animation |
| | **Sheen** | Pointer-following highlight and per-icon shading |
| | **Pick up the last selection** | Off: the marker only rises, without sliding from the previous app |
| Trigger | **Take over ⌘Tab** | Opt-in; see *Troubleshooting* |
| | **Advance on open** | Off: the selection stays on the current app |
| | **Trigger** | The key combination that opens the panel |
| Navigation | **Cycle windows with `` ` ``** | Only while the panel is open |
| | **Cycle apps** / **Switch windows** / **Confirm · cancel** | Key reference |
| Window actions | **Quit · close · minimize** / **Fullscreen · hide** | Key reference |

## Privacy

- **No network.** Glance contains no networking code and sends nothing anywhere.
- **Window titles and previews stay in memory** for the duration of a session.
- **Preferences** live in the app's `UserDefaults` (appearance, trigger, switches, window frames).
- **One additional file** is written: a small marker in
  `~/Library/Application Support/Glance`, so Glance can restore the system
  <kbd>⌘</kbd><kbd>Tab</kbd> shortcut after an unclean exit (see below). It is removed as soon as
  the shortcut is restored.

## Troubleshooting

**<kbd>⌘</kbd><kbd>Tab</kbd> does nothing.** This can only happen if you enabled *Take over
⌘Tab*. Taking over disables a **system-level** shortcut, and that state persists after the app
exits. If the app is killed without a chance to restore it — Xcode's Stop button, Force Quit —
the system shortcut stays disabled, and once Glance is not running nothing is left to put it
back. Give it back to macOS with:

```bash
swift Tools/NativeHotkeys.swift restore
```

Glance notices this situation on the next launch: it restores the shortcut and logs
`[T13] 上次退出没来得及归还原生热键(强杀)——本次启动已自愈`
("the previous exit did not restore the native hotkeys (killed) — self-healed on this launch").

**When developing, stop the app with `pkill -TERM Glance`** rather than Xcode's Stop button.
A signal lets Glance restore the shortcut on the way out; `SIGKILL` does not.

**The panel does not appear.** Check both permissions above, then reset them with the
`tccutil` commands and restart the app.

## Project layout

```
Sources/Glance/          App target — panel, trigger layer, inventory, settings
  Panel/                 Panel windows, layout, controller
  Trigger/               Event taps, hotkeys, session rules
  Inventory/             Window enumeration, thumbnails
  Settings/              Settings window
  Design/                Design tokens (metrics, colors, motion)
Packages/GlanceCore/     Pure core: rule engines, no AppKit, unit-tested
Tools/                   Developer utilities (hotkey restore, capture, key injection, checks)
design/                  Visual contracts and experiments
docs/                    Architecture, ADRs, debugging handbook, task index
```

## Documentation

The working documentation is written in Chinese:

| Document | Contents |
|---|---|
| [`docs/architecture.md`](docs/architecture.md) | Module boundaries and the pure-core rule |
| [`docs/adr/`](docs/adr/) | Decision records |
| [`docs/debugging.md`](docs/debugging.md) | Measurement recipes and known failure modes |
| [`docs/tasks.md`](docs/tasks.md) | Task index with evidence for each change |
| [`design/`](design/) | Visual contracts, tokens and experiment pages |

## Known limits

- No in-panel search.
- No per-app exception list yet.
- Previews require Screen Recording.
- Scope is deliberately limited to the display the pointer is on.
- <kbd>⌘</kbd><kbd>`</kbd> (cycle windows of the frontmost app) is intentionally left to macOS.
