import Foundation

public enum SplatLoaderError: LocalizedError {
    case unknownFileType
    case unsupportedFormat(SplatFileType, reason: String)

    public var errorDescription: String? {
        switch self {
        case .unknownFileType:
            return "Could not determine the splat file type."
        case let .unsupportedFormat(fileType, reason):
            return "Unsupported \(fileType.rawValue) splat format: \(reason)."
        }
    }
}

public enum SplatLoader {
    public static func load(url: URL, fileType: SplatFileType? = nil) throws -> PackedSplats {
        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        if (fileType ?? Self.fileType(for: data, path: url.path)) == .rad {
            return try SplatRADLoader.load(url: url)
        }
        return try parse(data, fileType: fileType, path: url.path)
    }

    public static func parse(
        _ data: Data,
        fileType explicitFileType: SplatFileType? = nil,
        path: String? = nil
    ) throws -> PackedSplats {
        guard let fileType = explicitFileType ?? fileType(for: data, path: path) else {
            throw SplatLoaderError.unknownFileType
        }

        switch fileType {
        case .ply:
            return try SplatPLYLoader.parse(data)
        case .splat:
            return try SplatRawSplatLoader.parse(data)
        case .spz:
            return try SplatSPZLoader.parse(data)
        case .ksplat:
            return try SplatKSPLATLoader.parse(data)
        case .pcsogs:
            guard let path else {
                throw SplatLoaderError.unsupportedFormat(.pcsogs, reason: "PCSOGS sidecar image paths require a metadata file path.")
            }
            let metadataURL = URL(fileURLWithPath: path)
            return try SplatPCSOGSLoader.parse(data, baseURL: metadataURL.deletingLastPathComponent())
        case .pcsogszip:
            return try SplatPCSOGSZipLoader.parse(data)
        case .rad:
            return try SplatRADLoader.parse(data)
        }
    }

    public static func fileType(for data: Data, path: String? = nil) -> SplatFileType? {
        data.withUnsafeBytes { rawBuffer in
            let bytes = rawBuffer.bindMemory(to: UInt8.self)
            if bytes.count >= 3,
               bytes[0] == 0x70,
               bytes[1] == 0x6c,
               bytes[2] == 0x79 {
                return .ply
            }
            if bytes.count >= 4,
               bytes[0] == 0x4e,
               bytes[1] == 0x47,
               bytes[2] == 0x53,
               bytes[3] == 0x50 {
                return .spz
            }
            if bytes.count >= 3,
               bytes[0] == 0x1f,
               bytes[1] == 0x8b,
               bytes[2] == 0x08 {
                return .spz
            }
            if bytes.count >= 4,
               bytes[0] == 0x50,
               bytes[1] == 0x4b,
               bytes[2] == 0x03,
               bytes[3] == 0x04 {
                return .pcsogszip
            }
            if bytes.count >= 4,
               bytes[0] == 0x52,
               bytes[1] == 0x41,
               bytes[2] == 0x44,
               bytes[3] == 0x30 {
                return .rad
            }
            return nil
        } ?? fileType(forPath: path)
    }

    public static func fileType(forPath path: String?) -> SplatFileType? {
        guard let path else { return nil }
        let trimmed = path
            .split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)[0]
            .split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0]
        guard let extensionStart = trimmed.lastIndex(of: ".") else { return nil }
        let pathExtension = trimmed[trimmed.index(after: extensionStart)...].lowercased()

        switch pathExtension {
        case "ply":
            return .ply
        case "spz":
            return .spz
        case "splat":
            return .splat
        case "ksplat":
            return .ksplat
        case "sog", "pcsogszip":
            return .pcsogszip
        case "json", "pcsogs":
            return .pcsogs
        case "zip":
            return .pcsogszip
        case "rad":
            return .rad
        default:
            return nil
        }
    }
}
