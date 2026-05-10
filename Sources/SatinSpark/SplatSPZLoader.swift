// SPZ decoding is ported from https://github.com/sparkjsdev/spark — `src/spz.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import simd
import zlib

public enum SplatSPZLoaderError: LocalizedError {
    case invalidFile
    case unsupportedVersion(UInt32)
    case unsupportedSHDegree(UInt8)
    case truncatedFile
    case invalidGzipStream(Int32)
    case decompressionFailed(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidFile:
            return "The file is not a valid SPZ file."
        case let .unsupportedVersion(version):
            return "Unsupported SPZ version: \(version)."
        case let .unsupportedSHDegree(degree):
            return "Unsupported SPZ spherical harmonics degree: \(degree)."
        case .truncatedFile:
            return "The SPZ file ended before all splat data could be read."
        case let .invalidGzipStream(code):
            return "Could not initialize SPZ gzip decompression: zlib code \(code)."
        case let .decompressionFailed(code):
            return "SPZ gzip decompression failed: zlib code \(code)."
        }
    }
}

public enum SplatSPZLoader {
    public static let magic: UInt32 = 0x5053474e

    public static func load(url: URL) throws -> PackedSplats {
        try parse(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func parse(_ data: Data, encoding: SplatEncoding = SplatEncoding()) throws -> PackedSplats {
        let decoded = try decodedSPZData(data)
        return try decoded.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 16, readUInt32LittleEndian(bytes, offset: 0) == magic else {
                throw SplatSPZLoaderError.invalidFile
            }

            let version = readUInt32LittleEndian(bytes, offset: 4)
            guard (1 ... 3).contains(version) else {
                throw SplatSPZLoaderError.unsupportedVersion(version)
            }

            let numSplats = Int(readUInt32LittleEndian(bytes, offset: 8))
            let shDegree = bytes[12]
            guard shDegree <= 3 else {
                throw SplatSPZLoaderError.unsupportedSHDegree(shDegree)
            }
            let fractionalBits = bytes[13]
            let flags = bytes[14]
            let hasLOD = (flags & 0x80) != 0

            var cursor = 16
            var centers = Array(repeating: SIMD3<Float>(repeating: 0.0), count: numSplats)
            var colors = Array(repeating: SIMD3<Float>(repeating: 1.0), count: numSplats)
            var opacities = Array(repeating: Float(1.0), count: numSplats)
            var scales = Array(repeating: SIMD3<Float>(repeating: SparkConstants.scaleZero), count: numSplats)
            var rotations = Array(
                repeating: simd_quatf(angle: 0.0, axis: [1.0, 0.0, 0.0]),
                count: numSplats
            )

            if version == 1 {
                try requireBytes(numSplats * 3 * 2, cursor: cursor, count: bytes.count)
                for index in 0 ..< numSplats {
                    let offset = cursor + index * 6
                    centers[index] = SIMD3<Float>(
                        Float(Float16(bitPattern: readUInt16LittleEndian(bytes, offset: offset))),
                        Float(Float16(bitPattern: readUInt16LittleEndian(bytes, offset: offset + 2))),
                        Float(Float16(bitPattern: readUInt16LittleEndian(bytes, offset: offset + 4)))
                    )
                }
                cursor += numSplats * 3 * 2
            } else {
                try requireBytes(numSplats * 3 * 3, cursor: cursor, count: bytes.count)
                let fixed = Float(1 << Int(fractionalBits))
                for index in 0 ..< numSplats {
                    let offset = cursor + index * 9
                    centers[index] = SIMD3<Float>(
                        Float(readInt24LittleEndian(bytes, offset: offset)) / fixed,
                        Float(readInt24LittleEndian(bytes, offset: offset + 3)) / fixed,
                        Float(readInt24LittleEndian(bytes, offset: offset + 6)) / fixed
                    )
                }
                cursor += numSplats * 3 * 3
            }

            try requireBytes(numSplats, cursor: cursor, count: bytes.count)
            for index in 0 ..< numSplats {
                opacities[index] = Float(bytes[cursor + index]) / 255.0
            }
            cursor += numSplats

            try requireBytes(numSplats * 3, cursor: cursor, count: bytes.count)
            let colorScale = spzSHC0 / 0.15
            for index in 0 ..< numSplats {
                let offset = cursor + index * 3
                colors[index] = SIMD3<Float>(
                    (Float(bytes[offset]) / 255.0 - 0.5) * colorScale + 0.5,
                    (Float(bytes[offset + 1]) / 255.0 - 0.5) * colorScale + 0.5,
                    (Float(bytes[offset + 2]) / 255.0 - 0.5) * colorScale + 0.5
                )
            }
            cursor += numSplats * 3

            try requireBytes(numSplats * 3, cursor: cursor, count: bytes.count)
            for index in 0 ..< numSplats {
                let offset = cursor + index * 3
                scales[index] = SIMD3<Float>(
                    exp(Float(bytes[offset]) / 16.0 - 10.0),
                    exp(Float(bytes[offset + 1]) / 16.0 - 10.0),
                    exp(Float(bytes[offset + 2]) / 16.0 - 10.0)
                )
            }
            cursor += numSplats * 3

            if version == 3 {
                try requireBytes(numSplats * 4, cursor: cursor, count: bytes.count)
                for index in 0 ..< numSplats {
                    rotations[index] = decodeSmallestThreeQuaternion(bytes, offset: cursor + index * 4)
                }
                cursor += numSplats * 4
            } else {
                try requireBytes(numSplats * 3, cursor: cursor, count: bytes.count)
                for index in 0 ..< numSplats {
                    let offset = cursor + index * 3
                    let x = Float(bytes[offset]) / 127.5 - 1.0
                    let y = Float(bytes[offset + 1]) / 127.5 - 1.0
                    let z = Float(bytes[offset + 2]) / 127.5 - 1.0
                    let w = sqrt(max(0.0, 1.0 - x * x - y * y - z * z))
                    rotations[index] = normalizedPackedQuaternion(r: w, i: x, j: y, k: z)
                }
                cursor += numSplats * 3
            }

            var sphericalHarmonics = PackedSphericalHarmonics.storage(numSplats: numSplats, degree: Int(shDegree))
            cursor += try decodeSphericalHarmonics(
                bytes,
                cursor: cursor,
                degree: shDegree,
                encoding: encoding,
                into: &sphericalHarmonics
            )

            if hasLOD {
                try requireBytes(numSplats * 2 + numSplats * 4, cursor: cursor, count: bytes.count)
            }

            var packedArray = Array(repeating: UInt32(0), count: numSplats * 4)
            for index in 0 ..< numSplats {
                writePackedSplatWords(
                    center: centers[index],
                    scale: scales[index],
                    rotation: rotations[index],
                    color: colors[index],
                    opacity: opacities[index],
                    encoding: encoding,
                    into: &packedArray,
                    at: index
                )
            }

            return PackedSplats(
                packedArray: packedArray,
                numSplats: numSplats,
                sphericalHarmonics: sphericalHarmonics,
                splatEncoding: encoding
            )
        }
    }
}

private let spzSHC0: Float = 0.28209479177387814

private func decodedSPZData(_ data: Data) throws -> Data {
    guard data.count >= 4 else {
        throw SplatSPZLoaderError.invalidFile
    }
    if data.starts(with: [0x4e, 0x47, 0x53, 0x50]) {
        return data
    }
    guard data.count >= 3, data[0] == 0x1f, data[1] == 0x8b, data[2] == 0x08 else {
        throw SplatSPZLoaderError.invalidFile
    }
    return try gunzip(data)
}

private func gunzip(_ data: Data) throws -> Data {
    var stream = z_stream()
    var status = inflateInit2_(&stream, 16 + MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size))
    guard status == Z_OK else {
        throw SplatSPZLoaderError.invalidGzipStream(status)
    }
    defer { inflateEnd(&stream) }

    var output = Data()
    let chunkSize = 64 * 1024
    var chunk = Array(repeating: UInt8(0), count: chunkSize)

    try data.withUnsafeBytes { rawBuffer in
        guard let source = rawBuffer.bindMemory(to: UInt8.self).baseAddress else {
            throw SplatSPZLoaderError.invalidFile
        }
        stream.next_in = UnsafeMutablePointer<Bytef>(mutating: source)
        stream.avail_in = uInt(rawBuffer.count)

        repeat {
            chunk.withUnsafeMutableBytes { outputBuffer in
                stream.next_out = outputBuffer.bindMemory(to: Bytef.self).baseAddress
                stream.avail_out = uInt(chunkSize)
                status = inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    output.append(outputBuffer.bindMemory(to: UInt8.self).baseAddress!, count: produced)
                }
            }
            guard status == Z_OK || status == Z_STREAM_END else {
                throw SplatSPZLoaderError.decompressionFailed(status)
            }
        } while status != Z_STREAM_END
    }

    return output
}

private func decodeSphericalHarmonics(
    _ bytes: UnsafeBufferPointer<UInt8>,
    cursor: Int,
    degree: UInt8,
    encoding: SplatEncoding,
    into sphericalHarmonics: inout PackedSphericalHarmonics
) throws -> Int {
    let vectors: Int
    switch degree {
    case 0:
        vectors = 0
    case 1:
        vectors = 3
    case 2:
        vectors = 8
    case 3:
        vectors = 15
    default:
        throw SplatSPZLoaderError.unsupportedSHDegree(degree)
    }
    let numSplats = degree == 0 ? 0 : (sphericalHarmonics.sh1?.count ?? 0) / 2
    let byteCount = numSplats * vectors * 3
    try requireBytes(byteCount, cursor: cursor, count: bytes.count)

    guard degree > 0 else { return 0 }
    var offset = cursor
    var sh1 = Array(repeating: Float(0.0), count: 9)
    var sh2 = Array(repeating: Float(0.0), count: 15)
    var sh3 = Array(repeating: Float(0.0), count: 21)

    for index in 0 ..< numSplats {
        for coefficient in 0 ..< 9 {
            sh1[coefficient] = (Float(bytes[offset + coefficient]) - 128.0) / 128.0
        }
        offset += 9
        sphericalHarmonics.setSH1(sh1, at: index, encoding: encoding)

        if degree >= 2 {
            for coefficient in 0 ..< 15 {
                sh2[coefficient] = (Float(bytes[offset + coefficient]) - 128.0) / 128.0
            }
            offset += 15
            sphericalHarmonics.setSH2(sh2, at: index, encoding: encoding)
        }

        if degree >= 3 {
            for coefficient in 0 ..< 21 {
                sh3[coefficient] = (Float(bytes[offset + coefficient]) - 128.0) / 128.0
            }
            offset += 21
            sphericalHarmonics.setSH3(sh3, at: index, encoding: encoding)
        }
    }

    return byteCount
}

private func decodeSmallestThreeQuaternion(
    _ bytes: UnsafeBufferPointer<UInt8>,
    offset: Int
) -> simd_quatf {
    var quaternion = Array(repeating: Float(0.0), count: 4)
    var packed = readUInt32LittleEndian(bytes, offset: offset)
    let valueMask: UInt32 = (1 << 9) - 1
    let largestIndex = Int(packed >> 30)
    let maxValue = Float(1.0 / sqrt(2.0))
    var sumSquares: Float = 0.0

    for component in stride(from: 3, through: 0, by: -1) where component != largestIndex {
        let value = packed & valueMask
        let sign = (packed >> 9) & 0x1
        packed >>= 10
        let decoded = maxValue * (Float(value) / Float(valueMask)) * (sign == 0 ? 1.0 : -1.0)
        quaternion[component] = decoded
        sumSquares += decoded * decoded
    }

    quaternion[largestIndex] = sqrt(max(0.0, 1.0 - sumSquares))
    return normalizedPackedQuaternion(r: quaternion[3], i: quaternion[0], j: quaternion[1], k: quaternion[2])
}

private func requireBytes(_ byteCount: Int, cursor: Int, count: Int) throws {
    guard byteCount >= 0, cursor >= 0, cursor + byteCount <= count else {
        throw SplatSPZLoaderError.truncatedFile
    }
}

@inline(__always)
private func readUInt16LittleEndian(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt16 {
    UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
}

@inline(__always)
private func readUInt32LittleEndian(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}

@inline(__always)
private func readInt24LittleEndian(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> Int32 {
    var value = Int32(bytes[offset])
        | (Int32(bytes[offset + 1]) << 8)
        | (Int32(bytes[offset + 2]) << 16)
    if (value & 0x00800000) != 0 {
        value |= ~0x00ff_ffff
    }
    return value
}
