// window.metal: "Rain on the Window".
//
// Night, indoors, looking out through a wet pane. The camera is focused on the
// glass, so the city and the storm behind it are thrown into soft bokeh while
// every drop is a tiny lens holding a sharp, inverted copy of the same scene.
//
// Everything is a periodic function of time: drop slides, trails, bead
// regrowth, cars, blinkers and lightning are scheduled mod u.loop and the
// clouds evolve along a periodic noise axis, so the loop needs no crossfade.
//
// Coordinates: p is the glass (frame) position in height units, q is a
// position in the background scene, also in height units. The base view sees
// the background at q = p through the defocus; a drop sees it at q = lens(p).
//
// Test hook: --define WIN_DEBUG_HEADS paints sliding drop heads magenta and
// gathering ones green, for counting slides per frame over the loop.

#ifndef WIN_FOV
#define WIN_FOV 0.42f          // how much of the scene a drop sees (q radius at its rim)
#endif
#ifndef WIN_DEFOCUS
#define WIN_DEFOCUS 0.032f     // background blur of the base view (height units)
#endif
#ifndef WIN_EXPOSURE
#define WIN_EXPOSURE 1.0f
#endif
#ifndef WIN_GRAIN
#define WIN_GRAIN 0.010f
#endif

constant float WIN_LANE_W = 0.11f;    // width of a vertical slide lane on the glass

constant float3 WIN_SODIUM = float3(1.00f, 0.42f, 0.11f);
constant float3 WIN_WARM   = float3(1.00f, 0.70f, 0.42f);
constant float3 WIN_COOL   = float3(0.70f, 0.82f, 1.00f);
constant float3 WIN_TEAL   = float3(0.25f, 0.80f, 0.78f);
constant float3 WIN_RED    = float3(1.00f, 0.10f, 0.06f);
constant float3 WIN_FLASH  = float3(0.70f, 0.77f, 1.00f);

// ------------------------------------------------------------------ lightning
// Hand-paced schedule for a 40 s loop (scaled if the loop length differs):
// three big strikes with a visible bolt, two medium sheet flashes low behind
// the towers (one of them a slow in-cloud flicker) and five soft distant
// flickers, on deliberately uneven gaps with a long calm after 19 s so the
// rhythm never settles into a beat. x is a fraction of the usable half width,
// y the height of the flash above the horizon, sp stretches the stroke
// spacing and rise is the onset time.

struct WinStrike { float t0; float x; float y; float power; float bolt; int strokes; float decay; float sp; float rise; };

constant int WIN_NSTRIKES = 10;
constant WinStrike WIN_STRIKES[WIN_NSTRIKES] = {
    { 3.0f, -0.45f, 0.30f, 0.55f, 1.0f, 2, 0.50f, 1.00f, 0.10f},
    { 7.0f,  0.80f, 0.36f, 0.26f, 0.0f, 2, 0.70f, 1.00f, 0.14f},
    { 9.9f, -0.20f, 0.44f, 0.14f, 0.0f, 1, 0.80f, 1.00f, 0.16f},
    {12.8f,  0.55f, 0.10f, 0.44f, 0.0f, 3, 0.45f, 1.36f, 0.22f},
    {15.8f, -0.85f, 0.40f, 0.22f, 0.0f, 2, 0.65f, 1.00f, 0.14f},
    {19.2f,  0.20f, 0.30f, 0.55f, 1.0f, 3, 0.50f, 1.00f, 0.10f},
    {30.5f, -0.70f, 0.26f, 0.55f, 1.0f, 2, 0.45f, 1.00f, 0.10f},
    {33.4f,  0.90f, 0.34f, 0.22f, 0.0f, 1, 0.70f, 1.00f, 0.14f},
    {36.0f,  0.35f, 0.12f, 0.42f, 0.0f, 2, 0.60f, 1.00f, 0.12f},
    {38.6f, -0.10f, 0.42f, 0.16f, 0.0f, 2, 0.80f, 1.00f, 0.16f},
};
constant float WIN_STROKE_T[3] = {0.0f, 0.43f, 0.88f};
constant float WIN_STROKE_A[3] = {1.0f, 0.62f, 0.40f};

// Per-pixel context shared by the base view and the drop view.
struct WinCtx {
    float t, L, halfW;
    float hz, yn, ys;       // far horizon line, near rooftop line, street line
    float xspread;          // usable half width for flashes and the street
    uint  seed;
    float flash;            // total sky flash right now (lights the glass)
    int   nf;               // active flashes (0..2)
    float2 fpos[2];
    float fsky[2], fbolt[2];
    float fshift[2];        // which return stroke dominates (shimmers the bolt)
    uint  fk[2];
    bool  portrait;
};

static void window_lightning(thread WinCtx& c) {
    c.nf = 0; c.flash = 0.0f;
    float sc = c.L / 40.0f;
    for (int k = 0; k < WIN_NSTRIKES; ++k) {
        WinStrike s = WIN_STRIKES[k];
        float dt = since_event(c.t, s.t0 * sc, c.L);
        if (dt > 4.0f) continue;
        float sky = 0.0f, bolt = 0.0f, js = 0.0f;
        for (int j = 0; j < s.strokes; ++j) {
            float ts = WIN_STROKE_T[j] * s.sp;
            sky  += WIN_STROKE_A[j] * flash_env(dt - ts, s.rise, s.decay);
            float bj = WIN_STROKE_A[j] * flash_env(dt - ts, 0.04f, 0.09f);
            bolt += bj; js += bj * float(j);
        }
        if (sky < 1e-4f || c.nf >= 2) continue;
        int i = c.nf++;
        c.fpos[i]  = float2(s.x * c.xspread, c.hz + s.y);
        c.fsky[i]  = sky * s.power;
        c.fbolt[i] = bolt * s.bolt * s.power;
        c.fk[i]    = uint(k);
        c.fshift[i] = js / max(bolt, 1e-4f);
        c.flash   += sky * s.power;
    }
}

// --------------------------------------------------------------- small noise

// 1D gradient noise, about [-1,1].
static float window_n1(float x, uint salt, uint seed) {
    float i = floor(x), f = x - i;
    float g0 = hash1(int2(int(i), int(salt)), seed) * 2.0f - 1.0f;
    float g1 = hash1(int2(int(i) + 1, int(salt)), seed) * 2.0f - 1.0f;
    return 2.0f * mix(g0 * f, g1 * (f - 1.0f), fade5(f));
}

// 1D piecewise-linear value noise in [-1,1]: a jagged polyline, the right
// primitive for a lightning channel.
static float window_jag(float x, uint salt, uint seed) {
    float i = floor(x), f = x - i;
    float a = hash1(int2(int(i), int(salt)), seed);
    float b = hash1(int2(int(i) + 1, int(salt)), seed);
    return mix(a, b, f) * 2.0f - 1.0f;
}

// fbm whose octaves fade out once they are finer than the blur radius, so
// defocused and minified samples are prefiltered instead of aliasing.
// Periodic along z with period zper (in lattice cells of the first octave).
static float window_fbm_blur(float3 p, int zper, float blur, uint seed) {
    float sum = 0.0f, amp = 0.5f, norm = 0.0f, freq = 1.0f;
    int per = zper;
    for (int k = 0; k < 5; ++k) {
        float w = amp * saturate(1.3f - blur * freq * 5.0f);
        if (w > 0.0f) sum += w * gnoise3p(p, int3(0, 0, per), seed + uint(k) * 0x9E3779B9u);
        norm += amp; amp *= 0.5f; p *= 2.0f; per *= 2; freq *= 2.0f;
    }
    return sum / norm;
}

// ----------------------------------------------------------------- the city

struct WinRow { float w; float base; float hmin; float hmax; float tall; uint salt; };

static float window_row_top(int i, WinRow r, uint seed) {
    float3 h = hash3(int2(i, int(r.salt)), seed);
    float top = r.base + mix(r.hmin, r.hmax, h.x * h.x);
    if (h.y < r.tall) top += mix(0.05f, 0.15f, h.z);
    return top;
}

// Blurred occupancy of a row of buildings (1 = facade, 0 = sky above it).
static float window_row_mask(float2 q, WinRow r, float b, uint seed, thread int& cell) {
    int i = int(floor(q.x / r.w));
    cell = i;
    float xl = float(i) * r.w, xr = xl + r.w;
    float t0 = window_row_top(i - 1, r, seed), t1 = window_row_top(i, r, seed), t2 = window_row_top(i + 1, r, seed);
    float m0 = 1.0f - smoothstep(t0 - b, t0 + b, q.y);
    float m1 = 1.0f - smoothstep(t1 - b, t1 + b, q.y);
    float m2 = 1.0f - smoothstep(t2 - b, t2 + b, q.y);
    float bx = min(b, 0.45f * r.w);
    float wl = 1.0f - smoothstep(-bx, bx, q.x - xl);
    float wr = smoothstep(-bx, bx, q.x - xr);
    return wl * m0 + wr * m2 + (1.0f - wl - wr) * m1;
}

// Lit windows on the facade of building `cell`: sharp rectangles when seen
// through a drop, their average glow when defocused.
static float3 window_facade_lights(float2 q, WinRow r, int cell, float ww, float wh, float b, uint seed) {
    float3 hb = hash3(int2(cell, int(r.salt) + 50), seed);
    float lit = mix(0.06f, 0.38f, hb.x);
    float top = window_row_top(cell, r, seed);
    float lx = q.x - float(cell) * r.w;
    float inside = smoothstep(0.004f, 0.008f, lx) * smoothstep(0.004f, 0.008f, r.w - lx)
                 * (1.0f - smoothstep(top - 0.012f, top - 0.006f, q.y));
    float3 tint = mix(WIN_WARM, hb.y < 0.25f ? WIN_COOL : WIN_SODIUM, 0.35f);
    float3 mean = tint * lit * 0.22f * 0.45f;
    float sharpness = 1.0f - smoothstep(0.25f * ww, 0.9f * ww, b);
    float3 col = mean;
    if (sharpness > 0.0f) {
        float2 g = float2(lx / ww, (q.y - r.base) / wh);
        int2 wi = int2(floor(g));
        float2 f = g - floor(g);
        float3 h = hash3(wi + int2(cell * 97, 0), seed + r.salt);
        float on = step(h.x, lit);
        float aa = max(b / ww, 0.02f);
        float rect = (1.0f - smoothstep(0.30f - aa, 0.30f + aa, abs(f.x - 0.5f)))
                   * (1.0f - smoothstep(0.28f - aa, 0.28f + aa, abs(f.y - 0.5f)));
        float3 wc = h.y < 0.2f ? WIN_COOL : (h.y < 0.75f ? WIN_WARM : WIN_SODIUM);
        float3 sharp = wc * on * rect * mix(0.15f, 0.5f, h.z);
        col = mix(mean, sharp, sharpness);
    }
    return col * inside;
}

// A defocused point light: a disc with a faintly brighter rim, clipped into a
// cat's eye toward the frame edges (only in the defocused base view).
static float window_disc(float2 q, float2 c, float r, float aa, float2 cat) {
    float s = max(0.16f, aa / r);
    float d = length(q - c) / r;
    if (d > 1.0f + s) return 0.0f;
    float m = 1.0f - smoothstep(1.0f - s, 1.0f + 0.3f * s, d);
    float d2 = length(q - c - cat) / r;
    m = min(m, 1.0f - smoothstep(1.0f - s, 1.0f + 0.3f * s, d2));
    // faint onion rings and a brighter rim, as aspheric lens elements leave
    float ring = 1.0f + 0.05f * sin(d * 23.0f + c.x * 40.0f) * (1.0f - s);
    return m * (0.80f + 0.30f * d * d * d) * ring;
}

// Light colour picker shared by the scattered city lights (teal only on the
// small far ones: on a big disc it reads as a muddy green smudge).
static float3 window_light_color(float h, int layer) {
    if (layer == 0) return h < 0.45f ? WIN_SODIUM : (h < 0.75f ? WIN_WARM : (h < 0.93f ? WIN_COOL : WIN_TEAL));
    return h < 0.55f ? WIN_SODIUM : (h < 0.80f ? WIN_WARM : (h < 0.94f ? WIN_COOL : WIN_RED));
}

// Scattered city lights on a jittered grid. Layer 0: far windows and streets
// near the horizon; layer 1: bigger, nearer lights around street level.
static float3 window_light_grid(float2 q, float f, float bq, thread const WinCtx& c, int layer,
                                WinRow farRow, WinRow nearRow) {
    float C  = layer == 0 ? 0.030f : 0.085f;
    float rb = layer == 0 ? 0.014f : 0.046f;   // defocused radius (before per-light depth scale)
    float rs = layer == 0 ? 0.0010f : 0.0016f; // radius of the sharp image in a drop
    uint salt = layer == 0 ? 301u : 302u;
    float aa = max(bq, 1e-4f);
    float2 cat = f > 0.5f ? -q / max(c.halfW, 0.5f) * 0.45f : float2(0.0f);
    int2 g = int2(floor(q / C));
    float3 acc = 0.0f;
    for (int j = -1; j <= 1; ++j)
    for (int i = -1; i <= 1; ++i) {
        int2 cell = g + int2(i, j);
        float3 h = hash3(cell, c.seed + salt);
        float2 pos = (float2(cell) + 0.1f + 0.8f * h.xy) * C;
        float prob;
        if (layer == 0) {
            float farTop  = window_row_top(int(floor(pos.x / farRow.w)), farRow, c.seed);
            float nearTop = window_row_top(int(floor(pos.x / nearRow.w)), nearRow, c.seed);
            prob = (pos.y < farTop - 0.008f && pos.y > nearTop - 0.01f) ? 0.50f : 0.0f;
            prob = max(prob, (pos.y < nearTop - 0.015f && pos.y > c.ys + 0.01f) ? 0.20f : 0.0f);
        } else {
            prob = pos.y < c.ys + 0.05f ? mix(0.34f, 0.10f, saturate((c.ys - pos.y) / 0.25f)) : 0.0f;
        }
        if (h.z >= prob) continue;
        float3 h2 = hash3(cell, c.seed + salt + 11u);
        float rd = rb * mix(0.6f, 1.25f, h2.x);             // depth: nearer lights blur more
        float rr = max(mix(rs, rd, f), bq);
        float gain = min((rd * rd) / (rr * rr), 9.0f);
        float I = (layer == 0 ? 0.26f : 0.50f) * (0.05f + 0.95f * h2.z * h2.z * h2.z);
        // a few far lights slowly dim and return (4-6 times per loop, exact)
        if (layer == 0 && fract(h2.x * 31.7f) < 0.06f) {
            float n = 4.0f + floor(fract(h2.z * 17.3f) * 2.999f);
            I *= mix(0.12f, 1.0f, 0.5f + 0.5f * cos(TAU * (n * c.t / c.L + h.x)));
        }
        // discs centred below the frame only show a clipped smudge: drop them
        if (f > 0.5f) I *= smoothstep(-0.54f, -0.49f, pos.y);
        acc += window_light_color(h2.y, layer) * I * gain
             * window_disc(q, pos, rr, aa, cat * rr);
    }
    return acc;
}

// Street lamps along the far kerb, cars on the wet road, and their streaky
// reflections in the asphalt.
static float3 window_street(float2 q, float f, float bq, float b, thread const WinCtx& c) {
    float3 acc = 0.0f;
    float aa = max(bq, 1e-4f);
    float2 cat = f > 0.5f ? -q / max(c.halfW, 0.5f) * 0.45f : float2(0.0f);
    const float sp = 0.21f;
    int k0 = int(floor(q.x / sp));
    float refl = exp(-max(c.ys - q.y, 0.0f) / 0.07f) * (1.0f - smoothstep(c.ys - b, c.ys + b, q.y));
    float ripple = mix(1.0f, 0.55f + 0.9f * vnoise2(float2(q.x * 30.0f, q.y * 140.0f), c.seed + 9u), 1.0f - smoothstep(0.002f, 0.01f, b));
    refl *= ripple;
    for (int k = k0 - 1; k <= k0 + 1; ++k) {
        float3 h = hash3(int2(k, 77), c.seed);
        // landscape shows ~9 lamps across: break the even string of pearls
        // with gaps, wider jitter and a few nearer, bigger lamps
        if (h.z < (c.portrait ? 0.22f : 0.40f)) continue;
        float3 h2 = hash3(int2(k, 78), c.seed);
        float jit = c.portrait ? 0.5f : 0.9f, yv = c.portrait ? 0.07f : 0.12f;
        float2 pos = float2((float(k) + 0.5f + (h.x - 0.5f) * jit) * sp, c.ys + 0.035f + yv * h.y);
        float3 lc = h2.x < 0.3f ? WIN_COOL : WIN_SODIUM;
        float rd = 0.055f * (c.portrait ? mix(0.65f, 1.15f, h2.y) : mix(0.55f, 1.6f, h2.y * h2.y));
        float rr = max(mix(0.0018f, rd, f), bq);
        float gain = min(rd * rd / (rr * rr), 9.0f);
        acc += lc * mix(0.25f, 0.65f, h2.z) * gain * window_disc(q, pos, rr, aa, cat * rr);
        // reflection: a soft vertical streak on the wet road
        float wr = max(0.007f, b * 0.9f);
        float dx = (q.x - pos.x) / wr;
        acc += lc * 0.10f * refl * exp(-dx * dx);
    }
    // cars: exactly periodic, crossing the whole view n times per loop
    float span = 2.0f * c.halfW + 0.5f;
    for (int j = 0; j < 4; ++j) {
        float3 h = hash3(int2(j, 91), c.seed);
        bool toward = (j & 1) == 0;                       // headlights vs tail lights
        float n = float(1 + (j >> 1));
        float x = fract(n * c.t / c.L + h.x) * span - 0.5f * span;
        if (!toward) x = -x;
        float y = c.ys - (toward ? 0.045f : 0.085f) - 0.01f * h.y;
        float3 lc = toward ? WIN_WARM * float3(1.0f, 1.05f, 1.15f) : WIN_RED;
        float I = toward ? 0.55f : 0.40f;
        float half_ = toward ? 0.010f : 0.013f;
        float rr = max(mix(0.0015f, 0.040f, f), bq);
        float gain = min(0.04f * 0.04f / (rr * rr), 9.0f);
        acc += lc * I * gain * (window_disc(q, float2(x - half_, y), rr, aa, cat * rr)
                              + window_disc(q, float2(x + half_, y), rr, aa, cat * rr));
        float wr = max(0.010f, b);
        float dx = (q.x - x) / wr;
        float below = exp(-max(y - q.y, 0.0f) / 0.05f) * (1.0f - smoothstep(y - b, y + b, q.y)) * ripple;
        acc += lc * I * 0.15f * below * exp(-dx * dx);
    }
    // landscape: two big dim lights very near the window, for depth
    if (!c.portrait && f > 0.5f) {
        acc += WIN_SODIUM * 0.15f * window_disc(q, float2(-0.30f * c.halfW * 2.0f, -0.36f), 0.115f, aa, cat * 0.115f);
        acc += WIN_WARM * 0.11f * window_disc(q, float2(0.36f * c.halfW * 2.0f, -0.31f), 0.095f, aa, cat * 0.095f);
    }
    return acc;
}

// ------------------------------------------------------------------ the sky

static float window_bolt_x(float y, float x0, float ytop, uint k, uint seed) {
    float s = float(k) * 7.31f;
    float2 r = rand2(k, 63u, seed);
    float lean = (0.03f + 0.09f * r.x) * (r.y < 0.5f ? -1.0f : 1.0f);
    return x0 + lean * (ytop - y)
         + 0.045f * window_jag(y * 4.0f + s, 21u, seed)
         + 0.020f * window_jag(y * 6.0f + s, 25u, seed)
         + 0.040f * window_jag(y * 11.0f + s, 22u, seed)
         + 0.013f * window_jag(y * 29.0f + s, 23u, seed)
         + 0.005f * window_jag(y * 71.0f + s, 24u, seed);
}

// Brightness of a channel x = path(y) at q: thin energy-conserving core plus a
// soft glow that the rain haze spreads around it. Only the core is measured
// across the (piecewise constant) slope; the wide glow uses plain |dx| so the
// slope jumps at the path's kinks cannot print horizontal seams into it.
static float window_channel(float dx, float slope, float b) {
    float d = abs(dx) / sqrt(1.0f + slope * slope);
    float w = max(0.0008f, b);
    return (0.0008f / w) * exp(-(d * d) / (w * w)) + 0.05f * exp(-abs(dx) / (0.012f + b));
}

static float window_bolt(float2 q, float b, uint k, float2 top, float ybot, uint seed) {
    if (q.y > top.y + 0.06f || q.y < ybot) return 0.0f;
    float x = window_bolt_x(q.y, top.x, top.y, k, seed);
    if (abs(q.x - x) > 0.25f + 12.0f * (0.012f + b)) return 0.0f;
    float sl = (window_bolt_x(q.y + 0.002f, top.x, top.y, k, seed) - window_bolt_x(q.y - 0.002f, top.x, top.y, k, seed)) / 0.004f;
    // the channel thins and dims toward the ground and fades into the cloud
    float taper = mix(0.6f, 1.0f, saturate((q.y - ybot) / max(top.y - ybot, 1e-3f)));
    float v = window_channel(q.x - x, sl, b * taper) * taper * smoothstep(top.y + 0.06f, top.y - 0.03f, q.y);
    // branches peeling off the main channel, the odd one forking again
    int nb = 3 + int(rand1(k, 60u, seed) * 1.999f);
    for (int j = 0; j < nb; ++j) {
        float3 r = rand3(k * 8u + uint(j), 61u, seed);
        float yb = top.y - (0.10f + 0.5f * r.x) * (top.y - ybot);
        float len = (0.35f + 0.35f * r.y) * (yb - ybot);
        if (q.y > yb || q.y < yb - len) continue;
        float dir = r.z < 0.5f ? -1.0f : 1.0f;
        float xb0 = window_bolt_x(yb, top.x, top.y, k, seed);
        float xb = xb0 + dir * (yb - q.y) * (0.3f + 0.4f * r.y)
                 + 0.012f * window_jag(q.y * 18.0f + float(j) * 3.3f, 31u + uint(j), seed)
                 + 0.004f * window_jag(q.y * 47.0f + float(j) * 3.3f, 41u + uint(j), seed);
        float tip = 1.0f - (yb - q.y) / len;
        float on = smoothstep(yb, yb - 0.015f, q.y);   // joins the main channel without a seam
        v += 0.75f * on * tip * window_channel(q.x - xb, 0.5f, b * mix(0.7f, 1.0f, tip));
        float rs = rand1(k * 8u + uint(j), 62u, seed);
        if (rs < 0.5f) {
            float ys = yb - (0.3f + 0.3f * rs) * len, ls = 0.45f * len;
            if (q.y < ys && q.y > ys - ls) {
                float xs0 = xb0 + dir * (yb - ys) * (0.3f + 0.4f * r.y)
                          + 0.012f * window_jag(ys * 18.0f + float(j) * 3.3f, 31u + uint(j), seed)
                          + 0.004f * window_jag(ys * 47.0f + float(j) * 3.3f, 41u + uint(j), seed);
                float xs = xs0 - dir * (ys - q.y) * 0.5f + 0.006f * window_jag(q.y * 30.0f + float(j), 51u, seed);
                float ts = 1.0f - (ys - q.y) / ls;
                v += 0.5f * smoothstep(ys, ys - 0.01f, q.y) * ts * ts * tip * window_channel(q.x - xs, 0.5f, b);
            }
        }
    }
    return v;
}

static float3 window_sky(float2 q, float b, thread const WinCtx& c) {
    float h = q.y - c.hz;
    float3 zen = float3(0.0090f, 0.0120f, 0.0230f);
    float3 mid = float3(0.0200f, 0.0240f, 0.0380f);
    float3 hor = float3(0.0520f, 0.0440f, 0.0500f);
    float3 base = mix(hor, mid, smoothstep(0.0f, 0.22f, h));
    base = mix(base, zen, smoothstep(0.18f, 0.65f, h));

    // Storm cloud deck, evolving in place: one lattice cell of z per loop.
    float z = c.t / c.L;
    float n = window_fbm_blur(float3(q.x * 1.5f, q.y * 2.7f, z), 1, b * 2.0f, c.seed + 5u);
    float d = smoothstep(-0.45f, 0.6f, n);
    float3 col = base * (0.22f + 1.7f * d * d);
    col += float3(0.030f, 0.019f, 0.016f) * d * d * smoothstep(0.40f, 0.02f, h);   // city glow on cloud bellies

    for (int i = 0; i < c.nf; ++i) {
        float2 dv = (q - c.fpos[i]) * float2(0.75f, 1.25f);
        float lit = c.fsky[i] * (0.02f + 1.0f * exp(-length(dv) / 0.20f));
        col += WIN_FLASH * lit * (0.02f + 1.6f * d * d);
        if (c.fbolt[i] > 1e-3f) {
            float v = window_bolt(q, b * 0.28f, c.fk[i], c.fpos[i] + float2(0.002f * c.fshift[i], 0.0f), c.hz - 0.03f, c.seed);
            col += WIN_FLASH * float3(0.95f, 0.97f, 1.0f) * v * c.fbolt[i] * 14.0f;
        }
    }
    return col;
}

// Rain falling between the window and the city, far out of focus: soft slanted
// streaks that only show where they catch the street light. Each layer falls a
// whole number of repeats per loop, so it is exactly periodic.
static float window_rain(float2 q, float b, thread const WinCtx& c) {
    float acc = 0.0f;
    for (int k = 0; k < 2; ++k) {
        float cw  = k == 0 ? 0.011f : 0.019f;
        float rep = k == 0 ? 0.55f : 0.85f;
        float len = k == 0 ? 0.11f : 0.18f;
        float v   = max(1.0f, round((k == 0 ? 1.1f : 1.5f) * c.L / rep)) * rep / c.L;
        float2 r = float2(q.x + 0.10f * q.y, q.y);
        float col = floor(r.x / cw);
        float3 h = hash3(int2(int(col), 900 + k), c.seed);
        if (h.z > 0.40f) continue;
        float dx = (fract(r.x / cw) - (0.2f + 0.6f * h.x)) * cw;
        float ly = fract((r.y + c.t * v) / rep + h.y) * rep;
        float along = ly / len;
        float body = smoothstep(0.0f, 0.15f, along) * (1.0f - smoothstep(0.35f, 1.0f, along));
        float w = max(0.0015f, b * 0.28f);
        acc += body * exp(-dx * dx / (w * w)) * (0.0030f / w) * (k == 0 ? 0.7f : 1.0f);
    }
    return acc;
}

// --------------------------------------------------------- whole background

// The scene behind the glass. f = 1 is the defocused base view, f = 0 the sharp
// image inside a drop; bq is the sample footprint (for prefiltering).
static float3 window_bg(float2 q, float f, float bq, thread const WinCtx& c) {
    float b = max(mix(0.0012f, WIN_DEFOCUS, f), bq);
    float3 col = window_sky(q, b, c);

    WinRow farRow  = {0.048f, c.hz, 0.015f, 0.10f, 0.14f, 401u};
    WinRow nearRow = {0.115f, c.yn, -0.04f, 0.035f, 0.0f, 402u};

    // far row: hazy towers, a touch of horizon glow on them
    int cf;
    float mf = window_row_mask(q, farRow, b, c.seed, cf);
    float3 farC = float3(0.011f, 0.014f, 0.022f) + float3(0.012f, 0.009f, 0.008f) * smoothstep(c.hz + 0.12f, c.hz - 0.06f, q.y);
    farC += window_facade_lights(q, farRow, cf, 0.0065f, 0.0085f, b, c.seed) * 0.6f;
    farC += WIN_FLASH * c.flash * 0.003f;
    col = mix(col, farC, mf);
    // soft red aviation lights on the tall towers, one slow blink every 2 s
    for (int k = cf - 1; k <= cf + 1; ++k) {
        float3 ht = hash3(int2(k, int(farRow.salt)), c.seed);
        float3 hb = hash3(int2(k, 450), c.seed);
        if (ht.y >= farRow.tall || hb.x > 0.7f) continue;
        float2 pos = float2((float(k) + 0.5f) * farRow.w, window_row_top(k, farRow, c.seed) + 0.004f);
        float ph = fract(c.t * 20.0f / c.L + hb.y) - 0.2f;
        float pulse = exp(-ph * ph / 0.012f);
        float rr = max(mix(0.0010f, 0.010f, f), bq);
        float gain = min(0.010f * 0.010f / (rr * rr), 9.0f);
        col += WIN_RED * 0.30f * pulse * gain * window_disc(q, pos, rr, max(bq, 1e-4f), float2(0.0f));
    }

    // near row: dark rooftops across the street
    int cn;
    float mn = window_row_mask(q, nearRow, b, c.seed, cn);
    float3 nearC = float3(0.0040f, 0.0048f, 0.0078f) + WIN_SODIUM * 0.006f * smoothstep(c.yn - 0.08f, c.ys, q.y);
    nearC += window_facade_lights(q, nearRow, cn, 0.0110f, 0.0150f, b, c.seed);
    nearC += WIN_FLASH * c.flash * 0.0015f;
    col = mix(col, nearC, mn);

    // street: wet asphalt picking up the sodium glow
    float ms = 1.0f - smoothstep(c.ys - b, c.ys + b, q.y);
    float3 road = float3(0.0060f, 0.0065f, 0.0090f) + WIN_SODIUM * 0.012f * exp(-(c.ys - q.y) / 0.12f);
    col = mix(col, road, ms);

    // emitters
    col += window_light_grid(q, f, bq, c, 0, farRow, nearRow);
    col += window_light_grid(q, f, bq, c, 1, farRow, nearRow);
    col += window_street(q, f, bq, b, c);
    // rain haze glowing over the lit streets, and the rain itself catching it
    float glow = exp(-abs(q.y - c.ys - 0.04f) / 0.10f);
    col += WIN_SODIUM * 0.020f * glow;
    float3 rainLight = mix(float3(0.10f, 0.11f, 0.14f), WIN_SODIUM * 0.35f, glow) + WIN_FLASH * c.flash * 0.10f;
    col += rainLight * (0.05f + glow) * window_rain(q, b, c) * f;
    return col;
}

// ---------------------------------------------------------------- the glass

// One sliding drop per lane per loop: it gathers at y0, then slides down in
// stop-and-go surges along a wandering path and leaves a wet trail.
struct WinLane {
    float x0, ts, y0, R0, V, send;
    float ps[4], pd[4];
    float s;      // head travel now (< 0 when not sliding)
    float grow;   // 0..1 size of the gathering drop before it slides (0 = absent)
    float spd;    // current speed
    uint  id;
    bool  on;
};

static float window_tau(thread const WinLane& ln, float s) {
    float tau = s / ln.V;
    for (int j = 0; j < 4; ++j) tau += ln.pd[j] * smoothstep(ln.ps[j] - 0.012f, ln.ps[j] + 0.012f, s);
    return tau;
}

static float window_path_x(thread const WinLane& ln, float y, uint seed) {
    float s = float(ln.id & 1023u) * 3.17f;
    return ln.x0 + 0.016f * window_n1(y * 4.0f + s, 1u, seed)
                 + 0.006f * window_n1(y * 13.0f + s, 2u, seed)
                 + 0.0022f * window_n1(y * 37.0f + s, 3u, seed);
}

static float window_lane_R(thread const WinLane& ln, float s) { return ln.R0 * (1.0f + 0.25f * saturate(s)); }

// Lane parameters; with `head` also where its drop is right now (only lanes
// that are drawn need that, sweep tests use the schedule alone).
static WinLane window_lane(int i, bool head, thread const WinCtx& c) {
    WinLane ln;
    uint k = uint(i + 100000);
    float3 a = rand3(k, 101u, c.seed), b = rand3(k, 102u, c.seed);
    ln.id = k;
    // The four central lanes (all of the portrait safe zone) always carry a
    // drop, further out about a third do. Neighbouring lanes start 0.27 L
    // apart, so in portrait a slide begins every ~11 s and the slides spread
    // over the loop instead of bunching.
    ln.on = (i >= -2 && i <= 1) || a.x < 0.35f;
    ln.x0 = (float(i) + 0.5f + (a.y - 0.5f) * 0.35f) * WIN_LANE_W;
    ln.ts = fract(float(i) * 0.27f + 0.10f * (a.z - 0.5f) + 0.5f) * c.L;
    ln.y0 = mix(-0.15f, 0.50f, b.x);
    ln.R0 = mix(0.011f, 0.026f, b.y * b.y);   // the odd big drop is an event
    ln.V  = mix(0.04f, 0.12f, b.z) * mix(1.0f, 0.75f, b.y * b.y);
    ln.send = ln.y0 + 0.56f;
    for (int j = 0; j < 4; ++j) {
        float2 r = rand2(k, 110u + uint(j), c.seed);
        ln.ps[j] = (float(j) + 0.2f + 0.6f * r.x) * ln.send / 4.0f;
        ln.pd[j] = 3.5f * r.y * r.y;
    }
    ln.s = -1.0f; ln.grow = 0.0f; ln.spd = 0.0f;
    if (!head || !ln.on) return ln;
    // where the head is now: invert tau(s) by bisection
    float tn = since_event(c.t, ln.ts, c.L);
    float tend = window_tau(ln, ln.send);
    const float pre = 6.0f;
    if (tn < tend) {
        float lo = 0.0f, hi = ln.send;
        for (int it = 0; it < 15; ++it) {
            float mid = 0.5f * (lo + hi);
            if (window_tau(ln, mid) < tn) lo = mid; else hi = mid;
        }
        ln.s = 0.5f * (lo + hi);
        float e = 0.003f;
        ln.spd = 2.0f * e / max(window_tau(ln, ln.s + e) - window_tau(ln, max(ln.s - e, 0.0f)), 1e-3f);
    } else if (tn > c.L - pre) {
        ln.grow = (tn - (c.L - pre)) / pre;
    }
    return ln;
}

// kind: 1 bead, 2 sliding head, 3 wet film, 4 head gathering before its slide
struct WinHit { float h; float2 e; float R; float2 c; int kind; float a; };

// Is a static bead at cp (radius r) currently wiped away by a lane's slide?
// delay = seconds after the head passes before a fresh bead lands there again.
static bool window_swept(float2 cp, float r, float delay, thread const WinLane* lanes, int i0, thread const WinCtx& c) {
    int j = int(floor(cp.x / WIN_LANE_W));
    for (int k = j - 1; k <= j + 1; ++k) {
        int idx = k - i0;
        if (idx < 0 || idx > 4) continue;
        thread const WinLane& ln = lanes[idx];
        if (!ln.on) continue;
        float sp = ln.y0 - cp.y;
        if (sp < -ln.R0 || sp > ln.send) continue;
        float sx = max(sp, 0.0f);
        float R = window_lane_R(ln, sx);
        if (abs(cp.x - window_path_x(ln, cp.y, c.seed)) > 0.85f * R + 0.6f * r) continue;
        float age = since_event(c.t, ln.ts + window_tau(ln, sx), c.L);
        if (age < delay) return true;
    }
    return false;
}

// One layer of static beads: at most one bead per (rotated) grid cell, kept
// inside its cell so no neighbour search is needed.
//
// Rain keeps landing: with `regen` set, each cell is hit twice per loop at
// random times, and every hit replaces its bead with a fresh one (a new drop
// landing, or two merging) that splashes in over a few frames.
static void window_beads(thread WinHit& hit, float2 p, float C, float rmin, float rmax, float prob, bool regen,
                         float ang, float2 off, uint salt, float pxs,
                         thread const WinLane* lanes, int i0, thread const WinCtx& c) {
    float2x2 m = rot2(ang);
    float2 pr = m * p + off;
    int2 cell = int2(floor(pr / C));
    float2 cw = (float2(cell) + 0.5f) * C;
    uint gen = 0u;
    float splash = 1.0f;
    if (regen) {
        float3 ht = hash3(cell, c.seed + salt + 13u);
        float a1 = since_event(c.t, ht.x * c.L, c.L);
        float a2 = since_event(c.t, (ht.x + mix(0.3f, 0.7f, ht.y)) * c.L, c.L);
        gen = a1 < a2 ? 1u : 2u;
        splash = smoothstep(0.0f, 0.10f, min(a1, a2));
    }
    float3 h = hash3(cell, c.seed + salt + gen * 0x632BE5ABu);
    // rain lands unevenly: a slow density field clusters the beads
    float dens = vnoise2(cw * 7.0f + float2(float(salt), 0.0f), c.seed + 3u);
    if (h.x > prob * mix(0.35f, 1.55f, dens)) return;
    float r = mix(rmin, rmax, h.y * h.y) * mix(0.55f, 1.0f, splash);
    float3 h2 = hash3(cell, c.seed + salt + 7u + gen * 0x632BE5ABu);
    float marg = r / C + 0.03f;
    float2 cc = (float2(cell) + marg + (1.0f - 2.0f * marg) * h2.xy) * C;
    float2 d = (pr - cc) * m;                      // back to glass axes
    // gravity: bigger beads sag, flatter on top, fuller at the bottom
    float sag = smoothstep(0.003f, 0.02f, r) * 0.10f;
    float2 e = float2(d.x / r, d.y / (r * (d.y > 0.0f ? 1.0f - sag : 1.0f + sag * 0.6f)));
    if (r > 0.005f) {
        // merged drops are not circles: wobble the outline with two low harmonics
        float a = atan2(d.y, d.x), ph = h2.z * TAU;
        float k = smoothstep(0.005f, 0.014f, r);
        e /= 1.0f + k * (0.06f * sin(2.0f * a + ph) + 0.03f * sin(3.0f * a + 2.1f * ph));
    }
    float aa = 1.2f * pxs;
    float rho = length(e);
    if (rho > 1.0f + aa / r) return;
    float hh = r * sqrt(max(0.0f, 1.0f - rho * rho));
    if (hh <= hit.h) return;
    float2 cp = (cc - off) * m;
    if (window_swept(cp, r, mix(1.5f, 30.0f, h2.z), lanes, i0, c)) return;
    hit.h = hh; hit.e = e; hit.R = r; hit.c = cp; hit.kind = 1;
    hit.a = saturate(0.5f + (1.0f - rho) * r / aa);
}

// Head drop, wet film and the beads the film breaks into, for one lane.
static void window_lane_draw(thread WinHit& hit, thread float& clear, float2 p, thread const WinLane& ln,
                             float pxs, thread const WinCtx& c) {
    if (!ln.on) return;
    float aa = 1.2f * pxs;
    if (ln.s >= 0.0f || ln.grow > 0.0f) {
        float s = max(ln.s, 0.0f);
        float R = ln.s >= 0.0f ? window_lane_R(ln, s) : ln.R0 * mix(0.45f, 1.0f, ln.grow);
        float yc = ln.y0 - s, xc = window_path_x(ln, yc, c.seed);
        float2 d = p - float2(xc, yc);
        float tail = ln.s >= 0.0f ? mix(0.3f, 1.7f, saturate(ln.spd / 0.12f)) : 0.15f;
        if (abs(d.x) < 2.0f * R && d.y > -1.5f * R && d.y < (1.0f + tail) * R + 0.01f) {
            if (d.y > 0.0f) d.x -= window_path_x(ln, p.y, c.seed) - xc;   // tail follows the path
            float ay = d.y > 0.0f ? R * (1.0f + tail) : R * 0.92f;
            float u = saturate(d.y / ay);
            float ax = R * (1.0f - 0.6f * u * u);
            float2 e = float2(d.x / ax, d.y / ay);
            float rho = length(e);
            if (rho < 1.0f + aa / R) {
                float hh = 1.0f + R * sqrt(max(0.0f, 1.0f - rho * rho));   // always on top
                if (hh > hit.h) {
                    hit.h = hh; hit.e = e; hit.R = R; hit.c = float2(xc, yc); hit.kind = ln.s >= 0.0f ? 2 : 4;
                    hit.a = saturate(0.5f + (1.0f - rho) * R / aa);
                }
            }
        }
    }
    float sp = ln.y0 - p.y;
    if (sp < 0.0f || sp > ln.send) return;
    float px = window_path_x(ln, p.y, c.seed);
    if (abs(p.x - px) > 1.1f * ln.R0 * 1.25f + 0.004f) return;
    float R = window_lane_R(ln, sp);
    float age = since_event(c.t, ln.ts + window_tau(ln, sp), c.L);
    // fresh film: a ragged ribbon that narrows as it beads up (so it tapers
    // toward the older top end)
    float film = 1.0f - smoothstep(1.0f, 4.0f, age);
    float w = 0.33f * R * mix(0.55f, 1.0f, film) * (1.0f + 0.22f * window_n1(p.y * 25.0f + float(ln.id & 255u), 5u, c.seed));

    // the wiped strip stays clear of mist for a short while
    float inStrip = 1.0f - smoothstep(0.2f * R, 1.0f * R, abs(p.x - px));
    clear = max(clear, 0.35f * inStrip * (1.0f - smoothstep(1.5f, 9.0f, age)));

    if (film > 0.0f && abs(p.x - px) < w + aa) {
        float hh = 0.0002f * film;
        if (hh > hit.h) {
            hit.h = hh; hit.e = float2((p.x - px) / w, 0.0f); hit.R = w; hit.c = float2(px, p.y);
            hit.kind = 3; hit.a = film * saturate(0.5f + (w - abs(p.x - px)) / aa);
        }
    }

    // beads left behind by the film
    const float D = 0.0075f;
    int j0 = int(floor(sp / D));
    for (int j = j0 - 1; j <= j0 + 1; ++j) {
        float3 h = rand3(ln.id * 4096u + uint(j + 2048), 71u, c.seed);
        if (h.x > 0.85f) continue;
        float sc = (float(j) + 0.5f + (h.y - 0.5f) * 0.6f) * D;
        if (sc < 0.0f || sc > ln.send) continue;
        float3 h2 = rand3(ln.id * 4096u + uint(j + 2048), 72u, c.seed);
        float ac = since_event(c.t, ln.ts + window_tau(ln, sc), c.L);
        float tb = 0.4f + 1.5f * h2.x;
        float r = mix(0.0010f, 0.0045f, h2.y * h2.y) * smoothstep(tb, tb + 0.6f, ac);
        if (r < 0.0002f) continue;
        float yc = ln.y0 - sc;
        float2 cc = float2(window_path_x(ln, yc, c.seed) + (h2.z - 0.5f) * 0.55f * ln.R0, yc);
        float2 e = (p - cc) / r;
        float rho = length(e);
        if (rho > 1.0f + aa / r) continue;
        float hh = r * sqrt(max(0.0f, 1.0f - rho * rho));
        if (hh <= hit.h) continue;
        hit.h = hh; hit.e = e; hit.R = r; hit.c = cc; hit.kind = 1;
        hit.a = saturate(0.5f + (1.0f - rho) * r / aa);
    }
}

// The background averaged horizontally: what a bead too small to resolve an
// image shows (a vertical, inverted smear of sky, city glow and street).
static float3 window_scene_mean(float qy, thread const WinCtx& c) {
    float h = qy - c.hz;
    float3 sky = mix(float3(0.0520f, 0.0440f, 0.0500f), float3(0.0200f, 0.0240f, 0.0380f), smoothstep(0.0f, 0.22f, h));
    sky = mix(sky, float3(0.0090f, 0.0120f, 0.0230f), smoothstep(0.18f, 0.65f, h)) * 0.75f;
    for (int i = 0; i < c.nf; ++i)
        sky += WIN_FLASH * c.fsky[i] * (0.05f + 0.35f * exp(-abs(qy - c.fpos[i].y) / 0.2f));
    float3 city = float3(0.010f, 0.011f, 0.016f) + WIN_SODIUM * 0.014f + WIN_WARM * 0.008f;
    float3 street = float3(0.008f, 0.008f, 0.010f) + WIN_SODIUM * 0.030f + WIN_WARM * 0.015f;
    float3 col = mix(sky, city, smoothstep(c.hz + 0.06f, c.hz - 0.03f, qy));
    return mix(col, street, smoothstep(c.ys + 0.08f, c.ys - 0.02f, qy));
}

// Colour of a drop: the scene seen through it as an inverted fisheye image,
// sharp in big drops and averaged in small beads, dark at the steep edges,
// with light gathered along the bottom contour.
static float3 window_drop_color(thread const WinHit& hit, float3 base, float3 veil, float pxs, thread const WinCtx& c) {
    float2 e = hit.e;
    float rho2 = dot(e, e), rho = sqrt(rho2);
    float2 n = e * 0.93f;
    float nz = sqrt(max(1e-4f, 1.0f - dot(n, n)));
    float2 lens = n / (0.45f + 0.55f * nz);
    float2 qc = float2(hit.c.x * 0.35f, c.hz - 0.02f + hit.c.y * 0.12f);
    float2 q = qc - WIN_FOV * lens;
    float bq = WIN_FOV * pxs / hit.R * (1.2f + 3.0f * rho2);
    float ws = smoothstep(0.0025f, 0.010f, hit.R);
    // small beads mostly pass the local colour (a bead on a bokeh disc is
    // clear, not a dark hole); bigger ones hold the averaged inverted scene
    float big = smoothstep(0.0035f, 0.0080f, hit.R);
    // (plus the faint room reflection the misted glass around them also has,
    // or every bead would print as a dark freckle on the night sky)
    float3 img = mix(base * 1.05f + veil, window_scene_mean(q.y, c) * 0.8f + base * 0.35f + 0.4f * veil, big);
    if (ws > 0.0f) img = mix(img, window_bg(q, 0.0f, bq, c) * 0.8f + base * 0.30f, ws);
    // dark band where the steep rim refracts the unlit room: thin and light on
    // small beads, deep on big drops
    float rb = smoothstep(0.003f, 0.010f, hit.R);
    img *= mix(1.0f, mix(0.65f, 0.18f, rb), smoothstep(mix(0.80f, 0.66f, rb), 0.97f, rho));
    // light gathered along the lower contour, a thin catch on the rest of it.
    // A lightning flash flares every drop: a cold crescent along the bottom
    // (sky light focused by the drop), strongest on drops near the strike.
    float fl = 0.0f;
    for (int i = 0; i < c.nf; ++i) fl += c.fsky[i] * exp(-abs(hit.c.x - c.fpos[i].x) / 0.4f);
    float rimw = max(1.5f * pxs / hit.R, 0.07f);
    float rim = exp(-pow((1.0f - rho) / rimw, 2.0f));
    float low = smoothstep(0.1f, -0.7f, e.y);
    float3 col = img + rim * (0.35f + mix(1.6f, 0.9f, rb) * low) * base * 1.2f
                     + rim * (0.02f + 0.30f * low) * WIN_FLASH * fl * 0.30f;
    float spec = exp(-dot(e - float2(-0.30f, 0.45f), e - float2(-0.30f, 0.45f)) / 0.018f);
    col += spec * (ws * float3(0.018f, 0.020f, 0.026f) + WIN_FLASH * fl * 0.30f * mix(0.4f, 1.0f, ws));
    return col;
}

// ---------------------------------------------------------------- the kernel

kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float2 p = frame_uv(gid, u.resolution);
    float pxs = px_size(u.resolution);
    bool portrait = is_portrait(u.resolution);

    WinCtx c;
    c.t = u.time; c.L = u.loop; c.seed = u.seed;
    c.halfW = 0.5f * aspect_of(u.resolution);
    c.hz = portrait ? -0.06f : -0.05f;
    c.yn = c.hz - 0.10f;
    c.ys = c.hz - 0.24f;
    c.xspread = min(0.7f, safe_extent(u.resolution).x - 0.03f);
    c.portrait = portrait;
    window_lightning(c);

    // lanes around this pixel (pixel lane +-2, enough for any sweep test)
    int li = int(floor(p.x / WIN_LANE_W));
    int i0 = li - 2;
    WinLane lanes[5];
    for (int k = 0; k < 5; ++k) lanes[k] = window_lane(i0 + k, k >= 1 && k <= 3, c);

    WinHit hit; hit.h = -1.0f; hit.kind = 0; hit.a = 0.0f; hit.e = 0.0f; hit.R = 1.0f; hit.c = 0.0f;
    float clear = 0.0f;
    window_beads(hit, p, 0.0062f, 0.0006f, 0.0018f, p.y > c.hz ? 0.32f : 0.45f, true,  0.21f, float2(0.13f, 0.71f), 501u, pxs, lanes, i0, c);
    window_beads(hit, p, 0.0130f, 0.0012f, 0.0040f, 0.45f, true,  1.10f, float2(0.37f, 0.19f), 502u, pxs, lanes, i0, c);
    window_beads(hit, p, 0.0170f, 0.0018f, 0.0055f, 0.55f, true, -0.37f, float2(0.52f, 0.33f), 503u, pxs, lanes, i0, c);
    window_beads(hit, p, 0.0420f, 0.0040f, 0.0120f, 0.50f, true,  0.53f, float2(0.11f, 0.47f), 504u, pxs, lanes, i0, c);
    window_beads(hit, p, 0.1000f, 0.0080f, 0.0190f, 0.32f, false, -0.11f, float2(0.29f, 0.83f), 505u, pxs, lanes, i0, c);
    for (int k = 1; k <= 3; ++k) window_lane_draw(hit, clear, p, lanes[k], pxs, c);

    // base view through misted glass
    float3 base = window_bg(p, 1.0f, pxs, c);
    float mist = 1.0f - clear;
    float3 veil = float3(0.010f, 0.011f, 0.015f) + WIN_FLASH * c.flash * 0.004f;
    float3 col = base * (1.0f - 0.10f * mist) + veil * mist;

#ifdef WIN_DEBUG_HEADS
    // test hook: sliding heads magenta, gathering heads green
    if (hit.kind == 2) { out.write(float4(1, 0, 1, 1), gid); return; }
    if (hit.kind == 4) { out.write(float4(0, 1, 0, 1), gid); return; }
#endif
    if (hit.kind == 1 || hit.kind == 2 || hit.kind == 4) {
        col = mix(col, window_drop_color(hit, base, veil, pxs, c), hit.a);
    } else if (hit.kind == 3) {
        float ex = hit.e.x;
        // a water film is a weak lens: slightly brighter than the glass, with a
        // soft catch of light along both edges
        float edge = exp(-pow((abs(ex) - 0.78f) / 0.16f, 2.0f));
        col = mix(col, base * (1.08f + 0.10f * (1.0f - ex * ex)) + veil * (0.6f + 1.6f * edge)
                       + base * edge * (ex > 0.0f ? 0.35f : 0.20f), hit.a);
    }

    // lens: gentle vignette, exposure
    float2 vq = p / float2(max(c.halfW, 0.5f), 0.5f);
    col *= (1.0f - 0.28f * dot(vq, vq) * 0.5f) * WIN_EXPOSURE;

    float3 o = srgb_encode(tonemap_filmic(col));
    // film grain, strongest in the mid tones
    uint fr = uint(floor(wrap_time(u.time, u.loop) * u.fps + 0.5f));
    int2 gc = int2(floor((p + 1.0f) * 1400.0f));
    uint3 hg = pcg3d(uint3(as_type<uint2>(gc), fr * 0x9E3779B9u + u.seed));
    float gn = u01(hg.x) + u01(hg.y) - 1.0f;
    float lum = dot(o, float3(0.2126f, 0.7152f, 0.0722f));
    o += gn * WIN_GRAIN * (0.35f + 2.4f * lum * (1.0f - lum));
    out.write(float4(saturate(o), 1.0f), gid);
}
