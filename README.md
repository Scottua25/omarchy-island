<h1 align="center">omarchy-island</h1>

<p align="center"><b>A dynamic island for <a href="https://omarchy.org">Omarchy</a>.</b><br>
The bar becomes a single island that grows into whatever is happening:<br>
music, notifications, volume, a control center, your screenshots, a shelf for files.</p>

> **This is an independently maintained fork**, not the original project.
> The original is [Liukskywalkerr/omarchy-island](https://github.com/Liukskywalkerr/omarchy-island).
> This fork adds configurable screen positions, clock and notch settings,
> Hyprland-matched borders, and changes to panel and hover behavior. Changes to
> the original repository are not automatically applied to this fork.

<p align="center"><img src="docs/media/hero.webp" alt="omarchy-island: hover for quick actions, click for the control center" width="860"></p>

<p align="center">🎬 Original project: <a href="https://github.com/Liukskywalkerr/omarchy-island/releases/download/v1.0.0/omarchy-island-tour.mp4"><b>3-minute tour</b></a> · <a href="https://github.com/Liukskywalkerr/omarchy-island/releases/download/v1.0.0/omarchy-island-short.mp4">20-second short</a></p>

The images and videos show the original project; some layouts and behavior in
this fork differ.

## What it does

| | |
|---|---|
| **At rest** | The time and active indicators, including caffeine and Do Not Disturb, with space for music, recording, timers and microphone/camera privacy indicators. In a corner, the indicators sit beside the clock toward the screen's center. |
| **Hover** | Quick actions for power, screenshots, caffeine and Do Not Disturb, or a compact player when media is available. In a corner, the full quick-action order from the screen edge is time, caffeine, Do Not Disturb, screenshot, power. Center positions keep the original order. |
| **Click** | The control center: Wi-Fi, Bluetooth, now playing, brightness and volume sliders, and Omarchy panels one tap away. Selected panels animate directly from the open control center. |
| **Notifications** | They live in the island, with their action buttons, grouped per app. Screenshots fly into the pill with a soft *bloop* and stay draggable. |
| **OSD** | Volume, brightness and every `omarchy osd` message. |
| **Shelf** | Drag files onto the pill, collect as many as you like, drag them all out at once (uses [OmaDrop](https://github.com/lucascnunes/omadrop)). |
| **Position and notch** | Choose the left corner, center or right corner of either screen edge. By default, tiled windows can reach the edge beneath the island; the notch follows the window border and includes active caffeine and Do Not Disturb indicators. |

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

Requires **Omarchy 4.5 or newer** (the Quickshell-based shell) and **Qt 6.12
or newer** for the gradient border renderer. Run the installer from an active
Omarchy desktop session.

```bash
git clone https://github.com/Scottua25/omarchy-island ~/.local/share/omarchy-island
~/.local/share/omarchy-island/install.sh
```

The installer clones the Omarchy plugins the island takes over with
`omarchy plugin clone`, rebuilds them from *your* Omarchy version plus the
island's changes, installs a systemd user service and an Omarchy post-update
hook. Your `shell.json` is backed up first.

**Uninstall** — removes the island service and installer-created clones and
restores the saved shell configuration:

```bash
~/.local/share/omarchy-island/uninstall.sh
```

Pre-existing plugin clones are kept and may retain island styling. The separate
island settings file is also kept. Use `uninstall.sh --keep-config` to retain
the current shell configuration instead of restoring the backup.

**Update this fork**

```bash
cd ~/.local/share/omarchy-island && git pull && ./install.sh
```

This updates from the checkout's configured Git remote. A checkout made with
the clone command above tracks this fork; changes from the original project
must be incorporated separately.

### Optional

- **[OmaDrop](https://github.com/lucascnunes/omadrop)** enables the shelf;
  **[omastats](https://github.com/crmne/omastats)** and
  **[Mirador](https://github.com/sanjyay/Mirador)** get the island look and a
  tile in the control center when installed.
- **SF Pro** is used if you have it installed (Apple's fonts can't be shipped);
  otherwise the island uses your system sans-serif.
- **Three-finger gestures** for the dashboard and Mirador: see
  [`extras/island-gesture`](extras/island-gesture).

## Omarchy updates

The island never edits Omarchy's own files. The panels it restyles are
clones, and after every `omarchy update` (and every time the island starts)
`tools/island-sync` rebuilds them from the new Omarchy version with a
three-way merge of the island's changes. This brings in changes to the installed
Omarchy plugins; it does not pull changes from the original island repository.
If a change can't be applied, that panel falls back to Omarchy's version and
you get a notification. If the island itself fails to start, the regular
Omarchy bar comes back on its own.

## Handy commands

```bash
systemctl --user restart omarchy-island          # restart
journalctl --user -u omarchy-island -f           # log
qs -c island ipc call island toggle              # open/close the control center
qs -c island ipc call island test notify         # also: volume, brightness, shelf, ws, shot:<png>
```

## Settings

Create `~/.config/omarchy-island/settings.json` to customize the island. Create
the `~/.config/omarchy-island/` directory first if needed. Changes reload on
save; restarting the service is not normally necessary:

```json
{
  "clockFormat": "h:mm AP",
  "notchScale": 0.95,
  "notchMode": "all",
  "position": "top-center"
}
```

- `clockFormat`: a Qt time format, such as `h:mm AP` for 12-hour time with
  AM/PM or `HH:mm` for 24-hour time.
- `notchScale`: the notch size relative to the normal island, from `0.5` to
  `1.0`. The default is `0.95`.
- `notchMode`: `all` allows tiled windows to reach the island's screen edge,
  including terminals; the island may cover content. `browser` uses the
  original browser and window-gap rule. `off` reserves space for the island.
  `ISLAND_NOTCH=off` overrides this setting.
- `position`: `top-left`, `top-center`, `top-right`, `bottom-left`,
  `bottom-center`, or `bottom-right`. The default is `top-center`; bottom
  positions can overlap a bottom dock.

The values above are the defaults when the file is absent or a setting is
missing. The file must be valid JSON: use double quotes and no trailing commas.
Invalid JSON leaves the last valid settings active. The settings file is
separate from the checkout and survives updates.

### Borders

The island and its flyouts use Hyprland's border colors, gradient, width and
rounding, and refresh them after Hyprland configuration or theme changes.
Screen-attached edges stay square; the corners facing the screen's interior
follow the configured rounding. The outline expands to include active caffeine
and Do Not Disturb indicators.

### Environment options

Set them in a drop-in (`systemctl --user edit omarchy-island`, `[Service]` → `Environment=…`):

| Variable | Effect |
|---|---|
| `ISLAND_PLAYERS=spotify\|mpv` | only these media players (regex on D-Bus name / identity) |
| `ISLAND_CAM_IGNORE="ffmpeg my-cam*"` | processes that don't count as "camera in use" (virtual-camera pipelines) |
| `ISLAND_DEMO=1` | generic Wi-Fi and Bluetooth names, for screen recordings |
| `ISLAND_NOTCH=off` | disable the notch, overriding `notchMode` |
| `ISLAND_HIDE=tiled` | hide the resting island for a single browser or two or more tiled windows; it can still appear for actions and notifications |

The island follows your Omarchy theme and the `animations` toggle, and speaks
English or Italian depending on your locale — more languages welcome in
[`quickshell/I18n.js`](quickshell/I18n.js).

## Contributing

Issues and pull requests are welcome — see [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits & license

Forked from [Liukskywalkerr/omarchy-island](https://github.com/Liukskywalkerr/omarchy-island),
which is built on [Omarchy](https://github.com/basecamp/omarchy) and
[Quickshell](https://quickshell.org). See [CREDITS.md](CREDITS.md) for the
original project's acknowledgments and [LICENSE](LICENSE) for the MIT license.
