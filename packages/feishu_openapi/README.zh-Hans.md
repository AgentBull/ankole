# FeishuOpenAPI

[English](README.md) | 简体中文

`FeishuOpenAPI` 是一个轻量的 Elixir 客户端，用于调用 飞书/Lark OpenAPI 和处理事件推送。

- 你可以直接传入原始 API 路径，例如 `"contact/v3/users/:user_id"`（会自动补上 `/open-apis/` 前缀；如果路径以 `/` 开头则原样透传）
- 请求和响应负载保持弱类型，不强制生成端点包装层
- 客户端负责 token 获取与缓存、响应信封解码、Webhook 加解密，以及 WS 事件推送接线

如果你想要一个小而通用的客户端，能够直接调用任意 飞书/Lark 接口，而不必等待生成式 wrapper，这个库会比较合适。

## 功能特性

- 通用的 飞书 / Lark HTTP 客户端
- 自动获取并缓存 `tenant_access_token` / `app_access_token`
- 为自建应用、商店应用和 OIDC `user_access_token` 提供辅助方法
- 托管式 OIDC `user_access_token` 存储，并基于 refresh token 自动刷新
- 弱类型请求构建，支持 `body`、`query`、`path_params` 和自定义 headers
- Multipart 上传与二进制下载辅助方法
- Webhook 解密与签名校验
- 可选的 `Plug` Webhook 适配器
- WebSocket 事件推送客户端

## 安装

把依赖加入 `mix.exs`：

```elixir
def deps do
  [
    {:feishu_openapi, "~> 0.1.0"}
  ]
end
```

如果你要使用 `FeishuOpenAPI.Event.Server` 或 `FeishuOpenAPI.CardAction.Server`，
还需要在你的应用里额外加入 `:plug`：

```elixir
def deps do
  [
    {:feishu_openapi, "~> 0.1.0"},
    {:plug, "~> 1.16"}
  ]
end
```

## 快速开始

创建一个 client：

```elixir
client =
  FeishuOpenAPI.new("cli_xxx", "secret_xxx",
    domain: :feishu,
    app_type: :self_built
  )
```

使用默认的 `tenant_access_token` 调一个 API：

```elixir
{:ok, resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
    path_params: %{user_id: "ou_xxx"},
    query: [user_id_type: "user_id"]
  )

resp["code"] == 0
resp["data"]
```

发送一个 POST 请求：

```elixir
{:ok, resp} =
  FeishuOpenAPI.post(client, "im/v1/messages",
    query: [receive_id_type: "user_id"],
    body: %{
      receive_id: "ou_xxx",
      msg_type: "text",
      content: Jason.encode!(%{text: "Hello World"})
    }
  )
```

## Client 模型

`FeishuOpenAPI` 不会生成端点模块。你直接按路径调用 Feishu/Lark API。

HTTP 动词辅助方法包括 `get/3`、`post/3`、`put/3`、`patch/3` 和 `delete/3`。
对应的 bang 版本（例如 `get!/3`）会在成功时返回响应，失败时抛出 `FeishuOpenAPI.Error`。

支持的 client 选项：

- `:domain` - `:feishu` 或 `:lark`
- `:base_url` - 完整覆盖默认域名
- `:app_type` - `:self_built` 或 `:marketplace`
- `:headers` - 追加到每个请求上的 headers
- `:req_options` - 底层 `Req` 选项

示例：

```elixir
FeishuOpenAPI.new("cli_xxx", "secret_xxx", domain: :lark)

FeishuOpenAPI.new("cli_xxx", "secret_xxx",
  base_url: "https://open.feishu.cn",
  headers: [{"x-custom-header", "1"}]
)
```

请求路径可以是：

- 类似 `"im/v1/chats"` 这样的相对简写路径（自动补上 `/open-apis/`）
- 类似 `"/open-apis/im/v1/chats"` 这样的绝对路径（原样使用；也适用于 `"/callback/ws/endpoint"` 这类非 `/open-apis/` 路径）
- 完整 URL，例如 `"https://open.feishu.cn/open-apis/im/v1/chats"`

`path_params` 可以传 map，也可以传 keyword list。

## 认证与 Token 选择

默认情况下，每个请求都会使用已缓存的 `tenant_access_token`。

你可以在单次请求上覆盖这个行为：

- `access_token_type: :tenant_access_token` - 默认行为
- `access_token_type: :app_access_token` - 使用 `app_access_token`
- `access_token_type: :user_access_token` - 配合 `user_access_token:` 或 `user_access_token_key:`
- `access_token_type: nil` - 不附带 `Authorization`
- `user_access_token: token` - 直接发送 `Authorization: Bearer <token>`（隐含 `:user_access_token`）
- `user_access_token_key: key` - 从 `FeishuOpenAPI.UserTokenManager` 加载托管的 `user_access_token`（隐含 `:user_access_token`）

示例：

```elixir
# 默认 tenant token
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx")

# app token
FeishuOpenAPI.get(client, "some/app-token-only/api", access_token_type: :app_access_token)

# 显式 user token
FeishuOpenAPI.get(client, "contact/v3/users/me",
  user_access_token: "eyJhbGciOi..."
)

# 托管 user token，支持自动刷新
FeishuOpenAPI.get(client, "contact/v3/users/me",
  user_access_token_key: "current-user"
)

# 不带认证头
FeishuOpenAPI.post(client, "auth/v3/tenant_access_token/internal",
  access_token_type: nil,
  body: %{app_id: "cli_xxx", app_secret: "secret_xxx"}
)
```

Token 会缓存在 `FeishuOpenAPI.TokenManager` 中，并在上游过期前 3 分钟刷新。

### 自建应用

内置认证辅助方法对应官方认证接口：

```elixir
{:ok, %{token: tenant_token, expire: tenant_expire}} =
  FeishuOpenAPI.Auth.tenant_access_token(client)

{:ok, %{token: app_token, expire: app_expire}} =
  FeishuOpenAPI.Auth.app_access_token(client)
```

### 商店应用

商店应用在获取 `app_access_token` 之前，需要先有 `app_ticket`。

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

也可以让 `FeishuOpenAPI.request/4` 自动拉取并使用已缓存的商店应用 token：

```elixir
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx",
  tenant_key: "tenant_key_xxx"
)
```

注意：

- 这个库不会自动持久化 `app_ticket`
- 当你收到商店应用的 `app_ticket` 事件后，需要从解码后的 envelope 中取出 ticket，并调用 `FeishuOpenAPI.TokenManager.put_app_ticket/2`
- 如果缺少 ticket，商店应用 token 获取会返回 `{:error, %FeishuOpenAPI.Error{code: :app_ticket_missing}}`

如果你希望在商店应用场景下，当本地没有缓存 `app_ticket` 时由 SDK 自动请求飞书重发一次，可在应用监督树中调用一次 `FeishuOpenAPI.TokenManager.bootstrap/1`（例如放在 `Application.start/2` 里）：

```elixir
_ = FeishuOpenAPI.TokenManager.bootstrap(client)
```

也可以按需单独调用：

```elixir
FeishuOpenAPI.Auth.app_ticket_resend(client)
```

### User Access Token

对于 OAuth 登录流程，可使用 OIDC 辅助方法：

```elixir
{:ok, user_tokens} =
  FeishuOpenAPI.Auth.user_access_token(client, "authorization_code_from_login")

user_tokens.access_token
user_tokens.refresh_token

{:ok, refreshed} =
  FeishuOpenAPI.Auth.refresh_user_access_token(client, user_tokens.refresh_token)
```

返回的 map 包含：

- `:access_token`
- `:refresh_token`
- `:token_type`
- `:expires_in`
- `:refresh_expires_in`
- `:scope`
- `:raw`

如果你希望 SDK 在多次请求之间自动维护 user token 的新鲜度，可以把它存进 `FeishuOpenAPI.UserTokenManager`：

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

`FeishuOpenAPI.UserTokenManager` 会用已存储的 `refresh_token`，在上游过期前 3 分钟自动刷新过期的 `access_token`。

如果你直接传 `user_access_token: "..."`，SDK 会把它当成显式 bearer token 使用，不会帮你自动刷新。

## 请求、上传与下载

### Request API

`FeishuOpenAPI.request/4` 及各个 HTTP 动词辅助方法支持：

- `:body`
- `:query`
- `:path_params`
- `:headers`
- `:req_options`
- `:form_multipart`
- `:raw`

示例：

```elixir
FeishuOpenAPI.put(client, "im/v1/chats/:chat_id",
  path_params: %{chat_id: "oc_xxx"},
  body: %{name: "New Name"}
)

FeishuOpenAPI.get(client, "drive/v1/files",
  query: [page_size: 50, page_token: "token_xxx"]
)
```

也支持顶层 JSON 标量：

```elixir
FeishuOpenAPI.post(client, "some/endpoint", body: false)
FeishuOpenAPI.post(client, "some/endpoint", body: nil)
```

### Multipart 上传

对 multipart 接口，使用 `FeishuOpenAPI.upload/3`：

```elixir
FeishuOpenAPI.upload(client, "im/v1/files",
  fields: [
    file_type: "stream",
    file_name: "report.txt"
  ],
  file: {:path, "/tmp/report.txt"}
)
```

支持的 `:file` 取值：

- `{:path, "/abs/path"}`
- `{:path, "/abs/path", "override.ext"}`
- `{:iodata, content, "name.ext"}`

### 二进制下载

对二进制响应，使用 `FeishuOpenAPI.download/3`：

```elixir
{:ok, %{body: bin, filename: filename, status: 200}} =
  FeishuOpenAPI.download(client, "im/v1/files/:file_key",
    path_params: %{file_key: "file_xxx"}
  )
```

## 响应与错误模型

成功的信封式响应会返回：

```elixir
{:ok, %{"code" => 0, "msg" => "success", "data" => data}}
```

如果传 `raw: true`，则会拿到原始的 `%Req.Response{}`：

```elixir
{:ok, %Req.Response{} = resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx", raw: true)
```

失败时返回 `{:error, %FeishuOpenAPI.Error{}}`。

重要字段：

- `:code` - 当响应 envelope 的 `code` 非 0 时，这里是 Feishu 业务错误码（整数）；当是传输层或客户端侧失败时，这里是 SDK 内部 atom（例如 `:http_error`、`:transport`、`:rate_limited`、`:bad_path`、`:tenant_key_required`、`:app_ticket_missing` 等）
- `:http_status`
- `:log_id`
- `:msg`
- `:raw_body`
- `:details` - 当 Feishu 返回嵌套 `"error"` 负载时，对应这里

对于数值型 `:code`，`Exception.message/1` 会追加一个指向官方 [通用错误码文档](https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code) 的提示，这样日志读者可以直接顺着链接去查具体含义。

示例：

```elixir
case FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx") do
  {:ok, resp} ->
    resp["data"]

  {:error, %FeishuOpenAPI.Error{code: code, log_id: log_id} = err} ->
    Logger.error("feishu error code=#{inspect(code)} log_id=#{log_id} err=#{Exception.message(err)}")
end
```

不要基于 `msg` 分支判断。和官方文档一样，这个客户端把 `code` 视为稳定的失败信号。

## 限流处理

Feishu 用业务码 `99991400` 表示限流，这个返回在实践中会以三种形态出现：

- HTTP 429，body 为 `{"code": 99991400, ...}`（当前主流接口）
- HTTP 400，body 相同（历史接口）
- HTTP 200，body 相同（实践中偶尔出现的边界情况）

三种情况都会被识别；客户端会等待后自动重试一次。如果重试后仍然限流，则返回 `{:error, %FeishuOpenAPI.Error{code: :rate_limited}}`。

等待时长优先使用 Feishu 专用的 `x-ogw-ratelimit-reset` header，而不是标准 `Retry-After`；如果两者都没有，则回退到约 1 秒。最终延迟会被限制在 30 秒以内。

每次重试都会发出一个 `[:feishu_openapi, :request, :rate_limited]` telemetry 事件，metadata 包含 `:method`、`:path`、`:app_id`、`:http_status`、`:source`（`:x_ogw_ratelimit_reset` | `:retry_after` | `:default`）、`:limit`（若有 `x-ogw-ratelimit-limit` 则带上）和 `:log_id`。如果你想在应用层观测限流，可自行挂 handler。各 API 的限流配额请参考 [Feishu 的频控策略文档](https://open.feishu.cn/document/server-docs/api-call-guide/rate-limit)。

## Webhook 事件

`FeishuOpenAPI.Event.Dispatcher` 负责处理：

- 明文事件负载
- 使用 `Encrypt Key` 的加密负载
- 基于 `x-lark-request-timestamp`、`x-lark-request-nonce` 和 `x-lark-signature` 的请求签名校验
- `Verification Token` 校验
- `url_verification` challenge 响应

创建一个 dispatcher：

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

也可以自己分发原始 webhook 数据：

```elixir
FeishuOpenAPI.Event.Dispatcher.dispatch(dispatcher, {:raw, raw_body, headers})
```

### 可选的 Plug 适配器

如果你的应用使用 `Plug`，`FeishuOpenAPI.Event.Server` 可以负责读取 HTTP body、校验/解密，并写回 JSON 响应：

```elixir
plug FeishuOpenAPI.Event.Server, dispatcher: dispatcher
```

返回行为：

- challenge -> `{"challenge": "..."}`
- handler 返回 map -> 该 map 会成为响应 body
- handler 返回 `{:ok, _}` -> `{"msg": "success"}`
- handler 返回 `{:error, _}` 或抛出异常 -> HTTP 500，让 provider 可以重试
- handler 返回其他任意值 -> `{"msg": "success"}`

对于真实的交互卡片 HTTP 回调，请使用 `FeishuOpenAPI.CardAction.Handler`，而不是 `Event.Dispatcher.on_callback/3`。卡片回调使用的签名算法与事件订阅 webhook 不同。

## 交互卡片回调

`FeishuOpenAPI.CardAction.Handler` 与 Go SDK 的 card-action 流程保持一致：

- 可选的 `Encrypt Key` 解密
- `url_verification` challenge 处理
- 基于 `x-lark-request-timestamp`、`x-lark-request-nonce`、`x-lark-signature` 和 `Verification Token` 的 SHA1 校验

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

如果你的应用使用 `Plug`，也可以挂载可选适配器：

```elixir
plug FeishuOpenAPI.CardAction.Server, handler: card_handler
```

## WebSocket 事件推送

`FeishuOpenAPI.WS.Client` 会建立 Feishu/Lark 的 WS 事件推送连接，并把解码后的事件负载转发到同一套 dispatcher 模型中。
WS 连接在建立时已经完成鉴权，因此推送过来的事件 frame 会按可信 decoded
事件分发，不需要 webhook 的 `Verification Token` 或 `Encrypt Key` 处理。

```elixir
{:ok, _pid} =
  FeishuOpenAPI.WS.Client.start_link(
    client: client,
    dispatcher: dispatcher,
    auto_reconnect: true
  )
```

行为包括：

- 从 `/callback/ws/endpoint` 获取 WS endpoint
- 应用服务端下发的 ping 和重连配置
- 重组被分片的 frame
- 分发解码后的 `event` 和 `card` 负载
- 对非致命连接失败进行自动重连

## 说明与限制

- 这是一个通用客户端，不是生成式 API surface。
- 商店应用的 `app_ticket` 持久化是有意保留给业务方自行处理的。
- 事件验签依赖原始 HTTP body。如果你自己实现适配器，请在修改请求体之前完成签名校验。

## 手工业务 E2E

仓库里带了一个仅用于开发阶段的手工脚本，会真实调用 Feishu API，跑一遍基础业务链路，包括：

- 订阅 `im.message.receive_v1`、`im.message.recalled_v1`、`im.message.reaction.created_v1` 和 `im.message.reaction.deleted_v1` 这几个 WS 事件
- 用户 / 消息 / 群聊的 REST 查询
- 消息资源下载
- 创建 / 回复 / 修改 / 删除消息流程
- CardKit 创建 / 内容更新 / 设置更新

它不会接入 `mix test`，因为它会访问真实 Feishu API，并且带有副作用。

在仓库根目录创建 `.env.local`，至少填入：

```dotenv
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx
```

然后运行：

```bash
mix run scripts/feishu_business_e2e.exs
```

默认的手工触发行为：

- 收到任意 `im.message.receive_v1` 事件后，会跑完整流程
- 会跳过非用户发送者，避免应用自己发出的消息触发回调环路
- 发送图片或文件消息，可以覆盖资源下载链路
- 添加 / 删除 reaction，或撤回消息，可以观察 WS 订阅侧效果

## 运行测试

```bash
mix test
```
