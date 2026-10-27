# vendor/unifont —— 第三方素材：GNU Unifont 18.0.01

本目录是**原样下载、未做任何修改**的上游文件。它只被 `tools/make-ui-assets.mjs`
读取（生成 `web/assets/ui-font-cjk.{png,fnt}`），引擎运行时不读它 ——
所以它进仓库的唯一理由是：**让资产生成可复现**，而不是靠"某台机器上装着这个字体"。

## 来源

| 项 | 值 |
|---|---|
| 项目 | GNU Unifont（GNU 项目，维护者 Paul Hardy，最初作者 Roman Czyborra） |
| 版本 | 18.0.01 |
| 文件 | `unifont-18.0.01.bdf.gz` |
| 下载地址 | https://unifoundry.com/pub/unifont/unifont-18.0.01/font-builds/unifont-18.0.01.bdf.gz |
| 下载日期 | 2026-10-27 |
| 字节数 | 1259315 |
| sha256 | `2989e0211030d8219fd931aba599fc95c86bc327ce1423848ef949783b208257` |
| 上游总入口 | https://unifoundry.com/unifont.html |

## 许可

上游自 13.0.04 起**双许可**，二者任选其一：

1. **SIL Open Font License 1.1**（`OFL-1.1.txt` 是上游原文）—— 本仓库按这一条使用；
2. GNU GPL v2+ **附 GNU 字体嵌入例外**（`LICENSE.txt` 是上游原文）。

按 OFL 1.1 使用需要满足的三件事，以及本仓库的对应做法：

| 要求 | 做法 |
|---|---|
| 随分发带上版权声明与许可原文 | `OFL-1.1.txt` 与本文件同目录，`web/assets/ui-font-cjk.fnt` 的 `info face` 里写明了来源与许可 |
| 衍生字体不得使用保留字体名（Reserved Font Name） | 上游未声明保留字体名；我们仍然把产物改名为 `unifont-cjk-16-subset`，不复用 `Unifont` 这个名字 |
| 衍生字体同样以 OFL 分发 | 产物由本目录源文件生成，取舍记录在 `docs/adr/0014-vendored-font-asset.md` |

**为什么不用 GPL 那一条**：GPL + 字体嵌入例外只解决"把字体嵌进文档"，
而我们要把**派生图集**（改过、子集化过）随引擎一起分发。OFL 明确允许修改与再分发，
只要保留许可、改名、不以作者名义背书 —— 这是唯一不需要逐案判断的选择。

## 为什么是这个字体

引擎要的是**位图字形**（不做抗锯齿、逐字节可复现、CI 上不依赖系统字体）。
满足"有 BDF 原始位图 + CJK 全覆盖 + 允许商用与再分发"三条的字体极少，Unifont 是其中最稳的一个：

- **BDF 是原生格式**，不是"从 TTF 栅格化出来的"。这一条决定了生成链里**没有光栅化器** ——
  没有 FreeType、没有浏览器 `fillText`，于是产物逐字节可复现，Linux runner 上的结果与开发机一致。
- **覆盖全部 BMP**，GB2312 的 6763 个汉字一个不缺。
- 16×16 的正方形汉字格，与 2.5D 像素风一致（不缩放、不插值）。

## 我们怎么用它

`tools/make-ui-assets.mjs` 只取**声明的字符集**（`tools/cjk-charset.txt`：可打印 ASCII +
GB2312 全集 7445 字），把它打进一张图集。**不**整字库打包：57086 个字形里有四万多个
我们永远用不到，图集白白大十倍，而"用得少"这件事在产物里看不出来。

升级版本时：换掉 `.bdf.gz` → 更新本文件的 URL / 字节数 / sha256 →
`node tools/make-ui-assets.mjs` → 跑 `npm test`（判据会核对字符集覆盖与图集内无重叠）。
