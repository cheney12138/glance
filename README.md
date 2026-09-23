<p align="center">
  <img src="docs/assets/icon.png" alt="Glance logo" width="110" />
  <br>
  <img src="docs/assets/wordmark.png" alt="glance" width="240" />
</p>

A per-display macOS app switcher. Each screen has its own switcher, and confirming
focuses **that specific window** — not the whole app.

<!-- demo: a 3-second GIF goes here (record it, drop it in docs/assets/, reference it here) -->

## Install

With Homebrew:

```sh
brew trust cheney12138/tap
brew install --cask cheney12138/tap/glance
```

Without Homebrew: download the DMG from
[Releases](https://github.com/cheney12138/glance/releases), drag it into Applications,
then trust it once:

```sh
xattr -dr com.apple.quarantine "/Applications/Glance.app"
```

> **Why the extra step.** Glance is signed but not notarized, so macOS refuses to open it
> once. The command above clears that flag; if you prefer the UI, use
> **System Settings ▸ Privacy & Security ▸ Open Anyway**.
> After that Glance updates itself and never asks again.

Requires **macOS 14** or later · Apple Silicon and Intel.

## What it does

- **Each screen gets its own switcher.** Hold `⌥` and press `Tab`: you see only the
  apps and windows on the screen your pointer is on — not every window you own.
- **It focuses the window you picked**, not just the app. No other windows jump to
  the front, and nothing lands on the wrong display.
- **Instant, because nothing is captured on the way in.** Every preview is already
  there when the panel appears.
- **`⌃⌃` carries your working context to the other display** — the pointer to the
  centre of that screen, the keyboard to the window in front there. Keep typing.
- **`⌘⇧M` sends the window you are using to the other display** — no panel needed,
  and the shortcut can be re-recorded in Settings.

**Keys** — `←` `→` first/last app · `Tab` next app · `1`–`9` pick a window ·
`` ` `` cycle windows · `Q` `W` `M` `F` `H` act on the selected window ·
release `⌥` to switch, `Esc` to cancel.

## Updating

Glance updates itself: menu ▸ **Check for Updates…**, and once a day in the
background. Updates it installs are not quarantined, so the step above is a
one-time thing.

## Issues

[github.com/cheney12138/glance/issues](https://github.com/cheney12138/glance/issues)
