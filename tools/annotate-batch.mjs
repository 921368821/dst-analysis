#!/usr/bin/env node
/**
 * annotate-batch.mjs —— 批量为Lua 文件插入中文文件头注释
 *
 * 策略：按模块分类 + 路径模式推导职责说明，为每个文件生成准确的中文文件头。
 *       保留原文件全部内容，仅在顶部插入注释块（不改任何代码）。
 *       已深度注释的文件（含本工具标记）会跳过，避免重复插入。
 *
 * 用法：node annotate-batch.mjs <源根> <目标根>
 */
import { readdirSync, statSync, readFileSync, writeFileSync, mkdirSync, existsSync } from "node:fs";
import { join, relative, dirname } from "node:path";

const [SRC, DST] = process.argv.slice(2);
if (!SRC || !DST) {
  console.error("用法: node annotate-batch.mjs <源根> <目标根>");
  process.exit(2);
}

function walk(dir, acc = []) {
  for (const n of readdirSync(dir)) {
    const p = join(dir, n);
    if (statSync(p).isDirectory()) walk(p, acc);
    else if (n.endsWith(".lua")) acc.push(p);
  }
  return acc;
}

/** 模块中文名映射 */
const MODULE_CN = {
  prefabs: "预制体",
  components: "组件系统",
  map: "地图与世界生成",
  stategraphs: "状态图（AI 行为机）",
  brains: "AI 大脑",
  widgets: "UI 控件",
  screens: "界面",
  behaviours: "行为树",
  scenarios: "冒险剧本",
  util: "工具函数",
  tools: "开发工具",
  languages: "本地化",
  cameras: "摄像机",
};

/** 顶层文件的中文职责说明（核心文件单独精写） */
const ROOT_DOC = {
  "class.lua": ["核心框架 / 面向对象基础设施", "整个游戏唯一的类系统。在纯 Lua 5.1 上实现单继承、属性 setter（写入拦截）、只读属性三项能力。全部游戏逻辑都基于它构建。"],
  "entityscript.lua": ["核心框架 / 实体", "实体（Entity）的 Lua 侧基类。定义实体的生命周期（OnSave/OnLoad/OnUpdate/LongUpdate/OnRemoveFromEntity）、事件总线、标签、定时任务与网络同步入口。这是理解整个引擎行为的枢纽文件。"],
  "main.lua": ["核心框架 / 主循环", "游戏主循环与初始化。注册各系统、驱动 tick 调度、初始化 TheWorld 之外的全局管理器。"],
  "scheduler.lua": ["核心框架 / 任务调度", "基于 tick 的协程调度器。实现 DoTaskInTime / DoPeriodicTask / StartThread 等延时与周期任务的底层机制。"],
  "prefab.lua": ["核心框架 / 预制体注册", "预制体注册表与 SpawnPrefab 工厂。管理 prefab 名到工厂函数的映射、网络哈希（prefab hash）的分配。"],
  "world.lua": ["世界系统", "世界实体与全局事件源。管理地图、寻路器、世界状态（白天/季节/天气）以及大量管理器组件。"],
  "constants.lua": ["常量定义", "全局常量表。游戏所有魔法数字、枚举值（物品栏槽位、工具类型、季节名等）的集中定义处。"],
  "actions.lua": ["动作系统", "玩家动作（挖掘、采集、攻击、建造等）的注册与执行逻辑。每个动作是一个 Action 对象，绑定动画、音效与网络同步。"],
  "bufferedaction.lua": ["缓冲动作", "动作队列（BufferedAction）。处理「长按操作」的进度、打断与多步动作串联。"],
  "inventory.lua": ["物品栏系统", "物品栏逻辑。管理物品堆叠、装备栏、容器与配方查找。"],
  "recipe.lua": ["合成系统", "合成配方定义与匹配逻辑。"],
  "stache.lua": ["储存系统", "小型储存容器（背包类）的物品存取。"],
  "player.lua": ["玩家角色", "玩家角色的实体脚本：属性、饥饿度、理智值、生命值、装备与状态效果。"],
  "playercontroller.lua": ["玩家控制", "玩家输入处理与角色移动控制。"],
  "brain.lua": ["AI 框架", "AI 大脑（Brain）基类。管理思考周期、状态图跳转与决策。"],
  "behaviourtree.lua": ["行为树框架", "行为树节点基类与运行时。AI 决策的另一种表达方式，与状态图并存。"],
  "stategraph.lua": ["状态图框架", "状态图（StateGraph）基类。AI 状态机的通用实现：状态、转换条件、OnEnter/OnUpdate/OnLeave。"],
  "widgets/widget.lua": ["UI 框架", "UI 控件基类。"],
  "modindex.lua": ["模组索引", "模组加载与索引。管理各模组的注册与加载顺序。"],
  "mods/modmanager.lua": ["模组管理", "模组管理器。控制模组的启用、禁用、配置与加载。"],
  "netvars.lua": ["网络变量", "网络同步变量的注册与定义。所有需要跨端同步的状态字段在此登记。"],
  "networkmanager.lua": ["网络管理", "网络会话管理。处理联机连接、玩家加入离开、心跳与超时。"],
  "gamesettings.lua": ["游戏设置", "全局游戏设置存取。"],
  "input.lua": ["输入处理", "键鼠/手柄输入的统一封装。"],
  "sim_persistent.lua": ["存档持久化", "存档数据的序列化与反序列化基类。"],
  "persist.lua": ["持久化", "存档系统的持久化层：世界数据、实体数据、玩家数据的存取。"],
  "worldsettings.lua": ["世界设置", "世界生成配置项的读取与默认值。"],
  "events.lua": ["事件定义", "全局事件名常量定义。"],
  "time.lua": ["时间系统", "游戏内时间推进：白天长度、季节循环、时间段查询。"],
  "weather.lua": ["天气系统", "天气类型定义与状态管理。"],
  "lighting.lua": ["光照系统", "光照计算与颜色管理。"],
};

/** 核心组件的机制说明（阅读时最需要知道的"为什么"） */
const COMPONENT_DOC = {
  sanity: "理智值随时间、恐怖事件、黑暗、怪物临近下降；受荧光棒、理智恢复物影响；归零后产生幻觉（Phantom）并进入 sanitydesat 状态。",
  hunger: "饥饿度随时间下降，进食恢复；归零后持续扣血。与 sanity/health 共同决定角色死亡原因。",
  health: "生命值与受伤、治疗、复活点相关；区分普通伤害与克制伤害（季节、生物属性）。",
  locomotor: "移动组件：处理水平/垂直速度、重力、跳跃、碰撞与地形约束。所有可移动实体都依赖它。",
  playercontroller: "玩家专用控制器：处理输入意图到移动的转换、控制台命令、网络同步的玩家位置。",
  network: "网络组件：管理实体的网络 ID、是否为副本（replica）、脏标记（dirtybit）与兴趣管理可见性。",
  transform: "底层变换组件（C++ 提供）：世界坐标、旋转、缩放。",
  physics: "底层物理组件（C++ 提供）：碰撞体、重力、受力与阻挡。",
  animstate: "底层动画状态组件（C++ 提供）：播放动画、管理动画事件与帧回调。",
  inventory: "物品栏组件：管理持有物品、装备栏、容器开合。",
  equippable: "可装备组件：处理物品装备到插槽、属性加成与耐久。",
  fueled: "燃料组件（篝火、矿灯等）：管理燃料值、燃烧状态与熄灭条件。",
  workable: "可工作组件：斧/镐/锄对实体的挖掘修理，耐久与效率。",
  useableitem: "可使用物品组件：右键使用行为（火把、药丸等）。",
  talkable: "可对话组件：NPC 对话交互。",
  updatableperiodiccomponent: "周期性更新基类：抽象出「每 N tick 执行一次」的模板方法，是所有周期行为的父类。",
  periodiccomponent: "旧版周期组件基类，功能同上。",
  entityscript: "实体脚本组件基类：所有实体行为的默认实现，提供最小可用的事件与更新接口。",
  eventlistener: "事件监听组件：注册到 TheWorld 事件总线，按事件名触发回调。",
  dynamicphysics: "动态物理组件：使实体受重力与碰撞影响，可被推挤、掉落。",
  environmentusetarget: "环境交互目标：标记实体可被玩家执行特定动作（挖、捡、开启）。",
  deployable: "可部署组件：物品放置为实体的逻辑（放篝火、建墙）。",
  stackable: "可堆叠组件：定义物品的堆叠上限。",
};

/** 从文件名/路径推断职责 */
function inferDoc(rel) {
  const parts = rel.split(/[\\/]/);
  const file = parts[parts.length - 1];
  const dir = parts.length > 1 ? parts[parts.length - 2] : "";

  // 命中精确映射
  const key = file;
  if (!parts.slice(0, -1).length && ROOT_DOC[key]) return ROOT_DOC[key];

  /** 预制体领域分类：按文件名前缀/关键词推断中文类别 */
function prefabCategory(stem) {
  const s = stem.toLowerCase();
  if (/^sg[a-z]/.test(s)) return "AI 状态图关联";
  if (/^(meat|monster|mobs)/.test(s) || /hound|eyeplant|spider|walker|grue|pigman|leech/.test(s)) return "敌对生物";
  if (/^(rock|reef|boulder|trees|grass|grass_tuft|tallgrass|flower|bush|reeds|vine|petal|eyeblossom)/.test(s)) return "自然与资源";
  if (/^structure/.test(s)) return "建筑结构";
  if (/^animated|moleworm|eyeplant|spider_dropper|slime_mound|butterfly|beaver|rabbithole|rock_eyeplant/.test(s)) return "环境动画";
  if (/wall|door|gate|fence|floor|window|portal|chest|container|crate|barrel|box|chest|coffin|grave|tomb|pyre|bell|jukebox|rock|/i.test(s)) return "建筑与容器";
  if (/^season|clock|moon|rain|lightning|snow|precip|weather|day|dusk|night/.test(s)) return "时间与环境";
  if (/^player|^character|wilba|willow|webber|wolfgang|wendy|wxanderer|warly|worden|wicker|wurt|wortox|warly|wolfgan/.test(s)) return "角色";
  if (/^admin|server|client|net_|steam|dedicated/.test(s)) return "联机与服务器";
  if (/^fx|_fx|light|particle|spark|smoke|fire/.test(s)) return "特效与光照";
  return "通用预制体";
}

  // prefabs/<名字>.lua（扁平结构，无分类子目录）
  if (dir === "prefabs") {
    const stem = file.replace(/\.lua$/, "");
    return [`预制体 / ${stem}（${prefabCategory(stem)}）`,
      `实体「${stem}」的预制体定义。SpawnPrefab("${stem}") 会执行本文件中的同名工厂函数：创建原生实体、添加底层组件与标签，再挂载其 Lua 组件。\n--   阅读要点：先看工厂函数里 AddComponent 的调用，可知该实体具备哪些行为。`];
  }
  if (dir === "components") {
    const stem = file.replace(/\.lua$/, "");
    const extra = COMPONENT_DOC[stem] ? `\n--   关键机制：${COMPONENT_DOC[stem]}` : "";
    return [`组件 / ${stem}`,
      `组件「${stem}」的实现。组件是挂在实体上的行为单元，通过 inst.components.${stem} 访问，负责本实体的某一类状态与逻辑。${extra}`];
  }
  if (dir === "stategraphs") {
    const stem = file.replace(/\.lua$/, "");
    return [`状态图 / ${stem}`, `状态图「${stem}」。定义该生物/对象的状态机：有哪些状态、状态间的转换条件，以及各状态进入/更新/离开时的行为。`];
  }
  if (dir === "brains") {
    const stem = file.replace(/\.lua$/, "");
    return [`AI 大脑 / ${stem}`, `大脑「${stem}」。驱动对应状态图的思考周期与决策，包括目标选择、情绪/好奇心等大脑参数的变化。`];
  }
  if (dir === "widgets") {
    const stem = file.replace(/\.lua$/, "");
    return [`UI 控件 / ${stem}`, `控件「${stem}」的实现：布局、渲染、输入响应与鼠标交互。`];
  }
  if (dir === "screens") {
    const stem = file.replace(/\.lua$/, "");
    return [`界面 / ${stem}`, `界面「${stem}」。一个全屏场景的 UI，含打开/关闭流程、控件组装与动画。`];
  }
  if (dir === "behaviours") {
    const stem = file.replace(/\.lua\/$/, "").replace(/\.lua$/, "");
    return [`行为树 / ${stem}`, `行为树节点「${stem}」。可复用的 AI 决策片段，被大脑与状态图组合调用。`];
  }
  if (dir === "map") {
    const stem = file.replace(/\.lua$/, "");
    return [`地图生成 / ${stem}`, `世界生成相关：「${stem}」。参与地形、生物群系、资源分布与任务布置的生成流程。`];
  }
  if (dir === "scenarios") {
    const stem = file.replace(/\.lua$/, "");
    return [`剧本 / ${stem}`, `冒险剧本「${stem}」的逻辑脚本：布置场景、配置任务链与胜利/失败条件。`];
  }
  const modName = MODULE_CN[dir] || dir;
  const stem = file.replace(/\.lua$/, "");
  return [`${modName} / ${stem}`, `${modName}模块中的「${stem}」。具体职责请结合函数实现阅读——本文件属于该模块的组成部分。`];
}

const MARK = "--============================================================";
const files = walk(SRC);
let done = 0;
let skipped = 0;

for (const src of files) {
  const rel = relative(SRC, src);
  const dst = join(DST, rel);

  const raw = readFileSync(src, "utf8");

  // ★ 保护已存在的深度注释版。
  //   深度注释版的标记可能位于文件头任意位置（不一定紧跟首行），
  //   因此不能用 startsWith(MARK) 判断，必须在整份内容里搜标记。
  //   （此前用 startsWith + 写回源内容，已导致 entityscript.lua 的 5194 行深度注释被冲掉）
  if (existsSync(dst)) {
    const cur = readFileSync(dst, "utf8");
    if (cur.includes("【深度注释版】")) {
      skipped++;
      continue;
    }
  }

  // 已带文件头的则跳过（源文件本身已注释过的情况）
  if (raw.startsWith(MARK)) {
    mkdirSync(dirname(dst), { recursive: true });
    writeFileSync(dst, raw, "utf8");
    skipped++;
    continue;
  }

  const [module, desc] = inferDoc(rel);
  const stem = rel.split(/[\\/]/).pop().replace(/\.lua$/, "");
  const header =
    `${MARK}\n` +
    `-- 文件：${rel.replace(/\\/g, "/")}\n` +
    `-- 模块：${module}\n` +
    `-- 职责：${desc}\n` +
    `-- 上游来源：Klei Entertainment《Don't Starve Together》游戏脚本\n` +
    `${MARK}\n\n`;

  mkdirSync(dirname(dst), { recursive: true });
  writeFileSync(dst, header + raw, "utf8");
  done++;
}

console.log(`已生成中文文件头: ${done} 个，跳过(已注释): ${skipped} 个，共 ${files.length} 个文件`);
console.log(`输出目录: ${DST}`);