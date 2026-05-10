import { writeFile } from "node:fs/promises";

const output = process.argv[2] ?? "/tmp/spark-banana-visible.png";
const endpoint = process.env.SATIN_SPARK_CHROME_ENDPOINT ?? "http://127.0.0.1:9222";
const targetURL = process.env.SATIN_SPARK_VISUAL_URL ?? "http://127.0.0.1:5179/fixture.html";

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function getTarget() {
  const response = await fetch(`${endpoint}/json/list`);
  if (!response.ok) {
    throw new Error(`DevTools target list failed: ${response.status}`);
  }
  const targets = await response.json();
  return targets.find((target) => target.url === targetURL) ?? targets.find((target) => target.type === "page");
}

async function connect(target) {
  const socket = new WebSocket(target.webSocketDebuggerUrl);
  await new Promise((resolve, reject) => {
    socket.addEventListener("open", resolve, { once: true });
    socket.addEventListener("error", reject, { once: true });
  });

  let nextID = 1;
  const pending = new Map();
  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data);
    if (!message.id) {
      if (message.method === "Runtime.consoleAPICalled") {
        const args = (message.params.args ?? []).map((arg) => {
          if (arg.type === "string") return arg.value;
          if ("value" in arg) return JSON.stringify(arg.value);
          if (arg.preview) return JSON.stringify(arg.preview, null, 0);
          return arg.description ?? arg.type;
        });
        process.stderr.write(`[chrome:${message.params.type}] ${args.join(" ")}\n`);
      } else if (message.method === "Runtime.exceptionThrown") {
        const ex = message.params.exceptionDetails;
        process.stderr.write(`[chrome:exception] ${ex.text} ${ex.exception?.description ?? ""}\n`);
      } else if (message.method === "Log.entryAdded") {
        const entry = message.params.entry;
        process.stderr.write(`[chrome:log:${entry.level}] ${entry.text}\n`);
      }
      return;
    }
    const resolver = pending.get(message.id);
    if (!resolver) {
      return;
    }
    pending.delete(message.id);
    if (message.error) {
      resolver.reject(new Error(message.error.message));
    } else {
      resolver.resolve(message.result);
    }
  });

  return {
    call(method, params = {}) {
      const id = nextID++;
      socket.send(JSON.stringify({ id, method, params }));
      return new Promise((resolve, reject) => {
        pending.set(id, { resolve, reject });
      });
    },
    close() {
      socket.close();
    },
  };
}

for (let attempt = 0; attempt < 80; ++attempt) {
  try {
    const target = await getTarget();
    if (target) {
      const cdp = await connect(target);
      await cdp.call("Page.enable");
      await cdp.call("Runtime.enable");
      await cdp.call("Log.enable");
      await cdp.call("Page.bringToFront");
      await cdp.call("Page.navigate", { url: targetURL });

      for (let i = 0; i < 120; ++i) {
        const result = await cdp.call("Runtime.evaluate", {
          expression: "({ ready: document.documentElement.dataset.ready, loaded: document.documentElement.dataset.loaded, error: document.documentElement.dataset.error })",
          returnByValue: true,
        });
        const value = result.result.value;
        if (value?.error) {
          throw new Error(value.error);
        }
        if (value?.ready === "1") {
          break;
        }
        await sleep(100);
      }

      await cdp.call("Runtime.evaluate", {
        expression: "window.scrollTo(0, 0); document.body.style.margin = '0';",
      });
      await sleep(200);
      // Grab the WebGL canvas content directly via toDataURL — works because
      // the renderer was created with preserveDrawingBuffer: true. Page.captureScreenshot
      // composites through Chrome's surface and can miss canvas content.
      const dataURL = await cdp.call("Runtime.evaluate", {
        expression: "document.getElementById('fixture').toDataURL('image/png')",
        returnByValue: true,
      });
      const value = dataURL.result?.value;
      if (typeof value !== "string" || !value.startsWith("data:image/png;base64,")) {
        throw new Error(`canvas toDataURL did not return a PNG (got ${typeof value})`);
      }
      const base64 = value.slice("data:image/png;base64,".length);
      await writeFile(output, Buffer.from(base64, "base64"));
      console.log(`wrote ${output}`);
      cdp.close();
      process.exit(0);
    }
  } catch (error) {
    if (attempt === 79) {
      throw error;
    }
  }
  await sleep(250);
}

throw new Error("No Chrome page target became available");
