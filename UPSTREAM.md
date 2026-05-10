# Upstream Sync Guide

This package ports renderer code from [Spark](https://github.com/sparkjsdev/spark)
(JS/WebGL/Three.js) to Metal + Satin. When Spark changes, parts of this
package may need to follow. This document is the playbook for those syncs.

## Pinned upstream

The current Satin-Spark code targets the following upstream commit. Update
this block (and the date) whenever you do a sync.

- Spark: **v2.0.0-11-g3cf9fa1** (`3cf9fa15adb7ac7c47a1e962740db97b9e8a9fdf`)
- Pinned on: 2026-05-10
- Local clone path used by `Scripts/spark-visual-server.mjs`:
  `/Users/mnmly/Development-local/GitHub/js/spark`

## Files that mirror upstream Spark

These are the load-bearing ports. When upstream changes them, this package
likely needs updates. Anything else can usually drift independently.

| Upstream file | Mirror in this repo | Nature of port |
| --- | --- | --- |
| `src/shaders/splatVertex.glsl` | `Sources/SatinSpark/Pipelines/Splat/Shaders.metal` (`splatVertex`) | Direct port. Math identity preserved. |
| `src/shaders/splatFragment.glsl` | `Sources/SatinSpark/Pipelines/Splat/Shaders.metal` (`splatFragment`) | Direct port. |
| `src/shaders/splatDefines.glsl` | helpers in `Shaders.metal` (`unpackHalf2`, `quatToMatrix`, `decodeQuatOctXy88R8`) | Direct port. |
| `src/utils.ts` (`setPackedSplat`, `getPackedSplat`, `floatToUint8`, `encodeQuatOctXy88R8`) | `Sources/SatinSpark/PackedSplats.swift` (helpers + struct layout) | Byte-level compatible. |
| `src/ply.ts` (sigmoid opacity, `SH_C0 * f_dc + 0.5`, alpha/red/green/blue divisors) | `Sources/SatinSpark/SplatPLYLoader.swift` | Math identity preserved. |
| `src/PackedSplats.ts` (`SplatEncoding` lnScaleMin/Max defaults, packed array layout) | `Sources/SatinSpark/PackedSplats.swift` (`SplatEncoding`) | |
| `rust/spark-worker-rs/src/sort.rs` | `Sources/SatinSpark/SplatGPUSorter.swift` + `Pipelines/SplatSort/Shaders.metal` | **Different algorithm** (bitonic on GPU vs radix on CPU). Same back-to-front semantics. |

Files that are intentionally not mirrored (deferred features, see
`PORTING.md`'s "Deliberate Deferrals"):

- `src/SparkRenderer.ts` (the JS wrapper — this package wires Metal/Satin
  directly instead).
- `src/SplatAccumulator.ts`, `src/SplatPager.ts`, LOD/paging machinery.
- `src/dyno/*` (Spark's runtime shader graph).
- `src/SparkPortals.ts`, WebXR helpers.
- SOG/SPZ/KSPLAT loaders.

## Sync procedure

1. **Bump the pin.** `cd /Users/mnmly/Development-local/GitHub/js/spark &&
   git pull`. Note the new commit hash and tag, update the "Pinned upstream"
   block above.

2. **Diff the load-bearing files.** For each entry in the table above, run
   `git -C /path/to/spark log <prev-pin>..HEAD -- <upstream-file>` and read
   the diffs. Most upstream commits don't touch these files.

3. **For each touched file**, decide whether the change is:
   - **Math/encoding** (changes the splat byte format, opacity convention,
     projection math, or shader semantics): must be ported. Skip step 4 only
     after this is mirrored in the corresponding Satin file.
   - **JS/build/WebGL-specific plumbing**: can usually be ignored.
   - **A bug fix**: port it.
   - **A new feature behind a flag (e.g. `enable2DGS`, SH eval, LOD)**:
     decide whether to take it now or add to deferred list.

4. **Run the parity harness.** This is the regression test for the renderer.

   ```bash
   # In one terminal, serve the visual fixture
   node Scripts/spark-visual-server.mjs

   # Launch a visible Chrome with debug port
   /Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome \
     --remote-debugging-port=9222 \
     --user-data-dir=/tmp/satin-spark-chrome \
     --new-window --app=http://127.0.0.1:5179/fixture.html \
     --window-size=512,512 --force-device-scale-factor=1 &

   # Build Satin tools
   swift build

   # Generate the deterministic packed binary used on both sides
   .build/debug/satin-spark-pack-dump fixture /tmp/fixture-packed.bin

   # Capture both renders
   SATIN_SPARK_VISUAL_URL="http://127.0.0.1:5179/fixture.html?packed=/fixture-packed.bin" \
     node Scripts/capture-visible-chrome.mjs /tmp/spark-fixture.png
   .build/debug/satin-spark-render-fixture /tmp/satin-fixture.png

   # Diff
   .build/debug/satin-spark-image-diff /tmp/satin-fixture.png /tmp/spark-fixture.png /tmp/diff.png
   ```

   **Acceptance thresholds** (current baselines, on the deterministic 5-splat
   fixture, viewZ-sorted, 512×512):

   | mode | expected `mae` | expected `normalizedMAE` |
   | --- | --- | --- |
   | default (linearly-correct, sRGB target) | ≤ 1.5 | ≤ 0.006 |
   | `SATIN_SPARK_LEGACY_BLENDING=1` | ≤ 0.5 | ≤ 0.002 |

   If your numbers regress past those bounds after a sync, something in the
   port drifted from the upstream change.

5. **Run the test suite.** `swift test`. The
   `sortedOrderingSupportsViewZAndRadialMetrics` test guards the CPU sort
   reference; PLY tests guard byte-level loader compatibility.

6. **Run a dense-scene regression.** Bigger assets stress accumulation and
   surface bugs that the 5-splat fixture won't.

   ```bash
   .build/debug/satin-spark-pack-dump path/to/scene.ply /tmp/scene-packed.bin
   SATIN_SPARK_PACKED_BANANA=/tmp/scene-packed.bin \
     node Scripts/spark-visual-server.mjs &
   # capture spark, render satin, diff as in step 4
   ```

   The current dense-scene parity ceiling is around `mae≈6` (see PORTING.md
   "Banana parity investigation"). Don't take a regression past `mae≈10`
   without understanding what changed.

7. **If you ported a shader change**, verify all of these:
   - `swift test` still passes.
   - `satin-spark-render-fixture` output coverage check (`changedPixelRatio
     > 0.002`) still passes.
   - `SATIN_SPARK_VERIFY_PROJECTED_SAMPLES=1` and
     `SATIN_SPARK_VERIFY_ALPHA_FALLOFF=1` both still pass on the
     deterministic fixture.

## Things to watch for in upstream Spark commits

These are the kinds of upstream change that have historically caused
asymmetric drift:

- **Packed format byte layout** — any change to `setPackedSplat` or the
  `splatDefines.glsl` `unpackSplat*` helpers. Even a quat-encoding tweak
  invalidates already-dumped `.bin` fixtures.
- **`SplatEncoding` defaults** (`LN_SCALE_MIN`, `LN_SCALE_MAX`, `rgbMin`,
  `rgbMax`). The encoding is written into the dumped header; mismatched
  defaults silently corrupt.
- **`SplatAccumulator` opacity transforms.** Spark currently does not
  pre-halve opacity in the ext path, but if it ever does (or the vertex
  `*=2.0` line gets touched), our shader convention needs to follow.
- **Fragment falloff branches** (the `if (rgba.a <= 1.0)` / `else` split in
  `splatFragment.glsl`). Direct port; if the formula changes, we must follow.
- **`encodeLinear` defaulting.** Currently `false` in our path; we depend on
  this for the sRGB target's blend math to land where it does.
- **`enable2DGS` becoming a default-on path.** Currently both engines treat
  it as off. If Spark turns it on by default, we need to port that branch.

## What to update if you bump the pin

In a single PR / commit, ideally:

1. Bump the "Pinned upstream" block at the top of this file.
2. Update `THIRD_PARTY_NOTICES.md` only if Spark's `LICENSE` text changes.
3. Update the "Spark Module Map" in `PORTING.md` if the upstream filenames
   moved.
4. Land the actual code changes that mirror the upstream changes.
5. Re-run the parity harness and paste the new numbers into the commit
   message.
