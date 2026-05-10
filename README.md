# Satin-Spark

Metal/Satin port of [Spark](https://github.com/sparkjsdev/spark) — Gaussian
splat rendering for Apple platforms (macOS, iOS, visionOS).

This package mirrors Spark's runtime architecture for `.ply` Gaussian splat
scenes: same packed byte format, same projection math, same alpha falloff —
implemented as a Metal vertex/fragment pipeline backed by a [Satin](https://github.com/Hi-Rez/Satin)
`Renderer`, plus a Metal compute bitonic sort for back-to-front ordering.

**Status:** early (`v0.1.0`). Renders packed splats correctly. Public API is
not yet frozen. See [PORTING.md](./PORTING.md) for what's done and deferred,
[UPSTREAM.md](./UPSTREAM.md) for the Spark sync playbook, and
[API.md](./API.md) for the public surface.

## What's in the box

- **`SatinSpark`** — library: `SplatMesh`, `SplatMaterial`, `PackedSplats`,
  `SplatPLYLoader`, `SplatGPUSorter`, `SplatDemoRenderer`. Drop a splat
  scene into any Satin app.
- **`satin-spark-pack-dump`** — CLI: `.ply` → packed binary in Spark's
  format (so the same bytes round-trip through the JS Spark fixture).
- **`satin-spark-render-fixture`** — CLI: offscreen render of a fixture or
  loaded `.ply` to PNG. Used as the regression check against Spark.
- **`satin-spark-image-diff`** — CLI: MAE / per-pixel diff between two PNGs.
- **`satin-spark-demo`** — SwiftUI app rendering the deterministic 5-splat
  scene live with mouse camera control.
- **`Scripts/`** — Spark↔Satin visual parity harness (Node.js server,
  Chrome capture via CDP, fixture HTML loading the local Spark JS clone).

## Install

Swift Package Manager. Add a path or git dependency:

```swift
.package(url: "https://github.com/<you>/Satin-Spark.git", from: "0.1.0"),
// then in your target:
.product(name: "SatinSpark", package: "Satin-Spark"),
```

You'll also need [Satin](https://github.com/Hi-Rez/Satin) — `Package.swift`
in this repo currently uses a local `.package(path:"../Satin")` for
development. Adapt to your fork/upstream as appropriate.

Requires Metal-capable Apple silicon and Swift 5.9+. macOS 14 / iOS 17 /
visionOS 2 baselines, matching Satin.

## Minimum example

```swift
import Metal
import Satin
import SatinSpark

// 1. Load a Gaussian splat .ply
let splats = try SplatPLYLoader.load(url: bundle.url(forResource: "scene", withExtension: "ply")!)

// 2. Build a SplatMesh and add it to a Satin scene
let context = Context(device: device, sampleCount: 1, colorPixelFormat: .bgra8Unorm_srgb, depthPixelFormat: .depth32Float)
let splatMesh = SplatMesh(context: context, packedSplats: splats)
let scene = Object(context: context, label: "scene", [splatMesh])

// 3. Render with sorted back-to-front ordering. Easiest path: extend
//    SplatDemoRenderer (SwiftUI), which wires GPU sort + camera control:
struct ContentView: View {
    var body: some View { SplatDemoView() }   // shows SplatFixtures.deterministicScene()
}
```

For a custom integration (your own renderer, your own command buffer),
`SplatGPUSorter.encode(commandBuffer:packedBuffer:orderingBuffer:numSplats:modelViewMatrix:metric:)`
is the call you want; pass `camera.viewMatrix * splatMesh.worldMatrix` so
the sort respects mesh transforms.

## Visual parity with upstream Spark

The parity harness diffs Satin's output against Three.js Spark on the same
packed binary. Useful when porting a shader change or bumping the Spark
pin.

```bash
# 1) Serve fixtures (expects local Spark clone, see Scripts/spark-visual-server.mjs)
node Scripts/spark-visual-server.mjs

# 2) Open Chrome with debug port
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
  --remote-debugging-port=9222 \
  --user-data-dir=/tmp/satin-spark-chrome \
  --new-window --app=http://127.0.0.1:5179/fixture.html \
  --window-size=512,512 --force-device-scale-factor=1 &

# 3) Build, dump fixture, capture, diff
swift build
.build/debug/satin-spark-pack-dump fixture /tmp/fixture-packed.bin
SATIN_SPARK_VISUAL_URL="http://127.0.0.1:5179/fixture.html?packed=/fixture-packed.bin" \
  node Scripts/capture-visible-chrome.mjs /tmp/spark-fixture.png
.build/debug/satin-spark-render-fixture /tmp/satin-fixture.png
.build/debug/satin-spark-image-diff /tmp/satin-fixture.png /tmp/spark-fixture.png /tmp/diff.png
```

Acceptance numbers on the deterministic 5-splat fixture (512×512):

| mode | mae | normalizedMAE |
| --- | --- | --- |
| default (linearly-correct, sRGB target) | ≤ 1.5 | ≤ 0.006 |
| `SATIN_SPARK_LEGACY_BLENDING=1` | ≤ 0.5 | ≤ 0.002 |

See [UPSTREAM.md](./UPSTREAM.md) for the full sync procedure.

## License

[MIT](./LICENSE). Spark and Satin attribution in
[THIRD_PARTY_NOTICES.md](./THIRD_PARTY_NOTICES.md).
