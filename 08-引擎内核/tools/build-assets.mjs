/**
 * 资产构建 CLI —— 把 `buildPublish`（纯函数）推到"真的落盘"
 *
 * §11.6 记过一个诚实缺口：**判据比的是内存里的字节，"写到磁盘上逐字节相同"还没验过**。
 * 这个脚本补上那一步，并且只做这一步 —— 它不含任何构建逻辑，
 * 逻辑全在 `src/extensions/build/publish.ts` 里（判据已经覆盖）。
 *
 * 用法：
 *   node --experimental-transform-types tools/build-assets.mjs \
 *     --src web/assets --out .cache/dist [--max 65536] [--entry assets/a.png ...]
 *
 * 输出目录里的东西（**只有**这些，不写时间戳/不写构建号）：
 *   manifest.txt      人可读清单（`renderManifest` 的结果，行序固定）
 *   <hash>.pack       每个包一个文件，文件名 = 内容 hash
 *
 * ★ 为什么 id 直接用相对路径：
 *   内容寻址只需要"稳定且唯一"。`stableIdFromPath` 那套 GUID 是给 `.meta` 身份用的，
 *   构建期再算一遍只会让 bug 多一个来源。要改名就改名，包名不受影响（包名只跟内容走）。
 *
 * ★ 为什么排除 `.meta`：
 *   它是导入期的输入，不是可发布内容。把 `.meta` 打进包会让"改一个导入设置"
 *   也改变产物 —— 而那种改动本不该影响玩家下载的字节。
 *
 * ★ `.meta` 里的 `dependencies` 按**相对路径**理解（本 CLI 的约定，与 AssetMeta 的
 *   AssetId 不同）。这个差异写在这里，而不是让两边偷偷不一致。
 */

import { mkdirSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { join, relative, resolve, sep } from "node:path";
import { buildPublish, renderManifest } from "../src/extensions/build/publish.ts";

function usage(msg) {
  if (msg !== undefined) console.error(`✗ ${msg}`);
  console.error(
    "用法: node --experimental-transform-types tools/build-assets.mjs --src <dir> --out <dir> [--max N] [--entry rel ...]",
  );
  process.exit(2);
}

function parseArgs(argv) {
  const out = { src: "", out: "", max: 64 * 1024, entries: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--src") out.src = argv[++i] ?? "";
    else if (a === "--out") out.out = argv[++i] ?? "";
    else if (a === "--max") out.max = Number(argv[++i] ?? "");
    else if (a === "--entry") out.entries.push(argv[++i] ?? "");
    else usage(`不认识的参数：${a}`);
  }
  if (out.src === "") usage("缺 --src");
  if (out.out === "") usage("缺 --out");
  if (!Number.isInteger(out.max) || out.max <= 0) usage("--max 必须是正整数");
  return out;
}

/** 递归列出目录下的所有文件（相对路径，正斜杠）。顺序排序，保证确定性。 */
function walk(root, dir = root, acc = []) {
  for (const e of readdirSync(dir, { withFileTypes: true }).sort((a, b) => (a.name < b.name ? -1 : 1))) {
    const p = join(dir, e.name);
    if (e.isDirectory()) walk(root, p, acc);
    else if (e.isFile()) acc.push(relative(root, p).split(sep).join("/"));
  }
  return acc;
}

const args = parseArgs(process.argv.slice(2));
const srcRoot = resolve(args.src);
const outRoot = resolve(args.out);

let files;
try {
  files = walk(srcRoot);
} catch (e) {
  console.error(`✗ 读不了源目录 ${srcRoot}：${e instanceof Error ? e.message : String(e)}`);
  process.exit(2);
}

// `.meta` 与 `.DS_Store` 之类不进产物
const publishable = files.filter((f) => !f.endsWith(".meta") && !f.split("/").some((s) => s.startsWith(".")));
if (publishable.length === 0) {
  console.error(`✗ ${srcRoot} 下没有可发布的文件`);
  process.exit(2);
}

const assets = publishable.map((id) => ({ id, path: `file:${id}`, bytes: readFileSync(join(srcRoot, id)) }));
const dependencies = new Map();
for (const id of publishable) {
  const metaPath = join(srcRoot, `${id}.meta`);
  let deps = [];
  try {
    const raw = readFileSync(metaPath, "utf8");
    const parsed = JSON.parse(raw);
    deps = Array.isArray(parsed?.dependencies) ? parsed.dependencies.filter((d) => typeof d === "string") : [];
  } catch (e) {
    if (e?.code !== "ENOENT") {
      // 解析失败必须报：静默当成"没依赖"会让缺件包上线
      console.error(`✗ ${id}.meta 解析失败：${e instanceof Error ? e.message : String(e)}`);
      process.exit(1);
    }
  }
  dependencies.set(id, deps);
}

const entries = args.entries.length > 0 ? args.entries : [...publishable].sort();
const r = buildPublish({ entries, assets, dependencies }, { maxBundleBytes: args.max });
if (!r.ok) {
  console.error(`✗ 构建失败 ${r.error.code}：${r.error.message}`);
  process.exit(1);
}

// ★ 先清空输出目录：残留的旧包会让"删掉一个未引用资产后产物不变"这条判据失去意义
//   （旧包还在目录里，产物看起来"没变"其实是因为没删）
rmSync(outRoot, { recursive: true, force: true });
mkdirSync(outRoot, { recursive: true });
writeFileSync(join(outRoot, "manifest.txt"), renderManifest(r.value.manifest), "utf8");
for (const [hash, bytes] of r.value.bundles) writeFileSync(join(outRoot, `${hash}.pack`), bytes);

console.log(
  JSON.stringify({
    manifest: r.value.manifest.hash,
    assets: r.value.manifest.assets.length,
    bundles: r.value.manifest.bundles.length,
    out: outRoot,
  }),
);
