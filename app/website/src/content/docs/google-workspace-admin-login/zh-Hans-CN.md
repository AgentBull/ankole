---
title: 用 Google Workspace 作管理员登录
description: 把 Google Workspace 配置为管理员 identity provider——OAuth client、工作空间边界、通过 service account 的 directory 同步，以及 adapter 在登录时施加的强制。
section: Guides
order: 313
---

本指南把 Console 管理员登录联合到 Google Workspace。读完，管理员用 Google 工作账号登录 Ankole、登录被限定在你的工作空间域、directory group 同步进 AuthZ 使你能按 group 授权。它建立在 [Google Workspace adapter](../adapters-google-workspace/) 参考之上；本页是身份面的运维 walkthrough。

先把决定性的性质说清楚：adapter 在登录时强制工作空间边界——`email_verified`、有 `hd` claim、且 `hd` 和邮箱域都在 `allowedDomains` 里。来自你工作空间之外的 Google 账号，即便 token 有效，也不能成为 Ankole 管理员。边界是重点；刻意设它。

## 在 Google Cloud 里需要什么

两份 Google Cloud 配置，各司其职：

1. **一个 OAuth client**，用于管理员登录（OIDC 流程）。在 *APIs & Services → Credentials* 下创建。记下它的 `clientID` 和 `clientSecret`，把 Ankole Console 的 OIDC 回调 URL 加进它的 authorized redirect URIs。订阅 `openid`、`email`、`profile` scope。

2. **一个 service account**，用于 directory 同步，对你想读取的 Google Workspace customer 启用**全域委派**。下载它的 JSON key——这就是 `serviceAccountKey`。委派让 service account 模拟一个管理员用户（`adminEmail`）调用 Directory API。

它们分开，因为做不同的事：OAuth client 鉴权*登录的管理员*；service account 代表 Ankole 读取*directory*。你可以不用 directory 同步只用 identity provider（跳过 service account），但反过来不行。

## 配置 identity provider

通过 Console 创建 identity provider：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/google-workspace \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "google-workspace",
    "clientID": "<oauth-client-id>",
    "clientSecret": "<oauth-client-secret>",
    "oidc": { "enabled": true, "allowedDomains": ["example.com"] },
    "serviceAccountKey": "<service-account-json>",
    "adminEmail": "directory-reader@example.com",
    "sync": { "contacts": true }
  }'
```

adapter 校验的字段：

| 字段 | 何时必需 | 含义 |
|---|---|---|
| `clientID` | `oidc.enabled` 为真 | OAuth client id |
| `clientSecret` | `oidc.enabled` 为真 | OAuth client secret（静态加密） |
| `oidc.allowedDomains` | `oidc.enabled` 为真 | 允许登录的工作空间域 |
| `serviceAccountKey` | `sync.contacts` 为真（默认） | service account JSON key |
| `adminEmail` | `sync.contacts` 为真 | service account 模拟的委派管理员 |

此 adapter 的每一个 AppConfigure pattern 都是加密的——`clientSecret` 和 `serviceAccountKey` 是 secret 材料，由控制面加密存储。

## 登录时的工作空间边界

管理员登录时，adapter 跑 OIDC 授权码流程，然后在接受身份前检查三件事：

1. **`email_verified` 为真**——Google 已确认邮箱。
2. **有 `hd`（hosted domain）claim**——账号属于某个工作空间，不是 `gmail.com` 消费者账号。
3. **`hd` 和邮箱域都在 `allowedDomains` 里**——这个工作空间是*你的*。

任何一项失败，以 `login_domain_not_allowed` 拒绝登录。这就是为什么 `allowedDomains` 要紧：它是把工作空间之外的有效 Google token 挡在 Console 之外的栅栏。把它设成你确实指的域；只有真正运行多域工作空间时才加第二个域。

## Directory 同步进 AuthZ

`sync.contacts` 开启时，adapter 把 Google Workspace 的 group 和成员拉进 AuthZ group，用 service account（模拟 `adminEmail`）调用 Directory API。customer 解析为 `my_customer`——service account 自己的 customer——所以你不必查 customer id。

Google Workspace 同步**仅全量同步**（`directory_full_sync`）。没有实时订阅：其它 adapter 用于实时的 Google 侧通道在此不适用，所以 adapter 按节奏同步。预期同步滞后于 directory 变更几分钟到几小时，而非几秒。

首次同步后，工作空间的 group 作为 Ankole AuthZ group 存在。通过 [Principal 与 AuthZ](../principal-authz/) 向它们授予——"`engineering@example.com` group 里的每个人可以管理这些 agent"现在是一条真实的 grant，以 Google Workspace 为事实来源。

## 验证登录

打开 Console 登录，选 Google Workspace 路径。用 `allowedDomains` 域里的用户登录。成功登录解析为一个 Ankole Principal，第一个成功用户成为本部署的 root 管理员（激活码随之失效）。

然后验证栅栏：来自 `gmail.com` 账号、或来自不在 `allowedDomains` 的工作空间的登录尝试，应以 `login_domain_not_allowed` 失败。若没有，`allowedDomains` 设得过宽——依赖它之前修好。

## 出问题的时候

- **登录在重定向处失败**——OAuth client 的 authorized redirect URIs 不含 Ankole Console 回调，或 `clientID` 不匹配。错误在 Ankole 看到 token 之前就出现在 Google 侧。
- **对有效用户 `login_domain_not_allowed`**——用户域不在 `allowedDomains`，或用户是 `gmail.com` 消费者账号（无 `hd` claim）。加域，或用工作空间账号。
- **Directory 同步返回空**——service account 缺全域委派，或 `adminEmail` 不是委派管理员。在 Google Cloud 确认对 Directory API scope 的委派，且 `adminEmail` 小写、含 `@`。
- **同步陈旧**——全量同步按节奏跑，不是实时。Google Workspace 里的 group 变更在下一次同步后出现，不立即。

## 本指南不是什么

它不是 Google Cloud 设置教程——OAuth client 和 service account 是标准 Google 配置，Google 控制台会变。它也不是接纳消费者 Google 账号的途径；`hd` 强制是刻意的，移除它不是受支持的配置。adapter 存在是为了联合*工作空间*，边界是功能。

## 下一步

- adapter 参考，读 [Google Workspace adapter](../adapters-google-workspace/)。
- 已同步 group 所喂给的权限模型，读 [Principal 与 AuthZ](../principal-authz/)。
- identity-provider 路由，读 [Console API 参考](../console-api/)。
