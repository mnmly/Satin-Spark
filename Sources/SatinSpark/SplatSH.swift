// Spherical harmonics packing/evaluation layout is ported from Spark's
// `src/utils.ts` and `src/PackedSplats.ts`.

import Foundation
import simd

public struct PackedSphericalHarmonics: Sendable, Equatable {
    public var sh1: [UInt32]?
    public var sh2: [UInt32]?
    public var sh3: [UInt32]?

    public init(sh1: [UInt32]? = nil, sh2: [UInt32]? = nil, sh3: [UInt32]? = nil) {
        self.sh1 = sh1
        self.sh2 = sh2
        self.sh3 = sh3
    }

    public var degree: Int {
        if sh3 != nil { return 3 }
        if sh2 != nil { return 2 }
        if sh1 != nil { return 1 }
        return 0
    }

    public static func storage(numSplats: Int, degree: Int) -> PackedSphericalHarmonics {
        PackedSphericalHarmonics(
            sh1: degree >= 1 ? Array(repeating: UInt32(0), count: numSplats * 2) : nil,
            sh2: degree >= 2 ? Array(repeating: UInt32(0), count: numSplats * 4) : nil,
            sh3: degree >= 3 ? Array(repeating: UInt32(0), count: numSplats * 4) : nil
        )
    }

    public func evaluate(at index: Int, viewDirection: SIMD3<Float>, encoding: SplatEncoding) -> SIMD3<Float> {
        var rgb = SIMD3<Float>(repeating: 0.0)
        let viewDirection = simd_normalize(viewDirection)
        if let sh1 {
            let base = index * 2
            rgb += evaluatePackedSH1(SIMD2(sh1[base], sh1[base + 1]), viewDirection: viewDirection, sh1Max: encoding.sh1Max)
        }
        if let sh2 {
            let base = index * 4
            rgb += evaluatePackedSH2(
                SIMD4(sh2[base], sh2[base + 1], sh2[base + 2], sh2[base + 3]),
                viewDirection: viewDirection,
                sh2Max: encoding.sh2Max
            )
        }
        if let sh3 {
            let base = index * 4
            rgb += evaluatePackedSH3(
                SIMD4(sh3[base], sh3[base + 1], sh3[base + 2], sh3[base + 3]),
                viewDirection: viewDirection,
                sh3Max: encoding.sh3Max
            )
        }
        return rgb
    }

    public mutating func setSH1(_ coefficients: [Float], at index: Int, encoding: SplatEncoding) {
        guard sh1 != nil else { return }
        encodeSH1(coefficients, into: &sh1!, at: index, encoding: encoding)
    }

    public mutating func setSH2(_ coefficients: [Float], at index: Int, encoding: SplatEncoding) {
        guard sh2 != nil else { return }
        encodeSH2(coefficients, into: &sh2!, at: index, encoding: encoding)
    }

    public mutating func setSH3(_ coefficients: [Float], at index: Int, encoding: SplatEncoding) {
        guard sh3 != nil else { return }
        encodeSH3(coefficients, into: &sh3!, at: index, encoding: encoding)
    }
}

private func evaluatePackedSH1(
    _ packed: SIMD2<UInt32>,
    viewDirection: SIMD3<Float>,
    sh1Max: Float
) -> SIMD3<Float> {
    let sh1_0 = SIMD3<Float>(
        Float(signExtend(packed.x, shift: 25)),
        Float(signExtend(packed.x << 18, shift: 25)),
        Float(signExtend(packed.x << 11, shift: 25))
    )
    let sh1_1 = SIMD3<Float>(
        Float(signExtend(packed.x << 4, shift: 25)),
        Float(signExtend((packed.x >> 3) | (packed.y << 29), shift: 25)),
        Float(signExtend(packed.y << 22, shift: 25))
    )
    let sh1_2 = SIMD3<Float>(
        Float(signExtend(packed.y << 15, shift: 25)),
        Float(signExtend(packed.y << 8, shift: 25)),
        Float(signExtend(packed.y << 1, shift: 25))
    )

    let rgb = sh1_0 * (-0.4886025 * viewDirection.y)
        + sh1_1 * (0.4886025 * viewDirection.z)
        + sh1_2 * (-0.4886025 * viewDirection.x)
    return rgb * (sh1Max / 63.0)
}

private func evaluatePackedSH2(
    _ packed: SIMD4<UInt32>,
    viewDirection: SIMD3<Float>,
    sh2Max: Float
) -> SIMD3<Float> {
    let sh2_0 = SIMD3<Float>(Float(signExtend(packed.x, shift: 24)), Float(signExtend(packed.x << 16, shift: 24)), Float(signExtend(packed.x << 8, shift: 24)))
    let sh2_1 = SIMD3<Float>(Float(Int32(bitPattern: packed.x) >> 24), Float(signExtend(packed.y, shift: 24)), Float(signExtend(packed.y << 16, shift: 24)))
    let sh2_2 = SIMD3<Float>(Float(signExtend(packed.y << 8, shift: 24)), Float(Int32(bitPattern: packed.y) >> 24), Float(signExtend(packed.z, shift: 24)))
    let sh2_3 = SIMD3<Float>(Float(signExtend(packed.z << 16, shift: 24)), Float(signExtend(packed.z << 8, shift: 24)), Float(Int32(bitPattern: packed.z) >> 24))
    let sh2_4 = SIMD3<Float>(Float(signExtend(packed.w, shift: 24)), Float(signExtend(packed.w << 16, shift: 24)), Float(signExtend(packed.w << 8, shift: 24)))

    let rgb = sh2_0 * (1.0925484 * viewDirection.x * viewDirection.y)
        + sh2_1 * (-1.0925484 * viewDirection.y * viewDirection.z)
        + sh2_2 * (0.3153915 * (2.0 * viewDirection.z * viewDirection.z - viewDirection.x * viewDirection.x - viewDirection.y * viewDirection.y))
        + sh2_3 * (-1.0925484 * viewDirection.x * viewDirection.z)
        + sh2_4 * (0.5462742 * (viewDirection.x * viewDirection.x - viewDirection.y * viewDirection.y))
    return rgb * (sh2Max / 127.0)
}

private func evaluatePackedSH3(
    _ packed: SIMD4<UInt32>,
    viewDirection: SIMD3<Float>,
    sh3Max: Float
) -> SIMD3<Float> {
    let sh3_0 = SIMD3<Float>(Float(signExtend(packed.x, shift: 26)), Float(signExtend(packed.x << 20, shift: 26)), Float(signExtend(packed.x << 14, shift: 26)))
    let sh3_1 = SIMD3<Float>(Float(signExtend(packed.x << 8, shift: 26)), Float(signExtend(packed.x << 2, shift: 26)), Float(signExtend((packed.x >> 4) | (packed.y << 28), shift: 26)))
    let sh3_2 = SIMD3<Float>(Float(signExtend(packed.y << 22, shift: 26)), Float(signExtend(packed.y << 16, shift: 26)), Float(signExtend(packed.y << 10, shift: 26)))
    let sh3_3 = SIMD3<Float>(Float(signExtend(packed.y << 4, shift: 26)), Float(signExtend((packed.y >> 2) | (packed.z << 30), shift: 26)), Float(signExtend(packed.z << 24, shift: 26)))
    let sh3_4 = SIMD3<Float>(Float(signExtend(packed.z << 18, shift: 26)), Float(signExtend(packed.z << 12, shift: 26)), Float(signExtend(packed.z << 6, shift: 26)))
    let sh3_5 = SIMD3<Float>(Float(Int32(bitPattern: packed.z) >> 26), Float(signExtend(packed.w << 26, shift: 26)), Float(signExtend(packed.w << 20, shift: 26)))
    let sh3_6 = SIMD3<Float>(Float(signExtend(packed.w << 14, shift: 26)), Float(signExtend(packed.w << 8, shift: 26)), Float(signExtend(packed.w << 2, shift: 26)))

    let xx = viewDirection.x * viewDirection.x
    let yy = viewDirection.y * viewDirection.y
    let zz = viewDirection.z * viewDirection.z
    let xy = viewDirection.x * viewDirection.y

    var rgb = SIMD3<Float>(repeating: 0.0)
    rgb += sh3_0 * (-0.5900436 * viewDirection.y * (3.0 * xx - yy))
    rgb += sh3_1 * (2.8906114 * xy * viewDirection.z)
    rgb += sh3_2 * (-0.4570458 * viewDirection.y * (4.0 * zz - xx - yy))
    rgb += sh3_3 * (0.3731763 * viewDirection.z * (2.0 * zz - 3.0 * xx - 3.0 * yy))
    rgb += sh3_4 * (-0.4570458 * viewDirection.x * (4.0 * zz - xx - yy))
    rgb += sh3_5 * (1.4453057 * viewDirection.z * (xx - yy))
    rgb += sh3_6 * (-0.5900436 * viewDirection.x * (xx - 3.0 * yy))
    return rgb * (sh3Max / 31.0)
}

private func signExtend(_ value: UInt32, shift: UInt32) -> Int32 {
    Int32(bitPattern: value << shift) >> Int32(shift)
}

func encodeSH1(_ coefficients: [Float], into sh1: inout [UInt32], at index: Int, encoding: SplatEncoding) {
    let base = index * 2
    let scale = 63.0 / encoding.sh1Max
    for i in 0 ..< min(coefficients.count, 9) {
        let value = UInt32(Int32(round(min(max(coefficients[i] * scale, -63.0), 63.0))) & 0x7f)
        let bitStart = i * 7
        let wordStart = bitStart / 32
        let bitOffset = bitStart - wordStart * 32
        sh1[base + wordStart] |= value << UInt32(bitOffset)
        if bitOffset > 25 {
            sh1[base + wordStart + 1] |= value >> UInt32(32 - bitOffset)
        }
    }
}

func encodeSH2(_ coefficients: [Float], into sh2: inout [UInt32], at index: Int, encoding: SplatEncoding) {
    let scale = 1.0 / encoding.sh2Max
    let base = index * 4
    sh2[base + 0] = packSignedNormalizedBytes(coefficients, offset: 0, scale: scale, maxValue: 127.0)
    sh2[base + 1] = packSignedNormalizedBytes(coefficients, offset: 4, scale: scale, maxValue: 127.0)
    sh2[base + 2] = packSignedNormalizedBytes(coefficients, offset: 8, scale: scale, maxValue: 127.0)
    sh2[base + 3] = packSignedNormalizedBytes(coefficients, offset: 12, scale: scale, maxValue: 127.0)
}

func encodeSH3(_ coefficients: [Float], into sh3: inout [UInt32], at index: Int, encoding: SplatEncoding) {
    let base = index * 4
    let scale = 31.0 / encoding.sh3Max
    for i in 0 ..< min(coefficients.count, 21) {
        let value = UInt32(Int32(round(min(max(coefficients[i] * scale, -31.0), 31.0))) & 0x3f)
        let bitStart = i * 6
        let wordStart = bitStart / 32
        let bitOffset = bitStart - wordStart * 32
        sh3[base + wordStart] |= value << UInt32(bitOffset)
        if bitOffset > 26 {
            sh3[base + wordStart + 1] |= value >> UInt32(32 - bitOffset)
        }
    }
}

private func packSignedNormalizedBytes(_ coefficients: [Float], offset: Int, scale: Float, maxValue: Float) -> UInt32 {
    var word: UInt32 = 0
    for lane in 0 ..< 4 {
        let coefficientIndex = offset + lane
        let coefficient = coefficientIndex < coefficients.count ? coefficients[coefficientIndex] : 0.0
        let value = UInt32(Int32(round(min(max(coefficient * scale * maxValue, -maxValue), maxValue))) & 0xff)
        word |= value << UInt32(lane * 8)
    }
    return word
}
