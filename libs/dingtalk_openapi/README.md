# DingTalkOpenAPI

English | [简体中文](README.zh-Hans.md)

`DingTalkOpenAPI` is Ankole's thin Elixir client for DingTalk enterprise-internal
apps: dual-domain REST, Stream-mode long connection, authorization-code login,
contacts, robot messaging, and card instances. It intentionally contains no
Ankole domain policy.

```elixir
client =
  DingTalkOpenAPI.Client.new(
    client_id: "ding…",
    client_secret: fn -> System.fetch_env!("DINGTALK_APP_SECRET") end
  )

{:ok, user} = DingTalkOpenAPI.get(client, "/v1.0/contact/users/me", token: {:user, user_token})
```

- Paths starting with `topapi/` or `media/` route to the old domain
  (`oapi.dingtalk.com`, token in the `access_token` query parameter, failure as
  HTTP 200 + non-zero `errcode`); everything else routes to the new domain
  (`api.dingtalk.com`, token in the `x-acs-dingtalk-access-token` header,
  failure as an HTTP status + `{code, message}`). Both dialects normalize into
  `DingTalkOpenAPI.Error` with a stable classified `reason`.
- App access tokens are fetched, cached, and proactively refreshed per
  credential set by `DingTalkOpenAPI.TokenManager` (concurrent misses coalesce
  into one upstream fetch).
- `DingTalkOpenAPI.Stream.Client` owns the Stream-mode lifecycle: register a
  connection (the ticket is ~90 s single-use and always fetched fresh), upgrade
  the WebSocket, echo SYSTEM `ping` opaques synchronously, and re-register at
  once on a SYSTEM `disconnect`. EVENT/CALLBACK frames dispatch in
  `DingTalkOpenAPI.EventTaskSupervisor` and are acknowledged only after the
  handler commits — an EVENT handler error acks `LATER` and a crash withholds
  the ack, so the platform redelivers either way.
- `OAuth` covers the authorization-code login chain (`authCode` → user access
  token → `contact/users/me` → `topapi/user/getbyunionid`); `Contact`, `Robot`,
  and `Card` wrap the directory, robot messaging/recall/media, and card
  instance/streaming endpoints.

Run tests with `mix test` from this directory.
