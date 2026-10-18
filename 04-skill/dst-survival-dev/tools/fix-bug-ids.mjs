// 一次性脚本：消除 bug-patterns.md 的编号冲突 + 标注同源重复条目
// 运行：node tools/fix-bug-ids.mjs
import fs from 'fs';
import path from 'path';
import { fileURLToPath } from 'url';

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.resolve(__dirname, '..');
const F = path.join(ROOT, 'references', 'bug-patterns.md');

const report = [];
const fail = [];
const ok = (m) => report.push('  [OK] ' + m);
const bad = (m) => fail.push('  [!!] ' + m);

// 本文件历史上是 CRLF 行尾，而同目录其他 md 都是 LF。
// 行尾不统一会让正则的 $ / \n 锚点全部错位，先统一成 LF 再做替换。
const raw = fs.readFileSync(F, 'utf8');
const hadCRLF = raw.includes('\r\n');
let src = raw.replace(/\r\n/g, '\n');
const lines = src.split('\n');
if (hadCRLF) ok('已归一化行尾：CRLF → LF');

// ---------- 定位各大区块的行号边界 ----------
function findLine(pred, from = 0) {
  for (let i = from; i < lines.length; i++) if (pred(lines[i], i)) return i;
  return -1;
}
const idxApp1 = findLine(l => /^# 附录：/.test(l));          // 附录一
const idxApp2 = findLine(l => /^# 附录二/.test(l));
const idxApp3 = findLine(l => /^# 附录三/.test(l));
const idxApp4 = findLine(l => /^# 附录四/.test(l));
const idxApp5 = findLine(l => /^# 附录五/.test(l));
for (const [n, v] of [['一', idxApp1], ['二', idxApp2], ['三', idxApp3], ['四', idxApp4], ['五', idxApp5]]) {
  if (v < 0) bad(`未找到附录${n}的起始行`);
}
if (fail.length) { console.error(fail.join('\n')); process.exit(1); }
report.push(`区块定位：附录一@${idxApp1 + 1} 二@${idxApp2 + 1} 三@${idxApp3 + 1} 四@${idxApp4 + 1} 五@${idxApp5 + 1}`);

// ---------- 1. 附录二的动作系统 A1-A8 → ACT1-ACT8 ----------
// 该区块内的 '### 症状：A<num> ·' 才是动作系统条目；主文的 A 条目在 idxApp1 之前，不受影响。
// 幂等：若已是 ACT 则跳过。
let renamedAct = 0, actAlready = 0;
for (let i = idxApp2; i < idxApp3; i++) {
  const m = lines[i].match(/^### 症状：A(\d+) · (.*)$/);
  if (m) { lines[i] = `### 症状：ACT${m[1]} · ${m[2]}`; renamedAct++; }
  else if (/^### 症状：ACT\d+ · /.test(lines[i])) actAlready++;
}
const actTotal = renamedAct + actAlready;
if (actTotal !== 8) bad(`动作系统条目应为 8 条，实际 ${actTotal}（改写 ${renamedAct} + 已存在 ${actAlready}）`);
else ok(`动作系统 ACT1-ACT8 就位（本次改写 ${renamedAct} 条，已存在 ${actAlready} 条）`);

// ---------- 2. 附录四的容器系统 C1-C9 → CTR1-CTR9 ----------
let renamedCtr = 0, ctrAlready = 0;
for (let i = idxApp4; i < idxApp5; i++) {
  const m = lines[i].match(/^### 症状：C(\d+) · (.*)$/);
  if (m) { lines[i] = `### 症状：CTR${m[1]} · ${m[2]}`; renamedCtr++; }
  else if (/^### 症状：CTR\d+ · /.test(lines[i])) ctrAlready++;
}
const ctrTotal = renamedCtr + ctrAlready;
if (ctrTotal !== 9) bad(`容器系统条目应为 9 条，实际 ${ctrTotal}（改写 ${renamedCtr} + 已存在 ${ctrAlready}）`);
else ok(`容器系统 CTR1-CTR9 就位（本次改写 ${renamedCtr} 条，已存在 ${ctrAlready} 条）`);

// ---------- 3. 附录四内 G1-G4 根因小节 → GR1-GR4（避免与主文 G1-G4 混淆）----------
let renamedGr = 0, grAlready = 0;
for (let i = idxApp4; i < idxApp5; i++) {
  const m = lines[i].match(/^### G(\d) (.*)$/);
  if (m) { lines[i] = `### GR${m[1]} ${m[2]}（主文 G${m[1]} 的精确根因）`; renamedGr++; }
  else if (/^### GR\d /.test(lines[i])) grAlready++;
}
const grTotal = renamedGr + grAlready;
if (grTotal !== 4) bad(`UI 根因小节应为 4 节，实际 ${grTotal}（改写 ${renamedGr} + 已存在 ${grAlready}）`);
else ok(`UI 根因小节 GR1-GR4 就位（本次改写 ${renamedGr} 节，已存在 ${grAlready} 节）`);

// ---------- 4. 修正内部交叉引用 ----------
// 4a. 附录二 A5 正文里引用「即 A1 的另一面」→ ACT1
let refFix = 0;
for (let i = idxApp2; i < idxApp3; i++) {
  if (lines[i].includes('即 A1 的另一面')) {
    lines[i] = lines[i].replace('即 A1 的另一面', '即 ACT1 的另一面');
    refFix++;
  }
}
refFix ? ok(`修正内部引用「即 A1 的另一面」→「即 ACT1 的另一面」（${refFix} 处）`)
       : (/即 ACT1 的另一面/.test(lines.join('\n')) ? ok('内部引用已是 ACT1（幂等）')
                                                    : bad('未找到「即 A1 的另一面」内部引用'));

// 4b. 附录四标题里的「附录：G1-G4 的精确根因」
let refFix2 = 0;
for (let i = idxApp4; i < idxApp5; i++) {
  if (lines[i].includes('UI 系统类（附录：G1-G4 的精确根因）')) {
    lines[i] = lines[i].replace('UI 系统类（附录：G1-G4 的精确根因）',
      'UI 系统类（主文 G1-G4 的精确根因，编号 GR1-GR4）');
    refFix2++;
  }
}
refFix2 ? ok('修正附录四小节标题的 G1-G4 指向')
        : (/主文 G1-G4 的精确根因，编号 GR1-GR4/.test(lines.join('\n'))
            ? ok('附录四 UI 小节标题已指向 GR1-GR4（幂等）')
            : bad('未找到附录四 UI 小节标题'));

// ---------- 5. 为同源条目加「同源」互见标记 ----------
// 同一根因在主文与附录各写了一遍：不是编号冲突，而是内容重复。
// 处理方式：不删除（两处侧重点不同），加一行显式互见，避免读者当成两条独立缺陷。
const DUP = [
  { main: 'B6', app: 'N5',  why: '同为 `networkclientrpc.lua:1848` 的 RPC 限流无上界' },
  { main: 'B8', app: 'P4',  why: '同为 `remote_vector.y` 一字段三语义' },
  { main: 'A1', app: 'N16', why: '同为周期任务回调内 yield 导致的漂移' },
  { main: 'C1', app: 'S1',  why: '同为 NaN 写坏存档；S1 补充了判据表的分支细节' },
  { main: 'D5', app: 'N3',  why: '同为环境类伤害不走 externalreduction 的短路' },
  { main: 'D2', app: 'N2',  why: '同为 `health.lua:628` 的 absorb 未做 nil 保护' },
];
let dupTag = 0, dupAlready = 0;
for (const d of DUP) {
  let hit = 0, already = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = lines[i].match(/^### 症状：([A-Z]+\d+) · /);
    if (m && m[1] === d.main) {
      // 幂等：紧邻标题下方已有同源标记则不再重复插入
      const alreadyTagged = lines.slice(i + 1, i + 4).some(l => l.includes(`**同源**：附录 \`${d.app}\``));
      if (alreadyTagged) { already++; continue; }
      lines[i] += `\n\n> **同源**：附录 \`${d.app}\` 记录了同一根因的另一面（${d.why}）。两者是**同一条缺陷**，编号不同只为区分侧重点。`;
      hit++;
    }
  }
  if (hit + already !== 1) bad(`同源标记 ${d.main} 命中 ${hit} + 已存在 ${already} 次（应为 1）`);
  else if (already) dupAlready++;
  else dupTag++;
}
if (dupTag + dupAlready === DUP.length)
  ok(`同源标记就位（本次新增 ${dupTag} 组，已存在 ${dupAlready} 组，共 ${DUP.length} 组）`);
else bad(`同源标记完成 ${dupTag + dupAlready}/${DUP.length}`);

// ---------- 6. 修正表头与目录 ----------
const before = src;
src = lines.join('\n');

const REPL = [
  // 6a. 抬头条数
  [/^> 收录 \*\*47 条\*\*/m, '> 收录 **108 条**'],
];
for (const [re, to] of REPL) {
  if (re.test(src)) { src = src.replace(re, to); ok('表头替换：' + String(re).slice(0, 40)); }
  else if (new RegExp(to.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).test(src)) ok('表头已是目标值（幂等）');
  else bad(`表头替换未命中：${re}`);
}
// 幂等：若已是 108 条则视为通过（脚本可重复运行）
if (/^> 收录 \*\*108 条\*\*/m.test(src)) ok('抬头条数已是 108 条');

// 6c. 目录表整体重建
const newTOC = `| 分区 | 主题 | 条数 | 编号 |
|---|---|---|---|
| [A](#a-协程与生命周期) | 协程与生命周期 | 7 | A1–A7 |
| [B](#b-网络同步与联机) | 网络同步与联机 | 8 | B1–B8 |
| [C](#c-存档与数据) | 存档与数据 | 6 | C1–C6 |
| [D](#d-数值与状态同步) | 数值与状态同步 | 6 | D1–D6 |
| [E](#e-世界生成) | 世界生成 | 6 | E1–E6 |
| [F](#f-性能) | 性能 | 6 | F1–F6 |
| [G](#g-ui-与输入) | UI 与输入 | 4 | G1–G4 |
| [H](#h-ai-与状态机) | AI 与状态机 | 7 | H1–H7 |
| [附录一](#附录逐行深度注释阶段新发现的缺陷18-条) | 深度注释阶段新发现（混合） | 18 | N1–N18 |
| [附录二](#附录二动作系统与存档系统深度注释新增缺陷13-条) | 动作系统 / 存档 | 11 | ACT1–ACT8、S1–S3 |
| [附录三](#附录三玩家控制与物品系统深度注释新增缺陷12-条) | 玩家控制与物品 | 8 | P1–P8 |
| [附录四](#附录四容器系统与-ui-框架深度注释新增缺陷14-条) | 容器系统 / UI 框架 | 9+4 | CTR1–CTR9、GR1–GR4 |
| [附录五](#附录五世界生成与数值系统深度注释新增缺陷11-条) | 世界生成 / 数值 | 12 | W1–W6、M1–M6 |
| — | [症状速查表](#症状速查表) | — | **共 108 条** |

**编号规则：** 主文用单字母分区（A–H），**字母在整个文档内唯一**。
附录另有独立前缀：\`N\` 深度注释新发现、\`ACT\` 动作、\`CTR\` 容器、\`GR\` UI 根因、
\`S\` 存档编码、\`P\` 玩家控制、\`W\` 世界生成、\`M\` 数值常量。
报 bug 时直接用完整编号（如 \`B3\`、\`ACT3\`、\`CTR4\`），不要只写字母。`;
const tocRe = /\| 分区 \| 主题 \| 条数 \| 编号 \|\n\|---\|---\|---\|---\|\n(?:\|.*\n)+?\n\*\*编号规则：\*\*[^\n]*/;
if (!tocRe.test(src)) bad('未匹配到目录表整体');
else { src = src.replace(tocRe, newTOC); ok('目录表已重建（含附录分区）'); }

// 6d. 编号规则那句单独处理（防止残留旧句）
src = src.replace(
  /\*\*编号规则：\*\*[^\n]*?\n\n---/s,
  '**编号规则：** 见上表。主文 A–H 的字母在全文唯一；附录使用独立前缀（ACT / CTR / GR / N / P / S / W / M）。报bug 时用完整编号，不要只写字母。\n\n---'
);
// 6d-2. 目录表必须已含H 区 7 条 / 108 条总账（重建后自检）
if (!/\| \[H\]\(#h-ai-与状态机\) \| AI 与状态机 \| 7 \| H1–H7 \|/.test(src)) bad('目录表 H 区未修正为 7 条');
else ok('目录表 H 区已修正为 7 条');
if (!/\*\*共 108 条\*\*/.test(src)) bad('目录表总账未写明 108 条');
else ok('目录表总账 108 条已写入');

// ---------- 6f. 修正各附录标题里与实际不符的条数声明 ----------
// 逐个附录按实际「### 症状：」条目数重算，改写标题括号里的数字。
{
  const L = src.split('\n');
  const heads = [];
  L.forEach((l, i) => { if (/^# 附录/.test(l)) heads.push(i); });
  const ORD = ['一', '二', '三', '四', '五'];
  let fixedCnt = 0;
  heads.forEach((s, k) => {
    const e = (k + 1 < heads.length) ? heads[k + 1] : L.length;
    const real = L.slice(s, e).filter(l => /^### 症状：/.test(l)).length;
    const m = L[s].match(/^(# 附录[^（]*?)（(\d+) 条）/);
    if (!m) { bad(`附录${ORD[k] || k + 1} 标题未匹配「（N 条）」格式：${L[s]}`); return; }
    const declared = m[2];                // 必须用捕获组，否则拿到 undefined
    if (Number(declared) === real) { ok(`附录${ORD[k] || k + 1} 标题条数正确（${real} 条）`); return; }
    L[s] = L[s].replace(/（\d+ 条）/, `（${real} 条）`);
    ok(`附录${ORD[k] || k + 1} 标题条数 ${declared} → ${real}`);
    fixedCnt++;
  });
  src = L.join('\n');
  if (!fixedCnt) ok('各附录标题条数无需改动');
}

// 6e. SKILL.md 里的条数（若同目录）
const skillF = path.join(ROOT, 'SKILL.md');
let skillChanged = false;
let skillSrc = '';
if (fs.existsSync(skillF)) {
  skillSrc = fs.readFileSync(skillF, 'utf8').replace(/\r\n/g, '\n');
  const b = skillSrc;
  skillSrc = skillSrc.replace(/\*\*96 条\*\*/g, '**108 条**')
                     .replace(/四个附录共 58 条/g, '五个附录共 58 条');
  skillChanged = skillSrc !== b;
  skillChanged ? ok('SKILL.md 条数已同步为 108 条') : ok('SKILL.md 已是 108 条（幂等，无需改动）');
}

// ---------- 8. 校验：全部通过才落盘 ----------
// 关键：先做完全部断言再写文件。任何一条失败都直接退出，绝不写出半成品。
if (fail.length) {
  console.log('\n===== 执行报告 =====');
  report.forEach(r => console.log(r));
  console.log('\n===== 失败项（未写入文件）=====');
  fail.forEach(f => console.log(f));
  process.exit(1);
}

// ---------- 9. 落盘 ----------
fs.writeFileSync(F, src);
if (fs.existsSync(skillF) && skillChanged) fs.writeFileSync(skillF, skillSrc);

console.log('\n===== 执行报告 =====');
report.forEach(r => console.log(r));
console.log('\n全部完成，无失败项。');