---
title: 用 Entra ID 作管理员登录
description: 把 Entra ID（Azure AD）配置为管理员 identity provider——应用注册、通过 Graph 订阅的 directory 全量与实时同步、让订阅保持存活的调和器。
section: Guides
order: 318
---

本指南把 Console 管理员登录联合到 Entra ID（Azure AD）。读完，管理员用 Microsoft 工作账号登录 Ankole、directory group 同步进 AuthZ（全量按节奏、实时经 Graph 订阅）、订阅无需看护即保持存活。它镜像[用 Google Workspace 作管理员登录](../google-workspace-admin-login/)；差异是 Entra 专属的：租户范围的应用注册、Graph 订阅生命周期、Google Workspace adapter 没有的实时同步。

先把决定性的性质说清楚：Entra ID 身份面同时承载 `directory_full_sync` 和 `directory_realtime_sync`。实时同步通过 adapter 创建的 Graph 订阅运行，在 48 小时窗口内续订、掉线则重建——所以 Entra ID 里的 directory 变更几分钟内到达 Ankole，而非等下一次全量。这是 Google Workspace adapter 缺少的能力，也是两个 adapter 不可互换的原因。

## 在 Entra ID 里需要什么

一份应用注册同时做两件事（OIDC 登录与 directory 访问），与 Google Workspace 的 OAuth client 加 service account 两件套不同：

| 字段 | 它是什么 |
|---|---|
| `tenantID` | Entra ID 租户 id——一个 GUID |
| `clientID` | 应用注册的 application（client）id |
| `clientSecret` | 应用的 client secret |

在 Entra ID 门户注册应用，默认单租户。把 Ankole Console 的 OIDC 回调加进它的 redirect URI。授予它所需的 Microsoft Graph 权限——登录用 `User.Read` 和 `openid`/`profile`/`email`，同步用 directory 读取权限（`Group.Read.All`、`User.Read.All`）——并授予管理员同意。`clientSecret` 与 Teams 聊天面用的 secret 相同，但身份面用 `clientID`/`clientSecret`/`tenantID`，不是聊天面的 `appID`/`appPassword`/`botTenancy`。

## 配置 identity provider

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/entra-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "entra-id",
    "tenantID": "<tenant-guid>",
    "clientID": "<client-id>",
    "clientSecret": "<client-secret>",
    "sync": { "contacts": true, "realtime": true, "pageSize": 999 }
  }'
```

adapter 校验的字段：

| 字段 | 何时必需 | 含义 |
|---|---|---|
| `tenantID` | 总是 | Entra ID 租户（GUID） |
| `clientID` | 总是 | 应用注册的 client id |
| `clientSecret` | 总是 | 应用 secret（静态加密） |
| `sync.contacts` | 默认真 | directory 同步是否运行 |
| `sync.realtime` | 默认真 | 是否使用 Graph 订阅 |
| `sync.pageSize` | 默认 999 | Graph 页大小（1–999） |

adapter id 是 `entra-id`（同一个 M365 plugin 在 `teams` 聊天 adapter 和两个 webhook handler 之外声明它）。每个 pattern 加密；`clientSecret` 是 secret 材料。

## 登录流程

管理员登录是标准 Entra ID OIDC：重定向到 Microsoft、换码、读用户。adapter 把用户解析为 Ankole Principal；第一个成功用户成为本部署的 root 管理员，激活码随之失效。与 Google Workspace adapter 不同，没有 `allowedDomains` 边界要配——租户自身就是边界。另一个租户的用户无法对单租户应用注册鉴权，所以应用的租户范围就是登录的栅栏。

## Directory 全量同步

`sync.contacts` 开启时，adapter 按节奏通过 Graph 读取 directory，每次按 `sync.pageSize` 行分页。全量是底：它保证 Ankole 的 directory 视图在实时漏掉变更时仍收敛到 Entra ID 的事实。全量之后，Entra ID group 作为 Ankole AuthZ group 存在，你通过 [Principal 与 AuthZ](../principal-authz/) 向它们授予。

## Directory 实时同步（Graph 订阅）

这是 Entra ID adapter 独有的能力。`sync.realtime` 开启时，adapter 为 directory 资源创建 Graph 订阅，每个带一个 `clientState` secret。Entra ID 里某事变化时，Graph 向 adapter 的 `entra-id` directory webhook handler（kinds `["directory"]`）POST 通知，由匹配的 `clientState` 鉴权——没有正确 `clientState` 的通知被拒。

`SubscriptionReconciler` 让订阅保持存活：

- 它在启动时、默认每 6 小时、以及保存 identity provider 时的保存时调和钩子上运行；
- 它在订阅过期前的 **48 小时续订窗口**内续订；
- 它重建掉线的订阅；
- 间隔（6 小时）远在 48 小时窗口内，所以漏跑几次不损失什么。

把 `sync.realtime` 关掉，调和器改为删除订阅——全量成为唯一路径，按其节奏滞后。

## 验证登录与同步

打开 Console 登录，选 Entra ID 路径。用租户里的用户登录。成功登录解析为 Ankole Principal。

然后验证同步：

- **全量同步**——首次同步运行后，检查 `/principal-groups` 看 Entra ID group。
- **实时同步**——在 Entra ID 改一个 group 成员，观察 `/principal-groups` 几分钟内更新。若不更新，订阅可能掉线；调和器会在其间隔内重建，但检查 Graph 能否到达你的公共 webhook（directory webhook 与 Teams 聊天面需要同样的公共入口）。

## 出问题的时候

- **登录在重定向处失败**——应用注册的 redirect URI 不含 Ankole Console 回调，或 `clientID`/`tenantID` 不匹配。错误在 Ankole 看到 token 之前出现在 Microsoft 侧。
- **对正确用户登录失败**——应用是单租户而用户在另一租户，或未对 Graph scope 授予管理员同意。
- **全量同步返回空**——应用缺 `Group.Read.All`/`User.Read.All`，或未授予管理员同意。同意是常见元凶，不是页大小。
- **实时同步陈旧**——Graph 无法到达公共 webhook（入口停、证书过期），或订阅掉线而调和器尚未重建。全量最终仍会收敛。

## 本指南不是什么

它不是 Entra ID 应用注册教程——门户会变，scope 由 Microsoft 文档。它不是接纳个人 Microsoft 账号的途径；租户是边界，单租户应用保持它。它也不与 Google Workspace adapter 互换；Entra ID 面通过 Graph 订阅有实时同步，Google Workspace 面没有，这个差异是它们分开的原因。

## 下一步

- adapter 参考（全部四个契约），读 [Microsoft 365 adapter](../adapters-microsoft-365/) 专页。
- 已同步 group 所喂给的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
- 实时同步与 Teams 聊天共享的公共入口要求，读[你的第一个 Microsoft Teams 机器人](../m365-teams-bot/)。
