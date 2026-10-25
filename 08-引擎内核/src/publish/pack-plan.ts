/**
 * L5 · 发布：平台分包规划（Steam / 微信小游戏）
 *
 * 这一层的目标不是「打得出去」（那要 steamcmd 与微信开发者工具），而是
 * **在上传之前把一定会失败的事情变成一条明确的错误**。三件：
 *
 * ① **包体预算**。微信小游戏的限制是官方硬约束，不是建议：
 *    主包 ≤ 4MB、单个分包 ≤ 4MB、主包 + 全部分包 ≤ 30MB。超了在真机上就是
 *    「打开失败」，而开发机上永远看不出来 —— 所以必须在构建期拦。
 *
 * ② **每个文件都要有归属**。分包规则没覆盖到的文件不许静默丢掉：
 *    「少了一个资产」在真机上表现为某个贴图变成空白的白块，而日志里一片安静。
 *    所以未匹配是一个**错误**，并且把所有未匹配文件一次列出来。
 *
 * ③ **同一份输入两次打包结果逐字节相同**。产物要能进版本库、能 diff ——
 *    这与 `build.ts` 的「内容寻址 + 不重写」是同一条纪律。
 *
 * ★ 这一层不认识文件系统（读盘在 `tools/pack.mjs`），只处理
 *   「路径 + 字节数」的列表。于是它能在 Node 里被逐条钉住，
 *   而平台限制的数值只在这里写一次。
 */

import { engineError, err, ok, type EngineError, type Result } from "../foundation/result.ts";

/** 微信小游戏官方硬约束（单位：字节）。三个数字都必须**照抄**，不许上调。 */
export const WECHAT_LIMITS = {
  mainPackage: 4 * 1024 * 1024,
  subPackage: 4 * 1024 * 1024,
  total: 30 * 1024 * 1024,
} as const;

/** 微信小游戏只接受这些后缀（官方白名单里允许上传的类型）。 */
export const WECHAT_EXT_WHITELIST: readonly string[] = [
  ".js",
  ".json",
  ".wasm",
  ".png",
  ".jpg",
  ".jpeg",
  ".gif",
  ".svg",
  ".txt",
  ".mp3",
  ".ogg",
  ".wav",
  ".m4a",
  ".ttf",
  ".fnt",
  ".bin",
];

export const PACK_EMPTY = "PACK.EMPTY";
export const PACK_BAD_CONFIG = "PACK.BAD_CONFIG";
export const PACK_UNMATCHED = "PACK.UNMATCHED";
export const PACK_DUPLICATE = "PACK.DUPLICATE";
export const PACK_OVER_MAIN = "PACK.OVER_MAIN";
export const PACK_OVER_SUB = "PACK.OVER_SUB";
export const PACK_OVER_TOTAL = "PACK.OVER_TOTAL";
export const PACK_BAD_EXT = "PACK.BAD_EXT";
export const PACK_FORBIDDEN_API = "PACK.FORBIDDEN_API";
export const PACK_MISPLACED = "PACK.MISPLACED";

/** 分包根目录的默认值（与配置里的 `root` 同一个口径）。 */
export function defaultSubpackageRoot(name: string): string {
  return `subpackage/${name}`;
}

/**
 * 分包的实际 root。
 *
 * 优先用配置里显式写的；没写时：**只有一条规则且是 `dir/` 形状** ⇒ 就取这个目录
 * （`assets/terrain/` 的天然 root 就是 `assets/terrain`，写完规则不必再对齐第二处）。
 * 其余情况退回 `subpackage/<name>`，此时文件也必须放在那个目录下 ——
 * 微信本来就要求分包内容集中在一个目录里，这不是本工具的额外要求。
 */
export function subpackageRoot(s: SubpackageRule): string {
  if (s.root !== undefined) return s.root;
  if (s.match.length === 1) {
    const only = s.match[0]!;
    if (only.endsWith("/") && only.length > 1) return only.slice(0, -1);
  }
  return defaultSubpackageRoot(s.name);
}

/** 待打包的一个文件。`path` 用 `/` 分隔、相对 staging 根。 */
export interface StagedFile {
  readonly path: string;
  readonly bytes: number;
}

export interface SubpackageRule {
  readonly name: string;
  /** 该分包放哪些文件（匹配规则见文件头的说明）。 */
  readonly match: readonly string[];
  /**
   * 分包根目录，默认 `subpackage/<name>`。
   *
   * ★ 所有命中这个分包的文件**必须位于 root 之下**，否则报 `PACK.MISPLACED`。
   *   这条约束让「输出布局 = staging 布局」成为一个可以逐字节核对的事实：
   *   分包里的文件原样落到 `<root>/...`，与 `game.json` 声明的 root 天然对齐。
   *   不检查的后果是「打包成功、`game.json` 也写了、真机上分包加载不到」——
   *   而日志里一切正常。
   */
  readonly root?: string;
}

export interface WechatPackConfig {
  /** 主包的匹配规则。 */
  readonly main: readonly string[];
  readonly subpackages: readonly SubpackageRule[];
  readonly deviceOrientation?: "portrait" | "landscape";
}

export interface PackedPackage {
  readonly name: string;
  /** `null` = 主包。 */
  readonly root: string | null;
  readonly files: readonly StagedFile[];
  readonly bytes: number;
}

export interface WechatPlan {
  readonly main: PackedPackage;
  readonly subpackages: readonly PackedPackage[];
  readonly totalBytes: number;
}

// ---------------------------------------------------------------- 匹配

/**
 * 单条规则的匹配。
 *
 * 只支持三种形状，**其余形态直接报错**而不是「匹配不到就跳过」：
 * - `*.ext`：按后缀（大小写不敏感）
 * - `dir/`：目录前缀
 * - 其它：精确路径
 *
 * ★ 不支持通配符是有意的：写一个 `assets/**` 然后它一条都没匹配上，
 *   是最典型的「配置看起来对、包内容少了东西」的来源。宁可报「不认识的规则」。
 */
export function matchRule(rule: string, path: string): boolean {
  if (rule.startsWith("*.")) return path.toLowerCase().endsWith(rule.slice(1).toLowerCase());
  if (rule.endsWith("/")) return path.startsWith(rule);
  return path === rule;
}

/** 规则里有没有不认识的写法（有就拒绝整个配置）。 */
export function ruleProblem(rule: string): string | null {
  if (rule.length === 0) return "规则为空";
  if (rule.startsWith("*.")) {
    return rule.length > 2 ? null : `规则 ${rule} 没有后缀`;
  }
  if (rule.includes("*")) return `规则 ${rule} 里只允许最前面的 *.ext 形式`;
  return null;
}

function extOf(path: string): string {
  const i = path.lastIndexOf(".");
  const slash = path.lastIndexOf("/");
  if (i <= slash) return "";
  return path.slice(i).toLowerCase();
}

// ---------------------------------------------------------------- 分包规划

/**
 * 规划微信小游戏的分包。
 *
 * 冲突处理：一个文件同时命中**两个分包**是配置错（`PACK.DUPLICATE`），
 * 因为「它到底在哪个包里」会变成规则声明顺序的隐式约定。
 * 命中「分包 + 主包」则分包优先（子包覆盖主包是常见意图），不报错。
 */
export function planWechat(
  files: readonly StagedFile[],
  cfg: WechatPackConfig,
): Result<WechatPlan, readonly EngineError[]> {
  const problems: EngineError[] = [];

  if (files.length === 0) {
    return err([engineError(PACK_EMPTY, "没有可打包的文件（staging 目录是空的？）")]);
  }
  const seen = new Set<string>();
  for (const f of files) {
    if (seen.has(f.path)) {
      problems.push(engineError(PACK_DUPLICATE, `文件 ${f.path} 在输入里出现了两次`));
    }
    seen.add(f.path);
  }

  for (const r of cfg.main) {
    const p = ruleProblem(r);
    if (p !== null) problems.push(engineError(PACK_BAD_CONFIG, `主包${p}`));
  }
  for (const s of cfg.subpackages) {
    if (s.name.trim() === "") problems.push(engineError(PACK_BAD_CONFIG, "分包名不能为空"));
    if (s.match.length === 0) problems.push(engineError(PACK_BAD_CONFIG, `分包 ${s.name} 没有任何匹配规则`));
    const root = subpackageRoot(s);
    if (root.trim() === "") problems.push(engineError(PACK_BAD_CONFIG, `分包 ${s.name} 的 root 不能为空`));
    else if (root.startsWith("/") || root.endsWith("/")) {
      problems.push(engineError(PACK_BAD_CONFIG, `分包 ${s.name} 的 root ${root} 不能以 / 开头或结尾`));
    }
    for (const r of s.match) {
      const p = ruleProblem(r);
      if (p !== null) problems.push(engineError(PACK_BAD_CONFIG, `分包 ${s.name}：${p}`));
    }
  }
  if (problems.length > 0) return err(problems);

  const names = new Set<string>();
  const roots: { name: string; root: string }[] = [];
  for (const s of cfg.subpackages) {
    if (names.has(s.name)) problems.push(engineError(PACK_BAD_CONFIG, `分包名 ${s.name} 重复`));
    names.add(s.name);
    roots.push({ name: s.name, root: subpackageRoot(s) });
  }
  // ★ 分包的 root 之间不能相同、不能互相嵌套：微信对嵌套 root 的处理是
  //   「内层文件被外层吃掉」，而 game.json 里两个分包都声明得通 —— 静默失效。
  for (let i = 0; i < roots.length; i++) {
    for (let j = i + 1; j < roots.length; j++) {
      const a = roots[i]!;
      const b = roots[j]!;
      if (a.root === b.root) {
        problems.push(engineError(PACK_BAD_CONFIG, `分包 ${a.name} 与 ${b.name} 的 root 都是 ${a.root}`));
      } else if (a.root.startsWith(`${b.root}/`) || b.root.startsWith(`${a.root}/`)) {
        problems.push(
          engineError(
            PACK_BAD_CONFIG,
            `分包 root ${a.root}（${a.name}）与 ${b.root}（${b.name}）互相嵌套 —— 内层文件会被外层吃掉`,
          ),
        );
      }
    }
  }

  const subFiles = new Map<string, StagedFile[]>();
  for (const s of cfg.subpackages) subFiles.set(s.name, []);
  const mainFiles: StagedFile[] = [];
  const unmatched: string[] = [];

  // 按 path 升序处理 ⇒ 同一个 staging 目录两次规划得到同样的包内容顺序
  for (const f of [...files].sort((a, b) => (a.path < b.path ? -1 : a.path > b.path ? 1 : 0))) {
    const hits = cfg.subpackages.filter((s) => s.match.some((r) => matchRule(r, f.path)));
    if (hits.length > 1) {
      problems.push(
        engineError(
          PACK_DUPLICATE,
          `文件 ${f.path} 同时命中分包 ${hits.map((h) => h.name).join(" / ")} —— 它到底在哪个包里说不清`,
        ),
      );
      continue;
    }
    if (hits.length === 1) {
      const hit = hits[0]!;
      const root = subpackageRoot(hit);
      // ★ 文件必须在自己的 root 之下：否则「包里有这个文件」与「game.json 声明的 root
      //   指向别处」两件事同时成立，真机上结局是分包加载失败 —— 而打包这一步全绿。
      if (!f.path.startsWith(`${root}/`)) {
        problems.push(
          engineError(
            PACK_MISPLACED,
            `文件 ${f.path} 命中分包 ${hit.name}，但它不在分包根 ${root}/ 之下` +
              ` —— 分包内容会落到 ${root}/ 之外，真机上加载不到`,
          ),
        );
        continue;
      }
      subFiles.get(hit.name)!.push(f);
      continue;
    }
    if (cfg.main.some((r) => matchRule(r, f.path))) {
      mainFiles.push(f);
      continue;
    }
    unmatched.push(f.path);
  }

  if (unmatched.length > 0) {
    problems.push(
      engineError(
        PACK_UNMATCHED,
        `${String(unmatched.length)} 个文件没有归属：${unmatched.slice(0, 8).join("、")}${
          unmatched.length > 8 ? " …" : ""
        }`,
      ),
    );
  }

  const sum = (xs: readonly StagedFile[]): number => xs.reduce((n, f) => n + f.bytes, 0);
  const mainPkg: PackedPackage = { name: "main", root: null, files: mainFiles, bytes: sum(mainFiles) };
  const subs: PackedPackage[] = cfg.subpackages.map((s) => {
    const fs = subFiles.get(s.name)!;
    return { name: s.name, root: subpackageRoot(s), files: fs, bytes: sum(fs) };
  });
  const totalBytes = mainPkg.bytes + subs.reduce((n, p) => n + p.bytes, 0);

  // ---- 预算（官方硬约束，一个字节都不放宽）
  if (mainPkg.bytes > WECHAT_LIMITS.mainPackage) {
    problems.push(
      engineError(
        PACK_OVER_MAIN,
        `主包 ${fmt(mainPkg.bytes)} 超过 4MB（超 ${fmt(mainPkg.bytes - WECHAT_LIMITS.mainPackage)}）` +
          "—— 请把大资产挪进分包，主包放不下时真机会直接打不开",
      ),
    );
  }
  for (const p of subs) {
    if (p.bytes > WECHAT_LIMITS.subPackage) {
      problems.push(
        engineError(
          PACK_OVER_SUB,
          `分包 ${p.name} ${fmt(p.bytes)} 超过 4MB（超 ${fmt(p.bytes - WECHAT_LIMITS.subPackage)}）`,
        ),
      );
    }
  }
  if (totalBytes > WECHAT_LIMITS.total) {
    problems.push(
      engineError(PACK_OVER_TOTAL, `主包 + 分包合计 ${fmt(totalBytes)} 超过 30MB（超 ${fmt(totalBytes - WECHAT_LIMITS.total)}）`),
    );
  }

  // ---- 后缀白名单（微信不接受的后缀上传会失败，而失败信息在控制台里很靠后）
  for (const f of files) {
    const e = extOf(f.path);
    if (e !== "" && !WECHAT_EXT_WHITELIST.includes(e)) {
      problems.push(engineError(PACK_BAD_EXT, `${f.path} 的后缀 ${e} 不在微信允许的列表里`));
    }
  }

  if (problems.length > 0) return err(problems);
  return ok({ main: mainPkg, subpackages: subs, totalBytes });
}

function fmt(n: number): string {
  if (n < 1024) return `${String(n)}B`;
  if (n < 1024 * 1024) return `${(n / 1024).toFixed(1)}KB`;
  return `${(n / (1024 * 1024)).toFixed(2)}MB`;
}

/** `game.json`（微信小游戏的入口配置）。字段顺序固定 ⇒ 逐字节可复现。 */
export function renderGameJson(plan: WechatPlan, cfg: WechatPackConfig): string {
  const obj = {
    deviceOrientation: cfg.deviceOrientation ?? "landscape",
    showStatusBar: false,
    networkTimeout: { request: 10000 },
    subpackages: plan.subpackages.map((p) => ({ name: p.name, root: p.root })),
  };
  return `${JSON.stringify(obj, null, 2)}\n`;
}

// ---------------------------------------------------------------- 小游戏运行环境

/** 微信小游戏里**不存在**的浏览器 API（命中就得改代码，不是改配置）。 */
export const FORBIDDEN_IN_MINIGAME: readonly string[] = [
  "document.",
  "window.",
  "XMLHttpRequest",
  "localStorage",
  "sessionStorage",
  "new Function",
  "eval(",
];

export interface ApiHit {
  readonly api: string;
  /** 命中位置所在的行号（从 1 起，方便人直接跳过去）。 */
  readonly line: number;
}

/**
 * 扫一遍要上小游戏的 JS 源码，把「这个环境里没有」的 API 找出来。
 *
 * ★ 这是**诊断**而不是编码器：它不假装能修好。当前这份 bundle 走的是浏览器宿主
 *   （`document.createElement("canvas")` 建画布），所以它一定会命中 ——
 *   那正是「上微信小游戏」真正的工作量：需要一个 `host-wx` 适配层，
 *   而不是一个打包脚本。把这件事说清楚，比写一个扫不出东西的检查有用得多。
 */
export function scanMiniGameSource(source: string): readonly ApiHit[] {
  const hits: ApiHit[] = [];
  const lines = source.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i]!;
    for (const api of FORBIDDEN_IN_MINIGAME) {
      if (line.includes(api)) hits.push({ api, line: i + 1 });
    }
  }
  return hits;
}

// ---------------------------------------------------------------- Steam

export interface AppBuildOptions {
  readonly appId: number;
  readonly desc: string;
  /** 上传产物的输出目录（steamcmd 会把 chunk 写进去）。 */
  readonly buildOutput: string;
  readonly contentRoot: string;
  readonly depots: readonly { readonly depotId: number; readonly file: string }[];
  /** 只对 beta 分支有效：default 分支必须人工在后台点发布。 */
  readonly setLive?: string;
  readonly preview?: number;
}

function vdfStr(v: string): string {
  // Valve 的 VDF 用双引号包值，内部引号要转义
  return `"${v.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function q(k: string, v: string | number): string {
  return `\t${vdfStr(k)}\t\t${vdfStr(String(v))}`;
}

/**
 * `app_build_<appid>.vdf`（SteamPipe 的入口）。
 *
 * ★ 缩进用**制表符**：Valve 的解析器容忍空格，但官方模板全是 tab，
 *   混用之后 `steamcmd` 的报错行号会跳，排查时白费时间。
 * ★ 返回值以 `\n` 结尾且不含时间戳 ⇒ 同样的配置两次生成逐字节相同（可 diff）。
 */
export function renderAppBuildVdf(o: AppBuildOptions): string {
  const lines: string[] = [];
  lines.push(vdfStr("appbuild"));
  lines.push("{");
  lines.push(q("appid", o.appId));
  lines.push(q("desc", o.desc));
  lines.push(q("buildoutput", o.buildOutput));
  lines.push(q("contentroot", o.contentRoot));
  if (o.preview !== undefined) lines.push(q("preview", o.preview));
  // ★ SetLive 只对 beta 分支自动生效；default 必须人工发布 —— 所以它是一个可选字段
  if (o.setLive !== undefined) lines.push(q("setlive", o.setLive));
  lines.push(`\t${vdfStr("depots")}`);
  lines.push("\t{");
  for (const d of o.depots) lines.push(`\t\t${vdfStr(String(d.depotId))}\t\t${vdfStr(d.file)}`);
  lines.push("\t}");
  lines.push("}");
  return `${lines.join("\n")}\n`;
}

export interface DepotBuildOptions {
  readonly depotId: number;
  readonly contentRoot: string;
  /** `null` = 整个 contentroot 递归（`LocalPath "*"`）。 */
  readonly localPath?: string;
  readonly depotPath?: string;
}

export function renderDepotBuildVdf(o: DepotBuildOptions): string {
  const lines: string[] = [];
  lines.push(vdfStr("DepotBuildConfig"));
  lines.push("{");
  lines.push(q("DepotID", o.depotId));
  lines.push(q("ContentRoot", o.contentRoot));
  lines.push(`\t${vdfStr("FileMapping")}`);
  lines.push("\t{");
  lines.push(`\t\t${vdfStr("LocalPath")}\t\t${vdfStr(o.localPath ?? "*")}`);
  lines.push(`\t\t${vdfStr("DepotPath")}\t\t${vdfStr(o.depotPath ?? ".")}`);
  lines.push(`\t\t${vdfStr("recursive")}\t\t${vdfStr("1")}`);
  lines.push("\t}");
  lines.push("}");
  return `${lines.join("\n")}\n`;
}

/**
 * VDF 结构自检：括号配平、引号成对。
 *
 * ★ 为什么不用一个完整的 VDF 解析器：这里要回答的问题只有一个 ——
 *   「我生成的这份文件 steamcmd 会不会在第三行就报语法错」。
 *   配平与引号是这类错误里唯一常见的两种；写一个完整解析器只会引入
 *   它自己的 bug，而真正的验证只有 `steamcmd +run_app_build` 那一次。
 */
export function checkVdf(text: string): string | null {
  let depth = 0;
  let inQuote = false;
  for (let i = 0; i < text.length; i++) {
    const c = text[i]!;
    if (c === '"' && text[i - 1] !== "\\") inQuote = !inQuote;
    if (inQuote) continue;
    if (c === "{") depth++;
    else if (c === "}") {
      depth--;
      if (depth < 0) return `第 ${String(i)} 个字符处多了一个 }`;
    }
  }
  if (inQuote) return "有一个引号没有闭合";
  if (depth !== 0) return `花括号没有配平（还剩 ${String(depth)} 层没关）`;
  return null;
}
