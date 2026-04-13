# VideoWallpaper

A macOS menu bar app that plays videos, images, or Wallpaper Engine wallpapers as your desktop wallpaper.

## Features

- **Video wallpaper** — loop any video (mp4, mov, mkv, webm, avi, m4v, wmv, flv, mpg, mpeg)
- **Image wallpaper** — static image (jpg, png, heic, webp, tiff, bmp, gif)
- **Wallpaper Engine support** — video and web (HTML/JS) types
- Per-screen wallpaper control with pause / stop / restore
- Remembers state across launches (including WE web user properties)
- Dark menu bar enforced while wallpaper is active
- Audio playback with mute toggle
- Mouse events forwarded into WE web wallpapers for interactive content
- Chinese / English UI

## Install

### Option 1: Download App (recommended)

Download from [Releases](https://github.com/FishfishCai/VideoWallpaper/releases), unzip, and drag to Applications.

```bash
xattr -cr VideoWallpaper.app  # remove quarantine if needed
```

### Option 2: Build from Source

```bash
git clone https://github.com/FishfishCai/VideoWallpaper.git
cd VideoWallpaper
swift build -c release
cp .build/release/VideoWallpaper ~/.local/bin/
```

Or build the full `.app` bundle:

```bash
./scripts/build.sh 1.0.0
```

## Usage

A **▶** icon appears in the menu bar:

- **设置动态壁纸 / Dynamic Wallpaper** — select video, image, or WE wallpaper folder per screen
- **设置退出状态壁纸 / Idle Wallpaper** — set fallback wallpaper per screen
- **全部暂停 / 全部继续** — toggle pause (switches based on state)
- **全部停止 / 全部恢复** — stop or restore (switches based on state)
- **静音 / 取消静音** — toggle audio
- **Language** — Chinese / English

### Wallpaper Engine

1. Copy a wallpaper folder (containing `project.json`) from Windows
2. Click **Select Wallpaper** → choose the folder
3. Supported WE types: **Video**, **Web** (HTML/JS with user-property injection and mouse forwarding)

## Architecture

Source is organized into four layers under `Sources/VideoWallpaper/`:

| Folder | Purpose |
|--------|---------|
| `App/` | `AppDelegate` (menu bar UI + lifecycle) and `WallpaperController` (per-screen state + backend orchestration) |
| `Config/` | `AppConfig` (state.json persistence) and `WEProject` (Wallpaper Engine `project.json` parsing) |
| `Backends/` | One file per wallpaper type: video / image / web, plus the borderless desktop-level window factory |
| `Scene/` | Metal renderer for Wallpaper Engine **scene** type — only compiled into the beta build via `-DENABLE_SCENE` |

Stable builds ship without any scene-renderer code linked in.

## Requirements

- macOS 13.0+

## License

MIT
