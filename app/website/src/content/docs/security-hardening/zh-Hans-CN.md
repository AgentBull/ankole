---
title: 安全加固
description: 加固一套 Ankole 部署的端到端形态——最小权限、secret 纪律、SSRF、凭证轮换、最小入口。
section: Guides
order: 316
---

Ankole 自带安全边界——Principal/AuthZ、加密 secret、沙箱 worker、鉴权入口。加固不是加墙，而是把已有的边界收紧到你实际使用所需的最小面。本页走完运维者加固的五个面，按最先关闭最多风险的顺序。

先把决定性的性质说清楚：Ankole 的模型是*默认最小权限、仅在证据需要时扩展*。下面的每一步都在收窄一项权限、一个 secret 的影响范围、或一条网络路径。如果你发现自己在放宽某一项，问为什么——放宽才是值得审视的动作，不是收窄。

## 面 1：Principal 与 AuthZ 权限

agent 在它的 Principal 下运行，该 Principal 能做什么由 AuthZ 隔离。加固动作是*每个 agent 最小权限*，不是一个强大的 agent。

- **每个 agent 一个 Principal，每个 agent 一个用途。** 客户成功 agent 和代码 agent 应是不同 Principal，这样一个被入侵不等于两个都被入侵。
- **授予完成工作所需的最小权限。** 读一个频道的授予窄于写每个频道的授予；限定到具体 resource pattern 的授予窄于通配符。见 [Principal 与 AuthZ](../principal-authz/)。
- **同步 directory group，再按 group 授予。** 已同步的 AuthZ group 让你按团队成员身份限定权限，并在某人离开时通过在来源 directory 移除成员身份来撤销——而不是逐条编辑授予。
- **不确定时禁用，不要删除。** 被禁用的 Principal 跨部署立即失去权限；你可以重新启用。被删除的 Principal 的 uid 没了。

审计面是 `/permission-grants` 和 `/principals/:uid/grants`。定期读它们；创建时合理的授予会漂移成过多。

## 面 2：WorkerEnv secret 纪律

secret 住在 WorkerEnv 里，静态加密、每行一密钥。加固动作关乎*影响范围与轮换*，不关乎更强的加密。

- **少解密。** `POST /worker-envs/:name/decryptions` 是一项单独授权、可观测的动作。优先轮换 secret（设新值）而非解密旧的。见 [WorkerEnv secret](../worker-env/)。
- **能按 agent 限定就按 agent。** 一个全局 secret 触达每个 agent；按 agent 的 secret 触达一个。除非 secret 确实共享，优先按 agent 形态。
- **不要覆盖保留名。** `PATH`、`HOME`、`WORKER_ID`、`RUNTIME_FABRIC_URL`、`DATABASE_URL`、任何以 `ANKOLE_` 开头的，以及少量 sandbox 关键名，无法通过 WorkerEnv 覆盖——存储拒绝它们。不要绕开；这些名字被保留是因为 sandbox 或 worker 身份拥有它们。
- **按节奏轮换引导 secret。** `ANKOLE_SECRET_BASE` 和 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` 派生其它密钥；轮换它们是部署重启操作，被入侵的 `ANKOLE_SECRET_BASE` 影响范围是整套部署。

## 面 3：SSRF 与模型控制的抓取

带 `web_fetch` 的 agent 能让 Ankole 抓取 URL。`security.ssrf_filter` 是决定拒绝什么的 AppConfigure 键。

- **默认是 `false`——翻转它之前先读为什么。** Ankole 常作企业内部 agent 使用，内网访问是预期的；过滤器关闭，这样内部抓取能工作。
- **云元数据端点始终被挡**，无论设置如何。尝试读 `169.254.169.254` 的模型，无论过滤器开关都被拒绝。
- **过滤器开启时**，私网、环回、链路本地和 CGNAT 目标被拒。当 agent 从公网抓取、且没有合理理由触达内部 IP 时开启它——这就是过滤器为之存在的场景。

决定是按部署的，错的不是"关"或"开"——而是不匹配 agent 实际需要触达什么的那个。

## 面 4：adapter 凭证轮换

每个聊天 adapter 和 identity provider 持有凭证（`appID`/`appSecret`、`botToken`/`appToken`、`clientId`/`clientSecret`、Entra ID `appPassword`、Google Workspace `serviceAccountKey`）。按节奏轮换，并在任何泄漏嫌疑时轮换。

- **先在 provider 轮换，再在 Ankole。** 在 provider 控制台作废旧凭证，再把新值放进 adapter 的 AppConfigure。顺序要紧：在 Ankole 轮换但仍在 provider 有效的凭证是一个窗口。
- **shell secret 用 WorkerEnv；adapter secret 用 AppConfigure。** adapter 凭证不在 WorkerEnv——它们在 adapter 自己的加密 AppConfigure 行里。通过 Console 的 provider 或 identity-provider 界面轮换。
- **Directory 同步凭证也是凭证。** Google Workspace 的 `serviceAccountKey` 和 `adminEmail`、用于 Graph 的 Entra ID 应用——这些能读你的 directory。用与聊天凭证同等的严肃对待它们的轮换。

## 面 5：最小网络入口

Ankole 需要一些入口；它极少需要全部。收紧到每种传输实际需要的。

- **长连接 adapter 只需出站。** Lark、Slack、钉钉开出站 WebSocket/Stream 连接；它们不需要公共入口端点。只用这些就把部署保持私有。
- **Teams 和 webhook 入口需要公共端点——限定它。** Bot Framework 和 `/webhooks/v1/...` 正门需要可达。用入口把该路径限制到预期 provider（能按源 IP 就按），其余依赖 adapter 自身鉴权（Bot Framework JWT、Graph `clientState`、ZAP/PLAIN worker 认证）。
- **Console 本身**应在你的管理员网络或 VPN 之后，不对公网开放。bearer 门挡住未授权访问，但没有理由把管理员界面暴露给世界。

## 审计姿态

加固不是一次性通过；它是一种姿态。三个习惯保持它：

- **定期读授予。** `/permission-grants` 和 `/principals/:uid/grants` 显示每个 Principal 能做什么。漂移会发生。
- **读 Brain 审计日志。** `GET /brain/audit-log` 显示 agent 被告知相信什么、谁改过它。记忆是对据此行动的 agent 的一个安全面。
- **测试还原。** [备份与还原](../backup-and-restore/)纪律是一项安全控制——你无法还原的备份不是从入侵中的恢复。

## 本指南不是什么

它不是渗透测试，也不是合规清单——它是收紧 Ankole 既有边界的运维动作。它不是"把一切锁死"；最小权限指你使用所需的*最小*面，不是零面，而一个做不了本职工作的 agent 是它自己的失败。它也不是各面参考页的替代；上面的每个面链接到解释其确切字段的参考。

## 下一步

- 权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
- secret 存储，读 [WorkerEnv secret](../worker-env/)。
- SSRF 键与引导 secret，读[环境变量](../environment-variables/)。
- 假设这份加固的事故流程，读[事故响应](../incident-response/)。
