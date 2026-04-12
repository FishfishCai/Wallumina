# VideoWallpaper

A macOS menu bar app that plays videos, images, or Wallpaper Engine wallpapers as your desktop wallpaper. Features a Metal-based scene rendering engine for WE Scene wallpapers.

## Features

- **Video wallpaper** — loop any video (mp4, mov, avi, mkv, etc.)
- **Image wallpaper** — static image as wallpaper (jpg, png, heic, webp, etc.)
- **Wallpaper Engine support** — video, web, and scene types
  - Metal rendering engine with GLSL-to-MSL shader translation
  - Particle systems (snow, fog, smoke, dust, fireflies)
  - Effect pipeline with FBO ping-pong (water ripple, water flow, shake, etc.)
  - Multi-layer compositing with per-layer parallax and blend modes
  - .tex texture decoder (ARGB8888, DXT1/3/5, LZ4, embedded JPEG/PNG)
  - Audio playback with mute toggle
  - Mouse interaction (parallax, cursor repulsion)
- Per-screen wallpaper control
- Pause, stop, and restore per screen or all at once
- Remembers state across launches
- Dark menu bar enforced while wallpaper is active
- Chinese / English UI

## Install

### Option 1: Download App (recommended)

Download `VideoWallpaper-v2.0.0-app.zip` from [Releases](https://github.com/FishfishCai/VideoWallpaper/releases), unzip, and drag to Applications.

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

## Usage

A **▶** icon appears in the menu bar:

- **Select Wallpaper** — pick a video file, image file, or WE wallpaper folder
- **Idle Wallpaper** — set fallback wallpaper per screen (default: solid black)
- **Pause/Resume All** — toggle all screens
- **Stop All / Resume All** — stop or restore all wallpapers
- **Mute/Unmute Audio** — toggle scene wallpaper audio
- **Language** — switch between English and Chinese
- **Quit** (⌘Q)

### Wallpaper Engine Support

1. Copy the wallpaper folder (contains `project.json`) from your Windows machine
2. Click **Select Wallpaper** and choose the folder
3. Supported types: **Video**, **Web** (HTML/JS), **Scene** (Metal rendering)

## Architecture

- `SceneEngine.swift` — Metal renderer with multi-layer compositing, FBO ping-pong effects, particle systems
- `TexDecoder.swift` — WE .tex binary texture decoder (ARGB8888, DXT1/3/5, LZ4 compression)
- `GLSLTranslator.swift` — WE GLSL to Metal Shading Language runtime translator
- `AudioCapture.swift` — Audio spectrum capture for shader uniforms
- `SceneScript.swift` — JavaScriptCore-based property formula evaluation

## Config

State is saved to `~/.config/VideoWallpaper/` and restored on next launch.

## Requirements

- macOS 13.0+

## License

MIT
