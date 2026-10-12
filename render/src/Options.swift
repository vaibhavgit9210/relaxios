import Foundation

/// Encoder defaults. Chosen from the _test.metal measurements in README.md.
enum Defaults {
    static let crf: Double = 22
    static let preset = "slow"
    static let x265 = "aq-mode=3"

    /// Size-budget cap in kbps when --maxrate is not given: 1080p files must
    /// stay under ~22 MB and 720p under ~11 MB for a 40 s loop.
    static func maxrate(w: Int, h: Int) -> Int {
        let long = max(w, h)
        if long >= 1920 { return 4000 }
        if long >= 1280 { return 2000 }
        return max(300, Int(2000.0 * Double(w * h) / (1280.0 * 720.0)))
    }
}

struct Options {
    var scene = "_test"
    var scenesDir = ""
    var w = 1080
    var h = 1920
    var loop = 40.0
    var fps = 30.0
    var seed: UInt32 = 1
    var ss = 1
    var xfade = 0.0
    var dither = 1.0
    var defines: [String: String] = [:]

    var stills: [Double] = []
    var outDir = "."
    var sheet: String?
    var count = 12
    var thumb = 320

    var video: String?
    var frames: Int?
    var crf = Defaults.crf
    var preset = Defaults.preset
    var maxrate: Int?
    var x265 = Defaults.x265
    var ffmpeg = ""

    var bench = 0
    var quiet = false

    var loopFrames: Int { Int((loop * fps).rounded()) }
}

let helpText = """
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
  --crf <n>             x265 CRF (default \(Defaults.crf))
  --preset <p>          x265 preset (default \(Defaults.preset))
  --maxrate <kbps>      VBV cap, bufsize = 2x (default: 4000 for 1080p, 2000 for 720p, scaled
                        by pixel count below that; 0 = uncapped)
  --x265 <k=v:k=v>      extra x265 params appended last (default "\(Defaults.x265)", pass "" to clear)
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
"""

func fail(_ msg: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(("storm-render: " + msg + "\n").data(using: .utf8)!)
    exit(code)
}

func parseOptions(_ argv: [String]) -> Options {
    var o = Options()
    var i = 1
    func value(_ flag: String) -> String {
        i += 1
        guard i < argv.count else { fail("\(flag) needs a value") }
        return argv[i]
    }
    func number(_ flag: String) -> Double {
        let s = value(flag)
        guard let d = Double(s) else { fail("\(flag): '\(s)' is not a number") }
        return d
    }
    func integer(_ flag: String) -> Int {
        let s = value(flag)
        guard let n = Int(s) else { fail("\(flag): '\(s)' is not an integer") }
        return n
    }
    while i < argv.count {
        let a = argv[i]
        switch a {
        case "-h", "--help": print(helpText); exit(0)
        case "--scene": o.scene = value(a)
        case "--scenes-dir": o.scenesDir = value(a)
        case "--define":
            let d = value(a)
            let parts = d.split(separator: "=", maxSplits: 1).map(String.init)
            o.defines[parts[0]] = parts.count > 1 ? parts[1] : "1"
        case "--w": o.w = integer(a)
        case "--h": o.h = integer(a)
        case "--loop": o.loop = number(a)
        case "--fps": o.fps = number(a)
        case "--seed":
            let s = value(a)
            guard let n = UInt32(s) else { fail("--seed: '\(s)' is not a uint32") }
            o.seed = n
        case "--ss": o.ss = integer(a)
        case "--xfade": o.xfade = number(a)
        case "--dither": o.dither = number(a)
        case "--still":
            o.stills = value(a).split(separator: ",").map {
                guard let d = Double($0.trimmingCharacters(in: .whitespaces)) else { fail("--still: bad time '\($0)'") }
                return d
            }
        case "--out": o.outDir = value(a)
        case "--sheet": o.sheet = value(a)
        case "--count": o.count = integer(a)
        case "--thumb": o.thumb = integer(a)
        case "--video": o.video = value(a)
        case "--frames": o.frames = integer(a)
        case "--crf": o.crf = number(a)
        case "--preset": o.preset = value(a)
        case "--maxrate": o.maxrate = integer(a)
        case "--x265": o.x265 = value(a)
        case "--ffmpeg": o.ffmpeg = value(a)
        case "--bench": o.bench = integer(a)
        case "--quiet": o.quiet = true
        default: fail("unknown argument '\(a)' (see --help)")
        }
        i += 1
    }

    if o.w < 16 || o.h < 16 || o.w % 2 != 0 || o.h % 2 != 0 { fail("--w/--h must be even and >= 16") }
    if !(1...3).contains(o.ss) { fail("--ss must be 1, 2 or 3") }
    if o.loop <= 0 || o.fps <= 0 { fail("--loop and --fps must be positive") }
    if abs(o.loop * o.fps - Double(o.loopFrames)) > 1e-6 { fail("--loop * --fps must be a whole number of frames") }
    if o.xfade < 0 || o.xfade >= o.loop { fail("--xfade must be in [0, loop)") }
    if o.count < 1 { fail("--count must be >= 1") }
    if let f = o.frames, f < 1 { fail("--frames must be >= 1") }
    if o.stills.isEmpty && o.sheet == nil && o.video == nil && o.bench <= 0 {
        fail("nothing to do: pass --still, --sheet, --video or --bench (see --help)")
    }
    if o.scenesDir.isEmpty {
        // bin/storm-render lives in render/bin, scenes in render/scenes.
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        o.scenesDir = exe.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scenes").path
    }
    if o.ffmpeg.isEmpty {
        o.ffmpeg = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/ffmpeg") ? "/opt/homebrew/bin/ffmpeg" : "ffmpeg"
    }
    return o
}
