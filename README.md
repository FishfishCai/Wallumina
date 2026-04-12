# VideoWallpaper

A macOS menu bar app that plays videos, images, or Wallpaper Engine wallpapers as your desktop wallpaper. Features a Metal-based scene rendering engine.

## Features

- **Video wallpaper** — loop any video (mp4, mov, avi, mkv, etc.)
- **Image wallpaper** — static image (jpg, png, heic, webp, etc.)
- **Wallpaper Engine support** — video, web, and scene types
- Per-screen wallpaper control with pause/stop/restore
- Remembers state across launches
- Dark menu bar enforced while wallpaper is active
- Audio playback with mute toggle
- Chinese / English UI

## WE Scene Support

| Feature | Status |
|---------|--------|
| **Layer** | |
| Image layer | ✅ |
| Multi-layer compositing | ✅ |
| Fullscreen / Composition | ✅ |
| Text layer | ❌ |
| **Effect** | |
| Shader effect pipeline (FBO ping-pong) | ✅ |
| GLSL → Metal shader translation | ✅ |
| Water Ripple / Water Flow | ✅ |
| Shake / Water Waves | ✅ (via GLSL translation) |
| Mouse parallax with delay | ✅ |
| Per-layer parallax depth | ✅ |
| Color blend modes | ✅ |
| Blur / God Rays | ✅ (via GLSL translation) |
| Global bloom | ✅ (basic) |
| PBR light | ❌ |
| **Camera** | |
| Orthographic projection | ✅ |
| ZoomFill / ZoomFit scaling | ✅ |
| Shake | ❌ (parsed, not rendered) |
| Fade / Path | ❌ |
| **Audio** | |
| Sound playback (loop) | ✅ |
| Mute toggle | ✅ |
| Audio visualization (spectrum) | ⚠️ (capture implemented, not wired to shaders) |
| **Particle System** | |
| Sprite renderer | ✅ |
| Rope / trail renderer | ✅ |
| Emitters (sphere, box) | ✅ |
| Initializers (color, size, alpha, velocity, lifetime, rotation) | ✅ |
| Operators (movement, drag, alpha fade, size change, oscillate) | ✅ |
| Turbulence (Perlin noise) | ✅ |
| Vortex | ✅ |
| Control point (cursor repulsion) | ✅ |
| Spritesheet animation | ⚠️ (parsed, basic) |
| Children (sub-emitters) | ❌ |
| Audio response | ❌ |
| **Other** | |
| .tex texture decoder (ARGB/DXT1/3/5/LZ4/JPEG/PNG) | ✅ |
| PKG package parser (all versions) | ✅ |
| Render dependency ordering | ✅ |
| SceneScript (JS property evaluation) | ⚠️ (basic via JavaScriptCore) |
| User properties | ❌ |
| Puppet warp / bone animation | ❌ |
| 3D model | ❌ |
| Timeline animations | ❌ |

✅ = Supported | ⚠️ = Partial | ❌ = Not supported

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

## Usage

A **▶** icon appears in the menu bar:

- **设置动态壁纸 / Dynamic Wallpaper** — select video, image, or WE wallpaper folder per screen
- **设置退出状态壁纸 / Idle Wallpaper** — set fallback wallpaper per screen
- **全部暂停 / 全部继续** — toggle pause (switches based on state)
- **全部停止 / 全部恢复** — stop or restore (switches based on state)
- **静音 / 取消静音** — toggle audio
- **Language** — Chinese / English

### Wallpaper Engine

1. Copy wallpaper folder (contains `project.json`) from Windows
2. Click **Select Wallpaper** → choose the folder
3. Supported: **Video**, **Web** (HTML/JS), **Scene** (Metal rendering)

## Architecture

| File | Purpose |
|------|---------|
| `SceneEngine.swift` | Metal renderer: multi-layer compositing, FBO ping-pong, particles |
| `TexDecoder.swift` | .tex binary texture decoder |
| `GLSLTranslator.swift` | WE GLSL → Metal Shading Language translator |
| `AudioCapture.swift` | Audio spectrum capture (FFT) |
| `SceneScript.swift` | JavaScriptCore property evaluation |
| `Config.swift` | Scene/PKG/JSON parsing, metadata generation |

## Requirements

- macOS 13.0+

## License

MIT
