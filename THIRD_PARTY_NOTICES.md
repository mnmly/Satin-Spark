# Third-Party Notices

This project ports and depends on third-party software. The components below
retain their original licenses; the verbatim license text for each is
reproduced.

---

## Spark (`@sparkjsdev/spark`)

- Source: https://github.com/sparkjsdev/spark
- License: MIT
- Copyright © 2025 World Labs Technologies, Inc.

The following files in this repository are direct ports or substantial
adaptations of Spark source files and are accordingly subject to Spark's MIT
license in addition to this project's own license:

| This repo | Upstream Spark file |
| --- | --- |
| `Sources/SatinSpark/Pipelines/Splat/Shaders.metal` | `src/shaders/splatVertex.glsl`, `src/shaders/splatFragment.glsl`, `src/shaders/splatDefines.glsl` |
| `Sources/SatinSpark/PackedSplats.swift` (packed encoding/decoding helpers, `floatToUint8`, `encodeQuatOctXy88R8`, `lnScaleMin/lnScaleMax` convention) | `src/utils.ts`, `src/PackedSplats.ts` |
| `Sources/SatinSpark/SplatPLYLoader.swift` (sigmoid opacity, `SH_C0 * f_dc + 0.5` color decode, alpha-channel handling) | `src/ply.ts` |
| `Sources/SatinSpark/SplatReference.swift` (CPU mirror of the GPU projection pipeline) | derived from `splatVertex.glsl` math |
| `Sources/SatinSpark/SplatFixtures.swift` | original, but the `PackedSplat` shape mirrors Spark's `setSplat(...)` parameters |

Spark's MIT license text:

```
The MIT License

Copyright © 2025 WORLD LABS TECHNOLOGIES, INC.

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.
```

---

## Satin

- Source: https://github.com/Hi-Rez/Satin
- License: MIT
- Copyright (c) 2025 Hi-Rez

Used as a Swift Package dependency (renderer, materials, geometry, camera,
math utilities). Not vendored — pulled in via `Package.swift`.

Satin's MIT license is reproduced at the canonical location in the upstream
repository.
