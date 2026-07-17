# BackgroundAgentJob 以租约恢复，不设总时长超时

状态：有效。

BackgroundAgentJob 的承诺必须比单个进程、worker 和 turn 更长寿。活性由
ActorRuntime 租约判断：worker 死亡或租约过期后，事件重新投递；新 worker
恢复 Job 私有 project，并用持久化的 `runtime_thread_id` 继续同一个 Codex
thread。

Job 不设置 wall-clock 总时长 timer，Plugin 也不能增加一个。总时长不是活性
事实，把它设成 runner 硬超时会把合法的长任务误判成故障。需要业务截止时间
时，由上层 workflow 决定何时 `steer` 或 `stop`。

真实执行机会最多五次。只有成功取得执行租约才消耗一次；placement 失败不
计数。机会耗尽后，control plane 以 `attempts_exhausted` 提交失败并唤醒
owner。

Codex app-server 与具体前台工具仍可使用协议级或调用级 timeout。这些 timeout
只处理一次调用的停滞，不构成 Job 总时长上限。

Agent Computer 把这个保证落在一个显式的 Job session 上：setup 只物化 project、
能力和 sandbox，session 独占 Codex client、thread、turn 与恢复计数，恢复动作由
无副作用的 transition table 决定。thread resume 和活跃 turn 共用一次 replacement
预算，瞬态重试和 compaction 也各有明确上限，所以 worker 内恢复不会变成无界循环。

详细契约见 `docs/design-docs/BackgroundAgentJob.md`。
