---
title: 你的第一个钉钉机器人
description: 一份完整 walkthrough——部署 Ankole、配置 provider、创建 agent、通过 Stream API 绑到钉钉机器人，并验证机器人在会话里回复。
section: Guides
order: 304
---

本指南把一个 agent 一路带到可用的钉钉机器人：在会话里 @、收到真实的模型回复、并验证端到端路径。读完你会得到一个能在钉钉里 @ 的 agent，并对沿途每一个边界都心中有数。

一句话讲完流程：**部署 Ankole → 激活并登录 → 配置 provider → 创建 agent → 绑到钉钉 → @ 机器人 → 验证回复。**

本指南与[你的第一个 Lark 机器人](../lark-first-bot/)镜像——共享步骤的更多深度先读那一篇。差异是钉钉专属的：Stream API 传输、流式回复的卡片模板模型、以及一个容易踩的单 binding 约束。

## 前置条件

- 一台满足[平台支持](../platform-support/)的 Linux 主机或 Kubernetes 集群。
- 一个能在[钉钉开发者后台](https://open-dev.dingtalk.com/)创建企业内部机器人的钉钉账号。
- 一个用于真实模型回合的 LLM provider API key。

## 第 1 步：部署 Ankole

按[安装部署](../installation/)——单机用 Docker Compose，集群用 Helm。栈健康后，打开 HTTPS `/setup` 页面，从控制面日志读取激活码。输入 code。在 plugin 这一步，保持**钉钉 adapter 启用**。

## 第 2 步：创建钉钉机器人

在钉钉开发者后台创建企业内部机器人。机器人给你一对一物两用的凭证：

| 字段 | 它是什么 | 它兼任什么 |
|---|---|---|
| `clientId` | 机器人的 AppKey | Stream API 的 `clientId` |
| `clientSecret` | 机器人的 AppSecret | Stream API 的 `clientSecret` |

一对凭证既给机器人鉴权，又打开投递事件的 Stream 连接。为机器人订阅所需事件——钉钉默认只把 @ 和私信投递给机器人，所以 agent 在被点名时醒来，而非每条群消息都醒。

机器人自己的 id（`robotCode`）对企业内部机器人默认就是 AppKey；通常无需手设。

## 第 3 步：构建 AI 卡片模板（用于流式回复）

Ankole 在钉钉上通过模板托管的 AI 卡片投递流式回复。卡片布局住在钉钉卡片平台；Ankole 只向卡片实例注入一组固定变量。每个钉钉组织构建一次这个模板：

1. 打开卡片平台 → 新建模板 → 选 **AI 卡片** 类别（它带 Ankole 通过流式 API 驱动的原生 输入中 / 已完成 / 出错 状态）。
2. 按 adapter 的 `priv/card_template/README.md` 文档，用完全一致的变量名加入那些变量。
3. 发布模板，复制它的 `cardTemplateId`。

在第 6 步把 `cardTemplateId` 粘进聊天 binding。留空则禁用卡片流式——回复降级为纯 Markdown，可用，但没有流式状态。

## 第 4 步：通过钉钉登录（可选）并启用 directory 同步

钉钉也能作为管理员 identity provider，带 OIDC 和 directory 同步（`directory_full_sync`、`directory_realtime_sync`）。通过设置流程或 `PUT /identity-providers/<provider_id>`（`adapter_id: "dingtalk"`）配置。Directory 同步把钉钉组织结构拉进 AuthZ group。

若只想要聊天机器人，跳过这一步——聊天 binding 不依赖它。

## 第 5 步：配置 provider、绑 profile、创建 agent

按 [Provider 与模型](../providers-and-models/)新增 provider 并绑定必需的 model profile 槽（`primary`、`light`、`heavy`）。按 [Agent](../agents/) 用 `POST /agents` 创建 agent，并至少撰写一份 `mission` 文档。

## 第 6 步：把 agent 绑到钉钉——留意单 binding 规则

创建 signal binding：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/dingtalk/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<dingtalk-config-key>", "cardTemplateId": "<template-id>" }'
```

这里有两个钉钉专属的约束，adapter 都强制执行：

- **一个 agent 最多一个启用的钉钉 binding。** 同一 agent 上第二个启用的 binding 会以 `dingtalk_binding_already_exists` 失败。想重绑，先禁用或删除旧的。
- **一个 `clientId` 不能绑给两个 agent。** 在第二个 agent 上复用同一机器人凭证会以 `dingtalk_app_already_bound` 失败（错误会点出 `clientId` 和已持有它的 agent）。每个 agent 用单独的机器人。

这两条存在，是因为 Stream 连接是按凭证一一对应——一个机器人不能服务两个 agent，一个 agent 也不需要两个钉钉 binding。一个 agent 配一个机器人。

## 第 7 步：验证机器人回复

打开与机器人的会话（或在它已加入的群里 @ 它）。发一个简单问题：

> 你能做什么？

收到回复，意味着整条路径都通了：Stream API 投递了事件、signal binding 接受了它、actor 醒来、model profile 解析成功、卡片（或 Markdown 兜底）渲染完成。如果机器人不回复，按顺序排查：

1. 最新版机器人已发布，且对测试用户已启用。
2. `clientId` 和 `clientSecret` 正确——错误的一对会在任何事件流动之前就让 Stream 握手失败。
3. 会话是钉钉会投递给机器人的那种（群里的 @，或私信）。钉钉不会把非 @ 的群消息投递给机器人。
4. signal binding 已启用，并指向这个 agent——且没有别的 agent 持有这个 `clientId`。
5. agent 有可用的 model profile，provider 凭证有效。
6. 如果回复看起来错（不只是没有），检查 `cardTemplateId`：空或错的 id 降级为 Markdown，而不是大声失败。

查看 worker 最近的输出，但不要打印它的环境：

```bash
docker logs --tail 200 ankole-dev-agent-computer   # 本地
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## 与 Lark 机器人有什么不同

walkthrough 的形态一致；钉钉专属的部分是：

- **Stream API，凭证兼任 Stream 凭证。** 一对 `clientId`/`clientSecret` 既鉴权又开 Stream；无需管理第二个 token。
- **模板托管的 AI 卡片。** 卡片布局住在钉钉卡片平台，binding 带 `cardTemplateId`。留空降级为 Markdown；Lark 在 adapter 内渲染卡片，无需单独模板步骤。
- **单 binding、单 clientId 约束。** 每个 agent 一个启用 binding，每个 `clientId` 一个 agent。Lark 和 Slack 不强制——按机器人规划。

## 下一步去哪里

你现在有一个 agent 在一个钉钉会话里活着。从这里出发：

- **给它节奏**——加一条[调度](../schedules/)，每天发一份帖子。
- **交接长工作**——让 agent 委派给[后台任务](../background-jobs-ops/)，见[后台研究任务](../background-research-job/)指南。
- **联合管理员登录**——若跳过了第 4 步，把钉钉配置为 identity provider。
- **更多 agent**——一个 agent 一个机器人；重复第 2 步和第 5–6 步。

运维界面读 [Console 运维操作](../console-operations/)。adapter 内部读[钉钉 adapter](../adapters-dingtalk/) 专页。
