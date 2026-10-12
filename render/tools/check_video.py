#!/usr/bin/env python3
"""check_video.py: assert that a rendered loop is fit to ship.

usage: check_video.py <file.mp4> [options]

Checks (exit 1 if any FAIL):
  format  hevc, hvc1 tag, Main 10, yuv420p10le, bt709 tags, limited range,
          no audio, keyframe every 2 s, dims (from --w/--h or the contract file
          name <scene>_<portrait|landscape>_<1080|720>.mp4), size budget.
  seam    mean |Y'| difference of last frame -> first frame against the median
          consecutive-frame difference. PASS if seam <= ratio * median + floor.
  flash   per-frame mean luma. "Large flash" follows WCAG 2.x general flash on
          the frame average: an opposing pair of changes of >= --flash-delta in
          relative (linear) luminance with the darker side < 0.8. FAIL if more
          than 3 large flashes start in any 1 s window (the loop is treated as
          cyclic). Also lists every lightning-like event (mean Y' rise >=
          --event within 4 frames) so a scene's schedule can be eyeballed, and
          FAILs if a single frame step of mean Y' exceeds --max-jump.

Python 3 stdlib only; all decoding and statistics are done by ffmpeg filters.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import tempfile

FFMPEG = "/opt/homebrew/bin/ffmpeg" if os.path.exists("/opt/homebrew/bin/ffmpeg") else "ffmpeg"
FFPROBE = "/opt/homebrew/bin/ffprobe" if os.path.exists("/opt/homebrew/bin/ffprobe") else "ffprobe"
NAME_RE = re.compile(r"(?P<scene>[^/]+)_(?P<orient>portrait|landscape)_(?P<res>1080|720)\.mp4$")

fails = []
warns = []


def report(status, msg):
    print(f"  [{status}] {msg}")
    if status == "FAIL":
        fails.append(msg)
    elif status == "warn":
        warns.append(msg)


def check(ok, msg):
    report("ok" if ok else "FAIL", msg)


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True)
    if p.returncode != 0:
        sys.exit(f"command failed: {' '.join(cmd)}\n{p.stderr}")
    return p.stdout


def read_yavg(path):
    """Parse a metadata=print file into a list of YAVG floats, in frame order."""
    vals = []
    with open(path) as f:
        for line in f:
            if line.startswith("lavfi.signalstats.YAVG="):
                vals.append(float(line.split("=", 1)[1]))
    return vals


def median(xs):
    s = sorted(xs)
    n = len(s)
    return s[n // 2] if n % 2 else 0.5 * (s[n // 2 - 1] + s[n // 2])


def zigzag(xs, th):
    """Alternating extremes [(index, value)] of a series; swings smaller than
    th are ignored."""
    ext = []
    lo = hi = 0
    trend = 0  # +1 rising (hunting a top), -1 falling (hunting a bottom), 0 undecided
    for i, v in enumerate(xs):
        if trend >= 0 and v > xs[hi]:
            hi = i
        if trend <= 0 and v < xs[lo]:
            lo = i
        if trend >= 0 and xs[hi] - v >= th:
            if trend == 0 and lo < hi:
                ext.append((lo, xs[lo]))
            ext.append((hi, xs[hi]))
            trend, lo = -1, i
        elif trend <= 0 and v - xs[lo] >= th:
            if trend == 0 and hi < lo:
                ext.append((hi, xs[hi]))
            ext.append((lo, xs[lo]))
            trend, hi = 1, i
    if trend == 1:
        ext.append((hi, xs[hi]))
    elif trend == -1:
        ext.append((lo, xs[lo]))
    return ext


def rises(series, thresh, darker_max=None):
    """(start_index, peak_index, base, peak) for each rise of >= thresh."""
    ev = []
    ext = zigzag(series, thresh)
    for (i0, v0), (i1, v1) in zip(ext, ext[1:]):
        if v1 - v0 >= thresh and (darker_max is None or v0 < darker_max):
            ev.append((i0, i1, v0, v1))
    return ev


def fast_rises(xs, th, k):
    """Lightning-like onsets: frames where the series sits >= th above its
    minimum over the previous k frames. Consecutive frames form one event
    (a return stroke after a partial decay is a new event).
    Returns [(onset_index, peak_index, base, peak)]."""
    ev = []
    cur = None
    for i in range(1, len(xs)):
        j0 = max(0, i - k)
        base_i = min(range(j0, i), key=lambda j: (xs[j], -j))  # latest minimum
        if xs[i] - xs[base_i] >= th:
            if cur is None:
                cur = [base_i, i, xs[base_i], xs[i]]
            elif xs[i] > cur[3]:
                cur[1], cur[3] = i, xs[i]
        elif cur is not None:
            ev.append(tuple(cur))
            cur = None
    if cur is not None:
        ev.append(tuple(cur))
    return ev


def max_per_window(starts, n, win):
    """Max number of event starts in any window of `win` frames on a cyclic
    timeline of n frames."""
    if not starts:
        return 0, None
    s = sorted(starts)
    ext = s + [x + n for x in s]
    best, at = 0, None
    j = 0
    for i in range(len(s)):
        while j < len(ext) and ext[j] < ext[i] + win:
            j += 1
        if j - i > best:
            best, at = j - i, s[i]
    return best, at


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("file")
    ap.add_argument("--w", type=int, help="expected width (default: from contract file name)")
    ap.add_argument("--h", type=int, help="expected height (default: from contract file name)")
    ap.add_argument("--fps", type=float, default=30.0, help="expected fps (default 30)")
    ap.add_argument("--frames", type=int, help="expected frame count (default: skip)")
    ap.add_argument("--max-mb", type=float, help="size budget in MB (default 22 for 1080p, 11 for 720p)")
    ap.add_argument("--seam-ratio", type=float, default=2.0, help="seam must be <= ratio * median diff + floor (default 2)")
    ap.add_argument("--seam-floor", type=float, default=0.5, help="absolute allowance in 10-bit codes (default 0.5)")
    ap.add_argument("--flash-delta", type=float, default=0.10, help="large-flash change in relative luminance (default 0.10)")
    ap.add_argument("--event", type=float, default=0.02, help="event rise in mean Y' 0..1 for the event list (default 0.02)")
    ap.add_argument("--max-jump", type=float, default=0.15, help="FAIL above this single-frame mean Y' step, 0..1 (default 0.15)")
    ap.add_argument("--warn-jump", type=float, default=0.10, help="warn above this single-frame mean Y' step (default 0.10)")
    ap.add_argument("--no-seam", action="store_true", help="skip the loop seam check (non-loop clips)")
    a = ap.parse_args()

    path = a.file
    print(f"check_video {path}")
    if not os.path.exists(path):
        sys.exit(f"no such file: {path}")

    # ---- format
    probe = json.loads(run([FFPROBE, "-v", "error", "-show_streams", "-show_format", "-of", "json", path]))
    streams = probe["streams"]
    vs = [s for s in streams if s["codec_type"] == "video"]
    check(len(vs) == 1, f"one video stream (found {len(vs)})")
    check(not any(s["codec_type"] == "audio" for s in streams), "no audio stream")
    v = vs[0]
    fmt = probe["format"]
    w, h = int(v["width"]), int(v["height"])
    num, den = (int(x) for x in v["r_frame_rate"].split("/"))
    fps = num / den
    nb = int(v.get("nb_frames", 0))
    dur = float(fmt["duration"])
    size = int(fmt["size"])
    kbps = size * 8 / dur / 1000
    print(f"  {w}x{h}  {fps:g} fps  {nb} frames  {dur:.3f} s  {size / 1e6:.2f} MB  {kbps:.0f} kbps")

    check(v["codec_name"] == "hevc", f"codec {v['codec_name']} == hevc")
    check(v.get("codec_tag_string") == "hvc1", f"tag {v.get('codec_tag_string')} == hvc1")
    check(v.get("profile") == "Main 10", f"profile {v.get('profile')} == Main 10")
    check(v["pix_fmt"] == "yuv420p10le", f"pix_fmt {v['pix_fmt']} == yuv420p10le")
    for key in ("color_primaries", "color_transfer", "color_space"):
        check(v.get(key) == "bt709", f"{key} {v.get(key)} == bt709")
    check(v.get("color_range") == "tv", f"color_range {v.get('color_range')} == tv")
    check(abs(fps - a.fps) < 1e-3, f"fps {fps:g} == {a.fps:g}")
    check(abs(dur - nb / fps) < 1.5 / fps, f"duration {dur:.3f}s matches {nb} frames")
    if a.frames:
        check(nb == a.frames, f"frames {nb} == {a.frames}")

    m = NAME_RE.search(path)
    ew, eh = a.w, a.h
    if m and (ew is None or eh is None):
        long_, short = (1920, 1080) if m["res"] == "1080" else (1280, 720)
        ew, eh = (short, long_) if m["orient"] == "portrait" else (long_, short)
    if ew and eh:
        check((w, h) == (ew, eh), f"size {w}x{h} == {ew}x{eh}")
    budget = a.max_mb or (22.0 if max(w, h) >= 1920 else 11.0 if max(w, h) >= 1280 else None)
    if budget:
        check(size / 1e6 <= budget, f"size {size / 1e6:.2f} MB <= {budget:g} MB")

    # moov before mdat (+faststart) and keyframe cadence, from the container only.
    with open(path, "rb") as f:
        head = f.read(1 << 16)
    moov, mdat = head.find(b"moov"), head.find(b"mdat")
    check(moov != -1 and (mdat == -1 or moov < mdat), "moov atom before mdat (+faststart)")
    pk = run([FFPROBE, "-v", "error", "-select_streams", "v:0", "-show_entries", "packet=pts_time,flags", "-of", "csv=p=0", path])
    keys = sorted(float(l.split(",")[0]) for l in pk.splitlines() if "K" in l.split(",")[-1])
    gaps = [b - a_ for a_, b in zip(keys, keys[1:])]
    if gaps:
        check(max(gaps) <= 2.0 + 1e-3 and min(gaps) >= 2.0 - 1e-3, f"keyframe every 2 s ({len(keys)} keyframes, gaps {min(gaps):.3f}..{max(gaps):.3f})")
    else:
        check(dur <= 2.0 + 1e-3, f"keyframe every 2 s (only {len(keys)} keyframe)")

    # ---- decode once: consecutive diffs, seam pair, mean Y' and mean linear luminance
    with tempfile.TemporaryDirectory() as td:
        f_diff, f_y, f_lin, f_seam = (os.path.join(td, n) for n in ("diff", "y", "lin", "seam"))
        last = nb - 1

        def pr(f):
            return f"metadata=mode=print:key=lavfi.signalstats.YAVG:file='{f}'"

        graph = (
            "[0:v]split=3[d][l][s];"
            f"[d]tblend=all_mode=difference,signalstats,{pr(f_diff)}[d2];"
            # Mean Y', then mean display-linear luminance (BT.1886 gamma 2.4 on limited range Y').
            f"[l]signalstats,{pr(f_y)},lutyuv=y='1023*pow(clip((val-64)/876\\,0\\,1)\\,2.4)',signalstats,{pr(f_lin)}[l2];"
            f"[s]select='eq(n\\,0)+eq(n\\,{last})',tblend=all_mode=difference,signalstats,{pr(f_seam)}[s2]"
        )
        run([FFMPEG, "-hide_banner", "-loglevel", "error", "-i", path, "-filter_complex", graph,
             "-map", "[d2]", "-f", "null", "-", "-map", "[l2]", "-f", "null", "-", "-map", "[s2]", "-f", "null", "-"])
        diffs, ys, lins, seam = read_yavg(f_diff), read_yavg(f_y), read_yavg(f_lin), read_yavg(f_seam)

    n = len(ys)
    check(n == nb, f"decoded {n} frames")
    ynorm = [(y - 64.0) / 876.0 for y in ys]
    lin = [x / 1023.0 for x in lins]

    # ---- seam
    if not a.no_seam and diffs and seam:
        med = median(diffs)
        s = seam[0]
        p90 = sorted(diffs)[int(0.9 * (len(diffs) - 1))]
        limit = a.seam_ratio * med + a.seam_floor
        print(f"  seam: last->first {s:.3f}  median consecutive {med:.3f}  p90 {p90:.3f}  "
              f"neighbours {diffs[-1]:.3f} (n-2->n-1) / {diffs[0]:.3f} (0->1)  [10-bit codes]")
        check(s <= limit, f"loop seam {s:.3f} <= {a.seam_ratio:g} x median + {a.seam_floor:g} = {limit:.3f}  (ratio {s / max(med, 1e-9):.2f})")

    # ---- flash
    if n > 1:
        win = max(1, int(round(fps)))
        cyc_y = ynorm + ynorm[:1]
        jumps = [abs(b - a_) for a_, b in zip(cyc_y, cyc_y[1:])]
        cyc_l = lin + lin[:1]
        ljumps = [abs(b - a_) for a_, b in zip(cyc_l, cyc_l[1:])]
        j = max(range(len(jumps)), key=jumps.__getitem__)
        print(f"  luma: mean Y' {sum(ynorm) / n:.3f} (min {min(ynorm):.3f} max {max(ynorm):.3f})  "
              f"linear {sum(lin) / n:.4f} (max {max(lin):.4f})")
        status = "FAIL" if jumps[j] > a.max_jump else "warn" if jumps[j] > a.warn_jump else "ok"
        report(status, f"max single-frame mean Y' step {jumps[j]:.3f} (fail > {a.max_jump:g}, warn > {a.warn_jump:g}) "
               f"at frame {j}->{(j + 1) % n}, t={j / fps:.2f}s; linear step {max(ljumps):.4f}")

        # Event list: fast rises of the mean Y' (within 4 frames), on a wrapped
        # series so an event straddling the loop point is still seen.
        ext_y = ynorm + ynorm[: 2 * win]
        events = [e for e in fast_rises(ext_y, a.event, 4) if e[0] < n]
        print(f"  events (mean Y' rise >= {a.event:g} within 4 frames): {len(events)}")
        for i0, i1, v0, v1 in events:
            print(f"    t={i0 / fps:6.2f}s  rise {v1 - v0:+.3f} to peak in {i1 - i0} frames  ({v0:.3f} -> {v1:.3f})")
        ev_max, ev_at = max_per_window([e[0] for e in events], n, win)
        starts = [e[0] for e in events]
        gaps = sorted((starts[(k + 1) % len(starts)] - starts[k]) % n / fps for k in range(len(starts))) if len(starts) > 1 else []
        if gaps:
            print(f"  event spacing: min {gaps[0]:.2f}s  max {gaps[-1]:.2f}s")
        if ev_max > 3:
            report("warn", f"{ev_max} events start within 1 s near t={ev_at / fps:.2f}s")

        # WCAG-style large flashes on linear luminance.
        ext_l = lin + lin[: 2 * win]
        large = [e for e in rises(ext_l, a.flash_delta, darker_max=0.8) if e[0] < n]
        lf_max, lf_at = max_per_window([e[0] for e in large], n, win)
        where = f" (near t={lf_at / fps:.2f}s)" if lf_at is not None else ""
        check(lf_max <= 3, f"large flashes (linear rise >= {a.flash_delta:g}): {len(large)} total, max {lf_max} in any 1 s{where} <= 3")

    print(f"  {'PASS' if not fails else 'FAIL'}" + (f" ({len(fails)} failed)" if fails else "") + (f", {len(warns)} warning(s)" if warns else ""))
    sys.exit(1 if fails else 0)


if __name__ == "__main__":
    main()
