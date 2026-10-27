# SlackOpenAPI

`SlackOpenAPI` 是 Ankole 的轻量 Elixir Slack 客户端，覆盖 Web API、
Socket Mode、Sign in with Slack、游标分页、私有文件下载，以及外部三步文件上传流程。本库专注于协议通信，不包含 Ankole 业务领域策略。

```elixir
client =
  SlackOpenAPI.Client.new(
    bot_token: fn -> System.fetch_env!("SLACK_BOT_TOKEN") end,
    app_token: fn -> System.fetch_env!("SLACK_APP_TOKEN") end
  )

{:ok, auth} = SlackOpenAPI.post(client, "auth.test", body: %{})
```

Socket Mode 事件处理函数在 `SlackOpenAPI.EventTaskSupervisor` 下异步执行，客户端仅在分发提交成功后才发送确认：所有已提交的结果（包括已过滤或已忽略等终局策略结论）都会发送确认；若处理函数返回错误或崩溃，客户端则不发送确认，以便 Slack 重新投递该信封。收到 Slack 例行轮换的 `disconnect` 通知时，客户端会立即重连；若遇到凭证失效等鉴权错误，则直接停止客户端。

在仓库根目录执行 `bun run control-plane:test:plugins slack_adapter` 运行测试。
