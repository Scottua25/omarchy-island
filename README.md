<h1 align="center">omarchy-island</h1>

<p align="center"><b>A dynamic island for <a href="https://omarchy.org">Omarchy</a>.</b><br>
The bar becomes a single pill at the top of the screen that grows into whatever is happening:<br>
music, notifications, volume, a control center, your screenshots, a shelf for files.</p>

<p align="center"><img src="docs/media/hero.webp" alt="omarchy-island: hover for quick actions, click for the control center" width="860"></p>

<p align="center">🎬 <a href="https://github.com/Liukskywalkerr/omarchy-island/releases/download/v1.0.0/omarchy-island-tour.mp4"><b>Watch the 3-minute tour</b></a> · <a href="https://github.com/Liukskywalkerr/omarchy-island/releases/download/v1.0.0/omarchy-island-short.mp4">20-second short</a></p>

## What it does

| | |
|---|---|
| **At rest** | Just the time. Things that are *on* appear beside it as small satellites — caffeine, Do Not Disturb, a shelf with files, low battery — and the pill grows little "ears" for music, recording, timers and the mic/camera privacy dots. |
| **Hover** | Quick actions: battery ring, screenshot, caffeine, Do Not Disturb. The clock and the satellites don't fade out — they *move* into place. |
| **Click** | The control center: Wi-Fi, Bluetooth, now playing, brightness and volume sliders, and every Omarchy panel one tap away. |
| **Notifications** | They live in the island, with their action buttons, grouped per app. Screenshots fly into the pill with a soft *bloop* and stay draggable. |
| **OSD** | Volume, brightness and every `omarchy osd` message. |
| **Shelf** | Drag files onto the pill, collect as many as you like, drag them all out at once (uses [OmaDrop](https://github.com/lucascnunes/omadrop)). |
| **Notch mode** | With a browser, or the gap between two windows, under the pill, the windows go all the way up and the pill sits in a notch cut into the window border. A terminal under the pill keeps the strip. |

Scroll on the pill for volume (<kbd>Shift</kbd> for brightness), middle-click to play/pause.

<table>
  <tr>
    <td width="50%"><img src="docs/media/notifications.webp" alt="Notifications"><br><sub><b>Notifications</b> take the shape they need, then fold back into the pill.</sub></td>
    <td width="50%"><img src="docs/media/music.webp" alt="Now playing"><br><sub><b>Now playing</b>: cover and equalizer at rest, a compact player on hover.</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/media/notch.webp" alt="Browser mode and screenshots"><br><sub><b>Browser mode</b>: the pill sits in a notch. Screenshots fly in, still draggable.</sub></td>
    <td width="50%"><img src="docs/media/dashboard.png" alt="Control center"><br><sub><b>Control center</b>: toggles, now playing, sliders and every Omarchy panel.</sub></td>
  </tr>
</table>

## Install

Requires **Omarchy 4.5 or newer** (the Quickshell-based shell).

```bash
    git clone https://github.com/Scottua25/omarchy-island ~/.local/share/omarchy-island
~/.local/share/omarchy-island/install.sh
```

The installer clones the Omarchy plugins the island takes over with
`omarchy plugin clone`, rebuilds them from *your* Omarchy version plus the
island's changes, installs a systemd user service and an Omarchy post-update
hook. Your `shell.json` is backed up first.

**Uninstall** — everything goes back the way it was:

```bash
~/.local/share/omarchy-island/uninstall.sh
```

**Update**

```bash
cd ~/.local/share/omarchy-island && git pull && ./install.sh
```

### Optional

- **[OmaDrop](https://github.com/lucascnunes/omadrop)** enables the shelf;
  **[omastats](https://github.com/crmne/omastats)** and
  **[Mirador](https://github.com/sanjyay/Mirador)** get the island look and a
  tile in the control center when installed.
- **SF Pro** is used if you have it installed (Apple's fonts can't be shipped);
  otherwise the island uses your system sans-serif.
- **Three-finger gestures** for the dashboard and Mirador: see
  [`extras/island-gesture`](extras/island-gesture).

## Surviving Omarchy updates

The island never edits Omarchy's own files. The panels it restyles are
clones, and after every `omarchy update` (and every time the island starts)
`tools/island-sync` rebuilds them from the new Omarchy version with a
three-way merge of the island's changes. Omarchy's fixes keep flowing in. If a
change can't be applied any more, that panel falls back to Omarchy's version and
you get a notification. If the island itself fails to start, the regular
Omarchy bar comes back on its own.

## Handy commands

```bash
systemctl --user restart omarchy-island          # restart
journalctl --user -u omarchy-island -f           # log
qs -c island ipc call island toggle              # open/close the control center
qs -c island ipc call island test notify         # also: volume, brightness, shelf, ws, shot:<png>
```

### Island settings

Create `~/.config/omarchy-island/settings.json` to customize the clock and notch. Changes reload on save:

```json
{
  "clockFormat": "h:mm AP",
  "notchScale": 0.95,
  "notchMode": "all",
  "position": "top-center"
}
```

- `clockFormat`: Qt time format, for example `h:mm AP` for 12-hour time or `HH:mm` for 24-hour time.
- `notchScale`: notch size relative to the normal pill; values are limited to 0.5–1.0.
- `notchMode`: `all` allows tiled windows to reach the top (the island may cover content); `browser` uses the original browser and window-gap behavior; `off` reserves space for the island. `ISLAND_NOTCH=off` takes precedence.
- `position`: `top-left`, `top-center`, `top-right`, `bottom-left`, `bottom-center`, or `bottom-right`. Bottom positions can overlap a bottom dock.

The values above are also the defaults if the file is absent. Invalid JSON leaves the last valid settings active. This file is separate from the checkout and survives updates.

### Borders

The island and its flyouts read Hyprland's active/inactive border colors,
gradient angle, border width and rounding, and refresh them after Hyprland
configuration or theme changes. Screen-attached edges keep their square shape.
The gradient border renderer uses Qt 6.12 or newer.

### Environment options

Set them in a drop-in (`systemctl --user edit omarchy-island`, `[Service]` → `Environment=…`):

| Variable | Effect |
|---|---|
| `ISLAND_PLAYERS=spotify\|mpv` | only these media players (regex on D-Bus name / identity) |
| `ISLAND_CAM_IGNORE="ffmpeg my-cam*"` | processes that don't count as "camera in use" (virtual-camera pipelines) |
| `ISLAND_DEMO=1` | generic Wi-Fi and Bluetooth names, for screen recordings |

The island follows your Omarchy theme and the `animations` toggle, and speaks
English or Italian depending on your locale — more languages welcome in
[`quickshell/I18n.js`](quickshell/I18n.js).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits & license

Built on [Omarchy](https://github.com/basecamp/omarchy) and
[Quickshell](https://quickshell.org); see [CREDITS.md](CREDITS.md).
MIT licensed.
