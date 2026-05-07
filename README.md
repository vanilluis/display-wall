# display-wall

Play a single video file across multiple Mac displays with frame-perfect sync. The built-in display hosts a small control window (play/pause, scrub, file picker, per-display reorder); each connected external display shows one vertical slice of the video, left-to-right.

Designed for portrait video walls — e.g. three vertical 9:16 displays showing one 27:16 master.

## Requirements

- macOS with Xcode Command Line Tools (`xcode-select --install`)
- One or more external displays connected (the built-in display is reserved for the control window)

## Install

```sh
git clone https://github.com/vanilluis/display-wall
cd display-wall
./install.sh
```

`install.sh` symlinks the `display-wall` command into `/usr/local/bin` if writable, otherwise `~/.local/bin`. If your install dir isn't on `PATH`, it tells you what to add to your shell rc.

## Usage

```sh
display-wall                  # opens with last-played video, or empty if none
display-wall path/to/clip.mov # opens with the given file
```

Controls:

| Action                   | Shortcut          |
| ------------------------ | ----------------- |
| Play / pause             | Space             |
| Open video               | ⌘O                |
| Reorder displays         | ◀ ▶ buttons       |
| Quit                     | ⌘Q or Esc         |

Display order and the last-played file persist between launches in `~/Library/Application Support/display-wall/config.json`. Order is keyed by EDID (vendor + model + serial), so it's stable across reboots and reconnects.

## How it works

A single `AVQueuePlayer` drives one `AVPlayerLayer` per external display. Each layer is sized N× wider than its window and shifted by `-i × width`, so only that display's slice is visible. Because every layer pulls from the same player clock, the displays stay in lockstep at the frame level.

## Notes on performance

- Apple Silicon's H.264 hardware decoder caps at 4K. Files above 4K decode in software, which can lag at high frame rates.
- For high-resolution masters, re-encode to HEVC (`hevc_videotoolbox`, hardware up to 8K) or ProRes 422 (hardware-decoded on M1 Pro/Max/Ultra and later). ProRes is largest but most reliable.

A small Swift helper (`encode-progress.swift`) shows a progress window while running ffmpeg; edit the encoder args near the top of the file before use.
