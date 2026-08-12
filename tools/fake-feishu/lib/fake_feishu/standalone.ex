defmodule FakeFeishu.Standalone do
  @moduledoc """
  Supervisor of the standalone fake Feishu server.

  Runs the EventHub, the platform State (owned by the hub, registered under
  `FakeFeishu.State`), one Bandit listener serving `FakeFeishu.Gateway` on a
  fixed port, and the seeder that provisions default chats for every
  registered or auto-registered app.
  """

  use Supervisor

  alias FakeFeishu.EventHub
  alias FakeFeishu.State

  @doc """
  Options:

    * `:port` — listen port (default 7788)
    * `:apps` — list of `{app_id, app_secret, bot_open_id | nil}`
    * `:users` — default persona names (default `["Alice", "Bob"]`)
    * `:cardkit` — emulate CardKit cards (default true; false answers card
      creation with code 200860 so the adapter uses its plain-text fallback)
    * `:strict_apps` — reject unknown app credentials instead of
      auto-registering them (default false)
  """
  def start_link(opts) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    port = Keyword.get(opts, :port, 7788)

    children = [
      {EventHub, name: EventHub},
      {State,
       name: State,
       owner: EventHub,
       auto_register_apps: not Keyword.get(opts, :strict_apps, false),
       cardkit_enabled: Keyword.get(opts, :cardkit, true)},
      {Bandit,
       plug: {FakeFeishu.Gateway, state: State},
       scheme: :http,
       ip: {127, 0, 0, 1},
       port: port,
       startup_log: false},
      {FakeFeishu.Standalone.Seeder,
       apps: Keyword.get(opts, :apps, []), users: Keyword.get(opts, :users, ["Alice", "Bob"])}
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end

defmodule FakeFeishu.Standalone.Seeder do
  @moduledoc """
  Registers the configured apps, seeds their default chats, and keeps seeding
  chats for apps the platform auto-registers at first authentication.
  """

  use GenServer

  alias FakeFeishu.EventHub
  alias FakeFeishu.Sim
  alias FakeFeishu.State

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts) do
    users = Keyword.fetch!(opts, :users)
    :ok = EventHub.attach_state(EventHub, State)

    for {app_id, app_secret, bot_open_id} <- Keyword.fetch!(opts, :apps) do
      register_opts = if bot_open_id, do: [bot_open_id: bot_open_id], else: []
      :ok = State.register_app(State, app_id, app_secret, register_opts)
      :ok = Sim.seed_default_chats(State, app_id, users)
    end

    :ok = EventHub.subscribe(EventHub, 0)
    {:ok, %{users: users}}
  end

  @impl true
  def handle_info({:hub_event, %{"type" => "app_auto_registered", "app_id" => app_id}}, state) do
    :ok = Sim.seed_default_chats(State, app_id, state.users)
    {:noreply, state}
  end

  # An app can authenticate between listener start and this subscription; the
  # backlog replay closes that window.
  def handle_info({:hub_backlog, events}, state) do
    for %{"type" => "app_auto_registered", "app_id" => app_id} <- events do
      :ok = Sim.seed_default_chats(State, app_id, state.users)
    end

    {:noreply, state}
  end

  def handle_info(_event, state), do: {:noreply, state}
end
