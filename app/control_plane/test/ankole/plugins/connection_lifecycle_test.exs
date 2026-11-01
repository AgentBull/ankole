defmodule Ankole.Plugins.ConnectionLifecycleTest do
  use Ankole.DataCase, async: false
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures, only: [start_connection_owner: 3]

  @registry Ankole.Plugins.ConnectionLifecycleTest.Registry
  @supervisor Ankole.Plugins.ConnectionLifecycleTest.Supervisor
  @warning_counter :connection_lifecycle_test_warning_counter
  @errors_event "connection_lifecycle_test_adapter.connection_reconciliation.completed_with_errors"

  defmodule Connections do
    use Ankole.Plugins.ConnectionLifecycle,
      adapter: "connection_lifecycle_test",
      registry: Ankole.Plugins.ConnectionLifecycleTest.Registry,
      supervisor: Ankole.Plugins.ConnectionLifecycleTest.Supervisor

    @impl true
    def binding_spec(%{config_ref: "bad"}, _opts), do: {:error, :bad_config}

    def binding_spec(%{config_ref: "raise", filters: filters}, _opts),
      do: raise(filters["cel"])

    def binding_spec(binding, _opts),
      do:
        {:ok,
         %{
           config: %{"key" => binding.config_ref, "secret" => binding.filters["cel"]},
           consumers: [%{agent_uid: binding.agent_uid}],
           secret_fingerprint: "same"
         }}

    @impl true
    def connection_key(config, _consumers), do: Map.fetch!(config, "key")

    @impl true
    def owner_child_spec(key, config, consumers) do
      name =
        {:via, Registry,
         {Ankole.Plugins.ConnectionLifecycleTest.Registry, key,
          Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

      %{id: key, start: {Agent, :start_link, [fn -> config end, [name: name]]}}
    end
  end

  defmodule TemporaryClient do
    use GenServer

    def start_link(opts) do
      case Keyword.fetch!(opts, :config) do
        %{"key" => "start_fails"} ->
          {:error, %{reason: "owner start refused", retry_at: DateTime.utc_now()}}

        _config ->
          GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
      end
    end

    @impl true
    def init(opts) do
      config = Keyword.fetch!(opts, :config)

      send(
        config["observer"],
        {:client_started, config["key"], self(), System.monotonic_time(:millisecond)}
      )

      if config["key"] == "fatal" and config["exit_counter"] do
        attempt = :ets.update_counter(config["exit_counter"], :attempt, 1)
        if attempt <= 10, do: send(self(), :exit)
      end

      {:ok, config}
    end

    @impl true
    def handle_info(:exit, state), do: {:stop, {:shutdown, :fatal}, state}
    def handle_info({:exit, reason}, state), do: {:stop, {:shutdown, reason}, state}
  end

  defmodule TemporaryConnections do
    use Ankole.Plugins.ConnectionLifecycle,
      adapter: "connection_lifecycle_test",
      registry: Ankole.Plugins.ConnectionLifecycleTest.Registry,
      supervisor: Ankole.Plugins.ConnectionLifecycleTest.Supervisor

    @impl true
    def binding_spec(%{config_ref: "blocked"}, _opts),
      do: {:blocked, "retry", :runtime_bot_identity_unavailable}

    def binding_spec(binding, opts) do
      {:ok, spec} = Connections.binding_spec(binding, opts)

      config =
        spec.config
        |> Map.put("observer", Keyword.fetch!(opts, :observer))
        |> Map.put("exit_counter", Keyword.get(opts, :exit_counter))

      {:ok, %{spec | config: config}}
    end

    @impl true
    def connection_key(config, consumers), do: Connections.connection_key(config, consumers)
    @impl true
    def owner_child_spec(key, config, consumers) do
      via =
        {:via, Registry,
         {Ankole.Plugins.ConnectionLifecycleTest.Registry, key,
          Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

      %{
        id: key,
        start: {TemporaryClient, :start_link, [[name: via, config: config]]},
        restart: :temporary
      }
    end
  end

  for timing <- [:during_restart, :after_restart] do
    @timing timing

    test "blocked connection recovers when its client exits #{@timing}" do
      %{principal: agent} = agent_fixture()

      assert {:ok, binding} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: "retry",
                 adapter: "connection_lifecycle_test",
                 config_ref: "retry"
               })

      name = {:global, {__MODULE__, make_ref()}}
      opts = [name: name, interval_ms: nil, observer: self()]
      start_supervised!({TemporaryConnections, opts})
      assert_receive {:client_started, "retry", original, _}, 1_000
      assert %{started: 1, errors: []} = TemporaryConnections.reconcile(name)
      assert [{^original, value}] = Registry.lookup(@registry, "retry")

      binding |> Ecto.Changeset.change(config_ref: "blocked") |> Repo.update!()

      assert %{errors: [%{reason: :runtime_bot_identity_unavailable}]} =
               TemporaryConnections.reconcile(name)

      supervisor = Process.whereis(@supervisor)
      stop_supervised!(TemporaryConnections)
      exit_before_restart(@timing, original)
      start_supervised!({TemporaryConnections, opts})

      assert %{errors: [%{reason: :runtime_bot_identity_unavailable}]} =
               TemporaryConnections.reconcile(name)

      exit_after_restart(@timing, original)
      assert_receive {:client_started, "retry", replacement, _}, 1_000
      refute replacement == original
      assert [{^replacement, ^value}] = Registry.lookup(@registry, "retry")
      assert Process.whereis(@supervisor) == supervisor
    end
  end

  # Forwards one adapter event's warnings to the test process.
  defmodule WarningCounter do
    def log(%{level: :warning, meta: %{event: event}}, %{config: %{pid: pid, event: event}}),
      do: send(pid, {:warning_logged, event})

    def log(_event, _config), do: :ok
  end

  test "an unchanged blocked reason logs one warning until it changes" do
    %{principal: agent} = agent_fixture()

    assert {:ok, binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "retry",
               adapter: "connection_lifecycle_test",
               config_ref: "blocked"
             })

    :ok =
      :logger.add_handler(@warning_counter, WarningCounter, %{
        config: %{pid: self(), event: @errors_event}
      })

    on_exit(fn -> :logger.remove_handler(@warning_counter) end)

    name = {:global, {__MODULE__, make_ref()}}
    start_supervised!({TemporaryConnections, name: name, interval_ms: nil, observer: self()})

    for _pass <- 1..5 do
      assert %{started: 0, errors: [%{reason: :runtime_bot_identity_unavailable}]} =
               TemporaryConnections.reconcile(name)
    end

    assert_receive {:warning_logged, @errors_event}
    refute_receive {:warning_logged, @errors_event}, 100

    assert {:ok, binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(binding, %{config_ref: "retry"})

    assert %{started: 1, errors: []} = TemporaryConnections.reconcile(name)
    assert_receive {:client_started, "retry", _client, _}, 1_000
    refute_receive {:warning_logged, @errors_event}, 100

    # The next occurrence after a recovery is a new warning.
    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(binding, %{config_ref: "blocked"})

    assert %{errors: [%{reason: :runtime_bot_identity_unavailable}]} =
             TemporaryConnections.reconcile(name)

    assert_receive {:warning_logged, @errors_event}
  end

  test "a repeated owner start failure with a moving retry time is one warning" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "start-fails",
               adapter: "connection_lifecycle_test",
               config_ref: "start_fails"
             })

    :ok =
      :logger.add_handler(@warning_counter, WarningCounter, %{
        config: %{pid: self(), event: @errors_event}
      })

    on_exit(fn -> :logger.remove_handler(@warning_counter) end)

    name = {:global, {__MODULE__, make_ref()}}
    start_supervised!({TemporaryConnections, name: name, interval_ms: nil, observer: self()})

    retry_times =
      for _pass <- 1..5 do
        assert %{started: 0, errors: [%{reason: "owner start refused", retry_at: retry_at}]} =
                 TemporaryConnections.reconcile(name)

        Process.sleep(2)
        retry_at
      end

    assert length(Enum.uniq(retry_times)) == 5
    assert_receive {:warning_logged, @errors_event}
    refute_receive {:warning_logged, @errors_event}, 100
    assert TemporaryConnections.registered_keys() == []
  end

  defp exit_before_restart(:during_restart, client), do: exit_client(client)
  defp exit_before_restart(:after_restart, _client), do: :ok
  defp exit_after_restart(:after_restart, client), do: exit_client(client)
  defp exit_after_restart(:during_restart, _client), do: :ok

  defp exit_client(client) do
    ref = Process.monitor(client)
    send(client, :exit)
    assert_receive {:DOWN, ^ref, :process, ^client, _}, 1_000
  end

  test "a disabled binding cannot return from a delayed retry or cached start arguments" do
    %{principal: agent} = agent_fixture()

    assert {:ok, binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "retry",
               adapter: "connection_lifecycle_test",
               config_ref: "retry"
             })

    name = {:global, {__MODULE__, make_ref()}}
    opts = [name: name, interval_ms: nil, restart_backoff_ms: [0, 200], observer: self()]
    start_supervised!({TemporaryConnections, opts})
    assert_receive {:client_started, "retry", first, _}, 1_000
    assert %{started: 1, errors: []} = TemporaryConnections.reconcile(name)
    exit_client(first)
    assert_receive {:client_started, "retry", second, _}, 1_000
    exit_client(second)
    binding |> Ecto.Changeset.change(enabled: false) |> Repo.update!()
    assert %{started: 0, errors: []} = TemporaryConnections.reconcile(name)
    refute_receive {:client_started, "retry", _, _}, 250

    stop_supervised!(TemporaryConnections)
    start_supervised!({TemporaryConnections, opts})
    assert %{started: 0, errors: []} = TemporaryConnections.reconcile(name)
    refute_receive {:client_started, "retry", _, _}, 250
    assert Registry.lookup(@registry, "retry") == []
  end

  setup do
    start_supervised!({Registry, keys: :unique, name: @registry})
    start_supervised!({DynamicSupervisor, name: @supervisor, strategy: :one_for_one})
    :ok
  end

  test "snapshot failures preserve the internal cause and healthy tenant without private logs" do
    secret = "private-connection-token-/srv/private/config"
    filter = ~s("#{secret}" == "#{secret}")
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "broken",
               adapter: "connection_lifecycle_test",
               config_ref: "raise",
               filters: %{"cel" => filter}
             })

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: agent} = agent_fixture()

      assert {:ok, _} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: agent.uid,
                 name: "healthy",
                 adapter: "connection_lifecycle_test",
                 config_ref: "healthy"
               })
    end)

    name = {:global, {__MODULE__, make_ref()}}

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        start_supervised!({Connections, name: name, interval_ms: nil})

        assert %{started: 1, errors: [%{reason: {:snapshot_failed, ^filter}}]} =
                 Connections.reconcile(name)

        assert [{healthy, {tenant_id, _}}] = Registry.lookup(@registry, "healthy")
        assert tenant_id == other.id
        assert Process.alive?(healthy)
      end)

    assert log =~ "plugins.connection_snapshot_failed"
    assert log =~ "connection_reconciliation.completed_with_errors"
    assert log =~ "error_count=1"
    assert log =~ "RuntimeError"
    assert log =~ "connection_lifecycle_test.exs"
    refute log =~ secret
  end

  test "client restart logs preserve lifecycle diagnostics without private exit causes" do
    secret = "private-connection-exit-/srv/private/connection"
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "retry",
               adapter: "connection_lifecycle_test",
               config_ref: "retry"
             })

    name = {:global, {__MODULE__, make_ref()}}

    log =
      ExUnit.CaptureLog.capture_log([format: "$metadata $message\n", metadata: :all], fn ->
        start_supervised!(
          {TemporaryConnections,
           name: name, interval_ms: nil, restart_backoff_ms: [0, 200], observer: self()}
        )

        assert_receive {:client_started, "retry", original, _}, 1_000
        assert %{started: 1, errors: []} = TemporaryConnections.reconcile(name)
        send(original, {:exit, %{token: secret}})
        assert_receive {:client_started, "retry", replacement, _}, 1_000
        refute replacement == original
        assert [{^replacement, _}] = Registry.lookup(@registry, "retry")
      end)

    assert log =~ "connection.client_exited"
    assert log =~ "failure=exit"
    assert log =~ "attempt=1"
    refute log =~ secret
  end

  test "temporary clients restart immediately once, then back off by key" do
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "retry",
               adapter: "connection_lifecycle_test",
               config_ref: "retry"
             })

    name = {:global, {__MODULE__, make_ref()}}

    start_supervised!(
      {TemporaryConnections,
       name: name, interval_ms: nil, restart_backoff_ms: [0, 200, 400], observer: self()}
    )

    assert_receive {:client_started, "retry", first, _}, 1_000
    assert %{started: 1, errors: []} = TemporaryConnections.reconcile(name)
    assert [{^first, value}] = Registry.lookup(@registry, "retry")
    send(first, :exit)
    assert_receive {:client_started, "retry", second, _}, 1_000
    refute first == second
    assert [{^second, ^value}] = Registry.lookup(@registry, "retry")
    started = System.monotonic_time(:millisecond)
    send(second, :exit)
    refute_receive {:client_started, "retry", _, _}, 150
    assert_receive {:client_started, "retry", third, second_time}, 1_000
    assert second_time - started >= 200
    started = System.monotonic_time(:millisecond)
    send(third, :exit)
    refute_receive {:client_started, "retry", _, _}, 350
    assert_receive {:client_started, "retry", fourth, third_time}, 1_000
    assert third_time - started >= 400
    assert [{^fourth, ^value}] = Registry.lookup(@registry, "retry")
  end

  test "ten exits immediately after startup leave the other tenant and supervisor alive", %{
    tenant: tenant
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: agent.uid,
               name: "fatal",
               adapter: "connection_lifecycle_test",
               config_ref: "fatal"
             })

    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: other_agent} = agent_fixture()

      assert {:ok, _} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: other_agent.uid,
                 name: "healthy",
                 adapter: "connection_lifecycle_test",
                 config_ref: "healthy"
               })
    end)

    assert Repo.tenant_id!() == tenant.id
    name = {:global, {__MODULE__, make_ref()}}
    counter = :ets.new(:connection_startup_failures, [:public])
    :ets.insert(counter, {:attempt, 0})

    start_supervised!(
      {TemporaryConnections,
       name: name,
       interval_ms: nil,
       restart_backoff_ms: [0, 1, 1],
       observer: self(),
       exit_counter: counter}
    )

    assert_receive {:client_started, "fatal", first, _}, 1_000
    assert_receive {:client_started, "healthy", healthy, _}, 1_000
    supervisor = Process.whereis(@supervisor)

    Enum.reduce(1..10, first, fn _attempt, client ->
      assert_receive {:client_started, "fatal", replacement, _}, 1_000
      refute client == replacement
      assert [{^healthy, {tenant_id, _}}] = Registry.lookup(@registry, "healthy")
      assert tenant_id == other.id
      assert Process.whereis(@supervisor) == supervisor
      assert Process.alive?(healthy)
      replacement
    end)

    assert [{:attempt, 11}] = :ets.lookup(counter, :attempt)
  end

  test "reconciliation reuses an owner and replaces it after the durable config changes" do
    %{principal: agent} = agent_fixture()

    attrs = %{
      agent_uid: agent.uid,
      name: "main",
      adapter: "connection_lifecycle_test",
      config_ref: "app",
      filters: %{"cel" => "true"}
    }

    assert {:ok, binding} = Ankole.SignalsFixtures.raw_binding_fixture(attrs)
    assert %{started: 1, errors: []} = Connections.reconcile_once()
    assert [{owner, _}] = Registry.lookup(@registry, "app")
    assert %{started: 1, errors: []} = Connections.reconcile_once()
    assert [{^owner, _}] = Registry.lookup(@registry, "app")

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(binding, %{filters: %{"cel" => "false"}})

    assert %{started: 1, errors: []} = Connections.reconcile_once()
    assert [{replacement, _}] = Registry.lookup(@registry, "app")
    refute replacement == owner
    refute Process.alive?(owner)
    assert Agent.get(replacement, & &1["secret"]) == "false"
  end

  test "lists only supervised owners as connections" do
    assert {:ok, _owner} =
             start_connection_owner(Connections, %{"key" => "app"}, [%{kind: :chat}])

    assert {:ok, _registered} = Registry.register(@registry, {:client, "app"}, nil)

    assert Connections.registered_keys() == ["app"]
  end

  test "stops owners that no enabled binding wants on startup and on request" do
    assert {:ok, zombie} =
             start_connection_owner(Connections, %{"key" => "zombie"}, [%{kind: :chat}])

    zombie_ref = Process.monitor(zombie)
    name = {:global, {__MODULE__, make_ref()}}

    start_supervised!({Connections, name: name, interval_ms: nil})
    assert_receive {:DOWN, ^zombie_ref, :process, ^zombie, _reason}

    assert {:ok, _owner} =
             start_connection_owner(Connections, %{"key" => "late"}, [%{kind: :chat}])

    assert %{started: 0, stopped: 1, errors: []} = Connections.reconcile(name)
    assert Connections.registered_keys() == []

    assert :ok = Connections.reconcile_async(name)
    assert %{started: 0, stopped: 0, errors: []} = Connections.reconcile(name)
  end

  test "one tenant's bad config retains only its own orphaned owner", %{tenant: tenant} do
    %{principal: first} = agent_fixture()

    {:ok, _} =
      Ankole.SignalsFixtures.raw_binding_fixture(%{
        agent_uid: first.uid,
        name: "old",
        adapter: "connection_lifecycle_test",
        config_ref: "first"
      })

    other = create_tenant()

    second =
      Repo.with_tenant(other.id, fn ->
        %{principal: second} = agent_fixture()

        {:ok, _} =
          Ankole.SignalsFixtures.raw_binding_fixture(%{
            agent_uid: second.uid,
            name: "old",
            adapter: "connection_lifecycle_test",
            config_ref: "second"
          })

        second
      end)

    assert %{started: 2, errors: []} = Connections.reconcile_once()

    {:ok, _} =
      Ankole.Signals.Bindings.disable_binding(
        Ankole.Signals.get_agent_binding!(first.uid, "old").id
      )

    {:ok, _} =
      Ankole.SignalsFixtures.raw_binding_fixture(%{
        agent_uid: first.uid,
        name: "bad",
        adapter: "connection_lifecycle_test",
        config_ref: "bad"
      })

    Repo.with_tenant(other.id, fn ->
      Ankole.Signals.Bindings.disable_binding(
        Ankole.Signals.get_agent_binding!(second.uid, "old").id
      )
    end)

    assert %{stopped: 1, errors: [%{tenant_id: id, reason: :bad_config}]} =
             Connections.reconcile_once()

    assert id == tenant.id
    assert Connections.registered_keys() == ["first"]
  end

  test "a conflicting new tenant cannot stop an existing owner" do
    %{principal: first} = agent_fixture()

    assert {:ok, _} =
             Ankole.SignalsFixtures.raw_binding_fixture(%{
               agent_uid: first.uid,
               name: "main",
               adapter: "connection_lifecycle_test",
               config_ref: "shared"
             })

    assert %{started: 1, errors: []} = Connections.reconcile_once()
    assert ["shared"] = Connections.registered_keys()
    other = create_tenant()

    Repo.with_tenant(other.id, fn ->
      %{principal: second} = agent_fixture()

      assert {:ok, _} =
               Ankole.SignalsFixtures.raw_binding_fixture(%{
                 agent_uid: second.uid,
                 name: "main",
                 adapter: "connection_lifecycle_test",
                 config_ref: "shared"
               })
    end)

    assert %{started: 1, stopped: 0, errors: [%{reason: :connection_tenant_mismatch}]} =
             Connections.reconcile_once()

    assert ["shared"] = Connections.registered_keys()
  end
end
