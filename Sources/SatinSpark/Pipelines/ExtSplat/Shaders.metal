// Spark ext-splat vertex path ported from https://github.com/sparkjsdev/spark.

#include <metal_stdlib>
using namespace metal;

constant float PI = 3.1415926535897932384626433832795;

typedef struct {
    float maxStdDev;
    float minPixelRadius;
    float maxPixelRadius;
    float minAlpha;
    float preBlurAmount;
    float blurAmount;
    float clipXY;
    float focalAdjustment;
    float falloff;
    float2 renderSize;
    uint numSplats;
} ExtSplatUniforms;

typedef struct {
    float4 position [[position]];
    float4 rgba;
    float2 splatUV;
    float adjustedStdDev;
} ExtSplatVertexData;

static float sqr(float x) {
    return x * x;
}

static float3 srgbToLinear(float3 c) {
    float3 lo = c / 12.92;
    float3 hi = pow((c + 0.055) / 1.055, float3(2.4));
    return select(lo, hi, c > 0.04045);
}

static float unpackHalf(uint word) {
    return float(as_type<half>(ushort(word & 0xffffu)));
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

static float4 decodeQuatOctXy1010R12(uint encoded) {
    uint quantU = encoded & 0x3ffu;
    uint quantV = (encoded >> 10u) & 0x3ffu;
    uint angleInt = (encoded >> 20u) & 0xfffu;

    float2 f = float2(float(quantU), float(quantV)) / 1023.0 * 2.0 - 1.0;
    float3 axis = float3(f, 1.0 - abs(f.x) - abs(f.y));
    float t = max(-axis.z, 0.0);
    axis.x += axis.x >= 0.0 ? -t : t;
    axis.y += axis.y >= 0.0 ? -t : t;
    axis = normalize(axis);

    float theta = (float(angleInt) / 4095.0) * PI;
    float halfTheta = theta * 0.5;
    return float4(axis * sin(halfTheta), cos(halfTheta));
}

static void unpackExtSplat(
    uint4 extA,
    uint4 extB,
    thread float3 &center,
    thread float3 &scales,
    thread float4 &quaternion,
    thread float4 &rgba
) {
    center = float3(as_type<float>(extA.x), as_type<float>(extA.y), as_type<float>(extA.z));
    rgba.a = unpackHalf(extA.w);
    rgba.r = unpackHalf(extB.x);
    rgba.g = unpackHalf(extB.x >> 16u);
    rgba.b = unpackHalf(extB.y);
    scales = exp(float3(
        unpackHalf(extB.y >> 16u),
        unpackHalf(extB.z),
        unpackHalf(extB.z >> 16u)
    ));
    quaternion = decodeQuatOctXy1010R12(extB.w);
}

static ExtSplatVertexData culledExtSplatVertex() {
    ExtSplatVertexData out;
    out.position = float4(0.0, 0.0, 2.0, 1.0);
    out.rgba = float4(0.0);
    out.splatUV = float2(0.0);
    out.adjustedStdDev = 0.0;
    return out;
}

vertex ExtSplatVertexData extSplatVertex(
    Vertex in [[stage_in]],
    ushort amp_id [[amplification_id]],
    uint instanceID [[instance_id]],
    constant VertexUniforms *vertexUniforms [[buffer(VertexBufferVertexUniforms)]],
    constant ExtSplatUniforms &uniforms [[buffer(VertexBufferMaterialUniforms)]],
    constant uint4 *extA [[buffer(VertexBufferCustom0)]],
    constant uint4 *extB [[buffer(VertexBufferCustom1)]],
    constant uint *ordering [[buffer(VertexBufferCustom2)]]
) {
    if (instanceID >= uniforms.numSplats) {
        return culledExtSplatVertex();
    }

    uint splatIndex = ordering[instanceID];
    if (splatIndex == 0xffffffffu || splatIndex >= uniforms.numSplats) {
        return culledExtSplatVertex();
    }

    float3 center;
    float3 scales;
    float4 quaternion;
    float4 rgba;
    unpackExtSplat(extA[splatIndex], extB[splatIndex], center, scales, quaternion, rgba);

    if (rgba.a <= 0.0 || rgba.a < uniforms.minAlpha || all(scales == float3(0.0))) {
        return culledExtSplatVertex();
    }

    float adjustedStdDev = uniforms.maxStdDev;
    if (rgba.a > 1.0) {
        rgba.a = min(rgba.a * 4.0 - 3.0, 5.0);
        adjustedStdDev = uniforms.maxStdDev + 0.7 * (rgba.a - 1.0);
    }

    constant VertexUniforms &vu = vertexUniforms[amp_id];
    float3 viewCenter = (vu.modelViewMatrix * float4(center, 1.0)).xyz;
    if (viewCenter.z >= 0.0) {
        return culledExtSplatVertex();
    }

    float4 clipCenter = vu.projectionMatrix * float4(viewCenter, 1.0);
    if (abs(clipCenter.z) >= clipCenter.w) {
        return culledExtSplatVertex();
    }
    float clip = uniforms.clipXY * clipCenter.w;
    if (abs(clipCenter.x) > clip || abs(clipCenter.y) > clip) {
        return culledExtSplatVertex();
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
    rgba.a *= sqrt(max(0.0, detOrig / det));
    if (rgba.a < uniforms.minAlpha) {
        return culledExtSplatVertex();
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
        return culledExtSplatVertex();
    }

    float2 pixelOffset = in.position.x * eigenVec1 * scale1 + in.position.y * eigenVec2 * scale2;
    float2 ndcOffset = (2.0 / scaledRenderSize) * pixelOffset;
    float3 ndcCenter = clipCenter.xyz / clipCenter.w;
    float3 ndc = float3(ndcCenter.xy + ndcOffset, ndcCenter.z);

    ExtSplatVertexData out;
    out.position = float4(ndc.xy * clipCenter.w, clipCenter.zw);
    out.rgba = rgba;
    out.splatUV = in.position.xy * adjustedStdDev;
    out.adjustedStdDev = adjustedStdDev;
    return out;
}

fragment half4 extSplatFragment(
    ExtSplatVertexData in [[stage_in]],
    constant ExtSplatUniforms &uniforms [[buffer(FragmentBufferMaterialUniforms)]]
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
    rgba.rgb = srgbToLinear(rgba.rgb);
    return half4(rgba);
}
