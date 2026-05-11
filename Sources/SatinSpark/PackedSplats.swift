// Packed splat byte layout, encoding helpers, and PLY-side conventions are ported
// from https://github.com/sparkjsdev/spark — `src/utils.ts`, `src/PackedSplats.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import Metal
import simd

public enum SplatSortMetric: Sendable, Equatable {
    case viewZ
    case radial
}

public final class PackedSplats: @unchecked Sendable {
    public private(set) var maxSplats: Int
    public private(set) var numSplats: Int
    public private(set) var packedArray: [UInt32]
    public var sphericalHarmonics: PackedSphericalHarmonics
    public var splatEncoding: SplatEncoding

    public init(
        packedArray: [UInt32] = [],
        numSplats: Int? = nil,
        maxSplats: Int? = nil,
        sphericalHarmonics: PackedSphericalHarmonics = PackedSphericalHarmonics(),
        splatEncoding: SplatEncoding = SplatEncoding()
    ) {
        precondition(packedArray.count.isMultiple(of: 4), "Packed splat arrays must contain 4 UInt32 words per splat")
        self.packedArray = packedArray
        self.numSplats = min(numSplats ?? packedArray.count / 4, packedArray.count / 4)
        self.maxSplats = max(maxSplats ?? packedArray.count / 4, self.numSplats)
        self.sphericalHarmonics = sphericalHarmonics
        self.splatEncoding = splatEncoding

        let requiredWords = self.maxSplats * 4
        if self.packedArray.count < requiredWords {
            self.packedArray.append(contentsOf: repeatElement(0, count: requiredWords - self.packedArray.count))
        }
    }

    public convenience init(splats: [PackedSplat], splatEncoding: SplatEncoding = SplatEncoding()) {
        let result = PackedSplats(maxSplats: splats.count, splatEncoding: splatEncoding)
        for (index, splat) in splats.enumerated() {
            result.setSplat(splat, at: index)
        }
        result.numSplats = splats.count
        self.init(
            packedArray: result.packedArray,
            numSplats: result.numSplats,
            sphericalHarmonics: result.sphericalHarmonics,
            splatEncoding: splatEncoding
        )
    }

    public func makeBuffer(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        guard !packedArray.isEmpty else { return nil }
        return packedArray.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: options)
        }
    }

    public func makeIdentityOrderingBuffer(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        guard numSplats > 0 else { return nil }
        let ordering = (0 ..< numSplats).map(UInt32.init)
        return ordering.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: options)
        }
    }

    public func makeSH1Buffer(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        makeBuffer(from: sphericalHarmonics.sh1, device: device, options: options)
    }

    public func makeSH2Buffer(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        makeBuffer(from: sphericalHarmonics.sh2, device: device, options: options)
    }

    public func makeSH3Buffer(device: MTLDevice, options: MTLResourceOptions = .storageModeShared) -> MTLBuffer? {
        makeBuffer(from: sphericalHarmonics.sh3, device: device, options: options)
    }

    public func sortedOrdering(
        modelViewMatrix: simd_float4x4,
        metric: SplatSortMetric = .radial
    ) -> [UInt32] {
        Self.sortedOrdering(
            packedArray: packedArray,
            numSplats: numSplats,
            modelViewMatrix: modelViewMatrix,
            metric: metric
        )
    }

    static func sortedOrdering(
        packedArray: [UInt32],
        numSplats: Int,
        modelViewMatrix: simd_float4x4,
        metric: SplatSortMetric = .radial
    ) -> [UInt32] {
        guard numSplats > 0 else { return [] }
        let entries = (0 ..< numSplats).map { index -> (index: UInt32, key: Float) in
            let center = fastCenter(in: packedArray, at: index)
            let viewCenter = (modelViewMatrix * SIMD4<Float>(center, 1.0)).xyz
            let key: Float
            switch metric {
            case .viewZ:
                key = viewCenter.z
            case .radial:
                key = simd_length_squared(viewCenter)
            }
            return (UInt32(index), key)
        }
        return entries.sorted { lhs, rhs in
            if lhs.key == rhs.key {
                return lhs.index < rhs.index
            }
            switch metric {
            case .viewZ:
                return lhs.key < rhs.key
            case .radial:
                return lhs.key > rhs.key
            }
        }.map(\.index)
    }

    private func fastCenter(at index: Int) -> SIMD3<Float> {
        Self.fastCenter(in: packedArray, at: index)
    }

    private static func fastCenter(in packedArray: [UInt32], at index: Int) -> SIMD3<Float> {
        let offset = index * 4
        let xy = packedArray[offset + 1]
        let zq = packedArray[offset + 2]
        return SIMD3<Float>(
            Float(Float16(bitPattern: UInt16(xy & 0xffff))),
            Float(Float16(bitPattern: UInt16((xy >> 16) & 0xffff))),
            Float(Float16(bitPattern: UInt16(zq & 0xffff)))
        )
    }

    public func makeOrderingBuffer(
        device: MTLDevice,
        ordering: [UInt32],
        options: MTLResourceOptions = .storageModeShared
    ) -> MTLBuffer? {
        guard !ordering.isEmpty else { return nil }
        return ordering.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: options)
        }
    }

    public func setSplat(_ splat: PackedSplat, at index: Int) {
        ensureCapacity(index + 1)
        let encoded = splat.encoded(encoding: splatEncoding)
        let offset = index * 4
        packedArray[offset + 0] = encoded.0
        packedArray[offset + 1] = encoded.1
        packedArray[offset + 2] = encoded.2
        packedArray[offset + 3] = encoded.3
        numSplats = max(numSplats, index + 1)
    }

    public func getSplat(at index: Int) -> PackedSplat {
        let decoded = SplatReference.decodePackedSplat(packedWords(at: index), encoding: splatEncoding)
        return PackedSplat(
            center: decoded.center,
            scale: decoded.scales,
            rotation: decoded.rotation,
            opacity: decoded.rgba.w,
            color: decoded.rgba.xyz
        )
    }

    public func forEachSplat(_ body: (_ index: Int, _ splat: PackedSplat) throws -> Void) rethrows {
        guard numSplats > 0 else { return }
        for index in 0 ..< numSplats {
            try body(index, getSplat(at: index))
        }
    }

    public func setCenter(_ center: SIMD3<Float>, at index: Int) {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let offset = index * 4
        let hx = UInt32(Float16(finiteOrZero(center.x)).bitPattern)
        let hy = UInt32(Float16(finiteOrZero(center.y)).bitPattern)
        let hz = UInt32(Float16(finiteOrZero(center.z)).bitPattern)
        packedArray[offset + 1] = hx | (hy << 16)
        packedArray[offset + 2] = hz | (packedArray[offset + 2] & 0xffff0000)
    }

    public func setScale(_ scale: SIMD3<Float>, at index: Int) {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let offset = index * 4
        let sx = encodePackedScale(scale.x, encoding: splatEncoding)
        let sy = encodePackedScale(scale.y, encoding: splatEncoding)
        let sz = encodePackedScale(scale.z, encoding: splatEncoding)
        packedArray[offset + 3] = sx | (sy << 8) | (sz << 16) | (packedArray[offset + 3] & 0xff000000)
    }

    public func setRotation(_ rotation: simd_quatf, at index: Int) {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let encoded = encodeQuatOctXy88R8(rotation)
        let qx = encoded & 0xff
        let qy = (encoded >> 8) & 0xff
        let qz = (encoded >> 16) & 0xff
        let offset = index * 4
        packedArray[offset + 2] = (packedArray[offset + 2] & 0x0000ffff) | (qx << 16) | (qy << 24)
        packedArray[offset + 3] = (packedArray[offset + 3] & 0x00ffffff) | (qz << 24)
    }

    public func setRGBA(color: SIMD3<Float>, opacity: Float, at index: Int) {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let offset = index * 4
        packedArray[offset] = packedRGBAWord(color: color, opacity: opacity, encoding: splatEncoding)
    }

    public func setColor(_ color: SIMD3<Float>, at index: Int) {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let offset = index * 4
        let rgb = packedRGBWord(color: color, encoding: splatEncoding)
        packedArray[offset] = rgb | (packedArray[offset] & 0xff000000)
    }

    public func setOpacity(_ opacity: Float, at index: Int) {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let offset = index * 4
        let alpha = floatToUInt8(opacity)
        packedArray[offset] = (packedArray[offset] & 0x00ffffff) | (alpha << 24)
    }

    private func ensureCapacity(_ count: Int) {
        guard count > maxSplats else { return }
        maxSplats = count
        packedArray.append(contentsOf: repeatElement(0, count: count * 4 - packedArray.count))
    }

    private func makeBuffer(
        from words: [UInt32]?,
        device: MTLDevice,
        options: MTLResourceOptions
    ) -> MTLBuffer? {
        guard let words, !words.isEmpty else { return nil }
        return words.withUnsafeBytes { bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: options)
        }
    }

    public func packedWords(at index: Int) -> SIMD4<UInt32> {
        precondition(index >= 0 && index < numSplats, "Splat index out of range")
        let offset = index * 4
        return SIMD4(
            packedArray[offset + 0],
            packedArray[offset + 1],
            packedArray[offset + 2],
            packedArray[offset + 3]
        )
    }
}

public struct PackedSplat: Sendable, Equatable {
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

    func encoded(encoding: SplatEncoding) -> (UInt32, UInt32, UInt32, UInt32) {
        let quat = encodeQuatOctXy88R8(rotation)
        let qx = quat & 0xff
        let qy = (quat >> 8) & 0xff
        let qz = (quat >> 16) & 0xff

        let sx = encodePackedScale(scale.x, encoding: encoding)
        let sy = encodePackedScale(scale.y, encoding: encoding)
        let sz = encodePackedScale(scale.z, encoding: encoding)

        let hx = UInt32(Float16(finiteOrZero(center.x)).bitPattern)
        let hy = UInt32(Float16(finiteOrZero(center.y)).bitPattern)
        let hz = UInt32(Float16(finiteOrZero(center.z)).bitPattern)

        let word0 = packedRGBAWord(color: color, opacity: opacity, encoding: encoding)
        let word1 = hx | (hy << 16)
        let word2 = hz | (qx << 16) | (qy << 24)
        let word3 = sx | (sy << 8) | (sz << 16) | (qz << 24)
        return (word0, word1, word2, word3)
    }
}

func packedRGBAWord(color: SIMD3<Float>, opacity: Float, encoding: SplatEncoding) -> UInt32 {
    packedRGBWord(color: color, encoding: encoding)
        | (floatToUInt8(encoding.lodOpacity ? 0.5 * opacity : opacity) << 24)
}

func packedRGBWord(color: SIMD3<Float>, encoding: SplatEncoding) -> UInt32 {
    let rgbRange = encoding.rgbMax - encoding.rgbMin
    let r = floatToUInt8((color.x - encoding.rgbMin) / rgbRange)
    let g = floatToUInt8((color.y - encoding.rgbMin) / rgbRange)
    let b = floatToUInt8((color.z - encoding.rgbMin) / rgbRange)
    return r | (g << 8) | (b << 16)
}

func encodePackedScale(_ value: Float, encoding: SplatEncoding) -> UInt32 {
    guard value.isFinite, value >= SparkConstants.scaleZero else {
        return 0
    }
    let scale = 254.0 / (encoding.lnScaleMax - encoding.lnScaleMin)
    let lnValue = log(value)
    guard lnValue.isFinite else {
        return 0
    }
    let encoded = round((lnValue - encoding.lnScaleMin) * scale) + 1.0
    return UInt32(min(max(encoded, 1.0), 255.0))
}

@inline(__always)
func finiteOrZero(_ value: Float) -> Float {
    value.isFinite ? value : 0.0
}

private extension SIMD4 where Scalar == Float {
    var xyz: SIMD3<Float> {
        SIMD3(x, y, z)
    }
}
