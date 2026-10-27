# FeishuOpenAPI

[English](README.md) | 简体中文

`FeishuOpenAPI` 是用于调用飞书与 Lark OpenAPI 及处理事件推送的轻量 Elixir 客户端：

- 直接传入原始接口路径，例如 `"contact/v3/users/:user_id"`（相对路径会自动补齐 `/open-apis/` 前缀；以 `/` 开头的绝对路径则原样透传）。
- 请求体与响应体保持弱类型映射，无需等待代码生成即可直接调用任意新接口。
- 内置令牌获取与缓存、响应信封解码、Webhook 加解密与验签，以及 WebSocket 事件推送长连接。

## 功能特性

- 通用的飞书 / Lark HTTP 客户端
- 自动获取并缓存 `tenant_access_token` 与 `app_access_token`
- 提供企业自建应用、应用商店应用及 OIDC `user_access_token` 认证辅助函数
- 托管 OIDC `user_access_token`，支持使用刷新令牌自动续期
- 支持通过 `body`、`query`、`path_params` 与自定义请求头构建弱类型请求
- 提供分块表单（Multipart）上传与二进制下载辅助函数
- 支持 Webhook 报文解密、签名校验，以及可选的 `Plug` 适配器
- 内置 WebSocket 事件推送长连接客户端

## 构建与测试

`FeishuOpenAPI` 位于 `plugins/lark_adapter` 插件目录中，随 `app/control_plane` Mix 项目一同编译。在仓库根目录运行 `bun run lark-adapter:test` 即可执行测试。

## 快速开始

创建客户端：

```elixir
client =
  FeishuOpenAPI.new("cli_xxx", "secret_xxx",
    domain: :feishu,
    app_type: :self_built
  )
```

使用默认缓存的 `tenant_access_token` 调用接口：

```elixir
{:ok, resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/:user_id",
    path_params: %{user_id: "ou_xxx"},
    query: [user_id_type: "user_id"]
  )

resp["code"] == 0
resp["data"]
```

发送 POST 请求：

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

## 客户端模型

`FeishuOpenAPI` 不生成按接口拆分的包装模块，而是直接按路径调用飞书或 Lark 接口。HTTP 动词辅助函数包括 `get/3`、`post/3`、`put/3`、`patch/3` 和 `delete/3`；带叹号的同名版本（如 `get!/3`）在成功时直接返回响应映射，失败时抛出 `FeishuOpenAPI.Error`。

支持的客户端配置项：

- `:domain` - `:feishu` 或 `:lark`
- `:base_url` - 显式指定基础 URL，覆盖默认域名
- `:app_type` - `:self_built`（自建应用）或 `:marketplace`（商店应用）
- `:headers` - 追加到每次请求的自定义请求头
- `:req_options` - 透传给底层 `Req` 的配置项

示例：

```elixir
FeishuOpenAPI.new("cli_xxx", "secret_xxx", domain: :lark)

FeishuOpenAPI.new("cli_xxx", "secret_xxx",
  base_url: "https://open.feishu.cn",
  headers: [{"x-custom-header", "1"}]
)
```

请求路径支持以下三种写法：

- 相对简写路径，如 `"im/v1/chats"`（自动补齐 `/open-apis/` 前缀）
- 绝对路径，如 `"/open-apis/im/v1/chats"`（原样请求，同样适用于 `"/callback/ws/endpoint"` 等非 `/open-apis/` 路径）
- 完整 URL，如 `"https://open.feishu.cn/open-apis/im/v1/chats"`

`path_params` 既支持映射（map），也支持关键字列表（keyword list）。

## 认证与令牌选择

默认情况下，每次请求都会携带已缓存的 `tenant_access_token`。如需在单次请求中切换认证方式，可传入以下选项：

- `access_token_type: :tenant_access_token` - 默认行为
- `access_token_type: :app_access_token` - 改用 `app_access_token`
- `access_token_type: :user_access_token` - 配合 `user_access_token:` 或 `user_access_token_key:` 使用
- `access_token_type: nil` - 不附带 `Authorization` 请求头
- `user_access_token: token` - 直接发送 `Authorization: Bearer <token>`（隐含 `:user_access_token`）
- `user_access_token_key: key` - 从 `FeishuOpenAPI.UserTokenManager` 读取托管的 `user_access_token`（隐含 `:user_access_token`）

示例：

```elixir
# 默认租户令牌
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx")

# 应用令牌
FeishuOpenAPI.get(client, "some/app-token-only/api", access_token_type: :app_access_token)

# 显式传入用户令牌
FeishuOpenAPI.get(client, "contact/v3/users/me",
  user_access_token: "eyJhbGciOi..."
)

# 托管用户令牌（自动续期）
FeishuOpenAPI.get(client, "contact/v3/users/me",
  user_access_token_key: "current-user"
)

# 不带认证请求头
FeishuOpenAPI.post(client, "auth/v3/tenant_access_token/internal",
  access_token_type: nil,
  body: %{app_id: "cli_xxx", app_secret: "secret_xxx"}
)
```

应用与租户令牌缓存在 `FeishuOpenAPI.TokenManager` 中，并在上游过期时间前 3 分钟自动刷新。

### 自建应用

内置认证辅助函数直接调用飞书标准鉴权接口：

```elixir
{:ok, %{token: tenant_token, expire: tenant_expire}} =
  FeishuOpenAPI.Auth.tenant_access_token(client)

{:ok, %{token: app_token, expire: app_expire}} =
  FeishuOpenAPI.Auth.app_access_token(client)
```

### 商店应用

商店应用必须先持有 `app_ticket`，才能换取 `app_access_token`：

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

写入票据后，`FeishuOpenAPI.request/4` 也可根据 `:tenant_key` 自动获取并缓存商店应用的租户令牌：

```elixir
FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx",
  tenant_key: "tenant_key_xxx"
)
```

注意事项：

- 本库不会将 `app_ticket` 持久化到外部存储。
- 收到商店应用的 `app_ticket` 推送事件后，请从解码后的事件信封中提取票据，并调用 `FeishuOpenAPI.TokenManager.put_app_ticket/2` 写入缓存。
- 若缓存中尚无票据，获取商店应用令牌会返回 `{:error, %FeishuOpenAPI.Error{code: :app_ticket_missing}}`。

若希望启动时在未缓存 `app_ticket` 的情况下自动请求飞书重推票据，可在应用启动阶段（如 `Application.start/2`）调用一次 `FeishuOpenAPI.TokenManager.bootstrap/1`：

```elixir
_ = FeishuOpenAPI.TokenManager.bootstrap(client)
```

也可随时手动触发重推：

```elixir
FeishuOpenAPI.Auth.app_ticket_resend(client)
```

### 用户访问令牌（User Access Token）

对于 OAuth 登录流程，可使用内置的 OIDC 辅助函数：

```elixir
{:ok, user_tokens} =
  FeishuOpenAPI.Auth.user_access_token(client, "authorization_code_from_login")

user_tokens.access_token
user_tokens.refresh_token

{:ok, refreshed} =
  FeishuOpenAPI.Auth.refresh_user_access_token(client, user_tokens.refresh_token)
```

上述函数与官方 Node SDK 保持一致，调用 `authen/v1/oidc/access_token` 与 `authen/v1/oidc/refresh_access_token`，返回的映射包含：

- `:access_token`
- `:refresh_token`
- `:token_type`
- `:expires_in`
- `:refresh_expires_in`
- `:scope`
- `:raw`

若需在多次请求之间自动为用户令牌续期，可将其交由 `FeishuOpenAPI.UserTokenManager` 托管：

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

`FeishuOpenAPI.UserTokenManager` 会在上游过期前 3 分钟使用已保存的 `refresh_token` 自动刷新 `access_token`。若直接传入 `user_access_token: "..."`，客户端会将其作为显式 Bearer 令牌原样发送，不会自动续期。

## 请求、上传与下载

### 请求参数

`FeishuOpenAPI.request/4` 及各 HTTP 动词辅助函数支持以下选项：

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

翻页辅助模块 `FeishuOpenAPI.Pagination` 优先读取 `data.page_token`，未出现时回退至 `data.next_page_token`，与官方 Node SDK 的分页迭代器一致。

请求体同样支持顶层 JSON 标量值：

```elixir
FeishuOpenAPI.post(client, "some/endpoint", body: false)
FeishuOpenAPI.post(client, "some/endpoint", body: nil)
```

### 分块表单上传

调用文件上传接口时使用 `FeishuOpenAPI.upload/3`：

```elixir
FeishuOpenAPI.upload(client, "im/v1/files",
  fields: [
    file_type: "stream",
    file_name: "report.txt"
  ],
  file: {:path, "/tmp/report.txt"}
)
```

`:file` 支持以下格式：

- `{:path, "/abs/path"}`
- `{:path, "/abs/path", "override.ext"}`
- `{:iodata, content, "name.ext"}`

### 二进制下载

下载文件等二进制响应时使用 `FeishuOpenAPI.download/3`：

```elixir
{:ok, %{body: bin, filename: filename, status: 200}} =
  FeishuOpenAPI.download(client, "im/v1/files/:file_key",
    path_params: %{file_key: "file_xxx"}
  )
```

## 响应与错误模型

标准信封响应成功时返回：

```elixir
{:ok, %{"code" => 0, "msg" => "success", "data" => data}}
```

若传入 `raw: true`，则直接返回未经解包的 `%Req.Response{}`：

```elixir
{:ok, %Req.Response{} = resp} =
  FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx", raw: true)
```

调用失败时统一返回 `{:error, %FeishuOpenAPI.Error{}}`，主要字段包括：

- `:code` - 响应信封中 `code` 非零时为飞书业务错误码（整数）；传输层或客户端侧失败时为内部原子标识（如 `:http_error`、`:transport`、`:rate_limited`、`:bad_path`、`:tenant_key_required`、`:app_ticket_missing` 等）
- `:http_status`
- `:log_id`
- `:msg`
- `:raw_body`
- `:details` - 飞书返回嵌套 `"error"` 字段时的附加错误详情

当 `:code` 为整数业务码时，`Exception.message/1` 会在消息末尾附上官方[通用错误码文档](https://open.feishu.cn/document/server-docs/api-call-guide/generic-error-code)链接，便于直接从日志排查原因。

示例：

```elixir
case FeishuOpenAPI.get(client, "contact/v3/users/ou_xxx") do
  {:ok, resp} ->
    resp["data"]

  {:error, %FeishuOpenAPI.Error{code: code, log_id: log_id} = err} ->
    Logger.error("feishu error code=#{inspect(code)} log_id=#{log_id} err=#{Exception.message(err)}")
end
```

请始终根据 `:code` 而非 `:msg` 编写错误处理分支；与飞书官方约定一致，`:code` 才是稳定的机器可读错误标识。

## 限流处理

飞书以业务错误码 `99991400` 标识限流，实际接口中可能以三种 HTTP 形态返回：

- HTTP 429，响应体为 `{"code": 99991400, ...}`（当前主流接口）
- HTTP 400，响应体相同（旧版接口）
- HTTP 200，响应体相同（线上偶发的边界情况）

客户端会统一识别这三种限流响应，等待退避时间后自动重试一次；若重试后仍被限流，则返回 `{:error, %FeishuOpenAPI.Error{code: :rate_limited}}`。

计算等待时长时，客户端优先读取飞书专用的 `x-ogw-ratelimit-reset` 请求头，其次读取标准 `Retry-After`，若两者均未提供则默认等待约 1 秒，单次最大等待时间不超过 30 秒。

每次限流重试都会触发一条 `[:feishu_openapi, :request, :rate_limited]` Telemetry 事件，元数据包含 `:method`、`:path`、`:app_id`、`:http_status`、`:source`（`:x_ogw_ratelimit_reset` | `:retry_after` | `:default`）、`:limit`（若有 `x-ogw-ratelimit-limit` 请求头则一并附带）以及 `:log_id`。如需在应用层监控限流，可挂载对应的事件处理函数。各接口的具体配额参见飞书[频控策略文档](https://open.feishu.cn/document/server-docs/api-call-guide/rate-limit)。

## Webhook 事件

`FeishuOpenAPI.Event.Dispatcher` 支持处理：

- 明文事件报文
- 使用 `Encrypt Key` 加密的事件报文
- 基于 `x-lark-request-timestamp`、`x-lark-request-nonce` 与 `x-lark-signature` 的请求签名校验
- `Verification Token` 校验
- `url_verification` 地址校验握手响应

创建事件分发器并注册回调：

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

手动分发原始 Webhook 报文：

```elixir
FeishuOpenAPI.Event.Dispatcher.dispatch(dispatcher, {:raw, raw_body, headers})
```

### 可选的 Plug 适配器

若宿主应用使用 `Plug`，可直接挂载 `FeishuOpenAPI.Event.Server` 读取原始请求体、完成验签与解密并写回 JSON 响应：

```elixir
plug FeishuOpenAPI.Event.Server, dispatcher: dispatcher
```

返回值与 HTTP 响应的对应关系：

- `url_verification` 握手请求 -> `{"challenge": "..."}`
- 处理函数返回映射（map） -> 直接序列化为响应体
- 处理函数返回 `{:ok, _}` -> `{"msg": "success"}`
- 处理函数返回 `{:error, _}` 或抛出异常 -> 返回 HTTP 500，触发飞书服务端重推
- 处理函数返回其他值 -> `{"msg": "success"}`

对于交互卡片的 HTTP 回调，请使用下文的 `FeishuOpenAPI.CardAction.Handler`，不要使用 `Event.Dispatcher.on_callback/3`，因为卡片回调的签名算法与事件订阅 Webhook 不同。

## 交互卡片回调

`FeishuOpenAPI.CardAction.Handler` 与飞书官方 Go SDK 的卡片回调处理流程一致，支持：

- 可选的 `Encrypt Key` 报文解密
- `url_verification` 地址校验握手
- 基于 `x-lark-request-timestamp`、`x-lark-request-nonce`、`x-lark-signature` 与 `Verification Token` 的 SHA-1 签名校验

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

在 `Plug` 路由中可挂载配套的适配器：

```elixir
plug FeishuOpenAPI.CardAction.Server, handler: card_handler
```

## WebSocket 事件推送

`FeishuOpenAPI.WS.Client` 负责建立飞书 / Lark WebSocket 事件推送长连接，并将解码后的事件交由同一个 `Dispatcher` 分发。由于长连接在建连阶段已完成应用鉴权，收到的事件帧会直接作为可信的已解码事件分发，无需再校验 Webhook 的 `Verification Token` 或 `Encrypt Key`。

```elixir
{:ok, _pid} =
  FeishuOpenAPI.WS.Client.start_link(
    client: client,
    dispatcher: dispatcher,
    auto_reconnect: true
  )
```

连接运行期间会自动完成以下工作：

- 请求 `/callback/ws/endpoint` 获取长连接接入地址
- 应用服务端下发的心跳间隔与重连参数
- 重组分片帧
- 分发解码后的 `event` 与 `card` 载荷
- 遇到非致命连接断开时自动重连

## 说明与限制

- 本库是按路径调用的通用客户端，而非代码生成的全量接口封装层。
- 商店应用的 `app_ticket` 持久化由调用方按自身存储方案自行管理。
- Webhook 验签依赖未经修改的原始 HTTP 请求体；若自行编写接入层，请务必在解析或改写请求体前完成验签。

## 手工业务端到端验证

仓库提供了一个仅用于本地开发联调的手工脚本 `plugins/lark_adapter/scripts/feishu_business_e2e.exs`，可直接连接真实飞书接口验证核心业务链路：

- 订阅 `im.message.receive_v1`、`im.message.recalled_v1`、`im.message.reaction.created_v1` 与 `im.message.reaction.deleted_v1` 长连接事件
- 调用用户、消息与群聊 REST 查询接口
- 下载消息内的媒体资源
- 执行发送、回复、编辑与撤回消息流程
- 执行 CardKit 卡片创建、流式内容更新与配置更新

由于该脚本会访问真实飞书环境并产生实际消息副作用，因此未纳入 `mix test`。

运行前在仓库根目录创建 `.env.local`，至少填入：

```dotenv
FEISHU_APP_ID=cli_xxx
FEISHU_APP_SECRET=xxx
```

随后在仓库根目录执行：

```bash
elixir plugins/lark_adapter/scripts/feishu_business_e2e.exs
```

默认触发方式：

- 向机器人发送任意用户消息即可触发 `im.message.receive_v1` 并跑完整个验证流程（脚本会自动忽略非用户发送者，防止机器人自身消息引发回调死循环）
- 发送图片或文件消息可验证资源下载链路
- 添加或移除表情回复、撤回消息可观察长连接事件推送

## 运行测试

```bash
bun run lark-adapter:test
```
