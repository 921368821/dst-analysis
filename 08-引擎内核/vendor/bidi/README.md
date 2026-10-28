# UAX #9 conformance 语料（子集）

由 `tools/make-bidi-corpus.mjs` 从官方全量语料确定性抽样生成 —— **不要手改**。
重新生成：把下表四个文件下载到 `.tmp-bidi/`，再跑 `node tools/make-bidi-corpus.mjs`。

| 文件 | 用途 | sha256（UCD 18.0.0） |
|---|---|---|
| BidiTest.txt | 类型序列语料（含 `@Levels` / `@Reorder` 指令） | `9af2f882a4ab50912e388f069a673b94eacd82fa6d07d20a3ff7f3c759e905aa` |
| BidiCharacterTest.txt | 真实码点语料（唯一覆盖 N0 括号的一类） | `045b24d2c8ab066951bd32fe8c6b4de34647f72b5b1c7df0265f24ab53573e01` |
| BidiBrackets.txt | 65 对括号（BD16 配对表） | `4b3b62e4a14b84ee752808c810c602534921c09a4a1bf78cfbee566d66c125b3` |
| BidiMirroring.txt | 438 对镜像（M1 表） | `cd54810ebf52f0e61a730c8b9cb25975de6c85f6d788a559b416afd548923fd6` |
| DerivedBidiClass.txt | Bidi_Class 全码点范围表（含 `@missing` 默认） | `d9e23222522551348ea1ccfbb4f62efbf98982afb95840f8959c08ed992c5607` |

下载地址统一是 `https://www.unicode.org/Public/UCD/latest/ucd/<文件名>`。
本次取到的是 **Unicode 18.0.0**（`# DerivedBidiClass-18.0.0.txt`，`Date: 2026-07-02`）。

## 格式要点

- **BidiTest.txt**：`@Levels:` 与 `@Reorder:` 指令行之后是数据行 `TYPES; BITSET`。
  BITSET 的位 1/2/4 分别表示「auto（P2/P3）」「显式 LTR」「显式 RTL」三种段落方向，
  所以**一行数据最多要跑三遍**（判据里就是这么做的）。
  期望 levels 里的 `x` = 该字符被 X9 移除，没有级别。
- **BidiCharacterTest.txt**：`码点; 段落方向; 期望段落级; 期望 levels; 期望视觉序`。
  段落方向 0/1/2 = LTR / RTL / auto；视觉序是**视觉→逻辑的下标映射**，
  不是「非 x 位置的下标」（按后者解析会得到"两次都算对"的假绿）。
- 两个期望 levels 都**含 L1**（行尾空白/隔离符已重置为段落级），比对前必须过一遍
  `applyL1` —— 只比 I1/I2 的产物会在 `LRE S` 这类用例上假红。

## 抽样口径

全量 BidiTest ≈49 万行 / BidiCharacterTest ≈9 万行，逐行跑会把单次判据拖到分钟级。
抽样规则见 `tools/make-bidi-corpus.mjs` 文件头，要点是**确定性**（不用随机数，
同一输入永远得到同一子集）且**不丢形状**：

- BidiTest：`len ≤ 3` 全保留，`len = 4` 按 FNV-1a 抽 1/20，`len ≥ 5` 全保留；
- BidiCharacterTest：按「类型序列 + 括号嵌套编号 + 段落方向」签名去重 ——
  第一版按「含括号就全保留」抽，实测 99.9% 的行都嵌括号，等于没抽（6.9MB 全留）。

子集实测：`BidiTest.subset.txt` 45855 个用例 / 750KB，
`BidiCharacterTest.subset.txt` 47024 个用例 / 3.6MB。

判据入口：`tests/extensions/ui-bidi.test.ts`。
