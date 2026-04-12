# VideoWallpaper

A lightweight macOS menu bar app that plays videos or Wallpaper Engine web wallpapers as your desktop wallpaper.

## Features

- Loop video as desktop wallpaper
- Import Wallpaper Engine wallpapers (video and web types)
- Interactive web wallpapers with mouse event passthrough
- Per-screen video and static wallpaper control
- Pause, stop, and restore per screen or all at once
- Remembers state across launches
- Dark menu bar enforced while wallpaper is active
- Supports mp4, mov, avi, and other macOS-compatible video formats
- Chinese / English UI

## Install

### Option 1: Download App (recommended)

Download `VideoWallpaper-vX.X.X-app.zip` from [Releases](https://github.com/FishfishCai/VideoWallpaper/releases), unzip, and drag `VideoWallpaper.app` to your Applications folder. Double-click to launch.

### Option 2: Download Binary

Download `VideoWallpaper-vX.X.X-binary.zip` from [Releases](https://github.com/FishfishCai/VideoWallpaper/releases), unzip, and move to your PATH:

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

- **Screen Wallpaper** — select video or import WE wallpaper per screen, pause/stop/restore individually
- **Idle Wallpaper** — set fallback wallpaper per screen (default: solid black)
- **Set Video for All** — same video on all screens
- **Set Idle Wallpaper for All** — same static wallpaper on all screens
- **Import Wallpaper Engine** — import a WE wallpaper folder for all screens
- **Pause/Resume All** — toggle all screens
- **Stop All / Resume All** — stop or restore all wallpapers
- **Language** — switch between English and Chinese
- **Quit** (⌘Q)

### Wallpaper Engine Support

Import wallpapers from [Wallpaper Engine](https://store.steampowered.com/app/431960/Wallpaper_Engine/) (Steam Workshop):

1. Copy the wallpaper folder (contains `project.json`) from your Windows machine
2. Use **Import Wallpaper Engine** in the menu
3. Select the folder containing `project.json`

Supported types:
- **Video** — plays the video file directly
- **Web** — loads HTML wallpapers in WKWebView with property injection and mouse interaction

To launch at login: System Settings → General → Login Items → add VideoWallpaper.

## How It Works

Places a borderless window below the desktop icon layer using `AVPlayer` for video or `WKWebView` for web wallpapers. Sets the system wallpaper to solid black while active to ensure a dark menu bar. Web wallpapers receive mouse events via global event monitoring and JavaScript injection.

## Config

State is saved to `~/.config/VideoWallpaper/` and restored on next launch.

## Requirements

- macOS 13.0+

## License

MIT
