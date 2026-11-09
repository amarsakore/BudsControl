<p align="center"><img src="docs/icon.png" width="128" alt="Buds Control icon"></p>

<h1 align="center">Buds Control</h1>

<p align="center">A native macOS menu bar app for switching <b>Noise Cancellation</b>, <b>Transparency</b> and <b>Off</b>
on OnePlus, Oppo, Realme buds without the phone app.</p>

---

## Features

- **One-click noise control:** Off, Transparency and Noise Cancellation, plus the ANC levels your model
  has (Smart, Max, Moderate, Mild, Adaptive), in a compact popover (Liquid Glass on macOS 26, plain
  materials on 14–15).
- **Battery at a glance:** the menu bar icon is ringed by the earbuds' battery level; the popover shows
  left, right and case.
- **More controls** behind the ⌄ button next to •••:
  - **Equalizer:** the built-in presets (Balanced, Vocal, Bass) and your custom EQ, with six band sliders
  - **Low latency** mode for games and video
  - **Find my earbuds:** play a loud sound to locate them
  - **Gestures:** pick what double tap, triple tap and touch & hold do on each bud
- **Global keyboard shortcuts:** cycle modes or jump straight to one from any app, with an on-screen HUD.
  No Accessibility permission needed.
- **Automatic reconnect:** when the buds come out of the case and only rejoin your phone, Buds Control
  brings them back to the Mac and reconnects within a few seconds.
- **Remember settings:** optionally puts back the noise mode and low latency you last picked whenever the
  buds connect, since the buds reset them on their own (for example after going back in the case).
- **Developer options:** a live packet log, raw commands, every noise-mode bit the model supports,
  game mode, and the list of devices the buds are paired with.

## Requirements

- macOS 14 (Sonoma) or later, on Apple silicon or Intel
- OnePlus, OnePlus Nord, OPPO Enco or realme earbuds, paired with the Mac in System Settings › Bluetooth

### Supported earbuds

Buds Control works with earbuds that use OnePlus/OPPO's HeyMelody app or realme Link: OnePlus Buds and
Nord Buds, OPPO Enco, and realme Buds. It knows **105 models** by product ID and shows **only the settings
each model has**, such as which noise modes and ANC levels exist, its EQ presets, low latency, find my
earbuds and gestures. Each setting also has to be confirmed by the buds themselves (their capability
reply and an answer to the setting's query) before it appears, so nothing shows up that the buds can't do.

- **Tested:** OnePlus Buds 4; OnePlus Buds Pro 3 (contributed)
- **realme:** uses realme's own noise-mode numbering and gesture codes. EQ presets aren't known for
  realme models, so only a custom EQ the buds report is shown.
- **Models not in the catalog** get the basics only: Off / Transparency / ANC (no levels), plus whatever
  the buds confirm they support.

If something on your model doesn't work, please [open an issue](../../issues) with the model name.

## Install

### Download

1. Download `BudsControl.zip` from the [latest release](../../releases/latest) and unzip it.
2. Move **Buds Control** to your Applications folder and open it.
3. The app isn't notarized by Apple, so the first launch is blocked. Open
   **System Settings › Privacy & Security**, scroll down and click **Open Anyway**.
4. Allow Bluetooth access when asked.

### Build from source

Needs Apple's Command Line Tools (`xcode-select --install`); full Xcode isn't required.

```bash
git clone https://github.com/amarsakore/BudsControl.git
cd BudsControl
./build.sh
open build/BudsControl.app
```

To start it at login, turn on **Launch at login** in Buds Control's settings.

## Usage

Click the earbuds icon in the menu bar. The ••• menu has **Settings…**, where you can set shortcuts,
launch at login, automatic reconnect, remembering settings between connections, the HUD, and developer
options.

### Command line

The app binary also works as a small CLI, handy for scripts and debugging:

```bash
open build/BudsControl.app --args --cli anc       # or: transparency, off, smart, max, moderate, mild, status
open build/BudsControl.app --args --watch 30      # log everything the buds send for 30 s
```

Running the binary directly from a terminal also works, but that terminal app then needs Bluetooth
permission.

## How it works

The buds expose a HeyMelody control service ("enco link") over classic Bluetooth RFCOMM (channel 15 on
the Buds 4). Buds Control opens it with IOBluetooth and exchanges small frames:

```
AA <len> 00 00 <command, 16-bit LE> <seq> <payload length, 16-bit LE> <payload…>
```

`<len>` counts the bytes after it and is a LEB128 varint: one byte for most frames, more for long ones
such as the multipoint device list. Replies use the request command with the high bit set
(`0x0106` → `0x8106`).

| Command | Purpose |
|---|---|
| `0x0100` | hello |
| `0x0103` | product ID (Buds 4 = `065414`) |
| `0x0106` | battery: `(id, level \| 0x80 if charging)` pairs; 1 left, 2 right, 3 case |
| `0x0109` | wear status |
| `0x010C [01 01]` | noise mode → bitmask |
| `0x0112` | paired devices (multipoint) |
| `0x0205 [count, ids…]` | subscribe to pushes (battery, wear and noise mode) |
| `0x0204` | push from the buds; first byte is the subscription type |
| `0x0108` / `0x0401 [01 side 01 gesture action]` | read / set touch gestures |
| `0x010D [n ids…]` / `0x0403 [id on]` | read / set on-off features (`06` = low latency) |
| `0x010F` / `0x0406 [id]` | read / set the EQ preset |
| `0x0122 [01 05]` / `0x0418 [02 …]` | list / rewrite custom EQs (bands as Hz + gain) |
| `0x0400 [01 \| 00]` | start / stop the find-my-earbuds sound |
| `0x0404 [01 01 <mask>]` | set noise mode |

On the Buds 4, mask bit 0 is off, bit 1 is ANC, bit 2 is transparency, bit 4 is max, bit 5 is moderate, bit 6 is mild,
bit 7 is smart and bit 11 is adaptive. The buds report some modes with a different bit than the one used to
set them (transparency comes back as bit 8, off as bit 3), and the layout differs between models; the
device catalog has each model's.

## Credits

### Contributors

Thank you to everyone who has improved Buds Control:

- **Lohith Srikar** ([@lsrik19](https://github.com/lsrik19)): macOS 14 Sonoma and 15 Sequoia support, with
  fallbacks for the Liquid Glass effects ([#2](https://github.com/amarsakore/BudsControl/pull/2)); parsing
  of long messages from the buds and fixes for the Settings window ([#7](https://github.com/amarsakore/BudsControl/pull/7))
- **Bhanu** ([@WinShell-Bhanu](https://github.com/WinShell-Bhanu)): OnePlus Buds Pro 3 compatibility, with their
  separate noise-mode layout and extra service lookup ([#3](https://github.com/amarsakore/BudsControl/pull/3))

Pull requests are welcome, especially support for more OnePlus and OPPO models.

### Protocol references

- The per-model noise-mode bit layouts and the RFCOMM framing come from the
  [`oppo-pods` plugin](https://github.com/noctalia-dev/community-plugins/tree/main/oppo-pods)
  for Noctalia by osp54 (MIT License, Copyright (c) 2026 osp54).
- Push subscriptions, wear status and multipoint commands were documented by the OPPO headphones support in
  [Gadgetbridge](https://codeberg.org/Freeyourgadget/Gadgetbridge).
- EQ, feature-switch and gesture command details come from the HeyMelody RFCOMM port in
  [RawS-Music](https://github.com/QFDY-GZC/RawS-Music) (Apache License 2.0).

No code was copied from any of these projects; Buds Control is an independent Swift implementation.
The device catalog (`Sources/DeviceCatalog.swift`, generated by `tools/generate_catalog.py`) is
derived from the RawS-Music and oppo-pods data; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

## Disclaimer

Buds Control is an unofficial project and isn't affiliated with, endorsed by, or supported by OnePlus,
OPPO or Apple. OnePlus and OPPO are trademarks of their respective owners. Use at your own risk.

## License

[MIT](LICENSE)
