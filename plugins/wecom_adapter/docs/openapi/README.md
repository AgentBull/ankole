# WeComOpenAPI

Thin Elixir client for WeCom (企业微信), built for Ankole's WeCom adapter.

It covers the two product surfaces the adapter uses:

- **AI-bot channel** (`WeComOpenAPI.Bot.Client` + `WeComOpenAPI.Bot`): the
  `wss://openws.work.weixin.qq.com` long connection — subscribe auth, ping
  heartbeat, message/event dispatch, streaming replies, template cards,
  proactive sends, chunked media upload, and encrypted media download
  (`WeComOpenAPI.Media`). The platform allows one live connection per bot; a
  `disconnected_event` kick stops the client instead of fighting the new
  connection holder.
- **Corp REST** (`WeComOpenAPI` + `WeComOpenAPI.Corp.Client`): the
  `https://qyapi.weixin.qq.com` API with cached access tokens per
  `{corp_id, secret}` (`WeComOpenAPI.TokenManager`), WWLogin helpers
  (`WeComOpenAPI.OAuth`), and contacts directory reads
  (`WeComOpenAPI.Contact`, contacts-sync secret required for member names).

Errors from both surfaces normalize into `WeComOpenAPI.Error` with a stable
`reason` classification (`:auth`, `:ip_rejected`, `:rate_limited`, ...).

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
