/**
 * 宿主级判据：`npm run sample:headless` 真的把存档写到了该去的地方。
 *
 * ★ 为什么要跑子进程而不是直接调函数：
 *   README 里的"实测输出"是一段**声明**。声明会腐烂（改代码忘了改文档），
 *   而这里有一条判据在跑同一条命令 —— 输出里的关键承诺（存→读→再存相同、
 *   落在 node: 还是 mem:）从此是**被验证过的**，不是被抄写过的。
 *
 * ★ 为什么还要断言"不给 --save-dir 时不往工作区写文件"：
 *   一个默认就往仓库里写 saves/ 的宿主，会让每个人的工作区在跑完判据后变脏，
 *   然后被 .gitignore 掩盖，然后没人再注意。默认必须是无副作用的。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

import { sceneFromJson, sceneToJson } from "../../src/core/scene/scene-io.ts";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..", "..");

function runSample(args: readonly string[]): { status: number | null; out: string } {
  const r = spawnSync(
    process.execPath,
    ["--experimental-transform-types", join(ROOT, "samples", "headless.ts"), ...args],
    { cwd: ROOT, encoding: "utf8", timeout: 120_000 },
  );
  return { status: r.status, out: `${r.stdout ?? ""}\n${r.stderr ?? ""}` };
}

test("宿主：--save-dir 落真实盘，存档能被重新解析且再存逐字节相同", () => {
  const dir = mkdtempSync(join(tmpdir(), "headless-save-"));
  try {
    const r = runSample(["--save-dir", dir]);
    assert.equal(r.status, 0, `宿主退出码 ${r.status}：\n${r.out.slice(-800)}`);
    assert.match(r.out, /where: 'node:\/saves\/slot1\.json'/, "没有走真实盘后端");

    const file = join(dir, "saves", "slot1.json");
    assert.equal(existsSync(file), true, `盘上没有存档：${file}`);
    const text = readFileSync(file, "utf8");
    const parsed = sceneFromJson(text);
    assert.equal(parsed.ok, true, parsed.ok ? "" : `解析失败：${parsed.error.code} ${parsed.error.message}`);
    if (!parsed.ok) return;
    assert.equal(sceneToJson(parsed.value), text, "盘上的存档不是规范形式（再存就变了）");
    assert.equal(parsed.value.nodes.length, 5);
    // 宿主自己也报告了"再次存相同"（对象键被 JSON 打印成 '再次存相同'）
    assert.match(r.out, /再次存相同': true/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("宿主：不给 --save-dir 时用内存盘，且**不往工作区写文件**", () => {
  const before = existsSync(join(ROOT, "saves"));
  const r = runSample([]);
  assert.equal(r.status, 0, `宿主退出码 ${r.status}：\n${r.out.slice(-800)}`);
  assert.match(r.out, /where: 'mem:\/saves\/slot1\.json'/, "默认没有用内存盘");
  assert.equal(
    existsSync(join(ROOT, "saves")),
    before,
    "宿主在仓库根目录建了 saves/ —— 默认行为必须无副作用",
  );
});

// ------------------------------------------------------------------ README 的实测输出
//
// ★ T119（已登记软点）：README 里那段"实测输出"含 `bytes: 923` 与 `sha256: '606b2492…'`，
//   这两个数是**硬抄**的。存档格式一改，它们会静默过期 —— 而"文档说 923 字节"正是
//   读者用来判断"我的存档是不是正常"的依据。
//   ​做法不是把数字再抄一遍到断言里（那只是把漂移点从一个文件搬到另一个文件），
//   而是**把 README 当被测对象**：从 README 里读出数字，与现在真跑出来的比。

/** 把空白（含换行）压成单空格：排版差异不是内容差异。 */
function squash(s: string): string {
  return s.replace(/\s+/g, " ").trim();
}

function sampleHomeBlock(): { line: string; at: number } | null {
  const readme = readFileSync(join(ROOT, "README.md"), "utf8");
  const idx = readme.indexOf("`npm run sample:headless` 的输出（实测");
  if (idx < 0) return null;
  const start = readme.indexOf("```", idx);
  if (start < 0) return null;
  const end = readme.indexOf("```", start + 3);
  if (end < 0) return null;
  return { line: readme.slice(start + 3, end), at: idx };
}

test("README 的实测输出块：存档字节数与 sha256 必须等于现在跑出来的", () => {
  const block = sampleHomeBlock();
  assert.ok(block !== null, "README 里找不到 `npm run sample:headless 的输出（实测` 那段代码块");
  const documented = /bytes: (\d+), sha256: '([0-9a-f]{8,})'/.exec(squash(block!.line));
  assert.ok(documented !== null, "README 的存档行里读不到 bytes/sha256 —— 行被改过了？");

  const r = runSample([]);
  assert.equal(r.status, 0, `宿主退出码 ${r.status}：\n${r.out.slice(-800)}`);
  // ★ 归一化后再匹配：`util.inspect` 在单行放不下时会换行，
  //   "同一份数据、两种排版"不该被判成文档漂移（否则换 Node 版本就假红一次）。
  const live = /bytes: (\d+), sha256: '([0-9a-f]{8,})'/.exec(squash(r.out));
  assert.ok(live !== null, "宿主输出里没有存档行");

  assert.equal(
    documented![1],
    live![1],
    "README 的存档字节数过期（存档格式变了就去更新 README，别改判据）",
  );
  assert.equal(
    documented![2],
    live![2],
    "README 的存档 sha256 过期（存档格式变了就去更新 README，别改判据）",
  );
});

test("README 的实测输出块：每一行都必须能在真实输出里找到（防止整块腐烂）", () => {
  const block = sampleHomeBlock();
  assert.ok(block !== null);
  const r = runSample([]);
  assert.equal(r.status, 0);
  const live = squash(r.out);
  const missing = block!.line
    .split(/\r?\n/)
    .map((l) => squash(l))
    .filter((l) => l !== "")
    .filter((l) => !live.includes(l));
  assert.deepEqual(
    missing,
    [],
    `README 里有 ${missing.length} 行在真实输出里找不到（文档比代码旧）：\n${missing.join("\n")}`,
  );
});
