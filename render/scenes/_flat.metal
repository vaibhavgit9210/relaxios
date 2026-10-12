// _flat.metal: one flat display-referred colour, for the colour roundtrip
// check. Override with --define FLAT_R=0.2 --define FLAT_G=0.4 --define FLAT_B=0.6

#ifndef FLAT_R
#define FLAT_R 0.5
#endif
#ifndef FLAT_G
#define FLAT_G 0.5
#endif
#ifndef FLAT_B
#define FLAT_B 0.5
#endif

kernel void scene(texture2d<float, access::write> out [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  uint2 gid [[thread_position_in_grid]]) {
    out.write(float4(FLAT_R, FLAT_G, FLAT_B, 1.0f), gid);
}
