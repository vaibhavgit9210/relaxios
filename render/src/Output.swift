import CoreGraphics
import CoreText
import Foundation
import ImageIO
import Metal

// MARK: - PNG

/// 8-bit RGBA canvas that can be written as an sRGB PNG.
struct Canvas {
    let w: Int, h: Int
    var px: [UInt8]

    init(w: Int, h: Int, fill: UInt8 = 0) {
        self.w = w; self.h = h
        px = [UInt8](repeating: fill, count: w * h * 4)
        for i in stride(from: 3, to: px.count, by: 4) { px[i] = 255 }
    }

    /// Copies an rgba64 frame, area-averaged down to tw x th, into (x0, y0).
    mutating func blit(_ src: UnsafePointer<UInt16>, sw: Int, sh: Int, x0: Int, y0: Int, tw: Int, th: Int) {
        for ty in 0..<th {
            let sy0 = ty * sh / th, sy1 = max(sy0 + 1, (ty + 1) * sh / th)
            for tx in 0..<tw {
                let sx0 = tx * sw / tw, sx1 = max(sx0 + 1, (tx + 1) * sw / tw)
                var r = 0, g = 0, b = 0
                for sy in sy0..<sy1 {
                    var p = src + (sy * sw + sx0) * 4
                    for _ in sx0..<sx1 {
                        r += Int(p[0]); g += Int(p[1]); b += Int(p[2])
                        p += 4
                    }
                }
                let n = (sy1 - sy0) * (sx1 - sx0) * 257
                let d = ((y0 + ty) * w + x0 + tx) * 4
                px[d] = UInt8((r + n / 2) / n)
                px[d + 1] = UInt8((g + n / 2) / n)
                px[d + 2] = UInt8((b + n / 2) / n)
            }
        }
    }

    /// Draws white text with its top-left at (x, y) in canvas pixels.
    mutating func text(_ s: String, x: Int, y: Int, size: CGFloat) {
        let (cw, chh) = (w, h)
        px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: cw, height: chh, bitsPerComponent: 8, bytesPerRow: cw * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            let font = CTFontCreateWithName("Menlo" as CFString, size, nil)
            let attrs: [NSAttributedString.Key: Any] = [
                NSAttributedString.Key(kCTFontAttributeName as String): font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(red: 1, green: 1, blue: 1, alpha: 0.92),
            ]
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: s, attributes: attrs))
            ctx.setShadow(offset: .zero, blur: 3, color: CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.textPosition = CGPoint(x: CGFloat(x), y: CGFloat(chh - y) - size)
            CTLineDraw(line, ctx)
        }
    }

    func writePNG(_ path: String) {
        let data = Data(px)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
              let dst = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { fail("cannot create \(path)") }
        CGImageDestinationAddImage(dst, img, nil)
        if !CGImageDestinationFinalize(dst) { fail("cannot write \(path)") }
    }
}

func timeLabel(_ t: Double) -> String { String(format: "%g", t) }

// MARK: - ffmpeg sink

/// Runs ffmpeg reading raw rgba64le frames from stdin. Writes block while
/// ffmpeg is busy (that is the backpressure); a dead ffmpeg surfaces as EPIPE.
final class FFmpegSink {
    private let proc = Process()
    private let fd: Int32
    private let pipe = Pipe()

    init(_ o: Options, path: String) {
        let gop = Int((2 * o.fps).rounded())
        let maxrate = o.maxrate ?? Defaults.maxrate(w: o.w, h: o.h)
        var params = "keyint=\(gop):min-keyint=\(gop):scenecut=0:open-gop=0"
            + ":colorprim=bt709:transfer=bt709:colormatrix=bt709:range=limited:log-level=error"
        if maxrate > 0 { params += ":vbv-maxrate=\(maxrate):vbv-bufsize=\(2 * maxrate)" }
        if !o.x265.isEmpty { params += ":" + o.x265 }

        let fps = o.fps == o.fps.rounded() ? String(Int(o.fps)) : String(o.fps)
        let args = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "rawvideo", "-pix_fmt", "rgba64le", "-s", "\(o.w)x\(o.h)", "-framerate", fps, "-i", "-",
            // RGB is full range; convert to limited-range BT.709 Y'CbCr 4:2:0 10-bit.
            "-vf", "scale=out_color_matrix=bt709:out_range=tv:flags=accurate_rnd+full_chroma_int,format=yuv420p10le",
            "-c:v", "libx265", "-preset", o.preset, "-crf", String(o.crf), "-profile:v", "main10",
            "-x265-params", params,
            "-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv",
            "-tag:v", "hvc1", "-movflags", "+faststart", "-an", path,
        ]
        if o.ffmpeg.contains("/") {
            proc.executableURL = URL(fileURLWithPath: o.ffmpeg)
            proc.arguments = args
        } else {
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            proc.arguments = [o.ffmpeg] + args
        }
        proc.standardInput = pipe
        do { try proc.run() } catch { fail("cannot start \(o.ffmpeg): \(error)") }
        // Drop our copy of the read end, otherwise a crashed ffmpeg would leave
        // writes blocked forever instead of failing with EPIPE.
        try? pipe.fileHandleForReading.close()
        fd = pipe.fileHandleForWriting.fileDescriptor
    }

    func write(_ base: UnsafeRawPointer, _ count: Int) {
        var off = 0
        while off < count {
            let n = Darwin.write(fd, base + off, count - off)
            if n > 0 { off += n; continue }
            if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            proc.waitUntilExit()
            fail("ffmpeg stopped reading (exit \(proc.terminationStatus)); see its error above")
        }
    }

    func finish() {
        try? pipe.fileHandleForWriting.close()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 { fail("ffmpeg failed with exit code \(proc.terminationStatus)") }
    }
}
