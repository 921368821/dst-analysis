// 统计深度注释文件的精确总行数（用于校对文档数字）
// 不调用 shell，直接遍历目录，避免 cmd.exe EBUSY 问题。
import { readFileSync, readdirSync, statSync } from "node:fs";
import { join } from "node:path";

const ROOT = "E:/DST-Analysis/02-注释源码/scripts";
const MARK = "-- 【深度注释版】";

const hits = [];
(function walk(dir) {
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) walk(p);
    else if (name.endsWith(".lua")) {
      const t = readFileSync(p, "utf8");
      if (t.includes(MARK)) hits.push(p);
    }
  }
})(ROOT);

let realLines = 0;
for (const p of hits) {
  const t = readFileSync(p, "utf8");
  const parts = t.split("\n");
  realLines += t.endsWith("\n") ? parts.length - 1 : parts.length;
}

console.log("深度注释文件数:", hits.length);
console.log("精确总行数:", realLines);