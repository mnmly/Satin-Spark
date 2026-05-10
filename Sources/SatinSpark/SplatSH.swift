// Spherical harmonics packing/evaluation layout is ported from Spark's
// `src/utils.ts` and `src/PackedSplats.ts`.

import Foundation

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

    mutating func setSH1(_ coefficients: [Float], at index: Int, encoding: SplatEncoding) {
        guard sh1 != nil else { return }
        encodeSH1(coefficients, into: &sh1!, at: index, encoding: encoding)
    }

    mutating func setSH2(_ coefficients: [Float], at index: Int, encoding: SplatEncoding) {
        guard sh2 != nil else { return }
        encodeSH2(coefficients, into: &sh2!, at: index, encoding: encoding)
    }

    mutating func setSH3(_ coefficients: [Float], at index: Int, encoding: SplatEncoding) {
        guard sh3 != nil else { return }
        encodeSH3(coefficients, into: &sh3!, at: index, encoding: encoding)
    }
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
