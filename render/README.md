# relaxios offline renderer

Renders the app's thunderstorm loops on a Mac with Metal and encodes them as
seamless HEVC Main10 mp4 files. Scenes are small Metal compute kernels; the
harness (`storm-render`) handles supersampling, the loop crossfade, dithering,
stills, contact sheets, benchmarks and the ffmpeg encode.

```
render/
  build.sh              swiftc -O -> bin/storm-render, bin/avcheck
  render_all.sh         every scene x 4 variants -> ../Relaxios/Videos/, then checks
  src/*.swift           the storm-render CLI
  scenes/common.metal   Uniforms + shared helpers (compiled in front of every scene)
  scenes/<id>.metal     one scene per file (window, plains, sea, above)
  scenes/<id>.conf      optional per-scene render settings (see _test.conf)
  scenes/_test.metal    stress test: dark gradients + dense fast streaks + periodic flash
  scenes/_flat.metal    flat colour, for the colour roundtrip check
  tools/check_video.py  format / size / loop seam / flash checks for an mp4
  tools/avcheck.swift   AVFoundation load check (what iOS uses)
  bin/                  build products (not source)
```

Requirements: macOS with Command Line Tools (no Xcode needed; shaders are
compiled at runtime with `MTLDevice.makeLibrary(source:)`), ffmpeg with libx265
(`/opt/homebrew/bin/ffmpeg` is used if present), python3 (stdlib only).

```bash
./build.sh
./bin/storm-render --scene _test --w 1080 --h 1920 --ss 2 --still 0,2.5,10 --out /tmp/shots
```

## Shared render contract

Scenes and the harness both conform to this. Copied from the project brief.

- Each scene is `render/scenes/<id>.metal`. The harness compiles
  `render/scenes/common.metal` + `render/scenes/<id>.metal` concatenated as ONE
  source string at runtime.
- `common.metal` defines:
  `struct Uniforms { float2 resolution; float time; float loop; float fps; uint seed; uint frame; float pad; };`
  plus shared helpers (hash, value/gradient noise, fbm, smoothstep helpers,
  sRGB encode, tonemap). Scenes may define their own helpers (prefix them with
  the scene id to be safe).
- Each scene defines:
  `kernel void scene(texture2d<float, access::write> out [[texture(0)]], constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]])`
  writing DISPLAY-REFERRED (sRGB-encoded) RGB in [0,1], alpha 1.
- A scene is a PURE function of (pixel, u.resolution, u.time, u.seed).
  Coordinates resolution-independent: normalize by the frame HEIGHT for
  portrait-vs-landscape-agnostic sizes, and size thin features (rain streak
  width, bolt core) in units that scale with resolution so 720p and 1080p look
  identical apart from sharpness.
- Loop: default L = 40 s at 30 fps (1200 frames). Frame i is rendered at
  t = i/fps. The harness offers an optional loop crossfade (`--xfade B`
  seconds): for t > L-B it blends F(t) with F(t-L) so frame N wraps seamlessly
  onto frame 0. Hence scenes must be valid for negative t, discrete EVENTS
  (lightning) must be scheduled periodically mod u.loop so they survive the
  crossfade at full strength, and anything that can be made exactly periodic
  (rain, drips, swell phases) should be. Slow non-periodic drift (clouds) is
  what the crossfade hides.
- Orientation: the SAME seed and time must produce the SAME event timing in
  portrait and landscape (the app swaps orientation files mid-play at the same
  timestamp). Composition adapts to aspect (re-compose, do not just crop). The
  app uses aspect-fill on 19.5:9 phones, which crops ~9% off each side of the
  frame's SHORT axis (portrait: left/right; landscape: top/bottom): keep
  important content inside that safe zone.
- Relaxation + photosensitivity: lightning must feel soothing, not like a
  strobe. Prefer soft in-cloud/sheet glow and distant bolts; frame-average
  luminance must never make more than 3 large flashes in any 1 s window; big
  full-frame jumps are capped (keep mean-luma jumps modest; illumination rises
  over 1-2 frames and decays over 0.3-1.0 s with at most 2-3 return strokes
  spaced >= 0.35 s). Roughly one notable strike every 6-12 s plus soft distant
  flickers in between, varied in position and strength.
- Video file naming (app depends on this):
  `<sceneId>_<portrait|landscape>_<1080|720>.mp4`, e.g.
  `window_portrait_1080.mp4` = 1080x1920, `window_landscape_720.mp4` =
  1280x720. Scene ids in display order: window, plains, sea, above.
- Encoding target: HEVC Main10 yuv420p10le, tagged hvc1, bt709, +faststart, no
  audio, keyframe every 2 s. Size budget: 1080p file <= ~22 MB, 720p <= ~11 MB
  for a 40 s loop.

## Writing a scene

```metal
// scenes/window.metal (common.metal is already in front of this)
kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float2 p = frame_uv(gid, u.resolution);    // height units, origin centre, +y up
    float3 col = /* linear light */ float3(0.01f, 0.012f, 0.02f);
    out.write(output_color(col), gid);          // filmic tonemap + sRGB encode
}
```

Notes the harness relies on or provides:

- `u.resolution` is the RENDER size, i.e. output size x `--ss`. Size things in
  height units (`frame_uv`), never in pixels; use `px_size(u.resolution)` only
  for anti-aliasing widths. `_test.metal` shows the "at least ~1 px wide,
  energy conserving" trick for thin streaks.
- The grid is dispatched with `dispatchThreads`, so no thread falls outside the
  texture and no bounds check is needed.
- `u.time` is negative for the second layer inside the crossfade window.
  `u.frame` is the output frame index and is the same for both layers; use
  `u.time` for anything visible.
- Write values in [0,1]; the harness clamps.
- Compile errors are printed with file and line relative to the scene file
  (`window.metal:42:7: error: ...`) and storm-render exits with status 2.
- `--define NAME=VALUE` passes preprocessor macros, handy for tuning without
  editing (`#ifndef NAME / #define NAME default / #endif` in the scene).

### common.metal helpers

| group | functions |
|---|---|
| coordinates | `frame_uv(gid, res)` (height units, origin centre, +y up), `px_size(res)`, `aspect_of`, `is_portrait`, `safe_extent(res)` (half extents visible after aspect-fill on a 19.5:9 phone) |
| hashing | `pcg_hash`, `pcg3d`, `pcg4d`, `u01`; lattice hashes `hash1/hash2/hash3(int2 or int3, seed)`; indexed randoms `rand1/rand2/rand3(k, salt, seed)` for event k |
| noise | value noise `vnoise2/vnoise3` ([0,1]); gradient noise `gnoise2/gnoise3` (~[-1,1]); periodic variants `vnoise2p/vnoise3p/gnoise2p/gnoise3p(p, int period, seed)` with exact `n(p + period) == n(p)` |
| fbm | `fbm2/fbm3(p, octaves, seed)` (rotated octaves, ~[-1,1]); periodic `fbm2p/fbm3p(p, period, octaves, seed)` |
| shaping | `smootherstep`, `linstep`, `remap`, `fade5`, `rot2(a)`, `rot3(axis, a)` |
| timing | `wrap_time(t, L)` (positive mod, works for negative t), `since_event(t, t0, L)`, `flash_env(dt, rise, decay)` |
| colour | `srgb_encode/decode`, `luma709`, `tonemap_filmic` (Narkowicz ACES fit), `tonemap_reinhard(c, white)`, `output_color(linear)` |
| dither | `tpdf(pix, frame, seed)` triangular noise in [-1,1] |

Exactly looping evolution: sample a periodic noise with time on one axis, e.g.
`fbm3p(float3(p * 3.0f, u.time / u.loop * 4.0f), int3(0, 0, 4), 5, u.seed)` changes
continuously and returns to the same field after one loop (period 4 along z
and 4 lattice cells travelled per loop). Periodic x/y needs integer lattice
periods too; a period of 0 on an axis means "not periodic".

Scheduling lightning: put every event at a fixed offset inside the loop and
measure time with `since_event(u.time, t0, u.loop)`, so it is identical in both
crossfade layers, both orientations and on every repeat.

## storm-render CLI

```
storm-render: renders a Metal scene offline to PNG stills, a contact sheet,
or a seamless HEVC Main10 loop (piped to ffmpeg/libx265).

usage: storm-render --scene <id> [options] [--still ..] [--sheet ..] [--video ..] [--bench ..]
At least one of --still, --sheet, --video, --bench is required; they can be combined.

scene
  --scene <id>          scene id, loads scenes/common.metal + scenes/<id>.metal (default _test)
  --scenes-dir <dir>    scene folder (default: the scenes/ folder beside bin/, i.e. render/scenes)
  --define NAME[=VAL]   preprocessor macro for the shader, repeatable (VAL defaults to 1)

frame
  --w <px> --h <px>     output size (default 1080 x 1920)
  --loop <s>            loop length L in seconds (default 40)
  --fps <n>             frame rate (default 30); frame i is rendered at t = i/fps
  --seed <n>            u.seed (default 1)
  --ss <1|2|3>          supersample: render k times larger, box-downsample in linear light (default 1)
  --xfade <s>           loop crossfade B: for t > L-B output mix(F(t), F(t-L)) with a smoothstep
                        weight, so the last frame flows into frame 0 (default 0 = off).
                        Also applies to stills/sheet frames inside the window.
  --dither <lsb>        TPDF dither amplitude in 10-bit LSBs before 16-bit output (default 1, 0 = off)

stills
  --still <t1,t2,...>   write PNG stills at these times (seconds) as <scene>_<w>x<h>_t<time>.png
  --out <dir>           directory for stills (default .)

contact sheet
  --sheet <file.png>    PNG grid of --count frames evenly spaced over the loop, labelled with time
  --count <n>           frames in the sheet (default 12)
  --thumb <px>          long side of each thumbnail (default 320)

video
  --video <file.mp4>    encode the loop: rgba64le -> ffmpeg -> libx265 main10 yuv420p10le, hvc1,
                        bt709 primaries/trc/matrix, limited range, +faststart, no audio,
                        keyframe every 2*fps frames, closed GOP
  --frames <n>          encode only the first n frames (quick tests; default round(L*fps))
  --crf <n>             x265 CRF (default 22.0)
  --preset <p>          x265 preset (default slow)
  --maxrate <kbps>      VBV cap, bufsize = 2x (default: 4000 for 1080p, 2000 for 720p, scaled
                        by pixel count below that; 0 = uncapped)
  --x265 <k=v:k=v>      extra x265 params appended last (default "aq-mode=3", pass "" to clear)
  --ffmpeg <path>       ffmpeg binary (default /opt/homebrew/bin/ffmpeg, else PATH)

other
  --bench <frames>      render <frames> frames spread over the loop, report GPU ms/frame
  --quiet               no progress output
  -h, --help            this text

examples
  storm-render --scene window --w 1080 --h 1920 --still 0,7.5,20 --out /tmp/shots
  storm-render --scene window --w 1920 --h 1080 --sheet /tmp/sheet.png --count 16
  storm-render --scene window --ss 2 --xfade 6 --video window_portrait_1080.mp4
  storm-render --scene window --ss 2 --bench 60
```

### What the harness does per frame

1. Dispatch `scene` into an `rgba16Float` texture of (w x ss) x (h x ss).
2. If t is inside the crossfade window, dispatch `scene` again at t - L into a
   second texture.
3. A harness-internal `resolve` kernel (compiled separately, no fast math):
   box-averages each ss x ss block in LINEAR light (decode sRGB, average,
   re-encode), blends the two layers with a smoothstep weight
   `w = s((t - (L-B)) / B)`, adds monochrome TPDF dither of +-1 LSB at 10-bit
   limited-range scale (1/876, same offset on R, G, B so it lands in luma not
   chroma), and writes rgba64 (16 bit per channel) into a shared-storage
   `MTLBuffer` (unified memory, no blit).
4. Frame i renders on the GPU while frame i-1 is written to ffmpeg's stdin
   (two output buffers). Writes are blocking, which is the backpressure; if
   ffmpeg dies the write fails with EPIPE and storm-render exits with an error.

ffmpeg side: `-f rawvideo -pix_fmt rgba64le` in, swscale converts with
`out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int` to
`yuv420p10le`, then libx265 main10 with
`keyint=2*fps:min-keyint=2*fps:scenecut=0:open-gop=0`, bt709 VUI tags,
optional `vbv-maxrate/vbv-bufsize`, `-tag:v hvc1 -movflags +faststart -an`.

## Recommended encode settings

**Defaults (built into storm-render): `--preset slow --crf 22 --x265 aq-mode=3`,
VBV cap 4000 kbps for 1080p and 2000 kbps for 720p (bufsize 2x), dither 1 LSB,
`--ss 2` in render_all.** The cap is what guarantees the size budget for any
scene; CRF 22 is low enough that the cap only bites on very busy content.

Measured with `_test.metal` (dense three-layer rain over near-black gradients,
`--ss 2 --xfade 6`, 40 s, 1200 frames). "Dark LF error" is the low-frequency
(13 px box blur) Y' error against a lossless encode of the same frame, over
pixels with Y' < 0.12, in 10-bit codes: this is what banding and blocking in
dark gradients look like numerically. 4 codes (10-bit) is 1 code in 8-bit.

| size | preset | crf | cap | MB | dark LF error rms / max |
|---|---|---|---|---|---|
| 1080x1920 | medium | 18 | none | 25.21 | 0.27 / 2.0 |
| 1080x1920 | medium | 20 | none | 21.75 | 0.31 / 2.3 |
| 1080x1920 | medium | 22 | none | 18.77 | 0.38 / 3.2 |
| 1080x1920 | medium | 24 | none | 16.28 | 0.45 / 3.8 |
| 1080x1920 | medium | 26 | none | 14.10 | 0.55 / 4.6 |
| 1080x1920 | medium | 22, aq-mode=2 | none | 14.64 | 0.52 / 3.0 |
| 1080x1920 | medium | 22, --dither 0 | none | 19.60 | 0.35 / 2.8 |
| 1080x1920 | slow | 20 | none | 19.39 | 0.32 / 3.1 |
| 1080x1920 | **slow** | **22** | none | **16.94** | 0.38 / 3.0 |
| 1080x1920 | slow | 24 | none | 14.88 | 0.47 / 3.6 |
| 720x1280 | medium | 18 / 20 / 22 / 24 / 26 | none | 17.66 / 15.06 / 12.86 / 10.99 / 9.40 | (c22) 0.47 / 3.7 |
| 720x1280 | slow | 20 | none | 13.42 | 0.39 / 2.6 |
| 720x1280 | slow | 22 | none | 11.64 (over budget) | 0.48 / 3.3 |
| 720x1280 | slow | 24 | none | 10.12 | 0.60 / 3.6 |
| 720x1280 | slow | 22 | 2100 | 10.71 | 0.60 / 3.8 |
| 720x1280 | slow | 23 | 2100 | 10.66 | 0.53 / 3.2 |

Final defaults, end to end through `render_all.sh _test` (`--ss 2 --xfade 6`,
slow, CRF 22, capped), every file passing `check_video.py` and `avcheck`:

| variant | MB | kbps | loop seam / median diff | encode time (machine under load) |
|---|---|---|---|---|
| portrait 1080 (1080x1920) | 16.97 | 3393 | 6.58 / 6.42 | 293 s |
| landscape 1080 (1920x1080) | 20.40 | 4079 (cap binding) | 7.25 / 7.37 | 293 s |
| portrait 720 (720x1280) | 10.20 | 2040 (cap binding) | 7.03 / 6.84 | 150 s |
| landscape 720 (1280x720) | 10.21 | 2043 (cap binding) | 7.82 / 8.14 | 132 s |

Landscape costs more than portrait for the same scene because a frame that
is 1.78 height units wide holds about 3x the rain columns of one 0.56 wide. With
a 4200 kbps cap landscape 1080 came out at 21.42 MB, too close to 22, hence
4000.

Reading it:

- Every setting stays under 1 code (8-bit) of low-frequency error in the dark
  areas, and an 8x-gain crop of the decoded frames shows faint block edges but
  no contour bands. 10-bit encoding is what kills banding here; CRF mostly
  trades rain-streak detail for size.
- `slow` gives the same quality as `medium` about 10% smaller, at roughly 2x
  the encode time. Worth it for final renders; use `--preset fast` for previews.
- `aq-mode=3` (biases bits toward dark frames) costs about 25% more size than
  the x265 default `aq-mode=2` at equal CRF and buys about 25% less dark error.
  In efficiency it is a wash (aq-mode 3 at CRF 26: 14.10 MB, 0.55; aq-mode 2 at
  CRF 22: 14.64 MB, 0.52). It is kept because it spends the extra bits on the
  dark gradients rather than on rain detail, which is the right trade here.
- The 720p budget is relatively tighter than 1080p (half the bytes for 0.44x
  the pixels, and small frames cost more bits per pixel), so on rain-heavy
  scenes the 2000 kbps cap is what keeps 720p inside 11 MB. The VBV
  undershoots slightly (`2100` cap gave 2143 kbps), hence 2000 not 2200.
- The TPDF dither does not cost size: x265 at these CRFs discards sub-LSB
  noise. It is there to keep the 16-bit RGB -> 10-bit Y'CbCr step unbanded.

Encode speed (M1 8-core, all x265): first clean run 1080p `medium` at 13 fps
(92 s per 40 s loop). The sweep ran while other jobs kept the load average at
30-70, so its timings are pessimistic: 1080p `slow` 330-470 s per loop, 720p
`slow` 120-160 s. GPU render time is not the limit (`_test` at ss2 1080p:
34 ms/frame, so about 29 fps).

## Checking a scene

```bash
B=./bin/storm-render; S=window; O=/tmp/$S; mkdir -p $O

# 1. stills in both orientations (look at them; same times = same events)
$B --scene $S --w 1080 --h 1920 --ss 2 --still 0,5,12.5,30 --out $O
$B --scene $S --w 1920 --h 1080 --ss 2 --still 0,5,12.5,30 --out $O

# 2. contact sheets over the whole loop (with the crossfade you will use)
$B --scene $S --w 1080 --h 1920 --xfade 6 --sheet $O/sheet_p.png --count 16
$B --scene $S --w 1920 --h 1080 --xfade 6 --sheet $O/sheet_l.png --count 16

# 3. GPU cost (keep ss 2 at 1080p well under ~60 ms so x265 stays the bottleneck)
$B --scene $S --w 1080 --h 1920 --ss 2 --bench 60

# 4. fast full-loop preview: seam + flash analysis without the slow preset
$B --scene $S --w 540 --h 960 --xfade 6 --preset fast --video $O/preview.mp4
python3 tools/check_video.py $O/preview.mp4 --no-seam   # add the seam back once xfade is set

# 5. the real thing (all 4 variants, checked)
./render_all.sh $S
```

`check_video.py` prints and asserts: codec hevc, tag hvc1, Main 10,
yuv420p10le, bt709 tags, limited range, no audio, +faststart, keyframe every
2 s, dims (taken from the contract file name if not given), fps, frame count,
duration, size vs budget, bitrate; LOOP SEAM (mean abs Y' difference of last
frame -> first frame against the median consecutive-frame difference, PASS if
seam <= 2 x median + 0.5 codes); FLASH (per-frame mean Y' and display-linear
luminance, a list of lightning-like events with their spacing, the largest
single-frame mean Y' step with fail > 0.15 / warn > 0.10, and WCAG-style large
flashes, i.e. linear rises >= 0.10 with the darker side < 0.8, FAIL if more than
3 start in any 1 s window, counted cyclically over the loop). `--help` lists the
thresholds. A preview at a different size is fine for flash/seam analysis
since the scene is resolution independent.

`bin/avcheck <file> [--w W --h H]` loads the file through AVFoundation:
isPlayable, one video track, no audio, codec `hvc1`, hvcC profile Main10 and
10-bit luma, bt709 colour tags, limited range, frame count, decode to 10-bit
`x420`, and Apple's own Y'CbCr->RGB value of the centre of frame 0.

## render_all.sh

```bash
./render_all.sh                    # window plains sea above, whichever exist
./render_all.sh sea                # one scene
ONLY=720 ./render_all.sh           # only the 720 variants (or ONLY=portrait_1080 ...)
OUT=/tmp/v DRY=1 ./render_all.sh   # print the commands only
```

Writes `../Relaxios/Videos/<id>_<portrait|landscape>_<1080|720>.mp4` (via a
temp file, so a failed render never replaces a good file), runs
`check_video.py` and `avcheck` on each and exits non-zero if anything failed.
Per-scene settings come from `scenes/<id>.conf`; `_test.conf` documents every
variable (`SS XFADE SEED LOOP FPS CRF CRF_1080 CRF_720 PRESET MAXRATE_1080
MAXRATE_720 EXTRA CHECK`). Default `SS=2`, `XFADE=0`.

## Gotchas

- **No `metal` CLI with Command Line Tools.** Shaders are compiled at runtime.
  The harness prepends `#line 1 "common.metal"` and `#line 1 "<id>.metal"`
  markers so compiler errors point at the right file and line. Metal's runtime
  compiler does not report warnings for libraries that compile.
- **Close the parent's copy of the pipe's read end.** Otherwise a crashed
  ffmpeg leaves storm-render blocked forever in `write()` instead of getting
  EPIPE. Verified: a bad `--preset` now fails in under a second with ffmpeg's
  error printed.
- **x265 is the bottleneck, not the GPU.** `_test` at 1080x1920 renders at
  7.5 ms/frame (ss1), 34 ms (ss2), 75 ms (ss3); x265 `slow` encodes 1080p at
  only a few fps, so ss2 is effectively free and ss3 costs little at 1080p.
- **Supersampling averages in linear light.** Thin bright streaks keep their
  energy instead of greying out. With `--ss 1` and outside the crossfade the
  scene's values pass through untouched (no decode/encode roundtrip).
- **The crossfade lowers contrast of the drifting layer mid-fade**: two
  uncorrelated noise fields mixed 50/50 have about 0.7x the contrast. Keep `B`
  long (6-10 s) and the non-periodic layer soft, or make the layer exactly
  periodic with `fbm3p` and use `--xfade 0`.
- **Discrete events must use `since_event(u.time, t0, u.loop)`**, otherwise the
  crossfade shows two half-strength strikes instead of one.
- **Rain is exactly periodic only if each layer moves a whole number of
  repeats per loop**: `v = round(v_wanted * L / rep) * rep / L` (see
  `_test.metal`).
- **`rgba16Float` has an 11-bit mantissa**: fine for display values in [0,1]
  (the harness dithers anyway), not for accumulating anything across frames.
- **TPDF dither and x265**: at shipping CRFs x265 smooths most sub-LSB noise
  away, so the dither mainly protects the 16 -> 10-bit RGB -> Y'CbCr step. The
  measured size cost is in the table above.
- **Colour roundtrip verified**: flat colours through the full pipeline decode
  within about 1 10-bit code (ffmpeg, worst case blue -1.07 codes from 4:2:0
  chroma quantisation) and within about 1.5 8-bit codes through AVFoundation's
  own Y'CbCr->RGB, so the bt709 matrix and limited range tags are right. What
  Apple's display pipeline then does with the BT.709 transfer tag is a display
  decision; judge final brightness of near-black areas on a real iPhone.
- **GPU watchdog**: a single command buffer running for several seconds can be
  killed by macOS. storm-render reports it as a GPU error; lower `--ss` or
  simplify the kernel.
- **macOS has no `timeout`, and zsh does not word-split `$var`**; the shell
  tools here are bash scripts for that reason.
