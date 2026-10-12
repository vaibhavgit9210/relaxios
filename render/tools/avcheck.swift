// avcheck: confirms AVFoundation (the stack iOS plays through) accepts a
// rendered loop: playable, hvc1, Main10 10-bit, size, duration, frame count,
// colour tags, and that a 10-bit decode works. Also prints Apple's own
// Y'CbCr -> RGB conversion of the centre pixel of frame 0 (colour roundtrip).
//
// usage: avcheck <file.mp4> [--w <px> --h <px>]   exit 1 on any failure

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation

var args = Array(CommandLine.arguments.dropFirst())
guard let path = args.first, !path.hasPrefix("-") else {
    print("usage: avcheck <file.mp4> [--w <px> --h <px>]"); exit(2)
}
var expectW: Int?, expectH: Int?
if let i = args.firstIndex(of: "--w"), i + 1 < args.count { expectW = Int(args[i + 1]) }
if let i = args.firstIndex(of: "--h"), i + 1 < args.count { expectH = Int(args[i + 1]) }

var failures: [String] = []
func check(_ ok: Bool, _ what: String) {
    print("  [\(ok ? "ok" : "FAIL")] \(what)")
    if !ok { failures.append(what) }
}

func fourCC(_ v: FourCharCode) -> String {
    String(bytes: [24, 16, 8, 0].map { UInt8((v >> $0) & 0xFF) }, encoding: .ascii) ?? "?"
}

/// Reads the first sample of `track` decoded to `format`.
func firstPixelBuffer(_ asset: AVAsset, _ track: AVAssetTrack, _ format: OSType) -> CVPixelBuffer? {
    guard let reader = try? AVAssetReader(asset: asset) else { return nil }
    let out = AVAssetReaderTrackOutput(track: track, outputSettings: [kCVPixelBufferPixelFormatTypeKey as String: format])
    reader.add(out)
    guard reader.startReading(), let s = out.copyNextSampleBuffer() else { return nil }
    reader.cancelReading()
    return CMSampleBufferGetImageBuffer(s)
}

let url = URL(fileURLWithPath: path)
let asset = AVURLAsset(url: url)
print("avcheck \(path)")
do {
    let (playable, duration, tracks) = try await asset.load(.isPlayable, .duration, .tracks)
    check(playable, "AVURLAsset isPlayable")
    let video = tracks.filter { $0.mediaType == .video }
    check(video.count == 1, "exactly one video track (found \(video.count))")
    check(tracks.allSatisfy { $0.mediaType != .audio }, "no audio track")
    guard let track = video.first else { throw CocoaError(.fileReadCorruptFile) }

    let (size, fps, fds) = try await track.load(.naturalSize, .nominalFrameRate, .formatDescriptions)
    print(String(format: "  natural size %.0fx%.0f  duration %.3fs  nominal %.3f fps", size.width, size.height, duration.seconds, fps))
    if let w = expectW { check(Int(size.width) == w, "width \(Int(size.width)) == \(w)") }
    if let h = expectH { check(Int(size.height) == h, "height \(Int(size.height)) == \(h)") }

    guard let fd = fds.first else { throw CocoaError(.fileReadCorruptFile) }
    let sub = CMFormatDescriptionGetMediaSubType(fd)
    check(fourCC(sub) == "hvc1", "codec tag \(fourCC(sub)) == hvc1")

    if let atoms = CMFormatDescriptionGetExtension(fd, extensionKey: kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms) as? [String: Any],
       let hvcC = atoms["hvcC"] as? Data, hvcC.count > 18 {
        let profile = Int(hvcC[1] & 0x1F)
        let depth = Int(hvcC[17] & 0x07) + 8
        check(profile == 2, "HEVC profile idc \(profile) == 2 (Main10)")
        check(depth == 10, "luma bit depth \(depth) == 10")
    } else {
        check(false, "hvcC atom present")
    }

    let ext = CMFormatDescriptionGetExtensions(fd) as? [String: Any] ?? [:]
    let prim = ext[kCMFormatDescriptionExtension_ColorPrimaries as String] as? String ?? "untagged"
    let trc = ext[kCMFormatDescriptionExtension_TransferFunction as String] as? String ?? "untagged"
    let mat = ext[kCMFormatDescriptionExtension_YCbCrMatrix as String] as? String ?? "untagged"
    let full = ext[kCMFormatDescriptionExtension_FullRangeVideo as String] as? Bool ?? false
    check(prim == (kCMFormatDescriptionColorPrimaries_ITU_R_709_2 as String), "colour primaries \(prim)")
    check(trc == (kCMFormatDescriptionTransferFunction_ITU_R_709_2 as String), "transfer function \(trc)")
    check(mat == (kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2 as String), "Y'CbCr matrix \(mat)")
    check(!full, "video (limited) range")

    // Count samples without decoding.
    let reader = try AVAssetReader(asset: asset)
    let pass = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    reader.add(pass)
    reader.startReading()
    var frames = 0
    while let s = pass.copyNextSampleBuffer() { frames += CMSampleBufferGetNumSamples(s) }
    check(reader.status == .completed, "sample read completed")
    print("  frames \(frames)")

    let tenBit = firstPixelBuffer(asset, track, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
    check(tenBit.map { CVPixelBufferGetPixelFormatType($0) == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange } ?? false,
          "decodes to 10-bit 4:2:0 (x420)")

    if let bgra = firstPixelBuffer(asset, track, kCVPixelFormatType_32BGRA) {
        CVPixelBufferLockBaseAddress(bgra, .readOnly)
        let w = CVPixelBufferGetWidth(bgra), h = CVPixelBufferGetHeight(bgra), row = CVPixelBufferGetBytesPerRow(bgra)
        let base = CVPixelBufferGetBaseAddress(bgra)!.assumingMemoryBound(to: UInt8.self)
        // Mean over a 16x16 block at the centre (averages out the dither).
        var sum = [0, 0, 0]
        for y in (h / 2 - 8)..<(h / 2 + 8) {
            for x in (w / 2 - 8)..<(w / 2 + 8) {
                let p = base + y * row + x * 4
                sum[0] += Int(p[2]); sum[1] += Int(p[1]); sum[2] += Int(p[0])
            }
        }
        CVPixelBufferUnlockBaseAddress(bgra, .readOnly)
        print(String(format: "  frame 0 centre RGB (AVFoundation, 0-255): %.1f %.1f %.1f",
                     Double(sum[0]) / 256, Double(sum[1]) / 256, Double(sum[2]) / 256))
    }
} catch {
    check(false, "load asset: \(error.localizedDescription)")
}

print(failures.isEmpty ? "  PASS" : "  FAIL (\(failures.count))")
exit(failures.isEmpty ? 0 : 1)
