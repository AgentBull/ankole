---
title: Lark（飞书）adapter
description: 把一个 agent 接到 Lark 或飞书——自建应用、按应用维持的 WebSocket 连接、IM 群同步、CardKit 回复，以及用于管理员登录的 OIDC identity provider。
section: User guide
order: 15
---

Lark adapter 把一个 Ankole agent 接到 Lark 或飞书。它有两个面：一个聊天 binding（agent 在 Lark 会话里读写回复），一个 identity provider 面（Lark OIDC 给管理员登录 Console）。本页是运维者的设置路径。

## adapter 声明了什么

`Ankole.Plugins.LarkAdapter`（plugin id `lark-adapter`）注册两个 adapter 声明：

- **`signals_gateway.adapter`**（`id: "lark"`）——聊天面。一个 signal binding 把 Lark 消息和事件路由给 agent。
- **`principals.identity_provider`**（`id: "lark"`）——身份面。Lark OIDC 作为管理员 identity provider，配置键模式为 `principals.identity_providers.lark.<id>`。

一个 plugin 同时贡献两个面，因为 adapter 声明 `consumer_kinds: [:chat, :identity_provider]`。启用 plugin 后，两个面都可用。

## 前置条件

在 Lark 或飞书开发者后台创建一个**企业自建应用**。聊天配置需要两个字段：

| 字段 | 含义 |
|---|---|
| `appID` | 自建应用标识（必填） |
| `appSecret` | 自建应用密钥（必填，由控制面加密存储） |
| `domain` | `feishu` 或 `lark`——要连接的服务网络 |

为应用订阅 agent 应当看到的事件（消息、@、卡片动作），并授予这些事件所需的权限。

你不需要手填机器人身份。连接建立时，adapter 只凭应用凭证调用 `bot/v3/info`，解析出机器人自己的 `open_id`，并把它只保存在进程内的 consumer 配置里（`runtimeBotOpenID`）。群 @ 事件会带上被 @ 机器人的 `open_id`，于是 adapter 能匹配。这一点与那些让你填 bot id 的 adapter 不同——这里没有任何东西要粘贴。

## 创建聊天 binding

启用 plugin、配置好应用后，把 agent 绑到 Lark：

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/lark/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

binding 的 `config_ref` 指向 Lark 应用配置。一个 binding 不需要聊天配置之外的额外输入——机器人身份在连接建立时解析，不随 binding 存储。filter 和群消息策略字段见 [Signal binding](../signal-bindings/)，所有 adapter 共用。

## 长连接模型

聊天面按 provider 应用维持一条 Feishu/Lark WebSocket，不是每个 binding 一条。一个 `ConnectionOwner` GenServer 持有长连接客户端，按 domain 和 app id 注册。`ConnectionReconciler` 监视已启用的 binding，按数据库变化启停 owner；凡是共享同一个 `domain`、`appID`（即 `connection_key`）以及同一组 secret 与 consumer 指纹的 consumer，由同一个 owner 服务。

owner 是常驻的。WebSocket 客户端退出时 owner 会重启；reconciler 让活着的 owner 集合在下一个 tick 收敛。你不需要自己启停 WebSocket。

## IM 群

Lark IM 群被投影为 `im_group` 类型的 channel。plugin 启动时跑一次 startup sync，之后 `sync_im_groups` 和 `refresh_im_group` 任务维持成员信息。范围限定在某个群的 binding 只在该群的消息上唤醒，群聊里的 agent 也知道群里都有谁。

群成员的事实来源始终在 Lark。你不在 Ankole 里管理成员——变动在同步运行时流入。

## 回复：CardKit

agent 通过 CardKit——Lark 的卡片模型——回复。Outbox 走 CardKit 管线（`markdown_segmenter`、`card_chain`、`renderer`、`error_policy`、`image_resolver`、`i18n`）渲染模型输出，`:card` outbox 操作产出卡片消息请求，卡片内容由 `Card.message_content` 构建。adapter 按 binding 的 reply mode 投递（channel 帖子或楼中楼回复）。

卡片动作可以往返。`card.action.trigger` 事件通过 adapter 作为 `signal.action.invoked` 事件返回，于是 agent 在卡片里发出的一个按钮能驱动一次后续回合。

## Lark 作为管理员 identity provider

身份面让管理员用自己的 Lark 账号登录 Console。通过 identity-provider 界面配置：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/lark-main \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "lark", "oidc": { "enabled": true, "scopes": ["contact:user.employee_id:readonly"] } }'
```

identity-provider 声明携带 `oidc_authorization` 和 `oidc_code_exchange` 能力。`oidc.enabled` 决定该 provider 能否给管理员登录，`oidc.scopes` 控制授权时请求的 scope。Lark 应用必须允许的回调 URL，本地开发用 `http://localhost:4000/sessions/oidc/lark-main/callback`（`<provider_id>` 段与你的 identity-provider id 一致）。登录后，一次 directory 同步把 Lark 通讯录和部门组拉进 AuthZ group。

## 出问题的时候

常见失败是配置形态的，不是代码形态的：

- **机器人在会话里不回复**——确认自建应用的机器人能力已开启、测试用户和会话在范围内、消息/卡片/事件/回调权限已激活、signal binding 已启用、agent 有可用的 model profile。[FAQ](../faq/) 按这个顺序排查。
- **登录失败、回调不匹配**——确认浏览器 origin、provider id 和 Lark 白名单合起来正好得到 provider 期望的回调 URL。
- **某个 binding 不可用**——binding 记下了 `unavailable_reason`；通过 binding 详情路由读取。
- **机器人身份解析不出来**——adapter 在连接建立时调用 `bot/v3/info`；这次调用失败（`appID`/`appSecret` 不对、机器人能力未开、缺权限）时机器人的 `open_id` 不会设置，@ 也匹配不上。修好应用凭证和权限，让 reconciler 重启连接。

## 下一步

- binding 模型，读 [Signal binding](../signal-bindings/)。
- identity-provider 路由，读 [Console API 参考](../console-api/)。
- 一条 Lark 事件如何变成 actor 事件的入境管线，读 [SignalsGateway](../signals-gateway/) 开发者页。
