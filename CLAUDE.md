# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run

```bash
swift build                              # debug build (stable, no scene)
swift build -c release                   # release build (stable)
swift build -Xswiftc -DENABLE_SCENE      # beta build including scene support
./scripts/build.sh 1.0.0                 # stable: release + bundle into VideoWallpaper.app, ad-hoc codesign, zip
./scripts/build.sh 1.0.0-beta.1          # beta: same, with -DENABLE_SCENE auto-detected from version string
.build/debug/VideoWallpaper              # run from CLI (menu bar icon ▶ appears)
open VideoWallpaper.app                  # run bundled app
```

`scripts/build.sh` rewrites `VideoWallpaper.app/Contents/Info.plist` version, copies the binary, strips xattrs, ad-hoc codesigns, and produces `VideoWallpaper-v<version>-app.zip` + `VideoWallpaper-v<version>-binary.zip`. It auto-detects beta from `beta`/`alpha`/`rc` in the version string and passes `-Xswiftc -DENABLE_SCENE`.

Signing must happen outside iCloud-tracked paths or `com.apple.FinderInfo` gets re-added before `codesign` runs. The script handles this by copying to `/tmp/VW-sign/` first.

There are no tests and no linter config. Runtime state lives at `~/.config/VideoWallpaper/` (`state.json`, `lang.json`, `black.png`) — delete to reset.

## Source layout

```
Sources/VideoWallpaper/
├── main.swift                Entry
├── App/
│   ├── AppDelegate.swift        NSApplicationDelegate — menu bar UI, lifecycle, @objc action forwarding
│   ├── WallpaperController.swift  Owns all per-screen state + backend orchestration (9 dicts, show/stop/pause/persist/inject)
│   └── Localization.swift       Chinese / English string table behind `L`
├── Config/
│   ├── AppConfig.swift          WallpaperType / WallpaperSource / ScreenConfig + state.json I/O
│   └── WEProject.swift          project.json → (video | web | scene) dispatch
├── Backends/
│   ├── WallpaperWindow.swift    createWallpaperWindow (borderless desktop-level NSWindow)
│   ├── VideoBackend.swift       setupVideoContent → AVPlayer + AVPlayerLayer (loop via AVPlayerItemDidPlayToEndTime)
│   ├── ImageBackend.swift       setupImageContent → NSImageView
│   ├── WebBackend.swift         setupWebContent → WKWebView with polling WE property injection
│   └── SceneBackend.swift       setupSceneContent → MTKView + SceneEngine.configure(with:)  [#if ENABLE_SCENE]
└── Scene/                       [entire folder is #if ENABLE_SCENE]
    ├── SceneLoader.swift        WE folder → in-memory SceneBundle (PKG extract, .tex decode, shader extraction)
    ├── SceneEngine.swift        Metal renderer: init, draw loop, setMuted, setPaused
    ├── SceneLayers.swift        ImageLayer model + SceneEngine extensions (configure/addLayer/addParticleSystem + render methods)
    ├── SceneParticles.swift     Particle / ParticleSystem (sprite + rope, turbulence, vortex, cursor repel)
    ├── SceneShaders.swift       Metal Shading Language source string (extension on SceneEngine)
    ├── SceneLog.swift           os.Logger instances (shader / audio / script categories)
    ├── SceneScript.swift        JavaScriptCore wrapper for WE property expressions
    ├── TexDecoder.swift         .tex binary texture decoder (ARGB / DXT1/3/5 / LZ4 / JPEG / PNG)
    ├── GLSLTranslator.swift     Runtime WE GLSL → MSL fragment shader translator
    └── AudioCapture.swift       FFT spectrum capture (plumbing present, not wired to shaders)
```

## Architecture

### AppDelegate → WallpaperController split

`AppDelegate` is a thin UI shell: menu bar construction, global mouse monitor, application lifecycle, and `@objc` action methods that forward to `WallpaperController`. It does not touch per-screen state directly.

`WallpaperController` (@MainActor class) owns every per-screen dictionary keyed by `NSScreen.localizedName`:

- `wallpaperWindows`, `players`, `webViews`, `sceneEngines` — live backend handles
- `activeSources`, `lastSources` — current + most-recent `WallpaperSource`
- `staticWallpapers` — idle fallback URLs
- `pausedScreens` — Set
- `webPropertyJS` — WE user-property JS object literals (persisted in `ScreenConfig`)

Public API: `show(on:source:propertyJS:)`, `stop(screen:)`, `stopAllActive()`, `togglePause(for:)`, `toggleAllPaused()`, `restoreLast(on:)`, `resumeAllLast()`, `setAudioMuted(_:)`, `injectMouseEvent(_:)`, `setStaticWallpaper(_:for:)`, `applyStaticWallpaper(for:)`, `applyStaticToAllScreens`, `applyStaticToInactiveScreens`, `enforceBlackOnActiveScreens`, `persist()`, `restore()`.

`AppDelegate` calls `rebuildMenu()` after every mutating action (including once after `restore()` on launch) so the top-level menu stays consistent with controller state.

### Wallpaper pipeline

`WallpaperType` has four cases: `video`, `image`, `web`, `scene`. `pickWallpaper()` in AppDelegate dispatches:

- File → extension match → `WallpaperSource(type: .video | .image)`
- Folder → `parseWEProject(at:)` in `Config/WEProject.swift` reads `project.json` and returns one of video/web/scene, plus an optional WE property JS blob for web wallpapers

Stable builds return `nil` from the scene branch (gated), which surfaces an "unsupported" alert. In beta, scene validation runs `loadSceneBundle(folderURL:) != nil` before accepting the folder.

`WallpaperController.show(on:source:propertyJS:)` tears down any prior state for that screen, creates a borderless desktop-level `NSWindow` via `createWallpaperWindow`, dispatches on `source.type` to one of the four `setup*Content` backends, orders the window front, and updates `activeSources` + `lastSources`. For scene it also calls `engine.setMuted(audioMuted)` so newly-loaded scenes inherit the current mute state.

### WE scene pipeline (beta only)

All scene code is gated by `#if ENABLE_SCENE`. Parsing is fully in-memory:

1. `Config/WEProject.swift` scene case → `loadSceneBundle(folderURL:)` in `Scene/SceneLoader.swift`
2. `loadSceneBundle` extracts `scene.pkg` (or reads loose `scene.json`), decodes WE JSON, topologically sorts objects, decodes `.tex` textures to `CGImage` via `TexDecoder`, extracts shader sources from the PKG, and calls `buildEffectBundle` per effect. Returns a `SceneBundle` (pure memory — no intermediate files on disk except audio, which AVPlayer requires as a URL and is written hash-named to `NSTemporaryDirectory()/VideoWallpaper/audio/`).
3. `Backends/SceneBackend.swift` creates an `MTKView` + `SceneEngine`, then calls `engine.configure(with: bundle)`.
4. `SceneEngine.configure(with:)` (extension in `Scene/SceneLayers.swift`) iterates layers — compiling effects via `GLSLTranslator` + `compileEffect`, uploading mask/extra textures, appending `ImageLayer` — and particles.
5. Render loop in `SceneEngine.drawFrame` composites layers into a scene FBO, applies per-layer effect chains via FBO ping-pong, then blits to the drawable with ZoomFill + parallax.

Mouse events flow from `AppDelegate.startMouseTracking` → `WallpaperController.injectMouseEvent` → each web view (via `dispatchEvent`) and each `SceneEngine.updateMouse`.

### Menu bar UI

`setupMenuBar` + `rebuildMenu` build the `NSStatusItem` menu. There are two submenus per screen (dynamic = active wallpaper controls; static = idle fallback) plus global pause/stop/restore/mute/language/quit. Submenus are refreshed in `menuWillOpen`; the top-level menu is rebuilt explicitly after every mutating action (and after `controller.restore()` on launch) so items like "Stop All" / "Restore All" stay in sync.

### Persistence

`AppConfig.swift` owns `loadConfig` / `saveConfig` (JSON at `~/.config/VideoWallpaper/state.json`). `ScreenConfig` persists `wallpaperSource`, `paused`, `staticWallpaperPath`, and `webPropertyJS`. `loadConfig` in stable builds silently drops any `.scene` entries so legacy saved state doesn't try to restore unsupported scenes.

`persist()` runs from `applicationWillTerminate`; `restore()` runs from `applicationDidFinishLaunching` and re-creates wallpapers for any screen whose source file still exists. Three delayed `enforceBlackOnActiveScreens` calls (1s / 3s / 6s) work around macOS resetting the desktop image shortly after launch.

## Conventions specific to this repo

- All UI/state code is `@MainActor`. Per-screen state is keyed by `NSScreen.localizedName` — never by index.
- `WallpaperSource` is `Codable` and lives in `state.json`; changing its shape requires migration or user state silently resets on next launch.
- The WE web-property poll script in `WebBackend.setupWebContent` is load-bearing — removing the `window.renderer` check breaks most WE web wallpapers (the listener is created at parse time but the renderer only exists after `onLoad`).
- Any mutation of `activeSources` / `lastSources` / `pausedScreens` from `AppDelegate` must be followed by `rebuildMenu()` or the top-level menu goes stale until the next state change.
- Signing has to run outside iCloud-tracked directories; `scripts/build.sh` copies the `.app` to `/tmp/VW-sign/` before `codesign` for this reason.
