# SatinSpark Public API

Reference for the `SatinSpark` library target. All types live in
`SatinSpark` and depend on Satin + Metal + simd.

> Status: `v0.1.0`. The surface here is functional but not yet frozen —
> packed-format extensions, SH evaluation, and the `legacySparkBlending`
> compatibility flag are likely to shift before `v1.0.0`.

## Loading splats

### `enum SplatPLYLoader`

Static loader that parses ASCII or binary little-endian Gaussian splat
`.ply` files and produces a `PackedSplats`.

```swift
public static func load(url: URL) throws -> PackedSplats
public static func load(data: Data) throws -> PackedSplats
```

Throws `SplatPLYLoaderError` on malformed/missing-property input.

Decoding conventions match Spark's `src/ply.ts`:
- Opacity: `1 / (1 + exp(-opacity))` (sigmoid of stored logit).
- Color: `f_dc_0/1/2 * SH_C0 + 0.5` (where `SH_C0 ≈ 0.282094`).
- Falls back to `red/green/blue` and `alpha` properties when DC SH absent.

### `final class PackedSplats`

Container for the 16-byte-per-splat packed array (RGBA / center / scales /
quaternion). Byte-compatible with Spark's `PackedSplats`.

```swift
public init(packedArray: [UInt32], numSplats: Int, splatEncoding: SplatEncoding)
public convenience init(splats: [PackedSplat], splatEncoding: SplatEncoding = SplatEncoding())

public private(set) var numSplats: Int
public private(set) var maxSplats: Int
public private(set) var packedArray: [UInt32]
public var splatEncoding: SplatEncoding

// Mutation (one splat at a time)
public func setSplat(_ splat: PackedSplat, at index: Int)
public func getSplat(at index: Int) -> PackedSplat
public func setCenter  (_ center: SIMD3<Float>, at index: Int)
public func setScale   (_ scale: SIMD3<Float>, at index: Int)
public func setRotation(_ rotation: simd_quatf, at index: Int)
public func setRGBA    (color: SIMD3<Float>, opacity: Float, at index: Int)
public func setColor   (_ color: SIMD3<Float>, at index: Int)
public func setOpacity (_ opacity: Float, at index: Int)

// Iteration / inspection
public func forEachSplat(_ body: (Int, PackedSplat) throws -> Void) rethrows
public func packedWords (at index: Int) -> SIMD4<UInt32>

// GPU buffers (storage modes default to .storageModeShared)
public func makeBuffer                (device: MTLDevice, options: MTLResourceOptions) -> MTLBuffer?
public func makeIdentityOrderingBuffer(device: MTLDevice, options: MTLResourceOptions) -> MTLBuffer?
public func makeOrderingBuffer        (device: MTLDevice, ordering: [UInt32], options: MTLResourceOptions) -> MTLBuffer?

// CPU reference sort (back-to-front)
public func sortedOrdering        (modelViewMatrix: simd_float4x4, metric: SplatSortMetric = .radial) -> [UInt32]
public static func sortedOrdering (packedArray: [UInt32], numSplats: Int, modelViewMatrix: simd_float4x4, metric: SplatSortMetric = .radial) -> [UInt32]
```

### `struct PackedSplat`

Decoded view of one splat. Useful for hand-building scenes (see
`SplatFixtures.deterministicScene()` for an example).

```swift
public var center  : SIMD3<Float>
public var scale   : SIMD3<Float>
public var rotation: simd_quatf
public var opacity : Float
public var color   : SIMD3<Float>

public init(center: SIMD3<Float>, scale: SIMD3<Float>,
            rotation: simd_quatf = simd_quatf(angle: 0, axis: [1, 0, 0]),
            opacity: Float = 1.0,
            color: SIMD3<Float> = [1.0, 1.0, 1.0])
```

### `struct SplatEncoding`

Range / convention metadata that the packed bytes are interpreted with.
Defaults match Spark.

```swift
public var rgbMin     : Float = 0.0
public var rgbMax     : Float = 1.0
public var lnScaleMin : Float = -12.0     // SparkConstants.lnScaleMin
public var lnScaleMax : Float = 9.0       // SparkConstants.lnScaleMax
public var sh1Max     : Float = 1.0
public var sh2Max     : Float = 1.0
public var sh3Max     : Float = 1.0
public var lodOpacity : Bool  = false
```

## Rendering

### `final class SplatMesh : Mesh`

A Satin `Mesh` instanced over an `nx2`-triangle quad, one instance per
splat. Defaults: `cullMode = .none`, `doubleSided = true`, render layer
`.opaque` (the material handles transparency). Honors the mesh's
`worldMatrix` end-to-end (shader covariance and sort).

```swift
public private(set) var packedSplats  : PackedSplats
public private(set) var packedBuffer  : MTLBuffer?
public private(set) var orderingBuffer: MTLBuffer?
public private(set) var ordering      : [UInt32]

public init(context: Context, packedSplats: PackedSplats, label: String = "SplatMesh")

public func replacePackedSplats(_ packedSplats: PackedSplats)
public func rebuildBuffers()

// Convenience wrappers around the CPU sort (see SplatGPUSorter for the GPU path)
public func updateOrdering       (modelViewMatrix: simd_float4x4, metric: SplatSortMetric = .radial)
public func makeOrderingSnapshot (modelViewMatrix: simd_float4x4, metric: SplatSortMetric = .radial) -> [UInt32]
public func applyOrdering        (_ ordering: [UInt32])
```

### `final class SplatMaterial : SourceMaterial`

The shader-backed material driving the splat pipeline. All `var` parameters
re-push their uniform on `didSet`.

```swift
// Geometry / projection
public var maxStdDev      : Float = sqrt(8.0)   // ellipse extent in std-devs (Spark default)
public var minPixelRadius : Float = 0.0
public var maxPixelRadius : Float = 512.0
public var clipXY         : Float = 1.4         // frustum-side cull factor on |clip.xy| / w
public var focalAdjustment: Float = 1.0

// Alpha / falloff
public var minAlpha       : Float = 0.5 / 255.0
public var preBlurAmount  : Float = 0.0         // adds to cov2D before AA blur
public var blurAmount     : Float = 0.3         // AA Gaussian blur in cov2D, attenuates alpha
public var falloff        : Float = 1.0         // 0 = flat, 1 = full Gaussian

// Required by the shader (caller wires these every frame / on resize)
public var renderSize     : SIMD2<Float> = [1.0, 1.0]
public var splatEncoding  : SplatEncoding = SplatEncoding()
public func setNumSplats(_ numSplats: Int)
public func setPackedBuffer (_ buffer: MTLBuffer?)
public func setOrderingBuffer(_ buffer: MTLBuffer?)

// Compatibility / debugging
public var legacySparkBlending: Bool = false    // see "Compatibility flags" below
public var debugMode      : UInt32 = 0          // 0=off, 1=quads, 2=projected, 3=covariance, 4=scales
```

`SplatMesh.init(...)` constructs and wires this material; you usually only
touch `renderSize` and `splatEncoding` from outside.

### `enum SplatSortMetric`

```swift
case viewZ    // sort by view-space Z (back-to-front for camera looking down -Z)
case radial   // sort by squared distance to camera
```

### `final class SplatGPUSorter`

Metal compute bitonic sort. One instance of this class can be reused
across frames; scratch buffers are sized once per max-splats seen.

```swift
public init(device: MTLDevice) throws

public func encode(
    commandBuffer: MTLCommandBuffer,
    packedBuffer: MTLBuffer,
    packedOffset: Int = 0,
    orderingBuffer: MTLBuffer,
    numSplats: Int,
    modelViewMatrix: simd_float4x4,
    metric: SplatSortMetric = .viewZ
)
```

After `commandBuffer.commit()` the first `numSplats` entries of
`orderingBuffer` are the splat indices in back-to-front order; padded
entries (up to the next power-of-two) are `0xffffffff` and are culled by
the vertex shader.

**Pass `camera.viewMatrix * splatMesh.worldMatrix`** for `modelViewMatrix`
so the sort respects mesh transforms. Same goes for the CPU sort variants
on `PackedSplats` / `SplatMesh`.

## Helpers

### `enum SplatFixtures`

```swift
public static func deterministicScene() -> PackedSplats
```

Five hand-built splats — used by the demo, the render-fixture's default
scene, and the visual parity harness.

### `enum SplatReference`

CPU mirror of the GPU pipeline (decode → project → falloff). Used by the
render-fixture's `SATIN_SPARK_VERIFY_*` modes; useful for unit-testing the
math against the shader without spinning up Metal.

```swift
public static func decodePackedSplat(_ words: SIMD4<UInt32>, encoding: SplatEncoding) -> DecodedSplat
public static func project(_ decoded: DecodedSplat,
                           modelViewMatrix: simd_float4x4,
                           projectionMatrix: simd_float4x4,
                           renderSize: SIMD2<Float>) -> ProjectedSplat?
```

### `class SplatDemoRenderer : MetalViewRenderer` and `SplatDemoView : View`

Quick path to a working SwiftUI demo. Shows `SplatFixtures.deterministicScene()`
with a `PerspectiveCameraController` and per-frame GPU sort. Subclass or
copy as needed.

```swift
public lazy var splatMesh: SplatMesh
public var sortMetric    : SplatSortMetric = .viewZ
public var sortDistance  : Float = 0.01      // re-sort threshold (camera position delta)
public var sortCoorient  : Float = 0.999     // re-sort threshold (camera-direction dot)
public func replacePackedSplats(_ packedSplats: PackedSplats)
public func resetCamera()
```

## Compatibility flags

### `SplatMaterial.legacySparkBlending`

Default: `false` (linearly-correct math + sRGB render target).

Set to `true` to match Three.js Spark's display-space-blend output
byte-for-byte. Requires the caller to *also*:
- Render to a non-sRGB target (`.bgra8Unorm`, not `.bgra8Unorm_srgb`).
- Pre-encode the clear color via `linearToSRGB` so blend-dst lands in the
  same byte storage Three.js's Spark renderer puts it in.

`SatinSparkRenderFixture/main.swift` shows the wiring; the
`SATIN_SPARK_LEGACY_BLENDING=1` env var on that binary opts in.

This flag exists for regression tests against Spark's actual byte output
(useful when porting or diffing). It's not the recommended production
mode — the default is mathematically correct.

## CLI tools (cmd-line, not library API)

These ship as separate Swift Package products.

| Tool | Purpose |
| --- | --- |
| `satin-spark-pack-dump <input.ply\|fixture> <output.bin>` | Pack a `.ply` or the deterministic fixture into Spark's wire-compatible packed binary. |
| `satin-spark-render-fixture <output.png> [<input.ply>]` | Offscreen render to PNG. Without `<input.ply>`, draws `SplatFixtures.deterministicScene()`. |
| `satin-spark-image-diff <a.png> <b.png> [<diff.png>]` | MAE / changed-pixel-ratio metrics + optional 8x-amplified diff PNG. |
| `satin-spark-demo` | SwiftUI live demo. |
| `satin-spark-bench` | Stub for future microbenchmarks. |

### `satin-spark-render-fixture` env vars

| Var | Effect |
| --- | --- |
| `SATIN_SPARK_LEGACY_BLENDING=1` | Render in Spark byte-parity mode. |
| `SATIN_SPARK_SORT=cpu\|gpu\|none` | Choose splat sort path. Default `gpu`. `none` uses identity ordering (mostly for debugging dense-scene accumulation). |
| `SATIN_SPARK_MAX_STD_DEV=<float>` | Override the material's `maxStdDev`. Debug knob. |
| `SATIN_SPARK_MESH_TRANSLATE=<x>,<y>,<z>` | Translate `splatMesh.position` before render. Smoke-test for world-matrix correctness. |
| `SATIN_SPARK_DEBUG_QUADS=1`, `_PROJECTED=1`, `_COVARIANCE=1`, `_SCALES=1` | Debug visualizations via `SplatMaterial.debugMode`. |
| `SATIN_SPARK_VERIFY_PROJECTED_SAMPLES=1` | After render, sample CPU-projected splat centers and assert color/dominance/axis hits. |
| `SATIN_SPARK_VERIFY_ALPHA_FALLOFF=1` | Render an isolated low-opacity splat and verify alpha matches the analytical Gaussian. |
| `SATIN_SPARK_DUMP_PACKED=1`, `_REFERENCE=1`, `_MATERIAL_PARAMS=1` | Dump diagnostic info to stdout. |

## See also

- [README.md](./README.md) — overview, install, minimum example.
- [PORTING.md](./PORTING.md) — what's done, what's deferred, parity findings.
- [UPSTREAM.md](./UPSTREAM.md) — Spark sync playbook + release/upstream mapping.
- [THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md) — Spark MIT, Satin MIT.
