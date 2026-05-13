import Metal
import Satin
import simd

open class SplatMesh: Mesh {
    public private(set) var packedSplats: PackedSplats
    public private(set) var packedBuffer: MTLBuffer?
    public private(set) var orderingBuffer: MTLBuffer?
    public private(set) var sh1Buffer: MTLBuffer?
    public private(set) var sh2Buffer: MTLBuffer?
    public private(set) var sh3Buffer: MTLBuffer?
    private var emptySHBuffer: MTLBuffer?
    public private(set) var ordering: [UInt32] = []

    public init(
        context: Context,
        packedSplats: PackedSplats,
        liveShader: Bool = false
    ) {
        self.packedSplats = packedSplats
        let material = SplatMaterial(context: context, live: liveShader)
        material.splatEncoding = packedSplats.splatEncoding
        material.shDegree = UInt32(packedSplats.sphericalHarmonics.degree)
        super.init(
            context: context,
            label: "SplatMesh",
            geometry: SplatGeometry(context: context),
            material: material,
            renderLayer: .opaque
        )
        castShadow = false
        receiveShadow = false
        doubleSided = true
        cullMode = .none
        instanceCount = packedSplats.numSplats
        rebuildBuffers()
    }

    public required init(from decoder: any Decoder) throws {
        fatalError("init(from:) has not been implemented")
    }

    public func replacePackedSplats(_ packedSplats: PackedSplats) {
        self.packedSplats = packedSplats
        instanceCount = packedSplats.numSplats
        if let material = material as? SplatMaterial {
            material.splatEncoding = packedSplats.splatEncoding
            material.shDegree = UInt32(packedSplats.sphericalHarmonics.degree)
        }
        rebuildBuffers()
    }

    public func rebuildBuffers() {
        SplatPerfLog.log("mesh: rebuildBuffers numSplats=\(packedSplats.numSplats)")
        SplatPerfLog.measure("mesh: packedBuffer") {
            packedBuffer = packedSplats.makeBuffer(device: context.device)
        }
        if emptySHBuffer == nil {
            let empty = [UInt32](repeating: 0, count: 4)
            emptySHBuffer = empty.withUnsafeBytes { bytes in
                context.device.makeBuffer(bytes: bytes.baseAddress!, length: bytes.count, options: .storageModeShared)
            }
        }
        SplatPerfLog.measure("mesh: sh1Buffer") {
            sh1Buffer = packedSplats.makeSH1Buffer(device: context.device)
        }
        SplatPerfLog.measure("mesh: sh2Buffer") {
            sh2Buffer = packedSplats.makeSH2Buffer(device: context.device)
        }
        SplatPerfLog.measure("mesh: sh3Buffer") {
            sh3Buffer = packedSplats.makeSH3Buffer(device: context.device)
        }
        SplatPerfLog.measure("mesh: identity ordering build") {
            ordering = (0 ..< packedSplats.numSplats).map(UInt32.init)
        }
        SplatPerfLog.measure("mesh: orderingBuffer") {
            orderingBuffer = packedSplats.makeOrderingBuffer(device: context.device, ordering: ordering)
        }
        SplatPerfLog.measure("mesh: bindSplatBuffers") {
            bindSplatBuffers()
        }
    }

    public func updateOrdering(modelViewMatrix: simd_float4x4, metric: SplatSortMetric = .radial) {
        applyOrdering(packedSplats.sortedOrdering(modelViewMatrix: modelViewMatrix, metric: metric))
    }

    public func makeOrderingSnapshot(modelViewMatrix: simd_float4x4, metric: SplatSortMetric = .radial) -> [UInt32] {
        PackedSplats.sortedOrdering(
            packedArray: packedSplats.packedArray,
            numSplats: packedSplats.numSplats,
            modelViewMatrix: modelViewMatrix,
            metric: metric
        )
    }

    public func applyOrdering(_ ordering: [UInt32]) {
        guard ordering.count == packedSplats.numSplats else { return }
        self.ordering = ordering
        let byteCount = ordering.count * MemoryLayout<UInt32>.stride
        if let orderingBuffer, orderingBuffer.length >= byteCount {
            ordering.withUnsafeBytes { bytes in
                orderingBuffer.contents().copyMemory(from: bytes.baseAddress!, byteCount: byteCount)
            }
        } else {
            orderingBuffer = packedSplats.makeOrderingBuffer(device: context.device, ordering: ordering)
            bindSplatBuffers()
        }
    }

    public func applyVisibleOrdering(_ visibleOrdering: [UInt32]) {
        var padded = Array(repeating: UInt32.max, count: packedSplats.numSplats)
        for (index, splatIndex) in visibleOrdering.prefix(packedSplats.numSplats).enumerated() {
            padded[index] = splatIndex
        }
        applyOrdering(padded)
    }

    open override func setupMaterial() {
        super.setupMaterial()
        bindSplatBuffers()
    }

    private func bindSplatBuffers() {
        guard let material = material as? SplatMaterial else { return }
        material.setPackedBuffer(packedBuffer)
        material.setOrderingBuffer(orderingBuffer)
        material.setSHBuffers(
            sh1: sh1Buffer ?? emptySHBuffer,
            sh2: sh2Buffer ?? emptySHBuffer,
            sh3: sh3Buffer ?? emptySHBuffer
        )
        material.setNumSplats(packedSplats.numSplats)
        material.shDegree = UInt32(packedSplats.sphericalHarmonics.degree)
    }
}
