#include <metal_stdlib>
using namespace metal;

constant float PI = 3.1415926535897932384626433832795;

struct SplatRADPagingUniforms {
    float4x4 modelViewMatrix;
    float4x4 projectionMatrix;
    float4 encoding;
    float2 renderSize;
    float maxStdDev;
    float minPixelRadius;
    float maxPixelRadius;
    float minAlpha;
    float preBlurAmount;
    float blurAmount;
    float focalAdjustment;
    float splitPixelRadius;
    uint count;
    uint lodOpacity;
    uint rootIndex;
};

static float2 unpackHalf2(uint word) {
    return float2(as_type<half2>(word));
}

static float3x3 quatToMatrix(float4 q) {
    float x = q.x;
    float y = q.y;
    float z = q.z;
    float w = q.w;
    float x2 = x + x;
    float y2 = y + y;
    float z2 = z + z;
    float xx = x * x2;
    float xy = x * y2;
    float xz = x * z2;
    float yy = y * y2;
    float yz = y * z2;
    float zz = z * z2;
    float wx = w * x2;
    float wy = w * y2;
    float wz = w * z2;

    return float3x3(
        float3(1.0 - (yy + zz), xy + wz, xz - wy),
        float3(xy - wz, 1.0 - (xx + zz), yz + wx),
        float3(xz + wy, yz - wx, 1.0 - (xx + yy))
    );
}

static float4 decodeQuatOctXy88R8(uint encoded) {
    uint quantU = encoded & 0xffu;
    uint quantV = (encoded >> 8u) & 0xffu;
    uint angleInt = (encoded >> 16u) & 0xffu;

    float2 f = float2(float(quantU), float(quantV)) / 255.0 * 2.0 - 1.0;
    float3 axis = float3(f, 1.0 - abs(f.x) - abs(f.y));
    float t = max(-axis.z, 0.0);
    axis.x += axis.x >= 0.0 ? -t : t;
    axis.y += axis.y >= 0.0 ? -t : t;
    axis = normalize(axis);

    float theta = (float(angleInt) / 255.0) * PI;
    float halfTheta = theta * 0.5;
    return float4(axis * sin(halfTheta), cos(halfTheta));
}

static void unpackSplat(
    uint4 packed,
    thread float3 &center,
    thread float3 &scales,
    thread float4 &quaternion,
    thread float4 &rgba,
    constant SplatRADPagingUniforms &uniforms
) {
    uint4 uRgba = uint4(
        packed.x & 0xffu,
        (packed.x >> 8u) & 0xffu,
        (packed.x >> 16u) & 0xffu,
        (packed.x >> 24u) & 0xffu
    );
    rgba = float4(uRgba) / 255.0;
    rgba.rgb = rgba.rgb * (uniforms.encoding.y - uniforms.encoding.x) + uniforms.encoding.x;
    if (uniforms.lodOpacity != 0u) {
        rgba.a *= 2.0;
    }

    float2 xy = unpackHalf2(packed.y);
    float2 z0 = unpackHalf2(packed.z & 0xffffu);
    center = float3(xy, z0.x);

    uint3 uScales = uint3(
        packed.w & 0xffu,
        (packed.w >> 8u) & 0xffu,
        (packed.w >> 16u) & 0xffu
    );
    float lnScaleStep = (uniforms.encoding.w - uniforms.encoding.z) / 254.0;
    scales = float3(
        uScales.x == 0u ? 0.0 : exp(uniforms.encoding.z + float(uScales.x - 1u) * lnScaleStep),
        uScales.y == 0u ? 0.0 : exp(uniforms.encoding.z + float(uScales.y - 1u) * lnScaleStep),
        uScales.z == 0u ? 0.0 : exp(uniforms.encoding.z + float(uScales.z - 1u) * lnScaleStep)
    );

    uint encodedQuat = ((packed.z >> 16u) & 0xffffu) | ((packed.w >> 8u) & 0xff0000u);
    quaternion = decodeQuatOctXy88R8(encodedQuat);
}

static float projectedRadius(uint index, constant uint4 *packedSplats, constant SplatRADPagingUniforms &uniforms) {
    float3 center;
    float3 scales;
    float4 quaternion;
    float4 rgba;
    unpackSplat(packedSplats[index], center, scales, quaternion, rgba, uniforms);

    if (rgba.a <= 0.0 || rgba.a < uniforms.minAlpha || all(scales == float3(0.0))) {
        return 0.0;
    }

    float adjustedStdDev = uniforms.maxStdDev;
    if (rgba.a > 1.0) {
        rgba.a = min(rgba.a * 4.0 - 3.0, 5.0);
        adjustedStdDev = uniforms.maxStdDev + 0.7 * (rgba.a - 1.0);
    }

    float3 viewCenter = (uniforms.modelViewMatrix * float4(center, 1.0)).xyz;
    if (viewCenter.z >= 0.0) {
        return 0.0;
    }

    float4 clipCenter = uniforms.projectionMatrix * float4(viewCenter, 1.0);
    if (abs(clipCenter.z) >= clipCenter.w) {
        return 0.0;
    }

    float3x3 localRS = quatToMatrix(quaternion) * float3x3(
        float3(scales.x, 0.0, 0.0),
        float3(0.0, scales.y, 0.0),
        float3(0.0, 0.0, scales.z)
    );
    float3x3 modelView3x3 = float3x3(
        uniforms.modelViewMatrix[0].xyz,
        uniforms.modelViewMatrix[1].xyz,
        uniforms.modelViewMatrix[2].xyz
    );
    float3x3 viewRS = modelView3x3 * localRS;
    float3x3 cov3D = viewRS * transpose(viewRS);

    float2 renderSize = max(uniforms.renderSize, float2(1.0));
    float2 scaledRenderSize = renderSize * uniforms.focalAdjustment;
    float2 focal = 0.5 * scaledRenderSize * float2(uniforms.projectionMatrix[0][0], uniforms.projectionMatrix[1][1]);
    float invZ = 1.0 / viewCenter.z;
    float2 j1 = focal * invZ;
    float2 j2 = -(j1 * viewCenter.xy) * invZ;
    float3x3 jacobian = float3x3(
        float3(j1.x, 0.0, j2.x),
        float3(0.0, j1.y, j2.y),
        float3(0.0, 0.0, 0.0)
    );
    float3x3 cov2D = transpose(jacobian) * cov3D * jacobian;
    float a = cov2D[0][0];
    float d = cov2D[1][1];
    float b = cov2D[0][1];

    a += uniforms.preBlurAmount;
    d += uniforms.preBlurAmount;

    float detOrig = a * d - b * b;
    a += uniforms.blurAmount;
    d += uniforms.blurAmount;
    float det = a * d - b * b;
    float blurAdjust = sqrt(max(0.0, detOrig / det));
    rgba.a *= blurAdjust;

    if (rgba.a < uniforms.minAlpha) {
        return 0.0;
    }

    float eigenAvg = 0.5 * (a + d);
    float eigenDelta = sqrt(max(0.0, eigenAvg * eigenAvg - det));
    float eigen1 = max(eigenAvg + eigenDelta, 0.0);
    float eigen2 = max(eigenAvg - eigenDelta, 0.0);
    float scale1 = min(uniforms.maxPixelRadius, adjustedStdDev * sqrt(max(eigen1, 0.0)));
    float scale2 = min(uniforms.maxPixelRadius, adjustedStdDev * sqrt(max(eigen2, 0.0)));

    if (scale1 < uniforms.minPixelRadius && scale2 < uniforms.minPixelRadius) {
        return 0.0;
    }
    return max(scale1, scale2);
}

static bool shouldSplit(
    uint index,
    constant uint4 *packedSplats,
    constant ushort *childCounts,
    constant SplatRADPagingUniforms &uniforms
) {
    return childCounts[index] > 0u
        && projectedRadius(index, packedSplats, uniforms) > uniforms.splitPixelRadius;
}

kernel void splatRADSelectLOD(
    constant uint4 *packedSplats [[buffer(0)]],
    constant ushort *childCounts [[buffer(1)]],
    constant uint *childStarts [[buffer(2)]],
    constant uint *parents [[buffer(3)]],
    device atomic_uint *visibleCount [[buffer(4)]],
    device uint *ordering [[buffer(5)]],
    constant SplatRADPagingUniforms &uniforms [[buffer(6)]],
    uint tid [[thread_position_in_grid]]
) {
    if (tid >= uniforms.count) {
        return;
    }

    if (shouldSplit(tid, packedSplats, childCounts, uniforms)) {
        return;
    }

    uint ancestor = parents[tid];
    if (tid != uniforms.rootIndex && ancestor == 0xffffffffu) {
        return;
    }

    uint guard = 0;
    while (ancestor != 0xffffffffu && guard < uniforms.count) {
        if (!shouldSplit(ancestor, packedSplats, childCounts, uniforms)) {
            return;
        }
        ancestor = parents[ancestor];
        guard += 1;
    }

    if (guard >= uniforms.count) {
        return;
    }

    uint slot = atomic_fetch_add_explicit(visibleCount, 1u, memory_order_relaxed);
    if (slot < uniforms.count) {
        ordering[slot] = tid;
    }
}
