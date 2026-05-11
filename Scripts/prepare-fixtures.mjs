#!/usr/bin/env node
import { mkdir, copyFile, rm, stat } from "node:fs/promises";
import { createWriteStream } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { pipeline } from "node:stream/promises";

const repoRoot = resolve(fileURLToPath(new URL("..", import.meta.url)));
const sparkRoot = resolve(process.env.SPARK_REPO ?? join(repoRoot, "..", "..", "js", "spark"));
const fixturesDir = resolve(repoRoot, "Tests", "SatinSparkTests", "Fixtures", "SparkAssets");
const tmpDir = resolve(process.env.SATIN_SPARK_FIXTURE_TMP ?? "/private/tmp");

const robotHeadURL = "https://sparkjs.dev/assets/splats/robot-head.spz";
const sutroURL = "https://sparkjs.dev/assets/splats/sutro.zip";
const gaussianSplats3DDataURL = "https://projects.markkellogg.org/downloads/gaussian_splat_data.zip";
const rawSplatURL = "https://media.reshot.ai/models/nike_next/model.splat";
const gaussianPlyURL = "https://huggingface.co/J0N45/Gaussian-Splats/resolve/d6a58cf8fd2f889dea24fdf8eb6604204c058968/point_cloud.ply";
const sourceSPZ = join(tmpDir, "satin-spark-robot-head.spz");
const sourceSOGZip = join(tmpDir, "satin-spark-sutro.zip");
const sourceKSPLATZip = join(tmpDir, "gaussian_splat_data.zip");
const sourceKSPLATEntry = "bonsai/bonsai_trimmed.ksplat";
const sourceKSPLAT = join(tmpDir, "satin-spark-bonsai-trimmed.ksplat");
const sourceRawSplat = join(tmpDir, "satin-spark-nike-next.splat");
const sourcePLY = join(tmpDir, "satin-spark-point-cloud.ply");
const inlineRAD = join(tmpDir, "satin-spark-robot-head-lod.rad");
const chunkedRAD = join(tmpDir, "satin-spark-robot-head-lod.rad");
const chunkedRADC = join(tmpDir, "satin-spark-robot-head-lod-0.radc");

await mkdir(fixturesDir, { recursive: true });
await download(robotHeadURL, sourceSPZ);
await download(sutroURL, sourceSOGZip);
await download(gaussianSplats3DDataURL, sourceKSPLATZip);
await download(rawSplatURL, sourceRawSplat);
await download(gaussianPlyURL, sourcePLY);
await extractZipEntry(sourceKSPLATZip, sourceKSPLATEntry, sourceKSPLAT);
await copyFile(sourceSPZ, join(fixturesDir, "robot-head.spz"));
await copyFile(sourceSOGZip, join(fixturesDir, "sutro.zip"));
await copyFile(sourceKSPLAT, join(fixturesDir, "bonsai-trimmed.ksplat"));
await copyFile(sourceRawSplat, join(fixturesDir, "nike-next.splat"));
await copyFile(sourcePLY, join(fixturesDir, "point-cloud.ply"));

await rm(inlineRAD, { force: true });
await runBuildLod(["--max-sh=0", "--quick"]);
await copyFile(inlineRAD, join(fixturesDir, "robot-head-lod.rad"));

await rm(chunkedRAD, { force: true });
await rm(chunkedRADC, { force: true });
await runBuildLod(["--max-sh=0", "--quick", "--rad-chunked"]);
await copyFile(chunkedRAD, join(fixturesDir, "satin-spark-robot-head-lod.rad"));
await copyFile(chunkedRADC, join(fixturesDir, "satin-spark-robot-head-lod-0.radc"));

console.log(`prepared Spark fixtures in ${fixturesDir}`);

async function download(url, outputPath) {
  try {
    const info = await stat(outputPath);
    if (info.size > 0) {
      console.log(`using cached ${outputPath}`);
      return;
    }
  } catch {
  }

  await mkdir(dirname(outputPath), { recursive: true });
  console.log(`downloading ${url}`);
  const response = await fetch(url);
  if (!response.ok || !response.body) {
    throw new Error(`download failed: ${response.status} ${response.statusText}`);
  }
  await pipeline(response.body, createWriteStream(outputPath));
}

async function runBuildLod(args) {
  const buildLodDir = join(sparkRoot, "rust", "build-lod");
  const command = ["run", "--release", "--", sourceSPZ, ...args];
  console.log(`cargo ${command.join(" ")}`);
  await run("/bin/zsh", ["-lc", ["cargo", ...command].map(shellQuote).join(" ")], buildLodDir);
}

async function run(command, args, cwd) {
  await new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, { cwd, stdio: "inherit" });
    child.on("error", reject);
    child.on("exit", (code) => {
      if (code === 0) {
        resolvePromise();
      } else {
        reject(new Error(`${command} exited with ${code}`));
      }
    });
  });
}

async function extractZipEntry(zipPath, entryName, outputPath) {
  await mkdir(dirname(outputPath), { recursive: true });
  console.log(`extracting ${entryName}`);
  await new Promise((resolvePromise, reject) => {
    const output = createWriteStream(outputPath);
    const child = spawn("unzip", ["-p", zipPath, entryName], { stdio: ["ignore", "pipe", "inherit"] });
    let exitCode = null;
    let outputFinished = false;
    let settled = false;
    const finish = () => {
      if (settled) return;
      if (exitCode === 0 && outputFinished) {
        settled = true;
        resolvePromise();
      } else if (exitCode !== null && exitCode !== 0) {
        settled = true;
        reject(new Error(`unzip exited with ${exitCode}`));
      }
    };
    child.stdout.pipe(output);
    child.on("error", reject);
    child.on("exit", (code) => {
      exitCode = code;
      finish();
    });
    output.on("error", reject);
    output.on("finish", () => {
      outputFinished = true;
      finish();
    });
  });
}

function shellQuote(value) {
  return `'${String(value).replaceAll("'", "'\\''")}'`;
}
