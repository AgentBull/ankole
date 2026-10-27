# FeishuOpenAPI

English | [简体中文](README.zh-Hans.md)

`FeishuOpenAPI` is a lightweight Elixir client for Feishu and Lark OpenAPI calls and event push:

- Pass raw API paths such as `"contact/v3/users/:user_id"` directly; relative paths automatically receive the `/open-apis/` prefix, while absolute paths starting with `/` pass through unchanged.
- Request and response payloads remain weakly typed maps, so you can call new endpoints without waiting for generated wrappers.
- Built-in managers and adapters handle token fetching and caching, response-envelope decoding, webhook decryption and signature verification, and WebSocket event push.

## Features

- Generic HTTP client for both Feishu (`open.feishu.cn`) and Lark (`open.larksuite.com`)
- Automatic fetching and caching of `tenant_access_token` and `app_access_token`
- Auth helpers for self-built apps, marketplace apps, and OIDC `user_access_token` flows
- Managed OIDC `user_access_token` storage with automatic refresh-token rotation
- Weakly typed request building with `body`, `query`, `path_params`, and custom headers
- Multipart upload and binary download helpers
- Webhook payload decryption and request signature verification, plus an optional `Plug` adapter
- WebSocket event-push client

## Build and Test

`FeishuOpenAPI` lives inside the Lark Plugin under `plugins/lark_adapter` and compiles as part of the `app/control_plane` Mix project. Run `bun run lark-adapter:test` from the repository root.

## Quick Start

Create a client:

```elixir
client =
  FeishuOpenAPI.new("cli_xxx", "secret_xxx",
    domain: :feishu,
    app_type: :self_built
  )
```

Call an endpoint using the default cached `tenant_access_token`:

```elixir
{:ok, resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
    path_params: %{user_id: "ou_xxx"},
    query: [user_id_type: "user_id"]
  )

resp["code"] == 0
resp["data"]
```

Send a `POST` request:

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

Rather than shipping generated modules per endpoint, `FeishuOpenAPI` calls Feishu and Lark routes directly by path through `get/3`, `post/3`, `put/3`, `patch/3`, and `delete/3`. Bang variants such as `get!/3` unwrap the response map on success or raise `FeishuOpenAPI.Error` on failure.

Supported client options:

- `:domain` - `:feishu` or `:lark`
- `:base_url` - overrides the `:domain` base URL completely
- `:app_type` - `:self_built` or `:marketplace`
- `:headers` - headers appended to every request
- `:req_options` - low-level options forwarded to `Req`

Examples:

```elixir
FeishuOpenAPI.new("cli_xxx", "secret_xxx", domain: :lark)

FeishuOpenAPI.new("cli_xxx", "secret_xxx",
  base_url: "https://open.feishu.cn",
  headers: [{"x-custom-header", "1"}]
)
```

Each request path can take one of three forms:

- a shorthand relative path such as `"im/v1/chats"`, which automatically receives the `/open-apis/` prefix
- an absolute path such as `"/open-apis/im/v1/chats"`, used verbatim (including non-`/open-apis/` routes such as `"/callback/ws/endpoint"`)
- a full URL such as `"https://open.feishu.cn/open-apis/im/v1/chats"`

`path_params` accepts either a map or a keyword list.

## Auth and Token Selection

By default, every request attaches a cached `tenant_access_token`. You can override authentication per request with these options:

- `access_token_type: :tenant_access_token` - default behavior
- `access_token_type: :app_access_token` - attach an `app_access_token`
- `access_token_type: :user_access_token` - pair with `user_access_token:` or `user_access_token_key:`
- `access_token_type: nil` - omit the `Authorization` header
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

`FeishuOpenAPI.TokenManager` caches app and tenant tokens and refreshes them 3 minutes before their upstream expiry.

### Self-Built Apps

The built-in auth helpers call the standard Feishu token endpoints directly:

```elixir
{:ok, %{token: tenant_token, expire: tenant_expire}} =
  FeishuOpenAPI.Auth.tenant_access_token(client)

{:ok, %{token: app_token, expire: app_expire}} =
  FeishuOpenAPI.Auth.app_access_token(client)
```

### Marketplace Apps

Marketplace apps require an `app_ticket` before they can request an `app_access_token`:

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

Once the ticket is cached, `FeishuOpenAPI.request/4` can fetch and cache marketplace tenant tokens automatically when given `:tenant_key`:

```elixir
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx",
  tenant_key: "tenant_key_xxx"
)
```

Keep in mind:

- `FeishuOpenAPI` does not persist `app_ticket` across restarts.
- When your webhook or WS handler receives a marketplace `app_ticket` event, extract the ticket from the decoded envelope and store it via `FeishuOpenAPI.TokenManager.put_app_ticket/2`.
- If no ticket is cached, marketplace token fetches return `{:error, %FeishuOpenAPI.Error{code: :app_ticket_missing}}`.

To have the client ask Feishu to resend an `app_ticket` whenever none is cached at startup, call `FeishuOpenAPI.TokenManager.bootstrap/1` from your supervision setup (such as `Application.start/2`):

```elixir
_ = FeishuOpenAPI.TokenManager.bootstrap(client)
```

You can also request a resend manually at any time:

```elixir
FeishuOpenAPI.Auth.app_ticket_resend(client)
```

### User Access Token

For OAuth user login flows, use the OIDC token helpers:

```elixir
{:ok, user_tokens} =
  FeishuOpenAPI.Auth.user_access_token(client, "authorization_code_from_login")

user_tokens.access_token
user_tokens.refresh_token

{:ok, refreshed} =
  FeishuOpenAPI.Auth.refresh_user_access_token(client, user_tokens.refresh_token)
```

Matching the official Node SDK, these helpers call `authen/v1/oidc/access_token` and `authen/v1/oidc/refresh_access_token` and return a map with:

- `:access_token`
- `:refresh_token`
- `:token_type`
- `:expires_in`
- `:refresh_expires_in`
- `:scope`
- `:raw`

To keep a user token fresh across requests automatically, register it in `FeishuOpenAPI.UserTokenManager`:

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

`FeishuOpenAPI.UserTokenManager` refreshes `access_token` values 3 minutes before upstream expiry using the stored `refresh_token`. By contrast, passing `user_access_token: "..."` directly sends that literal bearer token without automatic refresh.

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

For cursor pagination, `FeishuOpenAPI.Pagination` checks `data.page_token` first and falls back to `data.next_page_token`, matching the iterators in the official Node SDK.

Top-level JSON scalars are also supported as request bodies:

```elixir
FeishuOpenAPI.post(client, "some/endpoint", body: false)
FeishuOpenAPI.post(client, "some/endpoint", body: nil)
```

### Multipart Upload

Use `FeishuOpenAPI.upload/3` for multipart file uploads:

```elixir
FeishuOpenAPI.upload(client, "im/v1/files",
  fields: [
    file_type: "stream",
    file_name: "report.txt"
  ],
  file: {:path, "/tmp/report.txt"}
)
```

Supported `:file` tuples:

- `{:path, "/abs/path"}`
- `{:path, "/abs/path", "override.ext"}`
- `{:iodata, content, "name.ext"}`

### Binary Download

Use `FeishuOpenAPI.download/3` for endpoints that return raw binary payloads:

```elixir
{:ok, %{body: bin, filename: filename, status: 200}} =
  FeishuOpenAPI.download(client, "im/v1/files/:file_key",
    path_params: %{file_key: "file_xxx"}
  )
```

## Response and Error Model

When an endpoint returns a standard JSON envelope with `"code" => 0`, the client returns:

```elixir
{:ok, %{"code" => 0, "msg" => "success", "data" => data}}
```

Pass `raw: true` to receive the underlying `%Req.Response{}` directly:

```elixir
{:ok, %Req.Response{} = resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx", raw: true)
```

On failure, the client returns `{:error, %FeishuOpenAPI.Error{}}` with these key fields:

- `:code` - Feishu's integer business error code when the response envelope carries a non-zero `code`, or a client atom (`:http_error`, `:transport`, `:rate_limited`, `:bad_path`, `:tenant_key_required`, `:app_ticket_missing`, …) for transport or client-side errors
- `:http_status`
- `:log_id`
- `:msg`
- `:raw_body`
- `:details` - nested `"error"` payload when Feishu includes one

When `:code` is numeric, `Exception.message/1` appends a link to Feishu's [generic error-code reference](https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code) so operators can look up the code directly from logs.

Example:

```elixir
case FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx") do
  {:ok, resp} ->
    resp["data"]

  {:error, %FeishuOpenAPI.Error{code: code, log_id: log_id} = err} ->
    Logger.error("feishu error code=#{inspect(code)} log_id=#{log_id} err=#{Exception.message(err)}")
end
```

Always branch on `:code` rather than `:msg`: matching Feishu's own guidance, `:code` is the stable programmatic error identifier.

## Rate Limiting

Feishu signals rate limiting with business code `99991400`, which can arrive in three HTTP shapes:

- HTTP 429 with `{"code": 99991400, ...}` (current endpoints)
- HTTP 400 with the same body (legacy endpoints)
- HTTP 200 with the same body (occasional edge case in production)

The client detects all three forms, waits, and retries the request once; if the retry is rate-limited again, it returns `{:error, %FeishuOpenAPI.Error{code: :rate_limited}}`.

To choose the backoff delay, the client checks Feishu's `x-ogw-ratelimit-reset` header first, falls back to standard `Retry-After`, and uses ~1 second when neither header is present, clamping the wait to at most 30 seconds.

Each retry emits a `[:feishu_openapi, :request, :rate_limited]` telemetry event with metadata `:method`, `:path`, `:app_id`, `:http_status`, `:source` (`:x_ogw_ratelimit_reset` | `:retry_after` | `:default`), `:limit` (from `x-ogw-ratelimit-limit` when present), and `:log_id`. See [Feishu's rate-limit documentation](https://open.feishu.cn/document/server-docs/api-call-guide/rate-limit) for per-endpoint quotas.

## Webhook Events

`FeishuOpenAPI.Event.Dispatcher` handles:

- plaintext event payloads
- encrypted payloads protected with `Encrypt Key`
- request signature verification via `x-lark-request-timestamp`, `x-lark-request-nonce`, and `x-lark-signature`
- `Verification Token` checks
- `url_verification` challenge handshakes

Build a dispatcher and register event handlers:

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

To dispatch a raw HTTP webhook payload directly:

```elixir
FeishuOpenAPI.Event.Dispatcher.dispatch(dispatcher, {:raw, raw_body, headers})
```

### Optional Plug Adapter

In a `Plug` pipeline, `FeishuOpenAPI.Event.Server` reads the raw request body, verifies and decrypts it, and writes the JSON response:

```elixir
plug FeishuOpenAPI.Event.Server, dispatcher: dispatcher
```

Response mapping:

- `url_verification` challenge -> `{"challenge": "..."}`
- handler returns a map -> serialized directly as the JSON response body
- handler returns `{:ok, _}` -> `{"msg": "success"}`
- handler returns `{:error, _}` or raises -> HTTP 500 so Feishu retries delivery
- handler returns any other value -> `{"msg": "success"}`

For HTTP interactive-card callbacks, use `FeishuOpenAPI.CardAction.Handler` rather than `Event.Dispatcher.on_callback/3`, because card callbacks use a different signature scheme from event-subscription webhooks.

## Interactive Card Callbacks

Matching Feishu's official Go SDK, `FeishuOpenAPI.CardAction.Handler` supports:

- optional payload decryption with `Encrypt Key`
- `url_verification` challenge responses
- SHA-1 signature verification across `x-lark-request-timestamp`, `x-lark-request-nonce`, `x-lark-signature`, and `Verification Token`

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

In a `Plug` router, mount the companion server plug:

```elixir
plug FeishuOpenAPI.CardAction.Server, handler: card_handler
```

## WebSocket Event Push

`FeishuOpenAPI.WS.Client` maintains a Feishu/Lark WebSocket event-push connection and feeds decoded events into the same `Dispatcher`. Because the WebSocket connection authenticates during establishment, incoming frames are dispatched directly as trusted decoded events without webhook `Verification Token` or `Encrypt Key` checks.

```elixir
{:ok, _pid} =
  FeishuOpenAPI.WS.Client.start_link(
    client: client,
    dispatcher: dispatcher,
    auto_reconnect: true
  )
```

At runtime, `WS.Client`:

- fetches a fresh WebSocket endpoint from `/callback/ws/endpoint`
- honors server-supplied ping intervals and reconnect delays
- reassembles fragmented binary frames
- dispatches decoded `event` and `card` payloads
- reconnects automatically after transient connection failures

## Notes and Limits

- Endpoints are invoked by path rather than generated wrapper modules.
- Marketplace `app_ticket` storage is left to the caller by design.
- Webhook signature verification requires the exact raw HTTP body; if you write a custom HTTP adapter, verify the signature before parsing or mutating the body.

## Manual Business E2E

For local development, `plugins/lark_adapter/scripts/feishu_business_e2e.exs` exercises core workflows end to end against the live Feishu API:

- WebSocket subscriptions for `im.message.receive_v1`, `im.message.recalled_v1`, `im.message.reaction.created_v1`, and `im.message.reaction.deleted_v1`
- REST lookups for users, messages, and chats
- message-resource binary downloads
- message creation, reply, patch, and deletion
- CardKit creation, streaming content updates, and settings updates

Because this script calls the live Feishu API and mutates real chat state, it is excluded from `mix test`.

To run it, create `.env.local` in the repository root:

```dotenv
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx
```

Then start the script from the repository root:

```bash
elixir plugins/lark_adapter/scripts/feishu_business_e2e.exs
```

Once connected:

- sending any user message triggers `im.message.receive_v1` and runs the end-to-end sequence (non-user senders are ignored to prevent bot reply loops)
- sending an image or file attachment exercises resource downloads
- adding or removing a reaction, or recalling a message, exercises the corresponding WebSocket event handlers

## Running Tests

```bash
bun run lark-adapter:test
```
