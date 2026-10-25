/**
 * L5 · 发布：平台分包规划（纯逻辑）
 *
 * ★ 这一层的判据全部围绕「**上传前一定失败的事情必须在构建期变红**」：
 *   超 4MB 的主包、没有归属的文件、微信不收的后缀、写坏的 VDF。
 *   每一条都对应一次真机上的「打开失败」或「贴图变白块」，而那些现象
 *   在开发机上看不出来 —— 所以只能在这里拦。
 *
 * ★ 预算判据用的是**边界**而不是"造一个 5MB 的假文件"：正好 4MB 通过、
 *   4MB+1 字节失败。差一字节的边界是这类规则唯一会出错的地方。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  FORBIDDEN_IN_MINIGAME,
  PACK_BAD_CONFIG,
  PACK_BAD_EXT,
  PACK_DUPLICATE,
  PACK_EMPTY,
  PACK_MISPLACED,
  PACK_OVER_MAIN,
  PACK_OVER_SUB,
  PACK_OVER_TOTAL,
  PACK_UNMATCHED,
  WECHAT_EXT_WHITELIST,
  WECHAT_LIMITS,
  checkVdf,
  matchRule,
  planWechat,
  renderAppBuildVdf,
  renderDepotBuildVdf,
  renderGameJson,
  ruleProblem,
  scanMiniGameSource,
  type StagedFile,
} from "../../src/publish/pack-plan.ts";

const MB = 1024 * 1024;

function files(...specs: [string, number][]): StagedFile[] {
  return specs.map(([path, bytes]) => ({ path, bytes }));
}

const CFG = {
  main: ["*.js", "*.json"],
  subpackages: [{ name: "terrain", match: ["assets/terrain/"] }],
};

function codes(r: { ok: boolean }): string[] {
  assert.equal(r.ok, false, "这一步本应失败");
  return (r as unknown as { error: { code: string }[] }).error.map((e) => e.code);
}

// ---------------------------------------------------------------- 匹配

test("[打包] 规则三种形状：*.ext 按后缀、dir/ 按前缀、其它按精确路径", () => {
  assert.equal(matchRule("*.js", "game.js"), true);
  assert.equal(matchRule("*.js", "sub/a.js"), true, "后缀规则不限定目录");
  assert.equal(matchRule("*.JS", "a.js"), true, "大小写不敏感（Windows 上导出的文件名常常是大写）");
  assert.equal(matchRule("assets/terrain/", "assets/terrain/t1.png"), true);
  assert.equal(matchRule("assets/terrain/", "assets/terrainx/t1.png"), false, "前缀必须按目录边界");
  assert.equal(matchRule("game.json", "game.json"), true);
  assert.equal(matchRule("game.json", "sub/game.json"), false, "精确路径就是精确匹配");
});

test("[打包] ★ 不认识的规则直接拒绝（`assets/**` 一条都匹配不上，却看起来对）", () => {
  assert.notEqual(ruleProblem("assets/**"), null, "通配符只允许最前面的 *.ext 形式");
  assert.notEqual(ruleProblem("assets/*.png"), null);
  assert.notEqual(ruleProblem("*."), null);
  assert.notEqual(ruleProblem(""), null);
  assert.equal(ruleProblem("*.png"), null);
  assert.equal(ruleProblem("assets/terrain/"), null);
  assert.equal(ruleProblem("game.json"), null);
});

// ---------------------------------------------------------------- 分包归属

test("[打包] ★ 分包优先于主包：`*.json` 与具体分包都命中时进分包", () => {
  const r = planWechat(files(["game.js", 100], ["a.json", 10], ["assets/terrain/t.png", 50]), CFG);
  assert.equal(r.ok, true, r.ok ? "" : r.error.map((e) => e.code).join(","));
  const plan = r.ok ? r.value : null;
  assert.ok(plan !== null);
  assert.deepEqual(plan.main.files.map((f) => f.path), ["a.json", "game.js"], "主包内按路径升序");
  assert.deepEqual(plan.subpackages[0]?.files.map((f) => f.path), ["assets/terrain/t.png"]);
  assert.equal(plan.subpackages[0]?.root, "assets/terrain", "唯一的 dir 规则 ⇒ root 就取这个目录");
  assert.equal(plan.totalBytes, 160);
});

test("[打包] ★ 分包文件必须落在自己的 root 之下（否则 game.json 指的目录里没有它）", () => {
  // root 默认 subpackage/<name>（因为规则是精确路径，不是目录），文件却在别处
  const r = planWechat(files(["game.js", 1], ["assets/t.png", 1]), {
    main: ["*.js"],
    subpackages: [{ name: "art", match: ["assets/t.png"] }],
  });
  assert.deepEqual(codes(r), [PACK_MISPLACED]);
  const msg = (r as unknown as { error: { message: string }[] }).error[0]!.message;
  assert.match(msg, /subpackage\/art/, "报错里要写出它应该在哪个目录下");
  assert.match(msg, /assets\/t\.png/);

  // 放到正确位置就通过
  const okR = planWechat(files(["game.js", 1], ["subpackage/art/t.png", 1]), {
    main: ["*.js"],
    subpackages: [{ name: "art", match: ["subpackage/art/t.png"] }],
  });
  assert.equal(okR.ok, true, okR.ok ? "" : okR.error.map((e) => e.code).join(","));
});

test("[打包] ★ 分包的 root 不能相同或互相嵌套（嵌套时内层文件被外层吃掉，日志看不出来）", () => {
  const same = planWechat(files(["game.js", 1], ["a/x.png", 1], ["b/y.png", 1]), {
    main: ["*.js"],
    subpackages: [
      { name: "p", match: ["a/"], root: "shared" },
      { name: "q", match: ["b/"], root: "shared" },
    ],
  });
  assert.ok(codes(same).includes(PACK_BAD_CONFIG));

  const nested = planWechat(files(["game.js", 1], ["a/x.png", 1], ["a/b/y.png", 1]), {
    main: ["*.js"],
    subpackages: [
      { name: "outer", match: ["a/"] },
      { name: "inner", match: ["a/b/"] },
    ],
  });
  assert.ok(codes(nested).includes(PACK_BAD_CONFIG), "a/ 与 a/b/ 是嵌套 root");
});

test("[打包] ★ 没有归属的文件是错误，而且一次把所有文件都列出来", () => {
  const r = planWechat(files(["game.js", 1], ["assets/tree.png", 2], ["assets/rock.png", 3]), CFG);
  assert.deepEqual(codes(r), [PACK_UNMATCHED]);
  const msg = (r as unknown as { error: { message: string }[] }).error[0]!.message;
  assert.match(msg, /assets\/rock\.png/, "两个漏掉的文件都要在报错里，不然要跑好几轮才补齐");
  assert.match(msg, /assets\/tree\.png/);
});

test("[打包] 空 staging 直接拒绝（不产出空包）", () => {
  assert.deepEqual(codes(planWechat([], CFG)), [PACK_EMPTY]);
});

test("[打包] ★ 同一文件命中两个分包是错误（它到底在哪个包里说不清）", () => {
  const r = planWechat(files(["game.js", 1], ["assets/shared.png", 1]), {
    main: ["*.js"],
    subpackages: [
      { name: "a", match: ["assets/"] },
      { name: "b", match: ["*.png"] },
    ],
  });
  assert.deepEqual(codes(r), [PACK_DUPLICATE]);
});

test("[打包] 分包名重复 / 空名 / 没有规则都拒绝", () => {
  assert.deepEqual(
    codes(planWechat(files(["a.js", 1]), { main: ["*.js"], subpackages: [{ name: "x", match: ["*."] }] })),
    [PACK_BAD_CONFIG],
    "*. 没有后缀是坏规则",
  );
  assert.deepEqual(
    codes(
      planWechat(files(["a.js", 1]), {
        main: ["*.js"],
        subpackages: [
          { name: "dup", match: ["a/"] },
          { name: "dup", match: ["b/"] },
        ],
      }),
    ),
    [PACK_BAD_CONFIG],
  );
  assert.deepEqual(
    codes(planWechat(files(["a.js", 1]), { main: ["*.js"], subpackages: [{ name: "  ", match: ["a/"] }] })),
    [PACK_BAD_CONFIG],
  );
});

// ---------------------------------------------------------------- 预算

test("[打包] ★ 主包预算：正好 4MB 通过，4MB+1 字节失败（差一字节是这类规则唯一会错的地方）", () => {
  const ok = planWechat(files(["game.js", WECHAT_LIMITS.mainPackage]), { main: ["*.js"], subpackages: [] });
  assert.equal(ok.ok, true, ok.ok ? "" : ok.error.map((e) => e.code).join(","));

  const over = planWechat(files(["game.js", WECHAT_LIMITS.mainPackage + 1]), { main: ["*.js"], subpackages: [] });
  assert.deepEqual(codes(over), [PACK_OVER_MAIN]);
});

test("[打包] ★ 分包预算同理（单个分包 4MB 上限，与主包同值但含义不同）", () => {
  const ok = planWechat(files(["a.js", 1], ["assets/big.bin", WECHAT_LIMITS.subPackage]), {
    main: ["*.js"],
    subpackages: [{ name: "big", match: ["assets/"] }],
  });
  assert.equal(ok.ok, true, ok.ok ? "" : ok.error.map((e) => e.code).join(","));

  const over = planWechat(files(["a.js", 1], ["assets/big.bin", WECHAT_LIMITS.subPackage + 1]), {
    main: ["*.js"],
    subpackages: [{ name: "big", match: ["assets/"] }],
  });
  assert.deepEqual(codes(over), [PACK_OVER_SUB]);
});

test("[打包] ★ 合计 30MB 上限：主包与分包都不超，加起来超了也要红", () => {
  // 主包 3.5MB（不超 4）+ 8 个分包各 3.5MB（都不超 4）= 31.5MB > 30MB
  const subs = Array.from({ length: 8 }, (_, i) => `big/s${String(i)}/`);
  const specs: [string, number][] = [["game.js", 3.5 * MB]];
  for (const d of subs) specs.push([`${d}x.bin`, 3.5 * MB]);
  const r = planWechat(files(...specs), {
    main: ["*.js"],
    subpackages: subs.map((d, i) => ({ name: `s${String(i)}`, match: [d] })),
  });
  assert.deepEqual(codes(r), [PACK_OVER_TOTAL]);
});

test("[打包] 超预算时**不返回半成品计划**（调用方拿不到「虽然超了但先给你用」的包）", () => {
  const r = planWechat(files(["game.js", WECHAT_LIMITS.mainPackage + 10]), { main: ["*.js"], subpackages: [] });
  assert.equal(r.ok, false);
  assert.equal("value" in r, false, "失败结果里不许带计划");
});

// ---------------------------------------------------------------- 后缀

test("[打包] 微信不收的后缀要点名报出来（上传失败的信息在控制台很靠后）", () => {
  const r = planWechat(files(["game.js", 1], ["notes.md", 1]), { main: ["*.js", "*.md"], subpackages: [] });
  assert.deepEqual(codes(r), [PACK_BAD_EXT]);
  const msg = (r as unknown as { error: { message: string }[] }).error[0]!.message;
  assert.match(msg, /notes\.md/);
  assert.match(msg, /\.md/);
  assert.equal(WECHAT_EXT_WHITELIST.includes(".md"), false);
});

test("[打包] 白名单里的后缀通过，且大小写不敏感", () => {
  for (const ext of [".js", ".json", ".png", ".bin", ".fnt", ".wasm"]) {
    assert.equal(WECHAT_EXT_WHITELIST.includes(ext), true, `${ext} 应该在白名单里`);
  }
  const r = planWechat(files(["game.js", 1], ["A.PNG", 1]), { main: ["*.js", "*.PNG"], subpackages: [] });
  assert.equal(r.ok, true, r.ok ? "" : r.error.map((e) => e.code).join(","));
});

// ---------------------------------------------------------------- game.json

test("[打包] game.json：分包 root 与规划一致，字段顺序固定 ⇒ 逐字节可复现", () => {
  const r = planWechat(files(["game.js", 1], ["assets/terrain/t.png", 1]), CFG);
  assert.equal(r.ok, true);
  const plan = r.ok ? r.value : null;
  assert.ok(plan !== null);
  const a = renderGameJson(plan, { ...CFG, deviceOrientation: "portrait" });
  const b = renderGameJson(plan, { ...CFG, deviceOrientation: "portrait" });
  assert.equal(a, b, "两次生成必须逐字节相同（要能进版本库、能 diff）");
  const obj = JSON.parse(a) as { deviceOrientation: string; subpackages: { name: string; root: string }[] };
  assert.equal(obj.deviceOrientation, "portrait");
  assert.deepEqual(obj.subpackages, [{ name: "terrain", root: "assets/terrain" }]);
});

test("[打包] 显式写 root 时以配置为准（不能一边写 root 一边用默认值）", () => {
  const r = planWechat(files(["game.js", 1], ["assets/terrain/t.png", 1]), {
    main: ["*.js"],
    subpackages: [{ name: "terrain", match: ["assets/terrain/"], root: "assets/terrain" }],
  });
  assert.equal(r.ok, true, r.ok ? "" : r.error.map((e) => e.code).join(","));
  const root = r.ok ? r.value.subpackages[0]!.root : "";
  assert.equal(root, "assets/terrain");

  // 显式 root 与文件位置不符 ⇒ 拒绝（而不是按名字猜一个）
  const bad = planWechat(files(["game.js", 1], ["assets/terrain/t.png", 1]), {
    main: ["*.js"],
    subpackages: [{ name: "terrain", match: ["assets/terrain/"], root: "pkg/terrain" }],
  });
  assert.deepEqual(codes(bad), [PACK_MISPLACED]);
});

// ---------------------------------------------------------------- 小游戏 API 扫描

test("[打包] ★ 扫描能报出浏览器专有 API，且带行号（要能直接跳过去改）", () => {
  const src = ["const a = 1;", "const c = document.createElement('canvas');", "window.x = 1;", "eval('1')"].join("\n");
  const hits = scanMiniGameSource(src);
  const apis = hits.map((h) => h.api);
  assert.ok(apis.includes("document."));
  assert.ok(apis.includes("window."));
  assert.equal(hits.find((h) => h.api === "document.")?.line, 2, "行号从 1 起");
  assert.equal(hits.find((h) => h.api === "eval(")?.line, 4);
});

test("[打包] 干净的源码扫不出东西（判据不能恒有命中）", () => {
  assert.deepEqual(scanMiniGameSource("const a = globalThis.wx; function f(){ return 1; }"), []);
  assert.ok(FORBIDDEN_IN_MINIGAME.length >= 5);
});

// ---------------------------------------------------------------- Steam VDF

test("[打包] app_build.vdf 含必需键，depot 清单与传入一致", () => {
  const text = renderAppBuildVdf({
    appId: 480,
    desc: "测试构建",
    buildOutput: "out/steam_output",
    contentRoot: "out",
    depots: [{ depotId: 481, file: "depot_build_481.vdf" }],
    setLive: "beta",
  });
  for (const key of ["appbuild", "appid", "desc", "buildoutput", "contentroot", "setlive", "depots"]) {
    assert.ok(text.includes(`"${key}"`), `VDF 里必须有 ${key}`);
  }
  assert.ok(text.includes('"481"'));
  assert.ok(text.includes('"depot_build_481.vdf"'));
  assert.equal(checkVdf(text), null, "自己生成的 VDF 必须能过结构自检");
});

test("[打包] ★ 同样的配置两次生成逐字节相同（VDF 不许带时间戳，否则每次打包都脏一个文件）", () => {
  const a = renderAppBuildVdf({ appId: 1, desc: "d", buildOutput: "o", contentRoot: "c", depots: [] });
  const b = renderAppBuildVdf({ appId: 1, desc: "d", buildOutput: "o", contentRoot: "c", depots: [] });
  assert.equal(a, b);
  assert.equal(/\d{4}-\d{2}-\d{2}/.test(a), false, "出现日期就一定不可复现");
});

test("[打包] 不给 setLive 时不写这个键（default 分支不许自动发布）", () => {
  const t = renderAppBuildVdf({ appId: 1, desc: "", buildOutput: "o", contentRoot: "c", depots: [] });
  assert.equal(t.includes("setlive"), false);
});

test("[打包] depot_build.vdf 默认整目录递归，也支持指定子路径", () => {
  const all = renderDepotBuildVdf({ depotId: 7, contentRoot: "/c" });
  assert.ok(all.includes('"DepotID"'));
  assert.ok(all.includes('"*"'), "默认 LocalPath 是 *（整目录）");
  assert.ok(all.includes('"recursive"'));
  const sub = renderDepotBuildVdf({ depotId: 7, contentRoot: "/c", localPath: "assets", depotPath: "assets" });
  assert.ok(sub.includes('"assets"'));
  assert.equal(checkVdf(sub), null);
});

test("[打包] ★ checkVdf 能抓住括号不配平与引号不闭合（自己生成的永远是对的，判据要能红）", () => {
  assert.equal(checkVdf('"a"\n{\n"b"\t\t"c"\n}\n'), null);
  assert.match(checkVdf('"a"\n{\n"b"\t\t"c"\n') ?? "", /花括号没有配平/);
  assert.match(checkVdf('"a"\n}\n') ?? "", /多了一个/);
  assert.match(checkVdf('"a\n{\n}\n') ?? "", /引号没有闭合/);
});
