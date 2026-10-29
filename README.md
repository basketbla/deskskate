# DeskSkate

A little skateboarder that lives on your Mac desktop. It rolls along the tops of your real
windows, rides them when you drag them, gets launched when you flick one upward, and falls when
you pull one out from under it. Drop quarter pipes, kickers, rails and boxes on the desktop from
the menu bar and drag them wherever you like.

No permissions needed for windows: positions come from the window server, titles are never read.
Desktop icons are ledges too (menu: **Skate on Desktop Icons**); for that macOS asks once to let
DeskSkate control Finder, which is the only place icon positions come from.

## Run

```sh
scripts/bundle.sh --open   # builds DeskSkate.app, installs it to /Applications and launches it
swift run simcheck         # headless physics scenarios
```

## Modes

- **Autonomous** (default): the skater cruises, ollies onto ledges, flips off ramps and grinds
  rails on its own. After a while on the floor it drops back in from the top of a screen.
- **Keyboard**: `⌘⌥S` (or the menu) hands the keyboard to the skater and shows a controls card
  (`/` hides it). `Esc` gives the keyboard back to the app you were in. Clicking another app keeps
  keyboard mode; `⌘⌥S` takes the keys back.

| Key | |
|---|---|
| ← → / A D | push and turn |
| Space | hold to crouch, release to ollie |
| ↑ / W / F | flip trick (in the air) |
| ↓ / S | hold to grind on landing |
| R | respawn at the mouse |
| / | show / hide the controls card |
| Esc | back to autonomous |
| ⌃⌥H | hide / show |

Grab the skater with the mouse to pick him up; drop or throw him onto a window.

Obstacles: drag them anywhere; right-click to flip or remove. They are saved between launches.
**Obstacle Gravity** in the menu makes them fall onto window tops (and ride the window) or the
floor. When the Dock slides up, its top is a floor too.
