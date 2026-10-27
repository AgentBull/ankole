# SlackOpenAPI

`SlackOpenAPI` is Ankole's thin Elixir client for the Slack Web API, Socket
Mode, Sign in with Slack, cursor pagination, private-file downloads, and Slack's
three-step external file upload flow. By design, it contains no Ankole domain
policy.

```elixir
client =
  SlackOpenAPI.Client.new(
    bot_token: fn -> System.fetch_env!("SLACK_BOT_TOKEN") end,
    app_token: fn -> System.fetch_env!("SLACK_APP_TOKEN") end
  )

{:ok, auth} = SlackOpenAPI.post(client, "auth.test", body: %{})
```

Socket Mode handlers execute under `SlackOpenAPI.EventTaskSupervisor`, and the
client acknowledges an envelope only after dispatch commits: any committed
outcome (including terminal policy decisions such as filtered or ignored events)
is acknowledged, whereas if a handler returns an error or crashes, the client
withholds the acknowledgement so Slack redelivers the envelope. When Slack asks
the connection to refresh via a routine `disconnect` frame, the client
reconnects immediately; if authentication fails because of invalid credentials,
the client stops instead of retrying in a loop.

Run tests from the repository root with `bun run control-plane:test:plugins slack_adapter`.
