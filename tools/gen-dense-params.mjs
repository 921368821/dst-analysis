#!/usr/bin/env node
/**
 * gen-dense-params.mjs —— 为 containers.lua 生成「密集注释」spec
 *
 * 目标：把 p1-p6 遗漏的结构性代码行补齐注释（widget 字段 / 蓝图声明 /
 *       槽位循环 / 字段覆盖赋值），把覆盖率从 ~16% 提到 ~75%。
 *
 * 反废话原则：
 *   · widget 字段用**专属释义表**；同一字段第二次起只写一行「同 N 行」+ 本行实际值；
 *   · 槽位循环先解析 for 范围，算出「几行 × 几列 = 几槽」再写；
 *   · slotpos/slotbg 插入行写明「第几槽」；
 *   · 蓝图声明行写容器身份（来自 CONTAINER_DESC 人工维护表）。
 */
import { readFileSync, writeFileSync } from "node:fs";
import { relSrc, relOut, pristineRoot, ANN_SCRIPTS } from "./lib/paths.mjs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));

const SRC = relSrc("containers.lua");

/* ── widget 字段专属释义表（每条一个字符串数组元素，不含换行） ── */
const FIELD_DOC = {
  widget: [
    "★ widget 子表：本容器全部 UI 配置的容器（槽位/贴图/音效/按钮/位置）。",
    "--   ★ 纯表现层——components/container.lua 一个字段都不读，只有 widgets 层消费。",
    "--   参见 widgets/containerwidget.lua（仓库外）；本文件只负责「声明值」。",
  ],
  animbank: ["UI 贴图库名（客户端 .tex 图集名），widgets 层据此加载贴图。"],
  animbuild: [
    "UI 构建名：从 bank 中取出的可渲染实例名，通常与 animbank 同值。",
  ],
  animloop: ["★ 开门动画是否**循环**播放（传送门漩涡这类用）。"],
  pos: [
    "★ UI 整体位置偏移（屏幕像素）。正值=右/上，负值=左/下。",
    "--   ★ 与 slotpos 的关系：slotpos 是**绝对坐标**，pos 是**整体偏移**，二者叠加生效。",
  ],
  side_align_tip: [
    "提示条侧边对齐距离（像素）：空间不足时把提示文字推到距容器这么远。",
  ],
  top_align_tip: ["提示条顶部对齐距离（像素）。"],
  bottom_align_tip: ["提示条底部对齐距离（像素）。"],
  opensound: [
    "★ 开箱 UI 音效。⚠ 只在**客户端**播放。",
    "--   多数容器用 skipopensnd 关掉它，改由 prefab 在**世界空间**播放（见第 508-513 行 V2C 注释）。",
  ],
  closesound: ["★ 关箱 UI 音效，同样只在客户端播放（同上）。"],
  type: null, // 动态生成
  acceptsstacks: [
    "★ 是否接受整摞物品。false = 每格只放一件。",
    "--   落点：components/container.lua:534 GiveItem 会把超量堆叠 Get() 拆成单个并**返回 false**。",
  ],
  issidewidget: [
    "★ UI 是否挂在屏幕**侧边**（背包类）而非中央（箱子类）。",
    "--   消费点：components/container.lua:637 作为第二参数传给 doer.HUD:OpenContainer。",
  ],
  openlimit: [
    "★ 同时开启人数上限（不是「一生只能开一次」）。",
    "--   判定在 components/container.lua:735 CanOpen；★ 但 Open 自身不检查它，",
    "--   守门在 actions.lua:1095 —— 这是「约定优于实现」的边界。",
  ],
  excludefromcrafting: [
    "箱内物品是否**排除在合成搜索之外**。true=不参与合成（沙尘蜂帽/弹弓用）。",
    "--   ⚠ 对照第 1373/1408/1444 行：beard_sack 把同一行注释掉了，即胡子袋要参与合成。",
  ],
  usespecificslotsforitems: [
    "★ 槽位是否有语义：true 时物品必须进 itemtestfn(item, slot) 指定的**那一格**。",
    "--   落点：components/container.lua:298 GetSpecificSlotForItem（逐槽试）、451 GiveItem（优先用）。",
  ],
  lowpriorityselection: [
    "★ 自动取物优先级最低（从背包找东西时先翻别处，找不到才来这里）。",
  ],
  slotpos: [
    "★ 槽位坐标数组：每个 Vector3 是**一个格子在屏幕上的绝对位置**。",
    "--   ★★ 数组顺序 = 槽位编号顺序（slot 1 = 第一个坐标）。改顺序就改了物品编号，",
    "--     而存档按编号还原（components/container.lua:996 OnLoad），所以这是**存档兼容雷区**。",
  ],
  slotbg: [
    "格子底纹贴图数组（与 slotpos 严格一一对应）。★ 纯装饰，容器逻辑从不读。",
  ],
  numslots: [
    "★ 显式声明槽位数。用于**动态槽位**容器（没有固定 slotpos 时必须写）。",
    "--   缺省时由 containers.lua:15 从 #widget.slotpos 数出。",
  ],
  buttoninfo: [
    "★ 容器按钮配置：text(文案) / position(位置) / fn(点击动作) / validfn(可用性灰显)。",
    "--   ★ fn 必须在第 330 行的双端模板下实现（服务端 BufferedAction / 客户端 SendRPCToServer）。",
  ],
  overrideactionfn: [
    "★ 按钮动作的前置拦截层：返回 true 表示「已处理（如弹了确认框）」，此时 fn 不再执行。",
  ],
  itemtestfn: [
    "★ 物品筛选闭包，签名固定 (container, item, slot)。",
    "--   调用点：components/container.lua:295 CanTakeItemInSlot —— **唯一的物品准入闸门**。",
    "--   ★ 第一形参 container 就是组件本身（调用处写的是 self:itemtestfn(item, slot)）。",
  ],
  priorityfn: [
    "★ 专用容器优先判定（弹药包这类）。常与 itemtestfn 共用同一函数，但语义相反：",
    "--   itemtestfn 管「能不能放」，priorityfn 管「优先往哪放」（components/container.lua:319）。",
  ],
  typefn: [
    "★ 动态 type（wx78 专用）：UI 层先问「有没有 typefn，有就调它，否则用静态 type」",
    "--   消费点：screens/playerhud.lua:392。",
  ],
  posfn: [
    "★ 动态 UI 位置（wx78 专用）：运行时实时算 UI 该摆哪（跟随物品栏格子移动）。",
  ],
  slotposfn: [
    "★ 动态槽位坐标（wx78 专用）：按运行时状态（柜子在躯体第几列）返回坐标，",
    "--   返回 nil 表示「沿用静态 slotpos」。",
  ],
  slotscale: ["格子整体缩放（wx78 装进躯体时缩到 0.85）。"],
  slotscalefn: ["★ 动态格子缩放（wx78 专用）。"],
  slothighlightscale: ["格子高亮时的放大比例（与 slotscale 配套调整）。"],
  slothighlightscalefn: ["★ 动态高亮缩放（wx78 专用）。"],
  animfn: [
    "★ 动态贴图名（wx78 专用）：按列号拼出 ui_..._Nx1。",
    "--   ⚠ 最脆弱的一处：美术改名规则变了这里会静默显示空白。",
  ],
  animbank_upgraded: ["★ 升级态贴图库名（箱子被季节活动升级后使用）。"],
  animbuild_upgraded: ["★ 升级态构建名。"],
  side_align_tip_fn: ["★ 动态提示条侧对齐（wx78 专用）。"],
  top_align_tip_fn: [
    "★ 动态顶部对齐（wx78 专用）。返回 nil 时回落到静态 top_align_tip（向后兼容）。",
  ],
  bottom_align_tip_fn: ["★ 动态底部对齐（wx78 专用）。"],
};

/* type 字段：按实际取值给出专属解释 */
const TYPE_DOC = {
  pack: "背包类：UI 在屏幕侧边（issidewidget=true），同一时刻只能开一个。",
  chest: "★ 箱子类：UI 在屏幕中央。★ **与筛选规则无关**——冰箱/木箱都是它。",
  cooker: "★ 加工类：只用于「不是侧边 UI、不是背包」这个否定语义。",
  "hand_inv": "手持物容器：UI 挂在角色的手持区（playerhud.lua:395）。",
  "side_inv_behind": "角色背后侧边容器（playerhud.lua:397）。",
  top_rack: "悬挂式：UI 挂在屏幕下方（playerhud.lua:398）。",
  inv: "物品栏顶行容器（playerhud.lua:394）。",
  backpack: "背包类新类型（全文件仅未开化 DLC 的两个容器在用）。",
  chest_addon: "★ 附加到别人的容器：仅由 typefn（第 2282 行）动态返回。",
};

const CONTAINER_DESC = {
  backpack: "玩家背包 2x4=8 格（type=pack，side UI）",
  spicepack: "香料包 2x3=6 格",
  chester: "Chester 箱子 3x3=9 格",
  shadowchester: "暗影 Chester 3x3（★ 已废弃，但为 dragonflychest/minotaurchest/模组/旧存档保留）",
  shadow_container: "月影传送门容器（deepcopy 暗影 Chester，开门动画循环）",
  rabbitkinghorn_container: "兔子王之角容器（传送门容器换皮，animloop 改回 nil）",
  hutch: "寄居蟹的箱子",
  wobysmall: "沃比小形态容器 3x3",
  wobybig: "沃比大形态容器",
  woby_rack_container: "沃比晾肉架 3x1（不堆叠，type=top_rack）",
  meatrack: "普通晾肉架 3x1（不堆叠）",
  meatrack_hermit: "寄居蟹 1x1 晾肉架",
  meatrack_hermit_multi: "寄居蟹 3x3 晾肉架",
  yotb_sewingmachine: "缝纫机 3 格（只放图纸碎片，带 SEW 按钮）",
  cookpot: "烹饪锅 4 竖格（不堆叠，type=cooker，带 COOK 按钮）",
  portablespicer: "便携香料锅 2 格语义槽（食材/香料）",
  bundle_container: "绷带包 2x2=4 格（带 WRAPBUNDLE 按钮）",
  construction_container: "★ 建造材料容器 4 槽（规则完全由携带者的 constructionbuilderuidata 决定）",
  construction_repair_container: "建造修理容器（构造器派生）",
  construction_rebuild_container: "建造重建容器（构造器派生）",
  enable_shadow_rift_construction_container: "月影裂隙献祭容器 1 槽 + 二次确认弹窗",
  enable_lunar_rift_construction_container: "月影裂隙献祭容器（月影版，文案由 prefab 提供）",
  construction_container_1x1: "建造材料容器 1x1 变体",
  mushroom_light: "蘑菇灯 4 竖格（只放灯燃料/灯芯）",
  mushroom_light2: "蘑菇灯 2 代（额外接受孢子）",
  yots_lantern_post: "永夜灯柱 1 格（灯燃料/孢子/灯芯）",
  hermitcrab_lightpost: "寄居蟹灯柱（换皮，复用同一 itemtestfn）",
  hermithouse2: "寄居蟹屋 2 代 2x2=4 格（只放装饰品）",
  winter_tree: "冬季树 8 格（放节日装饰）",
  winter_twiggytree: "冬季树枝树",
  winter_deciduoustree: "冬季落叶树",
  winter_palmconetree: "冬季棕榈树",
  sisturn: "★ 露西的花槽 2x2=4 格（规则依赖打开者的技能树解锁 wendy_sisturn_3）",
  offering_pot: "供奉锅 2x2=4 格（只放海藻）",
  offering_pot_upgraded: "供奉锅 II 3x2=6 格（只放海藻）",
  merm_toolshed: "鱼人工具棚 2 语义槽（树枝/石头）",
  merm_toolshed_upgraded: "鱼人工具棚升级版",
  merm_armory: "鱼人军械库 2 语义槽（木头/草）",
  merm_armory_upgraded: "鱼人军械库升级版",
  livingtree_halloween: "万圣节树 3 格（放万圣节装饰）",
  icebox: "★★ 冰箱 3x3=9 格（四层漏斗筛选；type 与木箱相同，特殊性全来自 itemtestfn）",
  saltbox: "盐罐（deepcopy 冰箱；额外要求 cookable 且非 deployable、无血条）",
  krampus_sack: "圣诞怪口袋 14 格（type=pack）",
  piggyback: "背背怪背包 12 格（type=pack）",
  teleportato_base: "土豆地传送锅 4 竖格（可堆叠；★ 按钮是空实现，联机无效）",
  balatro_machine: "同步机房 5 横格（筛选宽松；★ 按钮无 validfn = 永远可点）",
  treasurechest: "宝箱 3x3=9 格（★ 无 itemtestfn = 万能容器）",
  pandoraschest: "潘多拉箱",
  chest_mimic: "拟态怪箱",
  skullchest: "骷髅宝箱",
  terrariumchest: "生态箱",
  quagmire_safe: "未开化保险箱（deepcopy 宝箱换美术）",
  boat_ancient_container: "古代船容器 4x4=16 格",
  minotaurchest: "牛头人宝箱",
  dragonflychest: "蜻蜓箱（deepcopy 暗影 Chester，只设升级态美术）",
  antlionhat: "沙尘蜂帽 1 格（放地砖，type=hand_inv）",
  fish_box: "鱼箱 5x4=20 格（只放小型海洋生物）",
  oceanfishingrod: "海洋钓竿 2 语义槽（浮标/诱饵，type=hand_inv）",
  beard_sack_1: "胡子袋 1 代 1 格（只收 FOODGROUP.OMNI 可食物）",
  beard_sack_2: "胡子袋 2 代 2 格（同上）",
  beard_sack_3: "胡子袋 3 代 3 格（同上）",
  slingshot: "弹弓 1 格（放弹弓弹药，type=hand_inv）",
  slingshotex: "弹弓（deepcopy 换皮）",
  slingshot999ex: "弹弓 999 变体（deepcopy slingshotex 换皮）",
  slingshot2: "★ 双格弹弓（★ 槽序反转：底部为 slot 1）",
  slingshot2ex: "双格弹弓（宝石版；微调第 2 槽 y 坐标）",
  slingshotmodscontainer: "★ 弹弓改装台 3 语义槽（弹带/弓框/握把，格子放大 1.6 倍）",
  tacklecontainer: "钓具箱 3x2=6 格（浮标/诱饵）",
  supertacklecontainer: "超级钓具箱 3x5=15 格",
  sunkenchest: "★★ 沉箱 3x5（★ 打不开但仍是真容器；★ 作者刻意手写而非 deepcopy 以免共享表被污染）",
  sacred_chest: "圣柜 3x2=6 格（无筛选）",
  seedpouch: "种子袋 14 格（prefab 精确 + string.match + 标签 三合一）",
  candybag: "糖果袋 14 格（万圣节糖果/饰品 + trinket_ 前缀）",
  alterguardianhatshard: "监护者帽碎片 1 格（只放孢子）",
  alterguardianhat: "监护者帽 5 竖排（孢子/月之种，type=hand_inv）",
  pocketwatch: "怀表 3x2=6 格（放怀表零件；★ pos.x=-850 → UI 摆到屏幕最左）",
  ocean_trawler: "海洋拖网渔船 4 竖格（不堆叠）",
  bookstation: "★★ 书站 4x5=20 格（全文件槽位最多之一，直接抬高全局 MAXITEMSLOTS）",
  beargerfur_sack: "熊皮袋 2x3=6 格（放熟食）",
  houndstooth_blowpipe: "獠牙吹管 1 格（放吹管弹药；deepcopy 自弹弓）",
  battlesong_container: "战歌容器 8 格（放战歌）",
  wortox_souljar: "沃尔托克斯魂罐 1 格（放灵魂，排除 nosouljar）",
  elixir_container: "温蒂灵药容器 3x3=9 格（灵药/幽灵花）",
  dragonflyfurnace: "蜻蜓焚化炉 2x2=4 格（排除 irreplaceable，带 INCINERATE 按钮）",
  slingshotammo_container: "弹弓弹药箱 3x2=6 格",
  wx78_backupbody: "WX-78 备用躯体 5x3=15 格",
  wx78_drone_delivery: "WX-78 送货无人机 3x2=6 格",
  wx78_drone_delivery_small: "WX-78 小型无人机 3x1=3 格",
  wx78_inventorycontainer: "★★ WX-78 物品柜容器（全文件唯一动态布局容器：slotposfn/slotscalefn/slothighlightscalefn/animfn/posfn/typefn 六个 *fn）",
  socket_keystone_construction_container: "基岩插槽容器 1 槽 + 二次确认弹窗",
  quagmire_pot: "未开化脓液锅 4 竖格（四重与筛选）",
  quagmire_pot_small: "未开化小锅 3 格",
  quagmire_casseroledish: "未开化平底锅",
  quagmire_casseroledish_small: "未开化小平底锅",
  quagmire_grill: "未开化烤架",
  quagmire_grill_small: "未开化小烤架",
  quagmire_pot_syrup: "★ 未开化糖浆锅 3 格（与 quagmire_pot 规则相反：★ 接受树液）",
  quagmire_backpack_small: "未开化小背包 4 格单排（type=backpack）",
  quagmire_backpack: "未开化背包 8 格单排（type=backpack）",
  archive_cookpot: "档案锅",
  portablecookpot: "便携烹饪锅",
};

const src = readFileSync(SRC, "utf8").split("\n");
const srcLen = src.length;

const doneList = process.argv[2];
const done = new Set(
  doneList ? readFileSync(doneList, "utf8").split("\n").map(Number) : []
);

const entries = {};
function add(lineno, lines) {
  if (!Array.isArray(lines)) lines = [lines];
  if (entries[lineno]) entries[lineno] = [...entries[lineno], ...lines];
  else entries[lineno] = lines;
}

let curContainer = null;
const forStack = [];
const seenField = {};
let slotCursor = 0; // 当前容器内已插入的槽位数

function resetContainer() {
  forStack.length = 0;
  slotCursor = 0;
}

/* ── 预扫描：建立「顶层 for 循环 → 循环体行区间 → 插入次数/内层循环数」索引 ── */
const loopInfo = new Map(); // 行号 → {cnt, innerLoops:[{line,cnt}], inserts, start, end}
{
  const stack = [];
  for (let i = 0; i < srcLen; i++) {
    const raw = src[i];
    const t = raw.trim();
    if (t === "" || t.startsWith("--")) continue;
    const fm = t.match(/^for\s+(\w+)\s*=\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)(?:\s*,\s*(-?[\d.]+))?\s+do$/);
    if (fm) {
      const step = fm[4] ? Number(fm[4]) : 1;
      const cnt = step ? Math.floor((Number(fm[3]) - Number(fm[2])) / step) + 1 : 0;
      const isFloat = String(fm[2]).includes(".") || String(fm[3]).includes(".");
      const node = {
        v: fm[1],
        a: fm[2],
        b: fm[3],
        st: fm[4],
        cnt,
        isFloat,
        start: i + 1,
        depth: raw.length - raw.trimStart().length,
        innerLoops: [],
        inserts: 0,
        end: 0,
        total: 0,
      };
      if (stack.length) stack[stack.length - 1].innerLoops.push(node);
      stack.push(node);
      continue;
    }
    if (/^end\s*$/.test(t) && stack.length) {
      const node = stack.pop();
      node.end = i + 1;
      if (stack.length === 0) loopInfo.set(node.start, node);
      continue;
    }
    if (stack.length && /^table\.insert\([^,]*\.widget\.slotpos/.test(t)) {
      stack[stack.length - 1].inserts++;
    }
  }
  // 计算每个顶层循环的总槽位数
  for (const node of loopInfo.values()) {
    if (node.innerLoops.length > 0) {
      // 内层循环的次数中最大的那个 = 列数（嵌套内层时取各内层之积，这里最多两层）
      let cols = 0;
      for (const inner of node.innerLoops) {
        const innerTotal =
          inner.innerLoops.length > 0
            ? inner.innerLoops.reduce((a, b) => a * b.cnt, 1)
            : inner.cnt;
        cols = Math.max(cols, innerTotal);
      }
      node.cols = cols;
      node.total = node.cnt * cols;
    } else {
      node.cols = node.inserts;
      node.total = node.cnt * node.inserts;
    }
  }
}

/* 行号 → 它所处的最内层顶层 for（用于 slotpos insert 描述所在位置） */
const loopOfLine = new Map();
for (const [start, node] of loopInfo) {
  for (let k = start; k <= node.end; k++) loopOfLine.set(k, node);
}

for (let i = 0; i < srcLen; i++) {
  const n = i + 1;
  const raw = src[i];
  const t = raw.trim();
  if (t === "" || t.startsWith("--")) continue;
  {
    const dm = t.match(/^params\.([A-Za-z0-9_]+)\s*=\s*(.*)$/);
    if (dm && /^\s{0,4}params\./.test(raw) && /^\s*$|^(\{|deepcopy\(|params\.)/.test(dm[2])) {
      curContainer = dm[1];
      resetContainer();
    }
  }
  if (done.has(n)) continue;

  /* 1) 蓝图声明：params.X = { / deepcopy( / params.Y */
  let m = t.match(/^params\.([A-Za-z0-9_]+)\s*=\s*(deepcopy\(|params\.|\{)?/);
  if (m && /^\s{0,4}params\./.test(raw) && m[2]) {
    const name = m[1];
    const alias = /^\s*params\./.test(t);
    const dc = /^\s*deepcopy\(/.test(t);
    curContainer = name;
    resetContainer();
    const desc = CONTAINER_DESC[name] ?? "（未登记身份的容器）";
    const out = [`-- 【蓝图：${name}】${desc}`];
    if (alias) {
      out.push(
        "--   ⚠ 疑似缺陷：**引用赋值**（params.X = params.Y），不是 deepcopy。",
        "--     ⇒ params.X 与 params.Y 指向**同一张表**，改一个等于改两个。",
        "--     本文件对同类派生多用 deepcopy（第 116/128/678/944/950 行等），此处属少数派。",
        "--     当前无后续修改故无害；模组若改 params.Y.widget.* 会连带影响 X。仅标注，不改代码。"
      );
    } else if (dc) {
      out.push(
        "--   ★ 由 deepcopy 派生：布局/美术/槽位全部继承，只覆盖个别字段。",
        "--   ★ 对照第 1663-1666 行 sunkenchest 的原注释：作者在那里**刻意拒绝**派生，",
        "--     理由是「确保它不会被共享表意外搞坏」—— 可见共享风险是团队共识。"
      );
    }
    add(n, out);
    continue;
  }

  /* 2) 顶层 for 循环（用预扫描得到的精确信息） */
  const node = loopInfo.get(n);
  if (node) {
    const short = (CONTAINER_DESC[curContainer] ?? curContainer ?? "").split("（")[0];
    if (node.inserts === 0 && node.innerLoops.length === 0) {
      // 这是 slotbg 专用的循环（只填底纹，不产生槽位）
      add(n, [
        `-- 底纹批量填充循环：${node.v} = ${node.a} … ${node.b} → **${node.cnt} 次**。`,
        "--   ★ 只往 slotbg 塞贴图、**不产生槽位**——槽位由 slotpos 决定。",
        short
          ? `--   ⇒ 它的次数必须与「${short}」的 slotpos 数量严格相等，否则底纹会错位。`
          : "--   ⇒ 次数必须与 slotpos 数量严格相等。",
      ]);
      continue;
    }
    const out = [
      `-- ★ 槽位生成循环（顶层）：${node.v} = ${node.a} … ${node.b}${node.st ? `，步长 ${node.st}` : ""} → **${node.cnt} 轮**${node.isFloat ? "，★ 含半格偏移（坐标原点不在整数格上）" : ""}。`,
    ];
    if (node.innerLoops.length > 0) {
      const inner = node.innerLoops[0];
      out.push(
        `--   内层循环：${inner.v} = ${inner.a} … ${inner.b}${inner.st ? `，步长 ${inner.st}` : ""} → **${inner.cnt} 列**。`
      );
    } else {
      out.push(`--   每轮直接插入 ${node.inserts} 个 slotpos 坐标（无内层循环）。`);
    }
    out.push(
      `--   ⇒ 槽位总数 = ${node.cnt} × ${node.cols} = **${node.total} 个槽**` +
        (short ? `，即「${short}」的 numslots。` : "。")
    );
    out.push(
      "--   ★ numslots 由 containers.lua:15 的 `#widget.slotpos` 数出——改这里的数字就改了容量，",
      "--     而从代码表面看不出来。判定处见 components/container.lua:107 IsFull。",
      `--   ★ 插入顺序 = 槽位编号顺序（slot 1 … slot ${node.total}），存档按编号还原`
    );
    add(n, out);
    continue;
  }

  /* 3) 内层 for */
  m = t.match(/^\s+for\s+(\w+)\s*=\s*(-?[\d.]+)\s*,\s*(-?[\d.]+)(?:\s*,\s*(-?[\d.]+))?\s+do/);
  if (m) {
    const step = m[4] ? Number(m[4]) : 1;
    const cols = step ? Math.floor((Number(m[3]) - Number(m[2])) / step) + 1 : 0;
    const outer = loopOfLine.get(n);
    add(n, [
      `-- 内层循环：${m[1]} = ${m[2]} … ${m[3]}${m[4] ? `，步长 ${m[4]}` : ""} → **${cols} 列**。`,
      outer
        ? `--   ★ 外层 ${outer.cnt} 轮 × 内层 ${cols} 列 = **共 ${outer.cnt * cols} 个槽位**。`
        : "--   （未识别到外层循环）",
    ]);
    continue;
  }

  /* 4) 顶层 end */
  if (/^end\s*$/.test(t)) {
    const owner = [...loopInfo.values()].find((x) => x.end === n);
    if (owner) {
      add(n, [
        `-- 循环结束：已插入 **${owner.total} 个** slotpos 坐标，本容器的 numslots 定为 ${owner.total}。`,
      ]);
    }
    continue;
  }

  /* 5) table.insert slotpos */
  if (/^table\.insert\([^,]*\.widget\.slotpos/.test(t)) {
    slotCursor++;
    const loop = loopOfLine.get(n);
    const isPlus = /\+\s*\d|\+\s*75|\+\s*80/.test(t);
    const slotNo = loop
      ? isPlus
        ? `每轮的**第 2 个**坐标（同行向右偏移一格的那一列）`
        : `每轮的**第 1 个**坐标`
      : "按插入顺序编号";
    add(n, [
      `-- 向 slotpos 追加一个槽位坐标：${slotNo}。本容器累计第 ${slotCursor} 次插入。`,
      "--   ★ Vector3 是**绝对屏幕坐标**（不是相对容器的局部坐标）；数组顺序 = 槽位编号顺序。",
    ]);
    continue;
  }

  /* 6) table.insert slotbg */
  if (/^table\.insert\([^,]*\.widget\.slotbg/.test(t)) {
    add(n, [
      "-- 向 slotbg 追加与该槽对应的底纹贴图（纯装饰，容器逻辑从不读）。",
      "--   ★ 必须与 slotpos **严格一一对应**，否则格子底图会错位。",
    ]);
    continue;
  }

  /* 7) 容器级字段覆盖：params.X.widget.<f> = v */
  m = t.match(/^params\.[A-Za-z0-9_]+\.(?:widget\.)?([A-Za-z0-9_]+)\s*=\s*(.+)$/);
  if (m && /^\s*params\./.test(raw)) {
    const f = m[1];
    const doc = FIELD_DOC[f];
    const val = m[2].replace(/,$/, "");
    if (doc) {
      add(n, [...doc, "--   ★ 这是「派生后覆盖单个字段」：蓝图其余部分保持继承。"]);
    } else {
      add(n, [
        `-- 覆盖字段 ${f} = ${val}。`,
        "--   ★ 派生式配置的最小粒度：只改一处、其余继承。",
      ]);
    }
    continue;
  }

  /* 8) 表内字段（缩进 >= 4） */
  m = t.match(/^([A-Za-z0-9_]+)\s*=\s*(.+?),?$/);
  if (m && /^\s{4,}/.test(raw)) {
    const f = m[1];
    const val = m[2].replace(/,$/, "");
    if (f === "type") {
      const key = val.replace(/"/g, "");
      add(n, [
        `-- type = "${key}"`,
        `--   ${TYPE_DOC[key] ?? "（未登记语义）"}`,
        "--   ★ 全文件 type 取值：chest×24 / cooker×21 / pack×6 / hand_inv×6 /",
        "--     side_inv_behind×3 / backpack×2 / inv×1 / top_rack×1 / chest_addon（动态）。",
      ]);
    } else if (doc2(f)) {
      const first = seenField[f];
      if (first === undefined) {
        seenField[f] = n;
        add(n, doc2(f));
      } else {
        add(n, [
          `-- ${f}：同第 ${first} 行（首次定义），此处值 = ${val}。`,
        ]);
      }
    }
    continue;
  }

  /* 9) slotpos 内联的 Vector3 */
  if (/^Vector3\(/.test(t)) {
    slotCursor++;
    add(n, [
      `-- 内联槽位坐标（本容器第 ${slotCursor} 个 slot）。`,
      "--   ★ 数组内先后顺序 = 槽位编号顺序。",
    ]);
    continue;
  }
}

function doc2(f) {
  const d = FIELD_DOC[f];
  if (!d) return null;
  return d;
}

const sorted = Object.keys(entries)
  .map(Number)
  .sort((a, b) => a - b);

// 统一补 `-- ` 前缀（FIELD_DOC 等表里有些条目为省事未带前缀）
function withPrefix(c) {
  const body = c.startsWith("--") ? c : "-- " + c;
  return body.replace(/\s+$/, "");
}
for (const k of sorted) entries[k] = entries[k].map(withPrefix);

let out = `/**
 * spec-containers-dense.mjs —— containers.lua 密集注释（结构性代码行补齐）
 *
 * 由 gen-dense-params.mjs 依据 FIELD_DOC / TYPE_DOC / CONTAINER_DESC 三张人工表生成：
 *   · widget 每个字段都有**专属释义**（不是统一套话）
 *   · 同一字段第二次出现只写「同第 N 行 + 本行实际值」，避免注释复读
 *   · 槽位循环先解析 for 范围，算出「行 × 列 = 槽数」再写
 *   · 蓝图声明行附容器身份与别名/deepcopy 的语义
 */

export const HEADER_EXTRA = [];

export const BEFORE = {
`;
for (const k of sorted) {
  out += `  ${k}: [\n`;
  for (const c of entries[k]) out += `    ${JSON.stringify(c)},\n`;
  out += "  ],\n";
}
out += "};\n\nexport const AFTER = {};\n";

writeFileSync(join(__dirname, "spec-containers-dense.mjs"), out, "utf8");
console.log(`✔ 生成 spec-containers-dense.mjs：${sorted.length} 个锚点`);