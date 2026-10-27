# DingTalkOpenAPI

English | [简体中文](README.zh-Hans.md)

`DingTalkOpenAPI` is Ankole's thin Elixir client for DingTalk enterprise-internal
apps, covering dual-domain REST calls, Stream-mode long connections,
authorization-code login, contacts, robot messaging, and card instances. By
design, it contains no Ankole domain policy.

```elixir
client =
  DingTalkOpenAPI.Client.new(
    client_id: "ding…",
    client_secret: fn -> System.fetch_env!("DINGTALK_APP_SECRET") end
  )

{:ok, user} = DingTalkOpenAPI.get(client, "/v1.0/contact/users/me", token: {:user, user_token})
```

- **Dual-domain REST routing**: The client routes paths starting with `topapi/`
  or `media/` to the legacy domain (`oapi.dingtalk.com`, passing the token in
  the `access_token` query parameter and detecting failures returned as HTTP 200
  with a non-zero `errcode`), and routes all other paths to `api.dingtalk.com`
  (passing the token in the `x-acs-dingtalk-access-token` header and detecting
  failures returned as an HTTP error status with `{code, message}`). Failures
  from both dialects are normalized into `DingTalkOpenAPI.Error` with a stable
  classified `reason`.
- **Token caching**: `DingTalkOpenAPI.TokenManager` fetches, caches, and
  proactively refreshes app access tokens per credential set, coalescing
  concurrent cache misses into a single upstream request.
- **Stream-mode long connection**: `DingTalkOpenAPI.Stream.Client` manages the
  Stream lifecycle: it fetches a fresh single-use connection ticket (~90 s TTL),
  upgrades to WebSocket, echoes `SYSTEM` `ping` opaque payloads synchronously,
  and re-registers immediately upon receiving a `SYSTEM` `disconnect`. It
  dispatches `EVENT` and `CALLBACK` frames under
  `DingTalkOpenAPI.EventTaskSupervisor` and acknowledges them only after the
  handler commits—if an `EVENT` handler returns an error, the client
  acknowledges `LATER`, and if the handler crashes, it withholds the
  acknowledgement so DingTalk redelivers the frame in both cases.
- **Endpoint helpers**: `OAuth` implements the authorization-code login chain
  (`authCode` → user access token → `contact/users/me` →
  `topapi/user/getbyunionid`), while `Contact`, `Robot`, and `Card` wrap
  directory queries, robot messaging/recall/media uploads, and card
  instance/streaming endpoints.

Run tests from the repository root with `bun run control-plane:test:plugins dingtalk_adapter`.
