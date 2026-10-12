// above.metal: "Above the Storm". Night, high above a sea of storm-cloud tops
// that stretches to a slightly curved horizon. A hero cumulonimbus rises into
// the sky (rounded overshooting dome, a downwind anvil that thins into fibres,
// mammatus underneath), with smaller cells and towering cumulus around it. A
// low moon on the left, a little ahead, splits towers and turrets into lit and
// shadowed halves; stars, a moon-washed Milky Way and a thin warm line of
// towns past the horizon.
//
// World units are km, and cloud shapes live in (x, altitude, z) space: the
// planet is a parabola with an exaggerated radius, so the horizon dips and
// bows a little. The camera looks along +z from ABOVE_CAM_ALT km over the mean
// deck top and floats on a small closed ellipse, so near turrets drift past the
// far towers. The cloud field is a signed "inside" value v (km, > 0 inside):
// a cauliflower heightfield deck (with broad mounds so the far deck and the
// horizon stay lumpy) merged with storm towers built from clusters of
// breathing bubbles, a 3D bubble skin and density-tapered anvils.
//
// The march skips empty space with cheap bounds (per-ray boxes around each
// tower) and integrates density analytically per segment, so steep flanks do
// not slice into contour bands. Lighting is evaluated once where the ray
// crosses the surface, found by regula falsi, so it varies continuously
// between pixels. Lightning is light diffusing out of the volume: falloff from
// each stroke's own (crawling) channel, attenuated by the cloud between the
// channel and the surface, so thin rims, gaps and the anvil glow while thick
// lobes stand dark; it is added after the haze and rolled off softly so a lit
// cell never clips. The deck also pulses softly from strikes buried in it.
// The scene anti-aliases itself (footprint-sized edges and octave fades,
// finer steps through tower fringes, Gaussian stars of at least 0.6 px) and is
// meant to render at --ss 1.
//
// Everything is exactly periodic over u.loop (integer frequencies for the
// breathing and the camera path, lightning scheduled with since_event), so the
// scene needs no loop crossfade.
//
// Tuning macros: ABOVE_EXPOSURE, ABOVE_GRAIN, ABOVE_GRAIN_RES, ABOVE_FLOAT,
// ABOVE_STEPS, ABOVE_DT, ABOVE_BISECT (secant steps), ABOVE_SOFT, ABOVE_FRINGE,
// ABOVE_HY_P/_L (horizon height), ABOVE_FOG_DECK, ABOVE_FLASH_GAIN/_TAU/_CAP,
// ABOVE_PULSE_GAIN/_RHO, ABOVE_DECK_VZ. ABOVE_DEBUG_STEPS shows march cost
// (red: steps / 110, green: full-detail steps / 60).

#ifndef ABOVE_EXPOSURE
#define ABOVE_EXPOSURE 1.25
#endif
#ifndef ABOVE_GRAIN
#define ABOVE_GRAIN 0.012
#endif
#ifndef ABOVE_GRAIN_RES
#define ABOVE_GRAIN_RES 770.0
#endif
#ifndef ABOVE_DT
#define ABOVE_DT 1.4
#endif
#ifndef ABOVE_FLOAT
#define ABOVE_FLOAT 0.3
#endif
#ifndef ABOVE_BISECT
#define ABOVE_BISECT 1
#endif
#ifndef ABOVE_SOFT
#define ABOVE_SOFT 0.07f
#endif
#ifndef ABOVE_HY_P
#define ABOVE_HY_P -0.05f
#endif
#ifndef ABOVE_HY_L
#define ABOVE_HY_L -0.10f
#endif
#ifndef ABOVE_FLASH_TAU
#define ABOVE_FLASH_TAU 4.0f
#endif
#ifndef ABOVE_FOG_DECK
#define ABOVE_FOG_DECK 34.0f
#endif
#ifndef ABOVE_FLASH_GAIN
#define ABOVE_FLASH_GAIN 5.0f
#endif
#ifndef ABOVE_DECK_VZ
#define ABOVE_DECK_VZ 4.0f
#endif
#ifndef ABOVE_PULSE_RHO
#define ABOVE_PULSE_RHO 1.6f
#endif
#ifndef ABOVE_PULSE_GAIN
#define ABOVE_PULSE_GAIN 2.5f
#endif
#ifndef ABOVE_FLASH_CAP
#define ABOVE_FLASH_CAP 0.30f
#endif
#ifndef ABOVE_FRINGE
#define ABOVE_FRINGE 1.0f
#endif
#ifndef ABOVE_STEPS
#define ABOVE_STEPS 220
#endif

constant float ABOVE_R        = 600.0f;  // planet radius, exaggerated
constant float ABOVE_CAM_ALT  = 2.0f;
constant float ABOVE_SIGMA    = 7.0f;    // cloud extinction, 1/km
constant float ABOVE_TOP      = 11.8f;   // nothing in the cloud field is higher
constant float ABOVE_DECK_MAX = 1.35f;   // nor in the deck
constant float ABOVE_TMAX     = 170.0f;
constant float2 ABOVE_WIND    = float2(0.86f, 0.51f);   // anvils spread this way (xz)
constant float2 ABOVE_WPERP   = float2(-0.51f, 0.86f);

// Storm towers: (x, z, stem radius, anvil altitude) and anvil (half width,
// thickness, downwind length, spin of the bubble layout). The hero stands
// close and tall so it rises well into the sky in both orientations; the
// rest are spread so portrait keeps 0..2 inside its safe zone and landscape
// gets the far giant and two growing cumulus at its edges.
constant int ABOVE_NCELLS = 6;
constant float4 ABOVE_CELLS[ABOVE_NCELLS] = {
    float4( -4.0f,  25.0f, 2.5f, 8.4f),   // 0 hero
    float4( 13.0f,  50.0f, 1.8f, 5.6f),   // 1 B
    float4(  5.0f,  64.0f, 1.4f, 3.8f),   // 2 C, towering cumulus between hero and B
    float4(-44.0f,  80.0f, 2.6f, 7.6f),   // 3 E, far giant (landscape)
    float4(-24.0f,  40.0f, 1.2f, 3.2f),   // 4 F, towering cumulus (landscape left)
    float4( 27.0f,  40.0f, 1.0f, 2.6f),   // 5 G, same (landscape right)
};
constant float4 ABOVE_ANVILS[ABOVE_NCELLS] = {
    float4(5.5f, 2.6f, 15.0f, 0.4f),
    float4(4.2f, 2.2f,  7.0f, 2.1f),
    float4(0.0f, 0.0f,  0.0f, 3.9f),   // C: no anvil
    float4(4.5f, 2.0f,  9.0f, 5.2f),
    float4(0.0f, 0.0f,  0.0f, 1.3f),   // F: no anvil yet
    float4(0.0f, 0.0f,  0.0f, 4.6f),   // G: same
};

// Lightning sources (x, z, altitude, spread). 0..5 sit in the towers, 6..7
// are strikes buried in the near deck, 8..11 pulse softly under the deck,
// 12..14 are storms beyond the horizon we only see as glow. The deck ones
// sit 6..16 km out, in the stretch of deck we look down on.
constant int ABOVE_SRC_DECK = 6, ABOVE_SRC_PULSE = 8, ABOVE_SRC_FAR = 12;
constant float4 ABOVE_SRC[15] = {
    float4( -4.0f,  25.0f,  3.8f, 2.5f),   // 0 hero
    float4( 13.0f,  50.0f,  2.6f, 1.8f),   // 1 B
    float4(  5.0f,  64.0f,  1.8f, 1.4f),   // 2 C
    float4(-44.0f,  80.0f,  3.4f, 2.6f),   // 3 E
    float4(-24.0f,  40.0f,  1.4f, 1.2f),   // 4 F
    float4( 27.0f,  40.0f,  1.1f, 1.0f),   // 5 G
    float4( -1.5f,  10.5f, -0.6f, 1.2f),   // 6 D, under the near deck
    float4(  3.0f,  13.5f, -0.6f, 1.2f),   // 7 D2
    float4( -2.5f,   9.0f, -0.7f, 1.5f),   // 8 pulses
    float4(  3.5f,  12.0f, -0.7f, 1.5f),   // 9
    float4( -1.0f,  16.0f, -0.7f, 2.0f),   // 10
    float4(  1.5f,   6.5f, -0.7f, 1.2f),   // 11
    float4(-34.0f,  88.0f, -0.8f, 4.0f),   // 12 far
    float4( 26.0f,  96.0f, -0.8f, 4.0f),   // 13 far
    float4(  2.0f, 118.0f, -0.8f, 4.0f),   // 14 far
};

// Lightning schedule for a 40 s loop: (t0, source, strength, strokes or
// pulses). A strike you can see across the whole frame (hero tower or the
// deck below us) every 5..7 s; between them the far towers flash, the deck
// breathes with slow pulses and the horizon flickers.
constant int ABOVE_NEV = 21;
constant float4 ABOVE_EVENTS[ABOVE_NEV] = {
    float4( 1.5f,  0.0f, 1.00f, 3.0f),
    float4( 4.2f,  8.0f, 0.30f, 3.0f),
    float4( 6.8f,  7.0f, 0.90f, 2.0f),
    float4( 9.0f,  1.0f, 0.90f, 2.0f),
    float4(10.6f,  9.0f, 0.25f, 3.0f),
    float4(12.4f,  6.0f, 0.60f, 2.0f),
    float4(14.8f,  2.0f, 0.80f, 2.0f),
    float4(15.8f, 13.0f, 0.50f, 2.0f),
    float4(17.0f, 10.0f, 0.30f, 2.0f),
    float4(19.0f,  0.0f, 0.75f, 2.0f),
    float4(21.5f, 12.0f, 0.45f, 1.0f),
    float4(23.0f, 11.0f, 0.30f, 4.0f),
    float4(25.2f,  0.0f, 0.60f, 2.0f),
    float4(27.0f,  3.0f, 0.80f, 2.0f),
    float4(28.3f,  4.0f, 0.50f, 2.0f),
    float4(29.6f,  8.0f, 0.25f, 3.0f),
    float4(32.4f,  0.0f, 0.95f, 3.0f),
    float4(34.0f,  5.0f, 0.40f, 1.0f),
    float4(35.2f, 14.0f, 0.40f, 2.0f),
    float4(36.6f,  9.0f, 0.30f, 3.0f),
    float4(38.3f,  6.0f, 0.75f, 1.0f),
};

// The moon is low on the left, a little ahead of us: turrets and towers split
// into lit and shadowed halves.
constant float3 ABOVE_MOON     = float3(-0.925f, 0.342f, 0.163f);   // yaw -80 deg, elev 20 deg
constant float3 ABOVE_MOON_COL = float3(0.80f, 0.84f, 0.95f);
constant float3 ABOVE_FLASH_IN  = float3(0.80f, 0.82f, 1.0f);   // violet white near the channel
constant float3 ABOVE_FLASH_OUT = float3(0.55f, 0.55f, 0.95f);  // falloff through the volume

// ------------------------------------------------------------------ noise
// Gradient noise with Perlin's 12-edge gradient set picked from hash bits:
// no trig per corner, which matters inside the march.

inline float above_g3(uint h, float3 f) {
    uint k = h & 15u;
    float a = k < 8u ? f.x : f.y;
    float b = k < 4u ? f.y : ((k == 12u || k == 14u) ? f.x : f.z);
    return ((k & 1u) ? -a : a) + ((k & 2u) ? -b : b);
}

inline float above_noise3_cell(uint4 b, float3 f, float3 w) {
    float n000 = above_g3(pcg4d(b).x, f);
    float n100 = above_g3(pcg4d(b + uint4(1, 0, 0, 0)).x, f - float3(1, 0, 0));
    float n010 = above_g3(pcg4d(b + uint4(0, 1, 0, 0)).x, f - float3(0, 1, 0));
    float n110 = above_g3(pcg4d(b + uint4(1, 1, 0, 0)).x, f - float3(1, 1, 0));
    float n001 = above_g3(pcg4d(b + uint4(0, 0, 1, 0)).x, f - float3(0, 0, 1));
    float n101 = above_g3(pcg4d(b + uint4(1, 0, 1, 0)).x, f - float3(1, 0, 1));
    float n011 = above_g3(pcg4d(b + uint4(0, 1, 1, 0)).x, f - float3(0, 1, 1));
    float n111 = above_g3(pcg4d(b + uint4(1, 1, 1, 0)).x, f - float3(1, 1, 1));
    return mix(mix(mix(n000, n100, w.x), mix(n010, n110, w.x), w.y),
               mix(mix(n001, n101, w.x), mix(n011, n111, w.x), w.y), w.z);
}

inline float above_noise3(float3 p, uint seed) {
    float3 fl = floor(p); int3 i = int3(fl); float3 f = p - fl;
    return above_noise3_cell(uint4(as_type<uint3>(i), seed), f, fade5(f));
}

inline float above_g2(uint h, float2 f) {
    uint k = h & 7u;
    float2 g = k < 4u ? float2((k & 1u) ? -1.0f : 1.0f, (k & 2u) ? -1.0f : 1.0f) * 0.7071f
                      : ((k & 1u) ? float2((k & 2u) ? -1.0f : 1.0f, 0.0f) : float2(0.0f, (k & 2u) ? -1.0f : 1.0f));
    return dot(g, f);
}

inline float2 above_g2x2(uint h, float2 f) {
    return float2(above_g2(h, f), above_g2(h >> 3u, f));
}

// Two independent gradient noises from one set of hashes, ~[-1,1].
inline float2 above_noise2x2(float2 p, uint seed) {
    float2 fl = floor(p); int2 i = int2(fl); float2 f = p - fl;
    uint x0 = as_type<uint>(i.x), y0 = as_type<uint>(i.y);
    float2 w = fade5(f);
    float2 a = above_g2x2(pcg3d(uint3(x0,      y0,      seed)).x, f);
    float2 b = above_g2x2(pcg3d(uint3(x0 + 1u, y0,      seed)).x, f - float2(1, 0));
    float2 c = above_g2x2(pcg3d(uint3(x0,      y0 + 1u, seed)).x, f - float2(0, 1));
    float2 d = above_g2x2(pcg3d(uint3(x0 + 1u, y0 + 1u, seed)).x, f - float2(1, 1));
    return 1.414f * mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

inline float above_noise2(float2 p, uint seed) {
    float2 fl = floor(p); int2 i = int2(fl); float2 f = p - fl;
    uint x0 = as_type<uint>(i.x), y0 = as_type<uint>(i.y);
    float2 w = fade5(f);
    float a = above_g2(pcg3d(uint3(x0,      y0,      seed)).x, f);
    float b = above_g2(pcg3d(uint3(x0 + 1u, y0,      seed)).x, f - float2(1, 0));
    float c = above_g2(pcg3d(uint3(x0,      y0 + 1u, seed)).x, f - float2(0, 1));
    float d = above_g2(pcg3d(uint3(x0 + 1u, y0 + 1u, seed)).x, f - float2(1, 1));
    return 1.414f * mix(mix(a, b, w.x), mix(c, d, w.x), w.y);
}

inline float above_fbm3(float3 p, int oct, uint seed) {
    const float3x3 m = float3x3(float3(0.00f, 1.60f, 1.20f), float3(-1.60f, 0.72f, -0.96f), float3(-1.20f, -0.96f, 1.28f));
    float s = 0.0f, a = 0.5f, n = 0.0f;
    for (int k = 0; k < oct; ++k) { s += a * above_noise3(p, seed + uint(k) * 101u); n += a; a *= 0.5f; p = m * p; }
    return s / n;
}

// Packed domes, one per lattice cell, in [0, ~1.15]: the cauliflower turrets
// of a convective cloud top seen from above. Each dome breathes with an
// integer number of cycles per loop. Centres sit in the middle half of their
// cell and radii are <= 0.75 cells, so only the 2x2 nearest cells reach x.
inline float above_domes(float2 x, float tz, int kmax, uint seed) {
    float2 base = floor(x - 0.5f);
    float best = 0.0f;
    for (int j = 0; j < 4; ++j) {
        int2 c = int2(base) + int2(j & 1, j >> 1);
        uint3 h = pcg3d(uint3(as_type<uint2>(c), seed));
        float2 ctr = float2(c) + 0.25f + 0.5f * float2(u01(h.x), u01(h.y));
        float hz = u01(h.z);
        float r = 0.52f + 0.23f * hz;
        float k = float(1 + int(h.x & 7u) % kmax);
        float hv = (0.6f + 0.4f * fract(hz * 7.31f)) * (1.0f + 0.16f * sin(TAU * (k * tz + fract(hz * 3.7f))));
        float q = max(1.0f - length_squared(x - ctr) / (r * r), 0.0f);
        best = max(best, hv * (0.55f * sqrt(q) + 0.45f * q));
    }
    return best;
}

inline float above_smax(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0f) / k;
    return max(a, b) + h * h * k * 0.25f;
}

inline float above_smin(float a, float b, float k) {
    float h = max(k - abs(a - b), 0.0f) / k;
    return min(a, b) - h * h * k * 0.25f;
}

// --------------------------------------------------------------- clouds

constant int   ABOVE_DOME_OCT = 5;
constant float ABOVE_DOME_S0  = 2.6f;    // km, cell size of the biggest turrets
constant float ABOVE_DOME_A0  = 0.40f;   // km, their height; each octave halves both
constant float ABOVE_DECK_MARGIN = ABOVE_DOME_A0 * 1.15f * (0.5f + 0.25f + 0.125f + 0.0625f);

// Deck height without the fine turrets (km altitude). `base` is the macro
// undulation alone (for ambient occlusion); `lumpy` says whether this is a
// field of turrets (1) or smoother stratiform cloud (~0.3).
inline float above_deck_coarse(float2 xz, float tz, uint seed, thread float &base, thread float &lumpy) {
    float2 q = xz + above_noise2x2(xz * 0.07f, seed + 3u) * 3.0f;
    float2 m = q * (1.0f / 16.0f);
    float2 n = above_noise2x2(m, seed + 5u);
    // broad mounds (~9 km) keep the far deck and the horizon line lumpy
    float mound = above_domes(q * (1.0f / 9.0f) + 3.7f, 0.0f, 1, seed + 9u);
    base = -0.62f + 0.55f * n.x + 0.25f * above_noise2(m * 2.03f + 5.1f, seed + 6u) + 0.42f * mound;
    lumpy = mix(0.45f, 1.0f, smoothstep(-0.35f, 0.25f, n.y));
    return base + ABOVE_DOME_A0 * lumpy * above_domes(q / ABOVE_DOME_S0, tz, 1, seed + 7u);
}

// Fine turret octaves; `oct` is fractional so the last octave fades in.
inline float above_deck_fine(float2 xz, float tz, float oct, uint seed) {
    const float2x2 m = float2x2(float2(0.8f, 0.6f), float2(-0.6f, 0.8f));
    float h = 0.0f, a = ABOVE_DOME_A0 * 0.5f, s = ABOVE_DOME_S0 * 0.47f;
    float2 p = m * xz;
    for (int k = 1; k < ABOVE_DOME_OCT; ++k) {
        float wk = saturate(oct - float(k));
        if (wk <= 0.0f) break;
        h += wk * a * above_domes(p / s, tz, 1 + k, seed + 31u * uint(k));
        a *= 0.5f; s *= 0.47f; p = m * p;
    }
    return h;
}

// Bubble layout of a tower body (unit stem radius): offset x, z, height
// fraction up the stem, radius. Wide base lobes that merge into the deck, a
// column of uneven lobes that bulge in and out, and a crown of smaller domes
// that push up through the anvil. Each tower spins and mirrors the table and
// jitters the radii, so no two towers share a silhouette.
constant int ABOVE_NB = 18;
constant float4 ABOVE_BUBBLES[ABOVE_NB] = {
    // main column, widening a little toward the crown
    float4(-0.45f, -0.20f, 0.00f, 0.95f),
    float4( 0.45f,  0.30f, 0.02f, 0.90f),
    float4( 0.00f, -0.55f, 0.10f, 0.85f),
    float4(-0.35f,  0.45f, 0.20f, 0.82f),
    float4( 0.45f, -0.30f, 0.30f, 0.85f),
    float4(-0.55f, -0.10f, 0.42f, 0.85f),
    float4( 0.35f,  0.45f, 0.50f, 0.90f),
    float4( 0.05f, -0.50f, 0.60f, 0.90f),
    float4(-0.50f,  0.35f, 0.70f, 0.92f),
    float4( 0.60f,  0.00f, 0.78f, 0.90f),
    float4(-0.25f, -0.45f, 0.88f, 0.85f),
    float4( 0.35f,  0.50f, 0.95f, 0.80f),
    float4(-0.60f,  0.05f, 1.00f, 0.70f),
    // two flanking towers that step down from the main column
    float4(-1.50f, -0.60f, 0.04f, 0.72f),
    float4(-1.40f, -0.70f, 0.20f, 0.56f),
    float4(-1.25f, -0.80f, 0.32f, 0.42f),
    float4( 1.00f, -1.35f, 0.04f, 0.65f),
    float4( 0.90f, -1.25f, 0.15f, 0.48f),
};

// Cheap lower bound (km) on tower k's distance: its bounding cylinder, the
// skirt, the domes and the anvil slab without noise, less what the smooth
// unions can add. Where it exceeds ~1 km the tower is invisible there and
// the march only needs a safe step, so the bubble cluster is not evaluated.
inline float above_tower_lb(int k, float3 p) {
    float4 c = ABOVE_CELLS[k];
    float4 av = ABOVE_ANVILS[k];
    float R = c.z, H = c.w;
    float3 q = p - float3(c.x, 0.0f, c.y);
    float d = max(length(q.xz - ABOVE_WIND * (0.2f * R)) - 2.65f * R,
                  max(-1.7f * R - 0.4f - q.y, q.y - H - 0.5f * R)) - 0.35f * R;
    float3 e = float3(q.x, q.y + 0.6f, q.z);
    float3 rad = float3(2.2f * R, 0.6f + 0.15f * R, 2.2f * R);
    d = min(d, (length(e / rad) - 1.0f) * min(rad.x, rad.y));
    float K = 0.3f * R;
    if (av.x > 0.0f) {
        float2 lt = ABOVE_WIND * (0.4f * R);
        d = min(d, length(q - float3(lt.x, H + 0.55f, lt.y)) - 0.68f * R);
        d = min(d, length(q.xz - lt) - 1.3f * R);   // the two side domes, loosely
        float2 r2 = q.xz - lt;
        float along = dot(r2, ABOVE_WIND), across = dot(r2, ABOVE_WPERP);
        float Lh = av.z, th = av.y;
        float hw = av.x * (0.5f + 0.7f * smoothstep(-0.1f, 0.9f, along / Lh));
        float2 e2 = float2((along - 0.43f * Lh) / (0.55f * Lh), across / hw);
        e2 *= e2;
        float ax = min(0.55f * Lh, hw);
        d = min(d, max((sqrt(sqrt(dot(e2, e2))) - 1.1f) * ax, max(q.y - H - 0.6f * th, H - 0.9f * th - q.y) - 0.4f * th));
        K = max(0.35f * R, 0.8f * th);
    }
    return d - 0.25f * K;
}

// Signed distance (km, < 0 inside) to tower k without surface noise: a
// cluster of breathing bubbles up the stem on a wide skirt, smooth-unioned;
// for mature cells an overshooting dome with secondary domes, and an anvil
// pushed downwind whose top is domed and whose underside rises toward the
// tip. `anv` says how much the anvil owns this point; `dens` thins the anvil
// toward its rims and tip so it dissolves into fibres instead of ending at a
// surface.
inline float above_tower(int k, float3 p, float tz, uint seed, thread float &anv, thread float &dens) {
    float4 c = ABOVE_CELLS[k];
    float4 av = ABOVE_ANVILS[k];
    float R = c.z, H = c.w;
    float3 q = p - float3(c.x, 0.0f, c.y);
    float sn = sin(av.w), cs = cos(av.w);
    float mir = (k & 1) ? -1.0f : 1.0f;
    // Far from the column a bounding cylinder is a safe lower bound, which
    // spares the bubble loop for most march steps. A bound is only used
    // where even after the smooth unions (radius K) the result stays beyond
    // 0.75 km, i.e. outside anything visible (no skin, no density), so the
    // shortcut cannot show as a seam.
    float K = av.x > 0.0f ? max(0.35f * R, 0.8f * av.y) : 0.3f * R;
    float far = 0.75f + 1.25f * K;
    float dcyl = max(length(q.xz - ABOVE_WIND * (0.2f * R)) - 2.65f * R,
                     max(-1.7f * R - 0.4f - q.y, q.y - H - 0.5f * R)) - 0.35f * R;
    float d = dcyl;
    if (dcyl < far) {
    d = 1e3f;
    // breathing: each bubble swells once per loop, phases spread by a
    // golden-angle step (a rotation recurrence instead of a sin per bubble)
    float2 ph = float2(sin(TAU * tz + float(k)), cos(TAU * tz + float(k)));
    const float2 rs = float2(sin(2.4f), cos(2.4f));
    for (int j = 0; j < ABOVE_NB; ++j) {
        float4 b = ABOVE_BUBBLES[j];
        float2 o = float2(cs * b.x - sn * b.y, sn * b.x + cs * b.y) * R;
        o.x *= mir;
        float js = fract(float(j) * 0.618f + float(k) * 0.37f);
        float hf = saturate(b.z + 0.05f * (js - 0.5f));
        float2 lean = ABOVE_WIND * (0.4f * R * hf * hf);
        float3 bc = float3(o.x + lean.x, mix(-0.4f, H - 0.6f, hf), o.y + lean.y);
        float br = R * b.w * (0.88f + 0.24f * js) * (1.0f + 0.05f * ph.x);
        d = above_smin(d, length(q - bc) - br, 0.25f * R);
        ph = float2(ph.x * rs.y + ph.y * rs.x, ph.y * rs.y - ph.x * rs.x);
    }
    // big lumps, so the column is not a cylinder of equal bubbles
    // (two products of sines with per-tower phases: cheaper than a 3D
    // noise here, and at this scale nobody sees the pattern repeat)
    {
        float3 x = q / (1.2f * R);
        float fk = float(k);
        float lump = sin(1.7f * x.x + 1.3f * fk) * sin(1.3f * x.y + 2.1f * fk)
                   + sin(1.9f * x.z + 0.6f * x.x + 0.7f * fk) * sin(0.8f * x.y - 0.5f * x.z + 2.9f * fk);
        d -= 0.17f * R * lump;
    }
    }
    // skirt: a low wide swell of deck the tower grows out of
    {
        float3 e = float3(q.x, q.y + 0.6f, q.z);
        float3 rad = float3(2.2f * R, 0.6f + 0.15f * R, 2.2f * R);
        float k0 = length(e / rad), k1 = length(e / (rad * rad));
        d = above_smin(d, k0 * (k0 - 1.0f) / k1, 0.3f * R);
    }
    anv = 0.0f; dens = 1.0f;
    if (av.x > 0.0f) {
        float2 lt = ABOVE_WIND * (0.4f * R);   // updraft top
        // overshooting dome above the updraft, and two smaller domes
        d = above_smin(d, length(q - float3(lt.x, H + 0.55f, lt.y)) - 0.68f * R, 0.35f * R);
        float2 s1 = lt + ABOVE_WPERP * (0.55f * R * mir) - ABOVE_WIND * (0.3f * R);
        float2 s2 = lt - ABOVE_WPERP * (0.6f * R * mir) + ABOVE_WIND * (0.25f * R);
        d = above_smin(d, length(q - float3(s1.x, H - 0.05f, s1.y)) - 0.42f * R, 0.3f * R);
        d = above_smin(d, length(q - float3(s2.x, H - 0.20f, s2.y)) - 0.36f * R, 0.3f * R);
        // anvil: an elliptic plan that widens downwind, a domed top and an
        // underside that rises toward the tip, both gently undulating
        float2 r2 = q.xz - lt;
        float along = dot(r2, ABOVE_WIND), across = dot(r2, ABOVE_WPERP);
        float Lh = av.z, th = av.y;
        float u = along / Lh;
        // cheap lower bound first: plan and slab without their noise
        float hw = av.x * (0.5f + 0.7f * smoothstep(-0.1f, 0.9f, u));
        float2 e2 = float2((along - 0.43f * Lh) / (0.55f * Lh), across / hw);
        e2 *= e2;
        float pr0 = sqrt(sqrt(dot(e2, e2)));
        float ax = min(0.55f * Lh, hw);
        float dlb = max((pr0 - 1.1f) * ax, max(q.y - H - 0.6f * th, H - 0.9f * th - q.y) - 0.4f * th);
        if (dlb > 0.75f + av.y) {
            anv = 0.0f; dens = 1.0f;
            return above_smin(d, dlb, 0.8f * th);
        }
        float2 nn = above_noise2x2(float2(along, across) * (1.2f / av.x) + float2(float(k) * 7.1f), seed + 41u);
        float pr = pr0 + 0.1f * nn.x;   // blunt, fan-shaped end
        float pd = (pr - 1.0f) * ax;
        float top = H + th * (0.12f + 0.2f * saturate(1.0f - pr * pr) - 0.12f * smoothstep(0.3f, 1.0f, u)) + 0.1f * th * nn.y;
        float mam = above_domes(float2(along, across) / (0.35f * th), 0.0f, 1, seed + 47u);   // mammatus
        float bot = H - th * (0.75f - 0.55f * smoothstep(-0.1f, 1.0f, u)) + 0.25f * th * nn.x - 0.12f * th * mam * smoothstep(0.1f, 0.5f, u);
        float2 w2 = float2(pd, max(q.y - top, bot - q.y));
        float de = length(max(w2, 0.0f)) + min(max(w2.x, w2.y), 0.0f);
        float own = saturate((d - de) / 0.6f + 0.5f);
        anv = own * smoothstep(0.0f, 0.5f, u);   // the root keeps its billows
        float fib = above_noise2(float2(along / (0.6f * av.x), across / (0.07f * av.x)), seed + 43u);
        float da = smoothstep(1.05f, 0.35f, pr + 0.22f * fib) * (1.0f - 0.6f * smoothstep(0.1f, 1.0f, u));
        dens = mix(1.0f, da, own);
        d = above_smin(d, de, 0.8f * th);
    }
    return d;
}

// Highest altitude tower k can reach (crown, domes, anvil top, skin).
inline float above_tower_top(int k) {
    float4 c = ABOVE_CELLS[k];
    float4 av = ABOVE_ANVILS[k];
    float crown = -0.6f + 1.0f * c.z;
    if (av.x > 0.0f) crown = max(max(crown, 0.55f + 0.72f * c.z), 0.62f * av.y);
    return c.w + crown + 0.35f;
}

// Horizontal bounding circle of tower k (xy = centre, z = radius, km): it
// encloses the skirt and the anvil.
inline float3 above_tower_bound(int k) {
    float4 c = ABOVE_CELLS[k];
    float4 av = ABOVE_ANVILS[k];
    float r1 = 2.7f * c.z + 0.3f;
    if (av.x <= 0.0f) return float3(c.xy, r1);
    float2 c2 = c.xy + ABOVE_WIND * (0.4f * c.z + 0.38f * av.z);
    float r2 = max(0.62f * av.z, 0.95f * length(float2(0.58f * av.z, 1.2f * av.x))) + 0.6f;
    float dd = length(c2 - c.xy);
    if (r1 >= dd + r2) return float3(c.xy, r1);
    if (r2 >= dd + r1) return float3(c2, r2);
    float Rb = 0.5f * (dd + r1 + r2);
    return float3(c.xy + (c2 - c.xy) * ((Rb - r1) / dd), Rb);
}

// Ray / axis-aligned box: (entry, exit) distances, entry > exit on a miss.
inline float2 above_box(float3 o, float3 d, float3 bmin, float3 bmax) {
    float3 inv = 1.0f / select(d, float3(1e-6f), abs(d) < 1e-6f);
    float3 t0 = (bmin - o) * inv, t1 = (bmax - o) * inv;
    float3 tn = min(t0, t1), tf = max(t0, t1);
    return float2(max(max(tn.x, tn.y), tn.z), min(min(tf.x, tf.y), tf.z));
}

// The stretch of a camera ray (flat space, origin ro, direction rd) inside
// tower k's bounding boxes: one around the column, one around the anvil
// (in the wind frame), padded by 1.5 km so everything visible of the tower
// lies within. The planet's curvature is folded into the boxes' heights.
inline float2 above_tower_span(int k, float3 ro, float3 rd) {
    float4 c = ABOVE_CELLS[k];
    float4 av = ABOVE_ANVILS[k];
    float R = c.z, H = c.w;
    const float pad = 1.5f;
    float top = above_tower_top(k) + pad;
    float2 cb = c.xy + ABOVE_WIND * (0.2f * R);
    float hb = 3.0f * R + pad;
    float d0 = max(length(cb) - 1.42f * hb, 0.0f), d1 = length(cb) + 1.42f * hb;
    float k2 = 0.5f / ABOVE_R;
    float2 sp = above_box(ro, rd, float3(cb.x - hb, -4.0f - k2 * d1 * d1, cb.y - hb),
                                  float3(cb.x + hb, top - k2 * d0 * d0, cb.y + hb));
    if (av.x > 0.0f) {
        float2 lt = c.xy + ABOVE_WIND * (0.4f * R);
        float Lh = av.z, th = av.y;
        float2 ca = lt + ABOVE_WIND * (0.38f * Lh);
        float da0 = max(length(ca) - Lh - 2.0f * av.x, 0.0f), da1 = length(ca) + Lh + 2.0f * av.x;
        float2 oxz = ro.xz - lt;
        float3 o = float3(dot(oxz, ABOVE_WIND), ro.y, dot(oxz, ABOVE_WPERP));
        float3 d = float3(dot(rd.xz, ABOVE_WIND), rd.y, dot(rd.xz, ABOVE_WPERP));
        float2 sa = above_box(o, d, float3(-0.32f * Lh - pad, H - 1.4f * th - pad - k2 * da1 * da1, -1.45f * av.x - pad),
                                    float3( 1.08f * Lh + pad, top - k2 * da0 * da0,               1.45f * av.x + pad));
        if (sa.x < sa.y) sp = sp.x < sp.y ? float2(min(sp.x, sa.x), max(sp.y, sa.y)) : sa;
    }
    return sp;
}

// Packed bubbles in 3D, in [0, ~1.1]: the cauliflower of a tower's flanks.
// Same layout rule as above_domes, so the 2x2x2 nearest cells suffice.
inline float above_bubbles(float3 x, float tz, int kmax, uint seed) {
    float3 base = floor(x - 0.5f);
    float best = 0.0f;
    for (int j = 0; j < 8; ++j) {
        int3 c = int3(base) + int3(j & 1, (j >> 1) & 1, j >> 2);
        uint4 h = pcg4d(uint4(as_type<uint3>(c), seed));
        float3 ctr = float3(c) + 0.25f + 0.5f * float3(u01(h.x), u01(h.y), u01(h.z));
        float hw = u01(h.w);
        float k = float(1 + int(h.x & 7u) % kmax);
        float r = (0.55f + 0.2f * hw) * (1.0f + 0.10f * sin(TAU * (k * tz + fract(hw * 5.3f))));
        float q = max(1.0f - length_squared(x - ctr) / (r * r), 0.0f);
        best = max(best, (0.7f + 0.4f * fract(hw * 9.1f)) * q * (2.0f - q));
    }
    return best;
}

// Cauliflower skin on a tower's inside value: two octaves of bubbles pushed
// out of the surface; the finer one fades out with the pixel footprint. The
// lobes are larger low down and tighter toward the crown. `smooth` (0..1)
// calms the skin on anvil tops.
inline float above_tower_skin(float vt, float3 pa, float tz, float foot, float smooth, uint seed, thread float &n1, thread float &n2) {
    float lodw = saturate(1.6f - foot / 0.04f);
    float2 w = above_noise2x2(pa.xz * 0.5f + pa.y * float2(0.41f, -0.33f), seed + 63u);
    float3 pw = pa + float3(w.x, 0.5f * (w.x - w.y), w.y) * 0.2f;   // break the lattice
    float sz = mix(1.15f, 0.75f, saturate(pa.y / 8.0f));
    n1 = above_bubbles(pw / (1.2f * sz), tz, 2, seed + 61u);
    n2 = lodw > 0.0f ? lodw * above_bubbles(pw / (0.45f * sz) + 17.0f, tz, 3, seed + 62u) : 0.0f;
    float rough = 1.0f - 0.75f * smooth;
    return vt + rough * (0.28f * (n1 - 0.45f) + 0.11f * (n2 - 0.45f * lodw));
}

// Max inside value over the towers this ray passes near, with the winning
// tower's anvil weight and density factor.
inline float above_towers(float3 pa, float tz, uint near, uint seed, thread float &anv, thread float &dens) {
    float vt = -1e3f;
    anv = 0.0f; dens = 1.0f;
    for (int k = 0; k < ABOVE_NCELLS; ++k) {
        if (!(near & (1u << k))) continue;
        float3 bnd = above_tower_bound(k);
        if (length(pa.xz - bnd.xy) > bnd.z || pa.y > above_tower_top(k)) continue;
        float a = 0.0f, dn = 1.0f;
        float lbk = above_tower_lb(k, pa);
        float vk = lbk > 1.0f ? -lbk : -above_tower(k, pa, tz, seed, a, dn);
        if (vk > vt) { vt = vk; anv = a; dens = dn; }
    }
    return vt;
}

// Cloud shape with most of its detail, for lighting probes. `dens` is the
// density factor there (anvil rims are thin).
inline float above_vshape(float3 pa, float tz, uint near, float foot, float fineOct, uint seed, thread float &dens, bool skin = true) {
    float v = -1e3f;
    dens = 1.0f;
    if (pa.y < ABOVE_DECK_MAX) {
        float base, lumpy;
        float h = above_deck_coarse(pa.xz, tz, seed, base, lumpy);
        h += lumpy * above_deck_fine(pa.xz, tz, fineOct, seed);
        v = h - pa.y;
    }
    float anv, dn;
    float vt = above_towers(pa, tz, near, seed, anv, dn);
    if (vt > -0.7f) {
        float n1, n2;
        float vs = skin ? above_tower_skin(vt, pa, tz, foot, anv, seed, n1, n2) : vt;
        dens = mix(1.0f, dn, saturate((vs - v) / 0.3f + 0.5f));
        v = above_smax(v, vs, 0.3f);
    }
    return v;
}

inline float above_vshape(float3 pa, float tz, uint near, float foot, float fineOct, uint seed) {
    float dn;
    return above_vshape(pa, tz, near, foot, fineOct, seed, dn);
}

// The full cloud field at one point (what the march integrates).
inline float above_field(float3 pa, float tz, uint near, float foot, uint seed, thread float &ao, thread float &dens) {
    float v = -1e3f;
    ao = 1.0f; dens = 1.0f;
    if (pa.y < ABOVE_DECK_MAX) {
        float base, lumpy;
        float oct = clamp(log2(ABOVE_DOME_S0 / (4.0f * foot)), 1.0f, float(ABOVE_DOME_OCT));
        float h = above_deck_coarse(pa.xz, tz, seed, base, lumpy);
        h += lumpy * above_deck_fine(pa.xz, tz, oct, seed);
        v = h - pa.y;
        ao = saturate((h - base) / (ABOVE_DOME_A0 * 1.3f));
    }
    float anv, dn;
    float vt = above_towers(pa, tz, near, seed, anv, dn);
    if (vt > -0.7f) {
        float n1, n2;
        float vs = above_tower_skin(vt, pa, tz, foot, anv, seed, n1, n2) * (1.0f - 0.5f * anv);
        float aot = saturate(0.3f + 0.9f * n1 + 0.4f * n2 + 0.3f * anv);
        float w = saturate((vs - v) / 0.3f + 0.5f);
        ao = mix(ao, aot, w);
        dens = mix(1.0f, dn, w);
        v = above_smax(v, vs, 0.3f);
    }
    return v;
}

// ---------------------------------------------------------------- lights

constant int ABOVE_NL = 6;
// pos in (x, alt, z); rho is the diffusion falloff (km), vz stretches
// vertical distance (light buried in the deck spreads sideways more easily
// than it climbs through it), G is the gain on the clouds.
struct above_light { float3 pos; float I; float rho; float3 col; float vz; float G; };

// Active lightning at time t, one light per stroke or pulse (at most
// ABOVE_NL). Each stroke has its own channel position, which crawls through
// the cell while it glows; the second stroke of a mature tower runs out
// into the anvil (spider lightning).
inline int above_lights(float t, float L, uint seed, thread above_light *ls) {
    int n = 0;
    float ts = L / 40.0f;
    for (int e = 0; e < ABOVE_NEV && n < ABOVE_NL; ++e) {
        float4 ev = ABOVE_EVENTS[e];
        float dt = since_event(t, ev.x * ts, L);
        if (dt > 6.0f) continue;
        int si = int(ev.y);
        float4 src = ABOVE_SRC[si];
        bool pulse = si >= ABOVE_SRC_PULSE && si < ABOVE_SRC_FAR;
        bool far = si >= ABOVE_SRC_FAR;
        float3 c = float3(src.x, src.z, src.y);
        float r = src.w;
        float tj = 0.0f;
        bool merge = pulse || far;   // soft glows: one light per event, at the strokes' centroid
        float sumE = 0.0f; float3 sumP = float3(0.0f);
        bool deck = si >= ABOVE_SRC_DECK && !far;
        float rho = far ? 14.0f : (pulse ? ABOVE_PULSE_RHO : (deck ? 1.6f : 1.0f + 0.6f * r));
        float vz = deck ? ABOVE_DECK_VZ : 1.0f;
        float G = far ? 1.0f : (pulse ? ABOVE_PULSE_GAIN : (deck ? 3.0f : ABOVE_FLASH_GAIN));
        // seen through a long air path, distant flashes turn warm
        float3 col = mix(ABOVE_FLASH_IN, float3(1.0f, 0.62f, 0.42f), smoothstep(50.0f, 110.0f, length(src.xy)));
        for (int j = 0; j < int(ev.w) && n < ABOVE_NL; ++j) {
            float3 h = rand3(uint(e * 8 + j), 11u, seed);
            float3 hr = rand3(uint(e * 8 + j), 12u, seed) - 0.5f;
            float3 hd = rand3(uint(e * 8 + j), 13u, seed) - 0.5f;
            float rise, decay, amp;
            if (pulse) {
                if (j > 0) tj += 0.4f + 0.5f * h.x;
                amp = 0.6f + 0.4f * h.y;
                rise = 0.15f + 0.15f * h.z; decay = 0.8f + 0.7f * h.y;
            } else {
                if (j > 0) tj += 0.38f + 0.30f * h.x;
                amp = j == 0 ? 1.0f : 0.5f + 0.4f * h.y;
                rise = 0.05f; decay = 0.30f + 0.35f * h.z * ev.z;
            }
            float env = amp * flash_env(dt - tj, rise, decay);
            if (env * ev.z < 2e-3f) continue;
            float vs = si < ABOVE_SRC_DECK ? 0.35f * ABOVE_CELLS[si].w : 0.6f * min(r, 1.5f);
            float3 pw = c + float3(hr.x * r, hr.y * vs, hr.z * r);
            if (si < ABOVE_SRC_DECK && j == 1 && ABOVE_ANVILS[si].x > 0.0f) {
                float4 cl = ABOVE_CELLS[si];
                float4 av = ABOVE_ANVILS[si];
                float2 ap = cl.xy + ABOVE_WIND * (0.4f * cl.z + av.z * (0.25f + 0.25f * h.z)) + ABOVE_WPERP * (hr.x * av.x * 0.6f);
                pw = float3(ap.x, cl.w - 0.35f * av.y, ap.y);
            }
            pw += hd * (pulse ? 0.6f : 1.2f) * max(dt - tj, 0.0f);   // the channel crawls
            if (merge) { sumE += env; sumP += env * pw; continue; }
            ls[n].pos = pw; ls[n].I = env * ev.z; ls[n].rho = rho; ls[n].vz = vz; ls[n].G = G; ls[n].col = col;
            ++n;
        }
        if (merge && sumE * ev.z >= 2e-3f && n < ABOVE_NL) {
            ls[n].pos = sumP / sumE; ls[n].I = sumE * ev.z; ls[n].rho = rho; ls[n].vz = vz; ls[n].G = G; ls[n].col = col;
            ++n;
        }
    }
    return n;
}

// Direction from the camera to a point given in (x, alt, z).
inline float3 above_dir_to(float3 pa, float3 ro) {
    float3 pf = float3(pa.x, pa.y - dot(pa.xz, pa.xz) / (2.0f * ABOVE_R), pa.z);
    return normalize(pf - ro);
}

// ------------------------------------------------------------------- sky

// Haze colour along d: what distant cloud fades into.
inline float3 above_haze(float3 d, float3 ro, float dip, thread above_light *ls, int nl) {
    float s = asin(clamp(d.y, -1.0f, 1.0f)) + dip;
    float3 c = mix(float3(0.024f, 0.034f, 0.042f), float3(0.012f, 0.016f, 0.028f), smoothstep(-0.06f, 0.2f, s));
    float cm = dot(d, ABOVE_MOON);
    c += ABOVE_MOON_COL * 0.012f * exp(-(1.0f - cm) * 4.0f);
    for (int i = 0; i < nl; ++i) {
        float ca = dot(d, above_dir_to(ls[i].pos, ro));
        c += ls[i].col * ls[i].I * (0.025f * exp(-(1.0f - ca) * 40.0f) + 0.04f * exp(-(1.0f - ca) * 250.0f));
    }
    return c;
}

inline float3 above_star_layer(float3 d, float N, float prob, float flux, float sig, float t, float L, uint seed) {
    float3 q = d * N;
    float3 cf = floor(q);
    int3 ci = int3(cf);
    float3 h = hash3(ci, seed);
    if (h.x > prob) return float3(0.0f);
    float3 h2 = hash3(ci, seed + 77u);
    float3 sd = normalize(cf + 0.15f + 0.7f * h2);
    float3 fr = sd * N - cf;
    float m = 4.0f * sig * N;
    if (any(fr < m) || any(fr > 1.0f - m)) return float3(0.0f);
    float a2 = length_squared(d - sd);
    float mag = pow(h.y, 22.0f) + 0.008f * h.y * h.y;   // a few bright, many faint
    float b = flux * mag * exp(-a2 / (2.0f * sig * sig)) / (TAU * sig * sig);
    float k = 3.0f + floor(h.z * 9.0f);
    b *= 1.0f + 0.15f * sin(TAU * k * t / L + 40.0f * h2.x);
    float3 tint = mix(float3(1.0f, 0.80f, 0.62f), float3(0.75f, 0.84f, 1.0f), smoothstep(0.15f, 0.85f, h2.y));
    return b * tint;
}

inline float3 above_sky(float3 d, float3 ro, float dip, float pixA, float t, float L, uint seed, thread above_light *ls, int nl) {
    float s = asin(clamp(d.y, -1.0f, 1.0f)) + dip;   // angle above the deck horizon
    float3 zen = float3(0.0042f, 0.0062f, 0.0175f);
    float3 hor = float3(0.0220f, 0.0310f, 0.0380f);
    float3 c = mix(hor, zen, pow(smoothstep(-0.02f, 0.9f, s), 0.5f));
    c += float3(0.0030f, 0.0055f, 0.0040f) * exp(-abs(s - 0.09f) / 0.05f);   // airglow
    c += float3(0.030f, 0.014f, 0.005f) * exp(-abs(s - 0.004f) / 0.010f);   // towns past the horizon
    float cm = dot(d, ABOVE_MOON);
    float moonGlow = exp(-(1.0f - cm) * 2.5f);   // the moonlit side of the sky
    c += ABOVE_MOON_COL * (0.011f * moonGlow + 0.02f * exp(-(1.0f - cm) * 40.0f));

    // Milky Way: a great circle rising from the right horizon to the upper left,
    // through the middle of the portrait frame; washed out by the moon.
    const float3 gn = float3(-0.7977f, -0.4747f, 0.3720f);
    const float3 gc = float3(0.3073f, 0.1045f, 0.9458f);
    float b = dot(d, gn);
    float band = exp(-(b / 0.16f) * (b / 0.16f)) * 0.6f + exp(-(b / 0.055f) * (b / 0.055f)) * 0.4f;
    float mw = 0.0f, core = 0.0f;
    if (band > 0.01f) {
        core = exp(-(1.0f - dot(d, gc)) * 6.0f);
        float clump = 0.5f + 0.6f * above_fbm3(d * 9.0f, 3, seed + 900u);
        float dust = smoothstep(-0.05f, 0.4f, above_fbm3(d * 14.0f + 3.0f, 3, seed + 901u))
                   * exp(-((b - 0.012f) / 0.035f) * ((b - 0.012f) / 0.035f));
        mw = band * max(clump, 0.0f) * (1.0f + 2.0f * core) * (1.0f - 0.85f * dust);
    }
    float ext = smoothstep(-0.01f, 0.25f, s);   // dimmer through the thick air low down
    c += 0.5f * mw * ext * (1.0f - 0.5f * moonGlow) * mix(float3(0.0100f, 0.0108f, 0.0135f), float3(0.0165f, 0.0138f, 0.0100f), core);

    // Stars, sized in angle (at least ~0.6 render px) with flux conserved;
    // the faint layer is denser along the Milky Way and fades toward the
    // moon; only a handful of bright ones.
    float sig = max(0.0005f, 0.6f * pixA);
    float3 st = above_star_layer(d, 300.0f, 0.30f + 0.6f * band, 2.0e-6f, sig, t, L, seed + 500u) * (1.0f - 0.6f * moonGlow)
              + above_star_layer(d, 80.0f, 0.25f, 1.1e-5f, sig, t, L, seed + 600u);
    c += st * (0.2f + 0.8f * ext) * (1.0f - 0.9f * smoothstep(0.99f, 0.9999f, cm));

    for (int i = 0; i < nl; ++i) {
        float ca = dot(d, above_dir_to(ls[i].pos, ro));
        c += ls[i].col * ls[i].I * (0.03f * exp(-(1.0f - ca) * 40.0f) + 0.05f * exp(-(1.0f - ca) * 250.0f));
    }
    return c;
}

// ------------------------------------------------------------------ scene

// Integral of saturate(v / s + 0.5) dv, for exact density over a segment
// along which the inside value v varies linearly.
inline float above_ramp_int(float v, float s) {
    float x = clamp(v / s + 0.5f, 0.0f, 1.0f);
    return 0.5f * s * x * x + max(v - 0.5f * s, 0.0f);
}

kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float2 p = frame_uv(gid, u.resolution);
    float t = u.time, L = u.loop;
    uint seed = u.seed * 7919u + 13u;

    // Camera: the short side spans ~45 deg; the horizon sits a little below
    // centre so the hero tower has sky to rise into.
    float asp = aspect_of(u.resolution);
    float f = 1.2f * min(asp, 1.0f);
    float hy = mix(ABOVE_HY_P, ABOVE_HY_L, saturate((asp - 0.5625f) / (1.7778f - 0.5625f)));
    float dip = sqrt(2.0f * ABOVE_CAM_ALT / ABOVE_R);
    float pitch = -dip - atan(hy / f);
    float3 dc = normalize(float3(p.x, p.y, f));
    float cp = cos(pitch), sp = sin(pitch);
    float3 rd = float3(dc.x, dc.y * cp + dc.z * sp, dc.z * cp - dc.y * sp);
    float pixA = 1.0f / (u.resolution.y * f);

    above_light ls[ABOVE_NL];
    int nl = above_lights(t, L, seed, ls);
    float tz = wrap_time(t, L) / L;

    // The camera floats on a slow ellipse once per loop (plus a gentle bob):
    // near turrets drift past the far towers, the stars stay put.
    float ca = TAU * tz;
    float3 ro = float3(ABOVE_FLOAT * cos(ca), ABOVE_CAM_ALT + 0.04f * sin(2.0f * ca), 0.5f * ABOVE_FLOAT * sin(ca));

    // Towers this ray passes near (horizontal closest approach).
    uint near = 0u;
    float2 dh2 = normalize(rd.xz);
    for (int k = 0; k < ABOVE_NCELLS; ++k) {
        float3 bnd = above_tower_bound(k);
        float2 c = bnd.xy - ro.xz;
        if (length(c - dh2 * max(dot(c, dh2), 0.0f)) < bnd.z) near |= 1u << k;
    }
    // where along this ray each tower can matter (the march skips the rest)
    float2 span[ABOVE_NCELLS];
    for (int k = 0; k < ABOVE_NCELLS; ++k) span[k] = (near & (1u << k)) ? above_tower_span(k, ro, rd) : float2(1e9f, -1.0f);

    float cosMoon = dot(rd, ABOVE_MOON);
    const float g = 0.55f;
    float hg = (1.0f - g * g) / pow(1.0f + g * g - 2.0f * g * cosMoon, 1.5f);
    float phase = 0.45f + 0.55f * 0.3f * hg;

    float3 acc = float3(0.0f), accF = float3(0.0f);
    float T = 1.0f;
    float jit = hash1(int2(gid), seed + 5u);
    float tr = 0.3f + 0.05f * jit, tprev = tr;
    float kc = 1.0f / (2.0f * ABOVE_R);
    float vprev = -1.0f;
    float3 haze = above_haze(rd, ro, dip, ls, nl);
    // Lights that can touch the clouds along this ray (closest approach in
    // the flat camera space, where the ray is straight), packed first.
    uint lmask = 0u;
    for (int k = 0; k < nl; ++k) {
        float3 pf = float3(ls[k].pos.x, ls[k].pos.y - dot(ls[k].pos.xz, ls[k].pos.xz) * kc, ls[k].pos.z) - ro;
        float ca2 = length(pf - rd * max(dot(pf, rd), 0.0f));
        if (ls[k].G * ls[k].I * (1.3f * exp(-ca2 / ls[k].rho) + 0.8f * exp(-ca2 / 0.6f)) > 0.0005f) lmask |= 1u << k;
    }
    float xz2 = dot(rd.xz, rd.xz);
    int nsteps = 0, nfine = 0;
    float moonLam = -1.0f;
    bool skipped = false;
    float aoSurf = 1.0f;
    float tNoSkip = 0.0f;
    bool moonFinal = false;
    float ftr = 1.0f;   // flash transmittance at the surface, weighted over the lights
    for (int i = 0; i < ABOVE_STEPS; ++i) {
        nsteps++;
        float3 pf = ro + rd * tr;
        float3 pa = float3(pf.x, pf.y + dot(pf.xz, pf.xz) * kc, pf.z);   // (x, alt, z)
        float rise = rd.y + 2.0f * kc * (tr * xz2 + dot(ro.xz, rd.xz));
        if (tr > ABOVE_TMAX || (pa.y > ABOVE_TOP && rise > 0.0f)) break;
        float foot = tr * pixA;
        float dt = (0.03f + 0.010f * tr) * ABOVE_DT;

        // towers: distance to their bounds, exact SDF inside them
        float dTow = 1e3f, vtw = -1e3f, anvw = 0.0f, densw = 1.0f;
        for (int k = 0; k < ABOVE_NCELLS; ++k) {
            if (tr > span[k].y) continue;
            if (tr < span[k].x) { dTow = min(dTow, span[k].x - tr); continue; }
            dTow = 0.0f;
            float a = 0.0f, dn = 1.0f;
            float lbk = above_tower_lb(k, pa);
            float vk = lbk > 1.0f ? -lbk : -above_tower(k, pa, tz, seed, a, dn);
            if (vk > vtw) { vtw = vk; anvw = a; densw = dn; }
        }

        // deck: a plane bound above it, the coarse heightfield below
        bool inDeck = pa.y < ABOVE_DECK_MAX;
        if (!inDeck && dTow > 0.0f) {
            if (rise >= 0.0f && dTow > 999.0f) break;          // only sky left
            float toPlane = rise < 0.0f ? (pa.y - ABOVE_DECK_MAX) / -rise : 1e3f;
            float step = max(min(toPlane, dTow), dt);
            tprev = tr; tr += step; vprev = -1.0f; skipped = true;
            continue;
        }
        float base = 0.0f, lumpy = 1.0f, hc = -1e3f;
        if (inDeck) hc = above_deck_coarse(pa.xz, tz, seed, base, lumpy);
        float vb = max(hc + ABOVE_DECK_MARGIN - pa.y, vtw + 0.35f);
        if (vb < 0.0f && tr >= tNoSkip) {
            // heightfield Lipschitz step: the coarse deck rises at most ~0.6 per km
            float step = -vb / (max(-rise, 0.0f) + 0.6f);
            if (vtw > -999.0f) step = min(step, -vb * 0.8f);
            if (dTow > 0.0f) step = min(step, max(dTow, dt));
            step = max(step, dt * 0.5f);
            tprev = tr; tr += step; vprev = vb; skipped = true;
            continue;
        }

        // full detail
        nfine++;
        float oct = clamp(log2(ABOVE_DOME_S0 / (4.0f * foot)), 1.0f, float(ABOVE_DOME_OCT));
        float v = -1e3f, ao = 1.0f, dens = 1.0f;
        if (inDeck) {
            float hf = hc + lumpy * above_deck_fine(pa.xz, tz, oct, seed);
            v = hf - pa.y;
            ao = saturate((hf - base) / (ABOVE_DOME_A0 * 1.3f));
        }
        if (vtw > -0.7f) {
            float n1, n2;
            float vt = above_tower_skin(vtw, pa, tz, foot, anvw, seed, n1, n2);
            vt *= 1.0f - 0.5f * anvw;
            float aot = saturate(0.3f + 0.9f * n1 + 0.4f * n2 + 0.3f * anvw);
            float w = saturate((vt - v) / 0.3f + 0.5f);
            ao = mix(ao, aot, w);
            dens = mix(1.0f, densw, w);
            v = above_smax(v, vt, 0.3f);
        }

        float soft = ABOVE_SOFT + 1.2f * foot;
        // A skip that landed inside cloud: go back and march that stretch
        // finely, or how much it absorbs would depend on where steps fall.
        if (skipped && v > -0.5f * soft && tr - tprev > 1.5f * dt) {
            tNoSkip = tr; tr = tprev; skipped = false; vprev = 1e9f;
            continue;
        }
        skipped = false;
        if (vprev > 1e8f) { vprev = v; tprev = tr; }   // first sample after a rewind
        float seg = tr - tprev;
        float vlast = vprev;   // inside value at the segment's start
        vprev = min(vprev, v);
        float vmid = 0.5f * (v + vprev);
        float rho = abs(v - vprev) > 1e-4f
                  ? (above_ramp_int(v, soft) - above_ramp_int(vprev, soft)) / (v - vprev)
                  : saturate(v / soft + 0.5f);
        vprev = v;

        if (rho <= 0.001f) { moonLam = -1.0f; moonFinal = false; }
        if (rho > 0.001f) {
            float vin = max(vmid, 0.0f) * dens;   // depth into the cloud (thin anvil: light gets in)
            // Moon: shape probes toward it, taken where the ray crosses the
            // cloud surface (v = 0, interpolated, so it moves continuously
            // from pixel to pixel) and reused through the thin skin we see.
            // For a distance-like field, (v(p) - v(p + m d)) / d is about n.m.
            // A faint fringe gets a provisional probe at its own position.
            if (!moonFinal && (moonLam < 0.0f || v >= 0.0f)) {
                float3 pc = pa;
                if (v >= 0.0f) {
                    // Find the crossing inside this segment by regula falsi
                    // (the field is close to a distance, so the secant lands
                    // near the surface and varies smoothly from pixel to
                    // pixel); the last sample also gives the occlusion.
                    float lo = tprev, hi = tr, vlo = min(vlast, -1e-3f), vhi = max(v, 1e-3f);
                    for (int b = 0; b < ABOVE_BISECT; ++b) {
                        float tm = mix(lo, hi, clamp(-vlo / (vhi - vlo), 0.1f, 0.9f));
                        float3 pfm = ro + rd * tm;
                        float3 pam = float3(pfm.x, pfm.y + dot(pfm.xz, pfm.xz) * kc, pfm.z);
                        float dnb;
                        float vm = above_field(pam, tz, near, foot, seed, aoSurf, dnb);
                        if (vm >= 0.0f) { hi = tm; vhi = max(vm, 1e-3f); } else { lo = tm; vlo = min(vm, -1e-3f); }
                    }
                    float3 pfc = ro + rd * mix(lo, hi, saturate(-vlo / (vhi - vlo)));
                    pc = float3(pfc.x, pfc.y + dot(pfc.xz, pfc.xz) * kc, pfc.z);
                }
                // At the surface use the full field (its centre sample also
                // gives the surface occlusion); fringe probes use a smoother
                // shape, since they land wherever the step does and fine
                // detail would turn that into streaks.
                // Aloft the normal comes from a wider probe, so the big
                // lobes of a tower carry the shading, not every small bubble.
                float aloft = smoothstep(1.0f, 2.5f, pc.y);
                float mo = mix(0.25f, 0.55f, aloft);
                float v0, v1, aod, dnd;
                if (v >= 0.0f) {
                    v0 = 0.0f;   // pc is on the surface
                    v1 = above_field(pc + ABOVE_MOON * mo, tz, near, foot, seed, aod, dnd);
                } else {
                    v0 = above_vshape(pc, tz, near, 1.0f, 1.0f, seed);
                    v1 = above_vshape(pc + ABOVE_MOON * mo, tz, near, 1.0f, 1.0f, seed);
                }
                float dn2;
                float v2 = above_vshape(pc + ABOVE_MOON * 1.2f, tz, near, 1.0f, 1.0f, seed, dn2, false);
                // wrapped: light scattered inside a cloud reaches past the
                // terminator; aloft, light bounced off the deck and the cell
                // itself keeps shadows from going black
                moonLam = saturate(((v0 - v1) / mo + 0.3f) / 1.3f)
                        * max(exp(-max(v2, 0.0f) * 2.0f * dn2), 0.3f * aloft);
                // Lightning: how much cloud lies between this surface point
                // and each channel, from two probes toward it. Light leaks
                // out where the cloud is thin (rims, gaps between billows,
                // the anvil) and the thick lobes stand dark against it.
                float fw = 1e-4f, fs = 1e-4f;
                for (int k = 0; k < nl; ++k) {
                    if (!(lmask & (1u << k))) continue;
                    float3 dv = ls[k].pos - pc;
                    float dl = length(dv);
                    float w = ls[k].G * ls[k].I * exp(-dl / ls[k].rho);
                    if (w < 0.02f) continue;
                    float3 dir = dv / max(dl, 1e-3f);
                    float da1, da2;
                    float o1 = saturate(above_vshape(pc + dir * min(0.3f, 0.3f * dl), tz, near, 1.0f, 1.0f, seed, da1, false) / 0.2f + 0.5f) * da1;
                    float o2 = saturate(above_vshape(pc + dir * min(1.0f, 0.7f * dl), tz, near, 1.0f, 1.0f, seed, da2, false) / 0.2f + 0.5f) * da2;
                    float tau = ABOVE_FLASH_TAU * (0.4f * o1 + 0.6f * o2);
                    fw += w * (0.65f * exp(-0.6f * tau) + 0.35f * exp(-0.15f * tau));
                    fs += w;
                }
                ftr = fw / fs;
                moonFinal = v >= 0.0f;
            }
            if (moonFinal) ao = aoSurf;   // surface shading, continuous across pixels
            float tm = moonLam * exp(-vin * 6.0f);
            float3 S = ABOVE_MOON_COL * 0.34f * phase * tm * (0.3f + 0.7f * ao);
            S += float3(0.0036f, 0.0058f, 0.0150f) * (1.0f + 1.2f * smoothstep(1.0f, 2.5f, pa.y)) * exp(-vin * 3.0f) * (0.15f + 0.85f * ao);
            float fogL = mix(ABOVE_FOG_DECK, 60.0f, smoothstep(0.8f, 4.0f, pa.y));   // thin air above the deck
            float fog = 1.0f - exp(-tr / fogL);
            S = mix(S, haze, fog);
            // In-cloud lightning, after the haze: it shines through it.
            float3 SF = float3(0.0f);
            for (int k = 0; k < nl; ++k) {
                if (!(lmask & (1u << k))) continue;
                float dl = length((pa - ls[k].pos) * float3(1.0f, ls[k].vz, 1.0f));
                float radial = 1.3f * exp(-dl / ls[k].rho) + 0.8f * exp(-dl / 0.6f);
                float3 lcol = ls[k].col * mix(float3(1.0f), ABOVE_FLASH_OUT / ABOVE_FLASH_IN, saturate(dl / (2.5f * ls[k].rho)));
                SF += lcol * (ls[k].G * ls[k].I) * radial;
            }
            SF *= ftr * mix(0.45f + 0.75f * (1.0f - ao), 0.8f, anvw) * exp(-tr / 60.0f) * exp(-vin * 2.0f);
            float al = 1.0f - exp(-ABOVE_SIGMA * rho * dens * seg);
            acc += T * al * S;
            accF += T * al * SF;
            T *= 1.0f - al;
            if (T < 0.01f) break;
        }
        tprev = tr;
        float din = (0.04f + 0.015f * tr) * (0.7f + 0.6f * jit);
        // resolve the visible skin; thin anvil cloud can take longer steps
        if (T > 0.25f) din = min(din, 0.9f / (ABOVE_SIGMA * max(dens, 0.2f)) + 2.0f * foot);
        // near the surface (thin fringe, grazing rays) step finer, so the soft
        // edge is sampled the same way in neighbouring pixels
        if (abs(v) < soft && T > 0.25f && pa.y > 1.2f) din = min(din, max(ABOVE_FRINGE * soft, 1.5f * foot));
        tr += v < -soft ? max(-v * 0.8f, min(dt, din)) : din;
    }

    // Flash radiance is rolled off softly so a lit cell never clips to a flat
    // white blob: its billows keep their modelling at the peak.
    float lf = luma709(accF);
    if (lf > 1e-5f) accF *= ABOVE_FLASH_CAP * (1.0f - exp(-lf / ABOVE_FLASH_CAP)) / lf;
    float3 col = acc + accF;
    if (T > 0.01f) col += T * above_sky(rd, ro, dip, pixA, t, L, seed, ls, nl);

#ifdef ABOVE_DEBUG_STEPS
    out.write(float4(float(nsteps) / 110.0f, float(nfine) / 60.0f, 0.0f, 1.0f), gid); return;
#endif
    col *= ABOVE_EXPOSURE;
    float3 disp = srgb_encode(tonemap_filmic(col));
    // grade: shadows lean indigo, highlights stay silver
    float l = dot(disp, float3(0.2126f, 0.7152f, 0.0722f));
    disp = mix(disp * float3(0.90f, 0.95f, 1.14f), disp, smoothstep(0.05f, 0.45f, l));
    disp = saturate(mix(float3(l), disp, 1.12f));

    // Film grain: monochrome, about one output pixel at 1080p (sized in height
    // units so 720p matches), strongest in the mid tones, a new pattern every
    // frame and exactly periodic over the loop.
    float2 gp = floor((p + 0.5f) * ABOVE_GRAIN_RES);
    uint fi = uint(round(wrap_time(t, L) * u.fps)) % uint(max(round(L * u.fps), 1.0f));
    uint3 gh = pcg3d(uint3(as_type<uint2>(int2(gp)), fi * 7919u + seed));
    float gn = u01(gh.x) + u01(gh.y) - 1.0f;   // triangular, [-1, 1]
    float gamp = ABOVE_GRAIN * (0.35f + 0.65f * smoothstep(0.03f, 0.3f, l)) * (1.0f - 0.6f * l);
    disp = saturate(disp + gn * gamp);
    out.write(float4(disp, 1.0f), gid);
}
