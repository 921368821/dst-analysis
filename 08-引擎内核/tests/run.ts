/**
 * 全部测试入口
 *
 * ★ 从"显式 import 清单"改成**目录自动发现**（2026-10-22 阶段 2）。
 *   原因很实际：清单模式在**并行开发**下必然冲突 —— 两条线同时新增测试文件，
 *   都要改这一个文件，合并时互相踩。而它原本的好处（"新增测试必须登记，
 *   否则不会静默漏跑"）可以用更强的形式拿到：
 *     ① 递归发现 `tests/**\/*.test.ts`（含子目录，无需登记）；
 *     ② 发现数为 0 或低于下限 ⇒ 直接抛（防止路径写错导致"跑了个寂寞"）；
 *     ③ 启动时打印清单 —— 少了一个文件是**可见**的，不是静默的。
 *   这比人工清单更难出错：人工清单的失败模式是"加了文件忘了登记"，
 *   自动发现的失败模式是"文件没放在 tests/ 下"（而这本身就是错的）。
 *
 * 约定：文件名必须以 `.test.ts` 结尾；`tests/run.ts` 自身除外；
 * `contract/*.contract.ts` 是被测试文件 import 的可复用契约，不会被单独发现执行。
 */

import { readdirSync } from "node:fs";
import { join, relative } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const TESTS_ROOT = fileURLToPath(new URL("./", import.meta.url));

/** 低于这个数说明发现逻辑坏了（阶段 1 结束时是 11 个，留余量）。 */
const MIN_EXPECTED = 16;

function discover(dir: string): string[] {
  const out: string[] = [];
  for (const ent of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, ent.name);
    if (ent.isDirectory()) {
      out.push(...discover(p));
    } else if (ent.name.endsWith(".test.ts") && ent.name !== "run.ts") {
      out.push(p);
    }
  }
  return out;
}

const files = discover(TESTS_ROOT).sort();
if (files.length < MIN_EXPECTED) {
  throw new Error(
    `只发现 ${files.length} 个测试文件（期望 ≥ ${MIN_EXPECTED}）—— 发现逻辑或目录结构坏了，拒绝"跑了个寂寞"`,
  );
}

console.log(`[tests] 发现 ${files.length} 个测试文件：`);
for (const f of files) console.log(`  - ${relative(TESTS_ROOT, f)}`);

// 顺序导入：先 arch（依赖方向）再其余 —— arch 挂了就没必要看后面的细节
for (const f of files) {
  await import(pathToFileURL(f).href);
}
