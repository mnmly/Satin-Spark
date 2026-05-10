#include <metal_stdlib>
using namespace metal;

// Bitonic sort on (key, originalIndex) pairs. Keys are computed from each splat's
// view-space center; ascending sort yields back-to-front draw order. Padding entries
// receive +infinity keys and are placed at the tail so the draw call (which only
// instances `numSplats` times) ignores them.

struct SplatSortParams {
    float4x4 modelViewMatrix;
    uint count;          // padded count, power of 2
    uint actualCount;    // real splat count
    uint metricMode;     // 0 = viewZ (key = z), 1 = radial (key = -|view|^2)
    uint k;              // outer bitonic stride
    uint j;              // inner compare distance
};

static float3 decodeSplatCenter(uint4 packed) {
    float2 xy = float2(as_type<half2>(packed.y));
    float2 z0 = float2(as_type<half2>(packed.z & 0xffffu));
    return float3(xy, z0.x);
}

kernel void splatSortComputeKeys(
    constant uint4 *packedSplats [[buffer(0)]],
    device float *keys [[buffer(1)]],
    device uint *indices [[buffer(2)]],
    constant SplatSortParams &params [[buffer(3)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= params.count) {
        return;
    }
    if (tid >= params.actualCount) {
        keys[tid] = INFINITY;
        indices[tid] = 0xffffffffu;
        return;
    }
    float3 center = decodeSplatCenter(packedSplats[tid]);
    float4 view = params.modelViewMatrix * float4(center, 1.0);
    float key = (params.metricMode == 0u) ? view.z : -dot(view.xyz, view.xyz);
    keys[tid] = key;
    indices[tid] = tid;
}

kernel void splatSortBitonicStep(
    device float *keys [[buffer(0)]],
    device uint *indices [[buffer(1)]],
    constant SplatSortParams &params [[buffer(2)]],
    uint tid [[thread_position_in_grid]]
) {
    uint i = tid;
    if (i >= params.count) {
        return;
    }
    uint partner = i ^ params.j;
    if (partner <= i) {
        return;
    }
    bool ascending = (i & params.k) == 0u;
    float ki = keys[i];
    float kp = keys[partner];
    bool needSwap = ascending ? (ki > kp) : (ki < kp);
    if (needSwap) {
        keys[i] = kp;
        keys[partner] = ki;
        uint ii = indices[i];
        uint ip = indices[partner];
        indices[i] = ip;
        indices[partner] = ii;
    }
}
