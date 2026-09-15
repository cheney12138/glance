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
never on a timer. The panel dismisses instantly on every exit path.

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
- **Updates itself.** A scheduled check fetches a signed appcast from GitHub — the only network
  request Glance ever makes. 「检查更新…」 in the menu bar checks on demand.

## Requirements

- macOS 14 or later.
- Building from source: Xcode 26 or later. A free Apple ID (Personal Team) is enough —
  no paid developer account.

## Download

Signed builds are on the [Releases page](https://github.com/cheney12138/glance/releases/latest).
Download `Glance-x.y.z.dmg`, drag `Glance.app` into **Applications**, then grant the two
permissions below.

The build is signed but **not notarized** (notarization needs a paid Apple Developer account),
so the first launch needs one extra step — see *Updating*.

## Build and run

```bash
git clone https://github.com/cheney12138/glance.git
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

- **No analytics, no telemetry, no accounts.** Nothing about you or your windows is ever sent
  anywhere.
- **One network request: the update check.** The updater (Sparkle) fetches a signed appcast from
  GitHub when a scheduled check is due and when you choose 「检查更新…」. The request reports the
  version it is running and (if there is a newer one) downloads the DMG — nothing else. Turn it
  off with `defaults write com.cheney12138.macswitcher SUEnableAutomaticChecks -bool false`.
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

**「检查更新…」 reports an error.** Two different failures with two different causes:

- *"The updater failed to start"* — the build's `SUPublicEDKey` is not a valid key (a valid
  Ed25519 public key is 44 base64 characters). Rebuild. The alert never says why; the reason is
  in the system log: `log show --last 15m --predicate 'process == "Glance"'`.
- *"An error occurred in retrieving update information"* — the appcast could not be fetched,
  which almost always means the newest GitHub release is missing `appcast.xml` (the app looks it
  up at `releases/latest/download/appcast.xml`).

Scheduled checks fail silently by design; only a manual check reports an error.

## Updating

Glance updates itself. It checks a signed appcast once a day (and whenever you choose
「检查更新…」 in the menu bar); when a newer build exists, Sparkle offers it, verifies the EdDSA
signature against the public key in `Info.plist`, and installs it in place. Sparkle-downloaded
updates are not quarantined, so they need no extra step.

To update by hand — for instance for the first install from the Releases page:

1. Quit Glance (menu bar icon ▸ **Quit**, or `pkill -TERM Glance`).
2. Open the new DMG and drag `Glance.app` into **Applications**, replacing the old copy.
3. Launch it.

**Your settings and permissions survive.** The bundle identifier and the signing identity do
not change between builds, so macOS keeps the Accessibility and Screen Recording grants and
Glance keeps its preferences.

**Keep only one copy.** Two builds of Glance in different folders (say `/Applications` and an
Xcode build) are the *same app* to macOS — only one can run, and the second one exits at
startup with a message naming the instance that is already running.

If macOS refuses to open a downloaded copy — *"cannot be opened because Apple cannot check it for
malicious software"* — the browser quarantined it, and the build is signed but not notarized
(notarization needs a paid Apple Developer account). Two ways through:

- **Recommended:** remove the quarantine flag, then open the app normally:

```bash
xattr -dr com.apple.quarantine /Applications/Glance.app
```
- Or approve it in the UI: **System Settings ▸ Privacy & Security**, scroll to the note about
  "Glance" being blocked, and click **Open Anyway**.


Note for macOS 15 and later: **right-click ▸ Open no longer bypasses this** — that trick worked
up to macOS 14.

```bash
xattr -dr com.apple.quarantine /Applications/Glance.app
```

### Releasing (maintainers)

```bash
bash Tools/release.sh 0.2.0     # 构建 universal DMG → EdDSA 签名 → 写出 appcast.xml
```

Then publish the release with the GitHub CLI — **both** assets, tag exactly `v0.2.0`, asset name
exactly `Glance-0.2.0.dmg` (the appcast spells both out in its download URL):

```bash
gh release create v0.2.0 ~/Desktop/Glance-0.2.0.dmg ~/Desktop/appcast.xml --title "Glance 0.2.0"
```

The app's feed URL points at `releases/latest/download/appcast.xml`, so the appcast must be on
the newest release — without it, update checking breaks (silently, for automatic checks).

Updates are authenticated with Sparkle's EdDSA key: the private key lives in the maintainer's
login keychain (account `glance`), the public key in `Info.plist`. **No Apple Developer account
is required.** Only the very first install needs the quarantine workaround above, because a
browser still tags the DMG it downloads.

**Never hand-copy the public key.** One wrong character is enough to make Sparkle fail at
startup, and the alert does not say why. Read it back from the keychain instead:

```bash
~/Library/Caches/glance-sparkle/bin/generate_keys -p --account glance   # 打印公钥,应为 44 字符
/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Glance.app/Contents/Info.plist | wc -c
```

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
