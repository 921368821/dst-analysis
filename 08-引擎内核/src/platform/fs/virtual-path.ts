/**
 * L0 · 虚拟路径归一化（**唯一的实现**）
 *
 * 为什么单独抽出来：`..` 的处理是**安全相关**的，而它已经出现过三个副本
 * （`fs-node` 的 sandbox、`fs-http` 的 URL 拼接、`fs-storage` 的键名拼接）。
 * 安全逻辑抄三遍，迟早有一份写松了，而"哪一份写松了"从代码审查看不出来 ——
 * 只有出事时才知道。
 *
 * ★ 这里的立场（三个后端一致）：
 *   · `..` **一律报错**，不做"归一化掉"。
 *     `/a/../b` 归一后是合法的 `/b`，但"能归一"意味着任何拼接错误都会变成
 *     一次**合法的越界读**。宁可让调用方看见错误。
 *   · `\` 报错：它在 URL 里不是分隔符，在 Windows 路径里是。
 *     放过去会让同一个字符串在两个后端里指向不同资源。
 *   · NUL 报错：OS 层会截断，JS 层不会 —— 截断后的路径可能指向别的东西。
 *
 * 返回**段数组**而不是拼好的字符串：调用方各有各的拼法（URL 要 encodeURIComponent，
 * 存储键要用分隔符，文件系统要用平台分隔符）。归一只管"分几段、每段是什么"。
 */

import { engineError, err, ok, type EngineError, type Result } from "../../foundation/result.ts";

/** `/a/./b/../c` → 报 PATH_ESCAPE；`/a/./b` → `["a","b"]`。 */
export function normalizeVirtualPath(path: string): Result<readonly string[], EngineError> {
  if (typeof path !== "string" || path === "") {
    return err(engineError("FS.BAD_PATH", "路径必须是非空字符串"));
  }
  if (path.includes("\0")) {
    return err(engineError("FS.BAD_PATH", "路径里不能有 NUL（OS 会静默截断，JS 不会）"));
  }
  if (path.includes("\\")) {
    return err(engineError("FS.BAD_PATH", `路径里不能有反斜杠：${path}`));
  }
  const out: string[] = [];
  for (const seg of path.split("/")) {
    if (seg === "" || seg === ".") continue;
    if (seg === "..") {
      return err(engineError("FS.PATH_ESCAPE", `路径含 ..（拒绝越界）：${path}`));
    }
    out.push(seg);
  }
  return ok(out);
}

/** 段数组 → 规范虚拟路径（总是以 `/` 开头；根是 `/`）。 */
export function virtualPathOf(segs: readonly string[]): string {
  return "/" + segs.join("/");
}
