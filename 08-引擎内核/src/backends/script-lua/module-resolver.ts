/**
 * L5 · 脚本模块解析：`require(name)` 的源码从哪儿来
 *
 * ★ 为什么需要这一层（批134 的起点是一次测量，不是设想）：
 *   把 `dstsrc` 顶层 218 个脚本按字母序全加载，**117 通过 / 101 失败**，
 *   失败绝大多数是同一句：`module 'class' not found` —— 因为 `actions.lua`
 *   排在 `class.lua` **前面**。DST 那边 `require` 是真的去 `scripts/` 里找文件的，
 *   而引擎这边只查 `package.loaded` / `package.preload`，且**没有任何 API**
 *   往 `package.preload` 里写（垫片文件头那句"唯一入口"是空头支票）。
 *
 *   所以这不是"垫片少一个函数"：**require 需要一张能解析模块名的表**，
 *   而"模块名 → 源码"这件事只有宿主知道（文件在哪、包里还是磁盘上）。
 *
 * ★★ 为什么回调是**同步**的（这不是偷懒，是 Lua 的语义边界）：
 *   `require` 在 Lua 里是同步调用，而 `IFileSystem.readText` 返回 Promise。
 *   想在 require 里 await，只能把整个 Lua 执行改成可中断的续体 —— 那是另一个引擎，
 *   不是这个后端能顺手做的事。所以：
 *     · 运行时只接受**同步**解析器（`LuaModuleResolver`）；
 *     · 异步宿主用 `collectModuleSources` 在**启动时一次性**把目录读成一张表
 *       （Lua 源码是几十 KB 量级，一次读完比每次 require 去问文件系统更省）。
 *   把这条差异写在类型上，而不是在运行时里偷偷 await（那会让 `require` 变成
 *   "有时同步有时异步"，而 Lua 侧完全看不出来）。
 *
 * ★ 失败要能分出三种，因为三种的处理完全不同：
 *   ① `not-found` —— 宿主里没有这个模块（拼错了 / 没打包进去）；
 *   ② `io`        —— 有这个东西但读不出来（权限、损坏、编码）；
 *   ③ 加载它时又缺别的模块 —— 这不是解析的失败，是**被加载模块的失败**，
 *      发生在 Lua 侧（`__engine_load` 的返回值里），两者不许合并成一句话。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";
import type { IReadableFileSystem } from "../../platform/fs/fs.ts";

/** 一次解析的结果。成功给源码，失败给**可分辨的**原因。 */
export type ModuleResolveOutcome =
  | {
      readonly ok: true;
      /** 模块源码（Lua 5.1 文本）。 */
      readonly source: string;
      /** 这份源码来自哪里（日志与报错用；相对路径即可）。 */
      readonly path: string;
    }
  | {
      readonly ok: false;
      /**
       * `not-found`：宿主里没有这个模块。
       * `io`：有，但读不出来。
       * ★ 不提供第三个 `"cycle"`：循环依赖是 Lua 侧在执行中发现的事实
       *   （解析器根本不知道谁在加载谁），硬塞进来只能是猜。
       */
      readonly reason: "not-found" | "io";
      readonly message: string;
    };

export type LuaModuleResolver = (name: string) => ModuleResolveOutcome;

/**
 * DST（以及 Lua 5.1 的 `package.path` 默认值）的找法，两种命名依次尝试：
 *   `<name>.lua` → `<name>/init.lua`
 * 模块名里的 `.` 在文件系统上是目录分隔符（`ai.brain` → `ai/brain`）。
 *
 * ★ 顺序是有意的：`ai/brain.lua` 与 `ai/brain/init.lua` 同时存在时，
 *   前者赢 —— 这也是标准 Lua `package.path` 的顺序，不是随便定的。
 */
export function candidatePaths(name: string): readonly [string, string] {
  const base = name.split(".").join("/");
  return [`${base}.lua`, `${base}/init.lua`];
}

/**
 * 把"路径 → 源码"的表变成一个同步解析器。路径是**相对**的（`cls.lua`、`ai/brain/init.lua`）。
 *
 * ★ 为什么不让调用方直接传 `Map<模块名, 源码>`：那样"两种命名"这条规则就跑到
 *   收集端去了，而收集端（`collectModuleSources`）根本不关心模块名怎么算 ——
 *   它只负责把文件读进来。规则留在这里，只有一处，也只需要一处判据。
 */
export function resolverFromSources(
  sources: ReadonlyMap<string, string>,
  options: { readonly missing?: string } = {},
): LuaModuleResolver {
  return (name: string): ModuleResolveOutcome => {
    for (const path of candidatePaths(name)) {
      const source = sources.get(path);
      if (source !== undefined) return { ok: true, source, path };
    }
    const where = options.missing === undefined ? "" : `（查找根：${options.missing}）`;
    return {
      ok: false,
      reason: "not-found",
      message: `没有 ${candidatePaths(name).join(" 也没有 ")}${where}`,
    };
  };
}

/**
 * 递归读一个目录里所有 `.lua` 文件，键是**相对路径**（用 `/`，不含根前缀）。
 *
 * ★ 只收 `.lua`：DST 的 `scripts/` 里还有 `.zip`（动画包）与 `.ktex`，
 *   把它们读成字符串再喂给 Lua，报错会变成"语法错误"，离根因很远。
 *
 * ★ 读不出来就**当场失败**，不跳过：静默跳过会让"少了一个模块"推迟到
 *   `module 'x' not found`，而那句话听起来像"没打包进去"，指向完全相反的方向。
 */
export async function collectModuleSources(
  fs: IReadableFileSystem,
  root: string,
): Promise<Result<ReadonlyMap<string, string>, EngineError>> {
  const out = new Map<string, string>();
  const walk = async (dir: string, prefix: string): Promise<EngineError | null> => {
    if (!fs.canList) {
      return engineError(
        "SCRIPT.MODULE_LIST_UNSUPPORTED",
        `这个文件系统不能列举目录（scheme=${fs.scheme}）—— 没法收集 Lua 模块：${root}`,
      );
    }
    const listed = await fs.list(dir);
    if (!listed.ok) return listed.error;
    // 名称排序：目录遍历顺序因文件系统而异，源码收集不该有"顺序随机"这回事
    const entries = [...listed.value].sort((a, b) => (a.name < b.name ? -1 : a.name > b.name ? 1 : 0));
    for (const ent of entries) {
      const rel = prefix === "" ? ent.name : `${prefix}/${ent.name}`;
      if (ent.isDirectory) {
        const bad = await walk(`${dir}/${ent.name}`, rel);
        if (bad !== null) return bad;
        continue;
      }
      if (!ent.name.endsWith(".lua")) continue;
      const read = await fs.readText(`${dir}/${ent.name}`);
      if (!read.ok) return read.error;
      out.set(rel, read.value);
    }
    return null;
  };

  const bad = await walk(root, "");
  return bad === null ? ok(out) : err(bad);
}
