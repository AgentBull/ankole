---
title: 安全加固
description: 加固 Ankole 实例，包括最小权限、Secret 管理、SSRF 防护、凭证轮换和减少外部入口。
section: Guides
order: 316
---

Ankole 已提供主体与 AuthZ、Secret 加密、每个 Agent 一个 Worker 容器和鉴权入口等安全边界。加固的目标是把这些边界收紧到实际需要的最小范围。本页按优先级说明六类运维加固操作。

先说明最关键的一点：Ankole 的模型是*默认最小权限、仅在证据需要时扩展*。下面的每一步都在收窄一项权限、一个 secret 的影响范围、或一条网络路径。如果你发现自己在放宽某一项，问为什么——放宽才是值得审视的动作，不是收窄。

## 1. 收紧主体与 AuthZ 权限

Agent 以自己的主体身份运行，AuthZ 决定该主体可以做什么。请为每个 Agent 分配完成职责所需的最小权限，不要让一个 Agent 拥有过大的权限范围。

- **每个 Agent 使用一个主体，并只承担一种职责。** 客户支持 Agent 和代码 Agent 应使用不同主体，避免一个 Agent 被攻破后同时影响两类工作。
- **只授予完成工作所需的权限。** 读取一个频道比写入所有频道范围更小；指定资源模式比使用通配符更安全。参见 [主体与 AuthZ](../principal-authz/)。
- **同步 directory group，再按 group 授予。** 已同步的 AuthZ group 让你按团队成员身份限定权限，并在某人离开时通过在来源 directory 移除成员身份来撤销——而不是逐条编辑授予。
- **严格区分暂停（Suspend）与离职清退（Offboard）。** 主体（Principal）不提供删除操作。**暂停（`disposition: :suspended`）** 会立即吊销会话、令牌和运行中的任务，同时保留个人 `SiteCredential` 凭证以便后续恢复访问；**离职清退（`disposition: :offboarded`）** 除吊销会话、令牌和任务外，还会释放未共享的 `SiteCredential` 与 Pod 邮箱身份绑定——人员离开组织时必须执行离职清退。

审计接口为 `/api/v2/permission-grants` 和 `/api/v2/principals/:uid/grants`。请定期检查，避免创建时合理的授权随职责变化而过宽。

## 面 2：Agent 使用的凭据

Agent 运行工具时需要的凭据应保存在 Console 的“环境变量”中并开启加密。安全重点是限制使用范围，并定期轮换。

- **少查看。** 优先直接输入新值完成轮换，不要为了确认而查看旧值。具体操作见 [环境变量](../worker-env/)。
- **能按 agent 限定就按 agent。** 一个全局 secret 触达每个 agent；按 agent 的 secret 触达一个。除非 secret 确实共享，优先按 agent 形态。
- **不要覆盖保留名。** `PATH`、`HOME`、`WORKER_ID`、`DATABASE_URL`、任何以 `ANKOLE_` 开头的名称，以及 [环境变量](../worker-env/) 列出的其他保留名称不能在 Console 中设置。不要绕开这项限制。
- **定期轮换引导 Secret。** `ANKOLE_SECRET_BASE` 用于派生加密密钥，`ANKOLE_FUNCTION_RUNTIME_TOKEN` 用于控制面与 `ankole-function-runtime` 之间的内部鉴权；轮换引导 Secret 需要重启部署，`ANKOLE_SECRET_BASE` 一旦泄露会影响整个实例。Worker 凭据不是引导 Secret，也无需手动设置：控制面为每个 Worker generation 生成随机凭据，用摘要校验身份，并加密保存重复启动同一 generation 所需的重试值。

## 面 3：SSRF 与模型控制的抓取

带 `web_fetch` 的 agent 能让 Ankole 抓取 URL。`security.ssrf_filter` 是决定拒绝什么的 AppConfigure 键。

- **默认是 `false`——翻转它之前先读为什么。** Ankole 常作企业内部 agent 使用，内网访问是预期的；过滤器关闭，这样内部抓取能工作。
- **云元数据端点始终被挡**，无论设置如何。尝试读 `169.254.169.254` 的模型，无论过滤器开关都被拒绝。
- **过滤器开启时**，私网、环回、链路本地和 CGNAT 目标被拒。当 agent 从公网抓取、且没有合理理由触达内部 IP 时开启它——这就是过滤器为之存在的场景。

决定因部署而异；错的不在“关”或“开”，而在是否匹配 agent 实际需要触达的范围。

## 面 4：adapter 凭证轮换

每个聊天渠道和身份源提供商都持有凭证（`appID`/`appSecret`、`botToken`/`appToken`、`clientId`/`clientSecret`、Entra ID `appPassword`、Google Workspace `serviceAccountKey`）。请定期轮换；一旦怀疑泄露，立即轮换。

- **先在 provider 轮换，再在 Ankole。** 在 provider 控制台作废旧凭证，再把新值放进 adapter 的 AppConfigure。顺序要紧：只在 Ankole 轮换，而旧凭证在 provider 侧仍有效，就等于留着一个利用窗口。
- **按用途选择配置页面。** Agent 工具使用的凭据放在“环境变量”中；聊天渠道和身份源提供商的凭据在各自的 Console 页面中轮换。
- **Directory 同步凭证也是凭证。** Google Workspace 的 `serviceAccountKey` 和 `adminEmail`、用于 Graph 的 Entra ID 应用——这些能读你的 directory。轮换它们时要和在聊天凭证上一样严肃。

## 面 5：最小网络入口

Ankole 需要一些入口；它极少需要全部。收紧到每种传输实际需要的。

- **长连接 adapter 只需出站。** Lark、Slack、钉钉开出站 WebSocket/Stream 连接；它们不需要公共入口端点。只用这些就把部署保持私有。
- **Teams 和 webhook 入口需要公共端点——限定它。** Bot Framework 和 `/webhooks/v1/...` 正门需要可达。用入口把该路径限制到预期 provider（能按源 IP 就按），其余依赖 adapter 自身鉴权（Bot Framework JWT、Graph `clientState`）。
- **Webhook 委托 URL 是凭据。** Agent 把检测交给外部系统时，`/webhooks/v1/event-callbacks/*` 必须可达。Ingress、proxy、CDN 和应用日志都要对完整路径脱敏。这个 URL 只授权唤醒，所以 Agent 在执行有后果的动作前必须复核外部系统当前状态。
- **Console 本身**应在你的管理员网络或 VPN 之后，不对公网开放。bearer 门挡住未授权访问，但没有理由把管理员界面暴露给世界。

## 面 6：Worker 容器、Function Runtime 与控制面

每个 Agent 都有自己的 Worker 容器或 Pod，Agent 之间从不共享 Worker、缓存盘或凭据。无状态的 TypeScript 程序（Workflow、PTC 与 Applet 后端）运行在独立的 `ankole-function-runtime` 服务中，不持有数据库凭证，也不挂载 Kubernetes ServiceAccount 令牌。容器是隔离边界：Worker 命令、Codex app-server、Automation 脚本和浏览器都以 Worker 的用户身份运行，没有内层沙箱；这些 Agent 进程以 uid 1000 运行，没有 capabilities 或 sudo。

- 命令以 uid 1000 运行，没有 sudo。Agent 可以在 Home 安装用户软件，不能安装系统软件。同一 Agent 的 Session 共享文件与进程。
- **Worker 凭据只代表一个 Agent。** Worker 把凭据保存在内存中，并从其命令的环境中移除。其他 Agent 的凭据，或已被替换的 Worker 的凭据，都无法连接。
- **把控制面当作等同 root 的组件来保护。** 控制面通过 Docker socket，或通过能创建和删除 Pod、Secret 和 PVC 的 namespace Role 创建 Worker。能访问 Docker socket 就等于拥有主机的 root 权限。
- **在 Kubernetes 上加 gVisor。** 在 Kubernetes provider YAML 中把 `podTemplate.spec.runtimeClassName` 设为集群中的 gVisor RuntimeClass，例如 `gvisor`。实例配置变化后，池中的 Worker 在空闲时替换。Helm 的 `worker.runtimeClassName` 只在首次启动时初始化生成的 provider；导入后在 Console 修改 provider。
- **限制 Worker 与 `ankole-function-runtime` 能访问的范围。** 使用 Docker Compose 时，Worker 容器加入 `ankole_workers` 网桥，`ankole-function-runtime` 加入 `ankole_functions` 网桥：两者都能访问控制面和互联网，但都无法访问仅挂载在内部 `ankole_backend` 网络上的 PostgreSQL。在云虚拟机上，请把实例元数据的 hop limit 设为 1，或对容器屏蔽 `169.254.169.254`。使用 Helm 时，开启 `networkPolicy.enabled` 后，Worker Pod 不接受任何入站连接，只能访问控制面、DNS 以及 `networkPolicy.workerDeniedCIDRs` 之外的公网地址；同时专用 `NetworkPolicy` 将 `ankole-function-runtime` 限制为仅接受控制面入站并拒绝访问 `functionRuntime.deniedCIDRs` 中的私网段与元数据地址。同时把节点的实例元数据 hop limit 设为 1。

## 审计姿态

加固不是一次性通过；它是一种姿态。两个习惯保持它：

- **定期检查授权规则。** `/api/v2/permission-grants` 和 `/api/v2/principals/:uid/grants` 会显示每个主体可以做什么。随着职责变化，旧授权可能已经过宽。
- **测试还原。** [备份与还原](../backup-and-restore/)纪律是一项安全控制——你无法还原的备份不是从入侵中的恢复。

## 本指南不是什么

它不是渗透测试，也不是合规清单——它是收紧 Ankole 既有边界的运维动作。它不是"把一切锁死"；最小权限指你使用所需的*最小*面，不是零面，而一个做不了本职工作的 agent 是它自己的失败。它也不是各面参考页的替代；上面的每个面链接到解释其确切字段的参考。

## 下一步

- 权限模型见 [主体与 AuthZ](../principal-authz/)。
- Agent 使用的凭据，读 [环境变量](../worker-env/)。
- SSRF 键与引导 secret，读 [环境变量](../environment-variables/)。
- 运行每个 Agent 命令的 Worker，读 [Agent Computer Worker](../agent-computer-worker/)。
