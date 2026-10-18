// spec-world.mjs —— prefabs/world.lua 注释规格汇总入口
// 逐段合并 spec-world-p1..p4.mjs 的 BEFORE / AFTER 映射。
// 同一行号被多段命中时把注释**拼接**（全部是 `--` 注释行，拼接不改变语义）。

const parts = await Promise.all([
  import("./spec-world-p1.mjs"),
  import("./spec-world-p2.mjs"),
  import("./spec-world-p3.mjs"),
  import("./spec-world-p4.mjs"),
]);

export const HEADER_EXTRA = [
  "--",
  "--【阅读导航】",
  "--  §零   依赖与资源清单（1-66）        —— 世界预制体为什么自带 asset 依赖",
  "--  §一   预制体清单（68-296）           —— ★ world prefab 是「全预制体」的根",
  "--  §二   玩家出生与游戏数据（298-333） —— 两级 DoTaskInTime 合并广播",
  "--  §三 ★ PostInit（335-355）           —— 装配收尾 + 状态变更自动推送",
  "--  §四   销毁与碰撞集（357-397）       —— TheWorld 单例的断言式拆解",
  "--  §五 ★★ MakeWorld 工厂（401-616）   —— 本文件的心脏",
  "--  §六   单例建立时序（414-437）       —— ★ TheWorld 在第 422 行被赋值",
  "--  §七   底层组件装配（439-457）       —— 五个 C++ 侧实体组件",
  "--  §八   地图渲染层建立（459-523）     —— 三轮循环：地面/苔藓/衰减",
  "--  §九 ★★ 23 个管理器组件（525-610）   —— 逐个职责说明，见下方清单",
  "--  §十   入口（615-618）               —— Prefab() 与 MakeWorld 的自我调用",
  "--",
  "--【本文件最重要的八条】",
  "--  1. ★★「世界」是一个 prefab，不是引擎里的特殊对象。",
  "--     TheWorld 的类型是 Entity，寿命受普通实体的 Remove/DoTaskInTime 管理。",
  "--     这一个决定统一了「世界」与「实体」：世界能加组件、能监听事件、能被遍历。",
  "--     参见第 401 行的 MakeWorld 与第 615 行的 Prefab() 封装。",
  "--  2. ★ 全局事件总线 = TheWorld 自己。TheWorld:PushEvent / inst:ListenForEvent",
  "--     走的是 entityscript.lua 的实体事件机制，只是**换了个实体当总线**。",
  "--     答案在 entityscript.lua:2966 ListenForEvent 与 :3156 PushEvent_Internal：",
  "--     事件能力是所有实体共有的，TheWorld 恰好是寿命最长、谁都可达的那个。",
  "--     命名空间 `ms_` 前缀是给「服务端世界」事件的固定约定（如 :349 ms_* 监听）。",
  "--  3. ★★ Ents 表是全局实体注册表，键是 GUID。定义在 main.lua:289，",
  "--     不是本文件；本文件第 305 行是它最典型的读法（全表遍历找玩家）。",
  "--     遍历 Ents 代价与实体总数成正比，见该行的性能注记。",
  "--  4. ★★★ ismastersim（第 426 行）是**端判定**的唯一权威：",
  "--     主机与专服为 true，纯客户端为 false。第 348 行与第 564 行两处用它分流。",
  "--     第 427 行的 ismastershard 进一步区分「主分片」——多分片集群里",
  "--     洞穴分片虽然也是 master sim，但不是 master shard。",
  "--  5. ★ 组件装配被三层条件切开：全部端 525-562 → 非专服 553-557 → 主 sim 568-610。",
  "--     第 564-566 行的提前 return 是整个函数的性能命门：客户端在此直接返回。",
  "--  6. ★★ 第 417-420 行的重复世界检查会 `print` 后 return nil，",
  "--     但此时 CreateEntity() 已经执行（第 415 行），实体已被创建却不会被清理。",
  "--  7. 第 358-365 行的销毁顺序：先删 minimap，再断言 TheWorld 就是自己，",
  "--     然后清空 TheWorld 与 TheFocalPoint。断言（assert）是防止误删的护栏。",
  "--  8. ★ 第 501-502 行 StartHop 的一对互斥断言是「参数自洽性校验」的范本：",
  "--     has_platform 与 platform 是否为 nil 必须相反。这类校验在 networkclientrpc.lua",
  "--     里被系统化为 check*/opt* 谓词（networkclientrpc.lua:4-13）。",
  "--",
  "--【★ 23 个管理器组件逐个职责（源文件第 525-598 行，条件不同）】",
  "--  —— 全端无条件（525-562），客户端也需要 ——",
  "--   :525 worldsettings          世界设置键值袋 + 监听 ms_setworldsetting",
  "--                              （见 components/worldsettings.lua，仅 23 行）",
  "--   :528 worldstate             ★ 世界 Lua 状态（cycles/season 等）的所有者，",
  "--                              :529 把 inst.state 直接别名到它的 data",
  "--   :532 groundcreep            地表苔藓/地衣的渲染与铺设（配合 :447 AddGroundCreep）",
  "--   :559 walkableplatformmanager 可站平台（船/矿车）的全局登记表与容量仲裁",
  "--                              （配合 walkableplatform.lua；locomotor 的跳跃预约对象）",
  "--   :561 waterphysics           水体物理，:562 restitution=0.75 即水面弹性",
  "--  —— 仅非专服（553-557，客户端也要）——",
  "--   :554 oceancolor             海水颜色渐变表现，纯客户端表现层",
  "--   :555 nutrients_visual_manager 土壤营养的视觉表现（不含逻辑，逻辑在 farming_manager）",
  "--   :556 hudindicatablemanager   HUD 图标的全局注册与显示仲裁",
  "--  —— 仅主模拟（568-610，客户端在 :565 已 return）——",
  "--   :568 shardtransactionsteps  ★ 跨分片事务的分步提交（仅 master sim，",
  "--                              次分片另有 shard_mermkingwatcher，见 shardnetworking.lua:52）",
  "--   :570 klaussackloot          小鸡与神秘雕像相关（Klaus Sack 的战利品机制）",
  "--   :572 undertile              地板之下的洞穴层实体管理（双向世界）",
  "--   :574 worldsettingstimer     ★ 世界设置变更的定时器回调（组件在 components/ 下有实体）",
  "--   :575 timer                  通用定时器（DoPeriodicTask 的宿主）",
  "--   :577 farming_manager        农场全局规则：季节掉率、肥沃度、腐化",
  "--   :579 dockmanager            码头/龙骸类停靠点的全局管理",
  "--   :580 vinebridgemanager      藤蔓桥的生成与维护（配合 :276 vine_bridge_fx 预制体）",
  "--   :581 worldroutes            世界路线图数据（地图 UI 与传送点）",
  "--   :583 playerspawner          ★ 出生点选择与出生流程（:269 SpawnAtNextLocation 的宿主）",
  "--   :585 nightlightmanager      夜晚光照管理（无光道具、照明衰减）",
  "--   :586 winonateleportpadmanager 汇智之帽传送基座的全局登记",
  "--   :588 corpsepersistmanager    ★ 尸体跨会话保留（死亡掉落物不消失）",
  "--   :591 skeletonsweeper        骨骼清理：分片扩容时清扫游离骨骼",
  "--   :598 uniqueprefabids        预制体 ID 去重，防止同批生成重复实体",
  "--",
  "--【⚠ 关于「时钟类组件不在本文件」】",
  "--   clock / seasons / worldtemperature / worldvoter / autosaver / worldreset /",
  "--   shardstate 这 7 个组件注册在 prefabs/world_network.lua:52-61，",
  "--   由 gamelogic.lua 挂到 TheWorld.net（net.lua 预制体）上，而不是 TheWorld 本体。",
  "--   所以「世界 = TheWorld」严格说是 **两个实体**：TheWorld（本体）与 TheWorld.net",
  "--   （联网壳）。这个分裂在 world.lua:423 `inst.net = nil` 与 :336-338 的",
  "--   `if inst.net ~= nil then inst.net:PostInit() end` 处可以看得很清楚。",
  "--   参见 networking.lua:186（TheWorld.net.components.worldcharacterselectlobby）。",
  "--",
  "--【★ 移植时最需要重写的三处】",
  "--  · 419 行的重复世界检查：应改成 SpawnPrefab 前置检查，或在 :415 CreateEntity",
  "--    之后补 inst:Remove()，避免实体泄漏；",
  "--  · 463/466 行的 NOTES 明确警告「地图 finalize 之后再调用会崩溃」，",
  "--    任何重排初始化顺序的改动都必须复查这两行；",
  "--  · 491-493 行的 TODO：渲染层 handle 在世界销毁时没有释放，",
  "--    现在靠「世界寿命 = 游戏寿命」掩盖了问题，多世界/重连场景会暴露。",
];

function merge(field) {
  const out = {};
  let merged = 0;
  for (const p of parts) {
    for (const [k, v] of Object.entries(p[field] ?? {})) {
      if (out[k] !== undefined) {
        out[k] = [...out[k], ...v];
        merged++;
      } else {
        out[k] = v;
      }
    }
  }
  if (merged) console.log(`[info] world.mjs ${field} 有 ${merged} 处行号被多段命中，已拼接`);
  return out;
}

export const BEFORE = merge("BEFORE");
export const AFTER = merge("AFTER");

const srcLineCount = 619;

// 覆盖率自检：确保没有大段连续区域完全没有注释锚点
const commented = new Set([
  ...Object.keys(BEFORE).map(Number),
  ...Object.keys(AFTER).map(Number),
]);
let run = 0;
const gaps = [];
for (let i = 1; i <= srcLineCount; i++) {
  if (commented.has(i)) {
    if (run > 0) gaps.push(`${i - run}-${i - 1}`);
    run = 0;
  } else {
    run++;
  }
}
if (run > 0) gaps.push(`${srcLineCount - run + 1}-${srcLineCount}`);

const bigGaps = gaps.filter((g) => {
  const [a, b] = g.split("-").map(Number);
  return b - a + 1 >= 25;
});
if (bigGaps.length) {
  console.log(`[warn] world.mjs 以下区段（≥25 行）尚无注释锚点: ${bigGaps.join(", ")}`);
}