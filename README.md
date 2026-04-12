# VideoWallpaper

A lightweight macOS menu bar app that plays videos as your desktop wallpaper.

## Features

- Loop video as desktop wallpaper
- Per-screen video and static wallpaper control
- Pause, stop, and restore per screen or all at once
- Remembers state across launches
- Dark menu bar enforced while video is active
- Supports mp4, mov, avi, and other macOS-compatible video formats
- Chinese / English UI

## Install

### Option 1: Download App (recommended)

Download `VideoWallpaper-app.zip` from [Releases](https://github.com/FishfishCai/VideoWallpaper/releases), unzip, and drag `VideoWallpaper.app` to your Applications folder. Double-click to launch.

### Option 2: Download Binary

Download `VideoWallpaper-binary.zip` from [Releases](https://github.com/FishfishCai/VideoWallpaper/releases), unzip, and move to your PATH:

```bash
cp VideoWallpaper ~/.local/bin/
# or: sudo cp VideoWallpaper /usr/local/bin/
```

Launch with `nohup VideoWallpaper &`.

### Option 3: Build from Source

Requires Xcode Command Line Tools (includes Swift).

```bash
git clone https://github.com/FishfishCai/VideoWallpaper.git
cd VideoWallpaper
swift build -c release
cp .build/release/VideoWallpaper ~/.local/bin/
```

## Usage

A **▶** icon appears in the menu bar:

- **Screen Video Wallpaper** — select video per screen, pause/stop/restore individually
- **Screen Static Wallpaper** — set fallback wallpaper per screen (default: solid black)
- **Set Video for All** — same video on all screens
- **Set Static for All** — same static wallpaper on all screens
- **Pause/Resume All** — toggle all screens
- **Stop All / Resume All** — stop or restore all videos
- **Language** — switch between English and Chinese
- **Quit** (⌘Q)

To launch at login: System Settings → General → Login Items → add VideoWallpaper.

## How it works

Places a borderless window below the desktop icon layer and uses `AVPlayer` to loop video playback. Sets the system wallpaper to solid black while video is active to ensure a dark menu bar.

## Config

State is saved to `~/.config/VideoWallpaper/` and restored on next launch.

## Requirements

- macOS 13.0+

## License

MIT
