// Extended splat encoding is ported from https://github.com/sparkjsdev/spark —
// `src/ExtSplats.ts` and `src/utils.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import Metal
import simd

public struct ExtSplat: Sendable, Equatable {
    public var center: SIMD3<Float>
    public var scale: SIMD3<Float>
    public var rotation: simd_quatf
    public var opacity: Float
    public var color: SIMD3<Float>

    public init(
        center: SIMD3<Float>,
        scale: SIMD3<Float>,
        rotation: simd_quatf = simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0]),
        opacity: Float = 1.0,
        color: SIMD3<Float> = [1.0, 1.0, 1.0]
    ) {
        self.center = center
        self.scale = scale
        self.rotation = rotation
        self.opacity = opacity
        self.color = color
    }

    public var covariance: simd_float3x3 {
        covarianceMatrix(scale: scale, rotation: rotation)
    }

    public var packedSplat: PackedSplat {
        PackedSplat(center: center, scale: scale, rotation: rotation, opacity: opacity, color: color)
    }
}

public final class ExtSplats: @unchecked Sendable {
    public private(set) var maxSplats: Int
    public private(set) var numSplats: Int
    public private(set) var extArrayA: [UInt32]
    public private(set) var extArrayB: [UInt32]

    public init(
        extArrayA: [UInt32] = [],
        extArrayB: [UInt32] = [],
        numSplats: Int? = nil,
        maxSplats: Int? = nil
    ) {
        precondition(extArrayA.count.isMultiple(of: 4), "Ext splat arrays must contain 4 UInt32 words per splat")
        precondition(extArrayB.count.isMultiple(of: 4), "Ext splat arrays must contain 4 UInt32 words per splat")
        let arraySplats = min(extArrayA.count / 4, extArrayB.count / 4)
        self.numSplats = min(numSplats ?? arraySplats, arraySplats)
        self.maxSplats = max(maxSplats ?? arraySplats, self.numSplats)
        self.extArrayA = extArrayA
        self.extArrayB = extArrayB

        let requiredWords = self.maxSplats * 4
        if self.extArrayA.count < requiredWords {
            self.extArrayA.append(contentsOf: repeatElement(0, count: requiredWords - self.extArrayA.count))
        }
        if self.extArrayB.count < requiredWords {
            self.extArrayB.append(contentsOf: repeatElement(0, count: requiredWords - self.extArrayB.count))
        }
    }

    public convenience init(splats: [ExtSplat]) {
        let result = ExtSplats(maxSplats: splats.count)
        for (index, splat) in splats.enumerated() {
            result.setSplat(splat, at: index)
        }
        result.numSplats = splats.count
        self.init(
            extArrayA: result.extArrayA,
            extArrayB: result.extArrayB,
            numSplats: result.numSplats
        )
    }

    public convenience init(packedSplats: PackedSplats) {
        var splats: [ExtSplat] = []
        splats.reserveCapacity(packedSplats.numSplats)
        packedSplats.forEachSplat { _, splat in
            splats.append(
                ExtSplat(
                    center: splat.center,
                    scale: splat.scale,
                    rotation: splat.rotation,
                    opacity: splat.opacity,
                    color: splat.color
                )
            )
        }
        self.init(splats: splats)
    }

    public func makeBufferA(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        makeBuffer(from: extArrayA, device: device, options: options)
    }

    public func makeBufferB(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        makeBuffer(from: extArrayB, device: device, options: options)
    }

    public func setSplat(_ splat: ExtSplat, at index: Int) {
        ensureCapacity(index + 1)
        encodeExtSplat(splat, intoA: &extArrayA, intoB: &extArrayB, at: index)
        numSplats = max(numSplats, index + 1)
    }

    public func getSplat(at index: Int) -> ExtSplat {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        return decodeExtSplat(arrayA: extArrayA, arrayB: extArrayB, at: index)
    }

    public func forEachSplat(_ body: (_ index: Int, _ splat: ExtSplat) throws -> Void) rethrows {
        guard numSplats > 0 else { return }
        for index in 0 ..< numSplats {
            try body(index, getSplat(at: index))
        }
    }

    public func toPackedSplats(encoding: SplatEncoding = SplatEncoding()) -> PackedSplats {
        var splats: [PackedSplat] = []
        splats.reserveCapacity(numSplats)
        forEachSplat { _, splat in
            splats.append(splat.packedSplat)
        }
        return PackedSplats(splats: splats, splatEncoding: encoding)
    }

    private func ensureCapacity(_ count: Int) {
        guard count > maxSplats else { return }
        maxSplats = count
        extArrayA.append(contentsOf: repeatElement(0, count: count * 4 - extArrayA.count))
        extArrayB.append(contentsOf: repeatElement(0, count: count * 4 - extArrayB.count))
    }

    private func makeBuffer(
        from words: [UInt32],
        device: MTLDevice,
        options: MTLResourceOptions
    ) -> MTLBuffer? {
        guard !words.isEmpty else { return nil }
        return words.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: options)
        }
    }
}

public func covarianceMatrix(scale: SIMD3<Float>, rotation: simd_quatf) -> simd_float3x3 {
    let r = simd_float3x3(rotation)
    let s2 = SIMD3<Float>(scale.x * scale.x, scale.y * scale.y, scale.z * scale.z)
    return r * simd_float3x3(
        SIMD3<Float>(s2.x, 0.0, 0.0),
        SIMD3<Float>(0.0, s2.y, 0.0),
        SIMD3<Float>(0.0, 0.0, s2.z)
    ) * r.transpose
}

func encodeExtSplat(_ splat: ExtSplat, intoA extA: inout [UInt32], intoB extB: inout [UInt32], at index: Int) {
    let i4 = index * 4
    extA[i4 + 0] = finiteOrZero(splat.center.x).bitPattern
    extA[i4 + 1] = finiteOrZero(splat.center.y).bitPattern
    extA[i4 + 2] = finiteOrZero(splat.center.z).bitPattern
    extA[i4 + 3] = UInt32(Float16(finiteOrZero(splat.opacity)).bitPattern)

    let logScale = SIMD3<Float>(
        log(max(finiteOrZero(splat.scale.x), .leastNonzeroMagnitude)),
        log(max(finiteOrZero(splat.scale.y), .leastNonzeroMagnitude)),
        log(max(finiteOrZero(splat.scale.z), .leastNonzeroMagnitude))
    )
    extB[i4 + 0] = UInt32(Float16(finiteOrZero(splat.color.x)).bitPattern)
        | (UInt32(Float16(finiteOrZero(splat.color.y)).bitPattern) << 16)
    extB[i4 + 1] = UInt32(Float16(finiteOrZero(splat.color.z)).bitPattern)
        | (UInt32(Float16(logScale.x).bitPattern) << 16)
    extB[i4 + 2] = UInt32(Float16(logScale.y).bitPattern)
        | (UInt32(Float16(logScale.z).bitPattern) << 16)
    extB[i4 + 3] = encodeQuatOctXy1010R12(splat.rotation)
}

func decodeExtSplat(arrayA extA: [UInt32], arrayB extB: [UInt32], at index: Int) -> ExtSplat {
    let i4 = index * 4
    let center = SIMD3<Float>(
        Float(bitPattern: extA[i4 + 0]),
        Float(bitPattern: extA[i4 + 1]),
        Float(bitPattern: extA[i4 + 2])
    )
    let opacity = Float(Float16(bitPattern: UInt16(extA[i4 + 3] & 0xffff)))
    let color = SIMD3<Float>(
        Float(Float16(bitPattern: UInt16(extB[i4 + 0] & 0xffff))),
        Float(Float16(bitPattern: UInt16((extB[i4 + 0] >> 16) & 0xffff))),
        Float(Float16(bitPattern: UInt16(extB[i4 + 1] & 0xffff)))
    )
    let scale = SIMD3<Float>(
        exp(Float(Float16(bitPattern: UInt16((extB[i4 + 1] >> 16) & 0xffff)))),
        exp(Float(Float16(bitPattern: UInt16(extB[i4 + 2] & 0xffff)))),
        exp(Float(Float16(bitPattern: UInt16((extB[i4 + 2] >> 16) & 0xffff))))
    )
    return ExtSplat(
        center: center,
        scale: scale,
        rotation: decodeQuatOctXy1010R12(extB[i4 + 3]),
        opacity: opacity,
        color: color
    )
}

func encodeQuatOctXy1010R12(_ quaternion: simd_quatf) -> UInt32 {
    var q = simd_normalize(quaternion.vector)
    if q.w < 0.0 {
        q = -q
    }

    let theta = 2.0 * acos(min(max(q.w, -1.0), 1.0))
    let xyzNorm = simd_length(q.xyz)
    let axis = xyzNorm < 1.0e-6 ? SIMD3<Float>(1.0, 0.0, 0.0) : q.xyz / xyzNorm
    let denom = abs(axis.x) + abs(axis.y) + abs(axis.z)
    var p = SIMD2<Float>(axis.x, axis.y) / max(denom, .leastNonzeroMagnitude)
    if axis.z < 0.0 {
        let oldX = p.x
        p.x = (1.0 - abs(p.y)) * (p.x >= 0.0 ? 1.0 : -1.0)
        p.y = (1.0 - abs(oldX)) * (p.y >= 0.0 ? 1.0 : -1.0)
    }

    let u = UInt32(min(max(round((p.x * 0.5 + 0.5) * 1023.0), 0.0), 1023.0))
    let v = UInt32(min(max(round((p.y * 0.5 + 0.5) * 1023.0), 0.0), 1023.0))
    let angle = UInt32(min(max(round((theta / Float.pi) * 4095.0), 0.0), 4095.0))
    return u | (v << 10) | (angle << 20)
}

func decodeQuatOctXy1010R12(_ encoded: UInt32) -> simd_quatf {
    let quantU = encoded & 0x3ff
    let quantV = (encoded >> 10) & 0x3ff
    let angleInt = (encoded >> 20) & 0xfff

    var axis = SIMD3<Float>(
        (Float(quantU) / 1023.0 - 0.5) * 2.0,
        (Float(quantV) / 1023.0 - 0.5) * 2.0,
        0.0
    )
    axis.z = 1.0 - abs(axis.x) - abs(axis.y)
    let t = max(-axis.z, 0.0)
    axis.x += axis.x >= 0.0 ? -t : t
    axis.y += axis.y >= 0.0 ? -t : t
    axis = simd_length(axis) < 1.0e-6 ? [1.0, 0.0, 0.0] : simd_normalize(axis)

    let theta = (Float(angleInt) / 4095.0) * Float.pi
    let halfTheta = theta * 0.5
    return simd_quatf(vector: SIMD4<Float>(axis * sin(halfTheta), cos(halfTheta)))
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
