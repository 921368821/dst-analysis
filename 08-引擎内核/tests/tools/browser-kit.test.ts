/**
 * browser-kit 的进程树判据
 *
 * 为什么值得单测：`killTree` 在 POSIX 上靠**进程组**杀树
 * （`process.kill(-pid, SIGKILL)`），而组成员资格由**起进程的那一侧**决定 ——
 * `spawn` 不给 `detached: true`，孩子就在父进程的组里，负数 pid 落 ESRCH，
 * 于是只杀到主进程，Chrome 的 renderer / zygote 整棵留在机器上。
 * 残留不报错，只是**越来越慢**：一轮变异校验起二十几次浏览器，
 * 2 核 runner 被拖到页面 10 秒总闸跑不完，最后以
 * 「M314/M315 还原不干净」的形式爆出来（2026-10-25 批75）——
 * 一个排错成本极高的位置，所以在这里钉死。
 *
 * 判据本身：起一棵三层的进程树（本测试 → 中间层 → 孙子层），
 * `killTree(中间层)` 之后**两层都必须没**。只杀主进程的实现会漏掉孙子层。
 * 杀之前先确认两层都活着 —— 否则这条判据是在对空气打（假绿）。
 */

import { test } from "node:test";
import assert from "node:assert/strict";
import { killTree, spawnBrowser } from "../../tools/browser-kit.mjs";

/** 等一个 pid 彻底消失。SIGKILL 是即时的，留时间是给系统排空/收养（reaper）。 */
async function waitGone(pid: number, timeoutMs = 5000): Promise<boolean> {
  const t0 = Date.now();
  while (Date.now() - t0 < timeoutMs) {
    try {
      process.kill(pid, 0);
    } catch {
      return true; // ESRCH = 没了
    }
    await new Promise((r) => setTimeout(r, 50));
  }
  return false;
}

test("killTree 连孙子进程一起杀（POSIX 靠进程组，不是只杀主进程）", async () => {
  // 中间层：拉起一个长期存活的孙子层，把两个 pid 打出来，然后自己挂着
  const src = [
    "const { spawn } = require('node:child_process');",
    "const c = spawn(process.execPath, ['-e', 'setInterval(() => {}, 1000)'], { stdio: 'ignore' });",
    "console.log(String(process.pid) + ' ' + String(c.pid));",
    "setInterval(() => {}, 1000);",
  ].join("\n");
  const mid = spawnBrowser(process.execPath, ["-e", src]);
  try {
    const line = await new Promise<string>((resolve, reject) => {
      let buf = "";
      const timer = setTimeout(() => reject(new Error("没等到进程树就绪（中间层没报 pid）")), 15_000);
      mid.stdout?.on("data", (d: Buffer | string) => {
        buf += String(d);
        const m = /(\d+) (\d+)/.exec(buf);
        if (m !== null) {
          clearTimeout(timer);
          resolve(m[0]);
        }
      });
      mid.on("exit", (code) => {
        clearTimeout(timer);
        reject(new Error(`中间层提前退出 code=${String(code)}`));
      });
    });
    const parts = line.split(" ");
    const midPid = Number(parts[0]);
    const grandPid = Number(parts[1]);
    assert.ok(midPid > 0 && grandPid > 0, `pid 不合理：${line}`);

    // 杀之前两层都在：否则这条判据是对空气打
    assert.doesNotThrow(() => process.kill(midPid, 0), "杀之前中间层应该在");
    assert.doesNotThrow(() => process.kill(grandPid, 0), "杀之前孙子层应该在");
    // ★ 机制本身也要钉（Windows 上没有牙的一环）：killTree 在 POSIX 上打的是
    //   **进程组**（`kill(-pid)`），组成员资格由起进程那侧的 `detached` 决定。
    //   只验"杀完两边都没了"在 Windows 上恒真（taskkill /T 本来就杀树），
    //   撤掉 detached 它照样绿 —— 而那个 bug 只在 Linux 上咬人（批75）。
    //   所以这里直接问：以 midPid 为组长的进程组存在吗？不存在 ⇒ killTree 必落 ESRCH。
    if (process.platform !== "win32") {
      assert.doesNotThrow(
        () => process.kill(-midPid, 0),
        `中间层 ${midPid} 不在自己的进程组里 —— spawn 少了 detached: true，killTree 在 POSIX 上杀不到树`,
      );
    }

    killTree(mid);

    assert.ok(await waitGone(midPid), `killTree 之后中间层 ${midPid} 还在`);
    assert.ok(
      await waitGone(grandPid),
      `killTree 之后孙子层 ${grandPid} 还在 —— 进程组没杀到（spawn 少了 detached: true？）`,
    );
  } finally {
    // 判据失败也不能把树留在机器上（测试自己起的东西自己收尸）
    killTree(mid);
  }
});
