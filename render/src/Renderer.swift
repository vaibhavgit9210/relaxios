import Foundation
import Metal

/// Must match `struct Uniforms` in scenes/common.metal (32 bytes).
struct Uniforms {
    var resolution: SIMD2<Float>
    var time: Float
    var loop: Float
    var fps: Float
    var seed: UInt32
    var frame: UInt32
    var pad: Float = 0
}

private struct ResolveParams {
    var width: UInt32
    var ss: UInt32
    var frame: UInt32
    var seed: UInt32
    var weight: Float
    var dither: Float
    var linear: UInt32
    var pad: UInt32 = 0
}

/// Harness-internal kernel, compiled separately from scene code (and without
/// fast math) so a scene can never break or shadow it. It box-averages the
/// ss x ss block in linear light, applies the loop crossfade, adds TPDF dither
/// and writes rgba64 (what ffmpeg reads) into a shared buffer.
private let resolveSource = """
#include <metal_stdlib>
using namespace metal;

struct ResolveParams { uint width; uint ss; uint frame; uint seed; float weight; float dither; uint linear; uint pad; };

static float3 dec(float3 c) {
    c = saturate(c);
    return select(pow((c + 0.055f) / 1.055f, 2.4f), c / 12.92f, c <= 0.04045f);
}
static float3 enc(float3 c) {
    c = saturate(c);
    return select(1.055f * pow(c, 1.0f / 2.4f) - 0.055f, 12.92f * c, c <= 0.0031308f);
}
static float3 box(texture2d<float, access::read> t, uint2 o, uint ss, bool linear) {
    if (!linear) return saturate(t.read(o).rgb);
    float3 s = 0.0f;
    for (uint j = 0; j < ss; ++j)
        for (uint i = 0; i < ss; ++i)
            s += dec(t.read(o + uint2(i, j)).rgb);
    return s / float(ss * ss);
}
static uint3 pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

kernel void resolve(texture2d<float, access::read> a [[texture(0)]],
                    texture2d<float, access::read> b [[texture(1)]],
                    device ushort4* dst [[buffer(0)]],
                    constant ResolveParams& p [[buffer(1)]],
                    uint2 gid [[thread_position_in_grid]]) {
    bool linear = p.linear != 0;
    uint2 o = gid * p.ss;
    float3 c = box(a, o, p.ss, linear);
    if (p.weight > 0.0f) c = mix(c, box(b, o, p.ss, linear), p.weight);
    if (linear) c = enc(c);
    // Monochrome TPDF: same offset on R, G and B so it lands in luma, not chroma.
    uint3 h = pcg3d(uint3(gid.x, gid.y, p.frame ^ (p.seed * 0x9E3779B9u) ^ 0x5BD1E995u));
    float n = float(h.x >> 8) * (1.0f / 16777216.0f) + float(h.y >> 8) * (1.0f / 16777216.0f) - 1.0f;
    c = saturate(c + n * p.dither);
    dst[gid.y * p.width + gid.x] = ushort4(ushort3(rint(c * 65535.0f)), 65535);
}
"""

final class Renderer {
    let o: Options
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let scenePSO: MTLComputePipelineState
    private let resolvePSO: MTLComputePipelineState
    private let texA: MTLTexture
    private let texB: MTLTexture?
    let rw: Int, rh: Int

    init(_ o: Options) {
        self.o = o
        guard let dev = MTLCreateSystemDefaultDevice() else { fail("no Metal device") }
        device = dev
        queue = dev.makeCommandQueue()!
        rw = o.w * o.ss
        rh = o.h * o.ss

        let sceneLib = Renderer.compileScene(o, dev)
        guard let fn = sceneLib.makeFunction(name: "scene") else {
            fail("scenes/\(o.scene).metal must define `kernel void scene(...)`")
        }
        scenePSO = try! dev.makeComputePipelineState(function: fn)

        let ropts = MTLCompileOptions()
        ropts.fastMathEnabled = false
        let rlib: MTLLibrary
        do { rlib = try dev.makeLibrary(source: resolveSource, options: ropts) } catch { fail("resolve kernel: \(error)") }
        resolvePSO = try! dev.makeComputePipelineState(function: rlib.makeFunction(name: "resolve")!)

        let td = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float, width: rw, height: rh, mipmapped: false)
        td.usage = [.shaderRead, .shaderWrite]
        td.storageMode = .private
        guard let a = dev.makeTexture(descriptor: td) else { fail("cannot allocate \(rw)x\(rh) render target") }
        texA = a
        texB = o.xfade > 0 ? dev.makeTexture(descriptor: td) : nil
    }

    /// Concatenates common.metal and <scene>.metal with #line markers so the
    /// Metal compiler reports errors as "<scene>.metal:LINE:COL".
    private static func compileScene(_ o: Options, _ dev: MTLDevice) -> MTLLibrary {
        let dir = URL(fileURLWithPath: o.scenesDir)
        let commonURL = dir.appendingPathComponent("common.metal")
        let sceneURL = dir.appendingPathComponent(o.scene + ".metal")
        guard let common = try? String(contentsOf: commonURL) else { fail("cannot read \(commonURL.path)") }
        guard let scene = try? String(contentsOf: sceneURL) else {
            let have = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
                .filter { $0.hasSuffix(".metal") && $0 != "common.metal" }
                .map { String($0.dropLast(6)) }.sorted()
            fail("no scene '\(o.scene)' in \(dir.path) (have: \(have.joined(separator: ", ")))")
        }
        let src = "#line 1 \"common.metal\"\n\(common)\n#line 1 \"\(o.scene).metal\"\n\(scene)\n"

        let opts = MTLCompileOptions()
        opts.languageVersion = .version3_0
        opts.preprocessorMacros = o.defines.mapValues { $0 as NSString }

        // The callback form also delivers warnings for libraries that compile.
        var lib: MTLLibrary?
        var log: String?
        let done = DispatchSemaphore(value: 0)
        dev.makeLibrary(source: src, options: opts) { l, e in
            lib = l
            log = e.map { ($0 as NSError).localizedDescription }
            done.signal()
        }
        done.wait()
        guard let library = lib else {
            fail("shader compile failed for scene '\(o.scene)':\n\(log ?? "(no log)")", code: 2)
        }
        if let log, !log.isEmpty, !o.quiet { FileHandle.standardError.write("shader warnings:\n\(log)\n".data(using: .utf8)!) }
        return library
    }

    func makeOutputBuffer() -> MTLBuffer {
        guard let b = device.makeBuffer(length: o.w * o.h * 8, options: .storageModeShared) else { fail("cannot allocate output buffer") }
        return b
    }

    /// Crossfade partner for time t: inside the last B seconds of the loop the
    /// output is mix(F(t), F(t - L), w) with w rising smoothly 0 -> 1, so the
    /// frame after the last one (t = L) would be exactly F(0).
    func crossfade(at t: Double) -> (time: Double, weight: Float)? {
        guard o.xfade > 0, t > o.loop - o.xfade, t < o.loop else { return nil }
        let a = (t - (o.loop - o.xfade)) / o.xfade
        return (t - o.loop, Float(a * a * (3 - 2 * a)))
    }

    private func threadgroup(_ pso: MTLComputePipelineState) -> MTLSize {
        let w = pso.threadExecutionWidth
        let h = max(1, min(pso.maxTotalThreadsPerThreadgroup / w, 8))
        return MTLSize(width: w, height: h, depth: 1)
    }

    private func dispatchScene(_ enc: MTLComputeCommandEncoder, _ tex: MTLTexture, _ t: Double, _ frame: Int) {
        var u = Uniforms(resolution: SIMD2(Float(rw), Float(rh)), time: Float(t), loop: Float(o.loop),
                         fps: Float(o.fps), seed: o.seed, frame: UInt32(truncatingIfNeeded: frame))
        enc.setComputePipelineState(scenePSO)
        enc.setTexture(tex, index: 0)
        enc.setBytes(&u, length: MemoryLayout<Uniforms>.stride, index: 0)
        enc.dispatchThreads(MTLSize(width: rw, height: rh, depth: 1), threadsPerThreadgroup: threadgroup(scenePSO))
    }

    /// Encodes and commits one output frame into `buf` (rgba64le, w*h*8 bytes).
    @discardableResult
    func render(frame: Int, time t: Double, into buf: MTLBuffer) -> MTLCommandBuffer {
        let cb = queue.makeCommandBuffer()!
        let enc = cb.makeComputeCommandEncoder()!
        dispatchScene(enc, texA, t, frame)
        var weight: Float = 0
        if let x = crossfade(at: t), let b = texB {
            dispatchScene(enc, b, x.time, frame)
            weight = x.weight
        }
        var p = ResolveParams(width: UInt32(o.w), ss: UInt32(o.ss), frame: UInt32(truncatingIfNeeded: frame),
                              seed: o.seed, weight: weight, dither: Float(o.dither / 876.0),
                              linear: (o.ss > 1 || weight > 0) ? 1 : 0)
        enc.setComputePipelineState(resolvePSO)
        enc.setTexture(texA, index: 0)
        enc.setTexture(texB ?? texA, index: 1)
        enc.setBuffer(buf, offset: 0, index: 0)
        enc.setBytes(&p, length: MemoryLayout<ResolveParams>.stride, index: 1)
        enc.dispatchThreads(MTLSize(width: o.w, height: o.h, depth: 1), threadsPerThreadgroup: threadgroup(resolvePSO))
        enc.endEncoding()
        cb.commit()
        return cb
    }

    static func check(_ cb: MTLCommandBuffer) {
        cb.waitUntilCompleted()
        if cb.status == .error { fail("GPU error: \(cb.error.map { "\($0)" } ?? "unknown") (a scene kernel that runs too long can hit the GPU watchdog; try lower --ss)") }
    }
}
