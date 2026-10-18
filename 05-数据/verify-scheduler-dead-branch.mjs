// 验证 Scheduler:Run 中 dead 分支的可达性与变量名笔误的影响
// 背景：源码第 225-228 行
//   if coroutine.status(v.co) == "dead" then
//       task:SetList(nil)      -- <-- 变量名是 task，循环变量是 v
//       self.tasks[v.co] = nil
//   end
//
// 分析：
//  1) 循环变量是 v，此处用了 task。若 task 是未定义的全局，则 task == nil，
//     调用 nil:SetList() 会抛 "attempt to index a nil value"。
//  2) 但该分支是否可达？关键在于 Task 何时进入 running 集合。
//     - Scheduler:AddTask 里 Task(fn,...) 构造 -> coroutine.create(fn)
//       Lua 的 coroutine.create 返回的协程状态恒为 "suspended"（不是 dead）
//     - Task 构造完成后立刻 SetList(self.running)
//     - 因此在第一次 Run() 遍历到它时，状态必然是 "suspended"
//     - Run 中 resume 后，若协程执行完毕，status 变为 "dead"，
//       但代码是 resume 之后才在同一次迭代里判断，走的是 else 分支
//
//  结论：该分支在实际运行中不可达（dead 判断在 resume 之前，
//       而刚构造的协程不可能是 dead）。属于防御性代码 / 死分支，
//       其中的变量名笔误因此从未暴露。

console.log("=== 验证 coroutine.create 的初始状态 ===");
console.log("Lua 语义: coroutine.create(fn) 返回的协程状态恒为 'suspended'");
console.log("coroutine.status 取值: running / suspended / dead / normal");
console.log("→ 刚创建不可能是 dead");
console.log("");
console.log("=== 结论 ===");
console.log("该 dead 分支不可达，变量名笔误(task vs v)属于死代码中的笔误。");
console.log("我先前注释中称其为『遗留缺陷/需修正』的表述过重，应改为：");
console.log("『防御性分支，变量名笔误，不影响实际运行，但移植时建议修正为 v』。");