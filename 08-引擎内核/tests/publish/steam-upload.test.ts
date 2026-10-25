/**
 * L7 · 发布：Steam 上传参数构造的判据
 *
 * 这一层验的不是"能不能上传"（那要真账号），而是**拼出去的命令对不对**。
 * 它是整条发布链上唯一"错了也不会抛异常"的一段：参数拼歪了，
 * steamcmd 会照跑，然后在某个与原因无关的地方失败 ——
 * 最坏的情况是**什么都不打印**，进程挂在提示符上直到超时。
 *
 * 所以这里的每条判据都对应一个真实症状：
 *   ① `+quit` 不在最后 ⇒ CI 挂住，日志没有任何错误；
 *   ② 密码进 argv ⇒ 出现在 `ps` / CI 命令行日志里；
 *   ③ 相对路径 ⇒ steamcmd chdir 后找不到 vdf；
 *   ④ 自己加引号 ⇒ spawn 不经 shell，引号成了路径的一部分；
 *   ⑤ PATH 里的空条目 ⇒ 在仓库里捡到一个叫 `steamcmd` 的文件然后执行它。
 */

import { test } from "node:test";
import assert from "node:assert/strict";

import {
  STEAM_UPLOAD_ERR,
  buildSteamCmdArgv,
  defaultPathLookup,
  isAbsolutePathLike,
  renderSteamCommandLine,
  resolveExecutable,
} from "../../src/publish/steam-upload.ts";

const VDF = "C:/build/steam_output/app_build_480.vdf";

function codes(r: { ok: boolean; error?: readonly { code: string }[] }): string[] {
  return r.ok ? [] : (r.error ?? []).map((e) => e.code);
}

// ---------------------------------------------------------------- argv 构造

test("[Steam上传] ★ 参数顺序固定，且 `+quit` 必须是最后一个", () => {
  const r = buildSteamCmdArgv({ appBuildVdf: VDF, login: "builder" });
  assert.equal(r.ok, true, r.ok ? "" : r.error.map((e) => e.message).join("；"));
  const argv = r.ok ? r.value.argv : [];
  assert.deepEqual(argv, ["+login", "builder", "+run_app_build", VDF, "+quit"]);

  // ★ 这两条是这条判据的重点，不是 deepEqual 的附庸：
  //   末尾少了 +quit ⇒ steamcmd 停在提示符上等输入（CI 挂到超时，日志无错）。
  assert.equal(argv[argv.length - 1], "+quit", "末尾不是 +quit：steamcmd 会停在提示符上等输入");
  assert.equal(argv.filter((a) => a === "+quit").length, 1, "+quit 只能出现一次（放两次 steamcmd 第二次会当未知命令）");
  // 顺序也必须对：+run_app_build 在 +login 之后（没登录就上传是另一类失败）
  assert.ok(argv.indexOf("+run_app_build") > argv.indexOf("+login"), "+run_app_build 必须在 +login 之后");
});

test("[Steam上传] 缺省登录名是 anonymous（并说明它只能下专用服务器）", () => {
  const r = buildSteamCmdArgv({ appBuildVdf: VDF });
  assert.equal(r.ok, true, r.ok ? "" : r.error.map((e) => e.code).join(","));
  assert.equal(r.ok ? r.value.login : "", "anonymous");
  assert.deepEqual(r.ok ? r.value.argv.slice(0, 2) : [], ["+login", "anonymous"]);
});

test("[Steam上传] ★★ 登录名含空格直接拒绝（引号救不了：后半截会被当成密码）", () => {
  // 这条不是"输入校验洁癖"：steamcmd 收到 3 个 token 时会把第 3 个当密码，
  // 于是失败信息是「登录失败」—— 看起来像密码错，排查方向全歪。
  const r = buildSteamCmdArgv({ appBuildVdf: VDF, login: "build bot" });
  assert.deepEqual(codes(r), [STEAM_UPLOAD_ERR.BAD_LOGIN]);
  assert.match(r.ok ? "" : r.error[0]!.message, /密码/, "报错要说清后果，不能只说「非法字符」");
});

test("[Steam上传] 登录名为空 / 全空白 / 含双引号 → BAD_LOGIN", () => {
  for (const login of ["", "   ", 'a"b']) {
    const r = buildSteamCmdArgv({ appBuildVdf: VDF, login });
    assert.deepEqual(codes(r), [STEAM_UPLOAD_ERR.BAD_LOGIN], `登录名 ${JSON.stringify(login)} 没被拒绝`);
  }
});

test("[Steam上传] ★★ 相对路径的 vdf 被拒绝（steamcmd 会 chdir，相对路径它找不到）", () => {
  for (const p of ["app_build_480.vdf", "./out/app_build_480.vdf", "C:out/app_build_480.vdf", "out\\a.vdf"]) {
    const r = buildSteamCmdArgv({ appBuildVdf: p });
    assert.deepEqual(codes(r), [STEAM_UPLOAD_ERR.BAD_VDF], `${p} 应该被判成非绝对路径`);
  }
});

test("[Steam上传] 后缀不是 .vdf → BAD_VDF（大小写不敏感）", () => {
  assert.deepEqual(codes(buildSteamCmdArgv({ appBuildVdf: "C:/x/app_build_480.txt" })), [STEAM_UPLOAD_ERR.BAD_VDF]);
  const upper = buildSteamCmdArgv({ appBuildVdf: "C:/x/APP_BUILD_480.VDF" });
  assert.equal(upper.ok, true, upper.ok ? "" : upper.error.map((e) => e.code).join(","));
});

test("[Steam上传] ★ 登录名与路径同时错时一次报全（不用来回跑两趟）", () => {
  const r = buildSteamCmdArgv({ appBuildVdf: "rel.vdf", login: "a b" });
  assert.deepEqual(codes(r), [STEAM_UPLOAD_ERR.BAD_LOGIN, STEAM_UPLOAD_ERR.BAD_VDF]);
});

test("[Steam上传] ★ 含双引号的路径拒绝对待，不做转义猜测", () => {
  const r = buildSteamCmdArgv({ appBuildVdf: 'C:/we"ird/app_build_480.vdf' });
  assert.deepEqual(codes(r), [STEAM_UPLOAD_ERR.BAD_ARG]);
});

test("[Steam上传] ★★ argv 里**不带引号**（spawn 不经 shell，加引号会变成路径的一部分）", () => {
  const spaced = "C:/Program Files/Steam/build/app_build_480.vdf";
  const r = buildSteamCmdArgv({ appBuildVdf: spaced });
  assert.equal(r.ok, true, r.ok ? "" : r.error.map((e) => e.code).join(","));
  const argv = r.ok ? r.value.argv : [];
  assert.equal(argv[3], spaced, "交给 spawn 的参数必须原样，不能带引号");
  assert.equal(
    argv.some((a) => a.startsWith('"')),
    false,
    "argv 里出现了引号 —— spawn 不解析引号，路径就真的变成带引号的了",
  );
});

test("[Steam上传] 给人复制的那一行**要**引号（与 argv 的差别是实质性的）", () => {
  const spaced = "C:/Program Files/Steam/build/app_build_480.vdf";
  const r = buildSteamCmdArgv({ appBuildVdf: spaced });
  assert.equal(r.ok, true);
  const line = renderSteamCommandLine(r.ok ? r.value.argv : []);
  assert.ok(line.startsWith("steamcmd +login anonymous +run_app_build "), line);
  assert.ok(line.includes(`"${spaced}"`), `含空格的路径没加引号，贴进终端会被拆成两个参数：${line}`);
  assert.ok(line.endsWith(" +quit"), "+quit 必须在最后");
  // 不带空格的参数不许被无谓地加引号（否则复制出来难看且容易误读）
  assert.ok(line.includes("+login anonymous"), line);
});

// ---------------------------------------------------------------- 绝对路径判定

test("[Steam上传] 绝对路径的几种形态：POSIX / 盘符 / UNC", () => {
  for (const p of ["/opt/build/a.vdf", "C:/b/a.vdf", "c:\\b\\a.vdf", "\\\\nas\\share\\a.vdf"]) {
    assert.equal(isAbsolutePathLike(p), true, `${p} 应该算绝对路径`);
  }
  for (const p of ["a.vdf", "./a.vdf", "../a.vdf", "C:a.vdf", "\\\\", "/"]) {
    // `\\` 与 `/` 单独出现时算绝对（根）—— 但后面会因为不是 .vdf 被另一条规则拒绝
    const expect = p === "\\\\" || p === "/";
    assert.equal(isAbsolutePathLike(p), expect, `${p} 判定错了`);
  }
});

// ---------------------------------------------------------------- 找 steamcmd

const existsIn = (set: readonly string[]) => (p: string) => set.includes(p);

test("[Steam上传] PATH 查找：按列写顺序命中第一个，不排序", () => {
  const set = ["/usr/games/steamcmd", "/usr/local/bin/steamcmd"];
  const found = resolveExecutable(["steamcmd"], { pathVar: "/usr/local/bin:/usr/games", sep: ":", exts: [""] }, existsIn(set));
  assert.equal(found, "/usr/local/bin/steamcmd", "没有按 PATH 的列写顺序找");
  const rev = resolveExecutable(["steamcmd"], { pathVar: "/usr/games:/usr/local/bin", sep: ":", exts: [""] }, existsIn(set));
  assert.equal(rev, "/usr/games/steamcmd");
});

test("[Steam上传] ★★ 跳过 PATH 里的空条目（空段既不是当前目录、也不是根，拼出来的全是垃圾路径）", () => {
  // 空条目按朴素拼接会变成 `/steamcmd`；按 POSIX 语义它是"当前目录"（= 仓库）。
  // 两种解释都会指向一个**不是用户想用的**文件 —— 而这一步是带凭据执行的。
  //
  // ★ 语料必须让 `/steamcmd` **真的存在**，否则这条判据抓不到"没跳过"
  //   （第一次写的时候 `exists` 只认 `/repo/steamcmd`，变异后拼出 `/steamcmd`
  //    照样返回 false ⇒ 判据绿 ⇒ 假绿，被 M357 当场揪出来）。
  const found = resolveExecutable(["steamcmd"], { pathVar: ":/usr/bin:", sep: ":", exts: [""] }, (p) =>
    p === "/steamcmd" || p === "/usr/bin/steamcmd",
  );
  assert.equal(found, "/usr/bin/steamcmd", `空条目被拼成了 ${String(found)} —— 这是"找到了错的东西"`);
});

test("[Steam上传] Windows 后缀按 exts 的顺序试（不是按目录内容排序）", () => {
  const both = ["C:/tools/steamcmd", "C:/tools/steamcmd.exe"];
  const exeFirst = resolveExecutable(["steamcmd"], { pathVar: "C:/tools", sep: ";", exts: ["", ".exe"] }, existsIn(both));
  assert.equal(exeFirst, "C:/tools/steamcmd", "exts 顺序是 [\"\", \".exe\"] 时应该先试无后缀那个");
  const exeOnly = resolveExecutable(
    ["steamcmd"],
    { pathVar: "C:/tools", sep: ";", exts: [".exe"] },
    (p) => p === "C:/tools/steamcmd.exe",
  );
  assert.equal(exeOnly, "C:/tools/steamcmd.exe");
});

test("[Steam上传] 目录项带尾部斜杠不会拼出双斜杠；找不到返回 null", () => {
  const found = resolveExecutable(["steamcmd"], { pathVar: "C:/tools/", sep: ";", exts: [""] }, (p) =>
    p === "C:/tools/steamcmd",
  );
  assert.equal(found, "C:/tools/steamcmd", `拼出了双斜杠：${String(found)}`);
  assert.equal(resolveExecutable(["steamcmd"], { pathVar: "/usr/bin", sep: ":", exts: [""] }, () => false), null);
});

test("[Steam上传] 平台口径：Windows 用 `;` 与四个后缀，POSIX 用 `:` 与一个", () => {
  const win = defaultPathLookup("a;C:\\b", "win32");
  assert.equal(win.sep, ";");
  assert.deepEqual([...win.exts], ["", ".exe", ".bat", ".cmd"]);
  const linux = defaultPathLookup("/a:/b", "linux");
  assert.equal(linux.sep, ":");
  assert.deepEqual([...linux.exts], [""]);
});
