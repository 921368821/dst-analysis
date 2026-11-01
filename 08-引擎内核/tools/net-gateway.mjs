#!/usr/bin/env node
/**
 * 联机网关的命令行入口（实现全在 `src/extensions/net/gateway.ts`）
 *
 * ★ 为什么要这一层：网关的核心逻辑必须被 `npm run typecheck` 覆盖、也必须能被
 *   Node 判据直接 import（`tests/host/net-gateway.test.ts`）。`.mjs` 没有声明文件，
 *   tsc 会报 TS7016；而把这个文件改成 `.ts` 会让"起网关"这件事绑上类型剥离开关。
 *   于是分成两层：**逻辑在 src，参数解析在这里**。
 *
 * 用法：
 *   node tools/net-gateway.mjs                       # 8787 端口，随机主机口令
 *   node tools/net-gateway.mjs --port 9000 --host-token mysecret
 *   node tools/net-gateway.mjs --max-clients 4 --host 0.0.0.0
 */

import { startGateway } from "../src/extensions/net/gateway.ts";

const args = process.argv.slice(2);
const flag = (name, dflt) => {
  const i = args.indexOf(name);
  return i >= 0 && args[i + 1] !== undefined ? args[i + 1] : dflt;
};

const gw = await startGateway({
  port: Number(flag("--port", "8787")),
  hostToken: flag("--host-token", undefined),
  // ★ 缺省听 `0.0.0.0`（CLI 的用途是"别人能连进来"），而**判据**缺省听 127.0.0.1
  //   —— 两者缺省不同是刻意的：CI 机器上弹一次防火墙提示，比"局域网连不上"更难查。
  host: flag("--host", "0.0.0.0"),
  maxClients: Number(flag("--max-clients", "8")),
  pingMs: 30000,
});

// ★ `--page` 而不是拿网关端口拼：网关**不供静态文件**（它只做 101 升级与转发），
//   页面上那句 `http://localhost:<网关端口>/index.html` 打开的是网关自己的状态文本，
//   而"照着提示点开却是一个纯文本页"是这类工具最常见的第一次踩坑。
//   页面由 `npm run serve:web`（8123）提供，两者是**两个**服务，端口不同。
const page = flag("--page", "http://localhost:8123/index.html");
const ws = `ws://localhost:${String(gw.port)}`;
console.log(`[gw] 主机打开：  ${page}?net=host&wire=ws&url=${ws}&token=${gw.hostToken}`);
console.log(`[gw] 客户端打开：${page}?net=client&wire=ws&url=${ws}`);
console.log("[gw] 静态页面由 `npm run serve:web`（8123）提供 —— 跨机器时把 localhost 换成这台机器的地址。");

const shutdown = () => {
  void gw.close().then(() => {
    process.exit(0);
  });
};
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
