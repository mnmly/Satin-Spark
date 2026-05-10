import Foundation
import simd

public enum SplatFileType: String, Sendable {
    case ply
    case spz
    case splat
    case ksplat
    case pcsogs
    case pcsogszip
    case rad
}

public struct SplatEncoding: Sendable, Equatable {
    public var rgbMin: Float
    public var rgbMax: Float
    public var lnScaleMin: Float
    public var lnScaleMax: Float
    public var sh1Max: Float
    public var sh2Max: Float
    public var sh3Max: Float
    public var lodOpacity: Bool

    public init(
        rgbMin: Float = 0.0,
        rgbMax: Float = 1.0,
        lnScaleMin: Float = SparkConstants.lnScaleMin,
        lnScaleMax: Float = SparkConstants.lnScaleMax,
        sh1Max: Float = 1.0,
        sh2Max: Float = 1.0,
        sh3Max: Float = 1.0,
        lodOpacity: Bool = false
    ) {
        self.rgbMin = rgbMin
        self.rgbMax = rgbMax
        self.lnScaleMin = lnScaleMin
        self.lnScaleMax = lnScaleMax
        self.sh1Max = sh1Max
        self.sh2Max = sh2Max
        self.sh3Max = sh3Max
        self.lodOpacity = lodOpacity
    }
}

public enum SparkConstants {
    public static let lnScaleMin: Float = -12.0
    public static let lnScaleMax: Float = 9.0
    public static let lnScaleZero: Float = -30.0
    public static let scaleZero: Float = exp(lnScaleZero)
}

@inline(__always)
func clamp01(_ value: Float) -> Float {
    if value.isNaN {
        return 0.0
    }
    guard value.isFinite else {
        return value.sign == .minus ? 0.0 : 1.0
    }
    return min(max(value, 0.0), 1.0)
}

@inline(__always)
func floatToUInt8(_ value: Float) -> UInt32 {
    UInt32(round(clamp01(value) * 255.0))
}

func encodeQuatOctXy88R8(_ quaternion: simd_quatf) -> UInt32 {
    var q = quaternion.vector
    if q.w < 0.0 {
        q = -q
    }

    let theta = 2.0 * acos(min(max(q.w, -1.0), 1.0))
    let halfTheta = theta * 0.5
    let s = sin(halfTheta)
    let axis: SIMD3<Float> = abs(s) < 1.0e-6 ? [1.0, 0.0, 0.0] : SIMD3<Float>(q.x, q.y, q.z) / s

    let denom = abs(axis.x) + abs(axis.y) + abs(axis.z)
    var p = SIMD2<Float>(axis.x, axis.y) / max(denom, .leastNonzeroMagnitude)
    if axis.z < 0.0 {
        let oldX = p.x
        p.x = (1.0 - abs(p.y)) * (p.x >= 0.0 ? 1.0 : -1.0)
        p.y = (1.0 - abs(oldX)) * (p.y >= 0.0 ? 1.0 : -1.0)
    }

    let u = UInt32(min(max(round((p.x * 0.5 + 0.5) * 255.0), 0.0), 255.0))
    let v = UInt32(min(max(round((p.y * 0.5 + 0.5) * 255.0), 0.0), 255.0))
    let angle = UInt32(min(max(round((theta / Float.pi) * 255.0), 0.0), 255.0))
    return u | (v << 8) | (angle << 16)
}
