# Spark Asset Fixtures

These local fixtures are generated from upstream example assets:

- Spark SPZ/RAD source: `https://sparkjs.dev/assets/splats/robot-head.spz`
- Spark SOG ZIP source: `https://sparkjs.dev/assets/splats/sutro.zip`
- Spark source repository reference: `/Users/mnmly/Development-local/GitHub/js/spark/examples/assets.json`
- generator: Spark's Rust `build-lod` tool from `/Users/mnmly/Development-local/GitHub/js/spark/rust/build-lod`
- GaussianSplats3D KSPLAT source bundle:
  `https://projects.markkellogg.org/downloads/gaussian_splat_data.zip`
- GaussianSplats3D source repository reference:
  `demo/bonsai.html` references `assets/data/bonsai/bonsai_trimmed.ksplat`
- raw `.splat` source cited by the original `antimatter15/splat` README:
  `https://media.reshot.ai/models/nike_next/model.splat`
- hosted Gaussian splat PLY source:
  `https://huggingface.co/J0N45/Gaussian-Splats/resolve/d6a58cf8fd2f889dea24fdf8eb6604204c058968/point_cloud.ply`
- command from this repo:

```sh
node Scripts/prepare-fixtures.mjs
```

The command regenerates:

- `robot-head.spz`: Spark hosted SPZ example.
- `sutro.zip`: Spark hosted bundled SOG/PC-SOGS example.
- `bonsai-trimmed.ksplat`: GaussianSplats3D demo KSPLAT extracted from the
  published data bundle.
- `nike-next.splat`: raw `.splat` example linked from the original
  `antimatter15/splat` README.
- `point-cloud.ply`: hosted Gaussian splat PLY example.
- `robot-head-lod.rad`: inline RAD.
- `satin-spark-robot-head-lod.rad` + `satin-spark-robot-head-lod-0.radc`:
  sidecar RAD/RADC.

The generated binary fixtures are ignored by git. Run the command before
fixture-backed tests or local loader benchmarking.
