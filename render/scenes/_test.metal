// _test.metal: harness stress test, not a real scene. It combines the three
// things that are hard to encode: near-black smooth gradients (banding), dense
// fast thin streaks (bitrate), and a periodic flash (flash checker), plus a
// slowly drifting non-periodic cloud layer so --xfade has a real seam to hide.

constant int TEST_LAYERS = 3;

// Three depth layers of slanted streaks. Each layer falls an integer number of
// vertical repeats per loop, so the rain is exactly periodic in u.loop.
static float test_rain(float2 p, float t, float L, float pxs, uint seed) {
    float acc = 0.0f;
    for (int k = 0; k < TEST_LAYERS; ++k) {
        float depth = float(k + 1) / float(TEST_LAYERS);   // 0.33 far .. 1 near
        float cw    = mix(0.004f, 0.011f, depth);          // column spacing
        float rep   = mix(0.30f, 0.75f, depth);            // vertical repeat
        float len   = mix(0.05f, 0.15f, depth);            // streak length
        float halfw = mix(0.0005f, 0.0014f, depth);        // streak half width
        float v     = max(1.0f, round(mix(1.3f, 2.8f, depth) * L / rep)) * rep / L;

        float2 q = float2(p.x + 0.13f * p.y, p.y);
        float col = floor(q.x / cw);
        float3 h = hash3(int2(int(col), k), seed);
        float dx = (fract(q.x / cw) - (0.2f + 0.6f * h.x)) * cw;
        float ly = fract((q.y + t * v) / rep + h.y) * rep;  // 0 = head (bottom)
        float along = ly / len;
        float body = smoothstep(0.0f, 0.08f, along) * (1.0f - smoothstep(0.3f, 1.0f, along));

        // Keep the streak at least ~1 px wide and conserve its energy so the
        // look matches across resolutions.
        float w = max(halfw, 0.75f * pxs);
        float across = (1.0f - smoothstep(0.0f, w, abs(dx))) * (halfw / w);
        float present = step(h.z, mix(0.55f, 0.35f, depth));
        acc += across * body * present * mix(0.18f, 0.45f, depth);
    }
    return acc;
}

kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    float2 p = frame_uv(gid, u.resolution);
    float t = u.time, L = u.loop;

    // Five flashes per loop, each with one return stroke 0.42 s later.
    const float period = L / 5.0f, offset = 2.3f;
    float dt = since_event(t, offset, period);
    uint  ev = uint(floor(wrap_time(t - offset, L) / period));
    float flash = 0.4f * (flash_env(dt, 0.07f, 0.35f) + 0.6f * flash_env(dt - 0.42f, 0.07f, 0.30f));
    float2 src = float2((rand1(ev, 1u, u.seed) - 0.5f) * 0.4f, 0.25f + 0.15f * rand1(ev, 2u, u.seed));

    // Drifting clouds: deliberately non-periodic (the crossfade hides them).
    float c = fbm3(float3(p * 2.2f + float2(0.012f * t, 0.0f), 0.02f * t), 5, u.seed);
    float dens = smoothstep(-0.35f, 0.6f, c);

    float3 sky = mix(float3(0.0025f, 0.0035f, 0.008f), float3(0.022f, 0.03f, 0.055f), smoothstep(-0.55f, 0.5f, p.y));
    sky *= 0.55f + 0.9f * dens;
    sky *= 1.0f - 0.55f * dot(p, p);

    float glow = flash * (0.15f + 0.85f * dens) * exp(-3.0f * length(p - src));
    float3 col = sky + glow * float3(0.55f, 0.6f, 0.8f);

    float rain = test_rain(p, t, L, px_size(u.resolution), u.seed);
    col += rain * float3(0.10f, 0.12f, 0.16f) * (1.0f + 4.0f * flash);

    out.write(output_color(col), gid);
}
