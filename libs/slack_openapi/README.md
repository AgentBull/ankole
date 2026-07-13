# SlackOpenAPI

`SlackOpenAPI` is Ankole's thin Elixir client for Slack Web API, Socket Mode,
Sign in with Slack, cursor pagination, private-file downloads, and the external
file-upload flow. It intentionally contains no Ankole domain policy.

```elixir
client =
  SlackOpenAPI.Client.new(
    bot_token: fn -> System.fetch_env!("SLACK_BOT_TOKEN") end,
    app_token: fn -> System.fetch_env!("SLACK_APP_TOKEN") end
  )

{:ok, auth} = SlackOpenAPI.post(client, "auth.test", body: %{})
```

Socket Mode handlers run in `SlackOpenAPI.EventTaskSupervisor`; an envelope is
acknowledged only after dispatch succeeds — a committed result (including a
terminal policy decision such as filtered or ignored) is acked, while an error
or a handler crash withholds the ack so Slack redelivers the envelope. Regular
Slack disconnect refreshes reconnect immediately, while credential failures
stop the client.

Run tests with `mix test` from this directory.
