# 委托以 delegation actor session 为执行载体

Subagent 委托需要四种保证：同一委托绝无并发双跑、活性可判定、失活可重投、运行中可打断。我们没有建共享 runner 或 worker 本地 job 框架，而是给每条委托开一个专属 actor session（`{agent_uid, "subagent:<delegation_id>"}`），在现有 worker fleet 上以新 turn 种类执行——串行投递、活性租约、重投、打断全部由既有 actor 轨道白拿。父会话因此永不承载执行，只做编排与交付。

## Considered Options

- 共享 runner 进程 / worker 本地 JobQueue（原 `manager.ts` 形态）：四套保证机制都要重造，且队列与状态真相落在 worker 本地，与「委托是 durable 工作项、比基础设施长寿」的定位直接矛盾。已随本决策删除。

出处：`internals/docs/SubagentDelegation.zh.md` §1 决策 1、§3。
