# Phoenix Quick Reference

## Plug Cheatsheet

### Function Plug

```elixir
def my_plug(conn, opts) do
  # opts are passed from plug declaration
  conn
  |> assign(:key, value)
  |> put_resp_header("x-custom", "value")
end

# Usage in router/controller
plug :my_plug, some: "option"
```

### Module Plug

```elixir
defmodule MyApp.Plugs.Authenticate do
  import Plug.Conn

  def init(opts), do: opts  # Compile time

  def call(conn, opts) do   # Runtime
    if authorized?(conn, opts) do
      conn
    else
      conn
      |> put_status(:unauthorized)
      |> Phoenix.Controller.put_view(MyAppWeb.ErrorJSON)
      |> Phoenix.Controller.render(:error, message: "Unauthorized")
      |> halt()
    end
  end
end

# Usage
plug MyApp.Plugs.Authenticate, roles: [:admin]
```

### Plug.Conn Functions

```elixir
# Assigns
assign(conn, :user, user)
conn.assigns.user

# Response
put_status(conn, :ok)              # 200
put_status(conn, :created)         # 201
put_status(conn, :not_found)       # 404
put_status(conn, 422)              # Numeric

# Headers
put_resp_header(conn, "x-custom", "value")
get_req_header(conn, "authorization")  # Returns list

# Session
put_session(conn, :user_id, user.id)
get_session(conn, :user_id)
delete_session(conn, :user_id)
clear_session(conn)
configure_session(conn, renew: true)

# Response body
send_resp(conn, 200, "OK")
json(conn, %{status: "ok"})        # In controller
html(conn, "<h1>Hello</h1>")       # In controller

# Halting
halt(conn)  # Stops plug pipeline
```

## Router DSL Reference

### Route Macros

```elixir
# Basic routes
get "/path", Controller, :action
post "/path", Controller, :action
put "/path", Controller, :action
patch "/path", Controller, :action
delete "/path", Controller, :action
options "/path", Controller, :action

# Match all methods
match :*, "/path", Controller, :action

# Resources (REST)
resources "/users", UserController
resources "/users", UserController, only: [:index, :show]
resources "/users", UserController, except: [:delete]

# Nested resources
resources "/users", UserController do
  resources "/posts", PostController
end

# LiveView
live "/dashboard", DashboardLive
live "/users/:id", UserLive, :show
live "/users/:id/edit", UserLive, :edit

# Forward to another router
forward "/admin", MyAppWeb.AdminRouter
```

### Scopes

```elixir
# Basic scope
scope "/api", MyAppWeb.Api do
  pipe_through :api

  resources "/users", UserController
end

# Nested scope
scope "/api", MyAppWeb.Api, as: :api do
  scope "/v1", V1 do
    resources "/users", UserController  # MyAppWeb.Api.V1.UserController
  end
end

# Without controller namespace
scope "/", MyAppWeb do
  pipe_through :browser
  get "/", PageController, :home
end
```

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

pipeline :authenticated do
  plug MyApp.Plugs.RequireAuth
end

# Stacking pipelines
scope "/" do
  pipe_through [:browser, :authenticated]
end
```

## Common Pipelines

### Browser Pipeline

```elixir
pipeline :browser do
  plug :accepts, ["html"]
  plug :fetch_session
  plug :fetch_live_flash
  plug :put_root_layout, html: {MyAppWeb.Layouts, :root}
  plug :protect_from_forgery
  plug :put_secure_browser_headers
  plug :fetch_current_user  # Custom auth plug
end
```

### API Pipeline

```elixir
pipeline :api do
  plug :accepts, ["json"]
  plug MyApp.Plugs.ApiAuth
end

pipeline :api_authenticated do
  plug MyApp.Plugs.RequireApiToken
end
```

### LiveView Pipeline

```elixir
# For authenticated LiveViews
pipeline :live_auth do
  plug :fetch_session
  plug :fetch_current_user
end

scope "/", MyAppWeb do
  pipe_through [:browser, :live_auth]
  live_session :authenticated, on_mount: [MyAppWeb.LiveAuth] do
    live "/dashboard", DashboardLive
  end
end
```

## Security Headers Reference

### put_secure_browser_headers

Default headers set:
```
x-frame-options: SAMEORIGIN
x-content-type-options: nosniff
x-xss-protection: 1; mode=block
```

### Custom Security Headers

```elixir
def put_csp_header(conn, _opts) do
  put_resp_header(conn, "content-security-policy",
    "default-src 'self'; script-src 'self' 'unsafe-inline'")
end

# In pipeline
plug :put_csp_header
```

### Session Configuration

```elixir
plug Plug.Session,
  store: :cookie,
  key: "_my_app_key",
  signing_salt: "secret_salt",
  encryption_salt: "encrypt_salt",
  same_site: "Strict",       # Strict, Lax, or None
  http_only: true,           # JS can't access
  secure: true,              # HTTPS only
  max_age: 86400 * 7         # 7 days in seconds
```

## Mix phx.* Commands

### Server

```bash
mix phx.server                    # Start server
iex -S mix phx.server             # With IEx shell
MIX_ENV=prod mix phx.server       # Production mode
```

### Routes

```bash
mix phx.routes                    # All routes
mix phx.routes MyAppWeb.Router    # Specific router
```

### Generators

```bash
# HTML (controller + views + templates)
mix phx.gen.html Accounts User users \
  name:string email:string:unique age:integer

# JSON API
mix phx.gen.json Accounts User users \
  name:string email:string:unique

# LiveView
mix phx.gen.live Accounts User users \
  name:string email:string:unique

# Context only (no web layer)
mix phx.gen.context Accounts User users \
  name:string email:string

# Schema only
mix phx.gen.schema Accounts.User users \
  name:string email:string

# Authentication
mix phx.gen.auth Accounts User users

# Embedded schema
mix phx.gen.embedded Accounts.Profile \
  bio:string website:string

# Channel
mix phx.gen.channel Room

# Presence
mix phx.gen.presence

# Notifier (email/SMS)
mix phx.gen.notifier Accounts
```

### Release

```bash
mix phx.gen.release              # Release files
mix phx.gen.release --docker     # With Dockerfile
mix phx.gen.secret               # Generate secret key
```

### Digest

```bash
mix phx.digest                   # Generate static asset digest
mix phx.digest.clean             # Remove old digests
```

## Generator Field Types

```bash
# Basic types
name:string
age:integer
price:decimal
active:boolean
body:text
data:binary
metadata:map
tags:array:string

# Dates/Times
birth_date:date
start_time:time
published_at:datetime
created_at:utc_datetime
updated_at:utc_datetime_usec
inserted_at:naive_datetime

# References
user_id:references:users
category_id:references:categories

# Modifiers
email:string:unique
slug:string:unique:index
position:integer:default:0

# Enums (Ecto 3.9+)
status:enum:pending:active:archived
```

## Channel Message Patterns

### Server Side

```elixir
defmodule MyAppWeb.RoomChannel do
  use Phoenix.Channel

  # Join with authorization
  def join("room:" <> room_id, params, socket) do
    if authorized?(socket, room_id) do
      send(self(), :after_join)
      {:ok, assign(socket, :room_id, room_id)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  # Handle incoming messages
  def handle_in("new_msg", %{"body" => body}, socket) do
    broadcast!(socket, "new_msg", %{body: body, user: socket.assigns.user})
    {:reply, :ok, socket}
  end

  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: true}}, socket}
  end

  # Handle process messages
  def handle_info(:after_join, socket) do
    push(socket, "presence_state", Presence.list(socket))
    {:noreply, socket}
  end
end
```

### Client Side (JavaScript)

```javascript
let channel = socket.channel("room:123", {})

// Join
channel.join()
  .receive("ok", resp => console.log("Joined", resp))
  .receive("error", resp => console.log("Failed", resp))

// Send message
channel.push("new_msg", {body: "Hello"})
  .receive("ok", resp => console.log("Sent", resp))
  .receive("error", resp => console.log("Error", resp))

// Receive messages
channel.on("new_msg", payload => {
  console.log("New message:", payload.body)
})
```

## Context Pattern Reference

### Standard Context Functions

```elixir
defmodule MyApp.Accounts do
  alias MyApp.Repo
  alias MyApp.Accounts.User

  # List
  def list_users, do: Repo.all(User)
  def list_users(criteria), do: Repo.all(from u in User, where: ^criteria)

  # Get
  def get_user(id), do: Repo.get(User, id)
  def get_user!(id), do: Repo.get!(User, id)
  def get_user_by(attrs), do: Repo.get_by(User, attrs)

  # Create
  def create_user(attrs \\ %{}) do
    %User{}
    |> User.changeset(attrs)
    |> Repo.insert()
  end

  # Update
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  # Delete
  def delete_user(%User{} = user) do
    Repo.delete(user)
  end

  # Change (for forms)
  def change_user(%User{} = user, attrs \\ %{}) do
    User.changeset(user, attrs)
  end
end
```

### Query Helpers

```elixir
import Ecto.Query

def list_active_users do
  from(u in User, where: u.active == true)
  |> Repo.all()
end

def list_users_with_posts do
  User
  |> preload(:posts)
  |> Repo.all()
end

def count_users do
  Repo.aggregate(User, :count)
end
```

## Component Attribute Reference

### Attribute Types

```elixir
attr :name, :string                    # String
attr :count, :integer                  # Integer
attr :price, :float                    # Float
attr :active, :boolean                 # Boolean
attr :data, :map                       # Map
attr :items, :list                     # List
attr :class, :any                      # Any type
attr :user, User                       # Struct type
attr :on_click, Phoenix.LiveView.JS    # JS commands
attr :rest, :global                    # Global HTML attrs
```

### Attribute Options

```elixir
attr :name, :string,
  required: true,                      # Must be provided
  default: "Anonymous",                # Default value
  values: ["sm", "md", "lg"],          # Allowed values
  doc: "The user's name",              # Documentation
  examples: ["John", "Jane"]           # Example values
```

### Slot Definition

```elixir
# Simple slot
slot :inner_block

# Required slot
slot :header, required: true

# Slot with attributes
slot :col do
  attr :label, :string, required: true
  attr :class, :string
end

# Multiple items in slot
slot :item, doc: "Repeated for each item"
```
