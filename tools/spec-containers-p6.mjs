/**
 * spec-containers-p6.mjs —— containers.lua 补漏锚点
 * 覆盖前半段若干未被 p1-p5 覆盖的关键行（widget 字段语义、深度漏斗等）
 */

export const BEFORE = {
  "containers.widgetsetup#1+15": [
    "-- ★ widget 表是「UI 蓝图」的容器：以下字段全集 ——",
    "--   · slotpos   —— 每个槽的绝对屏幕坐标（Vector3 数组）",
    "--   · slotbg    —— 每个槽的底纹贴图（table 数组，与 slotpos 一一对应）",
    "--   · animbank/animbuild —— UI 贴图库名与构建名（客户端 C++ 侧读取）",
    "--   · animloop  —— 开门动画是否循环播放",
    "--   · animbank_upgraded/animbuild_upgraded —— 升级态贴图",
    "--   · pos       —— UI 整体位置偏移",
    "--   · posfn     —— 动态 pos（wx78 用）",
    "--   · side_align_tip / top_align_tip / bottom_align_tip —— 提示条对齐距离",
    "--   · side_align_tip_fn / top_align_tip_fn / bottom_align_tip_fn —— 动态版",
    "--   · slotscale / slotscalefn —— 格子缩放",
    "--   · slothighlightscale / slothighlightscalefn —— 高亮缩放",
    "--   · slotposfn —— 动态槽位坐标（wx78 用）",
    "--   · animfn    —— 动态贴图名（wx78 用）",
    "--   · opensound / closesound —— UI 开合音效",
    "--   · buttoninfo —— 按钮（text / position / fn / validfn）",
    "--   ★ 这些字段**全部只被 UI 层（widgets/containerwidget.lua）消费**，",
    "--     容器逻辑（components/container.lua）一个都不读。",
    "--     ⇒ 这是理解本文件的关键：widget 是纯表现层配置。",
  ],
  "containers.widgetsetup#1+20": [
    "-- ★ animbank 与 animbuild 同名：bank 是「贴图库」，build 是「库内构建名」。",
    "--   两者通常相同，UI 层用 build 从 bank 里取出可渲染的实例。",
  ],
  "containers.widgetsetup#1+24": ["-- ★ 容器组件里对应的字段名 issidewidget（无下划线）——蓝图到组件会做重命名。"],
  "params.cookpot.widget.buttoninfo.fn#1+3": [
    "-- ★★ 「客户端读 widgets 字段」的直接证据就在这一行：",
    "--   `item.dryingrack_lastinfo` 是**客户端组件上的运行时字段**。",
    "--   它由服务端在搬运失败时写回，客户端在渲染时读它来决定「哪一格高亮」。",
    "--   ⇒ 说明 dryingrack_lastinfo 通过某条同步链路到达客户端（很可能是 classified netvar）。",
    "--   ⚠ 风险：这个字段**在客户端与服务端的写入时机不一定同步**，",
    "--     若客户端判定早于同步，会出现「高亮错了格子」的短暂视觉 bug。",
  ],
  "params.bundle_container.widget.buttoninfo.validfn#1+2": [
    "-- ★ IsReadOnlyContainer 在 validfn 里出现（第 487 行）：只读容器连按钮都不能点。",
    "--   ⇒ 只读容器（readonlycontainer）是一个**端到端的三层开关**：",
    "--     服务端：CanTakeItemInSlot 第 275 行拒绝一切放入；",
    "--     客户端：IsReadOnlyContainer 让 UI 灰掉；",
    "--     事件层：EnableReadOnlyContainer 第 1618 行挂断言监听器，",
    "--              若有物品硬塞进去直接 assert(false)。",
  ],
  "IsConstructionSiteComplete#1+9": [
    "-- ★ 这里的 ingredients 来自建造站（constructionsite）而非容器本身。",
    "--   ⇒ 印证第 523 行的结论：建造容器的规则完全由「携带者」决定。",
  ],
  "params.livingtree_halloween.itemtestfn#1+21": [
    "-- ★ 冰箱的槽位坐标与 chester（第 85 行）**逐字相同**（80 间距 3x3）。",
    "--   ⇒ 冰箱 UI 与木箱 UI 用同一套坐标，美术换图即可 —— 布局参数已高度抽象。",
  ],
  "params.saltbox.itemtestfn#1+77": [
    "-- ★ 传送锅的按钮（ACTIVATE.GENERIC）是**空函数**（第 1137-1140 行），",
    "--   所以玩家点了没反应。与第 1187 行机房的「无 validfn（永远可点）」形成对比：",
    "--     传送锅 = 按钮可点但无效果；机房 = 按钮可点且有效果。",
  ],
  "params.balatro_machine.widget.buttoninfo.validfn#1+36": [
    "-- ★ quagmire_safe 用 deepcopy 而第 1230 行四连用赋值 —— 同区块两种风格。",
  ],
  "params.slingshot.itemtestfn#1+16": [
    "-- ★ 四个变体共享 itemtestfn：注意 slingshot999ex 是 slingshotex 的 deepcopy（1487 行），",
    "--   所以给它赋值等于「把 slingshotex 的判定也给它一份指针」。函数共享安全。",
  ],
  "params.battlesong_container.itemtestfn#1+13": [
    "-- ★ 魂罐的 slotpos 是 `{ Vector3(0, 0, 0) }` —— 单元格式，与第 1267 行沙尘蜂帽同型。",
    "--   ★ 单槽容器的标准写法：slotpos 数组长度 1 → 第 15 行得出 numslots = 1。",
  ],
  "typefn#1+5": [
    "-- ⚠ 注意第 2284 行被注释掉的 `excludefromcrafting = true`：",
    "--   柜子里的东西**参与合成搜索**（与第 1279 行沙尘蜂帽相反的取舍）。",
    "--   被注释而非写成 false，说明「暂时不排除」的意图留在了代码里。",
  ],
};

export const AFTER = {};