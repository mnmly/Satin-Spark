// RAD header decoding is ported from https://github.com/sparkjsdev/spark —
// `rust/spark-lib/src/rad.rs` and `src/SplatPager.ts`.
// Spark is MIT-licensed; see THIRD_PARTY_NOTICES.md for the full attribution.
// Copyright © 2025 World Labs Technologies, Inc. (upstream)
// Copyright © 2026 Hiroaki Yamane (this port)

import Foundation

public enum SplatRADLoaderError: LocalizedError {
    case incompleteHeader
    case invalidMagic(UInt32)
    case invalidMetadata
    case unsupportedVersion(Int)
    case unsupportedType(String)

    public var errorDescription: String? {
        switch self {
        case .incompleteHeader:
            return "The RAD header is incomplete."
        case let .invalidMagic(magic):
            return "Invalid RAD magic: 0x\(String(magic, radix: 16))."
        case .invalidMetadata:
            return "The RAD metadata is invalid."
        case let .unsupportedVersion(version):
            return "Unsupported RAD metadata version: \(version)."
        case let .unsupportedType(type):
            return "Unsupported RAD type: \(type)."
        }
    }
}

public struct SplatRADHeader: Sendable, Equatable {
    public var metadata: SplatRADMetadata
    public var chunksStart: Int
}

public struct SplatRADMetadata: Sendable, Equatable {
    public var version: Int
    public var type: String
    public var count: Int
    public var maxSH: Int?
    public var lodTree: Bool
    public var chunkSize: Int
    public var allChunkBytes: Int?
    public var chunks: [SplatRADChunkRange]
    public var splatEncoding: SplatEncoding?
}

public struct SplatRADChunkRange: Sendable, Equatable {
    public var offset: Int
    public var bytes: Int
    public var base: Int?
    public var count: Int?
    public var filename: String?
}

public enum SplatRADLoader {
    public static func loadHeader(url: URL) throws -> SplatRADHeader {
        try parseHeader(Data(contentsOf: url, options: [.mappedIfSafe]))
    }

    public static func parseHeader(_ data: Data) throws -> SplatRADHeader {
        try data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            guard bytes.count >= 8 else { throw SplatRADLoaderError.incompleteHeader }
            let magic = readLittleUInt32(bytes, offset: 0)
            guard magic == 0x3044_4152 else { throw SplatRADLoaderError.invalidMagic(magic) }

            let metadataByteCount = Int(readLittleUInt32(bytes, offset: 4))
            guard bytes.count >= 8 + metadataByteCount else {
                throw SplatRADLoaderError.incompleteHeader
            }

            let metadataData = Data(bytes: bytes.baseAddress! + 8, count: metadataByteCount)
            let decoded = try JSONDecoder().decode(RADMetadataJSON.self, from: metadataData)
            guard decoded.version == 1 else { throw SplatRADLoaderError.unsupportedVersion(decoded.version) }
            guard decoded.type == "gsplat" else { throw SplatRADLoaderError.unsupportedType(decoded.type) }
            guard decoded.count >= 0, !decoded.chunks.isEmpty else {
                throw SplatRADLoaderError.invalidMetadata
            }

            let chunkSize = decoded.chunkSize ?? decoded.count
            guard chunkSize > 0 else { throw SplatRADLoaderError.invalidMetadata }
            let expectedChunkCount = (decoded.count + chunkSize - 1) / chunkSize
            guard decoded.chunks.count == expectedChunkCount else {
                throw SplatRADLoaderError.invalidMetadata
            }

            let metadata = SplatRADMetadata(
                version: decoded.version,
                type: decoded.type,
                count: decoded.count,
                maxSH: decoded.maxSH,
                lodTree: decoded.lodTree ?? false,
                chunkSize: chunkSize,
                allChunkBytes: decoded.allChunkBytes,
                chunks: decoded.chunks.map {
                    SplatRADChunkRange(
                        offset: $0.offset,
                        bytes: $0.bytes,
                        base: $0.base,
                        count: $0.count,
                        filename: $0.filename
                    )
                },
                splatEncoding: decoded.splatEncoding?.splatEncoding
            )

            return SplatRADHeader(metadata: metadata, chunksStart: 8 + roundUpToEight(metadataByteCount))
        }
    }
}

private struct RADMetadataJSON: Decodable {
    var version: Int
    var type: String
    var count: Int
    var maxSH: Int?
    var lodTree: Bool?
    var chunkSize: Int?
    var allChunkBytes: Int?
    var chunks: [RADChunkRangeJSON]
    var splatEncoding: RADSplatEncodingJSON?

    private enum CodingKeys: String, CodingKey {
        case version
        case type
        case count
        case maxSH = "maxSh"
        case lodTree
        case chunkSize
        case allChunkBytes
        case chunks
        case splatEncoding
    }
}

private struct RADChunkRangeJSON: Decodable {
    var offset: Int
    var bytes: Int
    var base: Int?
    var count: Int?
    var filename: String?
}

private struct RADSplatEncodingJSON: Decodable {
    var rgbMin: Float?
    var rgbMax: Float?
    var lnScaleMin: Float?
    var lnScaleMax: Float?
    var sh1Max: Float?
    var sh2Max: Float?
    var sh3Max: Float?
    var lodOpacity: Bool?

    var splatEncoding: SplatEncoding {
        SplatEncoding(
            rgbMin: rgbMin ?? 0.0,
            rgbMax: rgbMax ?? 1.0,
            lnScaleMin: lnScaleMin ?? SparkConstants.lnScaleMin,
            lnScaleMax: lnScaleMax ?? SparkConstants.lnScaleMax,
            sh1Max: sh1Max ?? 1.0,
            sh2Max: sh2Max ?? 1.0,
            sh3Max: sh3Max ?? 1.0,
            lodOpacity: lodOpacity ?? false
        )
    }
}

@inline(__always)
private func roundUpToEight(_ size: Int) -> Int {
    (size + 7) & ~7
}

@inline(__always)
private func readLittleUInt32(_ bytes: UnsafeBufferPointer<UInt8>, offset: Int) -> UInt32 {
    UInt32(bytes[offset])
        | (UInt32(bytes[offset + 1]) << 8)
        | (UInt32(bytes[offset + 2]) << 16)
        | (UInt32(bytes[offset + 3]) << 24)
}
