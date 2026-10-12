// sea.metal: "Storm at Sea".
//
// A camera 7 m above open ocean at night, looking at the horizon under a low
// storm deck. Everything is a pure function of (pixel, time, seed):
//   sea     heightfield of 24 directional deep-water waves with peaked crests.
//           The big swells are ray traced, all components shade the normal,
//           plus capillary noise, rain rings and whitecaps up close. A static
//           warp and per-wave envelopes keep crests finite (wave groups, not
//           endless sine lines). Every component makes a whole number of
//           periods per loop, so the sea repeats exactly.
//   sky     perspective cloud deck plus a ragged scud layer, rain curtains and
//           haze toward the horizon. Cloud drift is the only non-periodic
//           motion; the harness crossfade hides it.
//   storm   a fixed schedule of strikes inside the loop: in-cloud glow,
//           distant channels with return strokes, flickers past the horizon.
//   accent  a lighthouse on a rock with a slowly sweeping warm beam.
//   rain    screen-space streak layers in depth, lit by the flashes.
// World units are metres: x right, y up, z forward, camera at (0, SEA_CAM_Y, 0).

#ifndef SEA_EXPOSURE
#define SEA_EXPOSURE 1.0f
#endif
#ifndef SEA_GRAIN
#define SEA_GRAIN 1.0f
#endif

constant float SEA_G     = 9.81f;
constant float SEA_CAM_Y = 7.0f;      // camera height above mean sea level
constant float SEA_CEIL  = 950.0f;    // storm cloud base
constant float SEA_SCUD  = 420.0f;    // ragged low cloud
constant float SEA_VIS   = 5200.0f;   // extinction length in the rain
constant float SEA_HMAX  = 4.4f;      // bounds of the traced swell height
constant float SEA_HMIN  = -2.8f;

constant float3 SEA_HORIZON = float3(0.036f, 0.054f, 0.076f);  // haze at the horizon
constant float3 SEA_DECK    = float3(0.0095f, 0.0110f, 0.0240f);  // unlit cloud base
constant float3 SEA_BOLT    = float3(0.80f, 0.86f, 1.00f);     // lightning, through rain
constant float3 SEA_LAMP    = float3(1.00f, 0.62f, 0.30f);     // lighthouse

// ------------------------------------------------------------------ camera

struct SeaCam { float hy; float f; float2 safe; float pxa; };

// Composition per orientation: landscape gets a wider horizon, portrait a
// taller column of sea and sky. hy is the horizon height in frame units.
inline SeaCam sea_cam(float2 res) {
    SeaCam c;
    c.safe = safe_extent(res);
    if (is_portrait(res)) { c.hy = -0.05f; c.f = 1.0f; }
    else                  { c.hy = -0.07f; c.f = 1.05f; }
    c.pxa = px_size(res) / c.f;   // one render pixel in radians (near the axis)
    return c;
}

inline float3 sea_ray(float2 p, SeaCam c) { return normalize(float3(p.x, p.y - c.hy, c.f)); }
inline float2 sea_project(float3 w, SeaCam c) {
    return float2(c.f * w.x / w.z, c.hy + c.f * (w.y - SEA_CAM_Y) / w.z);
}
inline float sea_trans(float d) { return exp(-d / SEA_VIS); }

// ------------------------------------------------------------------- storm
// Strikes at fixed fractions of the loop, so both crossfade layers, both
// orientations and every repeat agree. kind 0: cloud-to-sea channel, 1:
// in-cloud sheet, 2: flicker beyond the horizon. sx is the screen position as
// a fraction of the safe half width; off/amp are up to three strokes.

struct SeaStrikeDef { float at; int kind; float sx; float dist; float power; float decay; float4 off; float4 amp; };

constant int SEA_NSTRIKE = 10;
constant int SEA_MAXL = 3;          // strikes overlapping at any moment
// Notable events at uneven gaps (6.2, 7.8, 6.2, 11.0, 8.8 s) with varied power,
// the last two on the same side, so the rhythm does not become predictable;
// far flickers fill the long gaps.
constant SeaStrikeDef SEA_STRIKES[SEA_NSTRIKE] = {
    {0.080f, 0, -0.45f,  5200.0f, 0.90f, 0.40f, float4(0.0f, 0.40f, 0.0f, 0.0f), float4(1.0f, 0.60f, 0.0f, 0.0f)},
    {0.160f, 2,  0.70f, 18000.0f, 0.35f, 0.45f, float4(0.0f, 0.45f, 0.0f, 0.0f), float4(1.0f, 0.50f, 0.0f, 0.0f)},
    {0.235f, 1,  0.40f,  7000.0f, 0.70f, 0.55f, float4(0.0f, 0.50f, 0.0f, 0.0f), float4(1.0f, 0.45f, 0.0f, 0.0f)},
    {0.330f, 2, -0.80f, 20000.0f, 0.30f, 0.45f, float4(0.0f, 0.0f,  0.0f, 0.0f), float4(1.0f, 0.0f,  0.0f, 0.0f)},
    {0.430f, 0,  0.25f,  3800.0f, 0.80f, 0.45f, float4(0.0f, 0.38f, 0.82f, 0.0f), float4(1.0f, 0.55f, 0.30f, 0.0f)},
    {0.510f, 2, -0.10f, 16000.0f, 0.30f, 0.40f, float4(0.0f, 0.0f,  0.0f, 0.0f), float4(1.0f, 0.0f,  0.0f, 0.0f)},
    {0.585f, 0, -0.75f,  9500.0f, 0.95f, 0.40f, float4(0.0f, 0.42f, 0.0f, 0.0f), float4(1.0f, 0.55f, 0.0f, 0.0f)},
    {0.720f, 2,  0.85f, 19000.0f, 0.30f, 0.45f, float4(0.0f, 0.0f,  0.0f, 0.0f), float4(1.0f, 0.0f,  0.0f, 0.0f)},
    {0.860f, 1, -0.30f,  6000.0f, 0.65f, 0.55f, float4(0.0f, 0.36f, 0.78f, 0.0f), float4(1.0f, 0.60f, 0.35f, 0.0f)},
    {0.965f, 2,  0.45f, 17000.0f, 0.28f, 0.45f, float4(0.0f, 0.0f,  0.0f, 0.0f), float4(1.0f, 0.0f,  0.0f, 0.0f)},
};

struct SeaLight {
    float3 src;      // where the flash lights the cloud from
    float3 foot;     // channel foot on the sea (kind 0)
    float  illum;    // large-area light right now (power x envelope)
    float  chan;     // channel brightness right now
    float  radius;   // spread of the glow inside the cloud
    float  trans;    // transmittance camera -> source
    int    kind;
    uint   id;
};

inline float sea_strokes(float dt, float4 off, float4 amp, float rise, float decay) {
    float e = 0.0f;
    for (int j = 0; j < 4; ++j)
        // max, not sum: a return stroke re-brightens, it never stacks above the first.
        if (amp[j] > 0.0f) e = max(e, amp[j] * flash_env(dt - off[j], rise, decay));
    return e;
}

inline int sea_lights(float t, float L, SeaCam cam, thread SeaLight* out) {
    int n = 0;
    for (int i = 0; i < SEA_NSTRIKE; ++i) {
        SeaStrikeDef s = SEA_STRIKES[i];
        float dt = since_event(t, s.at * L, L);
        if (dt > 3.5f || n == SEA_MAXL) continue;
        SeaLight l;
        l.kind = s.kind;
        l.id = uint(i);
        l.illum = s.power * sea_strokes(dt, s.off, s.amp, 0.08f, s.decay);
        l.chan = s.kind == 0 ? max(s.power, 0.9f) * sea_strokes(dt, s.off, s.amp, 0.07f, 0.11f) : 0.0f;
        float x = s.sx * cam.safe.x * 0.85f;
        float X = x * s.dist / cam.f;
        if (s.kind == 0)      { l.src = float3(X, SEA_CEIL - 60.0f, s.dist);  l.radius = 900.0f; }
        else if (s.kind == 1) { l.src = float3(X, SEA_CEIL + 150.0f, s.dist); l.radius = 1500.0f; }
        else                  { l.src = float3(X, 1600.0f, s.dist);           l.radius = 4000.0f; }
        l.foot = float3(X + (rand1(uint(i), 3u, 7u) - 0.5f) * 0.25f * SEA_CEIL, 0.0f, s.dist);
        // Flashes past the horizon light the air above the rain, which is clearer.
        l.trans = s.kind == 2 ? exp(-s.dist / 15000.0f) : sea_trans(s.dist);
        if (l.illum < 1e-4f && l.chan < 1e-4f) continue;
        out[n++] = l;
    }
    return n;
}

// Soft in-scatter around a flash: what makes the rain air itself glow.
inline float3 sea_flash_glow(float3 d, thread const SeaLight* lt, int nl) {
    float3 g = 0.0f;
    for (int i = 0; i < nl; ++i) {
        float3 s = lt[i].src - float3(0.0f, SEA_CAM_Y, 0.0f);
        float mu = dot(d, normalize(s));
        float k = 1.0f - mu;
        float w = 0.30f * exp(-k * 260.0f) + 0.08f * exp(-k * 40.0f) + 0.004f * exp(-k * 6.0f);
        g += lt[i].illum * lt[i].trans * w;
    }
    return g * SEA_BOLT;
}

// ------------------------------------------------------------------- noise

// Gradient fbm whose octaves fade out once their wavelength nears the pixel
// footprint `fp` (same units as p). Mean stays 0, so faded octaves only lose
// contrast instead of shimmering. 2D noise costs half the lattice hashes of
// 3D; instead of a time axis each octave slides by its own multiple of
// `drift`, so small detail creeps across the large forms as the field drifts.
inline float sea_fbm2(float2 p, int oct, float fp, uint seed, float2 drift) {
    const float2x2 m = rot2(0.71f) * 2.07f;
    float sum = 0.0f, amp = 0.5f, norm = 0.0f, freq = 1.0f;
    for (int k = 0; k < oct; ++k) {
        float w = 1.0f - smoothstep(0.2f, 0.5f, fp * freq);
        if (w <= 0.0f) break;
        sum += amp * w * gnoise2(p + drift * float(k + 1), seed + uint(k) * 0x9E3779B9u);
        norm += amp; amp *= 0.5f; freq *= 2.07f; p = m * p;
    }
    for (; amp > 0.004f; amp *= 0.5f) norm += amp;
    return sum / max(norm, 1e-4f);
}

// ------------------------------------------------------------------- sky

// Haze colour toward d before any flash: brighter toward the horizon and a
// faint gap low on the left where the deck thins.
inline float3 sea_haze(float3 d) {
    float az = atan2(d.x, d.z);
    float gap = exp(-pow((az + 0.28f) / 0.55f, 2.0f));
    float e = max(d.y, 0.0f);
    float3 h = SEA_HORIZON * (0.75f + 0.45f * gap);
    return h * (0.35f + 0.65f * exp(-e * 9.0f));
}

// Cloud deck density (0..1) at deck coordinates q (km) in .x, billow
// lumpiness (1 on a lump, 0 in a crease) in .y.
inline float2 sea_deck2(float2 q, float t, float fp, uint seed) {
    float2 dr = float2(0.006f, -0.004f) * t;
    float2 w = float2(sea_fbm2(q * 0.7f, 3, fp * 0.7f, seed + 11u, dr),
                      sea_fbm2(q * 0.7f + 5.2f, 3, fp * 0.7f, seed + 12u, dr));
    float big = sea_fbm2(q * 0.3f, 3, fp * 0.3f, seed + 14u, dr * 0.5f);
    float n = sea_fbm2(q * 1.15f + w * 0.3f, 8, fp * 1.15f, seed + 13u, dr);
    // Billows: folded noise gives rounded lumps separated by dark creases;
    // they show most where the cloud is thick.
    float bil = 1.0f - abs(sea_fbm2(q * 3.3f + w * 0.15f, 6, fp * 3.3f, seed + 15u, dr * 1.5f));
    float d = smoothstep(-0.05f, 1.0f, 0.5f + 1.2f * n + 0.6f * big);
    return float2(saturate(d * (0.7f + 0.5f * bil * bil)), bil);
}
inline float sea_deck(float2 q, float t, float fp, uint seed) { return sea_deck2(q, t, fp, seed).x; }

struct SeaSkyOut { float3 col; float cover; float curtain; float dens; };

// Radiance seen along d (d.y >= 0): deck, scud, curtains, haze and flash glow.
// fpk scales the footprint (1 for primary rays, larger for blurry reflections).
// refl skips what a rough reflection would blur away anyway: cloud relief,
// curtains and scud.
inline SeaSkyOut sea_sky(float3 d, float t, SeaCam cam, float fpk, uint seed,
                         thread const SeaLight* lt, int nl, bool refl) {
    SeaSkyOut o;
    float3 hz = sea_haze(d);
    float dy = max(d.y, 1e-4f);
    float2 wind = float2(0.010f, 0.0035f);       // km/s drift of the deck

    // Deck.
    float tc = (SEA_CEIL - SEA_CAM_Y) / dy;
    float3 C = d * tc;
    float fp = tc * cam.pxa * fpk / sqrt(max(dy, 0.02f)) * 0.001f;
    float2 q = C.xz * 0.001f - wind * t;
    float2 db = sea_deck2(q, t, fp, seed);
    float dens = db.x, bil = db.y;
    o.dens = dens;
    float3 nb = float3(0.0f, -1.0f, 0.0f);
    float rim = 0.0f;
    if (!refl) {
        float e = 0.05f, fe = max(fp, 2.0f * e);
        float d0 = sea_deck(q, t, fe, seed);
        float dx = sea_deck(q + float2(e, 0.0f), t, fe, seed) - d0;
        float dz = sea_deck(q + float2(0.0f, e), t, fe, seed) - d0;
        // Thicker cloud hangs lower: the base is a surface with normal pointing down.
        nb = normalize(float3(dx * 5.0f, -1.0f, dz * 5.0f));
        // Thin, fast-changing cloud edges catch the flash as a silver rim.
        rim = smoothstep(0.08f, 0.35f, length(float2(dx, dz))) * (1.0f - smoothstep(0.35f, 0.8f, dens));
    }

    float3 amb = SEA_DECK * (0.22f + 2.0f * dens * dens);
    // Faint light from the horizon gap rakes the lumps.
    float3 toGap = normalize(float3(-0.3f, -0.25f, 1.0f));
    amb *= 0.65f + 0.8f * saturate(dot(nb, toGap) + 0.4f);
    float3 lit = 0.0f;
    for (int i = 0; i < nl; ++i) {
        float3 v = lt[i].src - (C + float3(0.0f, SEA_CAM_Y, 0.0f));
        float r = length(v);
        float E = lt[i].illum * exp(-r / lt[i].radius);
        float sh = 0.5f + 0.8f * saturate(dot(nb, v / r) + 0.3f);
        // Light follows the cloud structure: thick lumps glow from inside,
        // creases and thin gaps stay dark, so the deck keeps its relief.
        float body = mix(0.15f, 1.0f, smoothstep(0.3f, 0.9f, dens)) * (0.4f + 0.6f * bil * bil);
        lit += E * (sh * body * 1.5f + rim * 0.6f);
    }
    float3 deck = amb + lit * SEA_BOLT * 0.40f;
    float T = exp(-tc / 9000.0f);
    float3 col = deck * T + hz * (1.0f - T);

    // Rain curtains hanging under the far deck.
    float az = atan2(d.x, d.z);
    float band = smoothstep(0.0f, 0.012f, d.y) * (1.0f - smoothstep(0.05f, 0.16f, d.y));
    float cur = 0.0f;
    o.cover = 0.0f;
    if (band > 0.0f && !refl) {
        float n = sea_fbm2(float2(az * 9.0f + d.y * 6.0f - 0.004f * t, d.y * 4.0f), 4,
                           cam.pxa * fpk * 9.0f, seed + 21u, float2(0.004f, 0.006f) * t);
        cur = band * smoothstep(-0.1f, 0.5f, n);
        col = mix(col, hz * 0.8f, cur * 0.6f);
    }

    // Scud: ragged low cloud moving faster than the deck.
    if (refl) {
        o.col = col + sea_flash_glow(d, lt, nl);
        o.curtain = 0.0f;
        return o;
    }
    float ts = (SEA_SCUD - SEA_CAM_Y) / dy;
    float3 S = d * ts;
    float fps = ts * cam.pxa * fpk / sqrt(max(dy, 0.02f)) * 0.001f;
    float2 qs = S.xz * 0.001f - wind * 2.2f * t;
    float sn = sea_fbm2(qs * 2.4f, 6, fps * 2.4f, seed + 31u, float2(0.01f, 0.008f) * t);
    float sa = smoothstep(0.05f, 0.55f, sn) * exp(-ts / 7000.0f);
    float3 scud = SEA_DECK * 0.55f;
    for (int i = 0; i < nl; ++i) {
        float r = length(lt[i].src - (S + float3(0.0f, SEA_CAM_Y, 0.0f)));
        scud += lt[i].illum * exp(-r / (lt[i].radius * 1.4f)) * SEA_BOLT * 0.12f;
    }
    col = mix(col, scud, sa * 0.85f);

    col += sea_flash_glow(d, lt, nl) * (1.0f - 0.5f * cur);
    o.col = col;
    o.cover = sa * 0.85f;
    o.curtain = cur;
    return o;
}

// --------------------------------------------------------------- lightning

inline float sea_seg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-12f));
    return length(pa - ba * h);
}

// Channel of strike `id` from screen point top to bot (frame units). Returns
// core (thin, energy conserving) in .x and soft halo in .y. Two levels of
// tortuosity: uneven main steps with persistent kinks, each split into three
// jittered sub-steps. `cloud` is the deck density along this pixel's ray: the
// top of the channel vanishes behind thick lumps of the cloud base.
constant int SEA_BOLT_N = 22;
constant int SEA_BOLT_S = 3;
constant int SEA_BOLT_M = SEA_BOLT_N * SEA_BOLT_S;
inline float2 sea_bolt(float2 p, float2 top, float2 bot, uint id, uint seed, float pxs, float cloud) {
    float span = top.y - bot.y;
    float margin = 0.05f;
    if (p.y > top.y + margin || p.y < bot.y - margin) return 0.0f;
    if (abs(p.x - 0.5f * (top.x + bot.x)) > 0.45f * span + margin) return 0.0f;

    // Main steps of uneven length (0.6-1.4x), y from 1 (top) down to 0.
    float ys[SEA_BOLT_N + 1], xs[SEA_BOLT_N + 1];
    float acc = 0.0f;
    ys[0] = 0.0f;
    for (int i = 1; i <= SEA_BOLT_N; ++i) { acc += 0.6f + 0.8f * rand1(id * 131u + uint(i), 53u, seed); ys[i] = acc; }
    float x = 0.0f, dir = 0.0f;
    for (int i = 0; i <= SEA_BOLT_N; ++i) {
        float r = rand1(id * 131u + uint(i), 41u, seed);
        float st = i > 0 ? (ys[i] - ys[i - 1]) / acc : 0.0f;
        if (i > 0) { dir = 0.55f * dir + (r - 0.5f) * 1.9f; x += dir * st; }
        xs[i] = x;
    }
    for (int i = 0; i <= SEA_BOLT_N; ++i) ys[i] = 1.0f - ys[i] / acc;
    float xend = xs[SEA_BOLT_N];
    float seg = span / float(SEA_BOLT_N);
    float2 pts[SEA_BOLT_M + 1];
    for (int i = 0; i < SEA_BOLT_N; ++i) {
        float2 a = float2(xs[i] - (1.0f - ys[i]) * xend, ys[i]);
        float2 b = float2(xs[i + 1] - (1.0f - ys[i + 1]) * xend, ys[i + 1]);
        for (int k = 0; k < SEA_BOLT_S; ++k) {
            float f = float(k) / float(SEA_BOLT_S);
            float2 q = mix(a, b, f);
            if (k > 0) q.x += (rand1(id * 977u + uint(i * 4 + k), 59u, seed) - 0.5f) * 0.55f * abs(b.y - a.y);
            pts[i * SEA_BOLT_S + k] = q;
        }
    }
    pts[SEA_BOLT_M] = float2(xs[SEA_BOLT_N] - xend, 0.0f);
    for (int i = 0; i <= SEA_BOLT_M; ++i) {
        float a = 1.0f - pts[i].y;
        pts[i] = float2(mix(top.x, bot.x, a) + pts[i].x * span, bot.y + pts[i].y * span);
    }

    float hw0 = max(0.0007f * span / 0.25f, 0.0004f);   // core half width
    float hide = smoothstep(0.35f, 0.7f, cloud);
    float core = 0.0f, halo = 0.0f;
    for (int i = 0; i < SEA_BOLT_M; ++i) {
        float d = sea_seg(p, pts[i], pts[i + 1]);
        float a = float(i) / float(SEA_BOLT_M);
        float hw = hw0 * mix(0.7f, 1.3f, a);              // thicker toward the foot
        float w = max(hw, 0.75f * pxs);
        // Emerges from the cloud base: the top part shows only through gaps.
        float fade = smoothstep(0.0f, 0.05f, a) * (1.0f - hide * (1.0f - smoothstep(0.05f, 0.3f, a)));
        fade *= 0.7f + 0.3f * rand1(id * 131u + uint(i / SEA_BOLT_S), 49u, seed);
        core = max(core, fade * (1.0f - smoothstep(0.0f, w, d)) * (hw / w));
        halo = max(halo, fade * (0.55f * exp(-d / 0.004f) + 0.25f * exp(-d / 0.02f)));
    }
    // Branches off the upper half: kinked, one or two of them long, bright
    // only for the first couple of steps.
    float w = max(hw0 * 0.8f, 0.75f * pxs);
    for (int b = 0; b < 3; ++b) {
        float3 r = rand3(id * 17u + uint(b), 43u, seed);
        int s0 = 2 * SEA_BOLT_S + int(r.x * float(SEA_BOLT_M) * 0.42f);
        float2 a = pts[s0];
        float side = r.y < 0.5f ? -1.0f : 1.0f;
        float2 dirv = normalize(float2(side * (0.5f + 0.6f * r.z), -1.0f));
        int nk = (b == 0 || r.z > 0.7f) ? 11 : 6;
        float bseg = seg * 0.75f;
        for (int k = 0; k < nk; ++k) {
            float2 rr = rand2(id * 977u + uint(b * 16 + k), 47u, seed);
            dirv = normalize(dirv + float2((rr.x - 0.5f) * 1.4f, 0.0f));
            float2 nb = a + dirv * bseg * (0.6f + 0.8f * rr.y);
            float d = sea_seg(p, a, nb);
            float s = (k < 2 ? 0.6f : 0.35f) * (1.0f - float(k) / float(nk));
            core = max(core, s * (1.0f - smoothstep(0.0f, w, d)) * (hw0 * 0.8f / w));
            halo = max(halo, s * (0.5f * exp(-d / 0.003f)));
            a = nb;
        }
    }
    return float2(core, halo);
}

// --------------------------------------------------------------- lighthouse

struct SeaHouse { float3 lamp; float3 beam; float glare; float x; float t; float L; };

inline SeaHouse sea_house(float t, float L, SeaCam cam) {
    SeaHouse h;
    // Portrait: off to the right of the sea column. Landscape: nearer (about
    // 1.3x larger) and on the right third, so the wide frame has an anchor.
    bool port = cam.safe.x < 0.5f;
    float Z = port ? 1500.0f : 1150.0f;
    float sx = port ? 0.62f : 0.38f;
    float X = sx * cam.safe.x * Z / cam.f;
    h.x = X;
    h.lamp = float3(X, 39.0f, Z);
    h.t = t; h.L = L;
    // Three full turns per loop, clockwise seen from above. The phase is
    // relative to the lamp's bearing to the camera, so the beam sweeps past us
    // at the same moment in both orientations (the app swaps files mid-play).
    float bear = atan2(-Z, -X) - atan2(-1500.0f, -214.6f);
    float a = -TAU * 3.0f * t / L + 0.9f + bear;
    h.beam = normalize(float3(cos(a), 0.012f, sin(a)));   // aimed a touch high
    float3 toCam = normalize(float3(0.0f, SEA_CAM_Y, 0.0f) - h.lamp);
    float c = dot(h.beam, toCam);
    h.glare = exp(-(1.0f - c) / 0.003f);
    return h;
}

// Scattered light of the beam seen along d: Gaussian beam of slowly
// widening radius, closest approach between view ray and beam axis.
inline float sea_beam(float3 d, SeaHouse h) {
    float3 o = float3(0.0f, SEA_CAM_Y, 0.0f);
    float3 w0 = o - h.lamp;
    float b = dot(d, h.beam), dd = dot(d, w0), e = dot(h.beam, w0);
    float den = max(1.0f - b * b, 1e-5f);
    // Closest points of the view ray and the beam ray, clamped to both rays
    // (each clamp re-solves the other parameter, so the result is continuous).
    float sb = max((e - b * dd) / den, 0.0f);       // along the beam
    float sv = dot(h.lamp + sb * h.beam - o, d);    // along the view ray
    if (sv < 0.0f) { sv = 0.0f; sb = max(e, 0.0f); }
    float D = length(o + sv * d - h.lamp - sb * h.beam);
    float wr = 3.0f + sb * 0.045f;
    float sinth = max(sqrt(den), 0.25f);
    float g = 0.5f, mu = -b;
    float hg = (1.0f - g * g) / pow(1.0f + g * g - 2.0f * g * mu, 1.5f);
    // The shaft thins out well before it reaches us, so a sweep past the
    // camera reads as a glare on the lamp rather than a frame-wide wash.
    float reach = 1.0f - 0.92f * smoothstep(300.0f, 1300.0f, sb);
    // Rain density breaks the shaft up: slow periodic noise along it.
    float3 bp = h.lamp + sb * h.beam;
    float rn = gnoise3p(float3(bp.xz * (1.0f / 140.0f), h.t / h.L * 8.0f), int3(0, 0, 8), 0xBEAu);
    float breakup = 0.8f + 0.3f * rn;
    return exp(-(D * D) / (wr * wr)) / (wr * sinth) * hg * reach * breakup * sea_trans(sb) * sea_trans(sv);
}

// Rock and tower silhouette at the lighthouse. Returns coverage; `tower`
// says how much of it is the white tower rather than rock.
inline float sea_house_mask(float2 p, SeaCam cam, SeaHouse h, float pxs, thread float& tower) {
    const float Z = h.lamp.z;
    float xl = p.x * Z / cam.f - h.x;              // metres from the tower axis
    float yw = (p.y - cam.hy) * Z / cam.f + SEA_CAM_Y;
    float mpp = pxs * Z / cam.f;                   // metres per render pixel
    tower = 0.0f;
    if (abs(xl) > 120.0f || yw > 50.0f) return 0.0f;
    float u = xl / 95.0f;
    float rock = 12.0f * pow(saturate(1.0f - u * u), 0.7f) + 2.0f * (vnoise2(float2(xl * 0.08f, 3.1f), 5u) - 0.5f)
               + 1.2f * (vnoise2(float2(xl * 0.35f, 7.7f), 6u) - 0.5f) - 0.5f;
    rock = max(rock, -1.0f);
    float m = saturate((rock - yw) / mpp + 0.5f);
    // Tower: tapered, gallery, lantern, cap.
    float base = 11.5f;
    float hw = (yw < 34.5f) ? mix(3.2f, 2.3f, saturate((yw - base) / 23.0f))
             : (yw < 35.3f ? 3.0f : (yw < 40.0f ? 1.9f : 1.9f * saturate(1.0f - (yw - 40.0f) / 2.2f)));
    float top = 42.2f;
    float tw = saturate((hw - abs(xl)) / mpp + 0.5f) * saturate((top - yw) / mpp + 0.5f) * step(base - 1.0f, yw);
    tower = tw;
    return max(m, tw);
}

// -------------------------------------------------------------------- sea

constant int SEA_NWAVE = 24;
constant int SEA_NGEOM = 7;

// A fixed wave set (drawn once from a seeded PRNG): whole periods per loop,
// unit direction of travel (roughly toward the camera, short waves more
// spread, two from the left as a crossing swell), steepness A*k and phase.
// Wavelengths run from 156 m down to 5 cm.
constant float  SEA_WN[SEA_NWAVE] = {4.0f, 5.0f, 6.0f, 7.0f, 8.0f, 10.0f, 11.0f, 14.0f, 16.0f, 19.0f, 23.0f, 27.0f, 32.0f, 38.0f, 46.0f, 54.0f, 65.0f, 77.0f, 92.0f, 109.0f, 130.0f, 154.0f, 184.0f, 219.0f};
constant float2 SEA_WD[SEA_NWAVE] = {
    float2(0.2308f, -0.9730f), float2(-0.6805f, -0.7328f), float2(0.2541f, -0.9672f), float2(-0.0306f, -0.9995f),
    float2(-0.6528f, -0.7575f), float2(0.6241f, -0.7814f), float2(-0.1001f, -0.9950f), float2(-0.2465f, -0.9691f),
    float2(-0.3281f, -0.9446f), float2(0.6546f, -0.7560f), float2(0.2471f, -0.9690f), float2(-0.0992f, -0.9951f),
    float2(0.7334f, -0.6798f), float2(-0.2333f, -0.9724f), float2(0.6872f, -0.7265f), float2(0.0212f, -0.9998f),
    float2(-0.7259f, -0.6878f), float2(0.1818f, -0.9833f), float2(-0.6834f, -0.7300f), float2(-0.3107f, -0.9505f),
    float2(0.6000f, -0.8000f), float2(-0.4164f, -0.9092f), float2(0.8813f, -0.4726f), float2(0.0974f, -0.9952f)};
constant float  SEA_WS[SEA_NWAVE] = {0.0681f, 0.0690f, 0.0703f, 0.0603f, 0.0654f, 0.0888f, 0.0643f, 0.0710f, 0.0815f, 0.0836f, 0.0891f, 0.1019f, 0.0908f, 0.0748f, 0.0791f, 0.0399f, 0.0285f, 0.0402f, 0.0349f, 0.0266f, 0.0368f, 0.0268f, 0.0280f, 0.0282f};
constant float  SEA_WP[SEA_NWAVE] = {5.8070f, 1.1603f, 4.9824f, 0.5697f, 6.1713f, 3.8677f, 3.3199f, 1.5202f, 2.7679f, 4.0231f, 2.8735f, 6.2561f, 1.9809f, 0.4412f, 5.3192f, 5.3238f, 5.7194f, 2.4971f, 4.8915f, 2.0897f, 0.7414f, 0.3763f, 3.5142f, 4.5986f};

struct SeaWave { float2 dir; float k; float w; float amp; float ph; };

// Static (time-free) modulation of the wave field, shared by the tracer and the
// shading normal so they agree. Summed sines give endless parallel crest lines;
// real swell comes in groups whose crests run a few hundred metres and die out.
// A gentle domain warp bends the crest lines and a per-wave amplitude envelope
// lets each train fade in and out along its length. No time term, so the loop
// stays exact.
struct SeaField { float2 xz; float4 e; };

// Four channels of value noise in [-1,1] from one lattice lookup.
inline float4 sea_vn4(float2 p, uint seed) {
    float2 i = floor(p), f = fade5(p - i);
    int2 c = int2(i);
    float4 a = float4(pcg4d(uint4(as_type<uint2>(c), seed, 0x5EAu))) * (2.0f / 4294967295.0f) - 1.0f;
    float4 b = float4(pcg4d(uint4(as_type<uint2>(c + int2(1, 0)), seed, 0x5EAu))) * (2.0f / 4294967295.0f) - 1.0f;
    float4 d = float4(pcg4d(uint4(as_type<uint2>(c + int2(0, 1)), seed, 0x5EAu))) * (2.0f / 4294967295.0f) - 1.0f;
    float4 g = float4(pcg4d(uint4(as_type<uint2>(c + int2(1, 1)), seed, 0x5EAu))) * (2.0f / 4294967295.0f) - 1.0f;
    return mix(mix(a, b, f.x), mix(d, g, f.x), f.y);
}

inline SeaField sea_field(float2 xz) {
    SeaField o;
    // Rotated lattices so no grid axis lines up with the view or the waves.
    float2 q = float2(0.81f * xz.x - 0.59f * xz.y, 0.59f * xz.x + 0.81f * xz.y);
    // One lookup (the tracer calls this ~40 times per pixel): all four
    // channels drive the envelopes, two of them also the warp.
    float4 a = sea_vn4(q * (1.0f / 260.0f), 0x1F3u);
    o.xz = xz + a.xy * 5.5f;
    o.e = a * 1.5f;
    return o;
}

// Envelope of wave i (mean ~0.85, range ~0.2..1.35), from the field channels.
inline float sea_env(int i, float4 e) {
    float fi = float(i);
    float4 B = float4(cos(fi * 2.4f), sin(fi * 2.4f), cos(fi * 1.31f + 1.0f), sin(fi * 3.7f + 2.0f));
    return 0.2f + 1.15f * smoothstep(-0.75f, 0.75f, dot(e, B) * 0.7f);
}
constant int SEA_NENV = 14;   // waves 0..13 (156 m down to ~13 m) get envelopes

inline SeaWave sea_wave(int i, float L) {
    SeaWave s;
    s.w = TAU * SEA_WN[i] / L;
    s.k = s.w * s.w / SEA_G;                             // deep-water dispersion
    s.dir = SEA_WD[i];
    s.amp = SEA_WS[i] / s.k;
    s.ph = SEA_WP[i];
    return s;
}

// exp(sin) gives sharp crests and broad troughs; 0.4658 is its mean.
inline float sea_hgeom(float2 xz, float t, float L) {
    float h = 0.0f;
    SeaField fd = sea_field(xz);
    for (int i = 0; i < SEA_NGEOM; ++i) {
        SeaWave w = sea_wave(i, L);
        float ph = w.k * dot(w.dir, fd.xz) - w.w * t + w.ph;
        h += w.amp * sea_env(i, fd.e) * (exp(sin(ph) - 1.0f) - 0.4658f);
    }
    return 1.5f * h;
}

inline float sea_trace(float3 ro, float3 rd, float t, float L) {
    float down = -rd.y;
    float tp = (ro.y) / down;
    float t0 = (ro.y - SEA_HMAX) / down, t1 = (ro.y - SEA_HMIN) / down;
    if (t0 > 1400.0f) return tp;
    const int N = 32;
    float pa = t0, da = ro.y + rd.y * t0 - sea_hgeom((ro + rd * t0).xz, t, L);
    for (int i = 1; i <= N; ++i) {
        float tb = mix(t0, t1, float(i) / float(N));
        float3 q = ro + rd * tb;
        float db = q.y - sea_hgeom(q.xz, t, L);
        if (db < 0.0f) {
            float a = pa, b = tb;
            for (int k = 0; k < 6; ++k) {
                float m = a + (b - a) * da / (da - db);
                float3 qm = ro + rd * m;
                float dm = qm.y - sea_hgeom(qm.xz, t, L);
                if (dm < 0.0f) { b = m; db = dm; } else { a = m; da = dm; }
            }
            return a + (b - a) * da / (da - db);
        }
        pa = tb; da = db;
    }
    return tp;
}

// Surface slope of every component, each faded as its wavelength nears the
// footprint; the slope variance it would have added goes into roughness.
// fp is the pixel footprint on the water in metres: .x across the view, .y
// along it (stretched by 1/sin of the grazing angle).
inline float3 sea_normal(float2 xz, float t, float L, float2 fp, thread float& var, thread float& crest) {
    float2 g = 0.0f;
    var = 0.0f;
    float ch = 0.0f, cmax = 0.0f;
    // The warp's Jacobian is within a few % of identity, so slopes are taken
    // in warped coordinates; the envelopes vary over hundreds of metres, so
    // their own slope is negligible next to the waves'.
    SeaField fd = sea_field(xz);
    // Shading-only waves get two more small static warps (odd and even waves
    // differ), so crossing trains stop locking into a regular diamond lattice
    // of glints.
    float2 qs = float2(0.62f * xz.x + 0.78f * xz.y, -0.78f * xz.x + 0.62f * xz.y);
    // Each warp is capped at 0.3 wavelengths (bent crests, not arcs).
    // Waves under ~1.2 m also get a fine envelope: short-crested wind chop.
    float4 sw = sea_vn4(qs * (1.0f / 11.0f), 0x3A1u);
    float4 se = sea_vn4(qs.yx * (1.0f / 2.6f) + 3.7f, 0x4C9u) * 1.4f;
    for (int i = 0; i < SEA_NWAVE; ++i) {
        SeaWave w = sea_wave(i, L);
        float wd = min(1.3f, 0.3f * TAU / w.k);
        float2 wx = i < SEA_NGEOM ? fd.xz : fd.xz + ((i & 1) ? sw.xy : sw.zw) * wd;
        float lam = TAU / w.k;
        float f = length(w.dir * fp);
        float fade = 1.0f - smoothstep(0.06f, 0.28f, f / lam);
        float env = sea_env(i, i < SEA_NENV ? fd.e : se);
        float sk = 1.5f * w.amp * w.k * env;
        if (fade > 0.0f) {
            float ph = w.k * dot(w.dir, wx) - w.w * t + w.ph;
            float e = exp(sin(ph) - 1.0f);
            g += w.dir * (sk * e * cos(ph) * fade);
            // Whitecaps break at the crest and trail foam behind it (the
            // side the wave travels away from: cos(ph) > 0).
            if (i >= 5 && i < 14) { ch += w.amp * env * e * clamp(1.0f + 0.7f * cos(ph), 0.25f, 1.5f); }
        }
        if (i >= 5 && i < 14) cmax += w.amp * 0.85f;
        var += 0.108f * sk * sk * (1.0f - fade * fade);
    }
    crest = ch / max(cmax, 1e-4f);
    return normalize(float3(-g.x, 1.0f, -g.y));
}

// Irregular capillary detail for the near water, so close glints break up
// instead of showing the interference grid of a few sines. Slope from
// finite differences of periodic noise evolving along a looping time axis.
inline float2 sea_detail(float2 xz, float t, float L, float2 fp, uint seed) {
    float2 g = 0.0f;
    float s = 1.7f, amp = 0.07f;
    for (int k = 0; k < 2; ++k) {
        float w = 1.0f - smoothstep(0.15f, 0.4f, max(fp.x, fp.y) * s);
        if (w <= 0.0f) break;
        float3 p = float3(xz * s, t / L * 24.0f);
        int3 per = int3(0, 0, 24);
        float e = 0.08f;
        float n0 = gnoise3p(p, per, seed + 61u + uint(k));
        float nx = gnoise3p(p + float3(e, 0.0f, 0.0f), per, seed + 61u + uint(k));
        float nz = gnoise3p(p + float3(0.0f, e, 0.0f), per, seed + 61u + uint(k));
        g += float2(nx - n0, nz - n0) / e * amp * w;
        s *= 2.3f; amp *= 0.6f;
    }
    return g;
}

// Rings from raindrops on the near water. Each 0.4 m cell gets a drop
// every L/nT seconds (nT whole, so it loops) at a new random spot. Returns the
// slope the rings add (xz) and a short splash speck in .z.
inline float3 sea_rain_rings(float2 xz, float t, float L, float fp, uint seed) {
    const float cell = 0.4f;
    float width = 0.035f;
    float vis = 1.0f - smoothstep(0.3f, 0.8f, fp / width);
    if (vis <= 0.0f) return 0.0f;
    float2 c0 = floor(xz / cell);
    float2 g = 0.0f;
    float speck = 0.0f;
    for (int j = -1; j <= 1; ++j)
    for (int i = -1; i <= 1; ++i) {
        int2 c = int2(c0) + int2(i, j);
        float3 h = hash3(c, seed + 71u);
        float nT = floor(mix(14.0f, 32.0f, h.x));
        float T = L / nT;
        float cyc = t / T + h.y;
        float age = (cyc - floor(cyc)) * T;
        int ni = int(nT);
        uint m = uint((int(floor(cyc)) % ni + ni) % ni);          // which drop, periodic in L
        float3 r = rand3(m, uint(c.x * 7919 + c.y * 104729), seed);
        if (r.z > 0.55f) continue;                                // not every cycle has a drop
        float2 ctr = (float2(c) + 0.15f + 0.7f * r.xy) * cell;
        float2 dv = xz - ctr;
        float dist = length(dv);
        float R = 0.06f + age * 0.32f;
        float x = (dist - R) / width;
        float amp = 0.2f * exp(-age * 2.6f);
        g += (dv / max(dist, 1e-4f)) * amp * sin(x * 2.6f) * exp(-x * x);
        speck += exp(-age * 30.0f) * exp(-dist * dist / (0.0025f));
    }
    return float3(g * vis, speck * vis);
}

// Whitecaps: lacy foam on the crests of the wind sea, more of it the higher
// the crest. Thresholded fbm gives crisp patch edges, a ridged term the lace.
// The texture evolves along a periodic time axis, so it loops exactly.
inline float sea_foam(float2 xz, float t, float L, float2 fp, float crest, uint seed) {
    float m = smoothstep(0.56f, 0.92f, crest);
    if (m <= 0.0f) return 0.0f;
    float2 sc = float2(1.1f, 0.5f);                  // streaks stretched along the wind
    float3 p = float3(xz * sc, t / L * 6.0f);
    int3 per = int3(0, 0, 6);
    float f = length(fp * sc);
    float sum = 0.0f, amp = 0.5f, norm = 0.0f;
    for (int k = 0; k < 5; ++k) {
        float w = 1.0f - smoothstep(0.2f, 0.5f, f);
        sum += amp * w * gnoise3p(p, per, seed + 81u + uint(k));
        norm += amp; amp *= 0.5f; p *= 2.0f; per *= 2; f *= 2.0f;
    }
    float n = sum / norm;
    float thr = mix(0.35f, -0.15f, m);
    // Edge width follows the footprint so far foam softens instead of aliasing.
    float edge = 0.06f + 0.5f * saturate(length(fp * sc) * 4.0f);
    float patch = smoothstep(thr, thr + edge, n);
    float3 pl = float3(xz * sc * 6.0f, t / L * 12.0f);
    float lace = 1.0f - abs(gnoise3p(pl, int3(0, 0, 12), seed + 91u));
    float lw = 1.0f - smoothstep(0.1f, 0.4f, length(fp * sc) * 6.0f);
    // Torn lace: the ridged term cuts holes into the patch instead of only
    // modulating it, so up close it reads as streaky foam, not a flat decal.
    float torn = 0.2f + 0.8f * smoothstep(0.55f, 0.92f, lace);
    return m * patch * mix(1.0f, torn, lw);
}

inline float sea_ggx(float ndh, float a) {
    float a2 = a * a, k = ndh * ndh * (a2 - 1.0f) + 1.0f;
    return a2 / (PI * k * k);
}
inline float sea_vis(float ndv, float ndl, float a) {
    float a2 = a * a;
    return 0.5f / (ndl * sqrt(ndv * ndv * (1.0f - a2) + a2) + ndv * sqrt(ndl * ndl * (1.0f - a2) + a2) + 1e-5f);
}
// Specular from a light at world position lp with radiant intensity I.
inline float sea_spec(float3 P, float3 n, float3 v, float3 lp, float a) {
    float3 l = lp - P;
    float dist = length(l); l /= dist;
    float3 h = normalize(l + v);
    float ndl = saturate(dot(n, l)), ndv = max(dot(n, v), 1e-3f);
    float f = 0.02f + 0.98f * pow(1.0f - saturate(dot(v, h)), 5.0f);
    return sea_ggx(saturate(dot(n, h)), a) * sea_vis(ndv, ndl, a) * f * ndl;
}

// -------------------------------------------------------------------- rain

constant int SEA_RAIN_LAYERS = 4;

// Streak layers by depth; each column falls a whole number of repeats per
// loop at its own speed, so the rain is exactly periodic.
inline float sea_rain(float2 p, float t, float L, float pxs, uint seed) {
    float acc = 0.0f;
    for (int k = 0; k < SEA_RAIN_LAYERS; ++k) {
        float depth = float(k) / float(SEA_RAIN_LAYERS - 1);    // 0 far .. 1 near
        float cw    = mix(0.0042f, 0.024f, depth * depth);
        float rep   = mix(0.42f, 1.30f, depth);
        float len   = mix(0.035f, 0.20f, depth);
        float halfw = mix(0.00035f, 0.0016f, depth);
        float vwant = mix(0.85f, 2.6f, depth);
        float slant = 0.14f + 0.06f * rand1(uint(k), 83u, seed);   // each layer its own wind
        float2 q = float2(p.x + slant * p.y, p.y);
        float col = floor(q.x / cw);
        uint4 hh = pcg4d(uint4(as_type<uint>(int(col)), uint(k), seed, 0x51A7u));
        float4 h = float4(u01(hh.x), u01(hh.y), u01(hh.z), u01(hh.w));
        if (h.w > mix(0.55f, 0.32f, depth)) continue;
        float v = max(1.0f, round(vwant * mix(0.85f, 1.15f, h.z) * L / rep)) * rep / L;
        float dx = (fract(q.x / cw) - (0.2f + 0.6f * h.x)) * cw;
        float ly = fract((q.y + t * v) / rep + h.y) * rep;
        float along = ly / (len * (0.7f + 0.6f * fract(h.z * 13.7f)));
        float body = smoothstep(0.0f, 0.1f, along) * (1.0f - smoothstep(0.25f, 1.0f, along));
        float w = max(halfw, 0.75f * pxs);
        float across = (1.0f - smoothstep(0.0f, w, abs(dx))) * (halfw / w);
        // Gusts: heavier curtains of rain swell and fade across the frame,
        // periodic in time so the loop stays exact.
        float gust = vnoise2p(float2(q.x * 1.3f + float(k) * 7.1f, t / L * 5.0f), int2(0, 5), seed + 85u + uint(k));
        acc += across * body * mix(0.30f, 0.40f, depth) * (0.35f + 0.65f * fract(h.w * 7.31f)) * (0.45f + 1.1f * gust);
    }
    return acc;
}

// ------------------------------------------------------------------ kernel

kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float2 p = frame_uv(gid, u.resolution);
    float pxs = px_size(u.resolution);
    float t = u.time, L = u.loop;
    SeaCam cam = sea_cam(u.resolution);
    float3 ro = float3(0.0f, SEA_CAM_Y, 0.0f);
    float3 rd = sea_ray(p, cam);

    SeaLight lt[SEA_MAXL];
    int nl = sea_lights(t, L, cam, lt);
    SeaHouse house = sea_house(t, L, cam);

    float flashAll = 0.0f;
    for (int i = 0; i < nl; ++i) flashAll += lt[i].illum * lt[i].trans;

    // Sea pixels trace the water first and look up the sky along the
    // reflection; sky pixels look along the view ray. One sky call either way.
    bool sea = rd.y < 0.0f;
    float hitDist = INFINITY, F = 0.0f, a = 0.03f, fpk = 1.0f;
    float3 P = 0.0f, n = float3(0.0f, 1.0f, 0.0f), v = -rd, dir = rd;
    float foam = 0.0f, speck = 0.0f;
    if (sea) {
        hitDist = sea_trace(ro, rd, t, L);
        P = ro + rd * hitDist;
        // Footprint axes: across = sideways in the world, along = toward the
        // horizon. The view is nearly along +z, so x/z are good enough.
        float2 fp = hitDist * cam.pxa * float2(1.0f, 1.0f / max(-rd.y, 0.003f));
        float var, crest;
        n = sea_normal(P.xz, t, L, fp, var, crest);
        float3 rr = hitDist < 60.0f ? sea_rain_rings(P.xz, t, L, fp.y, u.seed) : 0.0f;
        float2 dg = hitDist < 150.0f ? sea_detail(P.xz, t, L, fp, u.seed) : 0.0f;
        n = normalize(n - float3(rr.x + dg.x, 0.0f, rr.y + dg.y));
        speck = rr.z;
        foam = sea_foam(P.xz, t, L, fp, crest, u.seed);
        float rough = sqrt(0.035f * 0.035f + 2.0f * var);
        a = clamp(rough, 0.03f, 1.0f);
        F = 0.02f + 0.98f * pow(1.0f - max(dot(n, v), 1e-3f), 5.0f);
        float3 r = reflect(rd, n);
        dir = normalize(float3(r.x, max(r.y, 0.002f), r.z));
        fpk = 4.0f + 300.0f * rough;
    }
    SeaSkyOut s = sea_sky(dir, t, cam, fpk, u.seed, lt, nl, sea);

    float3 col;
    if (!sea) {
        col = s.col;
        float occl = (1.0f - s.cover) * (1.0f - 0.5f * s.curtain);
        for (int i = 0; i < nl; ++i) {
            if (lt[i].kind != 0 || lt[i].chan < 1e-4f) continue;
            float2 top = sea_project(float3(lt[i].src.x, SEA_CEIL, lt[i].src.z), cam);
            float2 bot = sea_project(lt[i].foot, cam);
            float2 b = sea_bolt(p, top, bot, lt[i].id, u.seed, pxs, s.dens);
            col += (b.x * 9.0f + b.y * 0.6f) * lt[i].chan * lt[i].trans * SEA_BOLT * occl;
        }
        col += sea_beam(rd, house) * 0.7f * SEA_LAMP;
    } else {
        float3 water = s.col * F;
        // Lightning channels as vertical line lights: the point nearest the
        // reflected ray gives the long broken glitter under each bolt.
        for (int i = 0; i < nl; ++i) {
            // Sheet and far flashes have no channel: a short segment inside the cloud.
            float3 B = float3(lt[i].src.x, lt[i].kind == 0 ? SEA_CEIL : lt[i].src.y + 150.0f, lt[i].src.z);
            float3 A = lt[i].kind == 0 ? lt[i].foot : B - float3(0.0f, 300.0f, 0.0f);
            float3 L0 = A - P, Ld = B - A;
            float rl = dot(dir, Ld), tt = (dot(dir, L0) * rl - dot(L0, Ld)) / max(dot(Ld, Ld) - rl * rl, 1e-3f);
            float3 lp = P + L0 + saturate(tt) * Ld;
            float I = (lt[i].kind == 0 ? lt[i].chan * 1.6f + lt[i].illum * 0.5f : lt[i].illum * 0.6f) * lt[i].trans;
            water += sea_spec(P, n, v, lp, a) * I * 0.06f * SEA_BOLT;
        }
        // Lighthouse lamp glints, strongest as the beam swings past.
        float3 toP = normalize(P - house.lamp);
        float beamOn = exp(-(1.0f - dot(house.beam, toP)) / 0.004f);
        water += sea_spec(P, n, v, house.lamp, a) * (0.02f + 1.5f * beamOn) * 0.05f * SEA_LAMP;
        // Deep water body and thin backlit crests.
        float3 body = float3(0.0022f, 0.0054f, 0.0065f) * (1.0f + 6.0f * flashAll);
        float crest = saturate((P.y + 0.3f) / 2.5f);
        float sss = 0.0f;
        for (int i = 0; i < nl; ++i) {
            float2 dl = normalize(lt[i].src.xz - P.xz);
            sss += lt[i].illum * lt[i].trans * pow(saturate(dot(normalize(rd.xz), dl)), 6.0f);
        }
        water += (body + sss * crest * crest * float3(0.02f, 0.07f, 0.065f)) * (1.0f - F);
        // Rain-roughened water scatters a little sky whatever its tilt, so a
        // trough facing us holds detail instead of going OLED-black.
        water += s.col * 0.022f;
        // Foam and splash specks: diffuse, lit by the sky and the flashes.
        float3 lightIn = float3(0.010f, 0.013f, 0.020f) + SEA_BOLT * flashAll * 0.22f;
        // Foam is shaded: bright on the lifted crest, dimmer where it slid
        // into a trough.
        float fsh = 0.55f + 0.7f * saturate((P.y + 0.8f) / 3.0f);
        water = mix(water, lightIn * fsh, saturate(foam * 0.75f) * exp(-hitDist / 250.0f));
        water += lightIn * speck * 0.6f;
        // Haze toward the horizon.
        // Spray and rain thicken the air at sea level: a softer horizon.
        float T = exp(-hitDist / 2600.0f);
        float3 hd = normalize(float3(rd.x, 0.0f, rd.z));
        float3 hzc = sea_haze(hd) + sea_flash_glow(hd, lt, nl);
        col = water * T + hzc * (1.0f - T);
        // The last few pixels of sea dissolve into spray haze: no ruler line.
        col = mix(col, hzc, 0.85f * (1.0f - smoothstep(0.0f, 0.007f, -rd.y)));
    }

    // Lighthouse silhouette and lantern (in front of everything beyond 1.5 km).
    if (hitDist > house.lamp.z) {
        float tower;
        float m = sea_house_mask(p, cam, house, pxs, tower);
        if (m > 0.0f) {
            float T = sea_trans(house.lamp.z);
            float3 rock = float3(0.004f, 0.005f, 0.007f) * (1.0f + 4.0f * flashAll);
            float3 tw = float3(0.020f, 0.022f, 0.026f) * (1.0f + 5.0f * flashAll);
            float3 c = mix(rock, tw, tower) * T + sea_haze(rd) * (1.0f - T);
            col = mix(col, c, m);
        }
    }
    float2 lp = sea_project(house.lamp, cam);
    float rl = length(p - lp);
    col += SEA_LAMP * (0.35f * exp(-rl / 0.0012f) + 0.04f * exp(-rl / 0.006f)) * 0.6f;
    col += SEA_LAMP * house.glare * (1.2f * exp(-rl / 0.0016f) + 0.12f * exp(-rl / 0.009f) + 0.012f * exp(-rl / 0.05f));

    // Rain, lit by the sky and the flashes.
    float rain = sea_rain(p, t, L, pxs, u.seed);
    col += rain * (float3(0.030f, 0.037f, 0.050f) + SEA_BOLT * flashAll * 0.30f + SEA_LAMP * house.glare * 0.1f);

    // Grade: exposure, soft shoulder, gentle vignette, grain.
    col *= SEA_EXPOSURE;
    float2 vq = p / float2(max(aspect_of(u.resolution), 1.0f) * 0.62f, p.y < 0.0f ? 0.8f : 0.62f);
    col *= 1.0f - 0.22f * smoothstep(0.35f, 1.25f, length(vq));
    col = 1.0f - exp(-col);
    float3 c = srgb_encode(col);
    float g = vnoise3(float3(p * 1150.0f, float(u.frame) * 17.0f), u.seed + 99u) - 0.5f;
    c += g * 0.018f * SEA_GRAIN * (0.35f + c.g) ;
    out.write(float4(saturate(c), 1.0f), gid);
}
