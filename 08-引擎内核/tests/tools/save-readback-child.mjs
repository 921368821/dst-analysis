/**
 * 在**全新进程**里读一份存档、再存一遍，并把它算成 sha256。
 *
 * 只用于判据（`tests/backends/fs-node.test.ts` 的子进程读档），不参与构建。
 * 之所以要另起进程：同一个进程内的"存→读→再存相同"证明不了**进程重启后还能读**，
 * 而"存档活过重启"正是 `fs-node` 存在的唯一理由。
 *
 * 用法：node --experimental-transform-types save-readback-child.mjs <存档路径> <scene-io 的 file:// URL>
 */

import { readFileSync } from "node:fs";
import { createHash } from "node:crypto";

const [savePath, ioUrl] = process.argv.slice(2);
if (savePath === undefined || ioUrl === undefined) {
  console.log(JSON.stringify({ ok: false, error: "缺参数" }));
  process.exit(2);
}

const io = await import(ioUrl);
const text = readFileSync(savePath, "utf8");
const parsed = io.sceneFromJson(text);
const sha = (s) => createHash("sha256").update(s).digest("hex");

if (!parsed.ok) {
  console.log(JSON.stringify({ ok: false, error: parsed.error.code, message: parsed.error.message }));
  process.exit(0);
}
const again = io.sceneToJson(parsed.value);
console.log(
  JSON.stringify({
    ok: true,
    pid: process.pid,
    nodes: parsed.value.nodes.length,
    version: parsed.value.version,
    sameBytes: again === text,
    shaOnDisk: sha(text),
    shaAgain: sha(again),
  }),
);
