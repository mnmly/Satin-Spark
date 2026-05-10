// Spark .splat binary decoding is ported from https://github.com/sparkjsdev/spark
// — `src/antisplat.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation
import simd

public enum SplatRawSplatLoaderError: LocalizedError {
    case invalidByteCount(Int)

    public var errorDescription: String? {
        switch self {
        case let .invalidByteCount(byteCount):
            return "Invalid .splat byte count \(byteCount); expected a multiple of 32 bytes."
        }
    }
}

public enum SplatRawSplatLoader {
    public static let bytesPerSplat = 32

    public static func load(url: URL) throws -> PackedSplats {
        try parse(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func parse(_ data: Data, encoding: SplatEncoding = SplatEncoding()) throws -> PackedSplats {
        guard data.count.isMultiple(of: bytesPerSplat) else {
            throw SplatRawSplatLoaderError.invalidByteCount(data.count)
        }

        let numSplats = data.count / bytesPerSplat
        var packedArray = Array(repeating: UInt32(0), count: numSplats * 4)

        data.withUnsafeBytes { rawBuffer in
            guard let base = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            for index in 0 ..< numSplats {
                let offset = index * bytesPerSplat
                let center = SIMD3<Float>(
                    readFloat32LittleEndian(base + offset + 0),
                    readFloat32LittleEndian(base + offset + 4),
                    readFloat32LittleEndian(base + offset + 8)
                )
                let scale = SIMD3<Float>(
                    readFloat32LittleEndian(base + offset + 12),
                    readFloat32LittleEndian(base + offset + 16),
                    readFloat32LittleEndian(base + offset + 20)
                )
                let color = SIMD3<Float>(
                    Float(base[offset + 24]) / 255.0,
                    Float(base[offset + 25]) / 255.0,
                    Float(base[offset + 26]) / 255.0
                )
                let opacity = Float(base[offset + 27]) / 255.0
                let rotation = normalizedPackedQuaternion(
                    r: (Float(base[offset + 28]) - 128.0) / 128.0,
                    i: (Float(base[offset + 29]) - 128.0) / 128.0,
                    j: (Float(base[offset + 30]) - 128.0) / 128.0,
                    k: (Float(base[offset + 31]) - 128.0) / 128.0
                )

                writePackedSplatWords(
                    center: center,
                    scale: scale,
                    rotation: rotation,
                    color: color,
                    opacity: opacity,
                    encoding: encoding,
                    into: &packedArray,
                    at: index
                )
            }
        }

        return PackedSplats(packedArray: packedArray, numSplats: numSplats, splatEncoding: encoding)
    }
}

@inline(__always)
private func readFloat32LittleEndian(_ base: UnsafePointer<UInt8>) -> Float {
    let bitPattern = UInt32(base[0])
        | (UInt32(base[1]) << 8)
        | (UInt32(base[2]) << 16)
        | (UInt32(base[3]) << 24)
    return Float(bitPattern: bitPattern)
}
