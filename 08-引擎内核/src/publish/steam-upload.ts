/**
 * L7 · 发布：Steam 上传（`steamcmd +run_app_build`）的**参数构造**
 *
 * 这一层解决一个很具体的问题：**VDF 生成对了，命令拼错了**。
 * 打包脚本到此为止都是「生成几个文件」，而真正上传的那一步是一条外部命令，
 * 它错起来不像代码错 —— 没有异常、没有栈，只有一行看不懂的 steamcmd 输出，
 * 或者更糟：**什么都不输出，进程挂着不动**。
 *
 * 三类错误在这层被提前拦掉：
 *
 * ① **`+quit` 忘了 / 放错位置**。steamcmd 是交互式 REPL：参数按 `+cmd` 顺序执行，
 *    末尾没有 `+quit` 就停在提示符上等输入。CI 里表现为「日志停在最后一行、一直不结束」，
 *    直到超时被杀 —— 而日志里没有任何错误。所以 `+quit` 必须由构造器**追加**，
 *    不允许调用方自己拼。
 *
 * ② **把密码放进 argv**。`+login <user> <pass>` 会让密码出现在 `ps`、
 *    `/proc/<pid>/cmdline`、以及 CI 的完整命令行日志里。这一层只传用户名，
 *    密码留给 steamcmd 自己交互（或 Steam Guard 缓存）。少一个"很方便"的参数，
 *    换掉一整类凭据泄漏。
 *
 * ③ **路径不是绝对的 / 带引号**。steamcmd 会 chdir，相对路径的 vdf 它找不到；
 *    而带 `"` 的路径不能靠"转义"猜 —— 不同平台对引号的解释不一样，
 *    猜错的表现是 steamcmd 收到一段被截断的路径，然后报「找不到文件」，
 *    和"路径真的不存在"完全分不清。所以含引号直接拒绝。
 *
 * ★ 一个容易写反的细节：**给人看的命令行**与**真正 spawn 的 argv** 是两件事。
 *   `spawnSync(cmd, argv)` 不经过 shell，argv 元素原样传下去 —— 此时给
 *   `C:\Program Files\x.vdf` 加引号，steamcmd 收到的就是**带引号的字符串**。
 *   反之打印出来让人复制到 shell 里跑的版本**必须**加引号。
 *   所以这里是两个函数：`buildSteamCmdArgv`（无引号）与
 *   `renderSteamCommandLine`（有引号，只用于显示）。
 */

import { engineError, err, ok, type EngineError, type Result } from "../foundation/result.ts";

export const STEAM_UPLOAD_ERR = {
  /** 登录名不像个登录名（含空格 / 引号 / 为空）。 */
  BAD_LOGIN: "STEAM.BAD_LOGIN",
  /** app_build 的路径不是绝对路径，或后缀不是 .vdf。 */
  BAD_VDF: "STEAM.BAD_VDF",
  /** 参数本身不可用（空串 / 含双引号）。 */
  BAD_ARG: "STEAM.BAD_ARG",
  /** 找不到 steamcmd 可执行文件（环境问题，不是打包问题）。 */
  NO_STEAMCMD: "STEAM.NO_STEAMCMD",
} as const;

/**
 * 路径是不是"绝对路径的样子"。
 *
 * ★ 不用 `node:path.isAbsolute`：这一层只许依赖 L0（它要在没有引擎、
 *   甚至没有完整 Node 平台层的环境里跑），而且我们要判断的是**字符串**，
 *   不是"在**当前**平台上的绝对路径" —— 一条 Windows 路径出现在 POSIX 上
 *   仍然是我们想拒绝的那种"看起来像绝对路径"之外的东西吗？不是：
 *   我们只关心"它会不会被 steamcmd 当成相对路径"，两种绝对形式都算。
 */
export function isAbsolutePathLike(p: string): boolean {
  if (p.startsWith("/")) return true;
  // UNC（`\\server\share\...`）：网络盘上的构建目录是真实场景，
  // 少了这一条会被判成相对路径，报错信息还会说"steamcmd 会 chdir" —— 驴唇不对马嘴。
  if (p.startsWith("\\\\")) return true;
  return /^[A-Za-z]:[\\/]/.test(p);
}

/** 含空白（空格 / 制表符 / 换行）的参数在命令行里需要引号。 */
function needsQuoting(a: string): boolean {
  return /\s/.test(a);
}

function checkArg(what: string, a: string): EngineError | null {
  if (a === "") return engineError(STEAM_UPLOAD_ERR.BAD_ARG, `${what}是空串`);
  // 换行会让命令在 shell 里断成两条（复制粘贴时最常见），引号则无法可靠转义
  if (a.includes("\n") || a.includes("\r")) return engineError(STEAM_UPLOAD_ERR.BAD_ARG, `${what}里含换行：${a}`);
  if (a.includes('"')) {
    return engineError(
      STEAM_UPLOAD_ERR.BAD_ARG,
      `${what}里含双引号，拒绝猜测怎么转义（不同平台规则不同，猜错的表现是「找不到文件」）：${a}`,
    );
  }
  return null;
}

export interface SteamUploadOptions {
  /** `app_build_<appid>.vdf` 的**绝对**路径。 */
  readonly appBuildVdf: string;
  /** Steam 账号名；缺省 `anonymous`（专用服务器/公开工具用得上，游戏上传统统需要真账号）。 */
  readonly login?: string;
}

export interface SteamCommand {
  readonly login: string;
  /** 真正交给 `spawnSync` 的 argv（**不带引号**）。 */
  readonly argv: readonly string[];
}

/**
 * 构造 `steamcmd` 的参数。
 *
 * 顺序固定为：`+login <user>` → `+run_app_build <vdf>` → `+quit`。
 * 失败时**一次返回全部问题**（登录名和路径可以同时错，一次说清比来回跑两趟好）。
 */
export function buildSteamCmdArgv(o: SteamUploadOptions): Result<SteamCommand, readonly EngineError[]> {
  const problems: EngineError[] = [];
  const login = o.login ?? "anonymous";

  if (login.trim() === "") {
    problems.push(engineError(STEAM_UPLOAD_ERR.BAD_LOGIN, "登录名不能为空（上传统统需要真账号，匿名只能下专用服务器）"));
  } else if (needsQuoting(login)) {
    // ★ 含空格的登录名不是"引号能救"的问题：steamcmd 会把后半截当成**密码**，
    //   于是失败信息是「登录失败」，看起来像密码错 —— 极难归因。
    problems.push(engineError(STEAM_UPLOAD_ERR.BAD_LOGIN, `登录名不能含空白（后半截会被当成密码）：${login}`));
  } else if (login.includes('"')) {
    problems.push(engineError(STEAM_UPLOAD_ERR.BAD_LOGIN, `登录名不能含双引号：${login}`));
  }

  if (!isAbsolutePathLike(o.appBuildVdf)) {
    problems.push(
      engineError(
        STEAM_UPLOAD_ERR.BAD_VDF,
        `app_build 的路径必须是绝对路径（steamcmd 会 chdir，相对路径它找不到）：${o.appBuildVdf}`,
      ),
    );
  } else if (!o.appBuildVdf.toLowerCase().endsWith(".vdf")) {
    problems.push(engineError(STEAM_UPLOAD_ERR.BAD_VDF, `app_build 的后缀必须是 .vdf：${o.appBuildVdf}`));
  }

  const vdfProblem = checkArg("vdf 路径", o.appBuildVdf);
  if (vdfProblem !== null) problems.push(vdfProblem);

  if (problems.length > 0) return err(problems);

  return ok({
    login,
    // ★ `+quit` 由这里追加，**不接受调用方传入** —— 它是唯一一个"忘了就挂住"的参数
    argv: ["+login", login, "+run_app_build", o.appBuildVdf, "+quit"],
  });
}

/**
 * 打印给人复制粘贴的命令行（**加引号**的那一版）。
 *
 * 与 `buildSteamCmdArgv` 的区别是实质性的，不是格式偏好：
 * 前者交给 `spawnSync`（不经 shell，加引号会让引号变成路径的一部分），
 * 后者给人贴进终端（不加引号会被 shell 拆成两个参数）。
 */
export function renderSteamCommandLine(argv: readonly string[], exe = "steamcmd"): string {
  const parts = [exe, ...argv].map((a) => (needsQuoting(a) ? `"${a}"` : a));
  return parts.join(" ");
}

// ---------------------------------------------------------------- 找 steamcmd

export interface PathLookup {
  /** 原样的 PATH 值（用 `sep` 切分）。 */
  readonly pathVar: string;
  /** 分隔符：Windows `;`、POSIX `:`。 */
  readonly sep: string;
  /** 依次尝试的后缀：Windows `["", ".exe", ".bat", ".cmd"]`、POSIX `[""]`。 */
  readonly exts: readonly string[];
}

/**
 * 在 PATH 里找可执行文件，返回**第一个**命中的完整路径；找不到返回 `null`。
 *
 * ★ **空条目一律跳过**。它在 POSIX 的 PATH 语义里表示"当前目录"——
 *   照那个语义去找，仓库里随便一个叫 `steamcmd` 的文件就会被执行；
 *   而按朴素拼接它又会变成根下的 `/steamcmd`（一个几乎不存在的垃圾路径）。
 *   两种解释都不该被执行：一条空条目能带来的只有"找到了错的东西"或"找不到"。
 *   这条规则不是洁癖 —— 上传步骤是带凭据跑的。
 * ★ 顺序按 PATH 的列写顺序、每个目录内按 `exts` 的顺序，**不排序** ——
 *   否则"先找到哪个"取决于字典序，与本机实际想用哪个版本无关。
 */
export function resolveExecutable(
  names: readonly string[],
  look: PathLookup,
  exists: (p: string) => boolean,
): string | null {
  for (const dir of look.pathVar.split(look.sep)) {
    if (dir === "") continue;
    const base = dir.replace(/[\\/]+$/, "");
    for (const name of names) {
      for (const ext of look.exts) {
        const full = `${base}/${name}${ext}`;
        if (exists(full)) return full;
      }
    }
  }
  return null;
}

/** 本机平台的查找口径（CLI 用；判据里直接构造 `PathLookup` 验各分支）。 */
export function defaultPathLookup(pathVar: string, platform: string): PathLookup {
  const win = platform === "win32";
  return { pathVar, sep: win ? ";" : ":", exts: win ? ["", ".exe", ".bat", ".cmd"] : [""] };
}

export const STEAMCMD_NAMES: readonly string[] = ["steamcmd"];
