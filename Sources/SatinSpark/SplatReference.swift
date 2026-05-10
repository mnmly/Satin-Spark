import Foundation
import simd

public struct DecodedSplat: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var scales: SIMD3<Float>
    public var rotation: simd_quatf
    public var rgba: SIMD4<Float>
}

public struct ProjectedSplat: Sendable, Equatable {
    public var ndcCenter: SIMD3<Float>
    public var viewCenter: SIMD3<Float>
    public var axis1: SIMD2<Float>
    public var axis2: SIMD2<Float>
    public var radius1: Float
    public var radius2: Float
    public var adjustedStdDev: Float
    public var rgba: SIMD4<Float>
}

public enum SplatReference {
    public static func decodePackedSplat(_ words: SIMD4<UInt32>, encoding: SplatEncoding = SplatEncoding()) -> DecodedSplat {
        let rgbaBytes = SIMD4<UInt32>(
            words.x & 0xff,
            (words.x >> 8) & 0xff,
            (words.x >> 16) & 0xff,
            (words.x >> 24) & 0xff
        )
        var rgba = SIMD4<Float>(rgbaBytes) / 255.0
        rgba.x = rgba.x * (encoding.rgbMax - encoding.rgbMin) + encoding.rgbMin
        rgba.y = rgba.y * (encoding.rgbMax - encoding.rgbMin) + encoding.rgbMin
        rgba.z = rgba.z * (encoding.rgbMax - encoding.rgbMin) + encoding.rgbMin
        if encoding.lodOpacity {
            rgba.w *= 2.0
        }

        let center = SIMD3<Float>(
            Float(Float16(bitPattern: UInt16(words.y & 0xffff))),
            Float(Float16(bitPattern: UInt16((words.y >> 16) & 0xffff))),
            Float(Float16(bitPattern: UInt16(words.z & 0xffff)))
        )

        let scaleStep = (encoding.lnScaleMax - encoding.lnScaleMin) / 254.0
        let sx = words.w & 0xff
        let sy = (words.w >> 8) & 0xff
        let sz = (words.w >> 16) & 0xff
        let scales = SIMD3<Float>(
            decodeScale(sx, encoding: encoding, scaleStep: scaleStep),
            decodeScale(sy, encoding: encoding, scaleStep: scaleStep),
            decodeScale(sz, encoding: encoding, scaleStep: scaleStep)
        )

        let encodedQuat = ((words.z >> 16) & 0xffff) | ((words.w >> 8) & 0xff0000)
        return DecodedSplat(
            center: center,
            scales: scales,
            rotation: decodeQuatOctXy88R8(encodedQuat),
            rgba: rgba
        )
    }

    public static func project(
        _ splat: DecodedSplat,
        modelViewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        renderSize: SIMD2<Float>,
        maxStdDev: Float = sqrt(8.0),
        minPixelRadius: Float = 0.0,
        maxPixelRadius: Float = 1024.0,
        minAlpha: Float = 1.0 / 255.0
    ) -> ProjectedSplat? {
        var rgba = splat.rgba
        rgba.w *= 2.0
        guard rgba.w > 0.0, rgba.w >= minAlpha, splat.scales != .zero else { return nil }

        var adjustedStdDev = maxStdDev
        if rgba.w > 1.0 {
            rgba.w = min(rgba.w * 4.0 - 3.0, 5.0)
            adjustedStdDev = maxStdDev + 0.7 * (rgba.w - 1.0)
        }

        let viewCenter4 = modelViewMatrix * SIMD4<Float>(splat.center, 1.0)
        let viewCenter = viewCenter4.xyz
        guard viewCenter.z < 0.0 else { return nil }

        let clipCenter = projectionMatrix * SIMD4<Float>(viewCenter, 1.0)
        guard abs(clipCenter.z) < clipCenter.w else { return nil }

        let localRS = simd_float3x3(splat.rotation) * simd_float3x3(diagonal: splat.scales)
        let modelView3 = simd_float3x3(
            SIMD3<Float>(modelViewMatrix.columns.0.x, modelViewMatrix.columns.0.y, modelViewMatrix.columns.0.z),
            SIMD3<Float>(modelViewMatrix.columns.1.x, modelViewMatrix.columns.1.y, modelViewMatrix.columns.1.z),
            SIMD3<Float>(modelViewMatrix.columns.2.x, modelViewMatrix.columns.2.y, modelViewMatrix.columns.2.z)
        )
        let viewRS = modelView3 * localRS
        let cov3D = viewRS * viewRS.transpose

        let safeRenderSize = max(renderSize, SIMD2<Float>(repeating: 1.0))
        let focal = 0.5 * safeRenderSize * SIMD2<Float>(projectionMatrix.columns.0.x, projectionMatrix.columns.1.y)
        let invZ = 1.0 / viewCenter.z
        let j1 = focal * invZ
        let j2 = -(j1 * viewCenter.xy) * invZ
        let jacobian = simd_float3x3(
            SIMD3<Float>(j1.x, 0.0, j2.x),
            SIMD3<Float>(0.0, j1.y, j2.y),
            SIMD3<Float>(0.0, 0.0, 0.0)
        )

        let cov2D = jacobian.transpose * cov3D * jacobian
        var a = cov2D.columns.0.x
        var d = cov2D.columns.1.y
        let b = cov2D.columns.0.y
        a += 0.3
        d += 0.3
        let det = a * d - b * b

        let eigenAverage = 0.5 * (a + d)
        let eigenDelta = sqrt(max(0.0, eigenAverage * eigenAverage - det))
        let eigen1 = max(eigenAverage + eigenDelta, 0.0)
        let eigen2 = max(eigenAverage - eigenDelta, 0.0)

        let axis1: SIMD2<Float>
        if abs(b) > 0.001 {
            axis1 = simd_normalize(SIMD2<Float>(b, eigen1 - a))
        } else {
            axis1 = a >= d ? SIMD2<Float>(1.0, 0.0) : SIMD2<Float>(0.0, 1.0)
        }
        let axis2 = SIMD2<Float>(axis1.y, -axis1.x)
        let radius1 = min(maxPixelRadius, adjustedStdDev * sqrt(eigen1))
        let radius2 = min(maxPixelRadius, adjustedStdDev * sqrt(eigen2))
        guard radius1 >= minPixelRadius || radius2 >= minPixelRadius else { return nil }

        return ProjectedSplat(
            ndcCenter: clipCenter.xyz / clipCenter.w,
            viewCenter: viewCenter,
            axis1: axis1,
            axis2: axis2,
            radius1: radius1,
            radius2: radius2,
            adjustedStdDev: adjustedStdDev,
            rgba: rgba
        )
    }

    private static func decodeScale(_ value: UInt32, encoding: SplatEncoding, scaleStep: Float) -> Float {
        value == 0 ? 0.0 : exp(encoding.lnScaleMin + Float(value - 1) * scaleStep)
    }

    private static func decodeQuatOctXy88R8(_ encoded: UInt32) -> simd_quatf {
        let quantU = encoded & 0xff
        let quantV = (encoded >> 8) & 0xff
        let angleInt = (encoded >> 16) & 0xff

        var axis = SIMD3<Float>(
            Float(quantU) / 255.0 * 2.0 - 1.0,
            Float(quantV) / 255.0 * 2.0 - 1.0,
            0.0
        )
        axis.z = 1.0 - abs(axis.x) - abs(axis.y)
        let t = max(-axis.z, 0.0)
        axis.x += axis.x >= 0.0 ? -t : t
        axis.y += axis.y >= 0.0 ? -t : t
        axis = simd_normalize(axis)

        let theta = (Float(angleInt) / 255.0) * Float.pi
        return simd_quatf(angle: theta, axis: axis)
    }
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}

private extension SIMD3 where Scalar == Float {
    var xy: SIMD2<Float> {
        SIMD2(x, y)
    }
}
