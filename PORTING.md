# Spark to Satin Porting Notes

This package should track Spark's architecture directly where practical. The WABF
Gaussian splat code is useful for Satin/Metal mechanics, but it is not the source
shape for this port.

> **License & upstream:** ports of Spark (MIT) and dependence on Satin (MIT) are
> attributed in [`THIRD_PARTY_NOTICES.md`](./THIRD_PARTY_NOTICES.md). When Spark
> upstream changes, follow the playbook in [`UPSTREAM.md`](./UPSTREAM.md) — the
> pinned commit, parity-harness command list, and acceptance thresholds live
> there.

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
  projection drift. The CPU projection oracle now uses the same opacity,
  pre-blur/blur, focal-adjustment, and radius defaults as `SplatMaterial`, so it
  catches actual shader drift instead of the older opacity-doubled reference path.
  The combined-scene center color check is intentionally tolerant of overlap
  between splats.
- `SATIN_SPARK_VERIFY_ALPHA_FALLOFF=1` renders a low-opacity isolated splat,
  infers fragment alpha from the blended RGB over the known clear color, and
  checks center/half-radius/three-quarter-radius samples against Spark's simple
  Gaussian falloff branch. The verifier samples the observed clear color from
  the output image, so it remains valid across sRGB and byte-parity render
  targets.
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
- `SplatLoader` now routes the static loader formats through the public
  dispatcher: PLY, Spark `.splat`, SPZ, KSPLAT, PC-SOGS metadata/images,
  bundled SOG/PC-SOGS zip, and inline RAD files.
- Packed SH data has a public CPU evaluator matching the shader-side SH1/SH2/SH3
  basis and quantization. `SplatMesh` already binds SH buffers and sets `shDegree`,
  so loaded SH data now has both render-time and CPU-test coverage.
- Real fixture preparation is handled by `node Scripts/prepare-fixtures.mjs`.
  It downloads Spark's hosted `robot-head.spz` and `sutro.zip` examples,
  extracts GaussianSplats3D's `bonsai_trimmed.ksplat` from the original demo
  data bundle, downloads a raw `.splat` example cited by the original
  `antimatter15/splat` README, downloads a hosted Gaussian splat PLY example,
  and derives inline/sidecar RAD fixtures with Spark's Rust `build-lod`. The
  generated binaries are ignored by git.
- Bundled SOG/PC-SOGS zip decoding now accepts Spark's current no-version SOG
  metadata shape in addition to the older version-2/codebook shape.
- Inline RAD decoding covers Spark's chunk property model for packed/static
  rendering: center, alpha, RGB, scales, orientation, and direct SH1/SH2/SH3
  properties, including the common scalar encodings and zlib/gzip-compressed
  property payloads. This is covered by a real fixture generated from Spark's
  hosted `robot-head.spz` example with Spark's Rust `build-lod` tool.
- Static RAD sidecar loading is in place for `.rad` headers with `.radc`
  filenames when loading from a file URL; the test fixture uses Spark's
  `--rad-chunked` output.
- RAD paging has a first local-file implementation: `SplatRADPagedFile` loads the
  header separately, `loadChunk`/`loadRootChunk` decode individual inline or
  sidecar chunks, and `SplatRADPage` preserves `child_count`/`child_start`. The
  page can do CPU LOD selection via `selectLOD(...)`, and `SplatMesh` can render
  that selected subset with `applyVisibleOrdering(...)`.
- GPU RAD page selection is in place for loaded pages: `SplatRADGPUPager` builds
  child-start/parent traversal buffers and encodes LOD selection into a mesh
  ordering buffer. `SplatGPUSorter.encodeExistingOrdering(...)` can then sort the
  selected subset on GPU before drawing.
- RAD page scheduling now has a local LRU cache (`SplatRADPageCache`) that keeps
  a bounded resident set of decoded chunks and can prepare chunk priorities for
  larger sidecar/inline RAD files.
- Remote/async RAD paging is represented by `SplatRADRemotePagedFile` and
  `SplatRADAsyncPageCache`. HTTP URLs use range requests for inline RAD chunks
  and sidecar URL resolution for `.radc`; file URLs use the same async API for
  tests and local apps.
- Spark's extended splat 8-word encoding is represented by `ExtSplats`:
  full-float centers, half-float opacity/RGB/log-scale, and octahedral 10/10/12
  quaternion packing. Ext splats can round-trip to packed splats and expose a
  covariance matrix helper for covariance-splat paths.
- Native ext-splat rendering is available through `ExtSplatMesh`,
  `ExtSplatMaterial`, and `Pipelines/ExtSplat/Shaders.metal`.
- `SplatSkinning` ports Spark's dual-quaternion skinning math for packed,
  ext, and covariance splats. It can transform individual splats or produce
  skinned `PackedSplats`/`ExtSplats` collections.

## Spark Module Map

| Spark | SatinSpark target |
| --- | --- |
| `defines.ts` | `SplatEncoding.swift` |
| `PackedSplats.ts` | `PackedSplats.swift` |
| `SplatGeometry.ts` | `SplatGeometry.swift` |
| `SplatMesh.ts` | `SplatMesh.swift` |
| `ExtSplats.ts` | `ExtSplats.swift` |
| `SplatPager.ts` | `SplatRADPageCache.swift`, `SplatRADRemotePagedFile.swift`, `SplatRADGPUPager.swift` |
| `SplatSkinning.ts` | `SplatSkinning.swift` |
| `shaders/splatDefines.glsl` | `Pipelines/Splat/Shaders.metal` helpers |
| `shaders/splatVertex.glsl` | `splatVertex` |
| `shaders/splatFragment.glsl` | `splatFragment` |

## Visual Parity Harness (Chrome vs Satin)

End-to-end runnable now. Three pieces:

- `Scripts/spark-visual-server.mjs` serves `Scripts/spark-visual-fixture.html` and
  packed-binary fixtures (`/banana-packed.bin`, `/fixture-packed.bin`, or any
  `?packed=...` query) from the local Spark JS clone at
  `/Users/mnmly/Development-local/GitHub/js/spark`.
- `Scripts/capture-visible-chrome.mjs` drives a visible Chrome over CDP (port 9222),
  navigates to a target URL, and grabs the canvas via `toDataURL`. Forwards
  `Runtime.consoleAPICalled`, `Runtime.exceptionThrown`, and `Log.entryAdded` over
  stderr (`[chrome:log]`, `[chrome:exception]`).
- `satin-spark-pack-dump fixture <out.bin>` dumps the deterministic 5-splat scene
  in the same packed binary format the JS fixture loads, so both engines see
  byte-identical input.

`satin-spark-render-fixture` and `satin-spark-image-diff` round out the loop on the
Satin side.

### Color pipeline parity findings

Spark's WebGL pipeline differs from the obvious Metal-correct path in two ways:

1. **Framebuffer / blend space.** Three.js with `outputColorSpace: srgb` and the
   default `WebGLRenderer` ends up alpha-blending in the sRGB-encoded byte storage
   (mathematically incorrect "linear blend on sRGB bytes" — common in legacy WebGL).
   For exact byte parity, Satin needs to render to `.bgra8Unorm` (no auto sRGB) and
   pre-encode the clear color via `linearToSRGB` so the dst byte matches.
2. **Opacity convention.** Spark's vertex shader has `rgba.a *= 2.0` in the
   single-texture branch but its `SplatAccumulator` repacks splats into the
   8-word ext format that bypasses that branch entirely (vertex `if` branch reads
   opacity directly). Net effect: Spark's effective alpha is the raw stored byte.
   Satin used to call `rgba.a *= 2.0` unconditionally — this has been removed.

### Current diff numbers

Captured with the deterministic 5-splat fixture, viewZ-sorted, 512x512:

| mode | mae | normalizedMAE | maxChannelDifference |
| --- | --- | --- | --- |
| Satin default (linearly-correct, `.bgra8Unorm_srgb`) | 1.32 | 0.0052 | 67 |
| Satin `SATIN_SPARK_LEGACY_BLENDING=1` (Spark byte-parity) | 0.43 | 0.0017 | 67 |

Banana 6585-splat scene still shows `mae≈30–40` in either mode. The dominant
residual is **per-splat projected size** (Satin's banana renders visibly wider
than Spark's), not opacity or colorspace. Sort metric (radial vs viewZ) moves
the result by <1%. Suspect: `adjustedStdDev`, `blurAmount`, or `focal` interact
slightly differently with dense-overlap accumulation. Needs a single-splat
isolation tool to debug — extracting one splat from the banana, rendering it
alone in both engines, and comparing projected radius.

### `legacySparkBlending` flag

Lives on `SplatMaterial`. When `true`:
- vertex skips `srgbToLinear` decode in fragment
- works in conjunction with a non-sRGB render target and pre-encoded clear color

Useful as a regression test against Spark's actual output, not as a production
mode. The render fixture toggles it via `SATIN_SPARK_LEGACY_BLENDING=1`. Default
(`false`) renders linearly-correct.

## GPU Splat Sort

Implemented in `SplatGPUSorter` (`Sources/SatinSpark/SplatGPUSorter.swift`,
kernels in `Pipelines/SplatSort/Shaders.metal`). Bitonic sort over (key, index)
pairs:

- `splatSortComputeKeys` decodes each splat's center, transforms to view-space,
  emits `key = view.z` (viewZ metric) or `-|view|²` (radial). Padding entries
  receive `+infinity` keys and `0xffffffff` indices, so they sort to the tail
  and the vertex shader culls them by index.
- `splatSortComputeKeysFromOrdering` performs the same keying pass from an
  existing ordering buffer, which keeps RAD GPU LOD selection and sorting on the
  command buffer without CPU readback.
- `splatSortBitonicStep` runs `O(log² N)` compare-and-swap passes. Scratch keys
  + indices buffers are `.storageModePrivate` and reused across calls.
- The sorted index array is blit-copied into the existing `orderingBuffer`
  (`storageModeShared`) the vertex shader already binds.

Wired in:
- `SatinSparkRenderFixture` uses GPU sort by default; `SATIN_SPARK_SORT=cpu`
  falls back to `PackedSplats.sortedOrdering` (CPU reference) for regression
  verification.
- `SplatDemoRenderer` now sorts on the GPU per-frame as part of the same
  command buffer that draws the splats. The original async-dispatch CPU sort
  scaffolding has been removed.

The CPU implementation (`PackedSplats.sortedOrdering`) is retained as a tested
reference and is not used at runtime.

A/B verification: GPU and CPU sort produce byte-identical output on the
deterministic 5-splat fixture, and within 1 LSB on banana 6585-splat (same-key
splats sort in different orders due to fp ordering of compares — both correct).

## Next Steps

1. Port SDF edit execution if the Satin integration needs interactive Spark edit
   workflows.
2. Optionally move `SplatSkinning` from CPU-produced skinned collections into a
   live GPU material path if animated skeletons need per-frame deformation
   without rebuilding splat buffers.

Parity is now measured against `biker.ply` rather than the earlier banana
fixture. The CPU sort is retained only as a test oracle and `SATIN_SPARK_SORT=cpu`
A/B toggle; no further optimization (e.g. ordering-buffer reuse) is planned for
that path since it does not run at runtime.

## Deliberate Deferrals

- Dyno shader graph.
- WebXR/control helpers (not planned).
- Portal rendering.
- SDF edit shader execution.
- Live GPU skinning in the render material; CPU skinning and covariance rotation
  are implemented.
