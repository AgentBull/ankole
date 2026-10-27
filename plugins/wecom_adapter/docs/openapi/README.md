# WeComOpenAPI

`WeComOpenAPI` is a thin Elixir client for WeCom (企业微信), built for Ankole's
WeCom adapter across two platform surfaces:

- **AI-bot channel** (`WeComOpenAPI.Bot.Client` + `WeComOpenAPI.Bot`): manages
  the `wss://openws.work.weixin.qq.com` WebSocket long connection, including
  subscription authentication, ping heartbeats, message and event dispatch,
  streaming replies, template cards, proactive messages, chunked media uploads,
  and encrypted media downloads (`WeComOpenAPI.Media`). Because WeCom permits
  only one live connection per bot, receiving a `disconnected_event` kick stops
  the client cleanly instead of competing with the new connection holder.
- **Corp REST** (`WeComOpenAPI` + `WeComOpenAPI.Corp.Client`): wraps the
  `https://qyapi.weixin.qq.com` REST API with cached access tokens keyed by
  `{corp_id, secret}` (`WeComOpenAPI.TokenManager`), WWLogin OAuth helpers
  (`WeComOpenAPI.OAuth`), and directory lookups (`WeComOpenAPI.Contact`, where
  reading member names requires the contacts-sync secret).

The client normalizes errors from both surfaces into `WeComOpenAPI.Error` with a
stable `reason` classification (`:auth`, `:ip_rejected`, `:rate_limited`, …).

## Example

```elixir
dispatcher =
  WeComOpenAPI.Bot.Dispatcher.new()
  |> WeComOpenAPI.Bot.Dispatcher.on_message(fn event ->
    WeComOpenAPI.Bot.reply_markdown(MyBot, event.req_id, "received")
    :ok
  end)

{:ok, _pid} =
  WeComOpenAPI.Bot.Client.start_link(
    bot_id: "BOT_ID",
    secret: "SECRET",
    dispatcher: dispatcher,
    name: MyBot
  )
```
