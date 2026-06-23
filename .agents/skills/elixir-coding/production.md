# Production Elixir Patterns

Real-world production patterns extracted from three open-source Elixir codebases: [changelog.com](https://github.com/thechangelog/changelog.com) (Phoenix web), [ExNVR](https://github.com/evercam/ex_nvr) (embedded IoT), and [Oban](https://github.com/oban-bg/oban) (job processing).

## Contents

| Section | What's There |
|---------|-------------|
| [Production Phoenix Patterns](#production-phoenix-patterns-from-changelogcom) | Schema base modules, kit modules, response caching, authorization, controller injection, HTTP retry, cache cascade, soft delete |
| [Edge/IoT Patterns](#edgeiot-patterns-from-exnvr) | Tick-based monitoring, periodic status collection, schedule validation, role-based auth, NIF modules, polymorphic embedded schemas |
| [Job Processing Patterns](#job-processing-patterns-from-oban) | Worker behaviours, pluggable engines, backoff/jitter, dispatch cooldown, leader election, distributed notifier, cron expressions, CTE fencing |
| [Telemetry](#telemetry) | Core API, span/3, built-in events, Telemetry.Metrics, custom instrumentation |
| [HTTP Clients](#http-clients) | Req (default), Finch, testing with Req.Test and Mox |
| [Plug halt/1 Semantics](#plug-halt1-semantics) | How halt works (flag, not execution stop) |
| [OpenApiSpex](#openapispex-api-documentation--validation) | Operation DSL, Schema modules, Parameter vs Schema properties, validation setup |

## Rules for Production Elixir (LLM)

1. ALWAYS use `Process.send_after/3` for periodic work — never `Process.sleep` in a loop (blocks the process, prevents message handling)
2. ALWAYS debounce threshold-based actions — require N consecutive violations before acting to prevent thrashing on transient spikes
3. ALWAYS use exponential backoff with jitter for retries — `base * 2^attempt` with random offset prevents thundering herd
4. ALWAYS use `:telemetry.span/3` for instrumenting operations — it handles start/stop/exception events automatically
5. ALWAYS call `halt()` after sending a response in plugs — `halt/1` sets a flag checked *between* plugs, it does NOT stop execution within your function
6. PREFER Req over HTTPoison for new projects — built-in retries, JSON, auth, connection pooling via Finch
7. PREFER database-backed leader election over `:global` locks in production — survives netsplits and doesn't require distributed Erlang
8. NEVER scatter authorization logic across controllers — extract to a dedicated module with pattern-matching clauses ordered by specificity

## Common Production Mistakes (BAD/GOOD)

**Periodic work — sleep loop vs send_after:**
```elixir
# BAD: blocks process, can't handle other messages during sleep
def handle_info(:check, state) do
  do_check(state)
  Process.sleep(60_000)
  send(self(), :check)
  {:noreply, state}
end

# GOOD: non-blocking timer, process remains responsive
def handle_info(:check, state) do
  do_check(state)
  Process.send_after(self(), :check, 60_000)
  {:noreply, state}
end
```

**Threshold action — immediate vs debounced:**
```elixir
# BAD: acts on first spike, causes thrashing if metric fluctuates
defp check_disk(usage, state) when usage >= 90, do: delete_old_files()

# GOOD: requires N consecutive violations before acting
defp check_disk(usage, %{ticks: t} = state) when usage >= 90 and t >= 5 do
  delete_old_files()
  %{state | ticks: 0}
end
defp check_disk(usage, state) when usage >= 90, do: %{state | ticks: state.ticks + 1}
defp check_disk(_usage, state), do: %{state | ticks: 0}  # reset on recovery
```

**Telemetry — manual emission vs span:**
```elixir
# BAD: manual start/stop, easy to miss exception path
:telemetry.execute([:my_app, :job, :start], %{}, meta)
result = do_work()
:telemetry.execute([:my_app, :job, :stop], %{duration: dur}, meta)

# GOOD: span handles start, stop, AND exception automatically
:telemetry.span([:my_app, :job], meta, fn ->
  result = do_work()
  {result, %{result_count: length(result)}}
end)
```

**Plug — forgetting halt doesn't stop execution:**
```elixir
# BAD: code after halt() still runs, may cause double-send
def call(conn, _opts) do
  if unauthorized?(conn) do
    conn |> send_resp(403, "Forbidden") |> halt()
  end
  # THIS STILL EXECUTES even when halted above!
  do_work(conn)
end

# GOOD: use if/else or multi-clause to ensure single return path
def call(conn, _opts) do
  if unauthorized?(conn) do
    conn
    |> send_resp(403, "Forbidden")
    |> halt()
  else
    do_work(conn)
  end
end
```

---

## Production Phoenix Patterns (from changelog.com)

> Patterns extracted from [thechangelog/changelog.com](https://github.com/thechangelog/changelog.com) — a large-scale Phoenix application in production since 2015.

| Pattern | Purpose |
|---------|---------|
| **Schema Base Module** | Inject common query helpers (`newest_first`, `limit`, `older_than`) into all schemas via `use MyApp.Schema` |
| **Kit Modules** | Small, focused utility modules (`StringKit`, `ListKit`) instead of one large helper |
| **Response Cache Plug** | Cache entire HTTP responses for unauthenticated users by request path |
| **Policy Module** | Authorization with `defoverridable` defaults - `is_admin/1`, `is_editor/1` helpers |
| **Controller Context Injection** | Override `action/2` to inject common assigns into all controller actions |
| **HTTP Client SSL Fallback** | Req client with custom retry step for servers that fail with default TLS |
| **Oban Telemetry Reporter** | Capture job failures via `:telemetry.attach` and forward to error tracking |
| **Cache Cascade Deletion** | Delete related cache entries when primary entity changes |
| **Soft Delete Subscription** | Track lifecycle with `unsubscribed_at` timestamp instead of hard delete |

### Schema Base Module

> Source: `Changelog.Schema` — configurable sort field, hashid encoding, common query helpers injected via `__using__`.

```elixir
defmodule MyApp.Schema do
  defmacro __using__(opts) do
    # Allow each schema to customize its default sort field
    sort_field = Keyword.get(opts, :default_sort, :inserted_at)

    quote do
      use Ecto.Schema
      import Ecto.Changeset
      import Ecto.Query

      @sort_field unquote(sort_field)

      def newest_first(query, field \\ @sort_field) do
        from(q in query, order_by: [desc: field(q, ^field)])
      end

      def newest_last(query, field \\ @sort_field) do
        from(q in query, order_by: [asc: field(q, ^field)])
      end

      def older_than(query, %{__struct__: _} = thing, field \\ @sort_field) do
        # Accept either a struct with the field or a raw datetime
        from(q in query, where: field(q, ^field) < ^Map.get(thing, field))
      end

      def newer_than(query, %{__struct__: _} = thing, field \\ @sort_field) do
        from(q in query, where: field(q, ^field) > ^Map.get(thing, field))
      end

      def limit(query, count), do: from(q in query, limit: ^count)
      def any?(query), do: MyApp.Repo.exists?(query)
      def with_ids(query, ids), do: from(q in query, where: q.id in ^ids)

      defoverridable [
        newest_first: 1, newest_first: 2, newest_last: 1, newest_last: 2,
        older_than: 2, older_than: 3, newer_than: 2, newer_than: 3,
        limit: 2, any?: 1
      ]
    end
  end
end

# Usage — schemas inherit all helpers, with custom sort field
defmodule MyApp.Episode do
  use MyApp.Schema, default_sort: :published_at  # sort by publish date
  schema "episodes" do
    field :title, :string
    field :published_at, :utc_datetime
    timestamps()
  end
end

# Composable queries
MyApp.Episode
|> MyApp.Episode.newest_first()
|> MyApp.Episode.limit(10)
|> MyApp.Repo.all()
```

### Kit Modules (Focused Utility Modules)

> Source: `Changelog.StringKit`, `Changelog.ListKit`, `Changelog.MapKit` — 10 Kit modules in production, each < 50 lines.

```elixir
defmodule MyApp.StringKit do
  def blank?(nil), do: true
  def blank?(str) when is_binary(str), do: String.trim(str) == ""
  def present?(str), do: not blank?(str)

  def truncate(str, max) when byte_size(str) <= max, do: str
  def truncate(str, max), do: String.slice(str, 0, max - 3) <> "..."

  def dasherize(str) do
    str
    |> String.downcase()
    |> String.replace(~r/[^\w]+/, "-")
  end
end

defmodule MyApp.ListKit do
  def compact(list), do: Enum.reject(list, &(&1 in [nil, ""]))
  def compact_join(list, sep \\ " ") do
    list
    |> compact()
    |> Enum.join(sep)
  end

  # Multi-clause exclude handles diverse input types
  def exclude(list, nil), do: list
  def exclude(list, items) when is_list(items), do: Enum.reject(list, &(&1 in items))
  def exclude(list, %{id: id}), do: Enum.reject(list, &(Map.get(&1, :id) == id))
  def exclude(list, item), do: Enum.reject(list, &(&1 == item))

  def overlap?(list1, list2), do: Enum.any?(list1, &(&1 in list2))
end

defmodule MyApp.MapKit do
  def sans_blanks(map) do
    map
    |> Enum.reject(fn {_k, v} -> MyApp.StringKit.blank?(v) end)
    |> Map.new()
  end
end
```

### Response Cache Plug

> Source: `ChangelogWeb.Plug.ResponseCache` — guards skip cache for authenticated users, cache key from request path + query string.

```elixir
defmodule MyAppWeb.Plug.ResponseCache do
  import Plug.Conn

  # Guard: never cache for authenticated users
  def cached_response(%{assigns: %{current_user: user}} = conn, _opts)
      when not is_nil(user), do: conn
  def cached_response(conn, _opts) do
    case MyApp.Cache.get(cache_key(conn)) do
      nil -> conn
      cached -> send_cached_response(conn, cached) |> halt()
    end
  end

  # Only cache for anonymous users
  def cache_public(%{assigns: %{current_user: user}} = conn) when not is_nil(user), do: conn
  def cache_public(conn, ttl \\ :infinity) do
    register_before_send(conn, fn conn ->
      MyApp.Cache.put(cache_key(conn), %{
        body: conn.resp_body,
        content_type: get_resp_header(conn, "content-type"),
        status: conn.status
      }, ttl)
      conn
    end)
  end

  defp cache_key(conn) do
    query = if conn.query_string == "", do: "", else: "?#{conn.query_string}"
    "response:#{conn.request_path}#{query}"
  end

  defp send_cached_response(conn, %{body: body, content_type: ct, status: status}) do
    conn
    |> put_resp_content_type(ct)
    |> send_resp(status, body)
  end
end
```

### Policy Module

> Source: `Changelog.Policies.Default` — deny-by-default, role helpers injected into all policies, `new/1` delegates to `create/1`.

```elixir
defmodule MyApp.Policy do
  defmacro __using__(_opts) do
    quote do
      # Default: deny everything
      def new(actor), do: create(actor)
      def create(_actor), do: false
      def index(_actor), do: false
      def show(_actor, _resource), do: false
      def edit(actor, resource), do: update(actor, resource)
      def update(_actor, _resource), do: false
      def delete(_actor, _resource), do: false

      # Role helpers injected into every policy
      defp is_admin(nil), do: false
      defp is_admin(actor), do: Map.get(actor, :admin, false)
      defp is_editor(nil), do: false
      defp is_editor(actor), do: Map.get(actor, :editor, false)
      defp is_admin_or_editor(nil), do: false
      defp is_admin_or_editor(actor), do: is_admin(actor) || is_editor(actor)

      defoverridable new: 1, create: 1, index: 1, show: 2, edit: 2, update: 2, delete: 2
    end
  end
end

# Concrete policy — only override what differs
defmodule MyApp.Policy.Post do
  use MyApp.Policy

  def index(_actor), do: true             # public
  def show(_actor, _post), do: true       # public
  def create(actor), do: is_admin_or_editor(actor)
  def update(actor, post), do: is_admin(actor) or is_owner(actor, post)
  def delete(actor, _post), do: is_admin(actor)

  defp is_owner(nil, _post), do: false
  defp is_owner(%{id: id}, %{author_id: author_id}), do: id == author_id
end
```

### Controller Context Injection

> Source: `ChangelogWeb.Admin.EpisodeController` — override `action/2` to inject podcast from assigns into all actions as a 3rd parameter.

```elixir
defmodule MyAppWeb.PodcastEpisodeController do
  use MyAppWeb, :controller

  # Override action/2 to inject podcast into all actions
  def action(conn, _) do
    podcast = conn.assigns.podcast    # set by earlier plug
    apply(__MODULE__, action_name(conn), [conn, conn.params, podcast])
  end

  # Every action receives podcast as 3rd arg — no repetitive lookup
  def index(conn, params, podcast) do
    episodes = Episodes.list_for_podcast(podcast, params)
    render(conn, :index, episodes: episodes)
  end

  def show(conn, %{"slug" => slug}, podcast) do
    episode = Episodes.get_by_podcast_and_slug!(podcast, slug)
    render(conn, :show, episode: episode)
  end

  def create(conn, %{"episode" => attrs}, podcast) do
    case Episodes.create(podcast, attrs) do
      {:ok, episode} -> redirect(conn, to: ~p"/#{podcast.slug}/#{episode.slug}")
      {:error, changeset} -> render(conn, :new, changeset: changeset)
    end
  end
end
```

### HTTP Client with SSL Fallback

> Source: adapted from `Changelog.HTTP` — retries once with `middlebox_comp_mode: false` to handle servers that fail with default TLS settings. Rewritten with Req.

```elixir
defmodule MyApp.HTTP do
  @doc "Reusable client with SSL fallback as a custom retry step."
  def client(opts \\ []) do
    Req.new(opts)
    |> Req.Request.append_request_steps(ssl_fallback: &ssl_fallback_step/1)
  end

  # Custom Req step — retry with relaxed SSL on connection failure
  defp ssl_fallback_step(request) do
    {request, fn {request, response_or_error} ->
      case response_or_error do
        %Req.TransportError{} ->
          updated = Req.Request.put_private(request, :ssl_fallback_attempted, true)
          fallback_opts = [connect_options: [transport_opts: [middlebox_comp_mode: false]]]
          {Req.Request.merge_options(updated, fallback_opts), response_or_error}

        _ ->
          {request, response_or_error}
      end
    end}
  end
end

# Usage
MyApp.HTTP.client() |> Req.get!(url: "https://finicky-server.example.com")
```

### Oban Telemetry Error Reporter

> Source: `Changelog.ObanReporter` — attaches to `[:oban, :job, :exception]`, extracts job metadata + measurements, forwards to Sentry.

```elixir
defmodule MyApp.ObanReporter do
  def attach do
    :telemetry.attach("oban-errors", [:oban, :job, :exception], &handle_event/4, [])
  end

  def handle_event([:oban, :job, _], measure, meta, _) do
    extra =
      meta.job
      |> Map.take([:id, :args, :meta, :queue, :worker, :attempt, :max_attempts])
      |> Map.merge(measure)

    Sentry.capture_exception(meta.reason, stacktrace: meta.stacktrace, extra: extra)
  end

  def handle_event(_event, _measure, _meta, _opts), do: :ok
end

# In application.ex start/2:
# MyApp.ObanReporter.attach()
```

### Cache with Cascade Deletion

> Source: `Changelog.Cache` — pattern-matched `delete/1` per struct type, NewsItem cascades to its referenced object, Episode fans out to podcast paths.

```elixir
defmodule MyApp.Cache do
  def delete(nil), do: :ok

  def delete(%Episode{} = ep) do
    ep = Repo.preload(ep, :podcast)
    delete_prefix("/#{ep.podcast.slug}/#{ep.slug}")
    delete_prefix("/#{ep.podcast.slug}")     # podcast listing
  end

  def delete(%NewsItem{} = item) do
    item = Repo.preload(item, :object)
    delete_key("response:/news/#{item.slug}")
    delete(item.object)                       # cascade to referenced entity
  end

  def delete(%Podcast{} = pod) do
    delete_prefix("podcasts")
    delete_prefix("/#{pod.slug}")
  end

  def delete(%Post{} = post), do: delete_key("response:/posts/#{post.slug}")

  defp delete_key(key), do: ConCache.delete(:app_cache, key)

  defp delete_prefix(prefix) do
    # Scan all keys — acceptable at moderate cache sizes
    ConCache.ets(:app_cache)
    |> :ets.tab2list()
    |> Enum.each(fn {key, _} ->
      if String.starts_with?(to_string(key), prefix), do: delete_key(key)
    end)
  end
end
```

### Subscription with Soft Delete

> Source: `Changelog.Subscription` — `unsubscribed_at` timestamp, re-subscribing clears it back to nil, `insert_or_update` reuses the same row.

```elixir
defmodule MyApp.Subscription do
  use Ecto.Schema
  import Ecto.{Changeset, Query}

  schema "subscriptions" do
    belongs_to :user, MyApp.User
    belongs_to :podcast, MyApp.Podcast
    field :unsubscribed_at, :utc_datetime
    field :context, :string            # how the subscription was created
    timestamps()
  end

  # Query scopes
  def subscribed(query), do: where(query, [s], is_nil(s.unsubscribed_at))
  def unsubscribed(query), do: where(query, [s], not is_nil(s.unsubscribed_at))

  def is_subscribed(%__MODULE__{unsubscribed_at: ts}), do: is_nil(ts)
  def is_subscribed(_), do: false

  # Re-subscribing clears unsubscribed_at — reuses same row
  def subscribe(user, podcast, context \\ "") do
    get_or_initialize(user, podcast)
    |> change(unsubscribed_at: nil, context: context)
    |> Repo.insert_or_update()
  end

  def unsubscribe(nil), do: false
  def unsubscribe(%__MODULE__{} = sub) do
    sub
    |> change(unsubscribed_at: DateTime.utc_now())
    |> Repo.update()
  end

  defp get_or_initialize(user, podcast) do
    case Repo.get_by(__MODULE__, user_id: user.id, podcast_id: podcast.id) do
      nil -> %__MODULE__{user_id: user.id, podcast_id: podcast.id}
      existing -> existing
    end
  end
end
```

---

## Edge/IoT Patterns (from ExNVR)

> Patterns extracted from [evercam/ex_nvr](https://github.com/evercam/ex_nvr) — a production network video recorder running on embedded Linux devices.

| Pattern | Purpose |
|---------|---------|
| **Tick-Based Threshold Monitor** | GenServer that triggers actions only after conditions persist for N consecutive checks - prevents thrashing on transient conditions |
| **Periodic System Status Collector** | GenServer that aggregates static info once and dynamic metrics (CPU, memory, uptime) on schedule |
| **Schedule Validation** | Validate time-based schedules with interval overlap detection using `reduce_while` |
| **Role-Based Authorization** | Pattern-matching authorization with Plug integration - admin/user roles |
| **NIF Module Pattern** | Two-module structure: NIF stubs + Elixir wrapper for native code integration |
| **Embedded Schema Validation** | Polymorphic `cast_embed` validation based on parent field (e.g., device type) |

### Tick-Based Threshold Monitor

> Source: `ExNVR.DiskMonitor` — per-device GenServer, 1-minute tick, must be over threshold for 5 consecutive ticks before taking action. Counter resets if condition clears even once.

```elixir
defmodule MyApp.DiskMonitor do
  use GenServer

  @interval_ms :timer.minutes(1)
  @threshold_percent 90
  @ticks_until_action 5
  @max_recordings_to_delete 30

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: opts[:name])
  end

  @impl true
  def init(opts) do
    schedule_tick()
    {:ok, %{path: opts[:path], full_ticks: 0}}
  end

  @impl true
  def handle_info(:tick, state) do
    usage = get_disk_usage(state.path)
    state = update_ticks(usage, state)
    schedule_tick()
    {:noreply, state}
  end

  # Over threshold long enough — take action, reset counter
  defp update_ticks(usage, %{full_ticks: ticks} = state)
       when usage >= @threshold_percent and ticks >= @ticks_until_action do
    delete_oldest_recordings(@max_recordings_to_delete)
    %{state | full_ticks: 0}
  end

  # Over threshold but not long enough — increment
  defp update_ticks(usage, state) when usage >= @threshold_percent do
    %{state | full_ticks: state.full_ticks + 1}
  end

  # Under threshold — reset counter (prevents thrashing)
  defp update_ticks(_usage, state), do: %{state | full_ticks: 0}

  defp schedule_tick, do: Process.send_after(self(), :tick, @interval_ms)

  defp get_disk_usage(path) do
    case :disksup.get_disk_info(String.to_charlist(path)) do
      [{_path, total, avail}] -> round((1 - avail / total) * 100)
      _ -> 0
    end
  end

  defp delete_oldest_recordings(count) do
    # Your batch deletion logic here
    Logger.info("Deleting #{count} oldest recordings to free disk space")
  end
end
```

### Periodic System Status Collector

> Source: `ExNVR.SystemStatus` — static info (hostname, serial, model) collected once in `init`, dynamic metrics (CPU, memory) collected every 15 seconds. External components can push data via `set/3`.

```elixir
defmodule MyApp.SystemStatus do
  use GenServer

  @collection_interval 15_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  def get_all, do: GenServer.call(__MODULE__, :get_all, :timer.seconds(20))
  def get(key), do: GenServer.call(__MODULE__, {:get, key}, :timer.seconds(20))
  def set(key, value), do: GenServer.cast(__MODULE__, {:set, key, value})

  @impl true
  def init(_opts) do
    state = collect_static_info()
    schedule_collection()
    {:ok, state}
  end

  @impl true
  def handle_info(:collect, state) do
    state = Map.merge(state, collect_dynamic_metrics())
    schedule_collection()
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_all, _from, state), do: {:reply, state, state}
  def handle_call({:get, key}, _from, state), do: {:reply, Map.get(state, key), state}

  @impl true
  def handle_cast({:set, key, value}, state), do: {:noreply, Map.put(state, key, value)}

  defp schedule_collection, do: Process.send_after(self(), :collect, @collection_interval)

  # Collected once — hardware doesn't change at runtime
  defp collect_static_info do
    %{
      version: Application.spec(:my_app, :vsn) |> to_string(),
      hostname: case :inet.gethostname(), do: ({:ok, h} -> List.to_string(h); _ -> "unknown"),
      serial: read_sys_file("/sys/firmware/devicetree/base/serial-number"),
      model: read_sys_file("/proc/device-tree/model")
    }
  end

  # Collected every 15 seconds
  defp collect_dynamic_metrics do
    %{
      cpu: %{
        load_avg: :cpu_sup.avg1() / 256,
        cores: :erlang.system_info(:logical_processors)
      },
      memory: :memsup.get_system_memory_data(),
      uptime:
        :erlang.statistics(:wall_clock)
        |> elem(0)
        |> div(1000)
    }
  end

  defp read_sys_file(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.replace(<<0>>, "")
        |> String.trim()
      _ -> nil
    end
  end
end
```

### Schedule Validation

> Source: `ExNVR.Model.Schedule` — week-based schedules keyed by day number, `reduce_while` for parsing and overlap detection, sorted intervals with boundary-safe comparison.

```elixir
defmodule MyApp.Schedule do
  @type interval :: %{start_time: Time.t(), end_time: Time.t()}

  @spec validate(map()) :: {:ok, map()} | {:error, atom()}
  def validate(schedule) when is_map(schedule) do
    with :ok <- validate_days(schedule),
         {:ok, parsed} <- parse_intervals(schedule),
         :ok <- check_all_overlaps(parsed) do
      {:ok, parsed}
    end
  end

  def scheduled?(schedule, %DateTime{} = dt) do
    day = Integer.to_string(Date.day_of_week(dt))
    time = DateTime.to_time(dt)
    case Map.get(schedule, day, []) do
      [] -> false
      intervals -> Enum.any?(intervals, &time_in_interval?(time, &1))
    end
  end

  defp validate_days(schedule) do
    if Enum.all?(Map.keys(schedule), &(&1 in ~w(1 2 3 4 5 6 7))),
      do: :ok, else: {:error, :invalid_schedule_days}
  end

  defp parse_intervals(schedule) do
    Enum.reduce_while(schedule, {:ok, %{}}, fn {day, intervals}, {:ok, acc} ->
      case parse_day_intervals(intervals) do
        {:ok, parsed} -> {:cont, {:ok, Map.put(acc, day, parsed)}}
        error -> {:halt, error}
      end
    end)
  end

  defp parse_day_intervals(intervals) do
    Enum.reduce_while(intervals, {:ok, []}, fn interval_str, {:ok, acc} ->
      case parse_interval(interval_str) do
        {:ok, interval} -> {:cont, {:ok, [interval | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp check_all_overlaps(schedule) do
    Enum.reduce_while(schedule, :ok, fn {_day, intervals}, :ok ->
      sorted = Enum.sort_by(intervals, & &1.start_time, Time)
      case check_overlap(sorted, nil) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  # Walk sorted intervals, compare each start to previous end
  defp check_overlap([], _prev_end), do: :ok
  defp check_overlap([interval | rest], nil), do: check_overlap(rest, interval.end_time)
  defp check_overlap([interval | rest], prev_end) do
    if Time.compare(interval.start_time, prev_end) in [:gt, :eq],
      do: check_overlap(rest, interval.end_time),
      else: {:error, :overlapping_intervals}
  end

  defp time_in_interval?(time, %{start_time: s, end_time: e}) do
    Time.compare(time, s) != :lt and Time.compare(time, e) != :gt
  end

  defp parse_interval(str) do
    case String.split(str, "-") do
      [start_str, end_str] ->
        with {:ok, start_time} <- Time.from_iso8601(start_str <> ":00"),
             {:ok, end_time} <- Time.from_iso8601(end_str <> ":59") do
          {:ok, %{start_time: start_time, end_time: end_time}}
        else
          _ -> {:error, :invalid_time_intervals}
        end
      _ -> {:error, :invalid_time_intervals}
    end
  end
end
```

### Role-Based Authorization

> Source: `ExNVR.Authorization` — 5 pattern-match clauses in priority order. Admin can do anything, regular users denied user/system management, allowed reads on everything else.

```elixir
defmodule MyApp.Authorization do
  @type resource :: :device | :recording | :user | :system
  @type action :: :read | :create | :update | :delete

  @spec authorize(User.t(), resource(), action()) :: :ok | {:error, :unauthorized}
  def authorize(%{role: :admin}, _resource, _action), do: :ok
  def authorize(%{role: :user}, :user, _action), do: {:error, :unauthorized}
  def authorize(%{role: :user}, :system, _action), do: {:error, :unauthorized}
  def authorize(%{role: :user}, _resource, :read), do: :ok
  def authorize(_, _, _), do: {:error, :unauthorized}
end

# In controllers — function-call authorization per action
defmodule MyAppWeb.DeviceController do
  def create(conn, params) do
    user = conn.assigns.current_user
    with :ok <- MyApp.Authorization.authorize(user, :device, :create),
         {:ok, device} <- Devices.create(params) do
      json(conn, device)
    end
  end
end

# In FallbackController
def call(conn, {:error, :unauthorized}) do
  conn
  |> put_status(403)
  |> json(%{error: "Forbidden"})
end
```

### NIF Module Pattern

> Source: `ExNVR.AV.VideoProcessor.NIF` + `ExNVR.AV.Encoder` — raw stubs return tuples, wrapper converts to typed structs. `@compile {:autoload, false}` prevents loading before `@on_load`.

```elixir
# Module 1: Raw NIF stubs — returns raw tuples from C
defmodule MyApp.VideoProcessor.NIF do
  @compile {:autoload, false}    # prevent loading before @on_load runs
  @on_load :__on_load__

  def __on_load__ do
    path = :filename.join(:code.priv_dir(:my_app), ~c"native/libvideoprocessor")
    :ok = :erlang.load_nif(path, 0)
  end

  # Stubs — replaced at load time by C functions
  def new_encoder(_codec, _params), do: :erlang.nif_error(:undef)
  def encode(_encoder, _data, _pts), do: :erlang.nif_error(:undef)
  def flush_encoder(_encoder), do: :erlang.nif_error(:undef)
  def new_decoder(_codec, _params), do: :erlang.nif_error(:undef)
  def decode(_decoder, _data, _pts), do: :erlang.nif_error(:undef)
end

# Module 2: Elixir wrapper — translates between Elixir types and NIF tuples
defmodule MyApp.VideoProcessor.Encoder do
  alias MyApp.VideoProcessor.NIF

  defmodule Packet do
    defstruct [:data, :dts, :pts, :keyframe]
  end

  def new(codec, opts) do
    # Translate Elixir options to NIF-friendly format
    nif_opts = %{
      width: opts[:width],
      height: opts[:height],
      time_base_num: elem(opts[:time_base], 0),    # split tuple for C
      time_base_den: elem(opts[:time_base], 1)
    }
    NIF.new_encoder(codec, nif_opts)
  end

  def encode(encoder, frame) do
    case NIF.encode(encoder, frame.data, frame.pts) do
      {:ok, raw_packets} -> {:ok, Enum.map(raw_packets, &to_packet/1)}
      {:error, _} = error -> error
    end
  end

  # Map raw NIF tuple to typed struct
  defp to_packet({data, dts, pts, keyframe}) do
    %Packet{data: data, dts: dts, pts: pts, keyframe: keyframe == 1}
  end
end
```

### Elixir as NIF Host

When using Rust NIFs via Rustler, these Elixir-side patterns are critical:

**Config-driven module swapping (test/prod):**
```elixir
# config/config.exs — default to real NIF
config :my_app, native_module: MyApp.Native

# config/test.exs — swap to mock
config :my_app, native_module: MyApp.MockNative

# In your context module — resolve at compile time
defmodule MyApp.Node do
  @native Application.compile_env!(:my_app, :native_module)

  def start(config), do: @native.start(config)
end
```

**`Application.compile_env` vs `Application.get_env`:**
- `compile_env` — inlined at compile time, Dialyzer can see the concrete module. Use for module swapping where you want compile-time guarantees.
- `get_env` — resolved at runtime. Use when the value might change or when compile-time resolution isn't needed.
- **Dialyzer caveat:** `compile_env` gives Dialyzer the concrete module type, so specs are checked. `get_env` returns `term()`, losing type info.

**Atom vs string keys across the NIF boundary:**
```elixir
# BAD: Elixir maps with atom keys sent to Rust NifMap
config = %{host: "localhost", port: 4001}
# Rust NifMap expects string keys by default — runtime crash!

# GOOD: Convert atom keys to strings before crossing the NIF boundary
config = %{"host" => "localhost", "port" => 4001}

# GOOD: Or use a NifStruct with a matching Elixir struct
config = %MyApp.Config{host: "localhost", port: 4001}
```

**Mock behaviour pattern for NIFs:**
```elixir
# Define a behaviour for the NIF interface
defmodule MyApp.NativeBehaviour do
  @callback start(map()) :: {:ok, reference()} | {:error, String.t()}
  @callback stop(reference()) :: :ok
end

# Real implementation loads the NIF
defmodule MyApp.Native do
  @behaviour MyApp.NativeBehaviour
  use Rustler, otp_app: :my_app, crate: "my_nif"

  @impl true
  def start(_config), do: :erlang.nif_error(:nif_not_loaded)
  @impl true
  def stop(_ref), do: :erlang.nif_error(:nif_not_loaded)
end

# Mock for testing
defmodule MyApp.MockNative do
  @behaviour MyApp.NativeBehaviour

  @impl true
  def start(_config), do: {:ok, make_ref()}
  @impl true
  def stop(_ref), do: :ok
end
```

### Embedded Schema with Type-Based Validation

> Source: `ExNVR.Model.Device` — `cast_embed` receives parent device type via `:with` option, each device type has completely different required fields and validation rules.

```elixir
defmodule MyApp.Device do
  use Ecto.Schema
  import Ecto.Changeset

  schema "devices" do
    field :name, :string
    field :type, Ecto.Enum, values: [:ip_camera, :webcam, :file]
    embeds_one :stream_config, StreamConfig, on_replace: :update
    timestamps()
  end

  def changeset(device, attrs) do
    device
    |> cast(attrs, [:name, :type])
    |> validate_required([:name, :type])
    |> validate_config()
  end

  # Pass parent type into embedded schema validation
  defp validate_config(changeset) do
    type = get_field(changeset, :type)
    cast_embed(changeset, :stream_config,
      required: true,
      with: &StreamConfig.changeset(&1, &2, type)
    )
  end
end

defmodule MyApp.Device.StreamConfig do
  use Ecto.Schema
  import Ecto.Changeset

  embedded_schema do
    field :stream_uri, :string      # IP cameras
    field :device_path, :string     # Webcams
    field :resolution, :string      # Webcams
    field :framerate, :integer      # Webcams
    field :filename, :string        # File sources
    field :duration, :integer       # File sources
  end

  def changeset(config, attrs, device_type) do
    config
    |> cast(attrs, __MODULE__.__schema__(:fields))
    |> validate_for_type(device_type)
  end

  # Each device type requires completely different fields
  defp validate_for_type(changeset, :ip_camera) do
    changeset
    |> validate_required([:stream_uri])
    |> validate_format(:stream_uri, ~r/^rtsp:\/\//)
  end

  defp validate_for_type(changeset, :webcam) do
    changeset
    |> validate_required([:device_path, :framerate])
    |> validate_format(:resolution, ~r/^\d+x\d+$/)
    |> validate_number(:framerate, greater_than_or_equal_to: 5, less_than_or_equal_to: 30)
  end

  defp validate_for_type(changeset, :file) do
    changeset
    |> validate_required([:filename, :duration])
  end
end
```

---

## Job Processing Patterns (from Oban)

> Patterns extracted from [oban-bg/oban](https://github.com/oban-bg/oban) source code — the standard Elixir job processing library.

| Pattern | Purpose |
|---------|---------|
| **Worker Behaviour with Macro** | `__using__` macro with `defoverridable` defaults for backoff/timeout. Return types control lifecycle: `:ok` completes, `{:error, _}` retries, `{:cancel, _}` terminates |
| **Pluggable Engine** | Behaviour with `@optional_callbacks` for swappable backends (Basic, Inline, Lite, Dolphin) |
| **Validation with Smart Suggestions** | Type-checking options with `String.jaro_distance` for typo suggestions |
| **Exponential Backoff with Jitter** | `min_pad + mult * 2^min(attempt, max_pow)` with `:inc/:dec/:both` jitter modes to prevent thundering herd |
| **Dispatch Cooldown** | GenServer with coalesced timers - cooldown between dispatches, jittered refresh interval |
| **Leader Election** | Database peer table or `:global.set_lock/3` for cluster coordination |
| **Notifier (Distributed Signals)** | PubSub with gzip+base64 encoding, scoped by `:any` or specific ident |
| **Telemetry Integration** | `with_span/4` wrapping engine operations in `:telemetry.span/3` |
| **Cron Expression** | MapSet-based field matching with shortcuts (`@hourly`, `@daily`), step and range parsing |
| **CTE Optimization Fence** | Subquery CTE forces Postgres to respect LIMIT before `FOR UPDATE SKIP LOCKED` |
| **Job Assertion Helpers** | `assert_enqueued/1`, `refute_enqueued/1` with timeout polling and client-side JSON matching |

### Worker Behaviour with Macro

> Source: `Oban.Worker` — `defoverridable` injects defaults, `__opts__/0` stores compile-time config, return types control job lifecycle.

```elixir
defmodule MyApp.Worker do
  @type result ::
    :ok | {:ok, term()} | {:error, term()} |
    {:cancel, term()} | {:snooze, pos_integer()}

  @callback perform(job :: Oban.Job.t()) :: result()
  @callback backoff(job :: Oban.Job.t()) :: pos_integer()
  @callback timeout(job :: Oban.Job.t()) :: pos_integer() | :infinity

  defmacro __using__(opts) do
    quote location: :keep do
      @behaviour MyApp.Worker

      # Store compile-time options for runtime access
      @impl MyApp.Worker
      def __opts__, do: Keyword.put(unquote(opts), :worker, inspect(__MODULE__))

      @impl MyApp.Worker
      def backoff(%{attempt: attempt}) do
        # Default: exponential with jitter
        (15 + :math.pow(2, min(attempt, 10)) |> round())
        |> MyApp.Backoff.jitter(mode: :inc)
      end

      @impl MyApp.Worker
      def timeout(_job), do: :infinity

      defoverridable backoff: 1, timeout: 1
    end
  end
end

# Concrete worker — override only what differs
defmodule MyApp.EmailWorker do
  use MyApp.Worker, queue: :mailer, max_attempts: 5

  @impl MyApp.Worker
  def perform(%{args: %{"to" => to, "subject" => subject}}) do
    case Mailer.send(to, subject) do
      :ok -> :ok
      {:error, :temporary} -> {:snooze, 60}   # retry in 60s, preserves attempt count
      {:error, :invalid_address} -> {:cancel, "bad address"}  # stop permanently
      {:error, reason} -> {:error, reason}     # retries with backoff
    end
  end

  @impl MyApp.Worker
  def backoff(%{attempt: attempt}), do: attempt * 60  # linear for emails
end
```

### Pluggable Engine with Optional Callbacks

> Source: `Oban.Engine` — ~24 callbacks, `@optional_callbacks` for backends that don't need everything, `function_exported?/3` for graceful fallback.

```elixir
defmodule MyApp.Engine do
  @callback init(conf :: map(), opts :: keyword()) :: {:ok, meta :: map()}
  @callback insert_job(conf :: map(), changeset :: Changeset.t(), opts :: keyword()) ::
    {:ok, Job.t()} | {:error, term()}
  @callback fetch_jobs(conf :: map(), meta :: map(), running :: map()) ::
    {:ok, {meta :: map(), [Job.t()]}}
  @callback complete_job(conf :: map(), job :: Job.t()) :: :ok
  @callback stage_jobs(conf :: map(), meta :: map(), opts :: keyword()) :: {:ok, non_neg_integer()}

  @optional_callbacks [stage_jobs: 3]

  # Dispatch with fallback for optional callbacks
  def stage_jobs(conf, meta, opts) do
    if function_exported?(conf.engine, :stage_jobs, 3) do
      conf.engine.stage_jobs(conf, meta, opts)
    else
      MyApp.Engines.Basic.stage_jobs(conf, meta, opts)
    end
  end

  # Every engine operation wrapped in telemetry
  def insert_job(conf, changeset, opts) do
    with_span(:insert_job, conf, %{changeset: changeset}, fn engine ->
      engine.insert_job(conf, changeset, opts)
    end)
  end

  defp with_span(event, conf, base_meta, fun) do
    meta = Map.merge(base_meta, %{conf: conf, engine: conf.engine})
    :telemetry.span([:my_app, :engine, event], meta, fn ->
      result = fun.(conf.engine)
      {result, meta}
    end)
  end
end
```

### Validation with Smart Suggestions

> Source: `Oban.Validation` — `String.jaro_distance/2` with 0.7 threshold suggests corrections for misspelled option keys.

```elixir
defmodule MyApp.Validation do
  def validate_schema(opts, schema) when is_list(opts) and is_map(schema) do
    Enum.reduce_while(opts, :ok, fn {key, value}, :ok ->
      case Map.fetch(schema, key) do
        {:ok, type} ->
          case validate_type(key, value, type) do
            :ok -> {:cont, :ok}
            error -> {:halt, error}
          end
        :error ->
          {:halt, unknown_error(key, Map.keys(schema))}
      end
    end)
  end

  defp unknown_error(name, known) do
    name_str = to_string(name)
    known
    |> Enum.map(&{String.jaro_distance(name_str, to_string(&1)), &1})
    |> Enum.sort(:desc)
    |> case do
      [{score, field} | _] when score > 0.7 ->
        {:error, "unknown option :#{name}, did you mean :#{field}?"}
      _ ->
        {:error, "unknown option :#{name}"}
    end
  end

  defp validate_type(_key, val, :pos_integer) when is_integer(val) and val > 0, do: :ok
  defp validate_type(key, _val, :pos_integer), do: {:error, "#{key} must be a positive integer"}
  defp validate_type(_key, val, :atom) when is_atom(val), do: :ok
  defp validate_type(_key, val, {:in, allowed}) when val in allowed, do: :ok
  defp validate_type(key, val, {:in, allowed}),
    do: {:error, "#{key} must be one of #{inspect(allowed)}, got: #{inspect(val)}"}
end
```

### Exponential Backoff with Jitter

> Source: `Oban.Backoff` — formula: `min_pad + mult * 2^min(attempt, max_pow)`, three jitter modes prevent thundering herd. Also includes `with_retry/2` for transient DB errors.

```elixir
defmodule MyApp.Backoff do
  def exponential(attempt, opts \\ []) do
    mult = Keyword.get(opts, :mult, 1)
    min_pad = Keyword.get(opts, :min_pad, 15)
    max_pow = Keyword.get(opts, :max_pow, 10)
    min_pad + mult * :math.pow(2, min(attempt, max_pow)) |> round()
  end

  def jitter(time, opts \\ []) do
    mode = Keyword.get(opts, :mode, :both)
    mult = Keyword.get(opts, :mult, 0.1)
    diff = trunc(:rand.uniform() * mult * time)
    case mode do
      :inc  -> time + diff                  # only increase
      :dec  -> time - diff                  # only decrease
      :both -> if(:rand.uniform() > 0.5, do: time + diff, else: time - diff)
    end
  end

  # Retry transient DB errors with exponential backoff
  def with_retry(fun, opts \\ []) do
    max = Keyword.get(opts, :max_retries, 10)
    attempt = Keyword.get(opts, :attempt, 1)
    try do
      fun.()
    rescue
      e in [DBConnection.ConnectionError, Postgrex.Error] ->
        if attempt < max do
          Process.sleep(exponential(attempt) |> jitter())
          with_retry(fun, Keyword.put(opts, :attempt, attempt + 1))
        else
          reraise e, __STACKTRACE__
        end
    end
  end
end
```

### Dispatch Cooldown

> Source: `Oban.Queue.Producer` — coalesced dispatch timer (skip scheduling if one is pending), jittered refresh with `:dec` mode so refresh fires 50-100% of base interval.

```elixir
defmodule MyApp.Producer do
  use GenServer

  defstruct [:queue, :dispatch_timer, :refresh_timer,
             dispatch_cooldown: 5, refresh_interval: 1_000]

  @impl true
  def init(opts) do
    state = %__MODULE__{
      queue: opts[:queue],
      dispatch_cooldown: opts[:dispatch_cooldown] || 5,
      refresh_interval: opts[:refresh_interval] || 1_000
    }
    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, schedule_dispatch(state)}

  @impl true
  def handle_info(:dispatch, state) do
    state = %{state | dispatch_timer: nil}    # clear timer ref
    case fetch_and_run_jobs(state) do
      {:ok, count} when count > 0 -> {:noreply, schedule_dispatch(state)}
      _ -> {:noreply, schedule_refresh(state)}
    end
  end

  def handle_info(:refresh, state), do: {:noreply, schedule_dispatch(state)}

  # Coalesce: skip if timer already pending
  defp schedule_dispatch(%{dispatch_timer: ref} = state)
       when is_reference(ref), do: state
  defp schedule_dispatch(state) do
    timer = Process.send_after(self(), :dispatch, state.dispatch_cooldown)
    %{state | dispatch_timer: timer}
  end

  # Jittered refresh — fires at 50-100% of base interval
  defp schedule_refresh(state) do
    delay = MyApp.Backoff.jitter(state.refresh_interval, mode: :dec, mult: 0.5)
    timer = Process.send_after(self(), :refresh, delay)
    %{state | refresh_timer: timer}
  end

  defp fetch_and_run_jobs(_state), do: {:ok, 0}
end
```

### Leader Election

> Source: `Oban.Peers.Database` — INSERT with ON CONFLICT on `oban_peers` table, 30-second election interval. Also `Oban.Peers.Global` using `:global.set_lock/3` for distributed Erlang.

```elixir
# Database-backed leader election (primary approach)
defmodule MyApp.Peer.Database do
  use GenServer

  @election_interval 30_000

  defstruct [:conf, :leader?, :timer]

  @impl true
  def init(conf), do: {:ok, %__MODULE__{conf: conf, leader?: false}, {:continue, :election}}

  @impl true
  def handle_continue(:election, state), do: {:noreply, run_election(state)}

  @impl true
  def handle_info(:election, state), do: {:noreply, run_election(state)}

  @impl true
  def handle_call(:leader?, _from, state), do: {:reply, state.leader?, state}

  defp run_election(state) do
    leader? = try_acquire_leadership(state.conf)
    if leader? != state.leader?,
      do: notify_leadership_change(state.conf, leader?)
    schedule_election()
    %{state | leader?: leader?}
  end

  defp try_acquire_leadership(conf) do
    peer_data = %{name: conf.name, node: conf.node, expires_at: expires_at()}

    # Leader refreshes expiry; non-leader INSERT is a no-op on conflict
    case Repo.insert_all("oban_peers", [peer_data],
           conflict_target: :name,
           on_conflict: if(conf.leader?, do: [set: [expires_at: peer_data.expires_at]], else: :nothing)) do
      {0, nil} -> false    # conflict, someone else is leader
      {_, nil} -> true     # inserted or updated successfully
    end
  end

  defp expires_at, do: DateTime.add(DateTime.utc_now(), @election_interval * 2, :millisecond)
  defp schedule_election, do: Process.send_after(self(), :election, @election_interval)
  defp notify_leadership_change(_conf, _leader?), do: :ok
end

# Distributed Erlang alternative using :global locks
defmodule MyApp.Peer.Global do
  def try_acquire(conf) do
    key = {conf.name, conf.node}
    :global.set_lock(key, Node.list([:visible, :this]), 0)  # non-blocking
  end

  def release(conf) do
    :global.del_lock({conf.name, conf.node}, Node.list([:visible, :this]))
  end
end
```

### Notifier for Distributed Signals

> Source: `Oban.Notifier` — payloads gzip-compressed and base64-encoded, scoped by ident so multiple Oban instances on the same PubSub don't interfere. Legacy fallback for uncompressed payloads.

```elixir
defmodule MyApp.Notifier do
  @channels [:insert, :signal, :leader]

  def listen(conf, channel) when channel in @channels do
    Phoenix.PubSub.subscribe(conf.pubsub, channel_name(conf, channel))
  end

  def notify(conf, channel, payload) when channel in @channels do
    encoded = encode(payload)
    Phoenix.PubSub.broadcast(conf.pubsub, channel_name(conf, channel),
      {:notification, channel, encoded})
  end

  def decode_and_dispatch(conf, channel, encoded) do
    with {:ok, payload} <- decode(encoded),
         true <- in_scope?(payload, conf) do
      {:ok, payload}
    end
  end

  # Compress payloads to fit within PG NOTIFY 8KB limit
  defp encode(payload) do
    payload
    |> Torque.encode!()
    |> :zlib.gzip()
    |> Base.encode64()
  end

  defp decode(encoded) do
    case Base.decode64(encoded) do
      {:ok, compressed} ->
        {:ok,
         compressed
         |> :zlib.gunzip()
         |> Torque.decode!()}
      :error -> {:ok, Torque.decode!(encoded)}    # legacy uncompressed fallback
    end
  end

  # Scope filtering — "any" broadcasts to all instances
  defp in_scope?(%{"ident" => "any"}, _conf), do: true
  defp in_scope?(%{"ident" => ident}, conf), do: conf.ident == ident
  defp in_scope?(_payload, _conf), do: true

  defp channel_name(conf, channel), do: "#{conf.prefix}:#{channel}"
end
```

### Cron Expression with MapSet

> Source: `Oban.Cron.Expression` — each field stored as MapSet for O(1) membership checks. Shortcuts are pattern-matched function heads, not a map lookup. `@reboot` sets a boolean flag.

```elixir
defmodule MyApp.Cron do
  defstruct [:input, :minutes, :hours, :days, :months, :weekdays, reboot?: false]

  def parse("@annually"), do: parse("0 0 1 1 *")
  def parse("@yearly"),   do: parse("0 0 1 1 *")
  def parse("@monthly"),  do: parse("0 0 1 * *")
  def parse("@weekly"),   do: parse("0 0 * * 0")
  def parse("@daily"),    do: parse("0 0 * * *")
  def parse("@hourly"),   do: parse("0 * * * *")
  def parse("@reboot"),   do: {:ok, %__MODULE__{input: "@reboot", reboot?: true}}

  def parse(input) do
    case String.split(input, " ", trim: true) do
      [min, hr, day, mon, dow] ->
        {:ok, %__MODULE__{
          input: input,
          minutes: parse_field(min, 0..59),
          hours: parse_field(hr, 0..23),
          days: parse_field(day, 1..31),
          months: parse_field(mon, 1..12),
          weekdays: parse_field(dow, 0..6)
        }}
      _ -> {:error, "invalid cron expression: #{input}"}
    end
  end

  def now?(%__MODULE__{reboot?: true}, _dt), do: true
  def now?(%__MODULE__{} = cron, %DateTime{} = dt) do
    dow = Date.day_of_week(dt) |> rem(7)
    MapSet.member?(cron.minutes, dt.minute) and
      MapSet.member?(cron.hours, dt.hour) and
      MapSet.member?(cron.days, dt.day) and
      MapSet.member?(cron.months, dt.month) and
      MapSet.member?(cron.weekdays, dow)
  end

  defp parse_field("*", range), do: MapSet.new(range)
  defp parse_field("*/" <> step, range) do
    range
    |> Enum.take_every(String.to_integer(step))
    |> MapSet.new()
  end
  defp parse_field(expr, range) do
    expr
    |> String.split(",")
    |> Enum.flat_map(&parse_part(&1, range))
    |> MapSet.new()
  end

  defp parse_part(part, range) do
    if String.contains?(part, "-") do
      [from, to] = String.split(part, "-") |> Enum.map(&String.to_integer/1)
      Enum.filter(range, &(&1 >= from and &1 <= to))
    else
      [String.to_integer(part)]
    end
  end
end
```

### CTE Optimization Fence

> Source: `Oban.Engines.Basic.fetch_jobs/3` — CTE forces Postgres to materialize the SELECT with LIMIT before the UPDATE. Without this, Postgres could inline the subquery and lock more rows than intended.

```elixir
defmodule MyApp.JobRepo do
  import Ecto.Query

  def fetch_available_jobs(queue, limit) do
    # CTE: materialize this first — prevents Postgres from inlining
    subset =
      from(j in "jobs",
        where: j.state == "available" and j.queue == ^queue,
        order_by: [asc: j.priority, asc: j.scheduled_at, asc: j.id],
        limit: ^limit,
        lock: "FOR UPDATE SKIP LOCKED",
        select: [:id]
      )

    # Outer query joins against materialized CTE
    query =
      from(j in "jobs")
      |> with_cte("subset", as: ^subset)
      |> join(:inner, [j], x in fragment(~s("subset")), on: j.id == x.id)
      |> where([j, _], j.attempt < j.max_attempts)
      |> select([j, _], j)

    updates = [
      set: [state: "executing", attempted_at: DateTime.utc_now()],
      inc: [attempt: 1]
    ]

    Repo.transaction(fn ->
      {_count, jobs} = Repo.update_all(query, updates)
      jobs
    end)
  end
end
```

### Job Assertion Helpers

> Source: `Oban.Testing` — two arities: immediate check and polling with timeout. JSON fields matched client-side with recursive `contains?/2`, not PostgreSQL `@>`.

```elixir
defmodule MyApp.JobCase do
  use ExUnit.CaseTemplate
  @wait_interval 10

  using do
    quote do
      import MyApp.JobCase
    end
  end

  def assert_enqueued(opts) do
    jobs = filter_jobs(opts)
    assert length(jobs) > 0,
      "expected job matching #{inspect(opts)}, found none"
    jobs
  end

  # Polling variant — retries every 10ms until timeout
  def assert_enqueued(opts, timeout) when timeout > 0 do
    if job_exists?(opts) do
      true
    else
      Process.sleep(@wait_interval)
      assert_enqueued(opts, timeout - @wait_interval)
    end
  end
  def assert_enqueued(opts, _timeout), do: assert_enqueued(opts)

  def refute_enqueued(opts) do
    jobs = filter_jobs(opts)
    assert jobs == [],
      "expected no jobs matching #{inspect(opts)}, found #{length(jobs)}"
  end

  defp filter_jobs(opts) do
    {json_opts, base_opts} = Keyword.split(opts, [:args, :meta])

    base_query(base_opts)
    |> Repo.all()
    |> Enum.filter(fn job ->
      Enum.all?(json_opts, &json_match?(&1, job))
    end)
  end

  defp base_query(opts) do
    query = from(j in Job, where: j.state in ["available", "scheduled"])
    query
    |> maybe_filter(:worker, opts[:worker])
    |> maybe_filter(:queue, opts[:queue])
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, :worker, w),
    do: from(j in query, where: j.worker == ^to_string(w))
  defp maybe_filter(query, :queue, q),
    do: from(j in query, where: j.queue == ^to_string(q))

  # Client-side recursive map matching
  defp json_match?({:args, expected}, job), do: contains?(expected, job.args)
  defp json_match?({:meta, expected}, job), do: contains?(expected, job.meta)

  defp contains?(expected, actual) when is_map(expected) and is_map(actual) do
    Enum.all?(expected, fn {k, v} ->
      Map.has_key?(actual, k) and contains?(v, Map.get(actual, k))
    end)
  end
  defp contains?(expected, actual), do: expected == actual

  defp job_exists?(opts), do: filter_jobs(opts) != []
end
```

---

## Telemetry

The `:telemetry` library is the standard way to instrument Elixir applications. Phoenix, Ecto, Oban, and Broadway all emit telemetry events automatically. See also the [Oban Telemetry Error Reporter](#oban-telemetry-error-reporter) pattern above for a real-world `:telemetry.attach` example.

**Core API:**

```elixir
# Emit an event (in your application code)
:telemetry.execute(
  [:my_app, :orders, :created],              # event name (list of atoms)
  %{count: 1, total_cents: order.total},     # measurements (numbers)
  %{order_id: order.id}                      # metadata (any data)
)

# Listen for events (in your telemetry module or application startup)
:telemetry.attach("my-handler",
  [:my_app, :orders, :created],              # event to listen for
  &MyApp.Telemetry.handle_event/4,           # handler (use & capture, not anon fn)
  nil                                        # config passed to handler
)

# Listen for multiple events with one handler
:telemetry.attach_many("my-handler",
  [[:phoenix, :endpoint, :stop], [:my_app, :repo, :query]],
  &MyApp.Telemetry.handle_event/4, nil
)
```

**`:telemetry.span/3` — instrument a block (emits start + stop/exception automatically):**

```elixir
result = :telemetry.span([:my_app, :external_api], %{url: url}, fn ->
  result = HTTPClient.get(url)
  {result, %{status: result.status}}     # {return_value, stop_metadata}
end)
# Emits: [:my_app, :external_api, :start]  with %{monotonic_time:, system_time:}
# Emits: [:my_app, :external_api, :stop]   with %{duration:} on success
# Emits: [:my_app, :external_api, :exception] with %{duration:} on failure
```

**Built-in events from Phoenix, Ecto, and Oban:**

| Library | Event | Measurements |
|---------|-------|-------------|
| Phoenix | `[:phoenix, :endpoint, :stop]` | `%{duration: native_time}` |
| Phoenix | `[:phoenix, :router_dispatch, :stop]` | `%{duration: native_time}` |
| Ecto | `[:my_app, :repo, :query]` | `%{total_time:, query_time:, queue_time:, decode_time:}` |
| Oban | `[:oban, :job, :stop]` | `%{duration:, queue_time:}` |
| Broadway | `[:broadway, :processor, :stop]` | `%{duration:}` |

**Slow query logger example:**

```elixir
:telemetry.attach("slow-queries", [:my_app, :repo, :query],
  fn _event, measurements, metadata, _config ->
    ms = System.convert_time_unit(measurements.total_time, :native, :millisecond)
    if ms > 100, do: Logger.warning("Slow query (#{ms}ms): #{metadata.query}")
  end, nil)
```

**Telemetry.Metrics — declarative metric definitions for dashboards/reporters:**

```elixir
import Telemetry.Metrics

def metrics do
  [
    summary("phoenix.endpoint.stop.duration", unit: {:native, :millisecond}),
    summary("my_app.repo.query.total_time", unit: {:native, :millisecond}),
    counter("my_app.orders.created.count"),
    distribution("my_app.external_api.request.duration",
      unit: {:native, :millisecond}, buckets: [100, 250, 500, 1000]),
    summary("vm.memory.total", unit: {:byte, :megabyte})
  ]
end
```

VM metrics (`:vm.memory`, `:vm.total_run_queue_lengths`) require the `:telemetry_poller` dependency.

**Custom telemetry module — multi-clause handler with logging:**

```elixir
defmodule MyApp.Telemetry do
  require Logger

  def attach_default_logger(opts \\ []) do
    events = [[:my_app, :job, :start], [:my_app, :job, :stop], [:my_app, :job, :exception]]
    :telemetry.attach_many("my-app-logger", events, &handle_event/4, opts)
  end

  defp handle_event([:my_app, :job, :start], _, meta, _),
    do: Logger.info("[Job] Starting #{meta.worker}")
  defp handle_event([:my_app, :job, :stop], m, meta, _),
    do: Logger.info("[Job] Completed #{meta.worker} in #{div(m.duration, 1_000_000)}ms")
  defp handle_event([:my_app, :job, :exception], _, meta, _),
    do: Logger.error("[Job] Failed #{meta.worker}: #{inspect(meta.reason)}")
end
```

> **Note:** PREFER `:telemetry.span/3` over manual start/stop emission. Only implement a custom `with_span` if you need non-standard metadata or measurement handling that `:telemetry.span/3` doesn't support.

## HTTP Clients

**Req** is the modern default HTTP client for Elixir, built on Finch. Batteries included: JSON decode, retries, redirects, compression, auth.

```elixir
# deps: [{:req, "~> 0.5"}]

# Simple requests
resp = Req.get!("https://api.example.com/data")
resp = Req.post!("https://api.example.com/data", json: %{name: "test"})

# Reusable client with shared config (connection pooling)
client = Req.new(
  base_url: "https://api.example.com",
  auth: {:bearer, token},
  retry: :transient,          # retry on 408/429/500/502/503/504
  max_retries: 3,
  receive_timeout: 15_000
)
{:ok, resp} = Req.get(client, url: "/users")
{:ok, resp} = Req.post(client, url: "/users", json: %{name: "new"})

# Streaming large responses
Req.get!("https://example.com/large.csv", into: File.stream!("/tmp/out.csv"))
```

| Library | Use When |
|---------|----------|
| **Req** | Default choice. High-level, auto-JSON, retries, redirects, auth, compression. |
| **Finch** | Fine-grained connection pool control, HTTP/2 multiplexing, low-level streaming. |
| **HTTPoison** | Legacy projects only. No reason to choose for new projects. |

**Testing HTTP calls with Req.Test:**

```elixir
# config/test.exs
config :my_app, weather_req_options: [plug: {Req.Test, MyApp.Weather}]

# In your module — merge test options
def get_temperature(location) do
  [base_url: "https://weather-api.com", params: [q: location]]
  |> Keyword.merge(Application.get_env(:my_app, :weather_req_options, []))
  |> Req.request()
end

# In test (async-safe)
test "returns temperature" do
  Req.Test.stub(MyApp.Weather, fn conn ->
    Req.Test.json(conn, %{"celsius" => 25.0})
  end)
  assert {:ok, %{body: %{"celsius" => 25.0}}} = MyApp.Weather.get_temperature("Oslo")
end

# Simulate network errors
test "handles timeout" do
  Req.Test.stub(MyApp.Weather, fn conn ->
    Req.Test.transport_error(conn, :timeout)
  end)
  assert {:error, %Req.TransportError{reason: :timeout}} = MyApp.Weather.get_temperature("Oslo")
end
```

**Alternative: Mox + behaviour** for HTTP testing (works with any client):

```elixir
# Define behaviour → production impl → mock in test
defmodule MyApp.HTTPClient do
  @callback get(String.t(), keyword()) :: {:ok, map()} | {:error, term()}
end

# test_helper.exs
Mox.defmock(MyApp.HTTPClientMock, for: MyApp.HTTPClient)
```

## Plug halt/1 Semantics

`halt/1` sets a flag — it does NOT stop execution of the current plug:

```elixir
# halt/1 just sets halted: true on the conn
def halt(%Conn{} = conn), do: %{conn | halted: true}

# The compiled pipeline checks the flag BETWEEN plugs, not during
# Your plug must still return the conn after halting
def call(conn, _opts) do
  conn
  |> put_status(403)
  |> send_resp(403, "Forbidden")
  |> halt()   # Sets flag; subsequent plugs in pipeline are skipped
  # Code AFTER halt() in this function still executes!
end
```

## Mix Custom Tasks & Quality Aliases

### Custom Task

```elixir
defmodule Mix.Tasks.MyApp.Setup do
  use Mix.Task
  @shortdoc "Setup the application"

  @impl Mix.Task
  def run(args) do
    Mix.Task.run("deps.get", args)
    Mix.Task.run("ecto.setup", args)
  end
end
```

### Quality Alias

```elixir
# In mix.exs
defp aliases do
  [
    quality: [
      "compile --warnings-as-errors",
      "format --check-formatted",
      "credo --strict",
      "sobelow --strict",
      "dialyzer",
      "test --cover"
    ]
  ]
end
```

## OpenApiSpex (API Documentation & Validation)

OpenApiSpex generates OpenAPI 3.0 specs from Phoenix controllers and validates request/response payloads at runtime.

### Key Rule

**NEVER put Schema properties on Parameter** — `enum`, `default`, `minimum`, `maximum`, `pattern`, `format` all belong inside `%Schema{}`, not on `%Parameter{}` or `Operation.parameter/5`.

```elixir
# BAD — :enum is not a Parameter field (raises KeyError)
Operation.parameter(:status, :query, :string, "Filter by status",
  enum: ["active", "inactive"]
)

# GOOD — enum belongs in Schema
Operation.parameter(:status, :query,
  %Schema{type: :string, enum: ["active", "inactive"]},
  "Filter by status"
)
```

### Operation DSL

```elixir
defmodule MyAppWeb.ReadingController do
  use MyAppWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias OpenApiSpex.Schema

  tags ["readings"]

  operation :index,
    summary: "List sensor readings",
    parameters: [
      sensor_id: [in: :path, type: :string, description: "Sensor ID", required: true],
      status: [in: :query, schema: %Schema{type: :string, enum: ["active", "inactive"]}],
      limit: [in: :query, type: :integer, description: "Max results"]
    ],
    responses: [
      ok: {"Reading list", "application/json", ReadingListResponse}
    ]

  def index(conn, params) do
    # params are validated against the spec automatically (if plug is added)
  end
end
```

### Schema Modules

```elixir
defmodule MyAppWeb.Schemas.Reading do
  require OpenApiSpex
  alias OpenApiSpex.Schema

  OpenApiSpex.schema(%{
    title: "Reading",
    description: "A sensor reading",
    type: :object,
    required: [:sensor_id, :value, :timestamp],
    properties: %{
      sensor_id: %Schema{type: :string, format: :uuid},
      value: %Schema{type: :number, format: :float},
      unit: %Schema{type: :string, enum: ["celsius", "fahrenheit", "kelvin"]},
      timestamp: %Schema{type: :string, format: :"date-time"}
    }
  })
end
```

### Setup Essentials

```elixir
# mix.exs
{:open_api_spex, "~> 3.22"}

# router.ex — spec endpoint
scope "/api" do
  pipe_through :api
  get "/openapi", OpenApiSpex.Plug.RenderSpec, []
end

# Add validation plug to your API pipeline (optional but recommended)
plug OpenApiSpex.Plug.CastAndValidate, json_render_error_v2: true
```

### Common Mistakes

| Mistake | Fix |
|---------|-----|
| `enum:` on Parameter | Move into `%Schema{enum: [...]}` |
| Missing `required: true` on path params | Path params are always required — set explicitly |
| Schema module not compiled | Ensure `require OpenApiSpex` before `OpenApiSpex.schema/1` |
| Validation not running | Add `CastAndValidate` plug to pipeline |

## Library Authoring Patterns

For library authors (not web app authors), these patterns differ from Phoenix production patterns:

### Supervision for Libraries

```elixir
# Libraries should provide an optional supervisor, not require one
defmodule MyLib do
  use Application

  def start(_type, _args) do
    children = [
      {MyLib.Registry, []},
      {MyLib.ConnectionPool, pool_config()}
    ]
    Supervisor.start_link(children, strategy: :rest_for_one, name: MyLib.Supervisor)
  end

  defp pool_config do
    Application.get_env(:my_lib, :pool, [])
  end
end
```

### Precompiled NIFs with `rustler_precompiled`

```elixir
# mix.exs — support both precompiled and local compilation
defp deps do
  [
    {:rustler, ">= 0.0.0", optional: true},
    {:rustler_precompiled, "~> 0.8"}
  ]
end
```

### Library Telemetry Convention

```elixir
# Emit telemetry events with [:library_name, :operation] naming
:telemetry.execute(
  [:my_lib, :request, :stop],
  %{duration: duration},
  %{peer_id: peer_id, result: result}
)
```

## NimbleOptions for Configuration Validation

NimbleOptions is the standard library for validating keyword list options in Elixir. Used by Broadway, Finch, NimblePool, and dozens of other libraries. It provides declarative schema validation with auto-generated documentation.

### Basic Usage

```elixir
defmodule MyServer do
  @options_schema [
    host: [
      type: :string,
      required: true,
      doc: "Hostname to connect to."
    ],
    port: [
      type: :pos_integer,
      default: 4000,
      doc: "Port number."
    ],
    pool_size: [
      type: :pos_integer,
      default: 10,
      doc: "Number of connections in the pool."
    ],
    transport: [
      type: {:in, [:tcp, :ssl]},
      default: :tcp,
      doc: "Transport protocol."
    ],
    ssl_opts: [
      type: :keyword_list,
      default: [],
      doc: "SSL options passed to `:ssl.connect/3`.",
      keys: [
        verify: [type: {:in, [:verify_peer, :verify_none]}, default: :verify_peer],
        cacertfile: [type: :string]
      ]
    ]
  ]

  def start_link(opts) do
    opts = NimbleOptions.validate!(opts, @options_schema)
    # opts is now validated and defaults are applied
    GenServer.start_link(__MODULE__, opts)
  end
end
```

### Auto-Generated Documentation

```elixir
defmodule MyServer do
  @options_schema [...]

  @moduledoc """
  My server module.

  ## Options

  #{NimbleOptions.docs(@options_schema)}
  """
end
# Produces formatted Markdown with types, defaults, and descriptions
```

### Common Types

| Type | Validates |
|---|---|
| `:string` | Binary string |
| `:atom` | Atom |
| `:pos_integer` | Integer > 0 |
| `:non_neg_integer` | Integer >= 0 |
| `:boolean` | true/false |
| `{:in, list}` | Value is member of list |
| `:keyword_list` | Keyword list (with optional nested `:keys`) |
| `{:list, inner_type}` | List where all elements match inner_type |
| `{:or, [type1, type2]}` | Value matches any of the types |
| `{:custom, mod, fun, args}` | Custom validation function |
| `:mfa` | `{module, function, args}` tuple |
| `{:fun, arity}` | Function with given arity |

### Nested Validation with Recursive Schemas

```elixir
@schema [
  retry: [
    type: :keyword_list,
    doc: "Retry configuration.",
    keys: [
      max_attempts: [type: :pos_integer, default: 3],
      backoff: [type: {:in, [:linear, :exponential]}, default: :exponential],
      base_ms: [type: :pos_integer, default: 100]
    ]
  ]
]
```

**When to use NimbleOptions:**
- Library `start_link/1` or public API options
- Any keyword list that crosses a module boundary
- Configuration that needs auto-generated docs
- NOT for simple internal functions with 1-2 known options

## Related Files

- **[SKILL.md](SKILL.md)** — Core Elixir rules, BAD/GOOD pairs, decision frameworks
- **[otp-advanced.md](otp-advanced.md)** — GenServer patterns (coordinated shutdown, subscriber resubscription, Broadway integration)
- **[architecture-reference.md](architecture-reference.md)** — Pipeline architecture, configuration (compile_env vs runtime), refactoring guide
- **[testing-examples.md](testing-examples.md)** — Mox, Oban testing, process testing, property-based testing
- **[ecto-reference.md](ecto-reference.md)** — Changeset semantics, Ecto.Multi, telemetry events for queries
