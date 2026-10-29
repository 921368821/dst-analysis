/**
 * `dstsrc` 全量加载失败的**归类**（纯函数，判据可直接打）。
 *
 * ★ 为什么单独一个文件：`tools/dstsrc-sweep.ts` 只是"跑一遍、打印"，
 *   而"每条失败到底缺什么"是**可判定的逻辑**，必须能用合成语料逐条打红。
 *   把归类写进 sweep 的话，CI 里没有 `dstsrc`（未入库）⇒ 永远只有人肉结论，
 *   而下一次有人改一句正则，没人会发现（这正是批130 记下的那个教训）。
 *
 * ★ 分类不是"好看"，是为了**决定下一刀做什么**（C27）：
 *   修 C26 之后剩下 54 条 / 218 条，如果它们全是"缺 DST 引擎全局"，
 *   那下一步就是"提供 API 面"；如果里面还有"文件根本不在 dstsrc"，
 *   那部分就不是引擎的活。混在一起看，只能得出"还有 54 条"这种没用的结论。
 *
 * 六个形状：
 *   `missing-module`        —— 解析器找不到文件（宿主里就没有这个模块）
 *   `missing-global-table`  —— 把某个全局**当表用**（`TheItems.x`），而它不存在
 *   `missing-global-value`  —— 把某个全局**当函数/值用**（`IsConsole(...)`），而它不存在
 *   `missing-global-strict` —— DST 的 `strict.lua` 另一种说法：`variable 'X' is not declared`
 *   `script-local-nil`      —— **局部**变量是 nil（脚本自己的逻辑问题，**不该**算进"缺全局"）
 *   `other`                 —— 其余，原文留样
 *
 * ★ `script-local-nil` 必须单独一类：把它算进"缺全局"会得出
 *   "引擎该提供 `v`"这种荒唐结论（`v` 是某个函数返回值）。
 */

/** 失败的形状。 */
export const SHAPES = [
  "missing-module",
  "missing-global-table",
  "missing-global-value",
  "missing-global-strict",
  "script-local-nil",
  "other",
];

/**
 * 取**最内层**那句：`模块 A 加载失败：A:12: …（源：x.lua）：y:5: 真正的原因` → `真正的原因`。
 *
 * 为什么必须取最内层：外层那句只说明"谁把它拖下水了"，形状判定要看最里面。
 * 上一层拿这个做归类时长这样 —— 54 条各成一类（因为每条都带着自己的模块名），
 * 等于没归类。
 */
export function innerMessage(message) {
  const line = String(message ?? "").split("\n")[0];
  let tail = line;
  for (const sep of ["）：", "加载失败："]) {
    const at = tail.lastIndexOf(sep);
    if (at >= 0) tail = tail.slice(at + sep.length);
  }
  // 去掉 `file:行号: ` / `module:行号: ` 前缀（模块名里不会有空格，行号一定是数字）
  return tail.replace(/^\s*[^\s:]+:\d+:\s*/, "").trim();
}

/**
 * 判一条失败属于哪个形状。
 *
 * @param message 运行时给的原文（可以带换行，只看第一行）
 * @returns `{ shape, name }`：`name` 是"缺的那个东西"的名字（`missing-module` 是模块名，
 *          `missing-global-*` 是全局名，`script-local-nil` 是局部名，`other` 为空串）
 */
export function classifyFailure(message) {
  const inner = innerMessage(message);

  if (/^module '[^']*' not found/.test(inner)) {
    const m = /^module '([^']*)' not found/.exec(inner);
    return { shape: "missing-module", name: m === null ? "" : m[1] };
  }

  const globalUse = /\(global '([^']*)'\)/.exec(inner);
  if (globalUse !== null) {
    const name = globalUse[1];
    // 当表用：index / 取字段。当函数用：call。其余（算术、拼接）按"当值用"归并 ——
    // 对"要不要提供这个全局"而言，这两类的处理完全一样，再细分只多两个没人看的类。
    if (/attempt to index a nil value/.test(inner)) return { shape: "missing-global-table", name };
    if (/attempt to (call|concatenate|perform arithmetic on) a nil value/.test(inner)) {
      return { shape: "missing-global-value", name };
    }
    return { shape: "missing-global-value", name };
  }

  const strict = /variable '([^']*)' is not declared/.exec(inner);
  if (strict !== null) return { shape: "missing-global-strict", name: strict[1] };

  const local = /\(local '([^']*)'\)/.exec(inner);
  if (local !== null) return { shape: "script-local-nil", name: local[1] };

  return { shape: "other", name: "" };
}

/**
 * 汇总一批失败（`[脚本名, 报错原文]`），给出分组与"缺什么"的清单。
 *
 * @param failures `Array<[string, string]>`
 * @returns `{ total, groups, missingGlobals, missingModules, localNils, others }`
 *   `groups` 按次数降序（同次数按形状名字典序 —— 让输出**稳定**，
 *   不稳定的话每次跑 diff 都变，人就懒得看 diff 了）。
 */
export function summarizeFailures(failures) {
  const list = Array.isArray(failures) ? failures : [];
  const counts = new Map();
  const globals = new Map();
  const modules = new Map();
  const locals = new Map();
  const others = new Map();

  for (const entry of list) {
    const script = String((entry && entry[0]) ?? "");
    const message = String((entry && entry[1]) ?? "");
    const { shape, name } = classifyFailure(message);
    counts.set(shape, (counts.get(shape) ?? 0) + 1);

    if (shape === "missing-module") {
      const rec = modules.get(name) ?? { name, count: 0, scripts: [] };
      rec.count += 1;
      if (script !== "" && rec.scripts.length < 3) rec.scripts.push(script);
      modules.set(name, rec);
    } else if (shape === "missing-global-table" || shape === "missing-global-value") {
      const rec = globals.get(name) ?? { name, count: 0, how: [], scripts: [] };
      rec.count += 1;
      const how = shape === "missing-global-table" ? "表" : "值";
      if (!rec.how.includes(how)) rec.how.push(how);
      if (script !== "" && rec.scripts.length < 3) rec.scripts.push(script);
      globals.set(name, rec);
    } else if (shape === "missing-global-strict") {
      const rec = globals.get(name) ?? { name, count: 0, how: [], scripts: [] };
      rec.count += 1;
      if (!rec.how.includes("strict")) rec.how.push("strict");
      if (script !== "" && rec.scripts.length < 3) rec.scripts.push(script);
      globals.set(name, rec);
    } else if (shape === "script-local-nil") {
      const rec = locals.get(name) ?? { name, count: 0, scripts: [] };
      rec.count += 1;
      if (script !== "" && rec.scripts.length < 3) rec.scripts.push(script);
      locals.set(name, rec);
    } else {
      const inner = innerMessage(message);
      const rec = others.get(inner) ?? { text: inner, count: 0, scripts: [] };
      rec.count += 1;
      if (script !== "" && rec.scripts.length < 3) rec.scripts.push(script);
      others.set(inner, rec);
    }
  }

  const byCountThenName = (a, b) => b.count - a.count || (a.name < b.name ? -1 : a.name > b.name ? 1 : 0);
  const byCountThenText = (a, b) => b.count - a.count || (a.text < b.text ? -1 : a.text > b.text ? 1 : 0);

  const groups = [...counts.entries()]
    .map(([shape, count]) => ({ shape, count }))
    .sort((a, b) => b.count - a.count || (a.shape < b.shape ? -1 : a.shape > b.shape ? 1 : 0));

  return {
    total: list.length,
    groups,
    missingGlobals: [...globals.values()].sort(byCountThenName),
    missingModules: [...modules.values()].sort(byCountThenName),
    localNils: [...locals.values()].sort(byCountThenName),
    others: [...others.values()].sort(byCountThenText),
  };
}
