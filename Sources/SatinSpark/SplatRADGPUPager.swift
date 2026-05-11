import Foundation
import Metal
import simd

public enum SplatRADGPUPagerError: LocalizedError {
    case missingLODMetadata
    case missingShader
    case bufferAllocationFailed

    public var errorDescription: String? {
        switch self {
        case .missingLODMetadata:
            return "The RAD page does not contain LOD child metadata."
        case .missingShader:
            return "Failed to find the RAD GPU paging kernel."
        case .bufferAllocationFailed:
            return "Failed to allocate RAD GPU paging buffers."
        }
    }
}

public struct SplatRADGPUTraversalBuffers {
    public let childCountBuffer: MTLBuffer
    public let childStartBuffer: MTLBuffer
    public let parentBuffer: MTLBuffer
    public let visibleCountBuffer: MTLBuffer
}

/// GPU LOD selector for a loaded RAD page.
///
/// The selector writes visible local splat indices into the supplied ordering
/// buffer and pads the rest with `UInt32.max`. Call `SplatGPUSorter
/// .encodeExistingOrdering(...)` after this encoder if the selected subset
/// should be rendered back-to-front without a CPU readback.
public final class SplatRADGPUPager {
    private struct Uniforms {
        var modelViewMatrix: simd_float4x4
        var projectionMatrix: simd_float4x4
        var encoding: SIMD4<Float>
        var renderSize: SIMD2<Float>
        var maxStdDev: Float
        var minPixelRadius: Float
        var maxPixelRadius: Float
        var minAlpha: Float
        var preBlurAmount: Float
        var blurAmount: Float
        var focalAdjustment: Float
        var splitPixelRadius: Float
        var count: UInt32
        var lodOpacity: UInt32
        var rootIndex: UInt32
    }

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState

    public init(device: MTLDevice) throws {
        self.device = device
        let url = Bundle.module.url(forResource: "Shaders", withExtension: "metal", subdirectory: "Pipelines/SplatRADPaging")!
        let source = try String(contentsOf: url, encoding: .utf8)
        let library = try device.makeLibrary(source: source, options: nil)
        guard let function = library.makeFunction(name: "splatRADSelectLOD") else {
            throw SplatRADGPUPagerError.missingShader
        }
        self.pipeline = try device.makeComputePipelineState(function: function)
    }

    public func makeTraversalBuffers(for page: SplatRADPage) throws -> SplatRADGPUTraversalBuffers {
        guard let childCounts = page.childCounts,
              let childStarts = page.localChildStarts(),
              let parents = page.parentIndices() else {
            throw SplatRADGPUPagerError.missingLODMetadata
        }
        guard childCounts.count == page.count,
              childStarts.count == page.count,
              parents.count == page.count else {
            throw SplatRADGPUPagerError.missingLODMetadata
        }

        guard let childCountBuffer = childCounts.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }),
        let childStartBuffer = childStarts.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }),
        let parentBuffer = parents.withUnsafeBytes({ bytes in
            device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
        }),
        let visibleCountBuffer = device.makeBuffer(length: MemoryLayout<UInt32>.stride, options: .storageModeShared) else {
            throw SplatRADGPUPagerError.bufferAllocationFailed
        }

        return SplatRADGPUTraversalBuffers(
            childCountBuffer: childCountBuffer,
            childStartBuffer: childStartBuffer,
            parentBuffer: parentBuffer,
            visibleCountBuffer: visibleCountBuffer
        )
    }

    public func encodeSelection(
        commandBuffer: MTLCommandBuffer,
        page: SplatRADPage,
        traversalBuffers: SplatRADGPUTraversalBuffers,
        packedBuffer: MTLBuffer,
        packedOffset: Int = 0,
        orderingBuffer: MTLBuffer,
        modelViewMatrix: simd_float4x4,
        projectionMatrix: simd_float4x4,
        renderSize: SIMD2<Float>,
        splitPixelRadius: Float = 2.0,
        projectionSettings: SplatProjectionSettings = SplatProjectionSettings()
    ) {
        guard page.count > 0 else { return }

        let encoding = page.splats.splatEncoding
        var uniforms = Uniforms(
            modelViewMatrix: modelViewMatrix,
            projectionMatrix: projectionMatrix,
            encoding: SIMD4<Float>(
                encoding.rgbMin,
                encoding.rgbMax,
                encoding.lnScaleMin,
                encoding.lnScaleMax
            ),
            renderSize: renderSize,
            maxStdDev: projectionSettings.maxStdDev,
            minPixelRadius: projectionSettings.minPixelRadius,
            maxPixelRadius: projectionSettings.maxPixelRadius,
            minAlpha: projectionSettings.minAlpha,
            preBlurAmount: projectionSettings.preBlurAmount,
            blurAmount: projectionSettings.blurAmount,
            focalAdjustment: projectionSettings.focalAdjustment,
            splitPixelRadius: splitPixelRadius,
            count: UInt32(page.count),
            lodOpacity: encoding.lodOpacity ? 1 : 0,
            rootIndex: UInt32(page.lodRootIndex())
        )

        guard let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        blit.label = "SplatRADGPUPager.reset"
        blit.fill(
            buffer: orderingBuffer,
            range: 0 ..< min(orderingBuffer.length, page.count * MemoryLayout<UInt32>.stride),
            value: 0xff
        )
        blit.fill(buffer: traversalBuffers.visibleCountBuffer, range: 0 ..< MemoryLayout<UInt32>.stride, value: 0)
        blit.endEncoding()

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        encoder.label = "SplatRADGPUPager.selectLOD"
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(packedBuffer, offset: packedOffset, index: 0)
        encoder.setBuffer(traversalBuffers.childCountBuffer, offset: 0, index: 1)
        encoder.setBuffer(traversalBuffers.childStartBuffer, offset: 0, index: 2)
        encoder.setBuffer(traversalBuffers.parentBuffer, offset: 0, index: 3)
        encoder.setBuffer(traversalBuffers.visibleCountBuffer, offset: 0, index: 4)
        encoder.setBuffer(orderingBuffer, offset: 0, index: 5)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 6)

        let threadsPerGroup = MTLSize(width: min(pipeline.maxTotalThreadsPerThreadgroup, 256), height: 1, depth: 1)
        let groups = MTLSize(width: (page.count + threadsPerGroup.width - 1) / threadsPerGroup.width, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadsPerGroup)
        encoder.endEncoding()
    }
}
