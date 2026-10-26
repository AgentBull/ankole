---
title: 审计轨迹
description: 如何阅读 Ankole 的审计面——AuthZ 授权记录、控制面结构化日志、各自记录了谁在何时改了什么。
section: Developer guide
order: 125
---

审计轨迹是"谁在何时改了什么"的持久记录。Ankole 没有单一审计日志；它有几个面，各自由不同子系统拥有，各自记录对自己要紧的决定。本页是这些面的运维者地图——各自记录什么、如何读取、如何配合使用。

先说明最关键的一点：每个审计面都是**持久 PostgreSQL 状态或结构化日志**，不是临时指标。写了的记录熬得过写它的进程；没写的记录无法重建。

## AuthZ 授权、人员访问变更与邀请记录

每条权限授予都是 `permission_grants` 表中的持久行。每条记录归属于单个 `principal_uid`、单个 `group_id`，或一个 Userset 页面受众（`source_page_id` 与 `source_action`），而 Pod ACL 权限授予则通过 `target_page_id` 与 `target_scope` 锚定到 `pages` 表行。`resource_pattern`、`action` 和 `condition` 标明允许的资源与操作，时间戳记录创建时间与最后更新时间。权限授予没有单独的审计日志——`permission_grants` 表本身就是记录。

人员账号生命周期变更与工作区邀请同样在 PostgreSQL 中写入持久记录：

- `human_access_events` 记录每次访问禁用、恢复或目录同步驱动的状态流转，包含操作者、来源、前后状态、`access_version` 以及释放的外部标识符（`released_identifiers`）。
- `human_access_restrictions` 保存当前生效的访问限制及其处置类型（`:suspended` 停用或 `:offboarded` 离职）与原因。
- `pod_invitations` 记录 Pod 工作区邀请、成员身份类型（`member` 或 `guest`）、已使用配额（`used_count`）以及创建人（`created_by_principal_uid`）。

通过 `GET /api/v2/principals/:uid/grants` 和 `GET /api/v2/principal-groups/:name/grants` 读取主体和权限组的权限授予。曾添加后又删除的授权可在 PostgreSQL 时间点恢复历史中追溯；当前存在的行即为系统实际执行的规则。

## 结构化控制面日志

控制面输出结构化日志，形态稳定——事件名、说明文字、结构化字段，严重级别从 `debug` 到 `error`。这些是运维事件的审计面：

- provider 调用（哪个 provider、哪个模型、结果）
- worker 生命周期（worker 启动、回合启动、回合完成或错误）
- 信号事件（到达了什么、被过滤还是被接受）
- 调度触发（何时、什么结果）

日志不是 PostgreSQL——它们由你的日志摄入器接收。需要用于审计时，实时发往持久存储（日志索引、S3 归档）。从未外发的日志随进程消失。

日志级别和格式见 [环境变量](../environment-variables/)，定位具体故障的方法见 [怎样阅读 Ankole 日志](../log-reading/)。

## Signal 与 delivery 行

每个 Signal（驱动 session 的持久收件箱）和每次 delivery 尝试是 PostgreSQL 里的一行。它们既是运维状态，也构成了系统被要求做什么以及是否已投递的记录。Console API 的 `/api/v2/background-agent-jobs/:id` 路由显示任务的 `attempts` 和 `error`；`/api/v2/ai-gateway/conversations` 路由显示一个回合做过的模型调用。

## 配合使用

一个真实的审计问题通常跨多个面：

| 问题 | 去哪查 |
|---|---|
| "谁给了这个 agent 或页面受众做 Y 的权限？" | `permission_grants` + `/api/v2/principals/:uid/grants` / `/api/v2/principal-groups/:name/grants` |
| "某个人员账号为什么被停用、离职或受邀加入？" | `human_access_events`、`human_access_restrictions` 与 `pod_invitations` |
| "这个回合 agent 做了什么？" | `/api/v2/ai-gateway/conversations/:id/messages` |
| "调度触发了吗？" | `/api/v2/cron-schedules/:id/runs` |
| "任务失败被重试了吗？" | `/api/v2/background-agent-jobs/:id`（`attempts`、`error`） |
| "那时 worker 日志记了什么？" | 结构化控制面日志 |

## 本指南不是什么

它不是合规框架——Ankole 提供界面，你的合规姿态决定保留多久。它不是 SIEM 集成指南——日志是结构化 JSON，摄入器是你的选择。它也不是经过测试的备份的替代——审计轨迹住在 PostgreSQL 里，无法还原的数据库带走轨迹。

## 下一步

- 权限模型见 [主体与 AuthZ](../principal-authz/)。
- 日志配置与排查方法，读 [环境变量](../environment-variables/)和 [怎样阅读 Ankole 日志](../log-reading/)。
- 保护轨迹的备份，读 [备份与还原](../backup-and-restore/)。
