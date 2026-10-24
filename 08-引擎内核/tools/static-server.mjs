/**
 * 极简静态服务器（只为本地验证浏览器宿主）。
 *
 * ★ 不引入 express 之类的依赖：验证用的服务器越简单，越不会成为"跑不起来"的原因。
 *   生产部署是另一件事（`web/` 是纯静态目录，任何静态服务器都能托管）。
 *
 * ★ 为什么是模块而不是一段 `listen`：`tools/serve.mjs`（人工看页面）与
 *   `tools/browser-selftest.mjs`（自动跑判据）必须是**同一份**服务逻辑。
 *   抄两遍的后果是"人工打开正常、自动跑 404"，而这类差异极难自查。
 */

import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

// ★ 必须用 fileURLToPath：`.pathname` 在 Windows 上给的是 `/E:/...`（正斜杠 + 前导斜杠），
// 与 `join()` 产出的反斜杠路径对不上，`startsWith(ROOT)` 会永远失败 ⇒ 403。
export const WEB_ROOT = fileURLToPath(new URL("../web/", import.meta.url));

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".css": "text/css; charset=utf-8",
  // ★ 必须给 wasm 正确的 MIME：`WebAssembly.instantiateStreaming` 要求
  //   `application/wasm`，否则会先失败再回退到 ArrayBuffer 实例化
  //   （能跑，但多一次请求 + 控制台警告，容易被误判成"加载失败"）。
  ".wasm": "application/wasm",
};

/**
 * 起服务。`port: 0` 表示由系统分配（自动判据用它，避免与人工开的 8123 撞车）。
 * 返回真实地址，调用方负责 `close()`。
 */
export async function startStaticServer({ port = 8123, root = WEB_ROOT } = {}) {
  const server = createServer(async (req, res) => {
    const url = new URL(req.url ?? "/", "http://x");
    let p = decodeURIComponent(url.pathname);
    if (p === "/") p = "/index.html";
    // 目录穿越防护：normalize 后必须以 web/ 为根
    const target = join(root, normalize(p).replace(/^(\.\.[/\\])+/, ""));
    if (!target.startsWith(root)) {
      res.writeHead(403).end("forbidden");
      return;
    }
    try {
      const body = await readFile(target);
      res.writeHead(200, {
        "Content-Type": MIME[extname(target)] ?? "application/octet-stream",
        "Cache-Control": "no-store",
      });
      res.end(body);
    } catch {
      res.writeHead(404).end("not found: " + p);
    }
  });

  await new Promise((resolve, reject) => {
    server.once("error", reject);
    server.listen(port, "127.0.0.1", resolve);
  });
  const addr = server.address();
  const actual = typeof addr === "object" && addr !== null ? addr.port : port;
  return {
    port: actual,
    origin: `http://127.0.0.1:${actual}`,
    close: () => new Promise((resolve) => server.close(() => resolve())),
  };
}
