import Foundation

public final class SplatRADPageCache {
    public let pagedFile: SplatRADPagedFile
    public let maxPages: Int

    private var pages: [Int: SplatRADPage] = [:]
    private var lru: [Int: UInt64] = [:]
    private var tick: UInt64 = 0

    public init(pagedFile: SplatRADPagedFile, maxPages: Int) {
        precondition(maxPages > 0, "SplatRADPageCache requires at least one page")
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
    public func loadChunk(_ chunkIndex: Int) throws -> SplatRADPage {
        if let page = pageIfResident(chunkIndex) {
            return page
        }

        evictIfNeeded()
        let page = try pagedFile.loadChunk(chunkIndex)
        pages[chunkIndex] = page
        markUsed(chunkIndex)
        return page
    }

    @discardableResult
    public func prepareChunks(_ chunkIndices: [Int]) throws -> [SplatRADPage] {
        var loaded: [SplatRADPage] = []
        loaded.reserveCapacity(min(chunkIndices.count, maxPages))
        for chunkIndex in chunkIndices {
            loaded.append(try loadChunk(chunkIndex))
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
