import Foundation
import Metal

signal(SIGPIPE, SIG_IGN)
setvbuf(stdout, nil, _IOLBF, 0)

let o = parseOptions(CommandLine.arguments)
let r = Renderer(o)
let N = o.loopFrames

func log(_ s: String) {
    if !o.quiet { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
}

func frameIndex(_ t: Double) -> Int { Int((t * o.fps).rounded()) }

func pixels(_ b: MTLBuffer) -> UnsafePointer<UInt16> {
    UnsafePointer(b.contents().assumingMemoryBound(to: UInt16.self))
}

log("scene \(o.scene)  \(o.w)x\(o.h)  ss \(o.ss) (render \(r.rw)x\(r.rh))  loop \(o.loop)s @ \(o.fps)fps = \(N) frames  seed \(o.seed)  xfade \(o.xfade)s")

// MARK: bench

if o.bench > 0 {
    let buf = r.makeOutputBuffer()
    for _ in 0..<2 { Renderer.check(r.render(frame: 0, time: 0, into: buf)) }  // warm-up
    var ms: [Double] = []
    var faded = 0
    let wall = Date()
    for k in 0..<o.bench {
        let i = k * N / o.bench
        let t = Double(i) / o.fps
        if r.crossfade(at: t) != nil { faded += 1 }
        let cb = r.render(frame: i, time: t, into: buf)
        Renderer.check(cb)
        ms.append((cb.gpuEndTime - cb.gpuStartTime) * 1000)
    }
    let total = Date().timeIntervalSince(wall)
    let sorted = ms.sorted()
    let mean = ms.reduce(0, +) / Double(ms.count)
    print(String(format: "bench %@ %dx%d ss%d: GPU ms/frame mean %.2f  median %.2f  max %.2f  (%d frames, %d in crossfade)  wall %.1f fps",
                 o.scene, o.w, o.h, o.ss, mean, sorted[sorted.count / 2], sorted.last!, ms.count, faded, Double(ms.count) / total))
}

// MARK: stills

if !o.stills.isEmpty {
    try? FileManager.default.createDirectory(atPath: o.outDir, withIntermediateDirectories: true)
    let buf = r.makeOutputBuffer()
    for t in o.stills {
        Renderer.check(r.render(frame: frameIndex(t), time: t, into: buf))
        var c = Canvas(w: o.w, h: o.h)
        c.blit(pixels(buf), sw: o.w, sh: o.h, x0: 0, y0: 0, tw: o.w, th: o.h)
        let path = (o.outDir as NSString).appendingPathComponent("\(o.scene)_\(o.w)x\(o.h)_t\(timeLabel(t)).png")
        c.writePNG(path)
        print(path)
    }
}

// MARK: contact sheet

if let sheet = o.sheet {
    let (tw, th) = o.w >= o.h ? (o.thumb, o.thumb * o.h / o.w) : (o.thumb * o.w / o.h, o.thumb)
    let cols = max(1, min(o.count, Int((Double(o.count) * 1.6 * Double(th) / Double(tw)).squareRoot().rounded(.up))))
    let rows = (o.count + cols - 1) / cols
    let gap = 4, header = 22
    var c = Canvas(w: cols * tw + (cols + 1) * gap, h: header + rows * th + (rows + 1) * gap, fill: 24)
    c.text("\(o.scene)  \(o.w)x\(o.h)  ss\(o.ss)  xfade \(timeLabel(o.xfade))s  seed \(o.seed)  loop \(timeLabel(o.loop))s",
           x: gap + 2, y: 4, size: 13)
    let buf = r.makeOutputBuffer()
    for k in 0..<o.count {
        let i = k * N / o.count
        let t = Double(i) / o.fps
        Renderer.check(r.render(frame: i, time: t, into: buf))
        let x = gap + (k % cols) * (tw + gap), y = header + gap + (k / cols) * (th + gap)
        c.blit(pixels(buf), sw: o.w, sh: o.h, x0: x, y0: y, tw: tw, th: th)
        c.text(String(format: "t=%.2fs", t), x: x + 5, y: y + 4, size: 11)
    }
    c.writePNG(sheet)
    print(sheet)
}

// MARK: video

if let video = o.video {
    let total = min(o.frames ?? N, N)
    let sink = FFmpegSink(o, path: video)
    let bufs = [r.makeOutputBuffer(), r.makeOutputBuffer()]
    let bytes = o.w * o.h * 8
    let start = Date()
    var lastReport = start
    var prev: MTLCommandBuffer?

    // Double buffering: frame i renders on the GPU while frame i-1 is written
    // to ffmpeg. Writing is synchronous, so a buffer is free again by the time
    // frame i+2 wants it.
    for i in 0...total {
        let cb = i < total ? r.render(frame: i, time: Double(i) / o.fps, into: bufs[i % 2]) : nil
        if let p = prev {
            Renderer.check(p)
            sink.write(bufs[(i - 1) % 2].contents(), bytes)
            let now = Date()
            if now.timeIntervalSince(lastReport) > 1 || i == total {
                lastReport = now
                let fps = Double(i) / now.timeIntervalSince(start)
                let eta = Double(total - i) / max(fps, 1e-6)
                if !o.quiet {
                    FileHandle.standardError.write(String(format: "\r  frame %d/%d  %.1f fps  eta %.0fs   ", i, total, fps, eta).data(using: .utf8)!)
                }
            }
        }
        prev = cb
    }
    sink.finish()
    let secs = Date().timeIntervalSince(start)
    let size = (try? FileManager.default.attributesOfItem(atPath: video)[.size] as? Int) ?? 0
    let dur = Double(total) / o.fps
    log("")
    print(String(format: "%@  %d frames in %.1fs (%.1f fps)  %.2f MB  %.0f kbps", video, total, secs, Double(total) / secs,
                 Double(size) / 1e6, Double(size) * 8 / dur / 1000))
}
