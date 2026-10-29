# DeskSkate

A little skateboarder that lives on your Mac desktop. It rolls along the tops of your real
windows, rides them when you drag them, gets launched when you flick one upward, and falls when
you pull one out from under it. Drop quarter pipes, kickers, rails and boxes on the desktop from
the menu bar and drag them wherever you like.

No permissions needed: window positions come from the window server, titles are never read.

## Run

```sh
scripts/bundle.sh --open   # builds build/DeskSkate.app and launches it (menu bar icon, no Dock icon)
swift run simcheck         # headless physics scenarios
```

## Modes

- **Autonomous** (default): the skater cruises, ollies onto ledges, flips off ramps and grinds
  rails on its own. After a while on the floor it drops back in from the top of a screen.
- **Keyboard**: `⌃⌥S` (or the menu) hands the keyboard to the skater. `Esc` or `⌃⌥S` gives it
  back to the app you were in. Clicking another app also switches back to autonomous.

| Key | |
|---|---|
| ← → / A D | push and turn |
| Space | hold to crouch, release to ollie |
| ↑ / W / F | flip trick (in the air) |
| ↓ / S | hold to grind on landing |
| R | respawn at the mouse |
| Esc | back to autonomous |
| ⌃⌥H | hide / show |

Obstacles: drag them anywhere; right-click to flip or remove. They are saved between launches.
