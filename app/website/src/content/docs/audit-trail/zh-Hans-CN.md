---
title: 审计轨迹
description: 如何查阅 Ankole 的审计记录：AuthZ 权限变更、人员访问事件、任务执行记录与控制面结构化日志。
section: Developer guide
order: 125
---

审计轨迹用于回答“谁在什么时间改动了什么”。Ankole 没有把所有事件塞进一张大一统的全局审计表，而是按领域边界由各子系统分别维护权威记录。本页为运维与安全人员梳理这些审计数据源，说明它们各自记录哪些事实、如何查询，以及如何交叉印证。

先明确一条基本原则：每一个审计数据源要么是 **PostgreSQL 中的持久化表记录**，要么是**实时外发的控制面结构化日志**，绝非易失的内存指标。只要记录已落盘或已发往外部日志系统，即使原工作进程重启也不会丢失；反之，从未外发的纯控制台日志一旦随容器销毁便无法找回。

## AuthZ 授权、人员访问变更与邀请记录

每一条权限授予都对应 `permission_grants` 表中的一行持久化记录。每行记录归属于单个主体（`principal_uid`）、单个权限组（`group_id`）或某类 Userset 页面受众（`source_page_id` 与 `source_action`）；Pod 页面级的 ACL 授权则通过 `target_page_id` 与 `target_scope` 锚定到具体的 `pages` 表记录。表中的 `resource_pattern`、`action` 和 `condition` 标明允许访问的资源与操作，时间戳记录创建时间与最后修改时间。权限系统不另设旁路审计表——`permission_grants` 表本身就是当前生效规则的权威账本。

人员账号的生命周期流转与工作区邀请同样在 PostgreSQL 中留有完整记录：

- `human_access_events`：记录每一次账号禁用、恢复访问或由企业目录同步触发的状态变更，完整包含操作人、触发来源、变更前后状态、`access_version` 以及释放解绑的外部身份标识（`released_identifiers`）。
- `human_access_restrictions`：保存当前正生效的访问限制记录、处置类别（`:suspended` 停用或 `:offboarded` 离职）及具体原因。
- `pod_invitations`：记录 Pod 工作区邀请链接、目标成员角色（`member` 正式成员或 `guest` 外部访客）、已使用次数（`used_count`）以及邀请创建人（`created_by_principal_uid`）。

日常核查时，可通过 `GET /api/v2/principals/:uid/grants` 和 `GET /api/v2/principal-groups/:name/grants` 接口直接查询指定主体或权限组当前持有的授权。若需追溯曾经授予但后来已被删除的历史权限，可通过 PostgreSQL 的时间点恢复（PITR）归档回查；而当前表中存在的行，即为运行时实际执行的权限规则。

## 结构化控制面日志

控制面持续输出格式稳定的结构化日志，每条日志均包含规范的事件名称、可读说明、结构化上下文字段以及从 `debug` 到 `error` 的严重级别。它是排查运行期动态事件的核心审计依据，覆盖：

- 上游 Provider 调用（目标 Provider、具体模型及调用结果）
- Worker 生命周期事件（实例拉起、回合开始、回合完成或异常退出）
- 信号接入事件（收到了什么外部事件、被规则过滤还是成功准入）
- 定时调度触发（触发时间点及执行结果）

请注意，日志不写入 PostgreSQL，而是输出到标准流供外部日志采集器收集。若有合规审计要求，请务必配置日志采集端将其投递至持久化存储（如集中式日志索引服务或 S3 归档桶）；未接入外部采集的容器本地日志会随进程销毁而消失。

日志级别与输出格式配置请参阅 [环境变量](../environment-variables/)，按日志排查具体故障的方法请参阅 [怎样阅读 Ankole 日志](../log-reading/)。

## Signal 与 delivery 行

每条进入系统的 Signal（驱动执行会话的持久化收件箱记录）以及每次对外消息投递（Delivery）尝试，在 PostgreSQL 中都对应独立的数据行。它们既是支撑断点恢复的运行状态，也忠实记录了“系统收到了什么指令”以及“回复最终是否送达”。此外，通过 Console API 的 `/api/v2/background-agent-jobs/:id` 路由可查看后台任务的尝试次数（`attempts`）与报错详情（`error`）；通过 `/api/v2/ai-gateway/conversations` 相关路由则可回溯某轮对话实际发起过的全部模型调用。

## 配合使用

实际开展安全或运维审计时，往往需要串联多个数据源交叉印证：

| 审计问题 | 查询位置 |
|---|---|
| “是谁给这个 Agent 或页面受众授予了执行某项操作的权限？” | `permission_grants` 表 + `/api/v2/principals/:uid/grants` / `/api/v2/principal-groups/:name/grants` |
| “某个员工账号为什么被停用、标记离职，或是由谁邀请进来的？” | `human_access_events`、`human_access_restrictions` 与 `pod_invitations` 表 |
| “在那一轮对话里，这个 Agent 具体调用了哪些模型和工具？” | `/api/v2/ai-gateway/conversations/:id/messages` |
| “某条定时任务当时有没有按时触发？” | `/api/v2/cron-schedules/:id/runs` |
| “某个后台任务报错后有没有自动重试？” | `/api/v2/background-agent-jobs/:id`（查看 `attempts` 与 `error` 字段） |
| “事发当时 Worker 容器和通道层报了什么错？” | 控制面结构化日志 |

## 本指南不是什么

本页不是企业合规制度模板——Ankole 负责提供完整的数据记录与查询接口，至于数据留存周期与归档策略，则取决于企业自身的安全合规要求。本页也不是特定 SIEM 平台的接入手册——控制面统一输出标准结构化 JSON 日志，运维团队可自由对接任意日志采集工具。最后，审计表本身不能替代定期验证的数据备份：核心审计记录全部保存在 PostgreSQL 中，一旦数据库损坏且无可用备份，审计线索也会随之灭失。

## 下一步

- 深入了解主体模型与运行时鉴权规则，请参阅 [主体与 AuthZ](../principal-authz/)。
- 配置日志输出格式与学习排障方法，请参阅 [环境变量](../environment-variables/)与 [怎样阅读 Ankole 日志](../log-reading/)。
- 为数据库与审计记录建立可靠的备份机制，请参阅 [备份与还原](../backup-and-restore/)。
