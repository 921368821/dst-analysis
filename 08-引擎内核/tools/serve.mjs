/**
 * 极简静态服务器（只为本地验证浏览器宿主）。
 * ★ 不引入 express 之类的依赖：验证用的服务器越简单，越不会成为"跑不起来"的原因。
 *   生产部署是另一件事（`web/` 是纯静态目录，任何静态服务器都能托管）。
 */
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { extname, join, normalize } from "node:path";
import { fileURLToPath } from "node:url";

// ★ 必须用 fileURLToPath：`.pathname` 在 Windows 上给的是 `/E:/...`（正斜杠 + 前导斜杠），
// 与 `join()` 产出的反斜杠路径对不上，`startsWith(ROOT)` 会永远失败 ⇒ 403。
const ROOT = fileURLToPath(new URL("../web/", import.meta.url));
const PORT = Number(process.argv[2] ?? 8123);
const MIME = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".css": "text/css; charset=utf-8",
};

createServer(async (req, res) => {
  const url = new URL(req.url ?? "/", "http://x");
  let p = decodeURIComponent(url.pathname);
  if (p === "/") p = "/index.html";
  // 目录穿越防护：normalize 后必须以 web/ 为根
  const target = join(ROOT, normalize(p).replace(/^(\.\.[/\\])+/, ""));
  if (!target.startsWith(ROOT)) {
    res.writeHead(403).end("forbidden");
    return;
  }
  try {
    const body = await readFile(target);
    res.writeHead(200, { "Content-Type": MIME[extname(target)] ?? "application/octet-stream", "Cache-Control": "no-store" });
    res.end(body);
  } catch {
    res.writeHead(404).end("not found: " + p);
  }
}).listen(PORT, "127.0.0.1", () => {
  console.log(`serving ${ROOT} on http://127.0.0.1:${PORT}/`);
  console.log(`  演示: http://127.0.0.1:${PORT}/index.html`);
  console.log(`  自检: http://127.0.0.1:${PORT}/selftest.html`);
});
