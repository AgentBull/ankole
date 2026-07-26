---
title: 你的第一个 Microsoft Teams 机器人
description: 一份完整 walkthrough——部署带公共 HTTPS 入口的 Ankole、注册 Entra ID 应用、把 agent 绑到 Teams adapter、校验 Bot Framework JWT，并确认机器人在频道里回复。
section: Guides
order: 305
---

本指南把一个 agent 一路带到可用的 Microsoft Teams 机器人：在 Teams 频道里 @、收到真实的模型回复、并验证端到端路径。读完你会得到一个能在 Teams 里 @ 的 agent，并对沿途每一个边界都心中有数。

一句话讲完流程：**部署带公共 HTTPS 端点的 Ankole → 注册 Entra ID 应用 → 激活并登录 → 配置 provider → 创建 agent → 绑到 Teams adapter → @ 机器人 → 验证回复。**

本指南与[你的第一个 Lark 机器人](../lark-first-bot/)镜像——共享步骤的更多深度先读那一篇。差异是 Teams 专属的，而且是所有 adapter 里最重的：公共 HTTPS 入口（Teams 没有长连接模式）、Bot Framework JWT 校验、Graph 订阅、以及所有 adapter 里最广的契约面。

## 前置条件

- 一台满足[平台支持](../platform-support/)的 Linux 主机或 Kubernetes 集群，**带公共 HTTPS 端点**。Teams 把消息作为 Bot Framework webhook 调用投递——没有 Socket Mode 或长连接兜底，所以部署必须在公共 HTTPS URL 上可达，且证书受信任。
- 一个能注册应用的 Entra ID（Azure AD）租户。
- 一个用于真实模型回合的 LLM provider API key。

如果你的 Ankole 部署在隧道或私有网络后面，先把它暴露出来。Bot Framework 不会投递到 `localhost`。

## 第 1 步：部署带公共 HTTPS 入口的 Ankole

按[安装部署](../installation/)——单机用 Docker Compose，集群用 Helm。对 Teams，HTTPS 入口是强制的，不是可选：Caddy（Compose）或 Ingress（Helm）必须在公共 DNS 名上、用受信任证书服务部署。继续之前确认 `curl -I https://<your-host>/` 成功。

读取激活码，在 `/setup` 输入，并在 plugin 这一步保持 **Microsoft 365 adapter 启用**。

## 第 2 步：注册 Entra ID 应用

在 Entra ID 门户注册一个新应用。应用注册给你 Teams 聊天配置所需的值：

| 字段 | 它是什么 |
|---|---|
| `appID` | 应用的 application（client）id——一个 GUID |
| `appPassword` | 应用的 client secret |
| `botTenancy` | `single_tenant` 或 `multi_tenant`（默认 `single_tenant`） |
| `tenantID` | 租户 id；`multi_tenant` 时 bot token 租户为 `botframework.com` |

adapter 把 `appID` 校验为 GUID。为应用订阅它所需的 Teams channel scope，并授予管理员同意。若要用 Entra ID 作管理员 identity provider，把应用的 OIDC 重定向 URI 配到 Ankole Console 的回调。

## 第 3 步：通过 Entra ID 登录（可选）并启用 directory 同步

Microsoft 365 adapter 声明最广的身份面：`oidc_authorization`、`oidc_code_exchange`、`directory_full_sync`、`directory_realtime_sync`。通过设置流程或 `PUT /identity-providers/<provider_id>`（`adapter_id: "entra-id"`）把 Entra ID 配为 identity provider。

实时 directory 同步使用 Graph 订阅，由 adapter 的 `SubscriptionReconciler` 保持存活。调和器在 48 小时窗口内续订订阅，并重建掉线的订阅，所以漏跑几次不会丢同步——但 Graph 必须能到达你的公共 webhook 以投递通知，这是入口强制的又一个理由。

若只想要聊天机器人，跳过这一步——Teams 聊天 binding 不依赖 Entra ID 登录。

## 第 4 步：配置 provider、绑 profile、创建 agent

按 [Provider 与模型](../providers-and-models/)新增 provider 并绑定必需的 model profile 槽（`primary`、`light`、`heavy`）。按 [Agent](../agents/) 创建 agent 并至少撰写一份 `mission` 文档。

## 第 5 步：把 agent 绑到 Teams adapter

创建 signal binding。注意 adapter id 是 `teams`，不是 `microsoft365`：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/teams/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<teams-config-key>", "unaddressed_group_message_policy": "addressed_only" }'
```

`config_ref` 指向带着 `appID`/`appPassword`/`botTenancy`/`tenantID` 的 Teams 配置。`addressed_only` 是最安全的首发策略——agent 只在 Teams 频道里被 @ 时醒来。

## 第 6 步：验证机器人回复

把机器人加进一个 Teams team 或频道（或开一个与它的私聊）。@ 它一个简单问题：

> 你能做什么？

收到回复，意味着整条路径都通了：Teams 把活动作为 Bot Framework webhook 调用投递、adapter 校验了 JWT（签发方 `https://api.botframework.com`、受众是你的 `appID`、service URL 与活动匹配）、signal binding 接受了结果事件、actor 醒来、model profile 解析成功、回复通过 Bot Framework 发回。如果机器人不回复，按顺序排查：

1. 公共 HTTPS 端点可达、证书受信任——Bot Framework 不会投递到不受信任或私有的端点。
2. 应用注册的 `appID` 和 `appPassword` 与 Teams 配置一致，且 JWT 的受众等于 `appID`。adapter 在受众错误时于边界处拒绝，不到 agent。
3. Bot Framework 门户里的消息端点指向你 Ankole 部署的 Teams webhook 路由。
4. 机器人已安装到该 team 或频道（Teams 不会为不是成员的机器人投递活动）。
5. signal binding 已启用，并指向这个 agent。
6. agent 有可用的 model profile，provider 凭证有效。

查看 worker 最近的输出，但不要打印它的环境：

```bash
docker logs --tail 200 ankole-dev-agent-computer   # 本地
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## 与其它首机器人指南有什么不同

walkthrough 的形态一致；Teams 专属的部分是所有 adapter 里最重的：

- **公共 HTTPS 入口强制。** Lark、Slack、钉钉都用长连接或 Socket Mode；Teams 把消息作为 Bot Framework webhook 调用投递。没有公共端点，就没有 Teams 机器人。
- **Bot Framework JWT 校验。** adapter 校验签发方、受众（`appID`）和 service URL；Emulator 路径被刻意拒绝。`appID` 错在边界处失败，不悄悄放过。
- **Graph 订阅用于 directory 实时同步。** `SubscriptionReconciler` 在 48 小时窗口内续订，重建掉线订阅；Graph 投递到你的公共 webhook，由 adapter 设置的 `clientState` 鉴权。
- **最广的契约面。** 四个声明：Teams 聊天 adapter、`teams` webhook handler（kinds `messages`）、`entra-id` identity provider、`entra-id` webhook handler（kinds `directory`）。adapter 做的事比聊天多。

## 下一步去哪里

你现在有一个 agent 在一个 Teams 频道里活着。从这里出发：

- **让它观察频道对话**——把 binding 的 `unaddressed_group_message_policy` 改开。
- **给它节奏**——加一条[调度](../schedules/)，每天发一份帖子。
- **交接长工作**——让 agent 委派给[后台任务](../background-jobs-ops/)，见[后台研究任务](../background-research-job/)指南。
- **通过 Entra ID 联合管理员登录**——若跳过了第 3 步，配置 identity provider，并把 directory group 同步进 AuthZ。

运维界面读 [Console 运维操作](../console-operations/)。adapter 内部读 [Microsoft 365 adapter](../adapters-microsoft-365/) 专页。
