---
title: Google Workspace adapter
description: 把 Ankole 管理员登录接到 Google Workspace——OIDC 登录加上通过 service account 的 directory 同步，所有 secret 静态加密。
section: User guide
order: 19
---

Google Workspace adapter 是这一组 adapter 里只负责身份的那一个。它让管理员用 Google 工作账号登录 Console，并把 Google Workspace 的 group 拉进 AuthZ。它不是 chat adapter——这里不路由任何消息。

## adapter 声明了什么

`Ankole.Plugins.GoogleWorkspaceAdapter`（plugin_id `"google-workspace-adapter"`）只注册一个契约：

- 一个 **identity** 声明，挂在 `principals.identity_provider` 下，adapter id 为 `"google-workspace"`。

没有 chat 面。adapter 在这一个契约上承担两项能力：OIDC 登录（`oidc_authorization`、`oidc_code_exchange`）和整库 directory 同步（`directory_full_sync`）。唯一的 AppConfigure pattern `principals.identity_providers.google-workspace.*` 是加密的——OAuth client secret 和 service account key 都是 secret 材料，控制面加密存储。

## 前置条件

你需要两份 Google Cloud 配置：

1. **一个 OAuth client**，用于 OIDC 登录。client 提供 OIDC 配置所需的 `clientID` 和 `clientSecret`。把 Ankole Console 的 OIDC 回调加进 client 的已授权回调 URI。
2. **一个 service account**，用于 directory 同步，并对你想读取的 Workspace customer 开启 domain-wide delegation。`serviceAccountKey` 是 Google 生成的 service account JSON key 文件；`adminEmail` 是 service account 通过这项委派去模拟（impersonate）的那个 Workspace 管理员。

给 OAuth client 登录时要请求的 scope——`openid`、`email`、`profile`；再向 service account 授予 Directory API 读取 scope 的 domain-wide delegation。

## 把 Google Workspace 配置为 identity provider

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/google-workspace \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "adapter_id": "google-workspace",
    "clientID": "...",
    "clientSecret": "...",
    "oidc": { "enabled": true, "scopes": ["openid", "email", "profile"], "allowedDomains": ["example.com"] },
    "serviceAccountKey": "...",
    "adminEmail": "admin@example.com",
    "sync": { "contacts": true }
  }'
```

adapter 在保存时校验配置。`oidc.enabled` 为 true 时，`clientID` 和 `clientSecret` 必填。`sync.contacts` 为 true 时，`serviceAccountKey` 和 `adminEmail` 必填：key 必须是可解析的 service account JSON，`adminEmail` 必须包含 `@`（存储时转为小写）。`oidc.allowedDomains` 在 OIDC 下必填——Google 没有租户隔离，adapter 只放行你列出的 Workspace 域。

## OIDC 登录

管理员登录时，adapter 针对 Google 跑 OIDC 授权码流程：把浏览器重定向到 Google 的授权端点，在 Google 的 token 端点用返回的 code 换取 token，再从 userinfo 读取用户身份。一次成功的登录解析为一个 Ankole Principal。

adapter 发送的 `clientID` 必须与你配置的 OAuth client 一致。adapter 还会在返回的 claim 上强制 Workspace 边界：email 必须已验证，必须带 hosted-domain（`hd`）claim，且 `hd` 与 email 的域名都要落在 `allowedDomains` 里。个人的 Gmail 地址，或来自你没列出的域的账号，都会被拒。

## directory 同步

directory 同步把 Google Workspace 的 group 和它们直接的 USER 成员拉进 AuthZ group，于是管理员在 Google Workspace 里的 group 成员身份，就成了它在 Ankole 里的 AuthZ group 成员身份。adapter 用 service account，以 `adminEmail` 通过 domain-wide delegation 模拟该管理员，换得一个短期 access token 访问 Directory API；读取 customer 时用 `my_customer`，它解析为被模拟管理员所在的 Workspace customer。

service account 的 access token 是短期的，所以 adapter 每次调用都重新签一个 assertion，同步走周期性整库同步（本阶段 Google 侧没有实时推送）。嵌套 group 不展开——只取直接的 USER 成员。同步之后，通过 [Principal 与 AuthZ](../principal-authz/) 界面向已同步的 group 授予 grant。

## 出问题的时候

- **登录在重定向处失败**——确认 OAuth client 的已授权回调 URI 包含 Console 的 OIDC 回调，且 adapter 发送的 `clientID` 与该 client 一致。
- **从 Google 回来后被拒**——email 必须已验证，且 `hd` claim 与 email 域名都要落在 `allowedDomains` 里。非 Workspace 账号，或来自你没列出的域的账号，会在这里失败。
- **directory 同步返回空**——确认 service account 对 Directory API 读取 scope 开启了 domain-wide delegation，`adminEmail` 属于你想要的 Workspace customer（`my_customer` 跟着被模拟的管理员走），且 `sync.contacts` 是开的。
- **token 在同步中途过期**——service account 的 access token 是短期的；adapter 每次调用都重新签 assertion。如果同步每个周期都在鉴权上失败，检查 `serviceAccountKey` 在 Google Cloud 里是否仍然有效。

## 下一步

- identity-provider 与同步路由，读 [Console API 参考](../console-api/)。
- 已同步的 group 如何变成权限，读 [Principal 与 AuthZ](../principal-authz/)。
