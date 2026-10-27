# DingTalkOpenAPI

[English](README.md) | 简体中文

`DingTalkOpenAPI` 是 Ankole 的钉钉企业内部应用轻量客户端，覆盖新旧双域名 REST 接口、Stream
模式长连接、授权码登录、通讯录、机器人消息与卡片实例。本库专注于协议通信，不包含任何 Ankole
业务策略。

```elixir
client =
  DingTalkOpenAPI.Client.new(
    client_id: "ding…",
    client_secret: fn -> System.fetch_env!("DINGTALK_APP_SECRET") end
  )

{:ok, user} = DingTalkOpenAPI.get(client, "/v1.0/contact/users/me", token: {:user, user_token})
```

- **新旧双域名路由**：以 `topapi/` 或 `media/` 开头的路径发往旧域名（`oapi.dingtalk.com`，访问令牌放入
  `access_token` 查询参数，失败表现为 HTTP 200 且 `errcode` 非零）；其余路径发往新域名
  （`api.dingtalk.com`，访问令牌放入 `x-acs-dingtalk-access-token` 请求头，失败表现为
  HTTP 错误状态码加 `{code, message}`）。两套接口的错误统一转换为带有稳定分类 `reason` 的
  `DingTalkOpenAPI.Error`。
- **令牌缓存与刷新**：`DingTalkOpenAPI.TokenManager` 按凭证集缓存应用访问令牌，并在过期前主动刷新；若多个请求同时未命中缓存，会合并为一次上游请求。
- **Stream 长连接生命周期**：`DingTalkOpenAPI.Stream.Client` 负责注册连接（单次连接票据有效期约 90 秒，每次均重新获取）、升级 WebSocket、在主循环内同步原样回传 `SYSTEM` `ping` 的透传字段（`opaque`），并在收到 `SYSTEM` `disconnect` 后立即重新注册建连。`EVENT` 与 `CALLBACK`
  帧交由 `DingTalkOpenAPI.EventTaskSupervisor` 异步处理，仅在处理函数提交完成后才发送确认：若 `EVENT` 处理函数返回错误则回复 `LATER`，若发生崩溃则不发送确认，这两种情况下钉钉平台都会重新投递。
- **业务接口封装**：`OAuth` 串联授权码登录流程（`authCode` → 用户访问令牌 → `contact/users/me` →
  `topapi/user/getbyunionid`）；`Contact`、`Robot` 与 `Card` 分别封装通讯录查询、机器人消息发送/撤回/媒体上传，以及卡片实例与流式更新接口。

在仓库根目录运行 `bun run control-plane:test:plugins dingtalk_adapter` 执行测试。
