import Metal
import Satin
import simd

open class SplatMesh: Mesh {
    public private(set) var packedSplats: PackedSplats
    public private(set) var packedBuffer: MTLBuffer?
    public private(set) var orderingBuffer: MTLBuffer?
    public private(set) var ordering: [UInt32] = []

    public init(
        context: Context,
        packedSplats: PackedSplats,
        liveShader: Bool = false
    ) {
        self.packedSplats = packedSplats
        let material = SplatMaterial(context: context, live: liveShader)
        material.splatEncoding = packedSplats.splatEncoding
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
        }
        rebuildBuffers()
    }

    public func rebuildBuffers() {
        packedBuffer = packedSplats.makeBuffer(device: context.device)
        ordering = (0 ..< packedSplats.numSplats).map(UInt32.init)
        orderingBuffer = packedSplats.makeOrderingBuffer(device: context.device, ordering: ordering)
        bindSplatBuffers()
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

    open override func setupMaterial() {
        super.setupMaterial()
        bindSplatBuffers()
    }

    private func bindSplatBuffers() {
        guard let material = material as? SplatMaterial else { return }
        material.setPackedBuffer(packedBuffer)
        material.setOrderingBuffer(orderingBuffer)
        material.setNumSplats(packedSplats.numSplats)
    }
}
