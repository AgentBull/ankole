---
title: 你的第一个 Lark 机器人
description: 一份完整 walkthrough——部署 Ankole、配置 provider、创建 agent、绑到 Lark 自建应用，并验证机器人在会话里回复。
section: Guides
order: 300
---

本指南把一个 agent 一路带到可用的 Lark（或飞书）机器人：在会话里发一条消息、收到真实的模型回复、并验证端到端路径。读完你会得到一个能在 Lark 会话里 @ 的 agent，并对沿途每一个边界都心中有数。

一句话讲完流程：**部署 Ankole → 激活并登录 → 配置 provider → 创建 agent → 绑到 Lark → @ 机器人 → 验证回复。**

## 前置条件

- 一台满足[平台支持](../platform-support/)的 Linux 主机或 Kubernetes 集群。
- 一个能在[飞书开放平台](https://open.feishu.cn/)（或 Lark 对应平台）创建企业自建应用的飞书/Lark 账号。
- 一个用于真实模型回合的 LLM provider API key。

本指南在每一步复用运维页，并链接出去，而不是重复字段表。边做边打开它们。

## 第 1 步：部署 Ankole

按[安装部署](../installation/)——单机用 Docker Compose，集群用 Helm。栈健康后，打开 HTTPS `/setup` 页面。从控制面日志读取激活码：

```bash
# Compose
docker compose logs control-plane | grep "SETUP ACTIVATION CODE"
# Helm
kubectl -n ankole logs deployment/ankole-control-plane -c control-plane | grep "SETUP ACTIVATION CODE"
```

输入 code。在 plugin 这一步，保持**飞书/Lark adapter 启用**。如果飞书 identity-provider 选项没出现，重启一次控制面再回到设置流程。

## 第 2 步：创建 Lark 自建应用

在飞书开放平台创建企业自建应用，启用其**机器人能力**，并把测试用户纳入应用的可用范围。用类似 `Ankole Local` 的名字，免得和正式应用混淆。

把 OIDC 回调 URL 加到应用的安全设置里：

```text
http://localhost:4000/sessions/oidc/lark-main/callback
```

生产主机用真实的 HTTPS origin 代替 `localhost`。`localhost` 和 `127.0.0.1` 是不同的 redirect URI——除非你也更新了白名单条目，否则用文档约定的形态。

授予基准消息 scope，让机器人能读能回：`im:message:send_as_bot`、`im:message:readonly`、`im:message:update`、`im:message.group_at_msg:readonly`、`im:message.p2p_msg:readonly`、`im:resource`。如果你的 binding 要让 agent 观察没被 @ 的群消息，再加 `im:message.group_msg`。发布一个初始应用版本——未发布的设置对测试用户不生效。

## 第 3 步：通过 Lark 登录并启用 directory 同步

回到 Ankole 设置流程，创建飞书 identity provider：

| 字段 | 值 |
|---|---|
| Provider ID | `lark-main` |
| Domain | Feishu（国际域名用 Lark） |
| App ID | 测试应用的 App ID |
| App Secret | 测试应用的 App Secret |
| OIDC | 启用 |
| Directory sync | 启用 |
| WebSocket 增量同步 | 启用 |

保存 provider 并完成 OIDC 登录。第一个成功登录的用户成为本部署的 root 管理员，激活码随之失效。保存 provider 还会从控制面建立出站 WebSocket 长连接——需要互联网访问，但不需要公网 IP、反向代理或隧道。

在飞书的事件与回调页，选择**长连接**选项，加入 agent 应当看到的事件：消息用 `im.message.receive_v1`，需要 directory 同步则加 `contact.user.*` 和 `contact.department.*` 事件。飞书在检测到客户端之前可能拒绝长连接事件——遇到时保持控制面运行并重试。

## 第 4 步：配置 provider 并绑定 model profile

agent 背后需要模型。按 [Provider 与模型](../providers-and-models/)：

1. 新增 provider 行：`PUT /ai-gateway/providers/<provider_id>`，带上你的 LLM 凭证。
2. 创建 agent（下一步），再把至少三个必需的 model profile 槽——`primary`、`light`、`heavy`——绑到该 provider 的选择符上。

## 第 5 步：创建 agent

按 [Agent](../agents/)。用 `POST /agents` 创建，记下它的 `uid`，并至少撰写一份 `mission` 文档，让 agent 知道自己的范围：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/library-documents/mission \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "content": "你是我们 Lark 工作区里的助手。回答要简洁。" }'
```

现在把 model profile 绑到这个 agent（第 4 步的后半）。

## 第 6 步：把 agent 绑到 Lark

创建 signal binding，把这个 agent 接到你的 Lark 应用：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/lark/main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "<lark-config-key>", "unaddressed_group_message_policy": "addressed_only" }'
```

`config_ref` 指向 Lark 聊天配置（第 2 步的 `appID`/`appSecret`/`domain` 三元组）。`addressed_only` 是最安全的首发策略——agent 只在被直接 @ 时醒来，而非每条群消息都醒。policy 字段见 [Signal binding](../signal-bindings/)，binding 承载的内容见 [Lark adapter](../adapters-lark/) 专页。

## 第 7 步：验证机器人回复

把机器人加进测试群，或开一个与它的单聊。@ 它一个简单问题：

> @Ankole Local 你能做什么？

收到回复，意味着整条路径都通了：长连接投递了事件、signal binding 接受了它、actor 醒来、model profile 解析成功、CardKit 回复渲染完成。如果机器人不回复，不要先追第二个错误——按 [FAQ](../faq/) 顺序排查：

1. 最新版应用已发布，且机器人能力已开启。
2. 测试用户和会话在范围内，机器人在该会话里。
3. 消息 scope（`im:message:send_as_bot`、`im:message:readonly`……）已激活。
4. signal binding 已启用，并指向这个 agent。
5. agent 有可用的 model profile，provider 凭证有效。
6. worker（本地 `ankole-dev-agent-computer`）就绪。

查看 worker 最近的输出，但不要打印它的环境：

```bash
docker logs --tail 200 ankole-dev-agent-computer   # 本地
kubectl -n ankole logs -l app.kubernetes.io/component=worker --tail=200  # Helm
```

## 你现在有什么，下一步去哪里

你现在有一个 agent 在一个 Lark 频道里活着——这是能证明模型可用的最小端到端 Ankole 部署。从这里出发：

- **更多 agent 或频道**——为每一个重复第 5–6 步。一个 binding 一个 adapter，一个 agent 可以持多个 binding。
- **让它观察群聊**——把 binding 的 `unaddressed_group_message_policy` 从 `addressed_only` 改开，并授予 `im:message.group_msg`。
- **给它节奏**——加一条[调度](../schedules/)，让 agent 每天发一份摘要。
- **交接长工作**——让 agent 委派给[后台任务](../background-jobs-ops/)。

你在每一步用到的运维界面，读 [Console 运维操作](../console-operations/)。adapter 内部细节，读 [Lark adapter](../adapters-lark/) 专页。
