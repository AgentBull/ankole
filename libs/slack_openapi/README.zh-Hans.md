# SlackOpenAPI

`SlackOpenAPI` 是 Ankole 使用的轻量 Elixir Slack 客户端，覆盖 Web API、
Socket Mode、Sign in with Slack、cursor 分页、私有文件下载与 external upload
三步上传。库内不放 Ankole 领域策略。

```elixir
client =
  SlackOpenAPI.Client.new(
    bot_token: fn -> System.fetch_env!("SLACK_BOT_TOKEN") end,
    app_token: fn -> System.fetch_env!("SLACK_APP_TOKEN") end
  )

{:ok, auth} = SlackOpenAPI.post(client, "auth.test", body: %{})
```

Socket Mode handler 在 `SlackOpenAPI.EventTaskSupervisor` 中执行；只有 dispatch
成功后才回 ack——已提交的结果（含 filtered/ignored 等终局策略决定）回 ack，而错误或
handler 崩溃不回 ack，由 Slack 重投信封。Slack 的例行 disconnect 会立即重连，凭证类
错误则停止客户端。

在本目录执行 `mix test`。
