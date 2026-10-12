// common.metal: shared by every scene. The harness compiles this file and
// scenes/<id>.metal as ONE source string, so everything here is visible to
// the scene. Scene-local helpers should be prefixed with the scene id.
//
// Conventions used below:
//   - "height units": positions divided by the frame height, origin at the
//     frame centre, +y up. A size given in height units looks the same at
//     720p and 1080p and in portrait and landscape (see frame_uv).
//   - value noise returns [0,1]; gradient noise and fbm return roughly [-1,1].
//   - every random helper takes a `seed`; pass u.seed (plus a salt) through.

#include <metal_stdlib>
using namespace metal;

struct Uniforms {
    float2 resolution; // render target size in px (already multiplied by --ss)
    float  time;       // seconds, frame i is at i/fps; negative inside the loop crossfade
    float  loop;       // loop length L in seconds
    float  fps;
    uint   seed;
    uint   frame;      // output frame index; prefer `time` for anything visible
    float  pad;
};

constant float PI  = 3.14159265358979f;
constant float TAU = 6.28318530717959f;

// ---------------------------------------------------------------- coordinates

// Pixel centre in height units: y in [-0.5, 0.5] (+y up), x in
// [-0.5*aspect, 0.5*aspect].
inline float2 frame_uv(uint2 gid, float2 res) {
    return float2(float(gid.x) + 0.5f - 0.5f * res.x,
                  0.5f * res.y - float(gid.y) - 0.5f) / res.y;
}

// One render pixel in height units. Use it for anti-aliasing widths only;
// size visible features in height units so 720p and 1080p match.
inline float px_size(float2 res) { return 1.0f / res.y; }

inline float aspect_of(float2 res) { return res.x / res.y; }
inline bool  is_portrait(float2 res) { return res.y > res.x; }

// Half extents (height units) of the region still visible after the app
// aspect-fills a 19.5:9 phone screen. Keep important content inside
// |x| < safe.x and |y| < safe.y.
inline float2 safe_extent(float2 res) {
    const float phone = 19.5f / 9.0f;
    float a = res.x / res.y;
    if (a < 1.0f) return float2(0.5f / phone, 0.5f);       // portrait: sides cropped
    return float2(0.5f * a, 0.5f * a / phone);              // landscape: top/bottom cropped
}

// -------------------------------------------------------------------- hashing
// PCG-family integer hashes (Jarzynski and Olano, "Hash Functions for GPU
// Rendering", JCGT 2020). Integer in, integer out, no float precision traps.

inline uint pcg_hash(uint v) {
    uint s = v * 747796405u + 2891336453u;
    uint w = ((s >> ((s >> 28u) + 4u)) ^ s) * 277803737u;
    return (w >> 22u) ^ w;
}

inline uint3 pcg3d(uint3 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    v ^= v >> 16u;
    v.x += v.y * v.z; v.y += v.z * v.x; v.z += v.x * v.y;
    return v;
}

inline uint4 pcg4d(uint4 v) {
    v = v * 1664525u + 1013904223u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    v ^= v >> 16u;
    v.x += v.y * v.w; v.y += v.z * v.x; v.z += v.x * v.y; v.w += v.y * v.z;
    return v;
}

// uint -> [0,1) using the top 24 bits.
inline float u01(uint x) { return float(x >> 8u) * (1.0f / 16777216.0f); }

inline float  hash1(int2 c, uint seed) { return u01(pcg3d(uint3(as_type<uint2>(c), seed)).x); }
inline float2 hash2(int2 c, uint seed) { uint3 h = pcg3d(uint3(as_type<uint2>(c), seed)); return float2(u01(h.x), u01(h.y)); }
inline float3 hash3(int2 c, uint seed) { uint3 h = pcg3d(uint3(as_type<uint2>(c), seed)); return float3(u01(h.x), u01(h.y), u01(h.z)); }
inline float  hash1(int3 c, uint seed) { return u01(pcg4d(uint4(as_type<uint3>(c), seed)).x); }
inline float3 hash3(int3 c, uint seed) { uint4 h = pcg4d(uint4(as_type<uint3>(c), seed)); return float3(u01(h.x), u01(h.y), u01(h.z)); }

// Random numbers for indexed things (event k, bolt k, salt = which property).
inline float  rand1(uint k, uint salt, uint seed) { return u01(pcg3d(uint3(k, salt, seed)).x); }
inline float2 rand2(uint k, uint salt, uint seed) { uint3 h = pcg3d(uint3(k, salt, seed)); return float2(u01(h.x), u01(h.y)); }
inline float3 rand3(uint k, uint salt, uint seed) { uint3 h = pcg3d(uint3(k, salt, seed)); return float3(u01(h.x), u01(h.y), u01(h.z)); }

// ---------------------------------------------------------------------- noise
// Lattice period: a component <= 0 means "not periodic" on that axis. With a
// period P the noise satisfies n(p + P) == n(p) exactly, which is how scenes
// make things loop: e.g. sample z = time / loop * Pz with integer Pz.

inline int2 lattice_wrap(int2 i, int2 per) {
    int2 p = max(per, int2(1));
    return select(i, ((i % p) + p) % p, per > 0);
}
inline int3 lattice_wrap(int3 i, int3 per) {
    int3 p = max(per, int3(1));
    return select(i, ((i % p) + p) % p, per > 0);
}

inline float  fade5(float t)  { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
inline float2 fade5(float2 t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }
inline float3 fade5(float3 t) { return t * t * t * (t * (t * 6.0f - 15.0f) + 10.0f); }

// Value noise, [0,1].
inline float vnoise2p(float2 p, int2 per, uint seed) {
    float2 fl = floor(p); int2 i = int2(fl); float2 f = p - fl;
    float a = hash1(lattice_wrap(i,              per), seed);
    float b = hash1(lattice_wrap(i + int2(1, 0), per), seed);
    float c = hash1(lattice_wrap(i + int2(0, 1), per), seed);
    float d = hash1(lattice_wrap(i + int2(1, 1), per), seed);
    float2 w = fade5(f);
    return mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

inline float vnoise3p(float3 p, int3 per, uint seed) {
    float3 fl = floor(p); int3 i = int3(fl); float3 f = p - fl;
    float3 w = fade5(f);
    float n000 = hash1(lattice_wrap(i + int3(0, 0, 0), per), seed);
    float n100 = hash1(lattice_wrap(i + int3(1, 0, 0), per), seed);
    float n010 = hash1(lattice_wrap(i + int3(0, 1, 0), per), seed);
    float n110 = hash1(lattice_wrap(i + int3(1, 1, 0), per), seed);
    float n001 = hash1(lattice_wrap(i + int3(0, 0, 1), per), seed);
    float n101 = hash1(lattice_wrap(i + int3(1, 0, 1), per), seed);
    float n011 = hash1(lattice_wrap(i + int3(0, 1, 1), per), seed);
    float n111 = hash1(lattice_wrap(i + int3(1, 1, 1), per), seed);
    return mix(mix(mix(n000, n100, w.x), mix(n010, n110, w.x), w.y),
               mix(mix(n001, n101, w.x), mix(n011, n111, w.x), w.y), w.z);
}

inline float vnoise2(float2 p, uint seed) { return vnoise2p(p, int2(0), seed); }
inline float vnoise3(float3 p, uint seed) { return vnoise3p(p, int3(0), seed); }

// Gradient (Perlin-style) noise, roughly [-1,1], zero at lattice points.
inline float2 noise_grad2(int2 c, uint seed) {
    float a = hash1(c, seed) * TAU;
    return float2(cos(a), sin(a));
}
inline float3 noise_grad3(int3 c, uint seed) {
    float3 h = hash3(c, seed);
    float z = h.x * 2.0f - 1.0f, r = sqrt(max(0.0f, 1.0f - z * z)), a = h.y * TAU;
    return float3(r * cos(a), r * sin(a), z);
}

inline float gnoise2p(float2 p, int2 per, uint seed) {
    float2 fl = floor(p); int2 i = int2(fl); float2 f = p - fl;
    float a = dot(noise_grad2(lattice_wrap(i,              per), seed), f);
    float b = dot(noise_grad2(lattice_wrap(i + int2(1, 0), per), seed), f - float2(1, 0));
    float c = dot(noise_grad2(lattice_wrap(i + int2(0, 1), per), seed), f - float2(0, 1));
    float d = dot(noise_grad2(lattice_wrap(i + int2(1, 1), per), seed), f - float2(1, 1));
    float2 w = fade5(f);
    return 1.41421356f * mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

inline float gnoise3p(float3 p, int3 per, uint seed) {
    float3 fl = floor(p); int3 i = int3(fl); float3 f = p - fl;
    float3 w = fade5(f);
    #define G3(ox, oy, oz) dot(noise_grad3(lattice_wrap(i + int3(ox, oy, oz), per), seed), f - float3(ox, oy, oz))
    float v = mix(mix(mix(G3(0, 0, 0), G3(1, 0, 0), w.x), mix(G3(0, 1, 0), G3(1, 1, 0), w.x), w.y),
                  mix(mix(G3(0, 0, 1), G3(1, 0, 1), w.x), mix(G3(0, 1, 1), G3(1, 1, 1), w.x), w.y), w.z);
    #undef G3
    return 1.1547f * v;
}

inline float gnoise2(float2 p, uint seed) { return gnoise2p(p, int2(0), seed); }
inline float gnoise3(float3 p, uint seed) { return gnoise3p(p, int3(0), seed); }

// ---------------------------------------------------------------------- fbm
// Gradient-noise fbm, normalised to roughly [-1,1]. Octaves are rotated and use
// a non-integer lacunarity so lattice axes never line up.

inline float2x2 rot2(float a) { float c = cos(a), s = sin(a); return float2x2(float2(c, s), float2(-s, c)); }

// Rotation about a unit axis (Rodrigues).
inline float3x3 rot3(float3 axis, float a) {
    float c = cos(a), s = sin(a), k = 1.0f - c;
    float3 n = normalize(axis);
    return float3x3(float3(c + n.x * n.x * k,       n.y * n.x * k + n.z * s, n.z * n.x * k - n.y * s),
                    float3(n.x * n.y * k - n.z * s, c + n.y * n.y * k,       n.z * n.y * k + n.x * s),
                    float3(n.x * n.z * k + n.y * s, n.y * n.z * k - n.x * s, c + n.z * n.z * k));
}

inline float fbm2(float2 p, int octaves, uint seed) {
    const float2x2 m = rot2(0.6435f) * 2.03f;
    float sum = 0.0f, amp = 0.5f, norm = 0.0f;
    for (int k = 0; k < octaves; ++k) {
        sum += amp * gnoise2(p, seed + uint(k) * 0x9E3779B9u);
        norm += amp; amp *= 0.5f; p = m * p;
    }
    return sum / norm;
}

inline float fbm3(float3 p, int octaves, uint seed) {
    const float3x3 m = rot3(float3(0.36f, 0.48f, 0.80f), 0.7f) * 2.03f;
    float sum = 0.0f, amp = 0.5f, norm = 0.0f;
    for (int k = 0; k < octaves; ++k) {
        sum += amp * gnoise3(p, seed + uint(k) * 0x9E3779B9u);
        norm += amp; amp *= 0.5f; p = m * p;
    }
    return sum / norm;
}

// Periodic fbm: lacunarity exactly 2 and no rotation, so octave k has period
// per * 2^k and the sum keeps the base period. Use it for anything that must
// loop exactly (e.g. cloud evolution along z = time / loop * per.z).
inline float fbm2p(float2 p, int2 per, int octaves, uint seed) {
    float sum = 0.0f, amp = 0.5f, norm = 0.0f;
    for (int k = 0; k < octaves; ++k) {
        sum += amp * gnoise2p(p, per, seed + uint(k) * 0x9E3779B9u);
        norm += amp; amp *= 0.5f; p *= 2.0f; per *= 2;
    }
    return sum / norm;
}

inline float fbm3p(float3 p, int3 per, int octaves, uint seed) {
    float sum = 0.0f, amp = 0.5f, norm = 0.0f;
    for (int k = 0; k < octaves; ++k) {
        sum += amp * gnoise3p(p, per, seed + uint(k) * 0x9E3779B9u);
        norm += amp; amp *= 0.5f; p *= 2.0f; per *= 2;
    }
    return sum / norm;
}

// ------------------------------------------------------------------ shaping

inline float smootherstep(float e0, float e1, float x) { return fade5(saturate((x - e0) / (e1 - e0))); }
inline float linstep(float e0, float e1, float x) { return saturate((x - e0) / (e1 - e0)); }
inline float remap(float x, float a, float b, float c, float d) { return c + (d - c) * (x - a) / (b - a); }

// ------------------------------------------------------------------- timing

// Positive modulo: t mapped into [0, L), also for negative t.
inline float wrap_time(float t, float L) { return t - L * floor(t / L); }

// Seconds since the most recent occurrence of an event that repeats every L
// seconds at offset t0, in [0, L). Schedule all discrete events this way so
// they are identical on both sides of the loop crossfade.
inline float since_event(float t, float t0, float L) { return wrap_time(t - t0, L); }

// Flash envelope with peak 1: smooth rise over `rise` s, exponential decay with
// time constant `decay` s. dt is seconds since the event (see since_event).
inline float flash_env(float dt, float rise, float decay) {
    if (dt < 0.0f) return 0.0f;
    float up = smoothstep(0.0f, rise, dt);
    return up * exp(-max(dt - rise, 0.0f) / decay);
}

// -------------------------------------------------------------------- colour

inline float srgb_encode(float x) {
    x = saturate(x);
    return x <= 0.0031308f ? 12.92f * x : 1.055f * pow(x, 1.0f / 2.4f) - 0.055f;
}
inline float3 srgb_encode(float3 c) { return float3(srgb_encode(c.r), srgb_encode(c.g), srgb_encode(c.b)); }

inline float srgb_decode(float x) {
    x = saturate(x);
    return x <= 0.04045f ? x / 12.92f : pow((x + 0.055f) / 1.055f, 2.4f);
}
inline float3 srgb_decode(float3 c) { return float3(srgb_decode(c.r), srgb_decode(c.g), srgb_decode(c.b)); }

// Relative luminance of a LINEAR Rec.709/sRGB colour.
inline float luma709(float3 c) { return dot(c, float3(0.2126f, 0.7152f, 0.0722f)); }

// Filmic curve (Narkowicz's fit of the ACES RRT+ODT), linear in, linear [0,1]
// out. Shoulder rolls highlights such as bolt cores off gently.
inline float3 tonemap_filmic(float3 x) {
    x = max(x, 0.0f);
    return saturate((x * (2.51f * x + 0.03f)) / (x * (2.43f * x + 0.59f) + 0.14f));
}

// Extended Reinhard on luminance, hue preserving. `white` maps to 1.
inline float3 tonemap_reinhard(float3 c, float white) {
    float l = luma709(max(c, 0.0f));
    float m = l * (1.0f + l / (white * white)) / (1.0f + l);
    return l > 0.0f ? saturate(c * (m / l)) : float3(0.0f);
}

// Linear scene colour -> the display-referred value a scene must write.
inline float4 output_color(float3 linear_rgb) { return float4(srgb_encode(tonemap_filmic(linear_rgb)), 1.0f); }

// Triangular-PDF noise in [-1,1] (sum of two uniforms), deterministic per
// pixel/frame/seed. Multiply by the target LSB, e.g. 1.0/255 for 8-bit. The
// harness already dithers the final 10-bit conversion, so scenes only need
// this for their own internal quantisation.
inline float tpdf(uint2 pix, uint frame, uint seed) {
    uint3 h = pcg3d(uint3(pix.x, pix.y, frame ^ (seed * 0x9E3779B9u)));
    return u01(h.x) + u01(h.y) - 1.0f;
}
