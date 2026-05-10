import Dispatch
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

    private var lastSortPosition: SIMD3<Float>?
    private var lastSortDirection: SIMD3<Float>?
    private var needsOrderingUpdate = true
    private let sortQueue = DispatchQueue(label: "com.satin.spark.demo.sort", qos: .userInteractive)
    private var sortGeneration = 0
    private var sortInFlight = false
    private var sortAgainAfterInFlight = false

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
        sortGeneration += 1
        sortInFlight = false
        sortAgainAfterInFlight = false
        splatMesh.replacePackedSplats(packedSplats)
        needsOrderingUpdate = true
        frameCamera(to: packedSplats)
    }

    open override func draw(renderPassDescriptor: MTLRenderPassDescriptor, commandBuffer: MTLCommandBuffer) {
        updateOrderingIfNeeded()
        renderer.draw(
            renderPassDescriptor: renderPassDescriptor,
            commandBuffer: commandBuffer,
            scene: scene,
            camera: camera
        )
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

        var minBounds = SIMD3<Float>(repeating: Float.greatestFiniteMagnitude)
        var maxBounds = SIMD3<Float>(repeating: -Float.greatestFiniteMagnitude)
        packedSplats.forEachSplat { _, splat in
            let radius = max(splat.scale.x, max(splat.scale.y, splat.scale.z))
            minBounds = simd_min(minBounds, splat.center - SIMD3<Float>(repeating: radius))
            maxBounds = simd_max(maxBounds, splat.center + SIMD3<Float>(repeating: radius))
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

    private func updateOrderingIfNeeded() {
        let position = camera.worldPosition
        let direction = camera.viewDirection
        let positionDelta = lastSortPosition.map { simd_length(position - $0) } ?? Float.greatestFiniteMagnitude
        let coorient = lastSortDirection.map { simd_dot(direction, $0) } ?? -Float.greatestFiniteMagnitude

        guard needsOrderingUpdate || positionDelta > sortDistance || coorient < sortCoorient else { return }

        scheduleOrderingUpdate(modelViewMatrix: camera.viewMatrix, metric: sortMetric)
        lastSortPosition = position
        lastSortDirection = direction
        needsOrderingUpdate = false
    }

    private func scheduleOrderingUpdate(modelViewMatrix: simd_float4x4, metric: SplatSortMetric) {
        if sortInFlight {
            sortAgainAfterInFlight = true
            return
        }

        sortInFlight = true
        sortAgainAfterInFlight = false
        let generation = sortGeneration
        let packedArray = splatMesh.packedSplats.packedArray
        let numSplats = splatMesh.packedSplats.numSplats

        sortQueue.async { [weak self] in
            let ordering = PackedSplats.sortedOrdering(
                packedArray: packedArray,
                numSplats: numSplats,
                modelViewMatrix: modelViewMatrix,
                metric: metric
            )

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                guard generation == sortGeneration else { return }

                splatMesh.applyOrdering(ordering)
                sortInFlight = false
                if sortAgainAfterInFlight {
                    needsOrderingUpdate = true
                    sortAgainAfterInFlight = false
                }
            }
        }
    }
}
