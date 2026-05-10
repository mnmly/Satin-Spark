import Foundation
import Metal
import simd

/// GPU bitonic sort over splat indices, keyed by view-Z or radial distance.
/// Encodes onto a caller-provided command buffer; writes ordering directly to
/// `SplatMesh.orderingBuffer`. Reuses scratch buffers across calls.
public final class SplatGPUSorter {
    private struct Params {
        var modelViewMatrix: simd_float4x4
        var count: UInt32
        var actualCount: UInt32
        var metricMode: UInt32
        var k: UInt32
        var j: UInt32
    }

    private let device: MTLDevice
    private let computeKeys: MTLComputePipelineState
    private let bitonicStep: MTLComputePipelineState

    private var keysBuffer: MTLBuffer?
    private var indicesBuffer: MTLBuffer?
    private var paddedCapacity: Int = 0

    public init(device: MTLDevice) throws {
        self.device = device
        let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Pipelines/SplatSort")!
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let computeKeysFn = library.makeFunction(name: "splatSortComputeKeys"),
              let bitonicStepFn = library.makeFunction(name: "splatSortBitonicStep") else {
            throw NSError(domain: "SplatGPUSorter", code: -1, userInfo: [NSLocalizedDescriptionKey: "Failed to find sort kernels"])
        }
        self.computeKeys = try device.makeComputePipelineState(function: computeKeysFn)
        self.bitonicStep = try device.makeComputePipelineState(function: bitonicStepFn)
    }

    /// Encode the sort onto `commandBuffer`. After the buffer commits, `orderingBuffer`
    /// contains real splat indices in back-to-front order, with padding indices
    /// (0xffffffff) tailed beyond `numSplats`.
    public func encode(
        commandBuffer: MTLCommandBuffer,
        packedBuffer: MTLBuffer,
        packedOffset: Int = 0,
        orderingBuffer: MTLBuffer,
        numSplats: Int,
        modelViewMatrix: simd_float4x4,
        metric: SplatSortMetric = .viewZ
    ) {
        guard numSplats > 0 else { return }
        let padded = nextPowerOfTwo(numSplats)
        ensureScratch(capacity: padded)

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "SplatGPUSorter"

        var params = Params(
            modelViewMatrix: modelViewMatrix,
            count: UInt32(padded),
            actualCount: UInt32(numSplats),
            metricMode: metric == .viewZ ? 0 : 1,
            k: 0,
            j: 0
        )

        // 1. Compute keys + initial indices.
        encoder.setComputePipelineState(computeKeys)
        encoder.setBuffer(packedBuffer, offset: packedOffset, index: 0)
        encoder.setBuffer(keysBuffer, offset: 0, index: 1)
        encoder.setBuffer(indicesBuffer, offset: 0, index: 2)
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 3)
        dispatch(encoder: encoder, pipeline: computeKeys, count: padded)

        // 2. Bitonic merge: O(log² N) passes.
        encoder.setComputePipelineState(bitonicStep)
        encoder.setBuffer(keysBuffer, offset: 0, index: 0)
        encoder.setBuffer(indicesBuffer, offset: 0, index: 1)

        var k: UInt32 = 2
        while k <= UInt32(padded) {
            var j = k / 2
            while j > 0 {
                params.k = k
                params.j = j
                encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 2)
                dispatch(encoder: encoder, pipeline: bitonicStep, count: padded)
                j /= 2
            }
            k *= 2
        }
        encoder.endEncoding()

        // 3. Blit sorted indices into the ordering buffer.
        // Both are uint32; the first `padded` entries are the sorted ordering, with
        // padding indices (0xffffffff) at the tail. Vertex shader culls those.
        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "SplatGPUSorter.copyOrdering"
        let copyBytes = min(orderingBuffer.length, padded * MemoryLayout<UInt32>.stride)
        blit.copy(from: indicesBuffer!, sourceOffset: 0, to: orderingBuffer, destinationOffset: 0, size: copyBytes)
        blit.endEncoding()
    }

    private func ensureScratch(capacity: Int) {
        guard capacity > paddedCapacity else { return }
        let bytes = capacity * MemoryLayout<UInt32>.stride
        keysBuffer = device.makeBuffer(length: capacity * MemoryLayout<Float>.stride, options: .storageModePrivate)
        indicesBuffer = device.makeBuffer(length: bytes, options: .storageModePrivate)
        paddedCapacity = capacity
    }

    private func dispatch(encoder: MTLComputeCommandEncoder, pipeline: MTLComputePipelineState, count: Int) {
        let threadsPerGroup = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        let groups = MTLSize(width: (count + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
    }
}

private func nextPowerOfTwo(_ n: Int) -> Int {
    guard n > 1 else { return 1 }
    var v = n - 1
    v |= v >> 1
    v |= v >> 2
    v |= v >> 4
    v |= v >> 8
    v |= v >> 16
    v |= v >> 32
    return v + 1
}
