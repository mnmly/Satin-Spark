import Foundation

public enum SplatRADRemoteError: LocalizedError {
    case invalidHTTPStatus(Int)
    case invalidChunkURL

    public var errorDescription: String? {
        switch self {
        case let .invalidHTTPStatus(status):
            return "RAD fetch failed with HTTP status \(status)."
        case .invalidChunkURL:
            return "Could not resolve RAD sidecar chunk URL."
        }
    }
}

public actor SplatRADRemotePagedFile {
    public let url: URL
    public let requestHeaders: [String: String]
    private var cachedHeader: SplatRADHeader?

    public init(url: URL, requestHeaders: [String: String] = [:]) {
        self.url = url
        self.requestHeaders = requestHeaders
    }

    public func loadHeader() async throws -> SplatRADHeader {
        if let cachedHeader {
            return cachedHeader
        }

        if url.isFileURL {
            let header = try SplatRADLoader.loadHeader(url: url)
            cachedHeader = header
            return header
        }

        for byteCount in [65_536, 256 * 1_024, 1_024 * 1_024] {
            let data = try await fetch(url: url, offset: 0, bytes: byteCount)
            if let header = try? SplatRADLoader.parseHeader(data) {
                cachedHeader = header
                return header
            }
        }

        return try SplatRADLoader.parseHeader(try await fetch(url: url, offset: nil, bytes: nil))
    }

    public func loadChunk(_ chunkIndex: Int) async throws -> SplatRADPage {
        let header = try await loadHeader()
        guard chunkIndex >= 0, chunkIndex < header.metadata.chunks.count else {
            throw SplatRADLoaderError.invalidMetadata
        }

        let range = header.metadata.chunks[chunkIndex]
        let chunkData: Data
        let chunkStart: Int
        if let filename = range.filename {
            let chunkURL: URL
            if url.isFileURL {
                chunkURL = url.deletingLastPathComponent().appendingPathComponent(filename)
            } else if let resolved = URL(string: filename, relativeTo: url)?.absoluteURL {
                chunkURL = resolved
            } else {
                throw SplatRADRemoteError.invalidChunkURL
            }
            chunkData = try await fetch(url: chunkURL, offset: nil, bytes: nil)
            chunkStart = range.offset
        } else {
            let absoluteOffset = header.chunksStart + range.offset
            chunkData = try await fetch(url: url, offset: absoluteOffset, bytes: range.bytes)
            chunkStart = 0
        }

        return try SplatRADLoader.decodePage(
            chunkIndex: chunkIndex,
            header: header,
            range: range,
            chunkData: chunkData,
            chunkStart: chunkStart
        )
    }

    public func loadRootChunk() async throws -> SplatRADPage {
        let header = try await loadHeader()
        return try await loadChunk(max(0, header.metadata.chunks.count - 1))
    }

    private func fetch(url: URL, offset: Int?, bytes: Int?) async throws -> Data {
        if url.isFileURL {
            let data = try Data(contentsOf: url, options: [.mappedIfSafe])
            guard let offset, let bytes else { return data }
            let end = min(data.count, offset + bytes)
            guard offset >= 0, offset <= end else { throw SplatRADLoaderError.invalidMetadata }
            return data.subdata(in: offset ..< end)
        }

        var request = URLRequest(url: url)
        for (key, value) in requestHeaders {
            request.setValue(value, forHTTPHeaderField: key)
        }
        if let offset, let bytes {
            request.setValue("bytes=\(offset)-\(offset + bytes - 1)", forHTTPHeaderField: "Range")
        }

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse,
           !(200 ... 299).contains(http.statusCode) {
            throw SplatRADRemoteError.invalidHTTPStatus(http.statusCode)
        }
        return data
    }
}

public actor SplatRADAsyncPageCache {
    public let pagedFile: SplatRADRemotePagedFile
    public let maxPages: Int

    private var pages: [Int: SplatRADPage] = [:]
    private var lru: [Int: UInt64] = [:]
    private var tick: UInt64 = 0

    public init(pagedFile: SplatRADRemotePagedFile, maxPages: Int) {
        precondition(maxPages > 0, "SplatRADAsyncPageCache requires at least one page")
        self.pagedFile = pagedFile
        self.maxPages = maxPages
    }

    public var residentChunkIndices: [Int] {
        pages.keys.sorted()
    }

    public func pageIfResident(_ chunkIndex: Int) -> SplatRADPage? {
        guard let page = pages[chunkIndex] else { return nil }
        markUsed(chunkIndex)
        return page
    }

    @discardableResult
    public func loadChunk(_ chunkIndex: Int) async throws -> SplatRADPage {
        if let page = pageIfResident(chunkIndex) {
            return page
        }

        evictIfNeeded()
        let page = try await pagedFile.loadChunk(chunkIndex)
        pages[chunkIndex] = page
        markUsed(chunkIndex)
        return page
    }

    @discardableResult
    public func prepareChunks(_ chunkIndices: [Int]) async throws -> [SplatRADPage] {
        var loaded: [SplatRADPage] = []
        loaded.reserveCapacity(min(chunkIndices.count, maxPages))
        for chunkIndex in chunkIndices.prefix(maxPages) {
            let page = try await loadChunk(chunkIndex)
            loaded.append(page)
        }
        return loaded
    }

    public func unloadChunk(_ chunkIndex: Int) {
        pages[chunkIndex] = nil
        lru[chunkIndex] = nil
    }

    public func unloadAll() {
        pages.removeAll()
        lru.removeAll()
    }

    private func markUsed(_ chunkIndex: Int) {
        tick &+= 1
        lru[chunkIndex] = tick
    }

    private func evictIfNeeded() {
        while pages.count >= maxPages {
            guard let evict = lru.min(by: { $0.value < $1.value })?.key else { return }
            unloadChunk(evict)
        }
    }
}
