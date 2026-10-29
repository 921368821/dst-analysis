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

/**
 * 加载顺序的预设。
 *
 * ★ 为什么"顺序"是**测量口径**的一部分（批136 的教训）：`IsConsole` / `IsSteamDeck` /
 *   `ValidateLineNumber` 是 `main.lua`（DST 的引导文件）**自己定义的**，
 *   `global` 在 `strict.lua` 里，`Vector3` 在 `vector3.lua` 里 —— 都是内容层的东西。
 *   按字母序加载时 `debugkeys.lua` 排在 `main.lua` 前面，于是它们"看起来"是引擎缺口。
 *   顺序不改对，"缺什么"就会数错。
 *
 * ★ `alpha` 是**我们原本的口径**（纯字母序），保留它是因为它是基线：
 *   换了口径的数字必须能和旧数字比。
 */
export const ORDER_PRESETS = {
  alpha: [],
  /** 只把 `strict.lua` 提到最前：isolate 出"允许读到 nil 继续跑"的影响。 */
  "strict-first": ["strict.lua"],
  /** DST 自己也认的引导文件（顺序有意义，不排序）都在最前。 */
  "boot-first": ["main.lua", "strict.lua", "class.lua", "util.lua", "vector3.lua", "constants.lua"],
};

/**
 * 按预设排加载顺序，返回**新数组**（不改入参）。
 *
 * @param files 语料里的脚本名
 * @param preset `ORDER_PRESETS` 的键；未知键**抛错**（不静默回退到 alpha ——
 *   回退会让"我以为在跑严格口径"变成无法发现的事实）
 */
export function orderScripts(files, preset = "alpha") {
  const first = ORDER_PRESETS[preset];
  if (first === undefined) {
    throw new Error(
      `未知的加载顺序预设：${preset}（可选：${Object.keys(ORDER_PRESETS).join(" / ")}）`,
    );
  }
  const present = new Set(files);
  // ★ 只把**语料里真的有**的引导文件排前面：缺 main.lua 的语料不该凭空多出一个元素。
  const head = first.filter((f) => present.has(f));
  const headSet = new Set(head);
  const rest = [...files].filter((f) => !headSet.has(f)).sort();
  return [...head, ...rest];
}

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

/**
 * 把一批「每个口径都缺」的全局名劈成两半。
 *
 * ★ 为什么需要这一刀（批136 实测）：`EntityScript` / `WORLD_TILES` / `Entity` /
 *   `Print` 这些名字在**三种加载顺序下都被报缺**，但它们其实有内容层定义 ——
 *   `componentactions.lua` 在 3128 行 `function EntityScript:XXX()` 之前就用了它，
 *   `constants.lua` 在自己跑到 1201 行 `WORLD_TILES = {` 之前就 `require` 了
 *   `custompresets`（嵌套加载）。只看报错，"缺"与"还没轮到"长得一模一样。
 *
 *   所以真正的判据是**跑完之后再问一次 `_G`**：
 *   · 跑完仍是 nil ⇒ 这份语料里没有任何文件给过它 ⇒ 引擎欠的
 *   · 跑完出现了  ⇒ 只是当时还没轮到 ⇒ 顺序/嵌套加载问题，别拿它做 API 面
 *
 * ★ 没探测到的名字算 `later`（**不主张缺口**）。理由：把"没证据"报成"引擎欠的"
 *   会让人去做一堆没人需要的假对象；而"引擎欠的"被误判成顺序问题，代价是下一批
 *   再量一次 —— 两种错都会发生，但前者会污染代码，后者只污染一次测量。
 *
 * @param names 每个口径都缺的全局名
 * @param probes 每个口径跑完时的一次探测（`Record<名字, type() 的结果>`），
 *        顺序无关，只要求"每个口径一份"
 * @returns `{ never, later }`：`never` = 三档跑完都还是 nil；`later` = 其余
 */
export function splitNeverDefined(names, probes) {
  const list = Array.isArray(names) ? names : [];
  const maps = Array.isArray(probes) ? probes : [];
  const never = [];
  const later = [];
  for (const raw of list) {
    const name = String(raw);
    const stillNil =
      maps.length > 0 &&
      maps.every((m) => m !== null && m !== undefined && m[name] === "nil");
    (stillNil ? never : later).push(name);
  }
  return { never, later };
}
