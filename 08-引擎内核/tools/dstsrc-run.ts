/**
 * 「按某种口径把一份 Lua 语料全量加载一遍」—— **测量仪器本身**。
 *
 * ★ 为什么从 `dstsrc-sweep.ts` 里拆出来（批138）：批136/137 的结论（「哪 18 个名字是
 *   顺序造成的假缺口」「`bit` 一给就 164 → 165」）全部由这段逻辑产出，而它原来只
 *   跑在 `dstsrc` 上 —— 那份素材**未入库**，于是 CI 里永远只有"跳过"，而跳过与通过
 *   长得一模一样（批130 的教训，这是它第三次以新形式出现）。
 *
 *   一个**承载结论**的仪器没有判据，等于结论没有判据：探针装错了模块名、顺序没应用到
 *   加载循环、解析器忘记传……每一样都会让"缺什么"的清单悄悄变样，而报告依旧全绿。
 *   拆出来之后，`tests/tools/dstsrc-sweep.test.ts` 用**合成的迷你语料**（MemoryFileSystem）
 *   直接打这段逻辑，不依赖任何素材。
 *
 * ★ 逐字保留的三条纪律（都是踩过的）：
 *   ① 顺序必须真的变成**加载顺序**（不是"算出来打印一下"）；
 *   ② 探针必须用 `rawget` —— strict 档的 `_G.__index` 会对未声明的名字直接 `error`，
 *      用 `_G[name]` 探测会把"没有这个全局"变成"探针自己炸了"；
 *   ③ 探的是**跑完之后**的 `_G`：同一次运行里"读到它时还没轮到"与"谁都没给过它"
 *      在报错上完全一样，只有跑完再问一次才分得开。
 */

import { engineError, err, ok, type EngineError, type Result } from "../src/foundation/result.ts";
import { LuaScriptRuntime } from "../src/backends/script-lua/runtime.ts";
import { ScriptErrorCode } from "../src/platform/script/runtime.ts";
import {
  collectModuleSources,
  resolverFromSources,
} from "../src/backends/script-lua/module-resolver.ts";
import type { IReadableFileSystem } from "../src/platform/fs/fs.ts";
import { orderScripts, summarizeFailures } from "./dstsrc-report.mjs";

export interface SweepPassOptions {
  /** 语料根：`readText(相对路径)` 就从这里读。 */
  readonly fs: IReadableFileSystem;
  /** 顶层脚本名（**顺序无关**，实际加载顺序由 `order` 决定）。 */
  readonly files: readonly string[];
  /** 加载顺序预设（`dstsrc-report.mjs` 的 `ORDER_PRESETS` 的键）。默认 `alpha`。 */
  readonly order?: string;
  /** 装不装模块解析器（`require` 的第三站）。默认 `false`。 */
  readonly resolve?: boolean;
  /**
   * 已收集的模块源码（可以多档复用同一份快照）。
   * 不给就现场 `collectModuleSources(fs, "")` —— 注意每档重收集会读到"当下的盘"，
   * 多档对比时应当由调用方收集一次再传进来，否则两档量的可能不是同一份语料。
   */
  readonly modules?: ReadonlyMap<string, string>;
}

export interface SweepPassResult {
  /** 实际加载顺序（`orderScripts` 的结果）。判据靠它确认"预设真的生效了"。 */
  readonly order: readonly string[];
  readonly ok: number;
  readonly fail: ReadonlyArray<readonly [string, string]>;
  /** 跑完之后对每个"曾被报缺"的全局的探测：`type()` 的结果，`"nil"` = 谁都没给过它。 */
  readonly probed: ReadonlyMap<string, string>;
}

/** 探针模块名：与语料里的模块名可能撞车，所以撞了就让位。 */
function pickProbeModuleName(rt: LuaScriptRuntime): string {
  let name = "__sweep_probe";
  for (let i = 2; rt.hasModule(name); i++) name = `__sweep_probe_${i}`;
  return name;
}

export async function runSweepPass(
  options: SweepPassOptions,
): Promise<Result<SweepPassResult, EngineError>> {
  const files = Array.isArray(options.files) ? options.files : [];
  const order = options.order ?? "alpha";
  const resolve = options.resolve === true;

  // 未知预设让 `orderScripts` 抛 —— 在这里转成 `Result`，免得一个笔误把整轮变成崩溃。
  let plan: string[];
  try {
    plan = orderScripts(files, order);
  } catch (e) {
    return err(
      engineError(
        ScriptErrorCode.BadValue,
        `加载顺序预设不可用：${e instanceof Error ? e.message : String(e)}`,
      ),
    );
  }

  let modules = options.modules;
  if (modules === undefined) {
    if (!resolve) {
      modules = new Map();
    } else {
      const collected = await collectModuleSources(options.fs, "");
      if (!collected.ok) return err(collected.error);
      modules = collected.value;
    }
  }

  const rt = new LuaScriptRuntime(
    resolve
      ? { sharedModuleEnv: true, resolveModule: resolverFromSources(modules) }
      : { sharedModuleEnv: true },
  );
  try {
    const ready = await rt.ready();
    if (!ready.ok) return err(ready.error);

    let okCount = 0;
    const fail: Array<readonly [string, string]> = [];
    for (const name of plan) {
      const read = await options.fs.readText(name);
      if (!read.ok) return err(read.error);
      // 与 CLI 一致：模块名去掉 `.lua` 后缀（`ai/brain.lua` → `ai/brain`）。
      const r = await rt.loadModule(name.replace(/\.lua$/, ""), read.value);
      if (r.ok) okCount++;
      else fail.push([name, r.error.message]);
    }

    // 跑完再问一次 `_G`：这是把「缺」劈成两半的那一刀。
    const probed = new Map<string, string>();
    const names = summarizeFailures(fail).missingGlobals.map((g) => g.name);
    if (names.length > 0) {
      const probeName = pickProbeModuleName(rt);
      const probe = await rt.loadModule(
        probeName,
        "function __sweep_probe_global(name)\n return type(rawget(_G, tostring(name)))\nend",
      );
      if (!probe.ok) return err(probe.error);
      for (const n of names) {
        const r = await rt.call("__sweep_probe_global", [n]);
        probed.set(n, r.ok ? String(r.value) : `?(调用失败 ${r.error.message})`);
      }
    }

    return ok({ order: plan, ok: okCount, fail, probed });
  } finally {
    rt.dispose();
  }
}
