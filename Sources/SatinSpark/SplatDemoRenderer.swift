import Metal
import Satin
import simd

open class SplatDemoRenderer: MetalViewRenderer, @unchecked Sendable {
    public lazy var renderer = Renderer(context: defaultContext)
    public lazy var splatMesh = SplatMesh(
        context: defaultContext,
        packedSplats: SplatFixtures.deterministicScene()
    )
    public lazy var scene = Object(context: defaultContext, label: "SatinSpark Demo", [splatMesh])
    public lazy var camera = PerspectiveCamera(
        context: defaultContext,
        position: [0.0, 0.0, 3.2],
        near: 0.01,
        far: 100.0,
        fov: 45.0
    )
    public private(set) var cameraController: PerspectiveCameraController?
    public var sortMetric: SplatSortMetric = .viewZ
    public var sortDistance: Float = 0.01
    public var sortCoorient: Float = 0.999

    private lazy var gpuSorter: SplatGPUSorter? = {
        SplatPerfLog.log("renderer: lazy gpuSorter creation (first draw)")
        return try? SplatPerfLog.measure("renderer: SplatGPUSorter total init") {
            try SplatGPUSorter(device: defaultContext.device)
        }
    }()

    private var lastSortPosition: SIMD3<Float>?
    private var lastSortDirection: SIMD3<Float>?
    private var needsOrderingUpdate = true
    private var didLogFirstDraw = false
    private var didLogFirstSort = false

    open override func setup() {
        renderer.setClearColor([0.03, 0.035, 0.045, 1.0])
        camera.lookAt(target: .zero)
        installCameraController()
    }

    open override func update() {
        cameraController?.update()
    }

    open override func cleanup() {
        cameraController?.disable()
        cameraController = nil
        super.cleanup()
    }

    public func replacePackedSplats(_ packedSplats: PackedSplats) {
        SplatPerfLog.log("renderer: replacePackedSplats numSplats=\(packedSplats.numSplats) bounds=\(packedSplats.precomputedBounds != nil ? "precomputed" : "missing")")
        SplatPerfLog.measure("renderer: splatMesh.replacePackedSplats") {
            splatMesh.replacePackedSplats(packedSplats)
        }
        needsOrderingUpdate = true
        SplatPerfLog.measure("renderer: frameCamera") {
            frameCamera(to: packedSplats)
        }
    }

    open override func draw(renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) {
        let isFirstDraw = !didLogFirstDraw
        if isFirstDraw {
            SplatPerfLog.log("renderer: first draw begin (numSplats=\(splatMesh.packedSplats.numSplats))")
            didLogFirstDraw = true
        }
        if let sorter = gpuSorter {
            updateOrderingIfNeeded(sorter: sorter, commandBuffer: commandBuffer)
        }
        if isFirstDraw, SplatPerfLog.enabled {
            commandBuffer.addCompletedHandler { buffer in
                let gpuMillis = (buffer.gpuEndTime - buffer.gpuStartTime) * 1000.0
                SplatPerfLog.log(String(format: "renderer: first draw GPU time: %.2fms", gpuMillis))
            }
        }
        SplatPerfLog.measure("renderer: draw encode\(isFirstDraw ? " (first)" : "")") {
            renderer.draw(
                renderPassDescriptor: renderPassDescriptor,
                commandBuffer: commandBuffer,
                scene: scene,
                camera: camera
            )
        }
    }

    private func updateOrderingIfNeeded(sorter: SplatGPUSorter, commandBuffer: MTLCommandBuffer) {
        let position = camera.worldPosition
        let direction = camera.viewDirection
        let positionDelta = lastSortPosition.map { simd_length(position - $0) } ?? Float.greatestFiniteMagnitude
        let coorient = lastSortDirection.map { simd_dot(direction, $0) } ?? -Float.greatestFiniteMagnitude

        guard needsOrderingUpdate || positionDelta > sortDistance || coorient < sortCoorient else { return }
        guard let packedBuffer = splatMesh.packedBuffer,
              let orderingBuffer = splatMesh.orderingBuffer else { return }

        let isFirstSort = !didLogFirstSort
        if isFirstSort { didLogFirstSort = true }
        SplatPerfLog.measure("renderer: sorter.encode\(isFirstSort ? " (first)" : "")") {
            sorter.encode(
                commandBuffer: commandBuffer,
                packedBuffer: packedBuffer,
                orderingBuffer: orderingBuffer,
                numSplats: splatMesh.packedSplats.numSplats,
                modelViewMatrix: camera.viewMatrix * splatMesh.worldMatrix,
                metric: sortMetric
            )
        }

        lastSortPosition = position
        lastSortDirection = direction
        needsOrderingUpdate = false
    }

    open override func resize(size: (width: Float, height: Float), scaleFactor _: Float) {
        if let cameraController {
            cameraController.resize(size)
        } else {
            camera.aspect = size.width / size.height
        }
        if let material = splatMesh.material as? SplatMaterial {
            material.renderSize = [size.width, size.height]
        }
        renderer.resize(size)
    }

    public func resetCamera() {
        cameraController?.reset()
    }

    private func installCameraController() {
        cameraController = PerspectiveCameraController(camera: camera, view: metalView)
        cameraController?.rotationScalar = 2.0
        cameraController?.translationScalar = 0.75
        cameraController?.zoomScalar = 0.75
    }

    private func frameCamera(to packedSplats: PackedSplats) {
        guard packedSplats.numSplats > 0 else { return }

        let minBounds: SIMD3<Float>
        let maxBounds: SIMD3<Float>
        if let bounds = packedSplats.precomputedBounds {
            minBounds = bounds.min
            maxBounds = bounds.max
        } else {
            var lo = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
            var hi = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
            packedSplats.forEachSplat { _, splat in
                let radius = max(splat.scale.x, max(splat.scale.y, splat.scale.z))
                lo = simd_min(lo, splat.center - SIMD3<Float>(repeating: radius))
                hi = simd_max(hi, splat.center + SIMD3<Float>(repeating: radius))
            }
            minBounds = lo
            maxBounds = hi
        }

        let center = (minBounds + maxBounds) * 0.5
        let extent = maxBounds - minBounds
        let radius = max(simd_length(extent) * 0.5, 0.01)
        let distance = radius / max(tan(camera.fov * 0.5 * .pi / 180.0), 0.001)
        let position = center + SIMD3<Float>(0.0, 0.0, distance * 1.35)

        cameraController?.disable()
        camera.position = position
        camera.near = max(distance - radius * 3.0, 0.001)
        camera.far = distance + radius * 4.0
        camera.lookAt(target: center)
        cameraController?.defaultDistance = simd_length(position - center)
        cameraController?.defaultPosition = camera.position
        cameraController?.defaultOrientation = camera.orientation
        cameraController?.enable()
        needsOrderingUpdate = true
    }
}
