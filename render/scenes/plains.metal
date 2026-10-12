// plains.metal: "Distant Storm". A lone supercell on the horizon of a night
// prairie, lit from within by intra-cloud lightning, with cloud-to-ground
// bolts under its base and from its anvil, rain shafts hanging from the flat
// base, stars in the clear sky and grass swaying in the foreground.
//
// The storm is a raymarched volume. Its macro form is a hand-placed set of
// primitives: a slanted cone for the updraft tower (broad at the base), a
// broad forward flank the rain falls from, a skirt spreading into a flat
// anvil lid that is the widest part, an overshooting top, a low flanking
// ridge, and a base height field with a lowered wall cloud and tail cloud.
// Billows come from turbulence noise displacing that form; the base is cut
// flat after the displacement. The camera stands on the plain a few
// storm-heights away, so base and anvil are seen slightly from below.
// Lighting: the moon from the left, sky and town-glow ambient, and up to two
// lightning channels inside the cloud with short shadow rays. The march
// finds the first surface by bisection and shades from a fixed depth under
// it, so its per-pixel jitter leaves no static hatch.
//
// Units: "cloud units" put the storm base at y = 0 and the anvil top near
// y = 1. Screen position = anchor + scale * cloud.xy, chosen per orientation.
// Lightning is scheduled with since_event, everything else that moves is
// either exactly periodic (rain, grass, stars) or a slow drift that the
// harness loop crossfade hides (cloud billows).

#ifndef PLAINS_EXPOSURE
#define PLAINS_EXPOSURE 1.0f
#endif

constant float  PLAINS_STEP  = 0.035f;   // primary march step, cloud units
constant int    PLAINS_OCT_N = 5;        // detail octaves at the visible surface
constant float  PLAINS_AMAX  = 0.17f;    // strict bound on outward noise displacement
constant float  PLAINS_FLASH = 0.028f;   // lightning light power
constant float  PLAINS_DIST  = 3.4f;     // camera distance to the storm, cloud units
constant float3 PLAINS_MOON_DIR = float3(-0.80f, 0.44f, -0.12f);

// ------------------------------------------------------------------ layout

struct PlainsLayout {
    float  horizon;   // screen y of the horizon
    float2 anchor;    // screen position of the cloud origin (base under the tower)
    float  scale;     // screen height units per cloud unit
    float  a;         // 0 portrait .. 1 landscape
};

static PlainsLayout plains_layout(float2 res) {
    PlainsLayout l;
    l.a = saturate((res.x / res.y - 0.5625f) / (1.7778f - 0.5625f));
    l.horizon = mix(-0.25f, -0.245f, l.a);
    l.anchor  = mix(float2(-0.06f, -0.165f), float2(-0.30f, -0.18f), l.a);
    l.scale   = mix(0.38f, 0.52f, l.a);
    return l;
}

// ------------------------------------------------------------------ noise
// Cheap 3D gradient noise: one pcg per corner, gradient taken from the hash
// bits (random vector in the cube), no trig.

static inline float plains_gd(int3 c, float3 f, uint seed) {
    uint h = pcg_hash(uint(c.x) * 0x8da6b343u ^ uint(c.y) * 0xd8163841u ^ uint(c.z) * 0xcb1ab31fu ^ seed);
    float3 g = float3(float(h & 1023u), float((h >> 10) & 1023u), float((h >> 20) & 1023u)) * (2.0f / 1023.0f) - 1.0f;
    return dot(g, f);
}

static inline float plains_gn3(float3 p, uint seed) {
    float3 fl = floor(p); int3 i = int3(fl); float3 f = p - fl;
    float3 w = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float a = plains_gd(i,                 f,                   seed);
    float b = plains_gd(i + int3(1, 0, 0), f - float3(1, 0, 0), seed);
    float c = plains_gd(i + int3(0, 1, 0), f - float3(0, 1, 0), seed);
    float d = plains_gd(i + int3(1, 1, 0), f - float3(1, 1, 0), seed);
    float e = plains_gd(i + int3(0, 0, 1), f - float3(0, 0, 1), seed);
    float g = plains_gd(i + int3(1, 0, 1), f - float3(1, 0, 1), seed);
    float h = plains_gd(i + int3(0, 1, 1), f - float3(0, 1, 1), seed);
    float k = plains_gd(i + int3(1, 1, 1), f - float3(1, 1, 1), seed);
    return mix(mix(mix(a, b, w.x), mix(c, d, w.x), w.y),
               mix(mix(e, g, w.x), mix(h, k, w.x), w.y), w.z);
}

static inline float plains_gn2(float2 p, uint seed) {
    float2 fl = floor(p); int2 i = int2(fl); float2 f = p - fl;
    float2 w = f * f * f * (f * (f * 6.0f - 15.0f) + 10.0f);
    float v[4];
    for (int k = 0; k < 4; ++k) {
        int2 o = int2(k & 1, k >> 1);
        uint h = pcg_hash(uint(i.x + o.x) * 0x8da6b343u ^ uint(i.y + o.y) * 0xd8163841u ^ seed);
        float2 g = float2(float(h & 1023u), float((h >> 10) & 1023u)) * (2.0f / 1023.0f) - 1.0f;
        v[k] = dot(g, f - float2(o));
    }
    return 1.4f * mix(mix(v[0], v[1], w.x), mix(v[2], v[3], w.x), w.y);
}

// Octave step: rotation about an arbitrary axis times lacunarity 2.03.
constant float3x3 PLAINS_OCT = float3x3(float3( 1.08447f,  1.05932f, -1.35007f),
                                        float3(-0.59640f,  1.73016f,  0.87849f),
                                        float3( 1.60908f, -0.07267f,  1.23551f));

// ------------------------------------------------------------------ shape

static inline float plains_smin(float a, float b, float k) {
    float h = saturate(0.5f + 0.5f * (b - a) / k);
    return mix(b, a, h) - k * h * (1.0f - h);
}

static inline float plains_capsule(float3 p, float3 a, float3 b) {
    float3 pa = p - a, ba = b - a;
    return length(pa - ba * saturate(dot(pa, ba) / dot(ba, ba)));
}

static inline float plains_box(float3 p, float3 c, float3 h, float r) {
    float3 q = abs(p - c) - h;
    return length(max(q, 0.0f)) + min(max(q.x, max(q.y, q.z)), 0.0f) - r;
}

// Billow turrets set into the surface of the tower and the forward body (xyz
// centre, radius). Each sticks out only ~0.05 past the cone, so they read as
// cauliflower relief on the moonlit flank, not as separate puffs.
constant int PLAINS_NLOBE = 6;
constant float4 PLAINS_LOBE[] = {
    float4(-0.22f, 0.24f, -0.10f, 0.13f),
    float4(-0.16f, 0.46f, -0.09f, 0.11f),
    float4(-0.09f, 0.66f, -0.07f, 0.10f),
    float4( 0.30f, 0.44f, -0.14f, 0.12f),
    float4( 0.58f, 0.26f, -0.10f, 0.11f),
    float4( 0.20f, 0.20f, -0.22f, 0.12f),
};
// Stepped turrets along the flanking line, shrinking away from the tower.
constant int PLAINS_NFLANK = 5;
constant float4 PLAINS_FLANK[] = {
    float4(-0.44f, 0.15f, -0.10f, 0.11f),
    float4(-0.64f, 0.11f, -0.12f, 0.090f),
    float4(-0.84f, 0.08f, -0.14f, 0.075f),
    float4(-1.04f, 0.06f, -0.15f, 0.060f),
    float4(-1.24f, 0.04f, -0.16f, 0.048f),
};

// Height of the cloud base: flat with faint rolls, a touch higher under the
// forward flank, lowered under the updraft into a wall cloud with a short
// tail cloud reaching toward the rain. Its slopes stay under ~2, so
// (base - y) * 0.45 is a safe distance bound.
static inline float plains_base(float x, float z) {
    float b = 0.012f * saturate((x - 0.25f) * 2.5f);
    float w = length(float2((x + 0.07f) / 0.13f, (z + 0.06f) / 0.12f));
    b -= 0.058f * smoothstep(1.0f, 0.72f, w);
    float tail = smoothstep(0.0f, 0.08f, x) * smoothstep(0.34f, 0.16f, x) * smoothstep(0.05f, 0.02f, abs(z + 0.08f));
    return b - 0.018f * tail;
}

// Distance to an ellipsoid (centre o, radii r), first-order: the implicit
// |q| - 1 divided by its gradient length, which stays close off-axis where
// (|q| - 1) * min(r) badly underestimates.
static inline float plains_ellipsoid(float3 c, float3 o, float3 r) {
    float3 q = (c - o) / r;
    float k = length(q);
    return (k - 1.0f) * k / max(length(q / r), 1e-4f);
}

struct PlainsShape { float sd; float anvil; float base; };

// Signed distance-ish to the storm's macro form (negative inside), plus the
// anvil weight that switches the detail pass to a smooth, streaky texture,
// and the base height under the point.
static PlainsShape plains_macro(float3 c) {
    PlainsShape s;
    // Updraft tower: a slanted cone, broad at the base and leaning into the
    // anvil. Radius 0.44 at y = -0.15 down to 0.22 at 0.85.
    float h = saturate((c.y + 0.15f) / 1.0f);
    float r = 0.28f + 0.17f * (1.0f - h) * (1.0f - 0.35f * h);
    float d = (length(float2(c.x - (-0.02f + 0.14f * h), c.z)) - r) * 0.92f;
    d = max(d, max(c.y - 0.90f, -0.20f - c.y));
    // Forward flank: the broad lower mass the rain falls from.
    d = plains_smin(d, plains_ellipsoid(c, float3(0.42f, 0.18f, 0.04f), float3(0.46f, 0.30f, 0.34f)), 0.12f);
    if (d < 0.2f) {
        for (int i = 0; i < PLAINS_NLOBE; ++i) {
            // smin(d, x, k) == d once x >= d + k: skip far lobes cheaply
            float4 b = PLAINS_LOBE[i];
            float3 q = c - b.xyz;
            float reach = b.w + d + 0.07f;
            if (dot(q, q) > reach * reach) continue;
            d = plains_smin(d, length(q) - b.w, 0.07f);
        }
    }
    // Skirt where the tower spreads into the anvil, and the overshooting top.
    float dFlare = plains_ellipsoid(c, float3(0.14f, 0.80f, 0.02f), float3(0.55f, 0.10f, 0.40f));
    d = plains_smin(d, dFlare, 0.10f);
    float dTop = plains_ellipsoid(c, float3(0.08f, 0.955f, 0.0f), float3(0.17f, 0.10f, 0.17f));
    d = plains_smin(d, dTop, 0.04f);

    // Anvil: a flat lid at the tropopause fanning out downwind (+x) far past
    // the frame, with a short rounded upwind edge, a dark underside rising
    // slowly downwind and mammatus pouches under its middle.
    if (c.y > 0.6f) {
        float spread = 0.24f + 0.42f * saturate((c.x + 0.4f) / 2.4f);
        float2 er = float2(1.68f, spread), e = float2(c.x - 1.10f, c.z) / er;
        float ke = length(e);
        float dxz = (ke - 1.0f) * ke / max(length(e / er), 1e-4f) * 0.8f;   // spread varies with x
        float ytop = 0.975f - 0.006f * (c.x - 0.1f) * (c.x - 0.1f);
        float ybot = 0.835f + 0.06f * saturate(c.x / 2.0f) + 0.05f * saturate(-c.x / 0.45f);
        // undulation and mammatus only matter near the anvil's footprint
        if (dxz < 0.2f && c.y < 0.93f) {
            ybot += 0.02f * plains_gn2(c.xz * float2(2.6f, 3.4f) + 9.0f, 72u);
            float mam = max(plains_gn2(c.xz * 11.0f, 73u), 0.0f);
            ybot -= 0.04f * mam * mam * smoothstep(0.30f, 0.60f, c.x) * smoothstep(1.6f, 1.0f, c.x);
        }
        float dAnvil = max(dxz, max(ybot - c.y, c.y - ytop));
        d = plains_smin(d, dAnvil, 0.06f);
    }

    // Flanking line: one low continuous ridge with stepped turrets, shrinking
    // to the left until it melts into the horizon haze.
    if (c.x < -0.15f && c.y < 0.40f) {
        float dr = plains_capsule(c, float3(-1.60f, 0.0f, -0.18f), float3(-0.30f, 0.02f, -0.08f))
                 - mix(0.035f, 0.13f, saturate((c.x + 1.6f) / 1.3f));
        d = plains_smin(d, dr, 0.08f);
        for (int i = 0; i < PLAINS_NFLANK; ++i) {
            float4 b = PLAINS_FLANK[i];
            float3 q = c - b.xyz;
            float reach = b.w + d + 0.10f;
            if (dot(q, q) > reach * reach) continue;
            d = plains_smin(d, length(q) - b.w, 0.10f);
        }
    }

    // Flat base (re-applied exactly after the detail displacement).
    s.base = plains_base(c.x, c.z);
    if (c.y < 0.2f) s.base += 0.006f * plains_gn2(c.xz * 5.0f, 74u);   // faint rolls
    s.sd = max(d, (s.base - c.y) * 0.45f);
    float3 ot = c - float3(0.08f, 0.955f, 0.0f);
    // anvil texture above 0.76, and also lower down once clear of the
    // tower (the underside of the outflow), never on the overshooting top
    float rho = length(float2(c.x - 0.10f, c.z));
    s.anvil = max(smoothstep(0.76f, 0.88f, c.y), smoothstep(0.60f, 0.78f, c.y) * smoothstep(0.34f, 0.50f, rho))
            * (1.0f - exp(-dot(ot, ot) * 40.0f));
    return s;
}

// Sum of detail octaves (displacement, cloud units). With `early` it stops
// as soon as the remaining octaves cannot change whether sd0 - disp is
// outside or fully inside; `empty` reports the first case.
static float plains_detail(float3 q, float amp, float smooth, int oct, uint seed, float sd0, float edge, bool early, thread bool& empty) {
    float rem = amp * 2.6f, disp = 0.0f;
    empty = false;
    for (int k = 0; k < oct; ++k) {
        // |n| gives round lobes with sharp creases (cumulus); plain n is
        // softer. Softly saturated below 0.75 so PLAINS_AMAX is a strict
        // bound without the flat facets a hard clamp leaves.
        float n = plains_gn3(q, seed + uint(k) * 0x9E3779B9u);
        n *= rsqrt(1.0f + n * n * 1.7778f);
        // only the big octaves get creases; fine ones would pit the surface
        disp += amp * mix(abs(n) * 2.0f - 0.5f, n, k >= 3 ? 1.0f : smooth);
        rem -= amp;
        if (early) {
            float sdp = sd0 - disp;
            if (sdp - rem > 0.0f) { empty = true; return disp + rem; }
            if (sdp + rem < -edge) break;
        }
        amp *= k < 2 ? 0.62f : 0.5f;
        q = PLAINS_OCT * q;
    }
    return disp;
}

// Extinction (per cloud unit) at c given its macro shape; `depth` returns how
// far inside the detailed surface the point is (for ambient occlusion). When
// the point is provably outside, -depth is a lower bound on the clearance.
static float plains_density(float3 c, PlainsShape s, float t, int oct, uint seed, thread float& depth) {
    depth = -s.sd;
    if (s.sd > PLAINS_AMAX) return 0.0f;
    // nothing hangs below the base (the cut is applied after the billows)
    if (c.y < s.base) { depth = min(depth, c.y - s.base); return 0.0f; }

    float wA = s.anvil;
    float far = saturate((c.x - 0.6f) / 1.6f);          // downwind anvil gets wispy
    float edge  = mix(0.006f, mix(0.02f, 0.07f, far), wA);
    float sigma = mix(110.0f, mix(70.0f, 14.0f, far), wA);
    bool empty;
    float disp;
    // Billows rise slowly; anvil detail is streaky along the outflow and
    // drifts downwind.
    float3 qt = (c + float3(-0.0005f, -0.0016f, 0.0006f) * t) * 3.6f;
    float3 qa = float3((c.x - 0.0012f * t) * 3.4f, c.y * 11.0f, c.z * 4.0f);
    if (wA < 0.01f) {
        disp = plains_detail(qt, 0.075f, 0.0f, oct, seed, s.sd, edge, true, empty);
        if (empty) { depth = -(s.sd - disp); return 0.0f; }
    } else if (wA > 0.99f) {
        disp = plains_detail(qa, 0.045f, 1.0f, oct, seed, s.sd, edge, true, empty);
        if (empty) { depth = -(s.sd - disp); return 0.0f; }
    } else {
        float dT = plains_detail(qt, 0.075f, 0.0f, oct, seed, 0.0f, edge, false, empty);
        float dA = plains_detail(qa, 0.045f, 1.0f, oct, seed, 0.0f, edge, false, empty);
        disp = mix(dT, dA, wA);
    }
    // the base is cut flat after the billows, so they cannot hang below it,
    // and the billows calm down toward it so its edge stays nearly straight
    disp *= 0.25f + 0.75f * smoothstep(0.0f, 0.14f, c.y - s.base);
    float sd = max(s.sd - disp, s.base - c.y);
    depth = -sd;
    return sigma * smoothstep(0.0f, edge, -sd);
}

static inline float plains_density_at(float3 c, float t, int oct, uint seed) {
    float dd;
    return plains_density(c, plains_macro(c), t, oct, seed, dd);
}

// Density from the macro form alone, for far shadow samples.
static inline float plains_density_coarse(float3 c) {
    PlainsShape s = plains_macro(c);
    return mix(80.0f, 40.0f, s.anvil) * smoothstep(-0.02f, 0.08f, -s.sd);
}

// ------------------------------------------------------------------ lightning
// Schedule for a 40 s loop (scaled to u.loop). kind 0 = in-cloud flash around
// pos, kind 1 = cloud-to-ground bolt whose channel leaves the base at pos.xy,
// kind 2 = a bolt from the anvil that arcs down in front of the forward
// flank (drawn over the cloud). Ground strokes: one at the edge of the rain
// core, one under the left end of the base, one through the rain shafts, and
// the anvil bolt. In-cloud flashes wander over tower, anvil and rain core.

constant int PLAINS_NEV = 15;
constant float  PLAINS_EV_T[]    = { 1.3f, 3.6f, 6.6f, 9.8f, 12.6f, 15.6f, 18.4f, 21.4f, 24.4f, 27.4f, 30.4f, 32.6f, 34.8f, 37.4f, 39.3f };
constant int    PLAINS_EV_KIND[] = { 0,    1,    0,    0,    0,     1,     0,     0,     0,     2,     0,     0,     0,     1,     0 };
constant float  PLAINS_EV_STR[]  = { 0.30f, 1.0f, 0.40f, 0.85f, 0.30f, 0.60f, 0.35f, 0.75f, 0.25f, 0.55f, 0.40f, 0.30f, 0.70f, 0.60f, 0.25f };
// ground strokes: where the foot lands relative to the top (cloud x units)
constant float  PLAINS_EV_FOOT[] = { 0.0f, 0.02f, 0.0f, 0.0f, 0.0f, -0.02f, 0.0f, 0.0f, 0.0f, -0.03f, 0.0f, 0.0f, 0.0f, 0.05f, 0.0f };
constant int    PLAINS_EV_N[]    = { 2,    3,    2,    2,    1,     2,     2,     3,     1,     2,     2,     1,     2,     2,     1 };
constant float  PLAINS_EV_GAP[]  = { 0.45f, 0.42f, 0.50f, 0.40f, 0.5f, 0.55f, 0.40f, 0.38f, 0.5f, 0.45f, 0.42f, 0.5f, 0.45f, 0.40f, 0.5f };
constant float  PLAINS_EV_DECAY[]= { 0.45f, 0.35f, 0.55f, 0.50f, 0.50f, 0.32f, 0.50f, 0.45f, 0.60f, 0.32f, 0.45f, 0.50f, 0.50f, 0.32f, 0.55f };
constant float3 PLAINS_EV_POS[]  = {
    float3(-0.08f, 0.48f, 0.16f), float3( 0.17f, 0.02f, 0.02f), float3( 0.85f, 0.86f, 0.10f),
    float3( 0.06f, 0.60f, 0.12f), float3(-0.40f, 0.20f, 0.02f), float3(-0.36f, 0.03f, 0.00f),
    float3( 0.55f, 0.30f, 0.10f), float3( 0.12f, 0.30f, 0.14f), float3( 1.10f, 0.88f, 0.10f),
    float3( 0.47f, 0.86f, -0.10f), float3( 0.10f, 0.88f, 0.08f), float3(-0.18f, 0.40f, 0.16f),
    float3( 0.18f, 0.52f, 0.12f), float3( 0.47f, 0.03f, 0.00f), float3( 0.40f, 0.20f, 0.10f),
};

// Seconds since event k (0..L), the same in both crossfade layers.
static inline float plains_since(int k, float t, float L) {
    return since_event(t, PLAINS_EV_T[k] * (L / 40.0f), L);
}

// Relative brightness of return stroke j.
static inline float plains_stroke_amp(int j) { return j == 0 ? 1.0f : (j == 1 ? 0.68f : 0.46f); }

// A lightning channel inside the cloud: segment pos +- axis, power col.
struct PlainsLight { float3 pos; float3 axis; float3 col; };

// The three brightest lightning sources right now (cloud space, linear rgb).
// Returns how many are lit; `total` sums all active strokes.
static int plains_lights(float t, float L, uint seed, thread PlainsLight* lt, thread float& total) {
    for (int i = 0; i < 3; ++i) { lt[i].pos = float3(0.0f); lt[i].axis = float3(0.0f, 0.01f, 0.0f); lt[i].col = float3(0.0f); }
    float best[3] = { 0.0f, 0.0f, 0.0f };
    total = 0.0f;
    for (int k = 0; k < PLAINS_NEV; ++k) {
        float dt = plains_since(k, t, L);
        if (dt > 3.0f) continue;
        bool cg = PLAINS_EV_KIND[k] != 0;
        for (int j = 0; j < PLAINS_EV_N[k]; ++j) {
            float e = PLAINS_EV_STR[k] * plains_stroke_amp(j) * flash_env(dt - float(j) * PLAINS_EV_GAP[k], 0.05f, PLAINS_EV_DECAY[k]);
            if (e < 1e-3f) continue;
            total += e;
            int slot = -1;
            for (int s = 0; s < 3; ++s) if (slot < 0 && e > best[s]) slot = s;
            if (slot < 0) continue;
            for (int s = 2; s > slot; --s) { best[s] = best[s - 1]; lt[s] = lt[s - 1]; }
            // Each in-cloud stroke lights a slightly different, mostly
            // horizontal channel; a ground stroke's channel runs up into the base.
            uint id = uint(k * 4 + j);
            float3 jit = (rand3(id, 11u, seed) - 0.5f) * float3(0.12f, 0.10f, 0.08f);
            float3 r = rand3(id, 12u, seed) - 0.5f;
            float3 axis = cg ? float3(0.02f, 0.10f, 0.0f)
                             : normalize(float3(r.x * 2.0f, r.y * 0.8f, r.z)) * (0.08f + 0.10f * PLAINS_EV_STR[k]);
            float3 col = cg ? float3(0.92f, 0.92f, 1.0f) : float3(0.84f, 0.88f, 1.0f);
            best[slot] = e;
            // in-cloud channels sit toward the visible face of the cloud
            lt[slot].pos = PLAINS_EV_POS[k] * float3(1.0f, 1.0f, cg ? 1.0f : 0.3f) + (cg ? float3(0.0f, 0.07f, 0.06f) : jit);
            lt[slot].axis = axis;
            // a ground stroke's light sits low in the base, so it is dimmer
            // (the anvil bolt's sits in the thin anvil, so dimmer still)
            lt[slot].col = col * (e * PLAINS_FLASH * (cg ? (PLAINS_EV_KIND[k] == 2 ? 0.30f : 0.55f) : 1.0f));
        }
    }
    return best[2] > 0.0f ? 3 : (best[1] > 0.0f ? 2 : (best[0] > 0.0f ? 1 : 0));
}

// ------------------------------------------------------------------ cloud march

static inline float plains_hg(float c, float g) {
    float g2 = g * g;
    return (1.0f - g2) / pow(1.0f + g2 - 2.0f * g * c, 1.5f);
}

// Light scattered toward the camera at cloud point c (macro shape ms,
// `depth` under the detailed surface): sky and town ambient, the moon with
// self-shadowing, and the lightning channels.
static float3 plains_shade(float3 c, PlainsShape ms, float depth, bool deep, float t, uint seed, thread PlainsLight* lt, int nl) {
    const float3 moonDir = normalize(PLAINS_MOON_DIR);
    const float3 moonCol = float3(0.0700f, 0.0790f, 0.1000f);
    const float3 skyAmb  = float3(0.0012f, 0.0015f, 0.0027f);
    const float3 warmAmb = float3(0.0013f, 0.0009f, 0.0006f);
    const float moonPhase = mix(1.0f, plains_hg(dot(-moonDir, float3(0, 0, -1)), 0.55f), 0.5f);
        // occlusion: depth under the surface, and creases between billows
        // (where the detail cuts into the macro form) see less sky
        float ao = exp(-max(depth - 0.02f, 0.0f) * 6.0f) * (0.15f + 0.85f * smoothstep(-0.06f, 0.10f, ms.sd));
        // Sky light comes from above: the low flanks and the base see
        // little of it. A faint warm kiss from the towns on the underside.
        float up = saturate((c.y - ms.base) * 1.6f);
        float3 S = skyAmb * (0.12f + 0.88f * up) * ao
                 + warmAmb * exp(-max(c.y - ms.base, 0.0f) * 9.0f);

        // Moonlight: a near shadow sample for the lobes, a far coarse one
        // for the big masses; multiple scattering as attenuation octaves.
        // Shadowing is read from how far under the surface two points
        // toward the moon lie (not from their density, which is a step at
        // these sigmas): a graded terminator instead of hard blotches.
        float dA, dB;
        float3 cA = c + moonDir * 0.022f, cB = c + moonDir * 0.08f;
        plains_density(cA, plains_macro(cA), t, 1, seed, dA);
        dB = -plains_macro(cB).sd;
        // relative to this sample's own depth, so a sample that lands a
        // little deeper (after a grazing hit) is not shaded darker
        float d0 = max(depth, 0.0f);
        // (offsets near the sample distance give a Lambert-like ramp: full
        // light only on faces turned to the moon)
        float od = 55.0f * max(dA - d0 + 0.018f, 0.0f) + 16.0f * max(dB - d0 + 0.05f, 0.0f)
                 + plains_density_coarse(c + moonDir * 0.22f) * 0.05f;
        // (a short multiple-scattering tail: the shadowed mass stays darker
    // than the sky, so the storm reads as a dark body with lit billows)
    S += moonCol * moonPhase * (0.80f * exp(-od) + 0.14f * exp(-0.30f * od) + 0.06f * exp(-0.09f * od));

        // Lightning channels inside the cloud, two shadow samples each.
        for (int i = 0; i < nl; ++i) {
            float3 a = lt[i].pos - lt[i].axis, ba = 2.0f * lt[i].axis;
            float3 v = a + ba * saturate(dot(c - a, ba) / dot(ba, ba)) - c;
            float d2 = dot(v, v);
            float d = sqrt(d2);
            // fall-off minus a floor, so the cut where we stop paying
            // for shadow rays is continuous (no contour on the anvil)
            float fall = 1.0f / (d2 + 0.010f) - 0.002f / max(lt[i].col.x, 1e-6f);
            if (fall <= 0.0f) continue;
            // smooth macro occlusion for the mass, plus a short detailed
            // sample so lobes facing away from the flash stay shaded
            float3 vl = v / max(d, 1e-4f);
            float odl = (plains_density_coarse(c + v * 0.3f) + plains_density_coarse(c + v * 0.7f)) * (d * 0.5f);
            if (!deep) odl += plains_density_at(c + vl * min(0.04f, 0.5f * d), t, 2, seed) * 0.05f;
            // steep: the light pools around the channel and lobes facing it
            // a long multiple-scattering tail keeps a buried flash glowing
            float tl = 0.55f * exp(-0.50f * odl) + 0.30f * exp(-0.12f * odl) + 0.15f * exp(-0.03f * odl);
            float ph = mix(1.0f, plains_hg(-vl.z, 0.6f), 0.5f);
            // light from deep inside comes out slightly blue-violet
            float3 tint = exp(-odl * float3(0.016f, 0.010f, 0.0f));
            S += lt[i].col * tint * tl * ph * fall;
        }

    return S;
}

// In-scattered light (rgb) and transmittance (a) along the view ray through
// screen point cxy. The camera stands on the plain at cloud point
// (cam.x, cam.y, -PLAINS_DIST), so higher parts are seen slightly from below.
static float4 plains_cloud(float2 cxy, float2 cam, float t, float jitter, uint seed, thread PlainsLight* lt, int nl) {
    // Conservative 2D silhouette of the parts (anvil, tower, flanking line),
    // padded for perspective drift over the march depth and the displacement.
    float2 drift = abs(cxy - cam) * (0.72f / PLAINS_DIST) + PLAINS_AMAX + 0.03f;
    bool inAnvil = cxy.y > 0.60f - drift.y && cxy.y < 1.06f + drift.y && cxy.x > -0.70f - drift.x && cxy.x < 2.90f + drift.x;
    bool inTower = cxy.y > -0.10f - drift.y && cxy.y < 1.05f + drift.y && cxy.x > -0.48f - drift.x && cxy.x < 0.92f + drift.x;
    bool inFlank = cxy.y > -0.10f - drift.y && cxy.y < 0.30f + drift.y && cxy.x > -1.70f - drift.x && cxy.x < 0.0f;
    if (!(inAnvil || inTower || inFlank)) return float4(0, 0, 0, 1);
    // a ray that stays under the lowest point of the base sees nothing
    float2 slope0 = (cxy - cam) / PLAINS_DIST;
    if (cxy.y + abs(slope0.y) * 0.72f < -0.075f) return float4(0, 0, 0, 1);

    // c(z) = (cxy + slope * z, z); path length per unit z is `stretch`.
    float2 slope = (cxy - cam) / PLAINS_DIST;
    float stretch = sqrt(1.0f + dot(slope, slope));
    float3 L = float3(0.0f);
    float T = 1.0f;
    float z = -0.72f + jitter * PLAINS_STEP;
    float zOut = z - PLAINS_STEP;    // last sample known to be outside
    int it = 0;
    // Three phases per contact (march to it, refine it, shade through it),
    // kept apart so the costly refine and shade run in step across a SIMD
    // group instead of once for every march iteration at which some lane
    // happens to arrive.
    for (int pass = 0; pass < 4 && T > 0.0f; ++pass) {
        // 1. march through empty space and the displacement shell
        bool hit = false;
        float3 c; PlainsShape ms; float depth = 0.0f, dens = 0.0f;
        for (; it < 140 && z < 0.72f; ++it) {
            c = float3(cxy + slope * z, z);
            // Under the flat base only the wall cloud and its tail hang down:
            // outside their footprint, jump to it or up to the base in one go
            // (stop if the ray never gets there).
            if (c.y < -0.008f && !(c.y > -0.075f && z > -0.20f && z < 0.08f && c.x > -0.30f && c.x < 0.44f)) {
                float zj = 1e3f;
                if (z < -0.20f && c.y > -0.075f) zj = -0.20f - z;
                if (slope.y > 1e-3f) zj = min(zj, (-0.008f - c.y) / slope.y);
                zOut = z;
                z += zj >= 1e3f ? 1e3f : ceil(max(zj, PLAINS_STEP) / PLAINS_STEP) * PLAINS_STEP;
                continue;
            }
            ms = plains_macro(c);
            // the anvil's own displacement is about half the tower's
            float amax = mix(PLAINS_AMAX, 0.10f, ms.anvil);
            if (ms.sd > amax) {
                // empty space: jump ahead, staying on the jittered step grid
                zOut = z;
                z += ceil(max((ms.sd - amax) / stretch, PLAINS_STEP) / PLAINS_STEP) * PLAINS_STEP;
                continue;
            }
            int oct = T > 0.7f ? PLAINS_OCT_N : (T < 0.45f ? 3 : PLAINS_OCT_N - 1);
            dens = plains_density(c, ms, t, oct, seed, depth);
            if (dens <= 0.0f && depth < -PLAINS_STEP) {
                // provably clear: the displaced surface is at least -depth
                // away; scaled down as the displacement is not 1-Lipschitz
                zOut = z;
                z += ceil(-0.7f * depth / stretch / PLAINS_STEP) * PLAINS_STEP;
                continue;
            }
            if (dens > 0.05f) { hit = true; break; }
            zOut = z;
            z += PLAINS_STEP;
        }
        if (!hit) break;

        // 2. First contact (or a new one after grazing a lobe): bisect back
        // to the surface and shade from a fixed depth under it, so the
        // per-pixel march jitter cannot print a static hatch on the billows.
        // Bisection needs only the sign of the density (the early-exit
        // depths are bounds, so secant estimates from them come out
        // jitter-dependent), and runs on the three big octaves: the fine
        // ones only crenellate silhouettes and still decide opacity below.
        if (T > 0.8f) {
            float za = zOut, zb = z;
            for (int k = 0; k < 6 && zb - za > 0.004f; ++k) {
                float zm = 0.5f * (za + zb);
                if (plains_density_at(float3(cxy + slope * zm, zm), t, 3, seed) > 0.05f) zb = zm; else za = zm;
            }
            z = zb + 0.006f;
            int oct = PLAINS_OCT_N;
            c = float3(cxy + slope * z, z); ms = plains_macro(c);
            dens = plains_density(c, ms, t, oct, seed, depth);
            // where the fine octaves carve the surface a little deeper,
            // nudge in by small fixed steps instead of falling back to the grid
            for (int k = 0; k < 3 && dens <= 0.05f; ++k) {
                z += 0.007f;
                c = float3(cxy + slope * z, z); ms = plains_macro(c);
                dens = plains_density(c, ms, t, oct, seed, depth);
            }
        }

        // 3. shade samples until the ray leaves the cloud or goes opaque
        for (; it < 140; ++it) {
            if (dens > 0.05f) {
                // the thin anvil gets double steps; its extinction follows
                // the anvil weight continuously so no contour is drawn
                float Ts = exp(-dens * PLAINS_STEP * stretch * mix(1.0f, 2.0f, ms.anvil));
                float3 S = plains_shade(c, ms, depth, T < 0.45f, t, seed, lt, nl);
                L += T * (1.0f - Ts) * S;
                T *= Ts;
                // nearly opaque: what lies deeper looks like this sample, so
                // credit the rest to it instead of shading more samples
                if (T < 0.15f) { L += T * S; T = 0.0f; break; }
                z += ms.anvil > 0.99f ? 2.0f * PLAINS_STEP : PLAINS_STEP;
            } else {
                // a ray that grazed one lobe and left it refines the next one
                if (T > 0.8f) break;
                zOut = z;
                z += PLAINS_STEP;
            }
            if (z >= 0.72f) break;
            c = float3(cxy + slope * z, z); ms = plains_macro(c);
            if (ms.sd > mix(PLAINS_AMAX, 0.10f, ms.anvil)) break;     // back to marching
            int oct = T > 0.7f ? PLAINS_OCT_N : (T < 0.45f ? 3 : PLAINS_OCT_N - 1);
            dens = plains_density(c, ms, t, oct, seed, depth);
            if (dens <= 0.0f && depth < -PLAINS_STEP) break;
        }
        if (z >= 0.72f || it >= 140) break;
    }
    return float4(L, T);
}

// ------------------------------------------------------------------ bolts

static inline float plains_seg(float2 p, float2 a, float2 b) {
    float2 pa = p - a, ba = b - a;
    float h = saturate(dot(pa, ba) / max(dot(ba, ba), 1e-8f));
    return length(pa - ba * h);
}

// Fractal lateral offset along a channel: smooth octaves for the big meander,
// then sideways jogs between straighter runs of irregular length, and only a
// small per-vertex kink (a uniform kink reads as a sawtooth).
static inline float plains_meander(float s, int i, uint id, uint seed) {
    float m = 0.0f, a = 0.16f, f = 1.7f;
    for (int k = 0; k < 5; ++k) {
        m += a * gnoise2(float2(s * f, 0.37f + float(k) * 3.1f), seed + id * 13u);
        a *= 0.58f; f *= 2.3f;
    }
    float run = floor(s * 11.0f + 1.6f * gnoise2(float2(s * 4.0f, 2.3f), seed + id * 13u + 5u));
    float jog = rand1(uint(int(run) + 64), id * 7u + 3u, seed) - 0.5f;
    return m + 0.030f * jog + 0.006f * (rand1(uint(i), id * 7u + 2u, seed) - 0.5f);
}

constant int PLAINS_MAIN_N = 96;
constant int PLAINS_BR_N   = 30;

// Vertex i of the main channel of bolt `id` (cloud space); m0 is
// plains_meander(0, 0, id, seed), which pins the channel to its top.
static inline float2 plains_main_v(int i, float2 top, float2 bot, uint id, uint seed, float m0) {
    float s = float(i) / float(PLAINS_MAIN_N);
    if (i > 0 && i < PLAINS_MAIN_N) s += (rand1(uint(i), id * 7u + 1u, seed) - 0.5f) * 0.6f / float(PLAINS_MAIN_N);
    float len = top.y - bot.y;
    float lat = len * (plains_meander(s, i, id, seed) - m0 * (1.0f - s));
    return float2(mix(top.x, bot.x, s) + lat, mix(top.y, bot.y, s));
}

// Distance to bolt `id`: x = main channel, y = nearest branch, z = that
// branch's brightness taper.
static float3 plains_bolt_dist(float2 c, float2 top, float2 bot, uint id, uint seed) {
    float len = top.y - bot.y;
    float m0 = plains_meander(0.0f, 0, id, seed);
    float dm = 1e3f;
    int ic = clamp(int(floor((top.y - c.y) / len * float(PLAINS_MAIN_N))), 0, PLAINS_MAIN_N - 1);
    for (int i = ic - 2; i <= ic + 2; ++i) {
        if (i < 0 || i >= PLAINS_MAIN_N) continue;
        dm = min(dm, plains_seg(c, plains_main_v(i, top, bot, id, seed, m0), plains_main_v(i + 1, top, bot, id, seed, m0)));
    }
    float db = 1e3f, taper = 0.0f;
    for (int b = 0; b < 5; ++b) {
        float3 r = rand3(uint(b), id * 5u + 77u, seed);
        int i0 = 3 + int(r.x * float(PLAINS_MAIN_N) * 0.6f);
        float2 o = plains_main_v(i0, top, bot, id, seed, m0);
        float ang = (r.y < 0.5f ? -1.0f : 1.0f) * (0.30f + 0.65f * r.z);
        float2 dir = float2(sin(ang), -cos(ang));
        float blen = len * (0.12f + 0.30f * rand1(uint(b), id * 5u + 78u, seed)) * (1.0f - float(i0) / float(PLAINS_MAIN_N) * 0.6f);
        float2 v = c - o;
        float along = dot(v, dir) / blen;
        if (along < -0.1f || along > 1.1f || abs(dot(v, float2(-dir.y, dir.x))) > 0.35f * blen + 0.02f) continue;
        int jc = clamp(int(floor(along * float(PLAINS_BR_N))), 0, PLAINS_BR_N - 1);
        uint bid = id * 31u + uint(b) * 3u + 5u;
        float b0 = plains_meander(0.0f, 0, bid, seed);
        for (int j = jc - 2; j <= jc + 2; ++j) {
            if (j < 0 || j >= PLAINS_BR_N) continue;
            float2 pts[2];
            for (int e = 0; e < 2; ++e) {
                float sb = float(j + e) / float(PLAINS_BR_N);
                float lat = blen * 0.75f * (plains_meander(sb * 1.5f, j + e, bid, seed) - b0);
                pts[e] = o + dir * (sb * blen) + float2(-dir.y, dir.x) * lat;
            }
            float dseg = plains_seg(c, pts[0], pts[1]);
            if (dseg < db) { db = dseg; taper = 1.0f - saturate(along); }
        }
    }
    return float3(dm, db, taper);
}

// Channel (x) and branch (y) brightness of ground stroke k at time t; return
// strokes re-light the main channel only, the branches belong to the first.
static inline float2 plains_cg_amp(int k, float t, float L) {
    float dt = plains_since(k, t, L);
    if (dt > 2.0f) return float2(0.0f);
    float ch = 0.0f, br = 0.0f;
    for (int j = 0; j < PLAINS_EV_N[k]; ++j) {
        float dj = dt - float(j) * PLAINS_EV_GAP[k];
        ch += plains_stroke_amp(j) * (flash_env(dj, 0.02f, 0.07f) + 0.12f * flash_env(dj, 0.02f, 0.15f));
        if (j == 0) br = flash_env(dj, 0.02f, 0.06f) + 0.10f * flash_env(dj, 0.02f, 0.12f);
    }
    return float2(ch, br) * PLAINS_EV_STR[k];
}

// Where ground stroke k meets the plain (cloud units).
static inline float2 plains_cg_foot(int k, float yg, uint seed) {
    float2 top = PLAINS_EV_POS[k].xy;
    return float2(top.x + PLAINS_EV_FOOT[k], yg);
}

// Light of the cloud-to-ground bolts at time t: channel core, glow, contact
// point. Return strokes re-light the main channel only; the branches belong
// to the first stroke.
static float3 plains_bolts(float2 cxy, float pxc, float t, float L, float yg, uint seed, bool front) {
    float3 bolt = float3(0.0f);
    for (int k = 0; k < PLAINS_NEV; ++k) {
        if (PLAINS_EV_KIND[k] != (front ? 2 : 1)) continue;
        float2 amp = plains_cg_amp(k, t, L);
        float ch = amp.x, br = amp.y;
        if (ch < 1e-3f) continue;
        float2 top = PLAINS_EV_POS[k].xy;
        float2 bot = plains_cg_foot(k, yg, seed);
        float sAlong = saturate((top.y - cxy.y) / (top.y - bot.y));
        if (abs(cxy.x - mix(top.x, bot.x, sAlong)) > 0.4f * (top.y - bot.y) + 0.12f || cxy.y > top.y + 0.2f || cxy.y < yg - 0.08f) continue;
        float3 dd = plains_bolt_dist(cxy, top, bot, uint(k), seed);
        // Core width in cloud units, kept >= ~1 px with its energy conserved.
        const float wCore = 0.0011f, wBr = 0.0007f;
        float wc = max(wCore, 0.75f * pxc), wb = max(wBr, 0.7f * pxc);
        float core  = exp(-(dd.x * dd.x) / (wc * wc)) * (wCore / wc);
        float bcore = exp(-(dd.y * dd.y) / (wb * wb)) * (wBr / wb) * pow(dd.z, 0.8f);
        float glow  = exp(-dd.x / 0.004f) * 0.30f + 0.05f / (1.0f + pow(dd.x / 0.035f, 2.0f));
        // the channel's brightness varies along its length
        core *= 0.55f + 0.45f * vnoise2(float2((top.y - cxy.y) * 14.0f, float(k)), seed + 19u);
        float bglow = exp(-dd.y / 0.005f) * 0.25f * dd.z;
        const float3 hot = float3(0.95f, 0.92f, 1.0f), halo = float3(0.55f, 0.52f, 1.0f);
        // glow fades into the cloud; a bolt drawn over the cloud stops at its top
        float above = front ? smoothstep(top.y + 0.04f, top.y - 0.03f, cxy.y) : smoothstep(top.y + 0.18f, top.y, cxy.y);
        bolt += above * (ch * (hot * core * 9.0f + halo * glow * 0.9f) + br * (hot * bcore * 4.0f + halo * bglow * 0.6f));
        float2 dg = (cxy - bot) * float2(1.0f, 2.5f);
        bolt += ch * halo * 0.25f * exp(-length(dg) / 0.02f);
    }
    return bolt;
}

// ------------------------------------------------------------------ veil
// Precipitation: a dark core of three ragged, wind-slanted shafts hanging
// from the base just downwind of the updraft, and a lighter, wispier veil
// falling from the forward anvil. 2D (it is soft and far), lit by the
// lightning around it. Returns light (rgb) and opacity (a).
static inline float plains_bump(float x, float c, float w) { float q = (x - c) / w; return exp(-q * q); }

static float4 plains_veil(float2 c, float yg, float t, float L, uint seed, thread PlainsLight* lt, float3 bolt) {
    if (c.x < 0.0f || c.x > 2.4f || c.y > 0.92f || c.y < yg - 0.04f) return float4(0.0f);
    // the outflow drags the feet of the shafts downwind; ragged edges
    float xq = c.x - 0.30f * (0.05f - c.y);
    xq += 0.035f * gnoise2(float2(c.y * 4.0f, c.x * 1.5f), seed + 6u) + 0.012f * gnoise2(c * 13.0f, seed + 7u);
    float core = 1.00f * plains_bump(xq, 0.27f, 0.085f) + 0.85f * plains_bump(xq, 0.50f, 0.11f)
         + 0.60f * plains_bump(xq, 0.73f, 0.075f)
         + 0.30f * smoothstep(0.12f, 0.28f, xq) * smoothstep(0.86f, 0.70f, xq);
    // it hangs from the base and rises into murk beside the forward flank
    core *= smoothstep(0.32f, 0.02f, c.y);
    // rain and virga from the anvil: wisps high up, a soft curtain lower down
    float anv = smoothstep(0.80f, 1.00f, xq) * smoothstep(2.3f, 1.4f, xq)
              * (0.25f + 0.75f * smoothstep(-0.2f, 0.6f, gnoise2(float2(xq * 2.6f, 1.7f), seed + 5u)))
              * smoothstep(0.88f, 0.62f, c.y) * (0.55f + 0.45f * smoothstep(0.45f, 0.0f, c.y));
    // falling streaks, exactly periodic over the loop
    float streak = 0.62f + 0.38f * gnoise2p(float2(xq * 10.0f, c.y * 1.2f + 6.0f * t / L), int2(0, 6), seed + 9u)
                         * (0.5f + 0.5f * gnoise2(float2(xq * 4.0f, 4.0f), seed + 10u));
    float ground = smoothstep(yg - 0.04f, yg + 0.015f, c.y);   // melts into the haze
    float dens = (1.5f * core + 0.9f * anv) * streak * ground;
    if (dens < 1e-3f) return float4(0.0f);
    float op = 1.0f - exp(-dens);
    // Dark grey-blue low down, where it hides the horizon glow; higher up the
    // anvil's veil catches a little moonlight and reads as grey against the
    // darker sky. A faint warm kiss from the towns near the ground.
    float3 l = mix(float3(0.0040f, 0.0046f, 0.0060f), float3(0.0120f, 0.0132f, 0.0160f), smoothstep(0.05f, 0.6f, c.y))
             + float3(0.0030f, 0.0018f, 0.0008f) * exp(-(c.y - yg) / 0.05f);
    for (int i = 0; i < 3; ++i) {
        // flashes in the cloud above light the rain from overhead
        float2 dl = c - lt[i].pos.xy;
        l += lt[i].col * (0.20f * exp(-length(dl) / 0.30f) + 0.06f * exp(-abs(dl.x) / 0.45f));
    }
    l += bolt * 0.6f;      // a bolt inside the shaft lights the rain around it
    return float4(l * op, op);
}

// ------------------------------------------------------------------ sky, ground

static float3 plains_stars(float2 p, float pxs, float t, float L, uint seed) {
    float3 acc = float3(0.0f);
    for (int layer = 0; layer < 2; ++layer) {
        float cell = layer == 0 ? 0.022f : 0.0095f;
        float prob = layer == 0 ? 0.55f : 0.45f;
        // One star at most per cell, kept off the cell border by more than
        // its glow reaches, so only the pixel's own cell needs testing.
        int2 cc = int2(floor(p / cell));
        {
            float3 h = hash3(cc, seed * 3u + 101u + uint(layer));
            if (h.z > prob) continue;
            float2 d = p - (float2(cc) + 0.1f + 0.8f * h.xy) * cell;
            float m = h.z / prob;
            float bright = layer == 0 ? 0.6f * pow(1.0f - m, 7.0f) + 0.02f : 0.035f * (1.0f - m) + 0.006f;
            // fixed angular size, at least ~1 px, energy conserved
            float r0 = 0.00042f, r = max(r0, 0.7f * pxs);
            float g = exp(-dot(d, d) / (r * r)) * (r0 * r0) / (r * r);
            float3 h2 = hash3(cc, seed * 3u + 202u + uint(layer));
            float3 tint = mix(float3(1.0f, 0.82f, 0.64f), float3(0.78f, 0.86f, 1.0f), h2.x);
            float tw = 1.0f + 0.28f * sin(TAU * (floor(3.0f + h2.y * 9.0f) * t / L) + h2.z * TAU);
            acc += tint * bright * tw * g;
        }
    }
    return acc;
}

static float3 plains_sky(float2 p, float horizon) {
    float e = p.y - horizon;
    float3 zen = float3(0.0030f, 0.0038f, 0.0090f);
    float3 hor = float3(0.0120f, 0.0160f, 0.0210f);
    float3 col = mix(hor, zen, pow(smoothstep(0.0f, 0.75f, e), 0.55f));
    // the moon, off-frame high on the left, brightens that side a little
    float2 m = p - float2(-1.3f, 0.7f);
    col += float3(0.004f, 0.006f, 0.010f) * exp(-dot(m, m) * 0.9f);
    // warm light domes of distant towns along the horizon
    col += float3(0.014f, 0.0075f, 0.0030f) * exp(-max(e, 0.0f) / 0.045f) * exp(-pow((p.x - 0.18f) / 0.55f, 2.0f));
    col += float3(0.006f, 0.0045f, 0.003f) * exp(-max(e, 0.0f) / 0.02f);
    return col;
}

// Height of the distant tree belts and farmsteads breaking the horizon.
static inline float plains_treeline(float x, uint seed) {
    float belt = smoothstep(0.55f, 0.8f, vnoise2(float2(x * 7.0f, 0.5f), seed + 61u));
    return belt * (0.0022f + 0.0018f * vnoise2(float2(x * 140.0f, 0.5f), seed + 62u));
}

// Gentle swells of the plain lift and lower the horizon by a few pixels.
static inline float plains_horizon(float x, float h0, uint seed) {
    return h0 + 0.0060f * (vnoise2(float2(x * 2.1f, 0.5f), seed + 63u) - 0.5f)
              + 0.0024f * (vnoise2(float2(x * 7.3f, 1.5f), seed + 64u) - 0.5f);
}

// ------------------------------------------------------------------ grass

static inline float plains_sway(float x, float t, float L) {
    return 0.55f * sin(TAU * (3.0f * t / L) - x * 7.0f)
         + 0.30f * sin(TAU * (7.0f * t / L) - x * 13.0f + 1.3f)
         + 0.15f * sin(TAU * (13.0f * t / L) - x * 29.0f + 4.1f);
}

// Coverage of grass blades in layer `layer` (0 back .. 2 front), an edge
// term for rim light and which side of the blade the pixel is on (+1 right). Blades grow from below the frame; a slow clump field
// varies their density and height so the band never reads as a comb.
static float3 plains_grass_layer(float2 p, float pxs, float t, float L, int layer, uint seed) {
    const float colw[3]  = { 0.0036f, 0.0062f, 0.0105f };
    const float hmin[3]  = { 0.06f, 0.08f, 0.07f };
    const float hmax[3]  = { 0.15f, 0.21f, 0.27f };
    const float hw[3]    = { 0.0009f, 0.0015f, 0.0026f };
    const float swayA[3] = { 0.004f, 0.007f, 0.011f };
    const float y0 = -0.53f;
    if (p.y > y0 + hmax[layer] * 1.35f) return float3(0.0f);
    float sw = swayA[layer] * plains_sway(p.x, t, L);
    float cov = 0.0f, edge = 0.0f, side = 0.0f;
    float col = colw[layer];
    for (int b = 0; b < 2; ++b) {
        float off = float(b) * 0.5f * col;
        int ic = int(floor((p.x - off) / col));
        for (int i = ic - 2; i <= ic + 2; ++i) {
            float3 h = hash3(int2(i, layer * 2 + b), seed * 7u + 919u);
            float xb = (float(i) + 0.15f + 0.7f * h.z) * col + off;
            float clump = vnoise2(float2(xb * 9.0f, float(layer) * 5.3f), seed + 31u);
            if (h.y > 0.25f + 0.85f * clump) continue;          // gaps between clumps
            float hgt = mix(hmin[layer], hmax[layer], h.x * h.x) * (0.55f + 0.7f * clump);
            float3 h2 = hash3(int2(i, layer * 2 + b), seed * 7u + 920u);
            bool stalk = layer == 2 && h2.x < 0.10f;
            if (stalk) hgt *= 1.3f;
            float s = (p.y - y0) / hgt;
            if (s < 0.0f || s > 1.0f) continue;
            float lean = (h2.y - 0.5f) * 4.0f * col + (stalk ? 0.0f : (h2.z - 0.5f) * 2.0f * col);
            float bend = lean + sw * (hgt / hmax[layer]);
            float xc = xb + bend * s * s;
            float slope = 2.0f * s * bend / hgt;
            float w = stalk ? hw[layer] * 0.35f : hw[layer] * pow(1.0f - s, 0.7f) * (0.6f + 0.8f * h.y);
            if (stalk) {
                // oat-like seed head over the top fifth
                float hs = saturate((s - 0.78f) / 0.22f);
                w += hw[layer] * 0.9f * sin(PI * hs) * (0.8f + 0.2f * sin(hs * 40.0f));
            }
            float aa = pxs * sqrt(1.0f + slope * slope);
            float dx = abs(p.x - xc);
            float c1 = saturate((w - dx) / aa + 0.5f) * saturate((1.0f - s) * hgt / (aa * 1.5f) + 0.3f);
            if (c1 > cov) { cov = c1; edge = saturate(1.0f - abs(w - dx) / (aa * 2.0f + w * 0.5f)) * s; side = sign(p.x - xc); }
        }
    }
    return float3(cov, edge, side);
}

// ------------------------------------------------------------------ kernel

kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float2 p = frame_uv(gid, u.resolution);
    float pxs = px_size(u.resolution);
    float t = u.time, L = u.loop;
    PlainsLayout lay = plains_layout(u.resolution);

    PlainsLight lt[3];
    float flashTotal;
    int nl = min(plains_lights(t, L, u.seed, lt, flashTotal), 2);

    float2 cxy = (p - lay.anchor) / lay.scale;
    float pxc = pxs / lay.scale;
    float yg = (lay.horizon - lay.anchor.y) / lay.scale;   // horizon in cloud units

    float3 col;
    float hzn = plains_horizon(p.x, lay.horizon, u.seed);
    float tree = plains_treeline(p.x, u.seed);
    float above = saturate((p.y - hzn - tree) / pxs + 0.5f);
    // Haze over the far plain: the sky's own horizon colour, dimmed where
    // the storm and its rain stand between it and the town glow beyond.
    float sx0 = lay.anchor.x - 0.40f * lay.scale, sx1 = lay.anchor.x + 0.95f * lay.scale;
    float under = smoothstep(sx0 - 0.08f, sx0 + 0.06f, p.x) * smoothstep(sx1 + 0.10f, sx1 - 0.06f, p.x);
    float3 haze = plains_sky(float2(p.x, lay.horizon + 0.004f), lay.horizon) * (1.0f - 0.40f * under);
    if (above > 0.0f) {
        // The storm, then whatever it leaves visible behind it.
        float jitter = fract(52.9829189f * fract(0.06711056f * float(gid.x) + 0.00583715f * float(gid.y)));
        float4 cl = plains_cloud(cxy, float2(-lay.anchor.x / lay.scale, yg), t, jitter, u.seed, lt, nl);
        col = cl.rgb;
        if (cl.a > 0.002f) {
            float3 bg = plains_sky(p, lay.horizon);
            bg += plains_stars(p, pxs, t, L, u.seed) * smoothstep(0.0f, 0.18f, p.y - lay.horizon);
            float3 bolt = plains_bolts(cxy, pxc, t, L, yg, u.seed, false);
            float4 veil = plains_veil(cxy, yg, t, L, u.seed, lt, bolt);
            bg = (bg + bolt) * (1.0f - veil.a) + veil.rgb;
            col += bg * cl.a;
        }
        // the anvil bolt passes in front of the forward flank
        col += plains_bolts(cxy, pxc, t, L, yg, u.seed, true);
        // the haze band softens whatever stands on the horizon
        col = mix(col, haze, 0.55f * exp(-max(p.y - hzn, 0.0f) / 0.010f));
        col *= above;
    }
    if (above < 1.0f) {
        // Prairie floor seen in perspective: ground depth Z and lateral X.
        float g = max(hzn - p.y, 0.0f);
        float Z = 0.02f / max(g, 2e-4f), X = p.x * Z;
        // low swells: lighter crests over darker troughs, receding in bands
        float sw = gnoise2(float2(X * 0.45f, Z * 1.7f), u.seed + 43u) * 0.7f
                 + gnoise2(float2(X * 1.1f, Z * 3.9f), u.seed + 44u) * 0.3f;
        float crest = smoothstep(-0.35f, 0.65f, sw);
        float swA = smoothstep(0.002f, 0.012f, g);
        // Tufted prairie: short upright streaks. x is screen x (any function
        // of X = p.x * Z fans out from the vanishing point), its frequency
        // stepping up with distance by blending two octave bands; y is the
        // log of the depression angle, so streak height shrinks with g.
        float lg = log(max(g, 1e-4f));
        float lod = log2(max(7.2f / max(g, 1e-4f), 1.0f) / 60.0f);
        float i0 = floor(lod), fr = lod - i0;
        float f0 = 60.0f * exp2(i0);
        float tex = mix(gnoise2(float2(p.x * f0, lg * 5.0f), u.seed + 41u + uint(i0 + 8.0f) * 5u),
                        gnoise2(float2(p.x * f0 * 2.0f, lg * 5.0f), u.seed + 46u + uint(i0 + 8.0f) * 5u), fr);
        float texA = smoothstep(0.003f, 0.03f, g);
        float3 gr = float3(0.0030f, 0.0036f, 0.0043f);
        float3 gcol = gr * (1.0f + swA * (0.55f * crest - 0.25f)) * (1.0f + 0.35f * texA * tex);
        // atmospheric gradient into the haze band at the horizon
        gcol = mix(gcol, haze, exp(-g / 0.018f));

        // Lightning washes the plain, mostly toward the storm and on the
        // far ground; swell crests catch more of it than the troughs.
        float3 wash = float3(0.0f);
        for (int i = 0; i < 3; ++i) {
            float lx = lay.anchor.x + lt[i].pos.x * lay.scale;
            wash += lt[i].col * exp(-abs(p.x - lx) / 0.55f);
        }
        float lit = (0.30f + 0.70f * exp(-g / 0.07f)) * (0.65f + swA * 0.7f * crest);
        gcol += wash * 0.30f * lit;
        // the plain glows where a bolt touches down
        for (int k = 0; k < PLAINS_NEV; ++k) {
            if (PLAINS_EV_KIND[k] == 0) continue;
            float ch = plains_cg_amp(k, t, L).x;
            if (ch < 1e-3f) continue;
            float2 fp = lay.anchor + plains_cg_foot(k, yg, u.seed) * lay.scale;
            float2 d = (p - float2(fp.x, hzn)) * float2(1.0f, 4.0f);
            gcol += float3(0.55f, 0.52f, 1.0f) * ch * (0.030f * exp(-length(d) / 0.020f) + 0.004f * exp(-abs(d.x) / 0.15f) * lit);
        }
        // tree belts on the horizon: hazy, a little darker than the haze
        gcol = mix(gcol, mix(gr, haze, 0.55f) + wash * 0.08f, step(g, 0.0f));

        // A farmhouse far away on the plain: a warm window and a yard light.
        float fx = mix(-0.13f, -0.48f, lay.a);
        float2 fh = float2(fx, plains_horizon(fx, lay.horizon, u.seed) + 0.0012f);
        for (int i = 0; i < 2; ++i) {
            float2 d = p - fh - (i == 0 ? float2(0.0f) : float2(0.009f, 0.0006f));
            float r0 = 0.00045f, r = max(r0, 0.7f * pxs);
            float pt = exp(-dot(d, d) / (r * r)) * (r0 * r0) / (r * r);
            float3 warm = i == 0 ? float3(1.0f, 0.62f, 0.28f) : float3(1.0f, 0.78f, 0.5f);
            float a = i == 0 ? 1.0f : 0.45f;
            gcol += warm * a * (pt * 1.6f + 0.004f * exp(-length(d * float2(0.6f, 1.6f)) / 0.006f));
        }
        col = above > 0.0f ? col + gcol * (1.0f - above) : gcol;
    }

    // Light scattered by the air between us and the storm.
    for (int i = 0; i < 3; ++i) {
        float d = length(p - (lay.anchor + lt[i].pos.xy * lay.scale));
        col += lt[i].col * 0.010f / (1.0f + pow(d / 0.22f, 2.0f));
    }

    // Foreground grass silhouettes, back to front. They stay black against
    // the brighter plain during a flash; only tips standing above the
    // horizon catch a hairline rim, on the side facing the storm.
    float stormX = lay.anchor.x + 0.2f * lay.scale;
    for (int layer = 0; layer < 3; ++layer) {
        float3 g = plains_grass_layer(p, pxs, t, L, layer, u.seed);
        if (g.x <= 0.0f) continue;
        float3 gc = layer == 0 ? float3(0.0022f, 0.0027f, 0.0031f)
                  : (layer == 1 ? float3(0.0012f, 0.0015f, 0.0018f) : float3(0.0005f, 0.0007f, 0.0009f));
        float facing = step(0.0f, g.z * (stormX - p.x));
        gc += g.y * facing * smoothstep(hzn - 0.01f, hzn + 0.01f, p.y) * float3(0.35f, 0.38f, 0.6f) * 0.005f * flashTotal;
        col = mix(col, gc, g.x);
    }

    // Exposure, vignette, soft shoulder.
    col *= PLAINS_EXPOSURE * 3.0f;
    float2 vq = p / float2(0.5f * aspect_of(u.resolution), 0.5f);
    col *= mix(1.0f, 0.72f, smoothstep(0.5f, 1.5f, length(vq)));
    col = 1.0f - exp(-col);
    float3 o = srgb_encode(col);
    // Film grain, fixed in time: x265 keeps grain in I-frames but smooths it
    // out of P-frames, so animated grain would pulse at every keyframe.
    float gn = hash1(int2(floor((p + 1.0f) * 1100.0f)), u.seed + 3u) - 0.5f;
    o += gn * 0.006f * smoothstep(0.0f, 0.25f, o.g) * (1.0f - o.g);
    out.write(float4(saturate(o), 1.0f), gid);
}
