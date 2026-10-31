#!/usr/bin/env node
/**
 * 确定性闸门：`src/` 里不许出现**规范没规定结果**的数值运算。
 *
 * ★ 为什么需要一道**静态**闸门，而不是再加几条行为判据：
 *   行为判据在这里是**没有分辨力的**。`Math.hypot(1, 1)` 与
 *   `Math.sqrt(1 + 1)` 在 V8 上恰好逐位相同（实测：`dirStep` 的定义域只有
 *   9 组方向向量，9/9 相同）—— 所以「把 planeLen 改回 hypot」，位置判据
 *   **一条都不会红**。它只在换宿主（JSC / SpiderMonkey / 将来的 V8）时红，
 *   而那种红**在我们的 CI 里永远不会出现**。
 *
 *   于是判据只能长在源码上：**扫描 + 白名单**。变异（把某处 planeLen 改回
 *   `Math.hypot`）打的就是这条扫描，必然被抓住。
 *
 * ★ 为什么扫描器自己也要自检（`--selftest`）：
 *   一个「恒不输出」的扫描器与一个「仓库真的干净」的扫描器，报告一模一样。
 *   自检用**合成语料**正向打每条规则与每条守卫，四种情形（命中/白名单/
 *   陈旧白名单/规则失效）都必须在内存里复现，不依赖仓库现状。
 *
 * 用法：
 *   node tools/determinism-scan.mjs              # 扫仓库
 *   node tools/determinism-scan.mjs --selftest   # 只跑自检（合成语料）
 *
 * 退出码：0 干净；1 有违规；2 扫描器自身失效（没扫到文件 / 规则零命中）。
 */

import { readdirSync, readFileSync, statSync } from "node:fs";
import { dirname, join, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCAN_ROOT = join(ROOT, "src");

/**
 * 规则表。`expect` 是**今天仓库里应命中的处数**（含白名单命中的）。
 *
 * ★ 为什么要写死一个数字：规则一旦失效（正则写错、文件被改名、代码被搬走），
 *   它会安静地命中 0 处，而"0 处"与"仓库干净"的输出完全一样。写死数字之后，
 *   任何增减都要有人来认领 —— 是新增了违规（该修）、还是规则废了（该删规则）。
 */
const RULES = [
  {
    id: "hypot",
    pattern: /Math\.hypot\s*\(/g,
    expect: 1,
    why: "Math.hypot 的实现未定义：IEEE-754 只规定 + - * / sqrt 是正确舍入的，各引擎的 hypot 为防溢出会先做缩放，结果可以差 1 ulp（实测任意浮点 39.03% 差 1 ulp）。",
    fix: "改用 foundation/math 的 planeLen(dx, dz)（= sqrt(dx²+dz²)，逐位可复现）。",
  },
  {
    id: "random",
    pattern: /Math\.random\s*\(/g,
    expect: 0,
    why: "Math.random 由宿主实现，同一种子在不同引擎/同一引擎不同版本上序列不同 —— 回放、存档比对、双端对局都会分叉。",
    fix: "用 foundation/random 的 XorShift128（种子来自存档/主机），不要在仿真层直接取随机数。",
  },
];

/**
 * 白名单：**逐条（文件 × 规则）**，并且必须写上「为什么它不危险」。
 *
 * ★ 键必须精确到文件与规则，不许「整个目录豁免」：目录豁免会让新文件自动免疫，
 *   而那正是闸门要防的事。
 * ★ 白名单条目**必须被用到**（见 `unusedAllow`）：文件改名 / 那段代码删掉之后，
 *   白名单会静默失效，闸门看起来还在守，实际守的是一片空地。
 */
const ALLOW = [
  {
    file: "src/editor-entry.ts",
    rule: "hypot",
    why: "编辑器拖拽阈值（判定「这次按下是点击还是拖拽」）。只在编辑器交互里跑，不进仿真、不进回放、不进存档 —— 它算出 1 ulp 的差别没有任何下游。",
  },
];

const EXTS = [".ts"];

/** 递归收集待扫文件（相对 ROOT 的 POSIX 路径）。 */
export function collect(dir, out = []) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) collect(p, out);
    else if (EXTS.some((e) => name.endsWith(e))) out.push(relative(ROOT, p).split("\\").join("/"));
  }
  return out;
}

/**
 * 这一行的**行首**是不是注释（斜杠、星号、块注释的开头与结尾）。
 *
 * ★ 为什么要跳过注释行：闸门守的是「会被执行的运算」，注释不执行。
 *   实测的代价很具体：`foundation/random.ts` 与 `worldgen.ts` 的文件头都写着
 *   「★ 为什么不能用 `Math.random()`」—— 那是**正确的文档**，被闸门判红之后
 *   只能加白名单，而白名单一多，人就会习惯性"红了就加一条"。
 *   闸门被训练成噪音之后就不再是闸门了。
 *
 * ★ 为什么是**行级**启发式，而不是剥掉整段注释：剥注释要解析字符串
 *   （本仓库有一堆内嵌 Lua 源码与 JSON，字符串里的 `//` 会被当注释），
 *   那是一个会静默吃掉代码的解析器。行级判断只看行首，最坏情况是
 *   「多行块注释中间的一行」被误判成代码（红一下，人看一眼就好），
 *   不会出现「代码被吃掉一段所以闸门全绿」。
 */
function isCommentLine(text) {
  const t = text.trimStart();
  return t.startsWith("//") || t.startsWith("*") || t.startsWith("/*") || t.startsWith("*/");
}

/**
 * 纯函数：给 `[{ path, text }]` 与规则表，返回违规与统计。
 *
 * ★ 做成纯函数是为了自检能在**内存里**造语料打它 —— 不读盘、不看仓库现状。
 */
export function scan(files, rules = RULES, allow = ALLOW) {
  const allowKeys = new Set(allow.map((a) => `${a.file}\u0000${a.rule}`));
  const used = new Set();
  const violations = [];
  const hitsByRule = new Map(rules.map((r) => [r.id, 0]));
  let lines = 0;

  for (const f of files) {
    const fileLines = f.text.split("\n");
    lines += fileLines.length;
    for (const rule of rules) {
      rule.pattern.lastIndex = 0;
      let m;
      while ((m = rule.pattern.exec(f.text)) !== null) {
        const before = f.text.slice(0, m.index);
        const line = before.split("\n").length;
        const lineText = fileLines[line - 1] ?? "";
        if (isCommentLine(lineText)) continue;
        hitsByRule.set(rule.id, (hitsByRule.get(rule.id) ?? 0) + 1);
        const key = `${f.path}\u0000${rule.id}`;
        if (allowKeys.has(key)) {
          used.add(key);
          continue;
        }
        violations.push({
          path: f.path,
          line,
          rule: rule.id,
          text: lineText.trim(),
          why: rule.why,
          fix: rule.fix,
        });
      }
    }
  }

  // 规则失效：命中数与登记值不符（新违规或规则废了，两种都要人来看）
  const stale = rules
    .filter((r) => (hitsByRule.get(r.id) ?? 0) !== r.expect)
    .map((r) => ({ id: r.id, expect: r.expect, actual: hitsByRule.get(r.id) ?? 0 }));

  // 陈旧白名单：登记了但今天一处都没命中
  const unusedAllow = allow.filter((a) => !used.has(`${a.file}\u0000${a.rule}`));

  return { violations, stale, unusedAllow, hitsByRule, lines, files: files.length };
}

function readAll(paths) {
  return paths.map((p) => ({ path: p, text: readFileSync(join(ROOT, p), "utf8") }));
}

function report(result) {
  const bad = [];
  for (const v of result.violations) {
    bad.push(
      `✗ ${v.path}:${v.line}  [${v.rule}]  ${v.text}\n` +
        `    为什么不行：${v.why}\n` +
        `    怎么改：${v.fix}`,
    );
  }
  for (const s of result.stale) {
    bad.push(
      `✗ 规则 ${s.id} 的命中数变了：登记 ${s.expect}，实际 ${s.actual}。\n` +
        `    多了 = 有人新写入了这类运算（该按规则改掉）；少了 = 那段代码被删/被搬走（该更新 expect 或删规则）。\n` +
        `    ★ 这一条不许改成"容差"—— 它存在的唯一理由就是逼人看一眼。`,
    );
  }
  for (const a of result.unusedAllow) {
    bad.push(
      `✗ 白名单条目没有被用到：${a.file} 里的 ${a.rule}。\n` +
        `    文件改名 / 那段代码被删 / 已经改成合规写法 —— 三种情况都该销账，\n` +
        `    否则这条白名单会在未来的某一天替一段新写的违规打掩护。`,
    );
  }
  return bad;
}

// ---------------------------------------------------------------- 自检

function selftest(quiet = false) {
  const cases = [];
  const fake = (path, text) => ({ path, text });

  // ① 命中未登记 ⇒ 红
  {
    const r = scan([fake("src/a.ts", "const d = Math.hypot(dx, dz);\n")], RULES, []);
    cases.push({
      name: "违规未登记 → 报出 1 处并带行号",
      ok:
        r.violations.length === 1 &&
        r.violations[0].line === 1 &&
        r.violations[0].rule === "hypot" &&
        // hypot 登记 1 处，这里正好命中 1 处 ⇒ 命中数没变，不是 stale
        r.stale.length === 0,
    });
  }

  // ② 命中且在白名单 ⇒ 绿
  {
    const r = scan(
      [fake("src/a.ts", "x\nconst d = Math.hypot(dx, dz);\n")],
      RULES,
      [{ file: "src/a.ts", rule: "hypot", why: "测试用" }],
    );
    cases.push({
      name: "命中但在白名单 → 无违规、无陈旧条目、命中数仍计 1",
      ok: r.violations.length === 0 && r.unusedAllow.length === 0 && r.stale.length === 0,
    });
  }

  // ③ 白名单登记了但没命中 ⇒ 红（陈旧白名单）
  {
    const r = scan([fake("src/a.ts", "const d = planeLen(dx, dz);\n")], RULES, [
      { file: "src/a.ts", rule: "hypot", why: "测试用" },
    ]);
    cases.push({
      name: "陈旧白名单 → 报出未使用条目（且命中数 0 触发 stale）",
      ok: r.unusedAllow.length === 1 && r.violations.length === 0 && r.stale.length === 1,
    });
  }

  // ④ 规则失效（正则写错 / 仓库里真的没有）⇒ 与登记值不符
  {
    const broken = [{ ...RULES[0], pattern: /Math\.hypott\s*\(/g }];
    const r = scan([fake("src/a.ts", "const d = Math.hypot(dx, dz);\n")], broken, []);
    cases.push({
      name: "规则失效（永远 0 命中）→ stale 报出来，不会假装干净",
      ok: r.violations.length === 0 && r.stale.length === 1 && r.stale[0].actual === 0,
    });
  }

  // ⑤ 整行注释里的**提及**不算违规（否则文件头写「为什么不能用 Math.random」都会被判红）
  {
    const r = scan([fake("src/a.ts", "// Math.hypot(a, b)\n * ★ 不能用 `Math.random()`\n")], RULES, []);
    cases.push({
      name: "整行注释里的提及不算违规（命中数也不计）",
      ok: r.violations.length === 0 && r.hitsByRule.get("hypot") === 0,
    });
  }

  // ⑤b 但**代码行**上的调用不豁免 —— 行首不是注释标记时照样红
  {
    const r = scan([fake("src/a.ts", "const d = Math.hypot(dx, dz); // 旧写法\n")], RULES, []);
    cases.push({
      name: "代码行末的注释不豁免调用（行首是代码就照样判）",
      ok: r.violations.length === 1 && r.violations[0].line === 1,
    });
  }

  // ⑥ 白名单键必须精确到文件：同规则换个文件就红
  {
    const r = scan([fake("src/b.ts", "Math.hypot(a, b);\n")], RULES, [
      { file: "src/a.ts", rule: "hypot", why: "测试用" },
    ]);
    cases.push({
      name: "白名单只对登记的那个文件生效（换个文件照样红）",
      ok: r.violations.length === 1 && r.unusedAllow.length === 1,
    });
  }

  // ⑦ 行号在多行文件里对得上
  {
    const r = scan([fake("src/a.ts", "a\nb\nc\nMath.hypot(1, 1);\n")], RULES, []);
    cases.push({ name: "行号按文件内真实行号（第 4 行）", ok: r.violations[0].line === 4 });
  }

  let bad = 0;
  for (const c of cases) {
    if (!quiet) console.log(`${c.ok ? "✓" : "✗"} ${c.name}`);
    if (!c.ok) {
      bad++;
      if (quiet) console.error(`✗ 自检失败：${c.name}`);
    }
  }
  if (!quiet) console.log(`\n自检：${cases.length - bad}/${cases.length} 通过`);
  return bad === 0 ? 0 : 2;
}

// ---------------------------------------------------------------- 主流程

/**
 * 扫到的东西必须像个真仓库。没有这两个下限，路径写错（cwd 不对、扩展名改错）
 * 会得到「0 个文件、0 处违规、干干净净」—— 那是最危险的一种绿。
 */
const MIN_FILES = 200;
const MIN_LINES = 40000;

export function main(argv = process.argv) {
  if (argv.includes("--selftest")) return selftest(false);

  // ★ 每次真跑之前**先**自检：一个"恒不输出"的扫描器与一个"仓库真的干净"的扫描器，
  //   报告完全一样。自检用的是内存里的合成语料，不依赖仓库现状，也不看磁盘。
  if (selftest(true) !== 0) {
    console.error("✗ 确定性闸门自检不过 —— 这时它的「没发现问题」不可信，先修扫描器。");
    return 2;
  }

  const result = scan(readAll(collect(SCAN_ROOT)));

  if (result.files < MIN_FILES || result.lines < MIN_LINES) {
    console.error(
      `✗ 扫描器没扫到应有的规模：${result.files} 个文件 / ${result.lines} 行 ` +
        `（下限 ${MIN_FILES} / ${MIN_LINES}）。\n` +
        `  多半是路径或扩展名写错了 —— 这时候的"没发现问题"不算通过。`,
    );
    return 2;
  }

  const bad = report(result);
  const hitSummary = [...result.hitsByRule].map(([id, n]) => `${id}=${n}`).join(" / ");

  if (bad.length > 0) {
    for (const line of bad) console.error(line);
    console.error(`\n✗ 确定性闸门：${bad.length} 处问题（扫了 ${result.files} 个文件 / ${result.lines} 行）`);
    return 1;
  }

  console.log(
    `✓ 确定性闸门：${result.files} 个文件 / ${result.lines} 行 / ${RULES.length} 条规则，` +
      `命中 ${hitSummary}（白名单 ${ALLOW.length} 条已用掉）`,
  );
  return 0;
}

// ★ 只有**直接运行**才执行。判据文件会 import `scan` / `main`，
//   顶层 `process.exit` 会把测试进程一起杀掉（`tests/tools/*.test.ts` 里已经
//   有 import 工具的惯例，所以这个守卫是必须的，不是防御性编程）。
const isEntry =
  process.argv[1] !== undefined && resolve(process.argv[1]) === fileURLToPath(import.meta.url);
if (isEntry) process.exit(main());
