// Ported from https://github.com/sparkjsdev/spark — `src/shaders/splatVertex.glsl`,
// `src/shaders/splatFragment.glsl`, and helpers from `src/shaders/splatDefines.glsl`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

#include <metal_stdlib>
using namespace metal;

constant float LN_SCALE_MIN = -12.0;
constant float LN_SCALE_MAX = 9.0;
constant float PI = 3.1415926535897932384626433832795;

typedef struct {
    float4 rgbMinMaxLnScaleMinMax; // color
    float3 shMax;
    float maxStdDev;               // slider,1.0,6.0,0.1
    float minPixelRadius;          // slider,0.0,8.0,0.05
    float maxPixelRadius;          // slider,1.0,2048.0,1.0
    float minAlpha;                // slider,0.0,1.0,0.001
    float preBlurAmount;           // slider,0.0,16.0,0.1
    float blurAmount;              // slider,0.0,16.0,0.1
    float clipXY;                  // slider,0.1,4.0,0.1
    float focalAdjustment;         // slider,0.1,4.0,0.1
    float falloff;                 // slider,0.0,1.0,0.01
    float2 renderSize;
    uint numSplats;
    uint debugMode;
    uint shDegree;
    uint legacySparkBlending;      // 1 = byte-parity with three.js Spark fixture
} SplatUniforms;

typedef struct {
    float4 position [[position]];
    float4 rgba;
    float2 splatUV;
    float adjustedStdDev;
} SplatVertexData;

static float sqr(float x) {
    return x * x;
}

static float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    return select(lo, hi, c > 0.04045);
}

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
    float4 encoding
) {
    uint4 uRgba = uint4(
        packed.x & 0xffu,
        (packed.x >> 8u) & 0xffu,
        (packed.x >> 16u) & 0xffu,
        (packed.x >> 24u) & 0xffu
    );
    rgba = float4(uRgba) / 255.0;
    rgba.rgb = rgba.rgb * (encoding.y - encoding.x) + encoding.x;

    float2 xy = unpackHalf2(packed.y);
    float2 z0 = unpackHalf2(packed.z & 0xffffu);
    center = float3(xy, z0.x);

    uint3 uScales = uint3(
        packed.w & 0xffu,
        (packed.w >> 8u) & 0xffu,
        (packed.w >> 16u) & 0xffu
    );
    float lnScaleStep = (encoding.w - encoding.z) / 254.0;
    scales = float3(
        uScales.x == 0u ? 0.0 : exp(encoding.z + float(uScales.x - 1u) * lnScaleStep),
        uScales.y == 0u ? 0.0 : exp(encoding.z + float(uScales.y - 1u) * lnScaleStep),
        uScales.z == 0u ? 0.0 : exp(encoding.z + float(uScales.z - 1u) * lnScaleStep)
    );

    uint encodedQuat = ((packed.z >> 16u) & 0xffffu) | ((packed.w >> 8u) & 0xff0000u);
    quaternion = decodeQuatOctXy88R8(encodedQuat);
}

static int signExtend(uint value, uint shift) {
    return int(value << shift) >> shift;
}

static float3 evaluatePackedSH1(uint2 packed, float3 viewDir, float sh1Max) {
    float3 sh1_0 = float3(
        signExtend(packed.x, 25u),
        signExtend(packed.x << 18u, 25u),
        signExtend(packed.x << 11u, 25u)
    );
    float3 sh1_1 = float3(
        signExtend(packed.x << 4u, 25u),
        signExtend((packed.x >> 3u) | (packed.y << 29u), 25u),
        signExtend(packed.y << 22u, 25u)
    );
    float3 sh1_2 = float3(
        signExtend(packed.y << 15u, 25u),
        signExtend(packed.y << 8u, 25u),
        signExtend(packed.y << 1u, 25u)
    );

    float3 rgb = sh1_0 * (-0.4886025 * viewDir.y)
        + sh1_1 * (0.4886025 * viewDir.z)
        + sh1_2 * (-0.4886025 * viewDir.x);
    return rgb * (sh1Max / 63.0);
}

static float3 evaluatePackedSH2(uint4 packed, float3 viewDir, float sh2Max) {
    float3 sh2_0 = float3(signExtend(packed.x, 24u), signExtend(packed.x << 16u, 24u), signExtend(packed.x << 8u, 24u));
    float3 sh2_1 = float3(int(packed.x) >> 24, signExtend(packed.y, 24u), signExtend(packed.y << 16u, 24u));
    float3 sh2_2 = float3(signExtend(packed.y << 8u, 24u), int(packed.y) >> 24, signExtend(packed.z, 24u));
    float3 sh2_3 = float3(signExtend(packed.z << 16u, 24u), signExtend(packed.z << 8u, 24u), int(packed.z) >> 24);
    float3 sh2_4 = float3(signExtend(packed.w, 24u), signExtend(packed.w << 16u, 24u), signExtend(packed.w << 8u, 24u));

    float3 rgb = sh2_0 * (1.0925484 * viewDir.x * viewDir.y)
        + sh2_1 * (-1.0925484 * viewDir.y * viewDir.z)
        + sh2_2 * (0.3153915 * (2.0 * viewDir.z * viewDir.z - viewDir.x * viewDir.x - viewDir.y * viewDir.y))
        + sh2_3 * (-1.0925484 * viewDir.x * viewDir.z)
        + sh2_4 * (0.5462742 * (viewDir.x * viewDir.x - viewDir.y * viewDir.y));
    return rgb * (sh2Max / 127.0);
}

static float3 evaluatePackedSH3(uint4 packed, float3 viewDir, float sh3Max) {
    float3 sh3_0 = float3(signExtend(packed.x, 26u), signExtend(packed.x << 20u, 26u), signExtend(packed.x << 14u, 26u));
    float3 sh3_1 = float3(signExtend(packed.x << 8u, 26u), signExtend(packed.x << 2u, 26u), signExtend((packed.x >> 4u) | (packed.y << 28u), 26u));
    float3 sh3_2 = float3(signExtend(packed.y << 22u, 26u), signExtend(packed.y << 16u, 26u), signExtend(packed.y << 10u, 26u));
    float3 sh3_3 = float3(signExtend(packed.y << 4u, 26u), signExtend((packed.y >> 2u) | (packed.z << 30u), 26u), signExtend(packed.z << 24u, 26u));
    float3 sh3_4 = float3(signExtend(packed.z << 18u, 26u), signExtend(packed.z << 12u, 26u), signExtend(packed.z << 6u, 26u));
    float3 sh3_5 = float3(int(packed.z) >> 26, signExtend(packed.w << 26u, 26u), signExtend(packed.w << 20u, 26u));
    float3 sh3_6 = float3(signExtend(packed.w << 14u, 26u), signExtend(packed.w << 8u, 26u), signExtend(packed.w << 2u, 26u));

    float xx = viewDir.x * viewDir.x;
    float yy = viewDir.y * viewDir.y;
    float zz = viewDir.z * viewDir.z;
    float xy = viewDir.x * viewDir.y;

    float3 rgb = sh3_0 * (-0.5900436 * viewDir.y * (3.0 * xx - yy))
        + sh3_1 * (2.8906114 * xy * viewDir.z)
        + sh3_2 * (-0.4570458 * viewDir.y * (4.0 * zz - xx - yy))
        + sh3_3 * (0.3731763 * viewDir.z * (2.0 * zz - 3.0 * xx - 3.0 * yy))
        + sh3_4 * (-0.4570458 * viewDir.x * (4.0 * zz - xx - yy))
        + sh3_5 * (1.4453057 * viewDir.z * (xx - yy))
        + sh3_6 * (-0.5900436 * viewDir.x * (xx - 3.0 * yy));
    return rgb * (sh3Max / 31.0);
}

static SplatVertexData culledSplatVertex() {
    SplatVertexData out;
    out.position = float4(0.0, 0.0, 2.0, 1.0);
    out.rgba = float4(0.0);
    out.splatUV = float2(0.0);
    out.adjustedStdDev = 0.0;
    return out;
}

vertex SplatVertexData splatVertex(
    Vertex in [[stage_in]],
    ushort amp_id [[amplification_id]],
    uint instanceID [[instance_id]],
    constant VertexUniforms *vertexUniforms [[buffer(VertexBufferVertexUniforms)]],
    constant SplatUniforms &uniforms [[buffer(VertexBufferMaterialUniforms)]],
    constant uint4 *packedSplats [[buffer(VertexBufferCustom0)]],
    constant uint *ordering [[buffer(VertexBufferCustom1)]],
    constant uint2 *sh1 [[buffer(VertexBufferCustom2)]],
    constant uint4 *sh2 [[buffer(VertexBufferCustom3)]],
    constant uint4 *sh3 [[buffer(VertexBufferCustom4)]]
) {
    if (instanceID >= uniforms.numSplats) {
        return culledSplatVertex();
    }

    if (uniforms.debugMode == 1u) {
        float x = (float(instanceID) - 2.0) * 0.28;
        SplatVertexData out;
        out.position = float4(in.position.xy * 0.12 + float2(x, 0.0), 0.5, 1.0);
        out.rgba = float4(1.0, 0.25 + 0.12 * float(instanceID), 0.15, 1.0);
        out.splatUV = in.position.xy;
        out.adjustedStdDev = 3.0;
        return out;
    }

    uint splatIndex = ordering[instanceID];
    if (splatIndex == 0xffffffffu || splatIndex >= uniforms.numSplats) {
        return culledSplatVertex();
    }

    float3 center;
    float3 scales;
    float4 quaternion;
    float4 rgba;
    unpackSplat(
        packedSplats[splatIndex],
        center,
        scales,
        quaternion,
        rgba,
        uniforms.rgbMinMaxLnScaleMinMax
    );

    if (uniforms.debugMode == 2u) {
        constant VertexUniforms &vu = vertexUniforms[amp_id];
        float4 viewCenter = vu.modelViewMatrix * float4(center, 1.0);
        float4 clipCenter = vu.projectionMatrix * viewCenter;
        if (clipCenter.w <= 0.0 || abs(clipCenter.z) >= clipCenter.w) {
            return culledSplatVertex();
        }

        float2 renderSize = max(uniforms.renderSize, float2(1.0));
        float2 ndcOffset = (2.0 / renderSize) * in.position.xy * 24.0;
        float3 ndcCenter = clipCenter.xyz / clipCenter.w;

        SplatVertexData out;
        out.position = float4((ndcCenter.xy + ndcOffset) * clipCenter.w, clipCenter.zw);
        out.rgba = float4(rgba.rgb, max(rgba.a, 0.85));
        out.splatUV = in.position.xy;
        out.adjustedStdDev = 2.0;
        return out;
    }

    // Note: Spark's vertex shader does `rgba.a *= 2.0` here, but its SplatAccumulator
    // pre-halves opacity (`mul(opacity, 0.5)` in SplatAccumulator.ts) so the round-trip
    // is identity. We pack opacity directly without halving, so we skip the doubling.
    if (rgba.a <= 0.0 || rgba.a < uniforms.minAlpha || all(scales == float3(0.0))) {
        return culledSplatVertex();
    }

    if (uniforms.debugMode == 4u) {
        float x = (float(instanceID) - 2.0) * 0.28;
        SplatVertexData out;
        out.position = float4(in.position.xy * 0.12 + float2(x, 0.0), 0.5, 1.0);
        out.rgba = float4(scales * 4.0, 1.0);
        out.splatUV = in.position.xy;
        out.adjustedStdDev = 3.0;
        return out;
    }

    float adjustedStdDev = uniforms.maxStdDev;
    if (rgba.a > 1.0) {
        rgba.a = min(rgba.a * 4.0 - 3.0, 5.0);
        adjustedStdDev = uniforms.maxStdDev + 0.7 * (rgba.a - 1.0);
    }

    constant VertexUniforms &vu = vertexUniforms[amp_id];
    if (uniforms.shDegree > 0u) {
        float3 worldCenter = (vu.modelMatrix * float4(center, 1.0)).xyz;
        float3 viewDir = normalize(worldCenter - vu.worldCameraPosition);
        if (uniforms.shDegree >= 1u) {
            rgba.rgb += evaluatePackedSH1(sh1[splatIndex], viewDir, uniforms.shMax.x);
        }
        if (uniforms.shDegree >= 2u) {
            rgba.rgb += evaluatePackedSH2(sh2[splatIndex], viewDir, uniforms.shMax.y);
        }
        if (uniforms.shDegree >= 3u) {
            rgba.rgb += evaluatePackedSH3(sh3[splatIndex], viewDir, uniforms.shMax.z);
        }
    }

    float3 viewCenter = (vu.modelViewMatrix * float4(center, 1.0)).xyz;
    if (viewCenter.z >= 0.0) {
        return culledSplatVertex();
    }

    float4 clipCenter = vu.projectionMatrix * float4(viewCenter, 1.0);
    if (abs(clipCenter.z) >= clipCenter.w) {
        return culledSplatVertex();
    }
    float clip = uniforms.clipXY * clipCenter.w;
    if (abs(clipCenter.x) > clip || abs(clipCenter.y) > clip) {
        return culledSplatVertex();
    }

    float3x3 localRS = quatToMatrix(quaternion) * float3x3(
        float3(scales.x, 0.0, 0.0),
        float3(0.0, scales.y, 0.0),
        float3(0.0, 0.0, scales.z)
    );
    float3x3 modelView3x3 = float3x3(
        vu.modelViewMatrix[0].xyz,
        vu.modelViewMatrix[1].xyz,
        vu.modelViewMatrix[2].xyz
    );
    float3x3 viewRS = modelView3x3 * localRS;
    float3x3 cov3D = viewRS * transpose(viewRS);

    float2 renderSize = max(uniforms.renderSize, float2(1.0));
    float2 scaledRenderSize = renderSize * uniforms.focalAdjustment;
    float2 focal = 0.5 * scaledRenderSize * float2(vu.projectionMatrix[0][0], vu.projectionMatrix[1][1]);
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
        return culledSplatVertex();
    }

    float eigenAvg = 0.5 * (a + d);
    float eigenDelta = sqrt(max(0.0, eigenAvg * eigenAvg - det));
    float eigen1 = max(eigenAvg + eigenDelta, 0.0);
    float eigen2 = max(eigenAvg - eigenDelta, 0.0);

    float2 eigenVec1 = abs(b) > 0.001
        ? normalize(float2(b, eigen1 - a))
        : (a >= d ? float2(1.0, 0.0) : float2(0.0, 1.0));
    float2 eigenVec2 = float2(eigenVec1.y, -eigenVec1.x);

    float scale1 = min(uniforms.maxPixelRadius, adjustedStdDev * sqrt(max(eigen1, 0.0)));
    float scale2 = min(uniforms.maxPixelRadius, adjustedStdDev * sqrt(max(eigen2, 0.0)));
    if (scale1 < uniforms.minPixelRadius && scale2 < uniforms.minPixelRadius) {
        return culledSplatVertex();
    }

    float2 pixelOffset = in.position.x * eigenVec1 * scale1 + in.position.y * eigenVec2 * scale2;
    float2 ndcOffset = (2.0 / scaledRenderSize) * pixelOffset;
    float3 ndcCenter = clipCenter.xyz / clipCenter.w;
    float3 ndc = float3(ndcCenter.xy + ndcOffset, ndcCenter.z);

    SplatVertexData out;
    out.position = float4(ndc.xy * clipCenter.w, clipCenter.zw);
    if (uniforms.debugMode == 3u) {
        float x = (float(instanceID) - 2.0) * 0.28;
        out.rgba = float4(0.15, 0.85, 1.0, 1.0);
        out.position = float4(in.position.xy * 0.12 + float2(x, 0.0), 0.5, 1.0);
        out.splatUV = in.position.xy;
        out.adjustedStdDev = 3.0;
        return out;
    }
    out.rgba = rgba;
    out.splatUV = in.position.xy * adjustedStdDev;
    out.adjustedStdDev = adjustedStdDev;
    return out;
}

fragment half4 splatFragment(
    SplatVertexData in [[stage_in]],
    constant SplatUniforms &uniforms [[buffer(FragmentBufferMaterialUniforms)]]
) {
    float z2 = dot(in.splatUV, in.splatUV);
    if (z2 > sqr(in.adjustedStdDev)) {
        discard_fragment();
    }

    float4 rgba = in.rgba;
    if (rgba.a <= 1.0) {
        rgba.a = mix(rgba.a, rgba.a * exp(-0.5 * z2), uniforms.falloff);
    } else {
        float a = exp((rgba.a * rgba.a - 1.0) / 2.718281828459045);
        float alpha = 1.0 - pow(1.0 - exp(-0.5 * z2), a);
        rgba.a = mix(1.0, alpha, uniforms.falloff);
    }

    if (rgba.a < uniforms.minAlpha) {
        discard_fragment();
    }
    if (uniforms.legacySparkBlending == 0u) {
        rgba.rgb = srgbToLinear(rgba.rgb);
    }
    return half4(rgba);
}
