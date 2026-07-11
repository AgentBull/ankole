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

Socket Mode handler 在 `SlackOpenAPI.EventTaskSupervisor` 中执行；dispatch
完成后才回 ack。Slack 的例行 disconnect 会立即重连，凭证类错误则停止客户端。

在本目录执行 `mix test`。
