# DingTalkOpenAPI

[English](README.md) | 简体中文

`DingTalkOpenAPI` 是 Ankole 的钉钉企业内部应用薄客户端：新旧双域 REST、Stream
模式长连接、授权码登录、通讯录、机器人消息与卡片实例。库内刻意不含任何 Ankole
领域策略。

```elixir
client =
  DingTalkOpenAPI.Client.new(
    client_id: "ding…",
    client_secret: fn -> System.fetch_env!("DINGTALK_APP_SECRET") end
  )

{:ok, user} = DingTalkOpenAPI.get(client, "/v1.0/contact/users/me", token: {:user, user_token})
```

- 以 `topapi/` 或 `media/` 开头的路径走旧域（`oapi.dingtalk.com`，token 挂
  `access_token` 查询参数，失败形态为 HTTP 200 + 非零 `errcode`）；其余路径走新域
  （`api.dingtalk.com`，token 挂 `x-acs-dingtalk-access-token` 请求头，失败形态为
  HTTP 状态码 + `{code, message}`）。两种方言统一归一化为
  `DingTalkOpenAPI.Error`，附带稳定的分类 `reason`。
- 应用 accessToken 由 `DingTalkOpenAPI.TokenManager` 按凭证集缓存并在过期前主动
  刷新，并发未命中合并为一次上游请求。
- `DingTalkOpenAPI.Stream.Client` 负责 Stream 模式生命周期：注册连接（ticket 约
  90 秒且单次使用，一律现取现用）、升级 WebSocket、在主循环内同步回射 SYSTEM
  `ping` 的 opaque、收到 SYSTEM `disconnect` 后立即重新注册建连。EVENT/CALLBACK
  帧投递到 `DingTalkOpenAPI.EventTaskSupervisor` 异步处理，handler 提交完成后才回
  ack——EVENT handler 出错回 `LATER`、崩溃则不回 ack，两种情况平台都会重投。
- `OAuth` 覆盖授权码登录链（`authCode` → 用户 accessToken → `contact/users/me` →
  `topapi/user/getbyunionid`）；`Contact`、`Robot`、`Card` 分别封装通讯录、机器人
  发送/撤回/媒体上传与卡片实例/流式端点。

在本目录运行 `mix test` 执行测试。
