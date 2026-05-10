# Spark to Satin Porting Notes

This package should track Spark's architecture directly where practical. The WABF
Gaussian splat code is useful for Satin/Metal mechanics, but it is not the source
shape for this port.

## Current MVP

- `PackedSplats` mirrors Spark's 16-byte packed splat representation:
  - word 0: RGBA as 4 x `uint8`
  - word 1: center x/y as `float16`
  - word 2: center z plus quaternion x/y bytes
  - word 3: scale x/y/z bytes plus quaternion z byte
- `SplatMesh` is a normal Satin `Mesh` with an instanced quad.
- `SplatMaterial` is a Satin `SourceMaterial` backed by `Pipelines/Splat/Shaders.metal`.
- The shader unpacks packed splats and applies Spark's fragment falloff.
- `satin-spark-render-fixture` renders `SplatFixtures.deterministicScene()` offscreen
  for visual smoke testing.

## Current Checkpoint

- Build with Xcode/DerivedData:
  `xcodebuild -scheme satin-spark-render-fixture -configuration Debug -destination platform=macOS -derivedDataPath ./.xcdd build`
- Run the Metal fixture from the Xcode product:
  `.xcdd/Build/Products/Debug/satin-spark-render-fixture /tmp/satin-spark-fixture.png`
- Build the live SwiftUI demo:
  `xcodebuild -scheme satin-spark-demo -configuration Debug -destination platform=macOS -derivedDataPath ./.xcdd build`
- Run the live demo from the Xcode product:
  `.xcdd/Build/Products/Debug/satin-spark-demo`
- Run CPU/reference parity tests:
  `swift test`
- The fixture currently renders five colored packed splats and passes the coverage
  threshold.
- The render path now uses Spark's covariance projection path rather than the
  earlier fixed-radius debug path.
- `rgbMinMaxLnScaleMinMax` is passed through Satin's material parameter system
  and used by the shader for RGB remap and packed scale decode. `SplatMaterial`
  re-applies its stored Swift-side values after shader parameter discovery so
  Satin's parsed defaults do not clobber values set before pipeline setup.
- Debug modes remain available through environment flags:
  `SATIN_SPARK_DEBUG_QUADS=1`, `SATIN_SPARK_DEBUG_PROJECTED=1`,
  `SATIN_SPARK_DEBUG_COVARIANCE=1`, `SATIN_SPARK_DEBUG_SCALES=1`, and
  `SATIN_SPARK_DUMP_MATERIAL_PARAMS=1`.
- `SATIN_SPARK_VERIFY_PROJECTED_SAMPLES=1` runs a shader-observable smoke check:
  it projects each fixture splat with the same Satin camera matrices used for the
  render, samples the output image at those centers, and verifies visible color
  dominance/energy. It also renders each fixture splat in isolation and samples
  inside/outside the CPU-projected major/minor axes to catch scale or axis
  projection drift. The combined-scene center color check is intentionally
  tolerant of overlap between splats.
- `SATIN_SPARK_VERIFY_ALPHA_FALLOFF=1` renders a low-opacity isolated splat,
  infers fragment alpha from the blended RGB over the known clear color, and
  checks center/half-radius/three-quarter-radius samples against Spark's simple
  Gaussian falloff branch.
- `satin-spark-demo` hosts `SplatDemoView` in a small SwiftUI app and renders the
  deterministic fixture scene live. `SplatDemoRenderer.resize` forwards the live
  viewport size into `SplatMaterial.renderSize`, matching the offscreen fixture
  path.
- `PackedSplats` now exposes Spark-style CPU helper APIs for unpacking,
  iterating, and per-field updates (`setCenter`, `setScale`, `setRotation`,
  `setRGBA`, `setColor`, `setOpacity`). CPU reference decode applies Spark's
  RGB remap and `lodOpacity` behavior, matching shader-side decode.
- CPU-side back-to-front ordering is in place: `PackedSplats.sortedOrdering`
  can sort by camera view Z or radial distance, `SplatMesh.updateOrdering`
  uploads the ordering buffer, and `satin-spark-demo` refreshes radial ordering
  before each draw.

## Spark Module Map

| Spark | SatinSpark target |
| --- | --- |
| `defines.ts` | `SplatEncoding.swift` |
| `PackedSplats.ts` | `PackedSplats.swift` |
| `SplatGeometry.ts` | `SplatGeometry.swift` |
| `SplatMesh.ts` | `SplatMesh.swift` |
| `shaders/splatDefines.glsl` | `Pipelines/Splat/Shaders.metal` helpers |
| `shaders/splatVertex.glsl` | `splatVertex` |
| `shaders/splatFragment.glsl` | `splatFragment` |

## Next Steps

1. Move ordering updates toward production scale: reuse ordering buffer storage
   instead of allocating each refresh, then move sorting to Metal compute.
2. Add Chrome-vs-Satin visual parity capture:
   - render the same deterministic packed scene in JS Spark under headless Chrome
   - render `SplatFixtures.deterministicScene()` through Satin offscreen
   - compare screenshots with tolerance and write a diff image
3. Port `SplatLoader` format-by-format, beginning with `.splat` or `.ply`.
4. Add extended splats, SH data, LOD, paging, and edit/skinning features after the
   packed render path is visually validated.

## Deliberate Deferrals

- Dyno shader graph.
- WebXR/control helpers.
- Portal rendering.
- SOG/SPZ/KSPLAT support until the base loader shape is established.
- GPU LOD traversal and paging until sorted packed rendering is stable.
