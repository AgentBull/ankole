---
title: 安全加固
description: 加固 Ankole 实例，包括最小权限、Secret 管理、SSRF 防护、凭证轮换和减少外部入口。
section: Guides
order: 316
---

Ankole 已提供主体与 AuthZ、Secret 加密、Worker 沙盒和鉴权入口等安全边界。加固的目标是把这些边界收紧到实际需要的最小范围。本页按优先级说明五类运维加固操作。

先把决定性的性质说清楚：Ankole 的模型是*默认最小权限、仅在证据需要时扩展*。下面的每一步都在收窄一项权限、一个 secret 的影响范围、或一条网络路径。如果你发现自己在放宽某一项，问为什么——放宽才是值得审视的动作，不是收窄。

## 1. 收紧主体与 AuthZ 权限

Agent 以自己的主体身份运行，AuthZ 决定该主体可以做什么。请为每个 Agent 分配完成职责所需的最小权限，不要让一个 Agent 拥有过大的权限范围。

- **每个 Agent 使用一个主体，并只承担一种职责。** 客户支持 Agent 和代码 Agent 应使用不同主体，避免一个 Agent 被攻破后同时影响两类工作。
- **只授予完成工作所需的权限。** 读取一个频道比写入所有频道范围更小；指定资源模式比使用通配符更安全。参见[主体与 AuthZ](../principal-authz/)。
- **同步 directory group，再按 group 授予。** 已同步的 AuthZ group 让你按团队成员身份限定权限，并在某人离开时通过在来源 directory 移除成员身份来撤销——而不是逐条编辑授予。
- **不确定时先停用，不要删除。** 主体被停用后会立即在整个实例内失去权限，而且可以重新启用；删除主体则会永久移除它的 UID。

审计面是 `/permission-grants` 和 `/principals/:uid/grants`。定期读它们；创建时合理的授予会漂移成过多。

## 面 2：Agent 使用的凭据

Agent 运行工具时需要的凭据应保存在 Console 的“环境变量”中并开启加密。安全重点是限制使用范围，并定期轮换。

- **少查看。** 优先直接输入新值完成轮换，不要为了确认而查看旧值。具体操作见[环境变量](../worker-env/)。
- **能按 agent 限定就按 agent。** 一个全局 secret 触达每个 agent；按 agent 的 secret 触达一个。除非 secret 确实共享，优先按 agent 形态。
- **不要覆盖保留名。** `PATH`、`HOME`、`WORKER_ID`、`DATABASE_URL`、任何以 `ANKOLE_` 开头的名称，以及少量沙盒关键名称不能在 Console 中设置。不要绕开这项限制。
- **定期轮换引导 Secret。** `ANKOLE_SECRET_BASE` 和 `ANKOLE_RUNTIME_FABRIC_WORKER_AUTH_KEY` 会派生其他密钥，轮换时需要重启部署。`ANKOLE_SECRET_BASE` 一旦泄露，会影响整个实例。

## 面 3：SSRF 与模型控制的抓取

带 `web_fetch` 的 agent 能让 Ankole 抓取 URL。`security.ssrf_filter` 是决定拒绝什么的 AppConfigure 键。

- **默认是 `false`——翻转它之前先读为什么。** Ankole 常作企业内部 agent 使用，内网访问是预期的；过滤器关闭，这样内部抓取能工作。
- **云元数据端点始终被挡**，无论设置如何。尝试读 `169.254.169.254` 的模型，无论过滤器开关都被拒绝。
- **过滤器开启时**，私网、环回、链路本地和 CGNAT 目标被拒。当 agent 从公网抓取、且没有合理理由触达内部 IP 时开启它——这就是过滤器为之存在的场景。

决定是按部署的，错的不是"关"或"开"——而是不匹配 agent 实际需要触达什么的那个。

## 面 4：adapter 凭证轮换

每个聊天渠道和身份源提供商都持有凭证（`appID`/`appSecret`、`botToken`/`appToken`、`clientId`/`clientSecret`、Entra ID `appPassword`、Google Workspace `serviceAccountKey`）。请定期轮换；一旦怀疑泄露，立即轮换。

- **先在 provider 轮换，再在 Ankole。** 在 provider 控制台作废旧凭证，再把新值放进 adapter 的 AppConfigure。顺序要紧：在 Ankole 轮换但仍在 provider 有效的凭证是一个窗口。
- **按用途选择配置页面。** Agent 工具使用的凭据放在“环境变量”中；聊天渠道和身份源提供商的凭据在各自的 Console 页面中轮换。
- **Directory 同步凭证也是凭证。** Google Workspace 的 `serviceAccountKey` 和 `adminEmail`、用于 Graph 的 Entra ID 应用——这些能读你的 directory。用与聊天凭证同等的严肃对待它们的轮换。

## 面 5：最小网络入口

Ankole 需要一些入口；它极少需要全部。收紧到每种传输实际需要的。

- **长连接 adapter 只需出站。** Lark、Slack、钉钉开出站 WebSocket/Stream 连接；它们不需要公共入口端点。只用这些就把部署保持私有。
- **Teams 和 webhook 入口需要公共端点——限定它。** Bot Framework 和 `/webhooks/v1/...` 正门需要可达。用入口把该路径限制到预期 provider（能按源 IP 就按），其余依赖 adapter 自身鉴权（Bot Framework JWT、Graph `clientState`、ZAP/PLAIN worker 认证）。
- **Webhook 委托 URL 是凭据。** Agent 把检测交给外部系统时，`/webhooks/v1/event-callbacks/*` 必须可达。Ingress、proxy、CDN 和应用日志都要对完整路径脱敏。这个 URL 只授权唤醒，所以 Agent 在执行有后果的动作前必须复核外部系统当前状态。
- **Console 本身**应在你的管理员网络或 VPN 之后，不对公网开放。bearer 门挡住未授权访问，但没有理由把管理员界面暴露给世界。

## 审计姿态

加固不是一次性通过；它是一种姿态。三个习惯保持它：

- **定期检查授权规则。** `/permission-grants` 和 `/principals/:uid/grants` 会显示每个主体可以做什么。随着职责变化，旧授权可能已经过宽。
- **读 Brain 审计日志。** `GET /brain/audit-log` 显示 agent 被告知相信什么、谁改过它。记忆是对据此行动的 agent 的一个安全面。
- **测试还原。** [备份与还原](../backup-and-restore/)纪律是一项安全控制——你无法还原的备份不是从入侵中的恢复。

## 本指南不是什么

它不是渗透测试，也不是合规清单——它是收紧 Ankole 既有边界的运维动作。它不是"把一切锁死"；最小权限指你使用所需的*最小*面，不是零面，而一个做不了本职工作的 agent 是它自己的失败。它也不是各面参考页的替代；上面的每个面链接到解释其确切字段的参考。

## 下一步

- 权限模型见[主体与 AuthZ](../principal-authz/)。
- Agent 使用的凭据，读[环境变量](../worker-env/)。
- SSRF 键与引导 secret，读[环境变量](../environment-variables/)。
