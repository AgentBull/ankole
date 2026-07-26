---
title: Slack adapter
description: 把一个 agent 接到 Slack——Slack 应用、bot 与 app token、事件投递、@ 路由、directory 成员，以及把 Slack 用作管理员身份提供方。
section: User guide
order: 17
---

Slack adapter 把一个 Ankole agent 接到一个 Slack workspace。它承载一个用于收发消息的聊天面，一个用 Slack 做管理员登录的身份提供方面，并拥有 Slack directory 成员，让频道里的 agent 知道频道里都有谁。本页是运维者的设置路径。

## adapter 声明了什么

`Ankole.Plugins.SlackAdapter`（plugin_id 为 `"slack-adapter"`）注册两份契约，两者都用 `"slack"` 这个 id：

- 一份**聊天**声明，挂在 `signals_gateway.adapter` 下，以及
- 一份**身份**声明，挂在 `principals.identity_provider` 下。

每一个 Slack AppConfigure pattern 都加密——无一例外。token 是 secret 材料，控制面加密存储。聊天 binding 放在 `signals_gateway.slack.bindings.<id>`，identity provider 放在 `principals.identity_providers.slack.<id>`。Slack directory 成员归这个 adapter 拥有，所以你在 Ankole 里看到的成员来自 Slack，不是这里凭空造的。

## 前置条件

在 Slack API dashboard 创建一个 Slack 应用。应用给你聊天配置必需的两个 token，adapter 对它们做严格校验：

| 字段 | 格式规则 | 含义 |
|---|---|---|
| `botToken` | 必须以 `xoxb-` 开头 | agent 行动所用的 bot user token |
| `appToken` | 必须以 `xapp-` 开头 | 驱动 Socket Mode、负责事件投递的 app-level token |

两个 token 都必需。缺 `botToken` 会以 `{:missing, "botToken"}` 失败，缺 `appToken` 会以 `{:missing, "appToken"}` 失败。前缀错的 token 会以 `{:invalid_token_prefix, "botToken"}` 或 `{:invalid_token_prefix, "appToken"}` 失败——不以 `xoxb-` 开头的 `botToken`，或不以 `xapp-` 开头的 `appToken`，在保存时就被拒。在应用里打开 Socket Mode，并订阅 agent 应当看到的事件（消息、app mention）。

## 创建聊天 binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/slack/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

binding 的 `config_ref` 指向 Slack 应用配置。filter 和群消息策略字段所有 adapter 共用，见 [Signal binding](../signal-bindings/)。

## Socket Mode 与事件投递

`appToken` 驱动 Socket Mode：adapter 用这个 app-level token 与 Slack 建立一条长连 WebSocket，事件从这条连接进来。这就是 Slack adapter 用的投递模型，不需要你自建对外 HTTP 入口。appToken 一变，adapter 的 `secret_fingerprint` 也跟着变，新 token 上会重新拉起一条连接。

## @ 路由

Slack 的 app-mention 事件决定 agent 何时被点名。adapter 的 @ 路由把入境消息分成 `addressed` 事件（agent 被 @）和 `may_intervene` 事件（允许 agent 插话）。binding 的 `unaddressed_group_message_policy` 就是你在频道里调节 agent 角色的那个字段——不点名就安静，还是观察并愿意插话。

## directory 成员

这个 adapter 拥有 Slack directory 成员。一个 Slack 频道的成员，事实来源在 Slack 那一侧；adapter 把它投影进 Ankole，让频道里的 agent 能就谁能看到它说的话做推理。成员不是第二事实来源——Slack 里的变动随 adapter 同步传播，全量同步走一轮，实时变动走 Socket Mode。正是这份投影，让一个 binding 把 agent 限定到某个频道时，它能知道频道里的人。

## 把 Slack 用作管理员身份提供方

同一个 adapter 也能用 OIDC 担当管理员登录的身份提供方。通过 identity-provider 路由配置：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/<id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "slack", "config_ref": "..." }'
```

`adapter_id` 设成 `"slack"`，登录就走 Slack 的 OIDC，directory（Slack 用户与 usergroup）也会同步进 Ankole 的 AuthZ。identity-provider 路由见 [Console API 参考](../console-api/)。

## 出问题的时候

- **保存时校验失败**——检查 token 前缀（`botToken` 用 `xoxb-`，`appToken` 用 `xapp-`），并确认两者都没缺。报错会指明字段和规则。
- **机器人不回复**——确认应用订阅了正确事件、bot 在频道里、binding 已启用、agent 有可用的 model profile。[FAQ](../faq/) 顺序适用。
- **成员看起来过期**——Slack directory 成员是从 Slack 投影过来的；给同步一个周期，或检查 Slack 应用能读取 workspace 名册、Socket Mode 已连上。

## 下一步

- binding 模型，读 [Signal binding](../signal-bindings/)。
- identity-provider 路由，读 [Console API 参考](../console-api/)。
- 入境管线，读 [SignalsGateway](../signals-gateway/) 开发者页。
