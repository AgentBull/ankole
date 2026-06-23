# FeishuOpenAPI

English | [简体中文](README.zh-Hans.md)

`FeishuOpenAPI` is a thin Elixir client for Feishu/Lark OpenAPI and event push.

- you pass raw API paths such as `"contact/v3/users/:user_id"` (the `/open-apis/` prefix is auto-prepended; absolute paths starting with `/` pass through)
- request and response payloads stay weakly typed
- the client handles token fetch, caching, envelope decoding, webhook crypto, and WS event plumbing

This makes it a good fit if you want one small client that can call any Feishu/Lark endpoint without waiting for a generated wrapper.

## Features

- Generic HTTP client for Feishu and Lark
- Automatic `tenant_access_token` / `app_access_token` fetch and cache
- Helpers for self-built apps, marketplace apps, and OIDC `user_access_token`
- Managed OIDC `user_access_token` storage with refresh-token-based auto refresh
- Weakly-typed request building with `body`, `query`, `path_params`, and custom headers
- Multipart upload and binary download helpers
- Webhook decryption and signature verification
- Optional `Plug` webhook adapter
- WebSocket event-push client

## Installation

Add the dependency to `mix.exs`:

```elixir
def deps do
  [
    {:feishu_openapi, "~> 0.1.0"}
  ]
end
```

If you want to use `FeishuOpenAPI.Event.Server` or `FeishuOpenAPI.CardAction.Server`,
also add `:plug` in your app:

```elixir
def deps do
  [
    {:feishu_openapi, "~> 0.1.0"},
    {:plug, "~> 1.16"}
  ]
end
```

## Quick Start

Create a client:

```elixir
client =
  FeishuOpenAPI.new("cli_xxx", "secret_xxx",
    domain: :feishu,
    app_type: :self_built
  )
```

Call an API with the default `tenant_access_token`:

```elixir
{:ok, resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
    path_params: %{user_id: "ou_xxx"},
    query: [user_id_type: "user_id"]
  )

resp["code"] == 0
resp["data"]
```

Send a POST request:

```elixir
{:ok, resp} =
  FeishuOpenAPI.post(client, "im/v1/messages",
    query: [receive_id_type: "user_id"],
    body: %{
      receive_id: "ou_xxx",
      msg_type: "text",
      content: Torque.encode!(%{text: "Hello World"})
    }
  )
```

## Client Model

`FeishuOpenAPI` does not ship generated endpoint modules. You call Feishu/Lark endpoints directly by path.

HTTP verb helpers are `get/3`, `post/3`, `put/3`, `patch/3`, and `delete/3`.
Bang variants such as `get!/3` return the response or raise `FeishuOpenAPI.Error`.

Supported client options:

- `:domain` - `:feishu` or `:lark`
- `:base_url` - override the default domain completely
- `:app_type` - `:self_built` or `:marketplace`
- `:headers` - headers appended to every request
- `:req_options` - low-level `Req` options

Examples:

```elixir
FeishuOpenAPI.new("cli_xxx", "secret_xxx", domain: :lark)

FeishuOpenAPI.new("cli_xxx", "secret_xxx",
  base_url: "https://open.feishu.cn",
  headers: [{"x-custom-header", "1"}]
)
```

The request path may be:

- a shorthand relative path such as `"im/v1/chats"` (auto-prefixed with `/open-apis/`)
- an absolute path such as `"/open-apis/im/v1/chats"` (used verbatim; also works for non-`/open-apis/` paths like `"/callback/ws/endpoint"`)
- a full URL such as `"https://open.feishu.cn/open-apis/im/v1/chats"`

`path_params` accepts either a map or a keyword list.

## Auth and Token Selection

By default, every request uses a cached `tenant_access_token`.

You can override that behavior per request:

- `access_token_type: :tenant_access_token` - default behavior
- `access_token_type: :app_access_token` - use `app_access_token`
- `access_token_type: :user_access_token` - pair with `user_access_token:` or `user_access_token_key:`
- `access_token_type: nil` - do not attach `Authorization`
- `user_access_token: token` - send `Authorization: Bearer <token>` directly (implies `:user_access_token`)
- `user_access_token_key: key` - load a managed `user_access_token` from `FeishuOpenAPI.UserTokenManager` (implies `:user_access_token`)

Examples:

```elixir
# default tenant token
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx")

# app token
FeishuOpenAPI.get(client, "some/app-token-only/api", access_token_type: :app_access_token)

# explicit user token
FeishuOpenAPI.get(client, "contact/v3/users/me",
  user_access_token: "eyJhbGciOi..."
)

# managed user token with auto refresh
FeishuOpenAPI.get(client, "contact/v3/users/me",
  user_access_token_key: "current-user"
)

# no auth header
FeishuOpenAPI.post(client, "auth/v3/tenant_access_token/internal",
  access_token_type: nil,
  body: %{app_id: "cli_xxx", app_secret: "secret_xxx"}
)
```

Tokens are cached in `FeishuOpenAPI.TokenManager` and refreshed 3 minutes before the upstream expiry.

### Self-Built Apps

The built-in auth helpers follow the official auth endpoints:

```elixir
{:ok, %{token: tenant_token, expire: tenant_expire}} =
  FeishuOpenAPI.Auth.tenant_access_token(client)

{:ok, %{token: app_token, expire: app_expire}} =
  FeishuOpenAPI.Auth.app_access_token(client)
```

### Marketplace Apps

Marketplace apps need an `app_ticket` before they can fetch `app_access_token`.

```elixir
client =
  FeishuOpenAPI.new("cli_xxx", "secret_xxx",
    app_type: :marketplace
  )

:ok = FeishuOpenAPI.TokenManager.put_app_ticket(client, "ticket_xxx")

{:ok, %{token: app_token, expire: _}} =
  FeishuOpenAPI.Auth.app_access_token_marketplace(client, "ticket_xxx")

{:ok, %{token: tenant_token, expire: _}} =
  FeishuOpenAPI.Auth.tenant_access_token_marketplace(client, app_token, "tenant_key_xxx")
```

Or let `FeishuOpenAPI.request/4` fetch cached marketplace tokens automatically:

```elixir
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx",
  tenant_key: "tenant_key_xxx"
)
```

Important:

- this library does not automatically persist `app_ticket`
- when you receive the marketplace `app_ticket` event, extract the ticket from the decoded envelope and call `FeishuOpenAPI.TokenManager.put_app_ticket/2`
- if the ticket is missing, marketplace token fetch returns `{:error, %FeishuOpenAPI.Error{code: :app_ticket_missing}}`

For marketplace apps that want the SDK to automatically ask Feishu to resend
an `app_ticket` when none is cached, call `FeishuOpenAPI.TokenManager.bootstrap/1`
once from your application's supervision tree (e.g. in `Application.start/2`):

```elixir
_ = FeishuOpenAPI.TokenManager.bootstrap(client)
```

Or ad-hoc:

```elixir
FeishuOpenAPI.Auth.app_ticket_resend(client)
```

### User Access Token

For OAuth login flows, use the OIDC helpers:

```elixir
{:ok, user_tokens} =
  FeishuOpenAPI.Auth.user_access_token(client, "authorization_code_from_login")

user_tokens.access_token
user_tokens.refresh_token

{:ok, refreshed} =
  FeishuOpenAPI.Auth.refresh_user_access_token(client, user_tokens.refresh_token)
```

These helpers follow the official Node SDK source path:
`authen/v1/oidc/access_token` and `authen/v1/oidc/refresh_access_token`.

The returned map includes:

- `:access_token`
- `:refresh_token`
- `:token_type`
- `:expires_in`
- `:refresh_expires_in`
- `:scope`
- `:raw`

If you want the SDK to keep a user token fresh across requests, store it in
`FeishuOpenAPI.UserTokenManager`:

```elixir
{:ok, _tokens} =
  FeishuOpenAPI.UserTokenManager.init_with_code(
    client,
    "current-user",
    "authorization_code_from_login"
  )

{:ok, resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/me",
    user_access_token_key: "current-user"
  )
```

`FeishuOpenAPI.UserTokenManager` refreshes expired `access_token`s 3 minutes ahead
of their upstream expiry using the stored `refresh_token`.

If you pass `user_access_token: "..."` directly, the SDK treats it as an
explicit bearer token and will not refresh it for you.

## Requests, Uploads, and Downloads

### Request API

`FeishuOpenAPI.request/4` and the HTTP verb helpers accept:

- `:body`
- `:query`
- `:path_params`
- `:headers`
- `:req_options`
- `:form_multipart`
- `:raw`

Examples:

```elixir
FeishuOpenAPI.put(client, "im/v1/chats/:chat_id",
  path_params: %{chat_id: "oc_xxx"},
  body: %{name: "New Name"}
)

FeishuOpenAPI.get(client, "drive/v1/files",
  query: [page_size: 50, page_token: "token_xxx"]
)
```

`FeishuOpenAPI.Pagination` reads `data.page_token` first and falls back to
`data.next_page_token`, matching the official Node SDK generated iterators.

Top-level JSON scalars are supported too:

```elixir
FeishuOpenAPI.post(client, "some/endpoint", body: false)
FeishuOpenAPI.post(client, "some/endpoint", body: nil)
```

### Multipart Upload

Use `FeishuOpenAPI.upload/3` for multipart endpoints:

```elixir
FeishuOpenAPI.upload(client, "im/v1/files",
  fields: [
    file_type: "stream",
    file_name: "report.txt"
  ],
  file: {:path, "/tmp/report.txt"}
)
```

Supported `:file` values:

- `{:path, "/abs/path"}`
- `{:path, "/abs/path", "override.ext"}`
- `{:iodata, content, "name.ext"}`

### Binary Download

Use `FeishuOpenAPI.download/3` for binary responses:

```elixir
{:ok, %{body: bin, filename: filename, status: 200}} =
  FeishuOpenAPI.download(client, "im/v1/files/:file_key",
    path_params: %{file_key: "file_xxx"}
  )
```

## Response and Error Model

Successful envelope responses return:

```elixir
{:ok, %{"code" => 0, "msg" => "success", "data" => data}}
```

If you pass `raw: true`, you get the untouched `%Req.Response{}`:

```elixir
{:ok, %Req.Response{} = resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx", raw: true)
```

Failures return `{:error, %FeishuOpenAPI.Error{}}`.

Important fields:

- `:code` - Feishu business code (integer) when the envelope reported a non-zero `code`, or an SDK-internal atom (`:http_error`, `:transport`, `:rate_limited`, `:bad_path`, `:tenant_key_required`, `:app_ticket_missing`, ...) for transport/client-side failures
- `:http_status`
- `:log_id`
- `:msg`
- `:raw_body`
- `:details` - nested `"error"` payload when Feishu returns one

For numeric `:code` values, `Exception.message/1` appends a pointer to the official [generic error-code reference](https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code) so the log line leads the reader to the right place to look up the meaning.

Example:

```elixir
case FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx") do
  {:ok, resp} ->
    resp["data"]

  {:error, %FeishuOpenAPI.Error{code: code, log_id: log_id} = err} ->
    Logger.error("feishu error code=#{inspect(code)} log_id=#{log_id} err=#{Exception.message(err)}")
end
```

Do not branch on `msg`. Like the official docs, this client treats `code` as the stable failure signal.

## Rate Limiting

Feishu marks rate-limited responses with business code `99991400`, which arrives in three shapes:

- HTTP 429 with body `{"code": 99991400, ...}` (current endpoints)
- HTTP 400 with the same body (legacy endpoints)
- HTTP 200 with the same body (edge case occasionally seen in practice)

All three are detected, retried once after waiting, and — if the retry is also rate-limited — returned as `{:error, %FeishuOpenAPI.Error{code: :rate_limited}}`.

For the wait duration the client prefers the Feishu-specific `x-ogw-ratelimit-reset` header over the standard `Retry-After`, and falls back to ~1s if neither is present. The delay is clamped to 30s.

A `[:feishu_openapi, :request, :rate_limited]` telemetry event fires per retry, with metadata `:method`, `:path`, `:app_id`, `:http_status`, `:source` (`:x_ogw_ratelimit_reset` | `:retry_after` | `:default`), `:limit` (the `x-ogw-ratelimit-limit` value, when present), and `:log_id`. Attach a handler if you want to observe rate-limiting from your app. See [Feishu's 频控策略 docs](https://open.feishu.cn/document/server-docs/api-call-guide/rate-limit) for the per-API limit matrix.

## Webhook Events

`FeishuOpenAPI.Event.Dispatcher` handles:

- plaintext event payloads
- encrypted payloads using `Encrypt Key`
- request signature verification using `x-lark-request-timestamp`, `x-lark-request-nonce`, and `x-lark-signature`
- `Verification Token` checks
- `url_verification` challenge responses

Create a dispatcher:

```elixir
dispatcher =
  FeishuOpenAPI.Event.Dispatcher.new(
    verification_token: "verification_token_xxx",
    encrypt_key: "encrypt_key_xxx"
  )
  |> FeishuOpenAPI.Event.Dispatcher.on("im.message.receive_v1", fn event_type, envelope ->
    IO.inspect({event_type, envelope}, label: "message event")
    :ok
  end)
```

Dispatch raw webhook data yourself:

```elixir
FeishuOpenAPI.Event.Dispatcher.dispatch(dispatcher, {:raw, raw_body, headers})
```

### Optional Plug Adapter

If your app uses `Plug`, `FeishuOpenAPI.Event.Server` can read the HTTP body, verify/decrypt it, and write the JSON response:

```elixir
plug FeishuOpenAPI.Event.Server, dispatcher: dispatcher
```

Return behavior:

- challenge -> `{"challenge": "..."}`
- handler returns a map -> that map becomes the response body
- handler returns `{:ok, _}` -> `{"msg": "success"}`
- handler returns `{:error, _}` or raises -> HTTP 500 so the provider can retry
- handler returns anything else -> `{"msg": "success"}`

For real interactive-card HTTP callbacks, use `FeishuOpenAPI.CardAction.Handler`
instead of `Event.Dispatcher.on_callback/3`. Card callbacks use a different
signature algorithm from event-subscription webhooks.

## Interactive Card Callbacks

`FeishuOpenAPI.CardAction.Handler` matches the Go SDK's card-action flow:

- optional body decryption with `Encrypt Key`
- `url_verification` challenge handling
- SHA1 verification using `x-lark-request-timestamp`, `x-lark-request-nonce`,
  `x-lark-signature`, and `Verification Token`

```elixir
card_handler =
  FeishuOpenAPI.CardAction.Handler.new(
    verification_token: "verification_token_xxx",
    encrypt_key: "encrypt_key_xxx",
    handler: fn action ->
      IO.inspect(action, label: "card action")

      %{
        toast: %{
          type: "success",
          content: "handled"
        }
      }
    end
  )

FeishuOpenAPI.CardAction.Handler.dispatch(card_handler, {:raw, raw_body, headers})
```

If your app uses `Plug`, you can mount the optional adapter:

```elixir
plug FeishuOpenAPI.CardAction.Server, handler: card_handler
```

## WebSocket Event Push

`FeishuOpenAPI.WS.Client` opens the Feishu/Lark WS event-push connection and forwards decoded event payloads into the same dispatcher model.
The WS connection is authenticated during setup, so pushed event frames are
dispatched as trusted decoded events and do not require webhook
`Verification Token` or `Encrypt Key` handling.

```elixir
{:ok, _pid} =
  FeishuOpenAPI.WS.Client.start_link(
    client: client,
    dispatcher: dispatcher,
    auto_reconnect: true
  )
```

Behavior:

- fetches the WS endpoint from `/callback/ws/endpoint`
- applies server-provided ping and reconnect settings
- reassembles fragmented frames
- dispatches decoded `event` and `card` payloads
- reconnects automatically for non-fatal connection failures

## Notes and Limits

- This is a generic client, not a generated API surface.
- Marketplace `app_ticket` persistence is manual by design.
- Event verification relies on the raw HTTP body. If you build your own adapter, verify signatures before mutating the request body.

## Manual Business E2E

The repository includes a manual development-only script that exercises the basic business flows end-to-end against the real Feishu API, including:

- WS subscription for `im.message.receive_v1`, `im.message.recalled_v1`,
  `im.message.reaction.created_v1`, and `im.message.reaction.deleted_v1`
- REST lookups for user / message / chat
- message-resource download
- create / reply / patch / delete message flows
- CardKit create / content update / settings update

It is intentionally not wired into `mix test`, because it talks to the real
Feishu API and has side effects.

Create `.env.local` in the repo root with at least:

```dotenv
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx
```

Then run:

```bash
mix run scripts/feishu_business_e2e.exs
```

Default manual trigger behavior:

- any received `im.message.receive_v1` event runs the full flow
- non-user senders are skipped to avoid callback loops from app-generated messages
- send an image or file message to exercise resource download
- add/remove a reaction or recall a message to observe the WS subscription side

## Running Tests

```bash
mix test
```
