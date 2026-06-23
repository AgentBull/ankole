# Elixir Testing Examples

Complete working examples based on production patterns from Elixir stdlib, Phoenix, Ecto, Mox, and JSON round-trip tests. Each example cites its production source.

---

## 1. Test Infrastructure (CaseTemplate)

Based on Phoenix installer templates (`phoenix/installer/templates/phx_test/support/conn_case.ex`, `phoenix/installer/templates/phx_ecto/data_case.ex`) and Phoenix channel case (`phoenix/priv/templates/phx.gen.channel/channel_case.ex`).

### test/test_helper.exs

```elixir
ExUnit.start()

# Configure Ecto Sandbox
Ecto.Adapters.SQL.Sandbox.mode(MyApp.Repo, :manual)

# Define Mox mocks (one per external boundary)
Mox.defmock(MyApp.HTTPClient.Mock, for: MyApp.HTTPClient)
Mox.defmock(MyApp.Mailer.Mock, for: MyApp.Mailer)

# Exclude slow/external tests by default
ExUnit.configure(exclude: [:slow, :external])

# Advanced: environment-aware config (from Elixir stdlib test suite)
assert_timeout = String.to_integer(System.get_env("ELIXIR_ASSERT_TIMEOUT") || "200")
ExUnit.start(assert_receive_timeout: assert_timeout)
```

### test/support/data_case.ex

```elixir
defmodule MyApp.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias MyApp.Repo
      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import MyApp.DataCase
      import MyApp.Factory
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    :ok
  end

  def setup_sandbox(tags) do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(MyApp.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
  end

  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts
      |> Keyword.get(String.to_existing_atom(key), key)
      |> to_string()
      end)
    end)
  end
end
```

### test/support/conn_case.ex

```elixir
defmodule MyAppWeb.ConnCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint MyAppWeb.Endpoint
      use MyAppWeb, :verified_routes
      import Plug.Conn
      import Phoenix.ConnTest
      import MyAppWeb.ConnCase
      import MyApp.Factory
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  # From phx.gen.auth — log in user for authenticated tests
  def register_and_log_in_user(%{conn: conn}) do
    user = MyApp.Factory.insert(:user)
    %{conn: log_in_user(conn, user), user: user}
  end

  def log_in_user(conn, user) do
    token = MyApp.Accounts.generate_user_session_token(user)
    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_token, token)
  end
end
```

### test/support/channel_case.ex

```elixir
defmodule MyAppWeb.ChannelCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import MyAppWeb.ChannelCase
      import MyApp.Factory
      @endpoint MyAppWeb.Endpoint
    end
  end

  setup tags do
    MyApp.DataCase.setup_sandbox(tags)
    :ok
  end
end
```

### test/support/factory.ex

```elixir
defmodule MyApp.Factory do
  use ExMachina.Ecto, repo: MyApp.Repo

  alias MyApp.Accounts.User
  alias MyApp.Blog.{Post, Comment}

  def user_factory do
    %User{
      email: sequence(:email, &"user#{&1}@example.com"),
      name: sequence(:name, &"User #{&1}"),
      hashed_password: Bcrypt.hash_pwd_salt("password123"),
      confirmed_at: DateTime.utc_now() |> DateTime.truncate(:second),
      role: :member
    }
  end

  def admin_factory do
    struct!(user_factory(), role: :admin)
  end

  def post_factory do
    %Post{
      title: sequence(:title, &"Post Title #{&1}"),
      body: "Post body with enough content to be valid.",
      slug: sequence(:slug, &"post-slug-#{&1}"),
      published_at: nil,
      author: build(:user)
    }
  end

  def published_post_factory do
    struct!(post_factory(),
      published_at:
        DateTime.utc_now()
        |> DateTime.add(-3600)
        |> DateTime.truncate(:second)
    )
  end

  def comment_factory do
    %Comment{
      body: "A comment on the post.",
      post: build(:post),
      author: build(:user)
    }
  end
end
```

---

## 2. Ecto Sandbox Patterns

Based on `ecto_sql/integration_test/sql/sandbox.exs` — the authoritative Sandbox test suite.

### Checkout/Checkin Rollback

```elixir
# From ecto_sql sandbox tests — demonstrates automatic rollback
test "sandbox rolls back on checkin" do
  Sandbox.checkout(TestRepo)
  assert {:ok, _} = TestRepo.insert(%Post{title: "temp"})
  assert TestRepo.all(Post) != []

  Sandbox.checkin(TestRepo)           # Transaction rolled back
  Sandbox.checkout(TestRepo)
  assert TestRepo.all(Post) == []     # Data gone — isolation preserved
  Sandbox.checkin(TestRepo)
end
```

### Cross-Process Allow

```elixir
# From ecto_sql sandbox tests — allow another process to share DB connection
test "spawned process accesses database via allow" do
  parent = self()

  Task.start_link(fn ->
    Sandbox.checkout(TestRepo)
    Sandbox.allow(TestRepo, self(), parent)
    send(parent, :allowed)
    Process.sleep(:infinity)
  end)

  assert_receive :allowed
  assert TestRepo.all(Post) == []
end
```

### Shared Mode

```elixir
# From ecto_sql sandbox tests — shared ownership for non-async tests
test "shared mode lets any process access connection" do
  parent = self()

  Task.start_link(fn ->
    Sandbox.checkout(TestRepo)
    Sandbox.mode(TestRepo, {:shared, self()})
    send(parent, :shared)
    Process.sleep(:infinity)
  end)

  assert_receive :shared
  assert Task.async(fn -> TestRepo.all(Post) end) |> Task.await() == []
after
  Sandbox.mode(TestRepo, :manual)
end
```

### start_owner! Pattern (Modern Phoenix 1.7+)

```elixir
# From ecto_sql sandbox tests — preferred modern approach
test "start_owner! manages connection lifecycle" do
  owner = Sandbox.start_owner!(TestRepo)
  assert TestRepo.all(Post) == []
  :ok = Sandbox.stop_owner(owner)
  refute Process.alive?(owner)
end

test "start_owner! with shared mode" do
  owner = Sandbox.start_owner!(TestRepo, shared: true)
  # Any process can use the connection
  assert Task.async(fn -> TestRepo.all(Post) end) |> Task.await() == []
  :ok = Sandbox.stop_owner(owner)
end
```

---

## 3. Mox Behaviour-Based Mocking

Based on `mox/test/mox_test.exs` and `mox/test/support/behaviours.ex`.

### Behaviour Definition

```elixir
# Step 1: Define the contract (from Mox test support)
defmodule MyApp.HTTPClient do
  @callback get(url :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback post(url :: String.t(), body :: map()) :: {:ok, map()} | {:error, term()}
end

# Step 2: Real implementation
defmodule MyApp.HTTPClient.Req do
  @behaviour MyApp.HTTPClient

  @impl true
  def get(url) do
    case Req.get(url) do
      {:ok, %{status: 200, body: body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def post(url, body) do
    case Req.post(url, json: body) do
      {:ok, %{status: status, body: resp}} when status in 200..299 -> {:ok, resp}
      {:ok, %{status: status}} -> {:error, {:http_error, status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Expect, Stub, Deny, Allow

```elixir
defmodule MyApp.WeatherTest do
  use ExUnit.Case, async: true
  import Mox

  setup :verify_on_exit!

  # Basic expect (from Mox test suite — expect/3 tests)
  test "fetches weather" do
    expect(MyApp.HTTPClient.Mock, :get, fn url ->
      assert url =~ "london"
      {:ok, %{"temp" => 15}}
    end)
    assert {:ok, %{"temp" => 15}} = MyApp.Weather.fetch("london")
  end

  # Multiple invocations with count (from mox_test.exs line 153)
  test "retries on failure" do
    MyApp.HTTPClient.Mock
    |> expect(:get, 2, fn _url -> {:error, :timeout} end)
    |> expect(:get, fn _url -> {:ok, %{"temp" => 20}} end)

    assert {:ok, _} = MyApp.Weather.fetch_with_retry("london")
  end

  # Stub gives expected calls precedence (from mox_test.exs line 677)
  test "stub with expect override" do
    MyApp.HTTPClient.Mock
    |> stub(:get, fn _url -> {:ok, %{"temp" => 0}} end)
    |> expect(:get, fn _url -> {:ok, %{"temp" => 99}} end)

    # First call uses expect, subsequent calls use stub
    assert {:ok, %{"temp" => 99}} = MyApp.HTTPClient.Mock.get("/first")
    assert {:ok, %{"temp" => 0}} = MyApp.HTTPClient.Mock.get("/second")
  end

  # Deny (from mox_test.exs line 348)
  test "cache hit does not call API" do
    deny(MyApp.HTTPClient.Mock, :get, 1)
    assert {:ok, cached} = MyApp.Weather.fetch_cached("london")
  end

  # stub_with — delegate to real implementation (from mox_test.exs line 749)
  test "stub with real module" do
    stub_with(MyApp.HTTPClient.Mock, MyApp.HTTPClient.InMemory)
    assert {:ok, _} = MyApp.Weather.fetch("london")
  end
end
```

### Multi-Process Mox

```elixir
# Allow pattern (from mox_test.exs line 840)
test "async task uses mock" do
  parent = self()
  expect(MyApp.HTTPClient.Mock, :get, fn _ -> {:ok, %{}} end)

  task = Task.async(fn ->
    MyApp.HTTPClient.Mock |> allow(parent, self())
    MyApp.HTTPClient.Mock.get("http://example.com")
  end)

  assert {:ok, %{}} = Task.await(task)
end

# Lazy allowance with Registry (from mox_test.exs line 1003)
test "lazy pid resolution via Registry" do
  name = {:via, Registry, {MyApp.Registry, :worker}}

  MyApp.HTTPClient.Mock
  |> expect(:get, fn _ -> {:ok, %{}} end)
  |> allow(self(), fn -> GenServer.whereis(name) end)

  {:ok, _} = GenServer.start_link(MyApp.Worker, [], name: name)
  assert {:ok, %{}} = GenServer.call(name, :fetch)
end

# Global mode (from mox_test.exs line 167)
test "global mode for integration test" do
  set_mox_global()
  expect(MyApp.HTTPClient.Mock, :get, fn _url -> {:ok, %{}} end)

  # Any process can call the mock
  task = Task.async(fn -> MyApp.HTTPClient.Mock.get("/") end)
  assert {:ok, %{}} = Task.await(task)
end
```

---

## 4. Channel Testing

Based on `phoenix/test/phoenix/test/channel_test.exs` and `phoenix/lib/phoenix/test/channel_test.ex`.

```elixir
defmodule MyAppWeb.RoomChannelTest do
  use MyAppWeb.ChannelCase, async: true

  alias MyAppWeb.RoomChannel
  alias MyAppWeb.UserSocket

  # Join and verify (from Phoenix channel_test.exs)
  describe "join/3" do
    test "joins successfully with valid params" do
      {:ok, reply, socket} =
        UserSocket
        |> socket("user:123", %{user_id: 123})
        |> subscribe_and_join(RoomChannel, "room:lobby")

      assert reply == %{}
      assert socket.assigns.user_id == 123
    end

    test "rejects unauthorized join" do
      assert {:error, %{reason: "unauthorized"}} =
        UserSocket
        |> socket("", %{})
        |> subscribe_and_join(RoomChannel, "room:private")
    end
  end

  describe "handle_in/3" do
    setup do
      {:ok, _, socket} =
        UserSocket
        |> socket("user:123", %{user_id: 123})
        |> subscribe_and_join(RoomChannel, "room:lobby")

      %{socket: socket}
    end

    # Push and assert reply (from Phoenix channel_test.ex docs)
    test "ping replies with pong", %{socket: socket} do
      ref = push(socket, "ping", %{})
      assert_reply ref, :ok, %{"response" => "pong"}
    end

    # Push and assert broadcast (from channel_test.ex docs)
    test "new_msg broadcasts to all", %{socket: socket} do
      push(socket, "new_msg", %{"body" => "hello"})
      assert_broadcast "new_msg", %{"body" => "hello"}
    end

    # Negative assertions
    test "rejects empty messages", %{socket: socket} do
      ref = push(socket, "new_msg", %{"body" => ""})
      assert_reply ref, :error, %{reason: "body cannot be empty"}
      refute_broadcast "new_msg", _
    end

    # Broadcast from outside channel
    test "receives external broadcasts", %{socket: socket} do
      broadcast_from!(socket, "update", %{"data" => "new"})
      assert_push "update", %{"data" => "new"}
    end

    # Synchronize before DB check (race condition prevention)
    test "persists message to database", %{socket: socket} do
      ref = push(socket, "new_msg", %{"body" => "saved"})
      assert_reply ref, :ok     # Wait for handler to complete
      assert Repo.get_by(Message, body: "saved")  # Now safe
    end
  end
end
```

---

## 5. LiveView Testing

Based on `phoenix/priv/templates/phx.gen.live/live_test.exs` and `phoenix/priv/templates/phx.gen.auth/settings_live_test.exs`.

```elixir
defmodule MyAppWeb.PostLiveTest do
  use MyAppWeb.ConnCase, async: true
  import Phoenix.LiveViewTest

  describe "Index" do
    test "lists all posts", %{conn: conn} do
      post = insert(:published_post, title: "First Post")
      {:ok, _view, html} = live(conn, ~p"/posts")
      assert html =~ "First Post"
    end

    # Element-based assertions (from Phoenix usage-rules/liveview.md)
    test "shows post details", %{conn: conn} do
      post = insert(:published_post)
      {:ok, view, _html} = live(conn, ~p"/posts")

      # Prefer has_element? over HTML string matching
      assert has_element?(view, "#posts-#{post.id}")
      assert has_element?(view, "[data-role=post-title]", post.title)
    end

    # Navigation via element click (from phx.gen.live template)
    test "navigates to new form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/posts")

      {:ok, form_view, _html} =
        view
        |> element("a", "New Post")
        |> render_click()
        |> follow_redirect(conn, ~p"/posts/new")

      assert render(form_view) =~ "New Post"
    end

    # Delete with element confirmation
    test "deletes post", %{conn: conn} do
      post = insert(:published_post)
      {:ok, view, _html} = live(conn, ~p"/posts")

      assert has_element?(view, "#posts-#{post.id}")

      view
      |> element("#posts-#{post.id} a", "Delete")
      |> render_click()

      refute has_element?(view, "#posts-#{post.id}")
    end
  end

  describe "Form" do
    # Form validation on change (from phx.gen.live template)
    test "validates on change", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/posts/new")

      html =
        view
        |> form("#post-form", post: %{title: ""})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    # Form submission with redirect (from phx.gen.live template)
    test "creates post on submit", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/posts/new")

      {:ok, index_view, _html} =
        view
        |> form("#post-form", post: %{title: "New Post", body: "Content"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/posts")

      assert render(index_view) =~ "Post created successfully"
    end

    # Validate then submit chain
    test "shows validation then succeeds", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/posts/new")

      # Verify validation error
      assert view
             |> form("#post-form", post: %{title: ""})
             |> render_change() =~ "can&#39;t be blank"

      # Submit valid data
      {:ok, conn} =
        view
        |> form("#post-form", post: %{title: "Valid", body: "Content"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html_response(conn, 200) =~ "Post created"
    end
  end

  describe "Async assigns" do
    # render_async for assign_async (LiveView 0.20+)
    test "loads async data", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Loading..."

      html = render_async(view)
      assert html =~ "Dashboard Data"
      refute html =~ "Loading..."
    end
  end

  describe "Auth-gated" do
    # From phx.gen.auth templates
    test "redirects if not logged in" do
      {:error, redirect} = live(build_conn(), ~p"/posts/new")
      assert {:redirect, %{to: path}} = redirect
      assert path =~ ~p"/log-in"
    end

    # Controller-delegated form (from settings_live_test.exs)
    test "login form submits to controller", %{conn: conn} do
      user = insert(:user)
      {:ok, view, _html} = live(conn, ~p"/log-in")

      form = form(view, "#login-form", user: %{
        email: user.email,
        password: "password123"
      })

      conn = submit_form(form, conn)
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "PubSub" do
    # Server-push events
    test "receives real-time updates", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/posts")

      Phoenix.PubSub.broadcast(MyApp.PubSub, "posts", {:post_created, %{title: "External"}})

      assert render(view) =~ "External"
    end
  end
end
```

---

## 6. Property-Based Testing

Based on JSON round-trip properties and `ash/test/generator/generator_test.exs` (action generators).

### Round-Trip Testing (Torque Pattern)

```elixir
defmodule MyApp.EncoderPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Encode/decode round-trip for JSON-compatible terms
  property "JSON encoding is reversible for safe types" do
    check all value <- json_value() do
      assert {:ok, ^value} =
               value
               |> Torque.encode!()
               |> Torque.decode()
    end
  end

  # Recursive generator for JSON-compatible terms
  defp json_value do
    simple = one_of([integer(), float(), string(:printable), boolean(), constant(nil)])

    tree(simple, fn json ->
      one_of([list_of(json), map_of(string(:printable), json)])
    end)
  end

  property "string encoding round-trips" do
    check all string <- string(:printable) do
      encoded = Torque.encode!(string)
      assert Torque.decode!(encoded) == string
    end
  end

  # Base64 round-trip
  property "Base64 encoding is reversible" do
    check all data <- binary() do
      assert data ==
               data
               |> Base.encode64()
               |> Base.decode64!()
    end
  end
end
```

### Oracle and Invariant Strategies

```elixir
defmodule MyApp.SortPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Oracle: compare against known-good reference
  property "custom sort matches Enum.sort" do
    check all list <- list_of(integer()) do
      assert MySort.sort(list) == Enum.sort(list)
    end
  end

  # Invariant: properties that always hold
  property "sorting preserves length" do
    check all list <- list_of(term()) do
      assert length(Enum.sort(list)) == length(list)
    end
  end

  property "reversing twice returns original" do
    check all list <- list_of(term()) do
      assert Enum.reverse(Enum.reverse(list)) == list
    end
  end

  # Smoke: verify no crashes on random input
  property "parser handles any string without crashing" do
    check all input <- string(:printable) do
      MyParser.parse(input)
    end
  end
end
```

### Custom Generators with Constraints

```elixir
defmodule MyApp.ValidatorPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  # Constraint-aware generator (from Ash type generators)
  defp email_generator do
    gen all local <- string(:alphanumeric, min_length: 1, max_length: 30),
            domain <- string(:alphanumeric, min_length: 1, max_length: 15),
            tld <- member_of(["com", "org", "net", "io"]) do
      "#{local}@#{domain}.#{tld}"
    end
  end

  property "valid emails pass validation" do
    check all email <- email_generator() do
      assert MyApp.Validator.valid_email?(email)
    end
  end

  # Filtered generator (from Ash string type generator)
  defp non_empty_trimmed_string do
    string(:printable, min_length: 1)
    |> StreamData.filter(fn value ->
      value
      |> String.trim()
      |> String.length() >= 1
    end)
  end

  property "slugify produces valid slug characters" do
    check all input <- non_empty_trimmed_string() do
      result = MyApp.StringUtils.slugify(input)
      assert result =~ ~r/^[a-z0-9-]*$/
    end
  end

  property "slugify is idempotent" do
    check all input <- string(:printable) do
      once = MyApp.StringUtils.slugify(input)
      assert MyApp.StringUtils.slugify(once) == once
    end
  end
end
```

---

## 7. Parametrized Tests (Elixir 1.18+)

Based on `elixir/lib/ex_unit/test/ex_unit/case_test.exs` and Phoenix integration tests.

```elixir
# Run same tests with multiple configurations
defmodule MyApp.AdapterTest do
  use ExUnit.Case,
    async: true,
    parameterize:
      for adapter <- [:postgres, :mysql, :sqlite],
          pool_size <- [1, 5],
          do: %{adapter: adapter, pool_size: pool_size}

  test "connects successfully", %{adapter: adapter, pool_size: pool_size} do
    {:ok, conn} = MyApp.DB.connect(adapter: adapter, pool_size: pool_size)
    assert MyApp.DB.alive?(conn)
  end
end

# Simpler: test multiple input/output pairs
defmodule MyApp.ParserTest do
  use ExUnit.Case,
    async: true,
    parameterize: [
      %{input: "true", expected: true},
      %{input: "false", expected: false},
      %{input: "null", expected: nil},
      %{input: "42", expected: 42}
    ]

  test "parses JSON literals", %{input: input, expected: expected} do
    assert Torque.decode!(input) == expected
  end
end
```

---

## 8. ExVCR HTTP Recording

```elixir
defmodule MyApp.GitHubClientTest do
  use ExUnit.Case, async: false     # ExVCR requires async: false
  use ExVCR.Mock, adapter: ExVCR.Adapter.Finch

  setup do
    ExVCR.Config.cassette_library_dir("test/fixture/vcr_cassettes")
    ExVCR.Config.filter_sensitive_data("Bearer [^\"]+", "Bearer ***FILTERED***")
    ExVCR.Config.filter_request_headers("Authorization")
    :ok
  end

  describe "get_user/1" do
    # First run: real HTTP call, saved to cassette
    # Subsequent runs: replayed from cassette
    test "returns user data" do
      use_cassette "github_get_user" do
        assert {:ok, user} = MyApp.GitHubClient.get_user("jose")
        assert user.login == "jose"
      end
    end

    # Stub mode: inline mock without cassette file
    test "handles 404" do
      use_cassette :stub, [
        url: "https://api.github.com/users/nonexistent",
        status_code: 404,
        body: ~s({"message": "Not Found"})
      ] do
        assert {:error, :not_found} = MyApp.GitHubClient.get_user("nonexistent")
      end
    end

    # Match by URL and body
    test "creates issue" do
      use_cassette "github_create_issue", match_requests_on: [:query, :request_body] do
        assert {:ok, issue} = MyApp.GitHubClient.create_issue("owner/repo", %{
          title: "Bug report",
          body: "Steps to reproduce..."
        })
        assert issue.number > 0
      end
    end
  end

  # Conditional recording (CI records, local replays)
  test "api integration" do
    opts = if System.get_env("CI"), do: [record: :new_episodes], else: []

    use_cassette "api_test", opts do
      assert {:ok, _} = MyApp.GitHubClient.get_rate_limit()
    end
  end
end
```

---

## 9. Capture IO/Log Patterns

Based on `elixir/lib/ex_unit/test/ex_unit/capture_io_test.exs` and `capture_log_test.exs`.

```elixir
defmodule MyApp.OutputTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO
  import ExUnit.CaptureLog

  # Basic capture (from ExUnit capture_io_test.exs)
  test "capture stdout" do
    output = capture_io(fn ->
      IO.puts("hello")
    end)
    assert output == "hello\n"
  end

  # Capture with input (from capture_io_test.exs — get_chars test)
  test "capture with simulated input" do
    output = capture_io("yes\n", fn ->
      answer = IO.gets("Continue? ")
      IO.puts("Got: #{answer}")
    end)
    assert output =~ "Continue?"
    assert output =~ "Got: yes"
  end

  # Capture stderr
  test "capture warnings" do
    output = capture_io(:stderr, fn ->
      IO.warn("deprecated function")
    end)
    assert output =~ "deprecated function"
  end

  # Nested captures (from capture_log_test.exs)
  test "nested IO and log capture" do
    log = capture_log(fn ->
      output = capture_io(fn ->
        Logger.info("logged")
        IO.puts("printed")
      end)
      assert output == "printed\n"
    end)
    assert log =~ "logged"
  end

  # with_log returns {result, log} (from capture_log_test.exs)
  test "with_log" do
    {result, log} = with_log(fn ->
      Logger.error("computing...")
      2 + 2
    end)
    assert result == 4
    assert log =~ "computing..."
  end

  # Suppress log noise in module
  @moduletag :capture_log
end
```

---

## 10. Telemetry Testing

Based on Phoenix and Plug telemetry patterns.

```elixir
defmodule MyApp.TelemetryTest do
  use ExUnit.Case, async: true

  # Attach handler that sends events to test process
  setup context do
    handler = fn event, measurements, metadata, _config ->
      send(self(), {:telemetry, event, measurements, metadata})
    end

    :telemetry.attach_many(
      "#{context.test}",
      [
        [:my_app, :repo, :query],
        [:my_app, :request, :stop]
      ],
      handler,
      nil
    )

    on_exit(fn -> :telemetry.detach("#{context.test}") end)
    :ok
  end

  test "repo query emits telemetry" do
    MyApp.Repo.all(MyApp.User)

    assert_receive {:telemetry, [:my_app, :repo, :query], measurements, metadata}
    assert is_integer(measurements.total_time)
    assert metadata.source == "users"
  end
end
```

---

## 11. Oban Job Testing

```elixir
defmodule MyApp.Workers.EmailWorkerTest do
  use MyApp.DataCase, async: true
  use Oban.Testing, repo: MyApp.Repo

  alias MyApp.Workers.EmailWorker

  # Test job performs correctly
  test "sends welcome email" do
    user = insert(:user)
    assert :ok = perform_job(EmailWorker, %{user_id: user.id, type: "welcome"})
  end

  # Test job was enqueued
  test "enqueues after registration" do
    {:ok, user} = MyApp.Accounts.register(%{email: "new@example.com"})
    assert_enqueued worker: EmailWorker, args: %{user_id: user.id, type: "welcome"}
  end

  # Refute no job enqueued
  test "does not enqueue for existing user" do
    user = insert(:user)
    MyApp.Accounts.touch(user)
    refute_enqueued worker: EmailWorker
  end

  # drain_queue — process all enqueued jobs
  test "processes all pending emails" do
    Enum.each(1..5, &MyApp.Notifications.enqueue_digest(&1))
    assert %{success: 5, failure: 0} = Oban.drain_queue(queue: :default)
  end
end
```

---

## 12. OTP Process Testing

```elixir
defmodule MyApp.CacheTest do
  use ExUnit.Case, async: true

  # start_supervised! with auto-cleanup (from ExUnit supervised_test.exs)
  setup do
    cache = start_supervised!(MyApp.Cache)
    %{cache: cache}
  end

  test "stores and retrieves", %{cache: cache} do
    MyApp.Cache.put(cache, :key, "value")
    assert MyApp.Cache.get(cache, :key) == "value"
  end

  # $callers tracking (from ExUnit supervised_test.exs)
  test "supervised process has correct $callers" do
    test_pid = self()
    fun = fn -> send(test_pid, {:callers, Process.get(:"$callers")}) end
    {:ok, _pid} = start_supervised({Task, fun})

    assert_receive {:callers, callers}
    assert List.last(callers) == test_pid
  end

  # Task.Supervisor for failure isolation
  test "supervised task failure doesn't crash parent" do
    {:ok, sup} = start_supervised(Task.Supervisor)

    Task.Supervisor.async_nolink(sup, fn -> raise "boom" end)

    assert_receive {:DOWN, _ref, :process, _pid, {%RuntimeError{message: "boom"}, _}}
  end
end
```

---

## Extended Testing Patterns (from main skill)

### Mox Anti-Patterns

```elixir
# BAD: Mocking modules you own — test the real code
defmock(MyApp.Users.Mock, for: MyApp.Users)

# GOOD: Mock at system boundaries only
defmock(MyApp.HTTPClient.Mock, for: MyApp.HTTPClient)
defmock(MyApp.Mailer.Mock, for: MyApp.Mailer)

# BAD: Using Application.get_env at runtime (slow, not compile-time safe)
def fetch(city) do
  client = Application.get_env(:my_app, :http_client)
  client.get(url)
end

# GOOD: Compile-time injection
@http_client Application.compile_env(:my_app, :http_client, MyApp.HTTPClient.Impl)

# BAD: Forgetting verify_on_exit! — unmet expectations silently pass
setup do
  :ok
end

# GOOD: Always verify
setup :verify_on_exit!
```

### Ecto Sandbox Modes

| Mode | How it works | When to use |
|---|---|---|
| `:manual` | Must explicitly checkout | Default in test_helper.exs |
| `:auto` | Auto-checkout on first query | Simple sync tests |
| `{:shared, pid}` | All processes share one connection | Non-async tests, LiveView tests |

**async: true requires `:manual` mode** — each test gets its own checkout, transactions are isolated, rolled back after test.

### Changeset Testing

```elixir
defmodule MyApp.UserTest do
  use MyApp.DataCase, async: true

  alias MyApp.Accounts.User

  # Test valid changeset
  test "valid changeset" do
    changeset = User.changeset(%User{}, %{email: "test@example.com", name: "Test"})
    assert changeset.valid?
  end

  # Test specific validations
  test "email is required" do
    changeset = User.changeset(%User{}, %{name: "Test"})
    assert %{email: ["can't be blank"]} = errors_on(changeset)
  end

  test "email must be valid format" do
    changeset = User.changeset(%User{}, %{email: "notanemail"})
    assert %{email: ["must have the @ sign and no spaces"]} = errors_on(changeset)
  end

  test "name must be at least 2 characters" do
    changeset = User.changeset(%User{}, %{email: "t@t.com", name: "A"})
    assert %{name: ["should be at least 2 character(s)"]} = errors_on(changeset)
  end

  # Test constraint errors (need DB round-trip)
  test "unique email constraint" do
    insert(:user, email: "taken@example.com")
    {:error, changeset} = %User{}
      |> User.changeset(%{email: "taken@example.com", name: "Test"})
      |> Repo.insert()
    assert %{email: ["has already been taken"]} = errors_on(changeset)
  end
end
```

### Phoenix-Style Fixtures (no ExMachina dependency)

```elixir
# From phx.gen.auth — fixture module pattern
defmodule MyApp.AccountsFixtures do
  def unique_user_email, do: "user#{System.unique_integer([:positive])}@example.com"

  def user_fixture(attrs \\ %{}) do
    {:ok, user} =
      attrs
      |> Enum.into(%{email: unique_user_email(), password: "hello world!"})
      |> MyApp.Accounts.register_user()
    user
  end
end
```

### Ecto.Multi Testing

```elixir
test "multi transaction succeeds" do
  multi =
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.changeset(%User{}, @valid_attrs))
    |> Ecto.Multi.insert(:profile, fn %{user: user} ->
      Profile.changeset(%Profile{user_id: user.id}, %{bio: "hello"})
    end)

  assert {:ok, %{user: user, profile: profile}} = Repo.transaction(multi)
  assert user.id
  assert profile.user_id == user.id
end

test "multi transaction rolls back on failure" do
  multi =
    Ecto.Multi.new()
    |> Ecto.Multi.insert(:user, User.changeset(%User{}, @valid_attrs))
    |> Ecto.Multi.run(:fail, fn _repo, _changes ->
      {:error, :intentional_failure}
    end)

  assert {:error, :fail, :intentional_failure, %{user: user}} = Repo.transaction(multi)
  # User was NOT persisted (rolled back)
  refute Repo.get(User, user.id)
end
```

### Phoenix Controller & Plug Testing

#### ConnTest Helpers

```elixir
defmodule MyAppWeb.UserControllerTest do
  use MyAppWeb.ConnCase, async: true

  import MyApp.AccountsFixtures

  # Setup with authenticated conn
  setup %{conn: conn} do
    user = user_fixture()
    conn = log_in_user(conn, user)  # From phx.gen.auth
    %{conn: conn, user: user}
  end

  # GET — HTML response
  test "lists users", %{conn: conn} do
    conn = get(conn, ~p"/users")
    assert html_response(conn, 200) =~ "Users"
  end

  # GET — JSON response
  test "shows user as JSON", %{conn: conn, user: user} do
    conn = get(conn, ~p"/api/users/#{user}")
    assert %{"id" => id, "email" => email} = json_response(conn, 200)
    assert id == user.id
  end

  # POST — create resource
  test "creates user and redirects", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{email: "new@example.com", name: "New"})
    assert redirected_to(conn) == ~p"/users"

    # Follow redirect
    conn = get(recycle(conn), ~p"/users")
    assert html_response(conn, 200) =~ "new@example.com"
  end

  # POST — validation errors
  test "renders errors on invalid data", %{conn: conn} do
    conn = post(conn, ~p"/users", user: %{email: ""})
    assert html_response(conn, 422) =~ "can&#39;t be blank"
  end

  # DELETE
  test "deletes user", %{conn: conn, user: user} do
    conn = delete(conn, ~p"/users/#{user}")
    assert redirected_to(conn) == ~p"/users"
  end

  # Testing error pages
  test "returns 404 for missing resource", %{conn: conn} do
    assert_error_sent 404, fn ->
      get(conn, ~p"/users/99999")
    end
  end

  # Testing with specific session/cookies
  test "with session data" do
    conn = build_conn()
           |> init_test_session(%{user_id: 123})
           |> get(~p"/dashboard")
    assert html_response(conn, 200)
  end

  # recycle — simulates new request keeping cookies (browser behavior)
  test "multi-step flow" do
    conn = post(build_conn(), ~p"/login", user: @creds)
    assert redirected_to(conn) == ~p"/dashboard"

    conn =
      conn
      |> recycle()
      |> get(~p"/dashboard")
    assert html_response(conn, 200) =~ "Welcome"
  end

  # bypass_through — run endpoint plugs without dispatching
  test "endpoint plugs set expected assigns" do
    conn =
      build_conn()
      |> bypass_through(MyAppWeb.Router, [:browser])
      |> get("/")
    assert conn.assigns[:current_user] == nil
  end
end
```

#### Custom Plug Testing

```elixir
defmodule MyAppWeb.Plugs.RequireAPIKeyTest do
  use MyAppWeb.ConnCase, async: true

  alias MyAppWeb.Plugs.RequireAPIKey

  test "halts with 401 when no API key" do
    conn = build_conn(:get, "/api/data")
           |> RequireAPIKey.call(RequireAPIKey.init([]))
    assert conn.halted
    assert conn.status == 401
  end

  test "passes through with valid API key" do
    conn = build_conn(:get, "/api/data")
           |> put_req_header("x-api-key", "valid-key")
           |> RequireAPIKey.call(RequireAPIKey.init([]))
    refute conn.halted
  end
end
```

### Extended Oban Job Testing

```elixir
# Additional Oban patterns beyond basic enqueue/perform

# Test with specific queue/priority
test "high-priority emails go to critical queue" do
  MyApp.Notifications.send_alert(%{level: :critical})

  assert_enqueued worker: EmailWorker,
                  queue: :critical,
                  args: %{type: "alert"},
                  priority: 0
end

# Test scheduled jobs
test "schedules reminder for tomorrow" do
  MyApp.Reminders.schedule(user)

  assert_enqueued worker: EmailWorker,
                  scheduled_at: {DateTime.utc_now(), delta: 86_400}
end

# Test job error handling
test "returns error for missing user" do
  assert {:error, :not_found} = perform_job(EmailWorker, %{user_id: -1, type: "welcome"})
end

# Test snooze/cancel
test "snoozes when rate limited" do
  assert {:snooze, 60} = perform_job(EmailWorker, %{user_id: 1, type: "bulk"})
end

# all_enqueued — inspect all enqueued jobs
test "batch enqueue creates correct jobs" do
  MyApp.Batch.process(user_ids: [1, 2, 3])

  jobs = all_enqueued(worker: EmailWorker)
  assert length(jobs) == 3
  assert Enum.all?(jobs, &(&1.args["type"] == "batch"))
end
```

**Oban testing modes:**

| Mode | Behavior | Use case |
|---|---|---|
| `:manual` | Jobs are inserted but NOT executed | Test enqueueing, use `perform_job` to test execution |
| `:inline` | Jobs execute immediately in the calling process | Integration tests, simple flows |
| (none/prod) | Normal async execution | Never in tests |

### Extended OTP Process Testing

```elixir
# TTL expiration
test "expires entries after TTL", %{cache: cache} do
  MyApp.Cache.put(cache, :key, "value", ttl: 50)
  Process.sleep(100)
  assert MyApp.Cache.get(cache, :key) == nil
end

# Test GenServer restart behavior
test "supervisor restarts on crash" do
  cache = start_supervised!({MyApp.Cache, name: :test_cache})
  Process.exit(cache, :kill)
  Process.sleep(50)  # Wait for restart
  new_pid = Process.whereis(:test_cache)
  assert new_pid != cache
  assert Process.alive?(new_pid)
end

# Test message handling
test "handles async messages" do
  cache = start_supervised!(MyApp.Cache)
  send(cache, {:invalidate, :all})
  # Give GenServer time to process
  assert eventually(fn -> MyApp.Cache.size(cache) == 0 end)
end

# Test process monitoring
defmodule MyApp.WorkerPoolTest do
  use ExUnit.Case, async: true

  test "monitors worker and detects crash" do
    {:ok, worker} = start_supervised(MyApp.Worker)
    ref = Process.monitor(worker)

    GenServer.cast(worker, :crash)

    assert_receive {:DOWN, ^ref, :process, ^worker, _reason}
  end
end
```

### When to Use Property-Based Testing

- Functions with many valid inputs (parsers, encoders, validators)
- Mathematical properties (sorting, set operations, arithmetic)
- Round-trip operations (serialize/deserialize, encode/decode)
- Edge case discovery (empty strings, zero, negative, Unicode)

### Extended Telemetry Testing

```elixir
# Additional: test request duration
test "request emits duration" do
  MyApp.handle_request(%{path: "/api/test"})

  assert_receive {:telemetry, [:my_app, :request, :stop], measurements, _metadata}
  assert measurements.duration > 0
end
```

### Testing Best Practices

**Test organization:**
- One test file per module: `lib/my_app/accounts.ex` -> `test/my_app/accounts_test.exs`
- Group related tests with `describe` blocks named after the function: `describe "create_user/1"`
- Test happy path first, then edge cases, then error cases

**What to test:**
- Public API (exported functions) -- NOT private implementation details
- Boundary behavior (empty input, nil, max values)
- Error paths and error messages
- Side effects (database changes, messages sent, jobs enqueued)

**What NOT to test:**
- Private functions directly -- test through public API
- Framework code (Ecto changeset internals, Phoenix routing)
- Exact log messages (brittle -- use `capture_log` + `=~` for key phrases)
- Implementation details that might change

**Test naming:**
```elixir
# BAD: describes implementation
test "calls Repo.insert" do ... end

# GOOD: describes behavior
test "creates user with valid attributes" do ... end
test "returns error when email is taken" do ... end

# BAD: generic names
test "it works" do ... end
test "test 1" do ... end

# GOOD: specific and descriptive
test "returns {:error, :not_found} when user does not exist" do ... end
```

**Performance:**
- Always use `async: true` unless you have a specific reason not to
- Use `start_supervised!` instead of manually starting/stopping processes
- Use `@tag :slow` for expensive tests, exclude from default runs
- Use `Ecto.Adapters.SQL.Sandbox` for database isolation (not manual cleanup)

**Common `errors_on/1` helper** (standard in Phoenix DataCase):

```elixir
def errors_on(changeset) do
  Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
    Regex.replace(~r"%{(\w+)}", message, fn _, key ->
      opts
      |> Keyword.get(String.to_existing_atom(key), key)
      |> to_string()
    end)
  end)
end
```

### Testing BAD/GOOD Pairs

**Testing private functions directly:**
```elixir
# BAD: Exposing internals for testing
defmodule MyApp.Parser do
  def parse(input), do: input |> tokenize() |> build_ast()
  # @doc false — but called directly in tests
  def tokenize(input), do: ...
end

# GOOD: Test through public API
test "parses complex expression" do
  assert {:ok, ast} = MyApp.Parser.parse("1 + 2 * 3")
  assert ast == {:+, 1, {:*, 2, 3}}
end
```

**Brittle HTML assertions in LiveView:**
```elixir
# BAD: Checking raw HTML (breaks on markup changes)
{:ok, _live, html} = live(conn, ~p"/items")
assert html =~ "<span class=\"text-sm\">Item 1</span>"

# GOOD: Use element selectors and has_element?
{:ok, live, _html} = live(conn, ~p"/items")
assert has_element?(live, "#item-1")
assert has_element?(live, "[data-role=item-name]", "Item 1")
```

**Not waiting for async in channel tests:**
```elixir
# BAD: Checking DB before channel handler completes
push(socket, "create", %{"name" => "test"})
assert Repo.get_by(Item, name: "test")  # RACE CONDITION

# GOOD: Wait for reply, then check DB
ref = push(socket, "create", %{"name" => "test"})
assert_reply ref, :ok  # Handler completed
assert Repo.get_by(Item, name: "test")  # Safe now
```

**Sharing state between tests:**
```elixir
# BAD: Tests depend on execution order
setup_all do
  {:ok, user} = Repo.insert(%User{email: "shared@test.com"})
  %{user: user}  # Shared across all tests — mutation causes flaky tests
end

# GOOD: Each test creates its own data
setup do
  %{user: insert(:user)}
end
```

**Not using verify_on_exit! with Mox:**
```elixir
# BAD: Unmet expectations pass silently
test "calls API" do
  expect(HTTPMock, :get, fn _ -> {:ok, %{}} end)
  # Forgot to actually call the function — test passes anyway!
end

# GOOD: Always verify
setup :verify_on_exit!
test "calls API" do
  expect(HTTPMock, :get, fn _ -> {:ok, %{}} end)
  # Test fails: "expected HTTPMock.get/1 to be called once but it was not called"
end
```

**Not testing error paths:**
```elixir
# BAD: Only testing happy path
test "creates user" do
  assert {:ok, _} = Accounts.create_user(@valid_attrs)
end

# GOOD: Test both success and failure
test "creates user with valid attrs" do
  assert {:ok, user} = Accounts.create_user(@valid_attrs)
  assert user.email == @valid_attrs.email
end

test "returns error with invalid attrs" do
  assert {:error, changeset} = Accounts.create_user(%{})
  assert %{email: ["can't be blank"]} = errors_on(changeset)
end

test "returns error when email already taken" do
  insert(:user, email: "taken@test.com")
  assert {:error, changeset} = Accounts.create_user(%{email: "taken@test.com"})
  assert %{email: ["has already been taken"]} = errors_on(changeset)
end
```

## How Mox Process Ownership Works (`$callers`)

Understanding how Mox tracks which test process "owns" expectations is important for debugging failures in spawned processes.

### Automatic Ownership via `$callers`

When you use `Task.async/1` or `Task.Supervisor.async/2`, Elixir automatically sets `$callers` in the spawned process's dictionary. Mox walks this chain to find the owning test process:

```elixir
# In your test (pid: #PID<0.100.0>)
expect(CalcMock, :add, fn x, y -> x + y end)

# Task.async sets $callers = [#PID<0.100.0>] in the spawned process
task = Task.async(fn ->
  CalcMock.add(1, 2)  # Works! Mox walks $callers to find test process
end)
Task.await(task)
```

### When `$callers` Doesn't Work

Processes started with bare `spawn`, `GenServer.start_link`, or `:proc_lib` do NOT set `$callers`. You must explicitly allow:

```elixir
test "GenServer uses mock" do
  expect(CalcMock, :add, fn x, y -> x + y end)

  # This GenServer won't have $callers — must allow explicitly
  {:ok, pid} = MyWorker.start_link([])
  allow(CalcMock, self(), pid)

  # Now the GenServer can use CalcMock
  assert MyWorker.compute(pid, 1, 2) == 3
end
```

### Lazy Allow for Dynamic PIDs

When the PID isn't known at allow time (e.g., process started inside the code under test):

```elixir
test "allows dynamically spawned process" do
  # Function is called lazily when the mock is dispatched
  allow(CalcMock, self(), fn -> GenServer.whereis(MyWorker) end)

  start_supervised!(MyWorker)
  assert MyWorker.compute(1, 2) == 3
end
```

### Global Mode for Non-Concurrent Tests

When ownership tracking is too complex (many processes, supervision trees):

```elixir
setup :set_mox_global  # All processes share expectations
setup :verify_on_exit!

# Cannot use async: true with global mode
```

### Pipe-Chainable Mox API

Mox returns the mock module from mutation functions, enabling chaining:

```elixir
CalcMock
|> expect(:add, fn x, y -> x + y end)
|> expect(:mult, 2, fn x, y -> x * y end)  # expect 2 calls
|> stub(:divide, fn _, 0 -> {:error, :div_by_zero}; x, y -> {:ok, x / y} end)
|> allow(self(), worker_pid)
```
