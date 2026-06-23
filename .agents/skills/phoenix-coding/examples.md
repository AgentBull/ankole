# Phoenix Examples & Anti-Patterns

## Complete Plug Examples

### Authentication Plug

```elixir
defmodule MyAppWeb.Plugs.RequireAuth do
  @moduledoc "Requires authenticated user in session"
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    if conn.assigns[:current_user] do
      conn
    else
      conn
      |> put_flash(:error, "You must be logged in")
      |> redirect(to: ~p"/login")
      |> halt()
    end
  end
end

# Usage in router
pipeline :authenticated do
  plug MyAppWeb.Plugs.RequireAuth
end

scope "/dashboard", MyAppWeb do
  pipe_through [:browser, :authenticated]
  live "/", DashboardLive
end
```

### Role-Based Authorization Plug

```elixir
defmodule MyAppWeb.Plugs.RequireRole do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts) do
    %{roles: Keyword.fetch!(opts, :roles)}
  end

  def call(conn, %{roles: allowed_roles}) do
    user = conn.assigns[:current_user]

    if user && user.role in allowed_roles do
      conn
    else
      conn
      |> put_status(:forbidden)
      |> put_view(MyAppWeb.ErrorHTML)
      |> render(:"403")
      |> halt()
    end
  end
end

# Usage
plug MyAppWeb.Plugs.RequireRole, roles: [:admin, :moderator]
```

### Rate Limiting Plug

```elixir
defmodule MyAppWeb.Plugs.RateLimit do
  import Plug.Conn
  import Phoenix.Controller

  @max_requests 100
  @window_ms 60_000

  def init(opts), do: opts

  def call(conn, _opts) do
    key = rate_limit_key(conn)

    case check_rate(key) do
      {:ok, _count} ->
        conn

      {:error, :rate_limited} ->
        conn
        |> put_status(:too_many_requests)
        |> json(%{error: "Rate limit exceeded"})
        |> halt()
    end
  end

  defp rate_limit_key(conn) do
    ip = conn.remote_ip |> :inet.ntoa() |> to_string()
    "rate_limit:#{ip}"
  end

  defp check_rate(key) do
    # Implement with ETS or Redis
    {:ok, 1}
  end
end
```

### API Token Plug

```elixir
defmodule MyAppWeb.Plugs.ApiAuth do
  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, user} <- verify_token(token) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> json(%{error: "Invalid or missing token"})
        |> halt()
    end
  end

  defp verify_token(token) do
    case MyApp.Accounts.get_user_by_api_token(token) do
      nil -> {:error, :invalid}
      user -> {:ok, user}
    end
  end
end
```

## Context Module Template

### Complete Context with All Operations

```elixir
defmodule MyApp.Blog do
  @moduledoc "The Blog context - manages posts and comments"

  import Ecto.Query
  alias MyApp.Repo
  alias MyApp.Blog.{Post, Comment}

  # =============
  # Posts
  # =============

  def list_posts(opts \\ []) do
    Post
    |> apply_filters(opts)
    |> apply_sorting(opts)
    |> apply_pagination(opts)
    |> Repo.all()
  end

  def list_published_posts do
    from(p in Post,
      where: p.published == true,
      order_by: [desc: p.published_at]
    )
    |> Repo.all()
  end

  def get_post(id), do: Repo.get(Post, id)
  def get_post!(id), do: Repo.get!(Post, id)

  def get_post_with_comments!(id) do
    Post
    |> Repo.get!(id)
    |> Repo.preload(comments: :author)
  end

  def create_post(attrs \\ %{}) do
    %Post{}
    |> Post.changeset(attrs)
    |> Repo.insert()
    |> broadcast(:post_created)
  end

  def update_post(%Post{} = post, attrs) do
    post
    |> Post.changeset(attrs)
    |> Repo.update()
    |> broadcast(:post_updated)
  end

  def delete_post(%Post{} = post) do
    Repo.delete(post)
    |> broadcast(:post_deleted)
  end

  def change_post(%Post{} = post, attrs \\ %{}) do
    Post.changeset(post, attrs)
  end

  def publish_post(%Post{} = post) do
    post
    |> Post.publish_changeset()
    |> Repo.update()
  end

  # =============
  # Comments
  # =============

  def list_comments_for_post(post_id) do
    from(c in Comment,
      where: c.post_id == ^post_id,
      order_by: [asc: c.inserted_at],
      preload: :author
    )
    |> Repo.all()
  end

  def create_comment(%Post{} = post, attrs) do
    %Comment{}
    |> Comment.changeset(attrs)
    |> Ecto.Changeset.put_assoc(:post, post)
    |> Repo.insert()
  end

  # =============
  # PubSub
  # =============

  @topic "blog"

  def subscribe do
    Phoenix.PubSub.subscribe(MyApp.PubSub, @topic)
  end

  defp broadcast({:ok, record}, event) do
    Phoenix.PubSub.broadcast(MyApp.PubSub, @topic, {event, record})
    {:ok, record}
  end

  defp broadcast({:error, _} = error, _event), do: error

  # =============
  # Query Helpers
  # =============

  defp apply_filters(query, opts) do
    Enum.reduce(opts[:filters] || [], query, fn
      {:author_id, id}, q -> where(q, [p], p.author_id == ^id)
      {:published, bool}, q -> where(q, [p], p.published == ^bool)
      {:tag, tag}, q -> where(q, [p], ^tag in p.tags)
      _, q -> q
    end)
  end

  defp apply_sorting(query, opts) do
    case opts[:sort] do
      :newest -> order_by(query, [p], desc: p.inserted_at)
      :oldest -> order_by(query, [p], asc: p.inserted_at)
      :title -> order_by(query, [p], asc: p.title)
      _ -> query
    end
  end

  defp apply_pagination(query, opts) do
    page = opts[:page] || 1
    per_page = opts[:per_page] || 20

    query
    |> limit(^per_page)
    |> offset(^((page - 1) * per_page))
  end
end
```

## Channel Implementation

### Full-Featured Room Channel

```elixir
defmodule MyAppWeb.RoomChannel do
  use Phoenix.Channel
  alias MyAppWeb.Presence

  @impl true
  def join("room:" <> room_id, params, socket) do
    if authorized?(socket.assigns.current_user, room_id) do
      send(self(), :after_join)

      {:ok,
       socket
       |> assign(:room_id, room_id)
       |> assign(:typing, false)}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    # Track presence
    {:ok, _} =
      Presence.track(socket, socket.assigns.current_user.id, %{
        online_at: inspect(System.system_time(:second)),
        typing: false
      })

    # Send current presence state
    push(socket, "presence_state", Presence.list(socket))

    # Send recent messages
    messages = Chat.list_recent_messages(socket.assigns.room_id, limit: 50)
    push(socket, "message_history", %{messages: messages})

    {:noreply, socket}
  end

  @impl true
  def handle_in("new_message", %{"body" => body}, socket) do
    user = socket.assigns.current_user
    room_id = socket.assigns.room_id

    case Chat.create_message(room_id, user, body) do
      {:ok, message} ->
        broadcast!(socket, "new_message", %{
          id: message.id,
          body: message.body,
          user: %{id: user.id, name: user.name},
          inserted_at: message.inserted_at
        })

        {:reply, :ok, socket}

      {:error, changeset} ->
        {:reply, {:error, %{errors: format_errors(changeset)}}, socket}
    end
  end

  def handle_in("typing", %{"typing" => typing}, socket) do
    Presence.update(socket, socket.assigns.current_user.id, fn meta ->
      Map.put(meta, :typing, typing)
    end)

    {:noreply, assign(socket, :typing, typing)}
  end

  def handle_in("ping", _params, socket) do
    {:reply, {:ok, %{pong: System.system_time(:millisecond)}}, socket}
  end

  defp authorized?(user, room_id) do
    Chat.user_can_access_room?(user, room_id)
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
  end
end
```

## Controller Examples

### Authentication Controller

```elixir
defmodule MyAppWeb.SessionController do
  use MyAppWeb, :controller

  alias MyApp.Accounts

  def new(conn, _params) do
    render(conn, :new)
  end

  def create(conn, %{"session" => %{"email" => email, "password" => password}}) do
    case Accounts.authenticate_user(email, password) do
      {:ok, user} ->
        conn
        |> delete_csrf_token()  # Prevent session fixation
        |> put_session(:user_id, user.id)
        |> configure_session(renew: true)
        |> put_flash(:info, "Welcome back!")
        |> redirect(to: ~p"/dashboard")

      {:error, :invalid_credentials} ->
        conn
        |> put_flash(:error, "Invalid email or password")
        |> render(:new)
    end
  end

  def delete(conn, _params) do
    conn
    |> clear_session()
    |> put_flash(:info, "Logged out successfully")
    |> redirect(to: ~p"/")
  end
end
```

### Form Controller with Validation

```elixir
defmodule MyAppWeb.UserController do
  use MyAppWeb, :controller

  alias MyApp.Accounts
  alias MyApp.Accounts.User

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

  def edit(conn, %{"id" => id}) do
    user = Accounts.get_user!(id)
    changeset = Accounts.change_user(user)
    render(conn, :edit, user: user, changeset: changeset)
  end

  def update(conn, %{"id" => id, "user" => user_params}) do
    user = Accounts.get_user!(id)

    case Accounts.update_user(user, user_params) do
      {:ok, user} ->
        conn
        |> put_flash(:info, "User updated successfully.")
        |> redirect(to: ~p"/users/#{user}")

      {:error, %Ecto.Changeset{} = changeset} ->
        render(conn, :edit, user: user, changeset: changeset)
    end
  end
end
```

### API Controller with JSON

```elixir
defmodule MyAppWeb.Api.PostController do
  use MyAppWeb, :controller

  alias MyApp.Blog
  alias MyApp.Blog.Post

  action_fallback MyAppWeb.FallbackController

  def index(conn, params) do
    posts = Blog.list_posts(
      page: params["page"] || 1,
      per_page: params["per_page"] || 20,
      filters: parse_filters(params)
    )

    render(conn, :index, posts: posts)
  end

  def show(conn, %{"id" => id}) do
    post = Blog.get_post!(id)
    render(conn, :show, post: post)
  end

  def create(conn, %{"post" => post_params}) do
    with {:ok, %Post{} = post} <- Blog.create_post(post_params) do
      conn
      |> put_status(:created)
      |> put_resp_header("location", ~p"/api/posts/#{post}")
      |> render(:show, post: post)
    end
  end

  def update(conn, %{"id" => id, "post" => post_params}) do
    post = Blog.get_post!(id)

    with {:ok, %Post{} = post} <- Blog.update_post(post, post_params) do
      render(conn, :show, post: post)
    end
  end

  def delete(conn, %{"id" => id}) do
    post = Blog.get_post!(id)

    with {:ok, %Post{}} <- Blog.delete_post(post) do
      send_resp(conn, :no_content, "")
    end
  end

  defp parse_filters(params) do
    []
    |> maybe_add_filter(:author_id, params["author_id"])
    |> maybe_add_filter(:published, params["published"])
  end

  defp maybe_add_filter(filters, _key, nil), do: filters
  defp maybe_add_filter(filters, key, value), do: [{key, value} | filters]
end
```

### Fallback Controller

```elixir
defmodule MyAppWeb.FallbackController do
  use MyAppWeb, :controller

  def call(conn, {:error, %Ecto.Changeset{} = changeset}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: MyAppWeb.ChangesetJSON)
    |> render(:error, changeset: changeset)
  end

  def call(conn, {:error, :not_found}) do
    conn
    |> put_status(:not_found)
    |> put_view(json: MyAppWeb.ErrorJSON)
    |> render(:"404")
  end

  def call(conn, {:error, :unauthorized}) do
    conn
    |> put_status(:unauthorized)
    |> put_view(json: MyAppWeb.ErrorJSON)
    |> render(:"401")
  end
end
```

## Security Configuration Examples

### Endpoint Security

```elixir
# endpoint.ex
defmodule MyAppWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :my_app

  # Session configuration
  @session_options [
    store: :cookie,
    key: "_my_app_key",
    signing_salt: "your_signing_salt",
    encryption_salt: "your_encryption_salt",
    same_site: "Strict",
    http_only: true,
    secure: true,  # Requires HTTPS
    max_age: 60 * 60 * 24 * 7  # 7 days
  ]

  plug Plug.Session, @session_options

  # Force SSL in production
  if Mix.env() == :prod do
    plug Plug.SSL, rewrite_on: [:x_forwarded_proto]
  end
end
```

### Content Security Policy

```elixir
defmodule MyAppWeb.Plugs.ContentSecurityPolicy do
  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    csp = """
    default-src 'self';
    script-src 'self' 'unsafe-inline' https://cdn.example.com;
    style-src 'self' 'unsafe-inline';
    img-src 'self' data: https:;
    font-src 'self' https://fonts.gstatic.com;
    connect-src 'self' wss://#{conn.host};
    frame-ancestors 'none';
    base-uri 'self';
    form-action 'self';
    """
    |> String.replace("\n", " ")

    put_resp_header(conn, "content-security-policy", csp)
  end
end
```

## Component Examples

### Table Component with Slots

```elixir
attr :id, :string, required: true
attr :rows, :list, required: true
attr :row_click, :any, default: nil

slot :col, required: true do
  attr :label, :string, required: true
  attr :class, :string
end

def table(assigns) do
  ~H"""
  <table id={@id} class="min-w-full divide-y divide-gray-200">
    <thead class="bg-gray-50">
      <tr>
        <th :for={col <- @col} class={["px-6 py-3 text-left text-xs font-medium text-gray-500 uppercase", col[:class]]}>
          {col.label}
        </th>
      </tr>
    </thead>
    <tbody class="bg-white divide-y divide-gray-200">
      <tr
        :for={row <- @rows}
        id={"#{@id}-#{row.id}"}
        class={@row_click && "cursor-pointer hover:bg-gray-50"}
        phx-click={@row_click && @row_click.(row)}
      >
        <td :for={col <- @col} class={["px-6 py-4 whitespace-nowrap", col[:class]]}>
          {render_slot(col, row)}
        </td>
      </tr>
    </tbody>
  </table>
  """
end
```

### Modal Component

```elixir
attr :id, :string, required: true
attr :show, :boolean, default: false
attr :on_cancel, Phoenix.LiveView.JS, default: %JS{}

slot :inner_block, required: true

def modal(assigns) do
  ~H"""
  <div
    id={@id}
    phx-mounted={@show && show_modal(@id)}
    phx-remove={hide_modal(@id)}
    class="relative z-50 hidden"
  >
    <div id={"#{@id}-bg"} class="fixed inset-0 bg-gray-500/75 transition-opacity" />
    <div class="fixed inset-0 overflow-y-auto">
      <div class="flex min-h-full items-center justify-center p-4">
        <div
          id={"#{@id}-container"}
          phx-click-away={JS.exec(@on_cancel, "phx-remove")}
          class="relative bg-white rounded-lg shadow-xl max-w-lg w-full"
        >
          <button
            phx-click={JS.exec(@on_cancel, "phx-remove")}
            class="absolute top-4 right-4"
          >
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
  </div>
  """
end

defp show_modal(id) do
  %JS{}
  |> JS.show(to: "##{id}")
  |> JS.show(to: "##{id}-bg", transition: {"ease-out duration-300", "opacity-0", "opacity-100"})
  |> JS.show(to: "##{id}-container", transition: {"ease-out duration-300", "opacity-0 scale-95", "opacity-100 scale-100"})
  |> JS.focus_first(to: "##{id}-container")
end

defp hide_modal(id) do
  %JS{}
  |> JS.hide(to: "##{id}-bg", transition: {"ease-in duration-200", "opacity-100", "opacity-0"})
  |> JS.hide(to: "##{id}-container", transition: {"ease-in duration-200", "opacity-100 scale-100", "opacity-0 scale-95"})
  |> JS.hide(to: "##{id}", transition: {"block", "block", "hidden"})
  |> JS.pop_focus()
end
```

## Anti-Patterns to Avoid

### Context Bypass

```elixir
# BAD: Direct repo access in controller
def show(conn, %{"id" => id}) do
  user = MyApp.Repo.get!(User, id)
  render(conn, :show, user: user)
end

# GOOD: Use context
def show(conn, %{"id" => id}) do
  user = Accounts.get_user!(id)
  render(conn, :show, user: user)
end
```

### N+1 Queries

```elixir
# BAD: Query in template/loop
<%= for post <- @posts do %>
  <p>Author: <%= post.author.name %></p>  <%# N+1! %>
<% end %>

# GOOD: Preload in context
def list_posts_with_authors do
  Post
  |> preload(:author)
  |> Repo.all()
end
```

### Atom Table Exhaustion

```elixir
# BAD: Converting user input to atoms
def update(conn, %{"status" => status}) do
  atom_status = String.to_atom(status)  # DANGEROUS!
end

# GOOD: Validate against known values
@valid_statuses ~w(pending active archived)

def update(conn, %{"status" => status}) when status in @valid_statuses do
  atom_status = String.to_existing_atom(status)
end
```

### Router Namespace Duplication

```elixir
# BAD: Redundant namespace
scope "/admin", MyAppWeb.Admin do
  live "/users", MyAppWeb.Admin.UserLive  # Redundant!
end

# GOOD: Let scope handle it
scope "/admin", MyAppWeb.Admin do
  live "/users", UserLive  # -> MyAppWeb.Admin.UserLive
end
```

### Missing CSRF Protection for Login

```elixir
# BAD: Not rotating CSRF token
def create(conn, %{"session" => params}) do
  case authenticate(params) do
    {:ok, user} ->
      conn
      |> put_session(:user_id, user.id)  # Session fixation risk!
      |> redirect(to: ~p"/dashboard")
  end
end

# GOOD: Delete CSRF token after login
def create(conn, %{"session" => params}) do
  case authenticate(params) do
    {:ok, user} ->
      conn
      |> delete_csrf_token()  # Prevent session fixation
      |> configure_session(renew: true)
      |> put_session(:user_id, user.id)
      |> redirect(to: ~p"/dashboard")
  end
end
```

### Blocking Operations in Plugs

```elixir
# BAD: Slow external call in plug
def call(conn, _opts) do
  # This blocks every request!
  user_data = HTTPClient.get!("https://slow-api.com/user")
  assign(conn, :external_data, user_data)
end

# GOOD: Cache or defer
def call(conn, _opts) do
  user_id = conn.assigns.current_user.id

  case Cache.get("user_data:#{user_id}") do
    nil -> conn  # Fetch async later if needed
    data -> assign(conn, :external_data, data)
  end
end
```

### Template Anti-Patterns

```elixir
# BAD: Using deprecated syntax
~E"""..."""  # Use ~H

# BAD: form_for
<%= form_for @changeset, ~p"/users", fn f -> %>

# GOOD: Phoenix.Component.form
<.form for={@form} action={~p"/users"}>

# BAD: let binding
<.form for={@form} let={f}>

# GOOD: Direct access
<.input field={@form[:email]} />

# BAD: else if
<%= if x do %>...<% else if y do %>...<% end %>

# GOOD: cond
<%= cond do %>
  <% x -> %>...
  <% y -> %>...
<% end %>

# BAD: Enum.each
<% Enum.each(@items, fn item -> %>
  <div>{item.name}</div>
<% end) %>

# GOOD: for comprehension
<%= for item <- @items do %>
  <div>{item.name}</div>
<% end %>
```

### Class List Anti-Patterns

```elixir
# BAD: String interpolation for conditional classes
<div class="px-2 <%= if @active, do: "bg-blue-500" %>">

# GOOD: List syntax
<div class={["px-2", @active && "bg-blue-500"]}>

# BAD: Ternary without list
<div class={"px-2 #{if @active, do: "bg-blue-500", else: "bg-gray-500"}"}>

# GOOD: Full list syntax
<div class={[
  "px-2",
  if(@active, do: "bg-blue-500", else: "bg-gray-500")
]}>
```

### Security Anti-Patterns

```elixir
# BAD: Trusting client data for authorization
def delete(conn, %{"user_id" => user_id}) do
  user = Repo.get!(User, user_id)
  Repo.delete!(user)  # No authorization check!
end

# GOOD: Check authorization
def delete(conn, %{"id" => id}) do
  current_user = conn.assigns.current_user
  user = Accounts.get_user!(id)

  if Accounts.can_delete?(current_user, user) do
    Accounts.delete_user(user)
    redirect(conn, to: ~p"/users")
  else
    conn
    |> put_status(:forbidden)
    |> render(:error)
  end
end

# BAD: Mass assignment without filtering
def update(conn, %{"user" => user_params}) do
  user
  |> User.changeset(user_params)  # Accepts all params!
  |> Repo.update()
end

# GOOD: Explicit attribute acceptance
def changeset(user, attrs) do
  user
  |> cast(attrs, [:name, :email])  # Only allow specific fields
  |> validate_required([:name, :email])
end
```
