// KSPLAT decoding is ported from https://github.com/sparkjsdev/spark —
// `src/ksplat.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import simd

public enum SplatKSPLATLoaderError: LocalizedError {
    case truncatedFile
    case unsupportedVersion(UInt8, UInt8)
    case invalidCompressionLevel(UInt16)
    case invalidSphericalHarmonicsDegree(UInt16)
    case invalidSection(index: Int, reason: String)

    public var errorDescription: String? {
        switch self {
        case .truncatedFile:
            return "The KSPLAT file ended before all splat data could be read."
        case let .unsupportedVersion(major, minor):
            return "Unsupported KSPLAT version: \(major).\(minor)."
        case let .invalidCompressionLevel(level):
            return "Invalid KSPLAT compression level: \(level)."
        case let .invalidSphericalHarmonicsDegree(degree):
            return "Invalid KSPLAT spherical harmonics degree: \(degree)."
        case let .invalidSection(index, reason):
            return "Invalid KSPLAT section \(index): \(reason)."
        }
    }
}

public enum SplatKSPLATLoader {
    public static let headerByteCount = 4096
    public static let sectionHeaderByteCount = 1024

    public static func load(url: URL) throws -> PackedSplats {
        try parse(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func parse(_ data: Data, encoding: SplatEncoding = SplatEncoding()) throws -> PackedSplats {
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            try ksplatRequireBytes(headerByteCount, cursor: 0, count: bytes.count)

            let versionMajor = bytes[0]
            let versionMinor = bytes[1]
            guard versionMajor == 0, versionMinor >= 1 else {
                throw SplatKSPLATLoaderError.unsupportedVersion(versionMajor, versionMinor)
            }

            let maxSectionCount = Int(ksplatReadUInt32(bytes, offset: 4))
            let splatCount = Int(ksplatReadUInt32(bytes, offset: 16))
            let compressionLevel = ksplatReadUInt16(bytes, offset: 20)
            guard let compression = KSPLATCompression(level: compressionLevel) else {
                throw SplatKSPLATLoaderError.invalidCompressionLevel(compressionLevel)
            }
            let minSH = ksplatReadFloat32(bytes, offset: 36)
            let maxSH = ksplatReadFloat32(bytes, offset: 40)
            let minSphericalHarmonicsCoeff = minSH == 0.0 ? -1.5 : minSH
            let maxSphericalHarmonicsCoeff = maxSH == 0.0 ? 1.5 : maxSH

            let sectionHeadersByteCount = maxSectionCount * sectionHeaderByteCount
            try ksplatRequireBytes(sectionHeadersByteCount, cursor: headerByteCount, count: bytes.count)

            var packedArray = Array(repeating: UInt32(0), count: splatCount * 4)
            var sectionBase = headerByteCount + sectionHeadersByteCount
            var globalSplatIndex = 0

            for sectionIndex in 0 ..< maxSectionCount {
                let headerOffset = headerByteCount + sectionIndex * sectionHeaderByteCount
                let sectionSplatCount = Int(ksplatReadUInt32(bytes, offset: headerOffset + 0))
                let sectionMaxSplatCount = Int(ksplatReadUInt32(bytes, offset: headerOffset + 4))
                let bucketSize = Int(ksplatReadUInt32(bytes, offset: headerOffset + 8))
                let bucketCount = Int(ksplatReadUInt32(bytes, offset: headerOffset + 12))
                let bucketBlockSize = ksplatReadFloat32(bytes, offset: headerOffset + 16)
                let bucketStorageSizeBytes = Int(ksplatReadUInt16(bytes, offset: headerOffset + 20))
                let rawCompressionScaleRange = ksplatReadUInt32(bytes, offset: headerOffset + 24)
                let compressionScaleRange = rawCompressionScaleRange == 0
                    ? compression.defaultScaleRange
                    : Float(rawCompressionScaleRange)
                let fullBucketCount = Int(ksplatReadUInt32(bytes, offset: headerOffset + 32))
                let partiallyFilledBucketCount = Int(ksplatReadUInt32(bytes, offset: headerOffset + 36))
                let sphericalHarmonicsDegree = ksplatReadUInt16(bytes, offset: headerOffset + 40)
                guard let shComponents = ksplatSHComponents(degree: sphericalHarmonicsDegree) else {
                    throw SplatKSPLATLoaderError.invalidSphericalHarmonicsDegree(sphericalHarmonicsDegree)
                }

                guard sectionSplatCount <= sectionMaxSplatCount else {
                    throw SplatKSPLATLoaderError.invalidSection(
                        index: sectionIndex,
                        reason: "section splat count exceeds max splat count"
                    )
                }
                guard sectionSplatCount == 0 || compressionLevel == 0 || bucketSize > 0 else {
                    throw SplatKSPLATLoaderError.invalidSection(index: sectionIndex, reason: "compressed section has zero bucket size")
                }
                guard globalSplatIndex + sectionSplatCount <= splatCount else {
                    throw SplatKSPLATLoaderError.invalidSection(index: sectionIndex, reason: "section splats exceed file splat count")
                }

                let bucketMetadataSizeBytes = partiallyFilledBucketCount * 4
                let bucketsStorageSizeBytes = bucketStorageSizeBytes * bucketCount + bucketMetadataSizeBytes
                let bytesPerSplat = compression.bytesPerSplat(shComponents: shComponents)
                let splatDataStorageSizeBytes = bytesPerSplat * sectionMaxSplatCount
                let storageSizeBytes = bucketsStorageSizeBytes + splatDataStorageSizeBytes
                try ksplatRequireBytes(storageSizeBytes, cursor: sectionBase, count: bytes.count)

                let bucketsBase = sectionBase + bucketMetadataSizeBytes
                let dataBase = sectionBase + bucketsStorageSizeBytes
                let compressionScaleFactor = bucketBlockSize / 2.0 / compressionScaleRange
                let fullBucketSplats = fullBucketCount * bucketSize
                var partialBucketIndex = fullBucketCount
                var partialBucketBase = fullBucketSplats

                for localIndex in 0 ..< sectionSplatCount {
                    let splatOffset = dataBase + localIndex * bytesPerSplat
                    let bucketIndex: Int
                    if compressionLevel == 0 {
                        bucketIndex = 0
                    } else if localIndex < fullBucketSplats {
                        bucketIndex = localIndex / bucketSize
                    } else {
                        var bucketLength = partialBucketLength(
                            bytes,
                            sectionBase: sectionBase,
                            partialBucketIndex: partialBucketIndex,
                            fullBucketCount: fullBucketCount,
                            partiallyFilledBucketCount: partiallyFilledBucketCount
                        )
                        while localIndex >= partialBucketBase + bucketLength,
                              partialBucketIndex + 1 < bucketCount {
                            partialBucketIndex += 1
                            partialBucketBase += bucketLength
                            bucketLength = partialBucketLength(
                                bytes,
                                sectionBase: sectionBase,
                                partialBucketIndex: partialBucketIndex,
                                fullBucketCount: fullBucketCount,
                                partiallyFilledBucketCount: partiallyFilledBucketCount
                            )
                        }
                        bucketIndex = partialBucketIndex
                    }
                    guard compressionLevel == 0 || bucketIndex < bucketCount else {
                        throw SplatKSPLATLoaderError.invalidSection(index: sectionIndex, reason: "bucket index out of range")
                    }

                    let center: SIMD3<Float>
                    if compressionLevel == 0 {
                        center = SIMD3<Float>(
                            ksplatReadFloat32(bytes, offset: splatOffset + 0),
                            ksplatReadFloat32(bytes, offset: splatOffset + 4),
                            ksplatReadFloat32(bytes, offset: splatOffset + 8)
                        )
                    } else {
                        let bucketOffset = bucketsBase + bucketIndex * 12
                        let bucketCenter = SIMD3<Float>(
                            ksplatReadFloat32(bytes, offset: bucketOffset + 0),
                            ksplatReadFloat32(bytes, offset: bucketOffset + 4),
                            ksplatReadFloat32(bytes, offset: bucketOffset + 8)
                        )
                        center = SIMD3<Float>(
                            (Float(ksplatReadUInt16(bytes, offset: splatOffset + 0)) - compressionScaleRange) * compressionScaleFactor + bucketCenter.x,
                            (Float(ksplatReadUInt16(bytes, offset: splatOffset + 2)) - compressionScaleRange) * compressionScaleFactor + bucketCenter.y,
                            (Float(ksplatReadUInt16(bytes, offset: splatOffset + 4)) - compressionScaleRange) * compressionScaleFactor + bucketCenter.z
                        )
                    }

                    let scale = SIMD3<Float>(
                        compression.readScale(bytes, splatOffset: splatOffset, componentOffset: 0),
                        compression.readScale(bytes, splatOffset: splatOffset, componentOffset: 1),
                        compression.readScale(bytes, splatOffset: splatOffset, componentOffset: 2)
                    )
                    let rotation = normalizedPackedQuaternion(
                        r: compression.readRotation(bytes, splatOffset: splatOffset, componentOffset: 0),
                        i: compression.readRotation(bytes, splatOffset: splatOffset, componentOffset: 1),
                        j: compression.readRotation(bytes, splatOffset: splatOffset, componentOffset: 2),
                        k: compression.readRotation(bytes, splatOffset: splatOffset, componentOffset: 3)
                    )
                    let colorOffset = splatOffset + compression.colorOffsetBytes
                    let color = SIMD3<Float>(
                        Float(bytes[colorOffset + 0]) / 255.0,
                        Float(bytes[colorOffset + 1]) / 255.0,
                        Float(bytes[colorOffset + 2]) / 255.0
                    )
                    let opacity = Float(bytes[colorOffset + 3]) / 255.0

                    writePackedSplatWords(
                        center: center,
                        scale: scale,
                        rotation: rotation,
                        color: color,
                        opacity: opacity,
                        encoding: encoding,
                        into: &packedArray,
                        at: globalSplatIndex + localIndex
                    )
                }

                _ = (minSphericalHarmonicsCoeff, maxSphericalHarmonicsCoeff)
                globalSplatIndex += sectionSplatCount
                sectionBase += storageSizeBytes
            }

            return PackedSplats(packedArray: packedArray, numSplats: splatCount, splatEncoding: encoding)
        }
    }
}

private struct KSPLATCompression {
    var level: UInt16
    var bytesPerCenter: Int
    var bytesPerScale: Int
    var bytesPerRotation: Int
    var bytesPerColor: Int
    var bytesPerSphericalHarmonicsComponent: Int
    var scaleOffsetBytes: Int
    var rotationOffsetBytes: Int
    var colorOffsetBytes: Int
    var sphericalHarmonicsOffsetBytes: Int
    var defaultScaleRange: Float

    init?(level: UInt16) {
        self.level = level
        switch level {
        case 0:
            bytesPerCenter = 12
            bytesPerScale = 12
            bytesPerRotation = 16
            bytesPerColor = 4
            bytesPerSphericalHarmonicsComponent = 4
            scaleOffsetBytes = 12
            rotationOffsetBytes = 24
            colorOffsetBytes = 40
            sphericalHarmonicsOffsetBytes = 44
            defaultScaleRange = 1.0
        case 1:
            bytesPerCenter = 6
            bytesPerScale = 6
            bytesPerRotation = 8
            bytesPerColor = 4
            bytesPerSphericalHarmonicsComponent = 2
            scaleOffsetBytes = 6
            rotationOffsetBytes = 12
            colorOffsetBytes = 20
            sphericalHarmonicsOffsetBytes = 24
            defaultScaleRange = 32767.0
        case 2:
            bytesPerCenter = 6
            bytesPerScale = 6
            bytesPerRotation = 8
            bytesPerColor = 4
            bytesPerSphericalHarmonicsComponent = 1
            scaleOffsetBytes = 6
            rotationOffsetBytes = 12
            colorOffsetBytes = 20
            sphericalHarmonicsOffsetBytes = 24
            defaultScaleRange = 32767.0
        default:
            return nil
        }
    }

    func bytesPerSplat(shComponents: Int) -> Int {
        bytesPerCenter
            + bytesPerScale
            + bytesPerRotation
            + bytesPerColor
            + shComponents * bytesPerSphericalHarmonicsComponent
    }

    func readScale(_ bytes: UnsafeBufferPointer<UInt8>, splatOffset: Int, componentOffset: Int) -> Float {
        if level == 0 {
            return ksplatReadFloat32(bytes, offset: splatOffset + scaleOffsetBytes + componentOffset * 4)
        }
        return Float(Float16(bitPattern: ksplatReadUInt16(bytes, offset: splatOffset + scaleOffsetBytes + componentOffset * 2)))
    }

    func readRotation(_ bytes: UnsafeBufferPointer<UInt8>, splatOffset: Int, componentOffset: Int) -> Float {
        if level == 0 {
            return ksplatReadFloat32(bytes, offset: splatOffset + rotationOffsetBytes + componentOffset * 4)
        }
        return Float(Float16(bitPattern: ksplatReadUInt16(bytes, offset: splatOffset + rotationOffsetBytes + componentOffset * 2)))
    }
}

private func ksplatSHComponents(degree: UInt16) -> Int? {
    switch degree {
    case 0:
        return 0
    case 1:
        return 9
    case 2:
        return 24
    case 3:
        return 45
    default:
        return nil
    }
}

private func partialBucketLength(
    _ bytes: UnsafeBufferPointer<UInt8>,
    sectionBase: Int,
    partialBucketIndex: Int,
    fullBucketCount: Int,
    partiallyFilledBucketCount: Int
) -> Int {
    let localPartialIndex = partialBucketIndex - fullBucketCount
    guard localPartialIndex >= 0, localPartialIndex < partiallyFilledBucketCount else {
        return 0
    }
    return Int(ksplatReadUInt32(bytes, offset: sectionBase + localPartialIndex * 4))
}

private func ksplatRequireBytes(_ byteCount: Int, cursor: Int, count: Int) throws {
    guard byteCount >= 0, cursor >= 0, cursor + byteCount <= count else {
        throw SplatKSPLATLoaderError.truncatedFile
    }
}

@inline(__always)
private func ksplatReadUInt16(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

@inline(__always)
private func ksplatReadUInt32(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
private func ksplatReadFloat32(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> Float {
    Float(bitPattern: ksplatReadUInt32(bytes, offset: offset))
}
