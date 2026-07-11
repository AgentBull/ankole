# 失活恢复走租约重投加 thread resume，不设硬超时

委托的承诺必须比基础设施长寿：worker 失活由活性租约过期触发事件重投，新 worker 按持久化的 runtime thread id `thread/resume` 续跑（spike 已验证跨进程 resume 与 dynamic tools 存活），真实执行机会封顶 3 次，耗尽即 `attempts_exhausted` 失败终局并唤醒父会话。全链路不设任何工具层/委托层 wall-clock 硬超时——委托可合法运行数小时，卡死由租约过期判定而非计时器，wall-clock 判死会误杀合法长任务。

## Consequences

- attempts 只在真正取得执行租约时消耗，placement 失败（无 worker、容量满）不计数，事件保持 queued 再 defer。
- 原「worker 失活即 failed（`owner_worker_stale`）」路径删除，仅保留 attempts 超限终局语义。

出处：`internals/docs/SubagentDelegation.zh.md` §1 决策 3、§3.2–§3.4。
