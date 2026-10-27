---
title: 安全加固
description: 加固 Ankole 私有部署实例——涵盖最小权限、密钥隔离、SSRF 防护、凭证轮换与网络收敛。
section: Guides
order: 316
---

Ankole 开箱即具备主体与 AuthZ 鉴权、敏感配置加密、单 Agent 独享 Worker 容器以及统一认证入口等内建安全边界；而安全加固的目标，则是将这些边界进一步收紧至实际业务所需的最小范围。下文按优先级梳理六大关键层面的运维加固实践。

贯穿全文的核心原则是：**默认遵循最小权限，仅在确有业务需求时按需放行**。以下每一项措施都在收窄某项操作权限、缩小某个密钥的爆炸半径，或是收敛某条网络暴露路径。每当你打算放宽某项限制时，请先追问背后的必要性——真正需要审慎评估的是“放宽”，而非“收紧”。

## 1. 收紧主体与 AuthZ 权限

每个 Agent 都以专属主体（Principal）的身份运行，能执行哪些操作完全由 AuthZ 裁定。请按各 Agent 的实际职责精确授予最小权限，切勿图省事赋予过宽的全局权限。

- **一职一 Agent，身份严格隔离。** 例如对外客服 Agent 与内部研发编码 Agent 应分别使用独立主体，防止单一 Agent 被诱导或攻破后波及另一类业务。
- **只授予履行职责所必需的最小权限。** 只读单个频道远比可写全部频道安全，精确的资源路径也远比宽泛通配符稳妥，详见 [主体与 AuthZ](../principal-authz/)。
- **优先同步外部目录组并按组授权。** 将身份源的部门或用户组同步为 AuthZ 目录组后按组分配权限；人员转岗或离职时，只需在源头企业通讯录中移出群组即可自动收回权限，避免手工逐条清理残留授权。
- **严格区分账户暂停（Suspend）与离职清退（Offboard）。** 系统不提供物理删除主体的操作：**暂停（`disposition: :suspended`）** 会立即吊销会话、令牌与在途任务，但保留个人 `SiteCredential` 凭证以便日后复职恢复；**离职清退（`disposition: :offboarded`）** 除吊销会话、令牌与任务外，还会彻底释放未共享的 `SiteCredential` 及 Pod 邮箱身份绑定——员工正式离开组织时，务必执行离职清退。

可通过 `/api/v2/permission-grants` 与 `/api/v2/principals/:uid/grants` 接口导出并核查现存授权。建议定期复盘，防止早期合理的授权随着业务职责变迁而演变为过度授权。

## 面 2：Agent 使用的凭据

Agent 调用外部工具所需的密钥与令牌，应统一存入 Console 的“环境变量”页面并开启加密存储。加固重点在于缩小可见范围并坚持定期轮换。

- **尽量只写不读。** 轮换密钥时直接覆盖填入新值即可，避免为了核对而反复在界面上解密查看旧值。具体操作见 [环境变量](../worker-env/)。
- **优先配置 Agent 级专属变量。** 全局环境变量会对实例内的每一个 Agent 暴露，而 Agent 级变量仅注入指定的单个 Agent；除非某份凭据确实需要全员共用，否则一律按单个 Agent 限定作用域。
- **严禁覆盖系统保留变量名。** `PATH`、`HOME`、`WORKER_ID`、`DATABASE_URL`、所有以 `ANKOLE_` 开头的变量名，以及 [环境变量](../worker-env/) 中列出的其他保留名称均禁止在 Console 中自定义覆盖，请勿尝试绕过该限制。
- **定期轮换底层引导密钥。** `ANKOLE_SECRET_BASE` 用于派生主加密密钥，`ANKOLE_FUNCTION_RUNTIME_TOKEN` 用于控制面与 `ankole-function-runtime` 之间的内部通信鉴权；轮换这类引导密钥后需重启整套部署，其中 `ANKOLE_SECRET_BASE` 一旦泄露将危及整个实例。至于 Worker 连接凭据则不属于引导密钥，无需人工配置：控制面会为每一代 Worker 实例（Generation）动态生成随机凭据、仅用哈希摘要核验身份，并加密保存重启同一代实例所需的重试令牌。

## 面 3：SSRF 与模型控制的抓取

具备 `web_fetch` 能力的 Agent 可以请求 Ankole 抓取指定 URL 的网页内容。AppConfigure 中的 `security.ssrf_filter` 配置项决定了是否拦截面向内网地址的抓取请求。

- **默认值为 `false`——开启前请先确认业务场景。** 许多企业部署 Ankole 正是为了让内部 Agent 访问内网维基、工单系统或私有服务，因此默认关闭该过滤器以保障内网可达。
- **云厂商实例元数据地址始终强制拦截。** 无论 `security.ssrf_filter` 是开是关，任何试图访问 `169.254.169.254` 等云元数据端点的模型请求都会被无条件拒绝。
- **纯公网场景请开启过滤器。** 将 `security.ssrf_filter` 设为 `true` 后，指向私有网段、本地环回、链路本地及运营商级 NAT（CGNAT）地址的抓取请求都会被拦截。只要你的 Agent 仅需检索公网信息、并无访问企业内网 IP 的正当需求，就应当开启此开关。

此项配置并无脱离场景的绝对对错，关键在于使网络放行范围与 Agent 的真实职责边界严丝合缝。

## 面 4：adapter 凭证轮换

每个已接入的聊天渠道与身份源提供商都保存着外部平台凭证（如 `appID`/`appSecret`、`botToken`/`appToken`、`clientId`/`clientSecret`、Entra ID 的 `appPassword`、Google Workspace 的 `serviceAccountKey` 等）。请建立定期轮换机制；一旦怀疑存在泄露风险，须立即应急轮换。

- **先在上游平台吊销旧密钥，再更新 Ankole 配置。** 请先在外部提供商控制台签发新密钥并作废旧密钥，随后将新值填入对应适配器的 AppConfigure 配置中。操作顺序至关重要：若只更新了 Ankole 配置却任由旧密钥在上游平台继续有效，攻击者仍可利用该时间窗盗用身份。
- **按凭证用途放对存储位置。** 供 Agent 工具脚本调用的外部 API 密钥放入“环境变量”；聊天渠道与身份源提供商自身的接入凭证，则在各自专属的 Console 配置页中管理与轮换。
- **同等重视目录同步凭证。** Google Workspace 的 `serviceAccountKey` 与 `adminEmail`、用于读取 Microsoft Graph 的 Entra ID 应用凭证等，都具备读取全公司组织架构与人员名单的权限，轮换周期与保管要求应与聊天渠道密钥同等严格。

## 面 5：最小网络入口

Ankole 只需要按实际启用的接入方式开放极少数入站端口，绝大部分部署无需将全部接口暴露在公网。

- **长连接聊天渠道仅需出站网络。** 飞书/Lark、Slack 与钉钉均支持由控制面主动向外建立 WebSocket/Stream 长连接，无需暴露任何公网入站端点；若仅使用这类渠道，可将整套实例完全收敛在内网中。
- **Teams 与 Webhook 入口需按源收敛。** Microsoft Bot Framework 及 `/webhooks/v1/...` 回调入口确需外部可达；建议在反向代理或网关层限制仅允许预期上游平台访问（支持源 IP 白名单的优先按 IP 放行），再叠加适配器内置的协议级验签（如 Bot Framework JWT、Graph `clientState`）。
- **将 Webhook 委托 URL 视同敏感凭据保护。** 当 Agent 将事件监测委托给外部系统时，`/webhooks/v1/event-callbacks/*` 必须对外部发送方可达，其中路径末尾的随机令牌本身就是唤醒凭证。请在 Ingress、反向代理、CDN 及应用访问日志中对完整 URL 路径做脱敏处理。由于该 URL 仅能授权“唤醒会话”，Agent 被唤醒后在执行任何有实质业务影响的操作前，仍须主动查询外部系统核实最新状态。
- **切勿将 Console 管理后台直接暴露到公网。** 尽管 Console 接口设有 Bearer 认证拦截未授权访问，管理后台仍应部署在企业办公内网或 VPN 之后，没有理由向整个公网敞开管理入口。

## 面 6：Worker 容器、Function Runtime 与控制面

每个 Agent 都独享专属的 Worker 容器或 Pod，不同 Agent 之间绝不混用 Worker 实例、缓存卷或运行凭据。与此同时，无状态的 TypeScript 程序（包括 Workflow、程序化工具调用 PTC 及 Applet 后端函数）统一运行在独立的 `ankole-function-runtime` 服务中，既不持有数据库连接凭证，也不挂载 Kubernetes ServiceAccount 令牌。在 Worker 侧，容器本身即为安全隔离边界：终端命令、Codex `app-server`、自动化脚本及无头浏览器均在容器内以普通 Worker 用户身份直接运行，不设额外的嵌套沙箱；所有 Agent 子进程统一以非特权用户 `uid 1000` 运行，剥离全部 Linux Capabilities 且不提供 `sudo` 权限。

- **非特权用户运行。** 命令以 `uid 1000` 身份执行且无 `sudo`，因此 Agent 可在自身主目录（Home）内安装用户态工具，但无法篡改系统级软件包。同一 Agent 名下的不同 Session 共享该 Agent 容器内的文件系统与进程空间。
- **Worker 连接凭据严格绑定单代单实例。** Worker 启动后仅在内存中持有连接凭据，并在拉起子进程命令前将其从环境变量中剔除；无论是其他 Agent 的凭据，还是旧一代已被替换淘汰的 Worker 凭据，都无法通过控制面校验。
- **按宿主机 root 同等安全级别保护控制面。** 控制面需要挂载 Docker Socket，或持有可在指定命名空间内创建与销毁 Pod、Secret 及 PVC 的 Kubernetes Role 来调度 Worker——而一旦能够操控 Docker Socket，在安全等价意义上就拥有了宿主机的 root 权限。
- **在 Kubernetes 环境中启用 gVisor 强隔离。** 可在 Kubernetes Worker 提供商的 YAML 配置中，将 `podTemplate.spec.runtimeClassName` 设为集群已安装的 gVisor RuntimeClass（如 `gvisor`）；修改保存后，池中现有 Worker 会在进入空闲状态时平滑替换为新配置。注意，Helm Chart 中的 `worker.runtimeClassName` 仅在首次部署初始化默认提供商时读取一次，后续调整请直接在 Console 中修改提供商配置。
- **收紧 Worker 与 `ankole-function-runtime` 的东西向网络边界。** 采用 Docker Compose 部署时，Worker 容器接入 `ankole_workers` 网桥，`ankole-function-runtime` 接入 `ankole_functions` 网桥：两者均可访问控制面与公网，但均无法触达仅挂载在内部 `ankole_backend` 网络上的 PostgreSQL；若运行在云主机上，请将云实例元数据服务的条数限制（hop limit）设为 `1`，或在宿主机防火墙层面屏蔽容器对 `169.254.169.254` 的访问。采用 Helm 部署并开启 `networkPolicy.enabled` 后，Worker Pod 拒绝一切入站连接，出站仅放行控制面、集群 DNS 以及不在 `networkPolicy.workerDeniedCIDRs` 列表内的公网地址；与此同时，专用 `NetworkPolicy` 会将 `ankole-function-runtime` 限制为仅接受来自控制面的入站请求，并拦截发往 `functionRuntime.deniedCIDRs` 所列私有网段与元数据地址的出站流量。同样地，请将 Kubernetes 工作节点的实例元数据 hop limit 设为 `1`。

## 审计姿态

安全加固并非一劳永逸的单次操作，而是一项需要长期坚持的运维习惯，核心在于落实以下两件事：

- **定期复核权限授予记录。** 结合 `/api/v2/permission-grants` 与 `/api/v2/principals/:uid/grants` 定期盘点各主体的实际权限，及时清理随业务调整而不再必要的历史授权。
- **定期演练备份还原流程。** 严格执行 [备份与还原](../backup-and-restore/) 规范本身就是一道兜底安全防线——一份从未验证过能否成功恢复的备份，无法在真正遭遇安全事件时帮你重建系统。

## 本指南不是什么

- **不是渗透测试报告或合规认证清单**：本文聚焦于收紧 Ankole 内建安全边界的实操措施。
- **不是“一刀切封死所有能力”**：最小权限意味着只开放完成工作所需的**最小**接口面，而非彻底归零——一个因过度封锁而无法履行正常职责的 Agent 同样背离了部署初衷。
- **不替代各子系统的参数参考手册**：上文每一节均附有指向对应专题文档的链接，涉及具体配置字段时请以各参考页为准。

## 下一步

- 深入了解底层权限模型，请参阅 [主体与 AuthZ](../principal-authz/)。
- 了解如何安全托管 Agent 工具凭据，请参阅 [环境变量](../worker-env/)。
- 查阅 SSRF 过滤开关与启动引导密钥说明，请参阅 [环境变量](../environment-variables/)。
- 了解负责隔离执行 Agent 命令的工作节点架构，请参阅 [Agent Computer Worker](../agent-computer-worker/)。
