---
name: phoenix
description: Phoenix Framework guidance including architecture, Plug, contexts, router, channels, PubSub, security, forms, Ecto patterns, configuration, Tailwind, and deployment. ALWAYS use for Phoenix web development and best practices. ALWAYS use when writing controllers, plugs, contexts, router config, or Phoenix templates.
---

# Phoenix Framework Skill

## Rules for Writing Phoenix Code (LLM)

1. ALWAYS use contexts for business logic — never access Repo directly from controllers or LiveViews
2. ALWAYS use `to_form()` and `@form[:field]` for forms — never access changesets directly in templates
3. ALWAYS use verified routes `~p"/path"` — never string-concatenate paths
4. ALWAYS preload associations before rendering — never trigger lazy loads in templates
5. ALWAYS use action-specific changesets — never cast all fields in one changeset (mass assignment risk)
6. ALWAYS guard `runtime.exs` config with `if config_env() == :prod` — it runs in ALL environments
7. ALWAYS use raw SQL or migration-local schemas in migrations — never reference application schemas
8. NEVER use `String.to_atom/1` with user input — atom table exhaustion attack vector
9. NEVER use `raw/1` on unsanitized user input — XSS vulnerability
10. ALWAYS use `~H` sigil and `{...}` interpolation — never use deprecated `~E`, `let={f}`, or `Phoenix.View`
11. ALWAYS set `same_site`, `http_only`, and `secure` on session cookies in production
12. ALWAYS call `delete_csrf_token/0` after login to prevent session fixation
13. ALWAYS prefer generators (`mix phx.gen.*`) over hand-writing contexts, schemas, and migrations — generators produce correct, tested, consistent code

## Decision Tables

### Which Route Type?

| When you need to... | Use this | NOT this |
|---|---|---|
| REST resource with CRUD | `resources "/users", UserController` | Individual route macros |
| LiveView with client state | `live "/dashboard", DashboardLive` | Controller + JS |
| Static page, no state | `get "/about", PageController, :about` | LiveView (overhead) |
| JSON API endpoint | `resources` in `:api` pipeline | `:browser` pipeline |
| WebSocket real-time | Channel via `socket "/socket"` | Polling controller |
| Delegate to sub-router | `forward "/admin", AdminRouter` | Duplicating pipelines |

### Which Data Access Pattern?

| When you need to... | Use this | NOT this |
|---|---|---|
| Fetch by ID (may not exist) | `context.get_thing(id)` → `nil` | `Repo.get!` in controller |
| Fetch by ID (must exist) | `context.get_thing!(id)` in controller | Manual nil check |
| Query with filters | Context function with `Ecto.Query` | Raw SQL in controller |
| Create/update with validation | Context returning `{:ok, struct}` / `{:error, changeset}` | `Repo.insert` in controller |
| Form changeset for display | `context.change_thing(struct)` | Building changeset in template |

### Which Component Type?

| When you need to... | Use this | NOT this |
|---|---|---|
| Reusable stateless UI | Function component with `attr`/`slot` | LiveComponent |
| Shared layout wrapper | Function component | `embed_templates` alone |
| Tabular data with columns | Slot attributes (`:col` with `:let`) | Manual table HTML |
| External template files | `embed_templates "components/*"` | Inline `~H` for large templates |

## Architecture Overview

### Request Flow

```
Request → Endpoint → Router → Pipeline → Controller/LiveView → View/Component → Response
```

1. **Endpoint**: Supervision tree root, initial plug pipeline (static files, session, CSRF)
2. **Router**: Matches routes, applies pipelines via scope blocks
3. **Pipeline**: Series of plugs for route groups (`:browser`, `:api`, etc.)
4. **Controller/LiveView**: Handles business logic via context calls
5. **View/Component**: Renders response (function components, HEEx templates)

Each request/WebSocket runs in its own BEAM process — isolation and fault tolerance by default.

## Plug Fundamentals

### Two Types of Plugs

```elixir
# Function plug - receives and returns conn
def my_plug(conn, opts) do
  conn
end

# Module plug - init at compile time, call at runtime
defmodule MyPlug do
  def init(opts), do: opts           # Compile time - do heavy work here
  def call(conn, opts), do: conn     # Runtime - keep fast
end
```

### Key Rules

- `init/1` executes at **compile time** — perfect for config processing
- `call/2` executes at **runtime** — keep it fast
- Every plug **must** return the connection
- Use `assign/3` instead of process dictionary
- **Always** define a catch-all route to avoid function clause errors

### Common Plugs

```elixir
plug :accepts, ["html"]           # Content negotiation
plug :fetch_session               # Load session data
plug :fetch_live_flash            # Flash messages for LiveView
plug :put_root_layout             # Set root layout
plug :protect_from_forgery        # CSRF protection
plug :put_secure_browser_headers  # Security headers
```

## Router & Pipelines

### Pipeline Definition

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
end

pipeline :api do
  plug :accepts, ["json"]
end
```

### Scopes and Routes

```elixir
scope "/", MyAppWeb do
  pipe_through :browser

  get "/", PageController, :home
  resources "/users", UserController
  live "/dashboard", DashboardLive
end

# Nested scope - alias is cumulative
scope "/admin", MyAppWeb.Admin do
  pipe_through [:browser, :require_admin]

  live "/users", UserLive  # Points to MyAppWeb.Admin.UserLive
end
```

**Critical**: Router `scope` blocks include alias — don't duplicate the namespace.

### Live Sessions

Group LiveView routes sharing authentication or on_mount hooks:

```elixir
scope "/", MyAppWeb do
  pipe_through [:browser, :require_authenticated_user]

  live_session :authenticated, on_mount: [{MyAppWeb.UserAuth, :ensure_authenticated}] do
    live "/dashboard", DashboardLive
    live "/settings", SettingsLive
    live "/profile", ProfileLive
  end
end
```

### Content-Type-Specific Pipelines

For XML feeds, JSON feeds, or other non-HTML responses:

```elixir
pipeline :feed do
  plug :accepts, ["xml"]
  plug :put_resp_content_type, "application/xml"
  plug MyAppWeb.Plugs.CacheControl, max_age: 900
end

scope "/", MyAppWeb do
  pipe_through :feed
  get "/feed", FeedController, :index
  get "/:podcast/feed", FeedController, :podcast
end
```

### Path Helpers

```elixir
# Use verified routes with ~p sigil
~p"/users"
~p"/users/#{user.id}"
~p"/users/#{user}/edit"
```

## Contexts & Domain Modeling

### What Contexts Are

Contexts are modules that group related functionality (bounded contexts). They:
- Encapsulate business logic separate from web interface
- Create clear public APIs for each domain
- Enable multiple consumers (web, API, CLI, channels)
- Reduce coupling between domains

### Context Design

```elixir
defmodule MyApp.Accounts do
  @moduledoc "The Accounts context - user management"

  alias MyApp.Accounts.User
  alias MyApp.Repo

  def get_user(id), do: Repo.get(User, id)
  def get_user!(id), do: Repo.get!(User, id)

  def create_user(attrs) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end
end
```

### Context Guidelines

- **Never** access Repo directly from controllers/LiveViews
- Create focused contexts (Accounts, Catalog, Orders) not "one resource contexts"
- Context functions should return `{:ok, struct}` or `{:error, changeset}`
- Bang functions (`get_user!`) raise on failure — use in controllers where failure means 404
- **Never** use bang functions (`Repo.insert!`, `Repo.update!`) inside context logic — crashes instead of returning errors. Use in controllers only, or pattern match on `{:ok, _} | {:error, _}`
- Group related schemas: `MyApp.Accounts.User`, `MyApp.Accounts.Credential`
- Non-Ecto structs are valid domain models — use plain `defstruct` for computed/assembled data not backed by a table

### God Context Smell

A context exceeding ~500 lines or handling 4+ distinct responsibilities needs splitting. Symptoms:

- Context has 30+ public functions
- Functions within it don't share data or schemas
- You need to read the whole module to understand one feature

```elixir
# BAD: God context — videos, channels, thumbnails, transcoding, subtitles all in one
defmodule MyApp.Library do  # 850 lines
  def list_videos(...), do: ...
  def get_channel!(...), do: ...
  def generate_thumbnail(...), do: ...
  def transmux_to_hls(...), do: ...
  def create_subtitle(...), do: ...
end

# GOOD: Split by responsibility
defmodule MyApp.Videos do ... end      # CRUD, queries, lifecycle
defmodule MyApp.Channels do ... end    # Channel profiles, derived from users
defmodule MyApp.Transcoding do ... end # FFmpeg, HLS, thumbnails
```

### Query Composition Helpers

When the same joins/selects appear in 3+ queries, extract a shared helper:

```elixir
# BAD: Copy-pasted select_merge across 10 queries
def list_videos do
  from(v in Video,
    join: u in User, on: v.user_id == u.id,
    select_merge: %{channel_name: u.name, channel_handle: u.handle})
  |> Repo.all()
end

# GOOD: Shared query builder
defp with_channel(query) do
  from(v in query,
    join: u in User, as: :user, on: v.user_id == u.id,
    select_merge: %{channel_name: u.name, channel_handle: u.handle})
end

def list_videos, do: Video |> with_channel() |> Repo.all()
def get_video!(id), do: Video |> with_channel() |> Repo.get!(id)
```

### Soft Deletes

Mark records as deleted instead of removing them:

```elixir
# Schema
field :deleted_at, :utc_datetime

# Query helper
def not_deleted(query \\ __MODULE__) do
  from(q in query, where: is_nil(q.deleted_at))
end

# Context — soft delete
def delete_video(%Video{} = video) do
  video |> Ecto.Changeset.change(%{deleted_at: DateTime.utc_now()}) |> Repo.update()
end

# Always filter: Video |> Video.not_deleted() |> Repo.all()
```

### HMAC-Signed Public URLs

For tamper-proof public URLs (unsubscribe links, tracking pixels, magic links):

```elixir
def sign_url(data, secret_key_base) do
  signature = :crypto.mac(:hmac, :sha256, secret_key_base, data) |> Base.url_encode64(padding: false)
  "#{data}/#{signature}"
end

def verify_url(data, signature, secret_key_base) do
  expected = :crypto.mac(:hmac, :sha256, secret_key_base, data) |> Base.url_encode64(padding: false)
  Plug.Crypto.secure_compare(expected, signature)
end

# Usage: /unsubscribe/:contact_id/:hmac
```

### Ecto.Multi for Safe Concurrent Operations

Use `Ecto.Multi` with row-level locking for operations that must be atomic under concurrency (e.g., reordering lists):

```elixir
def update_position(%Song{} = song, new_position) do
  Ecto.Multi.new()
  |> Ecto.Multi.run(:lock, fn repo, _ ->
    {:ok, repo.one(from s in Song, where: s.id == ^song.id, lock: "FOR UPDATE")}
  end)
  |> Ecto.Multi.run(:reorder, fn repo, %{lock: locked} ->
    # Shift other items and update position
    repo.update(Song.changeset(locked, %{position: new_position}))
  end)
  |> Repo.transaction()
end
```

### Event Structs for PubSub

For complex apps, use dedicated event structs instead of bare tuples — provides compile-time checking and self-documenting payloads:

```elixir
# In context module
defmodule MyApp.MediaLibrary.Events do
  defmodule Play do
    defstruct [:song, :elapsed]
  end

  defmodule SongsImported do
    defstruct [:count, :user_id]
  end
end

# Broadcasting
Phoenix.PubSub.broadcast(MyApp.PubSub, "media:#{user_id}", %Play{song: song, elapsed: 0})

# Receiving — pattern match on struct
def handle_info(%Play{song: song}, socket) do
  {:noreply, assign(socket, now_playing: song)}
end
```

### Context with Filtering and Pagination

```elixir
def list_users(filters \\ %{}, opts \\ []) do
  page = Keyword.get(opts, :page, 1)
  per_page = Keyword.get(opts, :per_page, 20)

  User
  |> apply_filters(filters)
  |> limit(^per_page)
  |> offset(^((page - 1) * per_page))
  |> Repo.all()
end

defp apply_filters(query, filters) do
  Enum.reduce(filters, query, fn
    {"role", role}, q -> where(q, [u], u.role == ^role)
    {"search", term}, q -> where(q, [u], ilike(u.name, ^"%#{term}%"))
    _, q -> q
  end)
end
```

## HEEx Templates & Components

### Function Components

```elixir
attr :name, :string, required: true
attr :class, :string, default: nil
attr :rest, :global
slot :inner_block

def greet(assigns) do
  ~H"""
  <div class={@class} {@rest}>
    Hello, {@name}!
    {render_slot(@inner_block)}
  </div>
  """
end
```

### Attrs and Slots

```elixir
attr :user, :map, required: true
attr :size, :string, default: "md", values: ["sm", "md", "lg"]
attr :rest, :global

slot :header
slot :col do
  attr :label, :string, required: true
end
```

### Phoenix 1.8 HEEx Rules

- **Always** use `~H` sigil or `.html.heex` files — **never** `~E`
- **Always** use `{...}` for interpolation in attributes
- **Always** use `<%= %>` for control flow blocks (if/for/cond)
- **Never** use `<% Enum.each %>` — use `<%= for item <- @items do %>`
- Class lists **must** use `[...]` syntax for conditionals:

```elixir
<a class={[
  "px-2 text-white",
  @active && "bg-blue-500",
  if(@large, do: "text-lg", else: "text-sm")
]}>
```

- No `else if` — use `cond`:

```elixir
<%= cond do %>
  <% @status == :pending -> %>
    <span class="text-yellow-500">Pending</span>
  <% @status == :approved -> %>
    <span class="text-green-500">Approved</span>
  <% true -> %>
    <span class="text-gray-500">Unknown</span>
<% end %>
```

- Comments: `<%!-- comment --%>`
- Wrap LiveView templates with `<Layouts.app flash={@flash} ...>`
- `Phoenix.View` is obsolete — don't use it

### embed_templates

```elixir
defmodule MyAppWeb.Components do
  use Phoenix.Component
  embed_templates "components/*"  # Loads .html.heex files as functions
end
```

## HTTP Requests

Use `:req` library — not `:httpoison`, `:tesla`, or `:httpc`:

```elixir
# deps: {:req, "~> 0.5"}
Req.get!("https://api.example.com/data")
Req.post!("https://api.example.com/users", json: %{name: "John"})
```

## Channels & PubSub

### Channel Architecture

One channel server process per client per topic. Broadcasts work across clustered nodes via PubSub.

```elixir
defmodule MyAppWeb.RoomChannel do
  use Phoenix.Channel

  def join("room:" <> room_id, _params, socket) do
    {:ok, assign(socket, :room_id, room_id)}
  end

  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{body: body})
    {:noreply, socket}
  end
end
```

### PubSub Broadcasting

```elixir
# Subscribe
Phoenix.PubSub.subscribe(MyApp.PubSub, "users:#{user_id}")

# Broadcast
Phoenix.PubSub.broadcast(MyApp.PubSub, "users:#{user_id}", {:user_updated, user})

# In LiveView handle_info
def handle_info({:user_updated, user}, socket) do
  {:noreply, assign(socket, :user, user)}
end
```

### Presence Tracking

```elixir
defmodule MyAppWeb.Presence do
  use Phoenix.Presence,
    otp_app: :my_app,
    pubsub_server: MyApp.PubSub
end

Presence.track(socket, user.id, %{online_at: System.system_time(:second)})
Presence.list(socket)
```

## Forms & Validation

### Controller Pattern

```elixir
def new(conn, _params) do
  changeset = Accounts.change_user(%User{})
  render(conn, :new, changeset: changeset)
end

def create(conn, %{"user" => user_params}) do
  case Accounts.create_user(user_params) do
    {:ok, user} ->
      conn
      |> put_flash(:info, "User created successfully.")
      |> redirect(to: ~p"/users/#{user}")

    {:error, %Ecto.Changeset{} = changeset} ->
      render(conn, :new, changeset: changeset)
  end
end
```

### Changeset Validation

```elixir
def changeset(user, attrs) do
  user
  |> cast(attrs, [:email, :password])
  |> validate_required([:email, :password])
  |> validate_format(:email, ~r/@/)
  |> validate_length(:password, min: 8)
  |> unique_constraint(:email)
end
```

### Ecto Guidelines

- Always preload associations accessed in templates
- Use `:string` type for all text columns (including text)
- `validate_number/2` skips nil automatically — no `:allow_nil` option
- Must use `Ecto.Changeset.get_field/2` to access changeset fields
- Programmatic fields like `user_id` shouldn't be in `cast/3` — set explicitly:

```elixir
# BAD - user_id from untrusted input
cast(attrs, [:body, :user_id])  # Security risk!

# GOOD - set programmatically
cast(attrs, [:body]) |> put_assoc(:user, user)
```

### Upsert (Find or Create)

Use `on_conflict` for idempotent inserts — common for OAuth user sync, counters, external data:

```elixir
def upsert_user(attrs) do
  %User{}
  |> User.changeset(attrs)
  |> Repo.insert(
    on_conflict: {:replace_all_except, [:id, :email, :inserted_at]},
    conflict_target: :email,
    returning: true
  )
end
```

`returning: true` ensures the upserted record (with DB-generated fields) is returned.

### Schemas in Migrations — NEVER

```elixir
# BAD: Migration breaks if User schema changes
alias MyApp.Accounts.User
from(u in User, where: u.old_field == "value") |> Repo.update_all(...)

# GOOD: Use raw SQL
execute("UPDATE users SET permission = 'default' WHERE old_field = 'value'")

# GOOD: Or migration-local schema
defmodule User do
  use Ecto.Schema
  schema "users" do
    field :old_field, :string
    field :permission, :string
  end
end
```

## Security

### CSRF Protection

- Enabled by default via `protect_from_forgery` plug
- Token passed via params (`_csrf_token`) or header (`x-csrf-token`)
- **Call `delete_csrf_token/0` after login** to prevent fixation attacks

### Session Security

```elixir
plug Plug.Session,
  store: :cookie,
  key: "_my_app_key",
  signing_salt: "secret",
  same_site: "Lax",
  http_only: true,
  secure: true,
  max_age: 60 * 60 * 24 * 7  # 7 days
```

### WebSocket Origin Protection

`check_origin` prevents Cross-site WebSocket Hijacking. Phoenix checks origin against configured host automatically:

```elixir
# Recommended: use endpoint host
config :my_app, MyAppWeb.Endpoint, url: [host: "my-production-domain.com"]

# Explicit whitelist for multiple domains
socket "/live", Phoenix.LiveView.Socket,
  websocket: [check_origin: [
    "https://example.com",
    "https://staging.example.com"
  ]]
```

**Never** set `check_origin: false` in production.

### Mass Assignment Prevention

```elixir
# BAD: User can set admin flag
cast(attrs, [:username, :email, :admin])

# GOOD: Separate changesets
def registration_changeset(user, attrs) do
  cast(attrs, [:username, :email])
end

def admin_changeset(user, attrs) do
  cast(attrs, [:admin, :role])
end
```

### SQL Injection Prevention

```elixir
# BAD: String interpolation in SQL
query = "SELECT * FROM users WHERE name = '#{params["name"]}'"

# GOOD: Ecto parameterization
from(u in User, where: u.name == ^params["name"]) |> Repo.all()

# GOOD: Raw SQL with parameters
Ecto.Adapters.SQL.query!(Repo, "SELECT * FROM users WHERE name = $1", [params["name"]])
```

### XSS Prevention

```elixir
# BAD: raw/1 on user input
<%= raw(@user_input) %>

# GOOD: Let Phoenix auto-escape (default)
<%= @user_input %>

# GOOD: If HTML needed, sanitize first
<%= raw(HtmlSanitizeEx.strip_tags(@user_input)) %>
```

### Sobelow Security Scanner

```bash
mix archive.install hex sobelow
mix sobelow  # Detects XSS, SQL injection, command injection, directory traversal
```

### Security Mistakes (Atoms)

```elixir
# BAD: User input to atom — atom table exhaustion!
role = String.to_atom(params["role"])

# GOOD: Validate against known values
role = case params["role"] do
  "admin" -> :admin
  "user" -> :user
  _ -> :guest
end
```

## Authentication

### Generated Auth (phx.gen.auth)

```bash
mix phx.gen.auth Accounts User users  # Session-based auth scaffolding
```

Generated code uses a **Scope-based, token-based** pattern:
- Session stores `:user_token` (not user ID) — enables per-session revocation and token rotation
- `live_socket_id` is `"users_sessions:#{Base.url_encode64(token)}"` — token-based, not user-id-based
- `current_scope` assign wraps user in a `Scope` struct — access user via `@current_scope.user`
- `on_mount` hooks: `:mount_current_scope` (optional auth), `:require_authenticated` (required auth), `:require_sudo_mode`
- Automatic token rotation after `@session_reissue_age_in_days` (default 7)
- `renew_session/2` is a private function combining `delete_csrf_token()`, `configure_session(renew: true)`, and `clear_session()`

```elixir
# Generated on_mount pattern — uses assign_new to avoid re-fetching
def on_mount(:require_authenticated, _params, session, socket) do
  socket = mount_current_scope(socket, session)

  if socket.assigns.current_scope && socket.assigns.current_scope.user do
    {:cont, socket}
  else
    {:halt, socket |> put_flash(:error, "You must log in") |> redirect(to: ~p"/users/log-in")}
  end
end

defp mount_current_scope(socket, session) do
  assign_new(socket, :current_scope, fn ->
    if token = session["user_token"] do
      {user, _} = Accounts.get_user_by_session_token(token)
      Scope.for_user(user)
    end || Scope.for_user(nil)
  end)
end
```

### OAuth Authentication Flow

For GitHub/Google/etc. OAuth:

```elixir
# Router
scope "/auth", MyAppWeb do
  pipe_through [:browser]
  get "/:provider", AuthController, :request
  get "/:provider/callback", OAuthCallbackController, :new
end

# Callback controller — with-chain for multi-step auth
defmodule MyAppWeb.OAuthCallbackController do
  use MyAppWeb, :controller

  def new(conn, %{"provider" => "github", "code" => code}) do
    with {:ok, token} <- GitHub.exchange_code(code),
         {:ok, info} <- GitHub.fetch_user_info(token),
         {:ok, user} <- Accounts.register_or_login_github_user(info, token) do
      UserAuth.log_in_user(conn, user)
    else
      {:error, reason} ->
        conn |> put_flash(:error, "Auth failed: #{reason}") |> redirect(to: ~p"/")
    end
  end
end
```

### live_socket_id for Multi-Tab Session Management

Set a `live_socket_id` on login to force-disconnect all LiveView tabs on logout:

```elixir
def log_in_user(conn, user) do
  token = Accounts.generate_user_session_token(user)

  conn
  |> renew_session(user)
  |> put_session(:user_token, token)
  |> put_session(:live_socket_id, "users_sessions:#{Base.url_encode64(token)}")
  |> redirect(to: ~p"/")
end

def log_out_user(conn) do
  token = get_session(conn, :user_token)
  token && Accounts.delete_user_session_token(token)

  if live_socket_id = get_session(conn, :live_socket_id) do
    MyAppWeb.Endpoint.broadcast(live_socket_id, "disconnect", %{})
  end

  conn |> renew_session(nil) |> redirect(to: ~p"/")
end

# renew_session is a private function — not a Plug built-in
defp renew_session(conn, _user) do
  delete_csrf_token()
  conn |> configure_session(renew: true) |> clear_session()
end
```

### Policy-Based Authorization

For complex role/permission models, use dynamic policy dispatch:

```elixir
defmodule MyAppWeb.Plugs.Authorize do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, policy_module) do
    user = conn.assigns.current_user
    if apply(policy_module, action_name(conn), [user]) do
      conn
    else
      conn |> put_flash(:error, "Not authorized") |> redirect(to: ~p"/") |> halt()
    end
  end
end

# Policy module — multi-clause functions for each action
defmodule MyApp.Policies.Post do
  def index(_user), do: true
  def create(%{role: role}) when role in [:admin, :editor], do: true
  def create(_), do: false
  def delete(%{role: :admin}), do: true
  def delete(_), do: false
end

# In controller: plug MyAppWeb.Plugs.Authorize, MyApp.Policies.Post
```

## External API Resilience

### Circuit Breaker (fuse)

Protect against cascading failures when calling external APIs:

```elixir
# deps: {:fuse, "~> 2.5"}

# Install the fuse (in Application.start or context init)
:fuse.install(:tesla_api, {{:standard, 5, 60_000}, {:reset, 300_000}})
# 5 failures in 60s → blow fuse, reset after 5 minutes

# In context — check fuse before calling
def fetch_vehicle_data(vehicle_id) do
  case :fuse.ask(:tesla_api, :sync) do
    :ok ->
      case TeslaClient.get_vehicle(vehicle_id) do
        {:ok, data} -> {:ok, data}
        {:error, :unauthorized} ->
          :fuse.melt(:tesla_api)  # Record failure
          {:error, :unauthorized}
      end

    :blown ->
      {:error, :api_unavailable}
  end
end
```

### ETS as Read Cache

For hot data read by many concurrent processes (auth tokens, config), use ETS with GenServer write serialization:

```elixir
defmodule MyApp.TokenCache do
  use GenServer

  def start_link(_) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def init(_) do
    table = :ets.new(__MODULE__, [:set, :named_table, :public, read_concurrency: true])
    {:ok, table}
  end

  # Fast concurrent reads — no GenServer bottleneck
  def get_token(user_id) do
    case :ets.lookup(__MODULE__, user_id) do
      [{^user_id, token}] -> {:ok, token}
      [] -> {:error, :not_found}
    end
  end

  # Writes serialized through GenServer
  def put_token(user_id, token) do
    GenServer.call(__MODULE__, {:put, user_id, token})
  end

  def handle_call({:put, user_id, token}, _from, table) do
    :ets.insert(table, {user_id, token})
    {:reply, :ok, table}
  end
end
```

### NimbleOptions for Init Validation

Validate GenServer/Plug options at startup — fail fast with clear errors:

```elixir
# deps: {:nimble_options, "~> 1.1"}

defmodule MyApp.Poller do
  use GenServer

  @opts_schema [
    interval: [type: :pos_integer, default: 5000, doc: "Poll interval in ms"],
    url: [type: :string, required: true, doc: "API endpoint URL"],
    max_retries: [type: :non_neg_integer, default: 3]
  ]

  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @opts_schema)
    GenServer.start_link(__MODULE__, opts)
  end
end

# Clear error on bad config:
# ** (NimbleOptions.ValidationError) invalid value for :interval option:
#    expected positive integer, got: -1
```

## Production Plugs

### Webhook Signature Verification (Pre-Parser)

Webhook providers (Stripe, GitHub) require verifying signatures against the **raw request body**. Place *before* `Plug.Parsers` in endpoint:

```elixir
# In endpoint.ex — BEFORE Plug.Parsers
plug MyAppWeb.Plugs.WebhookBody

defmodule MyAppWeb.Plugs.WebhookBody do
  import Plug.Conn

  def init(opts), do: opts

  def call(%{request_path: "/webhooks/" <> _} = conn, _opts) do
    {:ok, raw_body, conn} = read_body(conn)
    assign(conn, :raw_body, raw_body)
  end

  def call(conn, _opts), do: conn
end
```

### Global Data Preloading

Preload data needed on every page (navigation, site config):

```elixir
defmodule MyAppWeb.Plugs.LoadNavData do
  import Plug.Conn
  def init(opts), do: opts
  def call(conn, _opts), do: assign(conn, :nav_categories, MyApp.Catalog.cached_categories())
end

# In pipeline: plug MyAppWeb.Plugs.LoadNavData
```

## Background Jobs (Oban)

Most production Phoenix apps need background job processing. Oban is the standard:

```elixir
# deps: {:oban, "~> 2.20"}

# config.exs
config :my_app, Oban,
  repo: MyApp.Repo,
  queues: [default: 10, mailer: 50, media: 5],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Cron, crontab: [
      {"0 * * * *", MyApp.Workers.HourlyCleanup},
      {"*/5 * * * *", MyApp.Workers.CheckScheduled}
    ]}
  ]
```

### Worker Pattern

```elixir
defmodule MyApp.Workers.SendEmail do
  use Oban.Worker, queue: :mailer, max_attempts: 3, unique: [period: 300]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id, "template" => template}}) do
    user = Accounts.get_user!(user_id)
    case Mailer.deliver(user, template) do
      {:ok, _} -> :ok
      {:error, :rate_limited} -> {:snooze, 60}  # Retry after 60 seconds
      {:error, reason} -> {:error, reason}       # Will retry with backoff
    end
  end
end

# Enqueue
%{user_id: user.id, template: "welcome"}
|> MyApp.Workers.SendEmail.new()
|> Oban.insert()

# Schedule for later
%{user_id: user.id, template: "reminder"}
|> MyApp.Workers.SendEmail.new(scheduled_at: DateTime.add(DateTime.utc_now(), 3600))
|> Oban.insert()
```

### Key Patterns

- Return `:ok` on success, `{:error, reason}` to retry, `{:snooze, seconds}` to delay
- Use `unique: [period: 300, keys: [:user_id]]` to prevent duplicate jobs
- Use `{:cancel, reason}` to permanently fail without retrying
- Test with `Oban.Testing` — `assert_enqueued worker: MyWorker, args: %{user_id: 1}`

## Multi-Tenancy

### Project-Based Isolation

Common pattern: Users → Accounts → Projects, with all data scoped to a project:

```elixir
# Plug loads project and verifies access
defmodule MyAppWeb.Plugs.LoadProject do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    project_id = conn.path_params["project_id"]
    user = conn.assigns.current_user

    case Projects.get_project_for_user(project_id, user.id) do
      %Project{} = project -> assign(conn, :current_project, project)
      nil -> conn |> put_status(404) |> halt()  # 404 not 403 — don't leak existence
    end
  end
end

# Scope all queries to project
def list_contacts(%Project{} = project) do
  from(c in Contact, where: c.project_id == ^project.id) |> Repo.all()
end
```

**Key**: Return 404 (not 403) when a user accesses another user's project — prevents resource enumeration.

## Compile-Time Feature Flags

For open-source + hosted versions from a single codebase:

```elixir
defmodule MyApp do
  defmacro if_cloud(do: block) do
    if Code.ensure_loaded?(MyAppCloud) do
      block
    end
  end

  def __mix_recompile__?, do: Code.ensure_loaded?(MyAppCloud) != @cloud_loaded
end

# In router — cloud-only routes
MyApp.if_cloud do
  scope "/billing", MyAppWeb.Cloud do
    live "/plans", PlansLive
  end
end
```

## Configuration Precedence

Config files load in order — **later overrides earlier**:

```
1. config/config.exs           — compile-time, all envs
2. config/{dev,test,prod}.exs  — compile-time, per-env
3. config/runtime.exs          — runtime, ALL envs (!)
```

> **CRITICAL:** `runtime.exs` runs in **every** environment. Always guard:

```elixir
# BAD: Overrides dev.exs/test.exs port!
config :my_app, MyAppWeb.Endpoint, http: [port: 4000]

# GOOD: Only in prod
if config_env() == :prod do
  config :my_app, MyAppWeb.Endpoint,
    http: [port: String.to_integer(System.get_env("PORT", "4000"))]
end
```

**Troubleshooting `:eaddrinuse`**: Check `runtime.exs` for unconditional endpoint config overriding `dev.exs`/`test.exs` port settings.

## Internationalization (Gettext)

### Setup

```elixir
# In MyAppWeb.Gettext (auto-generated)
use Gettext.Backend, otp_app: :my_app

# In templates
{gettext("Hello")}
{ngettext("1 item", "%{count} items", @count)}
{dgettext("errors", "is invalid")}

# Extract and merge translations
mix gettext.extract
mix gettext.merge priv/gettext
```

### Locale Plug

Set locale per request from user preference, Accept-Language header, or URL:

```elixir
defmodule MyAppWeb.Plugs.SetLocale do
  import Plug.Conn

  @supported_locales ~w(en de es fr)

  def init(opts), do: opts

  def call(conn, _opts) do
    locale =
      conn.params["locale"] ||
      get_session(conn, :locale) ||
      parse_accept_language(conn) ||
      "en"

    if locale in @supported_locales do
      Gettext.put_locale(MyAppWeb.Gettext, locale)
      conn |> put_session(:locale, locale)
    else
      conn
    end
  end

  defp parse_accept_language(conn) do
    case get_req_header(conn, "accept-language") do
      [header | _] -> header |> String.split(",") |> hd() |> String.split("-") |> hd()
      _ -> nil
    end
  end
end

# In pipeline: plug MyAppWeb.Plugs.SetLocale
```

### LiveView Locale

LiveView doesn't have access to the conn after mount. Pass locale via connect params:

```javascript
// app.js
let liveSocket = new LiveSocket("/live", Socket, {
  params: {_csrf_token: csrfToken, locale: document.documentElement.lang}
})
```

```elixir
# In on_mount hook
def on_mount(:set_locale, _params, _session, socket) do
  locale = get_connect_params(socket)["locale"] || "en"
  Gettext.put_locale(MyAppWeb.Gettext, locale)
  {:cont, assign(socket, :locale, locale)}
end
```

## GraphQL (Absinthe)

For GraphQL APIs alongside or instead of REST, use [Absinthe](https://hexdocs.pm/absinthe). Brief overview — deep coverage is out of scope for this skill:

```elixir
# Router — GraphQL endpoint alongside REST
scope "/" do
  pipe_through :api
  forward "/graphql", Absinthe.Plug, schema: MyAppWeb.Schema
  forward "/graphiql", Absinthe.Plug.GraphiQL, schema: MyAppWeb.Schema
end

# Schema (lib/my_app_web/schema.ex)
defmodule MyAppWeb.Schema do
  use Absinthe.Schema
  import_types MyAppWeb.Schema.UserTypes

  query do
    field :user, :user do
      arg :id, non_null(:id)
      resolve &MyAppWeb.Resolvers.Users.get/3
    end
  end
end
```

**Key patterns**: Use Dataloader for N+1 prevention, middleware for auth, separate mutation objects with `import_fields`. For file operations that don't fit GraphQL well (multipart uploads), use REST controllers alongside.

## Tailwind CSS Integration

### Phoenix 1.8 / Tailwind v4

```css
/* app.css */
@import "tailwindcss";
```

No `tailwind.config.js` needed in Tailwind v4.

### Guidelines

- **Never** use `@apply` in CSS (per Phoenix AGENTS.md)
- **Only** `app.js` and `app.css` bundles are supported
- **Never** use external script `src` — import into app.js

### DaisyUI Setup

```bash
cd assets && npm install -D daisyui@latest
```

```css
@import "tailwindcss";
@plugin "daisyui";
```

## Deployment

### Mix Release

```bash
mix phx.gen.release --docker  # Generate Dockerfile
MIX_ENV=prod mix release      # Build release
```

### Fly.io

```bash
fly launch       # Detects Phoenix, creates Dockerfile
fly deploy       # Deploy changes
fly ssh console  # Remote IEx shell
fly secrets set KEY=value
```

### Production Configuration

```elixir
# runtime.exs
if config_env() == :prod do
  config :my_app, MyAppWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST"), port: 443, scheme: "https"],
    secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
end
```

### Release Migrations

```elixir
defmodule MyApp.Release do
  def migrate do
    Application.ensure_all_started(:my_app)
    Ecto.Migrator.run(MyApp.Repo, :up, all: true)
  end
end

# ./bin/my_app eval "MyApp.Release.migrate()"
```

## Generators

**Always prefer generators over hand-writing** — they produce correct, consistent code with migrations, tests, and context functions already wired up.

### Which Generator?

| When you need to... | Use this | What it creates |
|---|---|---|
| Full CRUD with HTML pages | `mix phx.gen.html` | Context, schema, migration, controller, templates, tests |
| JSON API endpoints | `mix phx.gen.json` | Context, schema, migration, controller, JSON view, tests |
| LiveView CRUD | `mix phx.gen.live` | Context, schema, migration, LiveView, components, tests |
| Business logic only (no web) | `mix phx.gen.context` | Context, schema, migration, context tests |
| Schema + migration only | `mix phx.gen.schema` | Schema module, migration |
| Embedded schema (no table) | `mix phx.gen.embedded` | Schema module only (no migration) |
| Session auth (login/register) | `mix phx.gen.auth` | Full auth system: context, schema, plugs, controllers, LiveViews, tests, migration |
| Channel (WebSocket) | `mix phx.gen.channel` | Channel module, socket setup, JS client |
| Presence tracking | `mix phx.gen.presence` | Presence module |
| Email/SMS notifications | `mix phx.gen.notifier` | Notifier module with email functions |
| Release + Dockerfile | `mix phx.gen.release --docker` | Dockerfile, release.ex, server script |

### Generator Examples

```bash
# Full HTML CRUD — creates Accounts context, User schema, controller, templates
mix phx.gen.html Accounts User users \
  name:string email:string:unique age:integer role:enum:admin:user

# JSON API — same but with JSON views instead of HTML
mix phx.gen.json Blog Post posts \
  title:string body:text published:boolean user_id:references:users

# LiveView CRUD — generates LiveView modules instead of controllers
mix phx.gen.live Catalog Product products \
  name:string price:decimal description:text category_id:references:categories

# Context only — when adding to an existing context
mix phx.gen.context Accounts Credential credentials \
  email:string:unique provider:string token:string user_id:references:users

# Schema only — when you need just the schema + migration
mix phx.gen.schema Accounts.Session sessions \
  token:binary user_id:references:users

# Embedded schema — for nested data (no DB table)
mix phx.gen.embedded Accounts.Address \
  street:string city:string zip:string country:string

# Auth — generates complete authentication system
mix phx.gen.auth Accounts User users

# Notifier
mix phx.gen.notifier Accounts
```

### Field Types

```bash
# Basic types
name:string               # varchar
body:text                 # text (unlimited)
age:integer               # integer
price:decimal             # numeric/decimal
active:boolean            # boolean
data:binary               # bytea/blob
metadata:map              # jsonb
tags:array:string         # text[]

# Date/Time
birth_date:date           # date
start_time:time           # time
published_at:utc_datetime # timestamp with timezone
updated_at:utc_datetime_usec  # microsecond precision

# References (foreign keys)
user_id:references:users
category_id:references:categories

# Modifiers
email:string:unique       # adds unique index
slug:string:unique:index  # unique + additional index
position:integer:default:0

# Enums (Ecto 3.9+)
status:enum:pending:active:archived
role:enum:admin:user:guest
```

### After Running a Generator

Generators print instructions — always follow them:

```bash
# 1. Add resource to router (generators tell you what to add)
# 2. Run migration
mix ecto.migrate

# 3. If adding to existing context, generators may skip the context file
#    — check if functions were added or if you need to merge manually
```

## Ecto Commands

```bash
# Database
mix ecto.create                   # Create database
mix ecto.drop                     # Drop database (destructive!)
mix ecto.reset                    # Drop + create + migrate + seed

# Migrations
mix ecto.gen.migration AddUserRole   # Generate empty migration
mix ecto.migrate                     # Run pending migrations
mix ecto.rollback                    # Rollback last migration
mix ecto.rollback --step 3           # Rollback last 3 migrations
mix ecto.migrations                  # Show migration status

# Seeds
mix run priv/repo/seeds.exs          # Run seed file
```

### Migration Patterns

```elixir
# Generate: mix ecto.gen.migration CreateProducts
defmodule MyApp.Repo.Migrations.CreateProducts do
  use Ecto.Migration

  def change do
    create table(:products, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :price, :decimal, precision: 10, scale: 2, null: false
      add :status, :string, default: "draft"
      add :metadata, :map, default: %{}
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:products, [:user_id])
    create unique_index(:products, [:name, :user_id])
  end
end
```

### Common Migration Operations

```elixir
# Add column
alter table(:users) do
  add :role, :string, default: "user"
end

# Remove column
alter table(:users) do
  remove :legacy_field
end

# Rename column
rename table(:users), :name, to: :full_name

# Add index
create index(:posts, [:user_id, :published_at])
create unique_index(:users, [:email])

# Data migration (use raw SQL, never app schemas)
execute "UPDATE users SET role = 'admin' WHERE is_admin = true"

# Enum type (Postgres)
execute "CREATE TYPE user_role AS ENUM ('admin', 'user', 'guest')", "DROP TYPE user_role"
alter table(:users) do
  add :role, :user_role, default: "user"
end
```

## Server Commands

```bash
mix phx.server                    # Start dev server
iex -S mix phx.server             # Start with IEx
mix phx.routes                    # List all routes
mix phx.routes MyAppWeb.Router    # Specific router
mix phx.gen.secret                # Generate secret key
mix phx.digest                    # Static asset digest (prod)
```

## Anti-Patterns (BAD/GOOD)

### Context Bypass

```elixir
# BAD: Accessing Repo directly in controller
def show(conn, %{"id" => id}) do
  user = Repo.get!(User, id)
end

# GOOD: Use context
def show(conn, %{"id" => id}) do
  user = Accounts.get_user!(id)
end
```

### N+1 Queries

```elixir
# BAD: Lazy load in loop
users = Accounts.list_users()
Enum.map(users, fn u -> u.department.name end)  # N+1!

# GOOD: Preload
users = Accounts.list_users() |> Repo.preload(:department)
```

### Router Namespace Duplication

```elixir
# BAD: Redundant namespace
scope "/admin", MyAppWeb.Admin do
  live "/users", MyAppWeb.Admin.UserLive
end

# GOOD: Scope provides alias
scope "/admin", MyAppWeb.Admin do
  live "/users", UserLive
end
```

### Template Deprecations

```elixir
# BAD
~E"..."                           # Use ~H
Phoenix.HTML.form_for(...)        # Use Phoenix.Component.form
<.form let={f}>                   # Use @form[:field]
<%= if x do %>...<% else if y do %>  # No else if — use cond
```

### Mix.env() in Runtime Code

```elixir
# BAD: Mix.env() is not available in releases — crashes in production!
def send_notification(user) do
  if Mix.env() == :prod do
    Mailer.deliver(user)
  end
end

# GOOD: Use compile-time config or Application.get_env
@env Application.compile_env(:my_app, :env)
def send_notification(user) do
  if @env == :prod, do: Mailer.deliver(user)
end

# GOOD: Or runtime config
def send_notification(user) do
  if Application.get_env(:my_app, :send_emails), do: Mailer.deliver(user)
end
```

### Hardcoded Fallback Secrets

```elixir
# BAD: Hardcoded secret ships in source control
secret_key_base: System.get_env("SECRET_KEY_BASE") || "hardcoded_fallback_value"

# GOOD: Fail loudly if secret is missing
secret_key_base: System.fetch_env!("SECRET_KEY_BASE")
```

### rescue for Control Flow

```elixir
# BAD: Using rescue to handle expected "not found" case
def on_mount(:ensure_authenticated, _params, session, socket) do
  user = Accounts.get_user!(session["user_id"])
  {:cont, assign(socket, current_user: user)}
rescue
  Ecto.NoResultsError -> {:halt, redirect(socket, to: ~p"/login")}
end

# GOOD: Pattern match on nil — expected case, not exceptional
def on_mount(:ensure_authenticated, _params, session, socket) do
  case Accounts.get_user(session["user_id"]) do
    %User{} = user -> {:cont, assign(socket, current_user: user)}
    nil -> {:halt, redirect(socket, to: ~p"/login")}
  end
end
```

### Bang Functions in Context Logic

```elixir
# BAD: Crashes the process on failure
def process_video(%Video{} = video) do
  updated = Repo.update!(Video.changeset(video, %{status: :processing}))  # Crash!
  Repo.insert!(Thumbnail.changeset(%{video_id: updated.id}))              # Crash!
end

# GOOD: Return ok/error tuples, let caller decide
def process_video(%Video{} = video) do
  Ecto.Multi.new()
  |> Ecto.Multi.update(:video, Video.changeset(video, %{status: :processing}))
  |> Ecto.Multi.insert(:thumbnail, fn %{video: v} ->
    Thumbnail.changeset(%Thumbnail{}, %{video_id: v.id})
  end)
  |> Repo.transaction()
end
```

### Process.sleep for Rate Limiting

```elixir
# BAD: Blocks the GenServer process — no other messages processed during sleep
def handle_info(:geocode_batch, state) do
  Enum.each(state.pending, fn addr ->
    geocode(addr)
    Process.sleep(1500)  # Blocks for N * 1.5 seconds!
  end)
  {:noreply, state}
end

# GOOD: Self-scheduling with send_after — process remains responsive
def handle_info(:geocode_next, %{pending: [addr | rest]} = state) do
  geocode(addr)
  Process.send_after(self(), :geocode_next, 1500)
  {:noreply, %{state | pending: rest}}
end

def handle_info(:geocode_next, %{pending: []} = state) do
  {:noreply, state}
end
```

### Context Coupling

```elixir
# BAD: Contexts calling each other directly — creates hidden dependencies
defmodule MyApp.Settings do
  def update_car_settings(car, attrs) do
    # ...update...
    MyApp.Vehicles.restart(car.id)  # Tight coupling!
  end
end

# GOOD: Use PubSub — contexts stay independent
defmodule MyApp.Settings do
  def update_car_settings(car, attrs) do
    # ...update...
    Phoenix.PubSub.broadcast(MyApp.PubSub, "settings:#{car.id}", {:settings_changed, car.id})
  end
end

# Vehicles subscribes and handles independently
def handle_info({:settings_changed, car_id}, state) do
  {:noreply, restart_car(state, car_id)}
end
```

### Overly Permissive CORS

```elixir
# BAD: Allows any origin — credential/token theft via malicious sites
plug Corsica, origins: "*"

# GOOD: Explicit allowed origins
plug Corsica, origins: ["https://app.example.com", "https://staging.example.com"]
```

### Mutating Config at Runtime

```elixir
# BAD: Not safe in concurrent OTP — races between processes
Application.put_env(:my_app, :mailer, adapter: Swoosh.Adapters.SMTP)

# GOOD: Set config at startup in Application.start or runtime.exs
# If truly dynamic, use a GenServer or ETS table
```

### Silencing Unexpected Messages

```elixir
# BAD: Silently swallows messages — hides bugs
def handle_info(_msg, socket), do: {:noreply, socket}

# GOOD: Log unexpected messages
def handle_info(msg, socket) do
  Logger.warning("Unexpected message in #{__MODULE__}: #{inspect(msg)}")
  {:noreply, socket}
end
```

## Supporting Files

- **[reference.md](reference.md)** — Plug.Conn functions, router DSL, generator field types, channel patterns, context pattern reference, component attribute types, session configuration
- **[examples.md](examples.md)** — Complete plug examples, context module template, channel implementation, controller examples, security configuration, component examples, anti-patterns gallery

## Related Skills

- **[phoenix-liveview](../phoenix-liveview/SKILL.md)** — LiveView lifecycle, components, forms, streams, async, hooks, JS commands. Key: LiveView builds on Phoenix — use contexts for data, PubSub for broadcasts.
- **[elixir](../elixir/SKILL.md)** — Pattern matching, pipelines, ok/error tuples, Ecto. Key: Phoenix controllers/contexts are Elixir modules — use multi-clause functions, not if/else chains.
- **[elixir-testing](../elixir-testing/SKILL.md)** — ExUnit, Mox, ConnCase. Key: Phoenix controller tests use `ConnCase`, LiveView tests use `Phoenix.LiveViewTest`.
- **[tailwind](../tailwind/SKILL.md)** — Utility classes, dark mode, responsive design. Key: Phoenix 1.8 uses Tailwind v4 — no config file needed.
- **[elixir-deployment](../elixir-deployment/SKILL.md)** — Mix releases, Docker, cloud providers, Kubernetes, production patterns.
- **[ash](../ash/SKILL.md)** — Alternative to hand-written contexts: resources, domains, actions, policies. Key: Ash can replace Phoenix contexts with declarative resource definitions.
