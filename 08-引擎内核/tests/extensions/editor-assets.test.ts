/**
 * L4 · 编辑器：资产列表的判据（批86）
 *
 * 这一组里最值钱的是**最后两条**：
 *
 * ① `清单与磁盘一致` —— 清单是唯一来源（浏览器端 `HttpFileSystem.canList = false`，
 *    页面没法自己列目录），所以它一定会过期。加一个 png 忘了写清单，面板就少一行，
 *    而**没有任何东西会报错**。这条判据就是那个"东西"：双向对账
 *    （清单里有但磁盘上没有 / 磁盘上有但清单里没有）。
 *
 * ② `后缀表与导入器一致` —— 这张表在 `asset-list.ts`，而真正的后缀集合在
 *    `asset-import/importers/*.ts` 里注册。两处各写一份的漂移是**静默**的：
 *    面板把 `.atlas.json` 显示成文本资产，而导入管线把它当图集 ——
 *    同一个文件在两个地方是两种东西，谁都不会报错。
 *
 * 其余几条钉的是"看起来成功"的三类：
 *   · `.meta` sidecar 被当资产 ⇒ 每张图在列表里出现两次，其中一条点下去没反应；
 *   · 排序靠 `readdir` 顺序 ⇒ 每次打开顺序都不同（人跟丢），判据靠顺序就变碰运气；
 *   · `inAtlas` 恒为 true ⇒ 点了「加入场景」什么都不会发生，画面上毫无痕迹。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync, readdirSync, statSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

import { stableIdFromPath } from "../../src/core/asset/asset.ts";
import { ImporterRegistry } from "../../src/extensions/asset-import/importer.ts";
import { textureImporter } from "../../src/extensions/asset-import/importers/texture.ts";
import { textImporter } from "../../src/extensions/asset-import/importers/text.ts";
import { atlasImporter } from "../../src/extensions/asset-import/importers/atlas.ts";
import {
  ASSET_MANIFEST_VERSION,
  EDIT_BAD_ASSET_LIST,
  assetNameOf,
  buildAssetCatalog,
  catalogFromManifest,
  classifyExtension,
  parseAssetManifest,
} from "../../src/extensions/editor/asset-list.ts";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..", "..");
const WEB_ASSETS = join(ROOT, "web", "assets");
const MANIFEST = join(ROOT, "web", "assets-manifest.json");

/** 真磁盘上的 web/assets（递归，相对路径用 `/`）。 */
function diskPaths(dir = WEB_ASSETS, base = WEB_ASSETS): string[] {
  const out: string[] = [];
  for (const name of readdirSync(dir)) {
    const full = join(dir, name);
    if (statSync(full).isDirectory()) out.push(...diskPaths(full, base));
    else out.push(relative(base, full).replace(/\\/g, "/"));
  }
  return out.sort();
}

// ------------------------------------------------------------ 分类与命名

test("后缀分类：最长后缀赢（.atlas.json 是图集，不是文本）", () => {
  assert.equal(classifyExtension("a.png")?.kind, "texture");
  assert.equal(classifyExtension("a.JPG")?.kind, "texture", "大小写不该影响分类");
  assert.equal(classifyExtension("a.fnt")?.kind, "font");
  assert.equal(classifyExtension("a.lua")?.kind, "text");
  assert.equal(
    classifyExtension("world.atlas.json")?.kind,
    "atlas",
    classificationBug("atlas"),
  );
  assert.equal(classifyExtension("notes.md")?.kind, "text", ".md 不能因为 .atlas.json 变了就掉队");
});

function classificationBug(what: string): string {
  return `.${what}.json 被当成了文本资产 —— 最长后缀优先的那条规则没生效`;
}

test("后缀分类：不是资产的后缀返回 undefined（不是抛错、也不是猜成 text）", () => {
  assert.equal(classifyExtension("a.psd"), undefined);
  assert.equal(classifyExtension("LICENSE"), undefined);
  assert.equal(classifyExtension("a.png.bak"), undefined);
});

test("★ 后缀表与导入器注册的后缀集合双向一致", () => {
  const reg = new ImporterRegistry();
  reg.register(textureImporter);
  reg.register(textImporter);
  reg.register(atlasImporter);
  const registered = reg.extensions();

  // 正向：导入器认识的每个后缀，这里都得有类别（否则面板根本不会列它）
  const missing = registered.filter((ext) => classifyExtension("x" + ext) === undefined);
  assert.deepEqual(missing, [], `这些后缀导入器收、但资产列表不认识：${missing.join(" ")}`);

  // 反向：这里认识的每个后缀，都得有导入器收（否则列出来也导不进去）
  const produced = new Set<string>();
  for (const ext of registered) {
    const got = classifyExtension("x" + ext);
    if (got !== undefined) produced.add(got.ext);
  }
  const kinds = ["a.png", "a.jpg", "a.jpeg", "a.fnt", "a.txt", "a.json", "a.lua", "a.md", "a.atlas.json"];
  for (const p of kinds) {
    const got = classifyExtension(p);
    assert.ok(got !== undefined, `${p} 应有类别`);
    assert.ok(
      produced.has(got.ext),
      `${p} 被分成 ${got.kind}（后缀 ${got.ext}），但没有导入器收 ${got.ext}`,
    );
  }
});

test("资产名：去掉最长的已知后缀（tree.png → tree、world.atlas.json → world）", () => {
  assert.equal(assetNameOf("tree.png"), "tree");
  assert.equal(assetNameOf("photo.jpg"), "photo");
  assert.equal(assetNameOf("ui-font.fnt"), "ui-font");
  assert.equal(assetNameOf("world.atlas.json"), "world");
  assert.equal(assetNameOf("sub/dir/rock.png"), "rock");
  // 去掉后缀会变空 ⇒ 保留原名，不能返回空串（空帧名会让"加入场景"直接失败）
  assert.equal(assetNameOf(".png"), ".png");
});

// ------------------------------------------------------------ 目录整理

test("★ .meta sidecar 不是资产（否则每张图在列表里出现两次）", () => {
  const cat = buildAssetCatalog(["tree.png", "tree.png.meta", "notes.md.meta"]);
  assert.deepEqual(
    cat.entries.map((e) => e.path),
    ["tree.png"],
  );
  assert.deepEqual(
    cat.skipped.map((s) => s.reason),
    ["sidecar", "sidecar"],
  );
});

test("未知后缀被跳过并记账（不是静默丢弃）", () => {
  const cat = buildAssetCatalog(["tree.png", "fire.psd"]);
  assert.equal(cat.entries.length, 1);
  assert.deepEqual(cat.skipped, [{ path: "fire.psd", reason: "unknown-ext" }]);
});

test("怪路径被拒：不许绝对路径 / 盘符 / .. 段", () => {
  const cat = buildAssetCatalog(["../secret.png", "/abs.png", "C:/x.png", "  "]);
  assert.equal(cat.entries.length, 0, "越界路径不能进列表");
  assert.equal(cat.skipped.filter((s) => s.reason === "bad-path").length, 4);
});

test("id 与导入管线同一个规则（stableIdFromPath）", () => {
  const cat = buildAssetCatalog(["tree.png"]);
  assert.equal(cat.entries[0]?.id, stableIdFromPath("tree.png"));
});

test("★ 排序是确定的：输入顺序打乱，输出一模一样", () => {
  const input = ["tree.png", "Berry.png", "berry.png", "a/zzz.png", "player.jpg"];
  const a = buildAssetCatalog(input).entries.map((e) => e.path);
  const b = buildAssetCatalog(input.slice().reverse()).entries.map((e) => e.path);
  const c = buildAssetCatalog([input[2]!, input[0]!, input[4]!, input[1]!, input[3]!]).entries.map(
    (e) => e.path,
  );
  assert.deepEqual(a, b);
  assert.deepEqual(a, c);
  // 按路径排：子目录的 a/zzz.png 在前（按"资产名 zzz" 排会把它排到最后，看着像坏了）；
  // 大小写只由原文兜底 —— Berry 与 berry 相邻，大写在前。
  assert.deepEqual(a, ["a/zzz.png", "Berry.png", "berry.png", "player.jpg", "tree.png"]);
});

test("同一路径写两次只出现一次（清单手抄重复不该出现两行）", () => {
  const cat = buildAssetCatalog(["tree.png", "tree.png"]);
  assert.equal(cat.entries.length, 1);
  assert.deepEqual(cat.skipped, [{ path: "tree.png", reason: "duplicate-path" }]);
});

test("★ inAtlas：图集里没有的帧要标出来（否则『加入场景』点了没反应）", () => {
  const frames = ["tree", "rock", "player", "berry", "ground", "terrain"];
  const cat = buildAssetCatalog(["tree.png", "photo.jpg", "rock.png"], { frameNames: frames });
  const byName = new Map(cat.entries.map((e) => [e.name, e]));
  assert.equal(byName.get("tree")?.inAtlas, true);
  assert.equal(byName.get("rock")?.inAtlas, true);
  assert.equal(byName.get("photo")?.inAtlas, false, "photo 没有同名帧，必须标成 false");

  // 不给帧表 = 不知道 ⇒ 一律 false，不能乐观地当成 true
  const blind = buildAssetCatalog(["tree.png"]);
  assert.equal(blind.entries[0]?.inAtlas, false);
});

test("★ 文本资产即便名字撞上帧名也不算「有帧」（ui-font.fnt vs ui-font.png）", () => {
  // 这一条是批87 接上真实图集之后补的：`ui-font.fnt` 与 `ui-font.png` 派生出的
  // 名字都是 `ui-font`，而图集里真有 `ui-font` 这一帧（来自那个 png）。
  // 只看帧名的话，字体的**文本**文件会被判成"可加入场景" ——
  // 点下去会造出一个精灵，指向字体图集的一块。页面自检当时就栽在这儿：
  // 「无帧被拒」那条返回了 ok:true。
  const cat = buildAssetCatalog(["ui-font.png", "ui-font.fnt", "ui-skin.json"], {
    frameNames: ["ui-font", "ui-skin"],
  });
  const byPath = new Map(cat.entries.map((e) => [e.path, e]));
  assert.equal(byPath.get("ui-font.png")?.inAtlas, true, "位图且帧在 ⇒ 可加入");
  assert.equal(byPath.get("ui-font.fnt")?.inAtlas, false, "同名帧的文本资产不能算可加入");
  assert.equal(byPath.get("ui-skin.json")?.inAtlas, false, "同上");
});

// ------------------------------------------------------------ 清单

test("清单：合法输入返回路径数组（容忍 BOM 与 CRLF）", () => {
  const text = '\uFEFF{\r\n  "version": 1,\r\n  "assets": ["a.png", "b.png"]\r\n}\r\n';
  const r = parseAssetManifest(text);
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (r.ok) assert.deepEqual(r.value, ["a.png", "b.png"]);
});

test("清单：坏输入全部报 EDIT.BAD_ASSET_LIST，且消息能区分是哪一种坏", () => {
  const cases: Array<[string, string, string]> = [
    ["不是 JSON", "{oops", "JSON"],
    ["顶层是数组", "[]", "对象"],
    ["缺 version", '{"assets":[]}', "version"],
    ["version 不是整数", '{"version":"1","assets":[]}', "version"],
    ["清单比编辑器新", `{"version":${String(ASSET_MANIFEST_VERSION + 1)},"assets":[]}`, "比编辑器新"],
    ["缺 assets", '{"version":1}', "assets"],
    ["元素不是字符串", '{"version":1,"assets":["a.png",3]}', "assets[1]"],
  ];
  for (const [label, text, mustMention] of cases) {
    const r = parseAssetManifest(text);
    assert.equal(r.ok, false, `${label}：本该报错却通过了`);
    if (r.ok) continue;
    assert.equal(r.error.code, EDIT_BAD_ASSET_LIST, `${label}：错误码不对`);
    assert.ok(
      r.error.message.includes(mustMention),
      `${label}：消息里没有「${mustMention}」，实际是「${r.error.message}」`,
    );
  }
});

test("catalogFromManifest：清单坏了要把错误交回去，不能返回空目录", () => {
  const r = catalogFromManifest("{oops");
  assert.equal(r.ok, false);
  if (!r.ok) assert.equal(r.error.code, EDIT_BAD_ASSET_LIST);
});

// ------------------------------------------------------------ 与磁盘对账

test("★★ 清单与 web/assets 双向一致（加了文件忘了写清单就红）", () => {
  const onDisk = diskPaths().filter((p) => !p.toLowerCase().endsWith(".meta"));
  const listed = parseAssetManifest(readFileSync(MANIFEST, "utf8"));
  assert.equal(listed.ok, true, listed.ok ? "" : `清单读不了：${listed.error.message}`);
  if (!listed.ok) return;

  const diskSet = new Set(onDisk);
  const listSet = new Set(listed.value);

  const missingInManifest = onDisk.filter((p) => !listSet.has(p));
  const missingOnDisk = listed.value.filter((p) => !diskSet.has(p));

  assert.deepEqual(
    missingInManifest,
    [],
    `这些文件在 web/assets 里但清单没写（面板会少几行，且不会有任何报错）：${missingInManifest.join(" ")}`,
  );
  assert.deepEqual(
    missingOnDisk,
    [],
    `清单写了但磁盘上没有（面板里那一行点下去会 404）：${missingOnDisk.join(" ")}`,
  );
});

test("★★ 清单喂出来的目录里，6 个真资产有帧、其余明确标无帧", () => {
  // 帧名就是编辑器的程序化图集的 6 帧（与 `render/atlas.ts` 的 layout 一致）
  const frames = ["tree", "rock", "player", "berry", "ground", "terrain"];
  const r = catalogFromManifest(readFileSync(MANIFEST, "utf8"), { frameNames: frames });
  assert.equal(r.ok, true, r.ok ? "" : r.error.message);
  if (!r.ok) return;

  const usable = r.value.entries.filter((e) => e.inAtlas).map((e) => e.name);
  assert.deepEqual(usable.sort(), ["berry", "ground", "player", "rock", "terrain", "tree"]);

  // 每个资产都得有类别、有 id、名字非空 —— 面板直接拿这些画，缺一个就是一行空白
  for (const e of r.value.entries) {
    assert.ok(e.name !== "", `${e.path} 的名字是空的`);
    assert.ok(e.id.startsWith("p"), `${e.path} 的 id 形如 ${e.id}`);
    assert.ok(["texture", "text", "font", "atlas"].includes(e.kind), `${e.path} 的类别是 ${e.kind}`);
  }
});
