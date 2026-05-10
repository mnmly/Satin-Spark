import { createReadStream, statSync } from "node:fs";
import { createServer } from "node:http";
import { extname, join, normalize, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = resolve(fileURLToPath(new URL("..", import.meta.url)));
const sparkRoot = resolve("/Users/mnmly/Development-local/GitHub/js/spark");
const bananaPath = resolve("/Users/mnmly/Development-local/Personal/SketchSceneKit copy/TestAssets/banana_100.ply");
const packedBananaPath = resolve(process.env.SATIN_SPARK_PACKED_BANANA ?? "/tmp/banana-packed.bin");
const packedFixturePath = resolve(process.env.SATIN_SPARK_PACKED_FIXTURE ?? "/tmp/fixture-packed.bin");
const port = Number(process.env.SATIN_SPARK_VISUAL_PORT ?? 5179);

const contentTypes = new Map([
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".mjs", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".wasm", "application/wasm"],
  [".ply", "application/octet-stream"],
  [".map", "application/json; charset=utf-8"],
]);

const server = createServer((request, response) => {
  try {
    const url = new URL(request.url ?? "/", `http://${request.headers.host ?? "127.0.0.1"}`);
    let path;
    if (url.pathname === "/" || url.pathname === "/fixture.html") {
      path = join(root, "Scripts", "spark-visual-fixture.html");
    } else if (url.pathname === "/banana.ply") {
      path = bananaPath;
    } else if (url.pathname === "/banana-packed.bin") {
      path = packedBananaPath;
    } else if (url.pathname === "/fixture-packed.bin") {
      path = packedFixturePath;
    } else if (url.pathname.startsWith("/spark/")) {
      path = resolve(sparkRoot, `.${url.pathname.slice("/spark".length)}`);
      if (!path.startsWith(`${sparkRoot}/`)) {
        throw Object.assign(new Error("Forbidden"), { statusCode: 403 });
      }
    } else {
      path = resolve(root, `.${normalize(url.pathname)}`);
      if (!path.startsWith(`${root}/`)) {
        throw Object.assign(new Error("Forbidden"), { statusCode: 403 });
      }
    }

    const stats = statSync(path);
    if (!stats.isFile()) {
      throw Object.assign(new Error("Not found"), { statusCode: 404 });
    }

    console.log(`${request.method} ${url.pathname} -> ${path}`);
    response.writeHead(200, {
      "Content-Type": contentTypes.get(extname(path)) ?? "application/octet-stream",
      "Content-Length": String(stats.size),
      "Cache-Control": "no-store",
      "Access-Control-Allow-Origin": "*",
    });
    createReadStream(path).pipe(response);
  } catch (error) {
    const statusCode = error.statusCode ?? 404;
    response.writeHead(statusCode, { "Content-Type": "text/plain; charset=utf-8" });
    response.end(`${statusCode} ${error.message ?? "Not found"}\n`);
  }
});

server.listen(port, "127.0.0.1", () => {
  console.log(`spark visual fixture: http://127.0.0.1:${port}/fixture.html`);
});
