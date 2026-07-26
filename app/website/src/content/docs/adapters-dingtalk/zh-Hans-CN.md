---
title: 钉钉 adapter
description: 把一个 agent 接到钉钉——企业内部应用、Stream 长连接、AI 卡片回复、markdown 渲染，以及用于管理员登录的 OIDC identity provider。
section: User guide
order: 16
---

钉钉 adapter 把一个 Ankole agent 接到钉钉。它承载两个面：一个聊天 binding，读取机器人消息并通过 AI 卡片回复；一个 identity provider 面，让管理员用钉钉 OIDC 登录 Console。两个面共用一条 Stream 长连接，也共用同一对 AppKey/AppSecret。本页是运维者的设置路径。

## adapter 声明了什么

`Ankole.Plugins.DingTalkAdapter`（`plugin_id: "dingtalk-adapter"`）声明两个 adapter 声明：

- **`signals_gateway.adapter`**（`id: "dingtalk"`）——聊天面，即「裁剪过的聊天面」。一个 signal binding 把钉钉消息和卡片回调路由给 agent。
- **`principals.identity_provider`**（`id: "dingtalk"`）——身份面。钉钉 OIDC 作为管理员 identity provider，一次 directory 同步把钉钉通讯录拉进 AuthZ。

聊天面被裁剪到钉钉机器人 API 实际能给的：群消息只在 @ 机器人或单聊时投递（`addressed_only`），没有 reaction、edit、recall 这类入境事件。启用钉钉 plugin 后，两个面都可用。

## 前置条件

在钉钉开发者后台创建一个**企业内部应用**。应用凭证给你聊天配置所需的两个值，且这两个值身兼二职：

| 字段 | 含义 |
|---|---|
| `clientId` | 应用的 AppKey，在「基础信息 → 凭证与基础信息」查看。同一个值也作 Stream `clientId`。 |
| `clientSecret` | 应用的 AppSecret，与 AppKey 在同一页面；由控制面加密存储。同一个值也作 Stream `clientSecret`。 |

机器人自身的加密 id 随 stream 到达，所以你不必手工给 adapter 一个 bot 身份——adapter 从入境帧里解析出来，做法和 Lark adapter 相同。可选的 `cardTemplateId` 选定 binding 要流式投递进去的 AI 卡片模板；留空时 AI 回复降级为纯 Markdown。

## 单 binding 约束

这是运维者最先踩到的限制。钉钉按 AppKey/AppSecret 对开一条 Stream 长连接，而这对凭证由聊天面和身份面共用。由此推出两条规则，adapter 在写入 binding 时强制执行：

- **一个 agent 至多有一个启用的钉钉 binding。** 在同一 agent 上再加一个启用的钉钉 binding 会被拒绝（`dingtalk_binding_already_exists`）。
- **一个 `clientId` 不能同时分给两个 agent。** 第二个 agent 复用某个启用 binding 的 `clientId` 会被拒绝（`dingtalk_app_already_bound`）。

更新当前 binding 是允许的，禁用的 binding 不占应用——这条约束只管**启用**的 binding。把 AppKey/AppSecret 对当作单租户资源：一个机器人，一个 agent。

## 创建聊天 binding

```bash
curl -X PUT https://ankole.example.com/api/v1/agents/<agent_uid>/signal-bindings/dingtalk/<binding_name> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "config_ref": "...", "filters": { ... }, "unaddressed_group_message_policy": "..." }'
```

binding 的 `config_ref` 指向钉钉应用配置（即 `signals_gateway.dingtalk.bindings.<id>` 这条 AppConfigure 键）。filter 和群消息策略字段见 [Signal binding](../signal-bindings/)，所有 adapter 共用。

## Stream 模型

钉钉不用 HTTP webhook 推事件。adapter 按 AppKey/AppSecret 对持有一条 Stream 长连接（`connection_key` 为 `{"dingtalk", clientId}`），聊天面和身份面共用它。由于这对凭证本身就是 Stream 的 `clientId`/`clientSecret`，无需再配第二个 secret——做 API 鉴权的 AppKey/AppSecret，就是开 stream 的那对。

App token 按凭证集合缓存。轮换 token 不会立即生效，而是在下一次 token 刷新时生效；如果你轮换了 `clientSecret`，缓存的 token 在那次刷新之前都是过期的。

## 回复：AI 卡片与 markdown

agent 通过钉钉的 AI 卡片投递回复，markdown 作为降级。adapter 把模型输出渲染成钉钉卡片平台所期望的卡片形态，通过 `PUT /v1.0/card/streaming` 流式投递；卡片模板放在 `priv/card_template/` 下，运维者每个钉钉组织构建一次，把它的 `cardTemplateId` 粘进 binding。`cardTemplateId` 留空会关闭卡片流式，AI 回复降级为纯 Markdown 消息。

markdown 分段由 adapter 负责，因为钉钉 markdown 有自己的约束。如果一条模型回复含有钉钉无法逐字渲染的内容，adapter 的 markdown 分段器会调和它；回复仍然显示异常，通常是因为模型产出了钉钉支持子集之外的内容。

## 钉钉作为管理员 identity provider

身份面让管理员用自己的钉钉账号登录 Console。通过 identity-provider 界面配置，`adapter_id` 取 `"dingtalk"`：

```bash
curl -X PUT https://ankole.example.com/api/v1/identity-providers/<provider_id> \
  -H "Authorization: Bearer $CONSOLE_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{ "adapter_id": "dingtalk", "oidc": { "enabled": true, "scope": "openid corpid" } }'
```

应用必须已发布版本，并在应用的「开发配置 → 安全设置 → 重定向URL（回调域名）」里登记登录回调地址；钉钉找不到应用时会直接拒绝浏览器登录。登录后，一次 directory 同步（`sync.contacts`）把钉钉通讯录、部门组和成员关系拉进 AuthZ，上面再叠一层增量通讯录变更流（`sync.websocket`）。

## 出问题的时候

常见失败是配置形态的，不是代码形态的：

- **`clientId` / `clientSecret` 校验失败**——两者都是必填字符串，留空或缺失会过不了 `validate_chat_config`。从企业内部应用的「基础信息 → 凭证与基础信息」复制 AppKey/AppSecret。
- **机器人不回复**——确认机器人订阅了正确事件、测试用户和会话在范围内、binding 已启用、agent 有可用的 model profile、Stream 连接还在。[FAQ](../faq/) 的排查顺序适用。
- **轮换后 token 过期**——app token 按凭证集合缓存，轮换 `clientSecret` 后要到下一次 token 刷新才生效。
- **第二个 binding 被拒**——这是单 binding 约束，不是 bug。一个 agent 至多持有一个启用的钉钉 binding，一个 `clientId` 至多服务一个 agent。先禁用或重新分配，再加第二个。

## 下一步

- binding 模型，读 [Signal binding](../signal-bindings/)。
- identity-provider 路由，读 [Console API 参考](../console-api/)。
- 入境管线，读 [SignalsGateway](../signals-gateway/) 开发者页。
