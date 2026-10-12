# relaxios

iPhone app (UIKit, iOS 16+, iPhone only, no packages, hand-written `project.pbxproj`) that plays silent, procedurally rendered thunderstorm loops fullscreen with zero UI. Swipe left/right changes storm; rotation crossfades to the other orientation file at the same timestamp. The visuals are Metal compute shaders rendered OFFLINE on the Mac by `render/` and shipped as HEVC Main10 mp4 loops; the app itself only plays videos.

Scenes, in display order (`VideoCatalog.sceneOrder`): `window` (Rain on the Window), `plains` (Distant Storm), `sea` (Storm at Sea), `above` (Above the Storm).

## Layout

```
Relaxios.xcodeproj/          hand-written project + shared scheme (never opened in Xcode on this machine)
Relaxios/*.swift             AppDelegate (audio .ambient), SceneDelegate (idle timer, pause/resume),
                             StormViewController (swipes, rotation, Low Power -> 720p, crossfades),
                             PlayerView (AVQueuePlayer + AVPlayerLooper, synced start), VideoCatalog
Relaxios/Videos/             folder reference: <id>_<portrait|landscape>_<1080|720>.mp4 (16 files, ~175 MB)
Relaxios/Assets.xcassets/    AppIcon (single 1024 icon-1024.png, RGB, no alpha), LaunchBackground colour
render/                      offline renderer; render/README.md is the full spec, read it before touching scenes
  scenes/common.metal        Uniforms + shared helpers, compiled in front of every scene
  scenes/<id>.metal|.conf    one shader + per-scene render/check settings (_test.conf documents every variable)
  src/                       storm-render CLI (Swift); build.sh -> bin/storm-render, bin/avcheck (bin/ is gitignored)
  tools/check_video.py       format / size / loop seam / flash checks
tools/validate_pbxproj.py    project graph, paths, build settings, scheme, Info.plist (148 checks)
tools/catalyst_harness/      runs the app's playback logic as a Mac Catalyst build with test loops (~26 s window)
docs/                        README assets: preview.webp, icon.png, screenshots/<id>_<orient>_<calm|strike>.jpg
```

## Render contract (brief; full text in render/README.md)

- Scene = pure function of (pixel, `u.resolution`, `u.time`, `u.seed`), writes display-referred sRGB via `output_color`. Size things in frame-HEIGHT units (`frame_uv`), never pixels.
- Loop L = 40 s, 30 fps, 1200 frames; frame i at t = i/fps. Either exactly periodic (`fbm3p` etc., `XFADE=0`) or hidden by the harness crossfade (`--xfade B`, so scenes must be valid for negative t).
- Lightning events at fixed offsets via `since_event(u.time, t0, u.loop)` so they survive the crossfade and match across orientations.
- SAME seed and time must give the SAME event timing in portrait and landscape. The app depends on this: rotation swaps files mid-play at the same timestamp (`PlayerView` seeks the new file to the old one's time). Re-compose per aspect, do not crop; keep content inside the ~9% aspect-fill safe zone on the short axis.
- Photosensitivity: no more than 3 large flashes in any 1 s window, soft rises, decays 0.3 to 1.0 s, a notable strike every 6 to 12 s.
- Encode: HEVC Main10 yuv420p10le, `hvc1`, bt709, limited range, +faststart, no audio, keyframe every 2 s. Budget 1080p <= ~22 MB, 720p <= ~11 MB.
- File names are load-bearing (the app looks them up by name).

## Commands

```bash
# Typecheck the app (no Xcode, no iOS SDK on this machine: Mac Catalyst instead)
SDK=$(xcrun --show-sdk-path)
swiftc -typecheck -target arm64-apple-ios16.0-macabi -sdk "$SDK" \
  -Fsystem "$SDK/System/iOSSupport/System/Library/Frameworks" \
  -I "$SDK/System/iOSSupport/usr/include" Relaxios/*.swift

python3 tools/validate_pbxproj.py      # project file sanity, must print OK
tools/catalyst_harness/run.sh          # runtime playback test, exit 0 = pass (opens a window)

cd render && ./build.sh                # storm-render + avcheck
./bin/storm-render --scene sea --w 1080 --h 1920 --ss 2 --still 6,17.3 --out /tmp/shots   # look at stills
./render_all.sh sea                    # 4 variants -> ../Relaxios/Videos/, runs check_video.py + avcheck
ONLY=720 ./render_all.sh               # subset;  DRY=1 prints commands
python3 tools/check_video.py <file.mp4>
```

A full 1080p loop takes several minutes (x265 `slow` is the bottleneck, not the GPU).

## Gotchas

- **No Xcode here** (Command Line Tools only). Verification is the Catalyst typecheck, `validate_pbxproj.py` and the Catalyst harness. Never claim something was built or run in Xcode. If you add a source file, add it to `project.pbxproj` by hand and re-run the validator.
- **Shaders compile at runtime** (`MTLDevice.makeLibrary(source:)`); there is no `metal` CLI. Errors are printed as `<id>.metal:line:col` and storm-render exits 2. Runtime compiles report no warnings.
- **Seam checker vs keyframe refresh.** On still, grainy scenes x265 freezes the dither/grain inside each GOP and refreshes it at every 2 s keyframe. Frame 0 is a keyframe, so the last-to-first step reads like a keyframe step and can trip the default seam floor even when the scene is exactly periodic. The fix is a per-scene `CHECK=(--seam-floor N)` after measuring internal keyframe steps (see the comments in `plains.conf`, `above.conf`, `window.conf`), not changing the scene.
- **Per-scene `.conf` overrides** (`SS`, `XFADE`, `CRF`, `CRF_1080`, `CRF_720`, `EXTRA`, `CHECK`, ...) are sourced as bash by `render_all.sh`. When rendering by hand, use the same values or the output will not match what ships. Each `.conf` also has a `# hero: <calm>,<strike>` comment: the times used for the README screenshots.
- **Time sync across orientations is required by the app**, not just nice to have. Never make event timing depend on aspect or resolution.
- `--ss` multiplies GPU cost by about ss^2; `above` runs at `SS=1` because the shader anti-aliases itself.
- macOS has no `timeout` and zsh does not word-split `$var`; the shell tools are bash scripts for that reason.
- Headless screenshots are not needed here: extract frames from the shipped videos with ffmpeg (`select=eq(n\,N)`), or render stills with `storm-render --still`.

## Deploy

- Git remote: `git@github-personal:vaibhavgit9210/relaxios.git` (personal account, via the `github-personal` SSH alias; never a plain github.com HTTPS remote).
- Push `main` only. No GitHub Pages, no `gh-pages` branch.
- The videos are ~175 MB in total; each file is under GitHub's 100 MB limit.
