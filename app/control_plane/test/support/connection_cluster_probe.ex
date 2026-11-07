defmodule Ankole.Plugins.ConnectionClusterProbe do
  @moduledoc false

  use Ankole.Plugins.ConnectionLifecycle,
    adapter: "connection_lifecycle_cluster_test",
    registry: Ankole.Plugins.ConnectionClusterProbe.Registry,
    supervisor: Ankole.Plugins.ConnectionClusterProbe.Supervisor

  defmodule Owner do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      GenServer.start_link(__MODULE__, opts, name: Keyword.fetch!(opts, :name))
    end

    @impl true
    def init(opts) do
      config = Keyword.fetch!(opts, :config)

      if is_pid(config["observer"]) do
        send(config["observer"], {:cluster_owner_started, node(), config["key"], self(), config})
      end

      {:ok, config}
    end
  end

  def runtime_spec(opts) do
    Ankole.Plugins.ConnectionLifecycle.supervisor_spec(__MODULE__, [
      {Registry, keys: :unique, name: Ankole.Plugins.ConnectionClusterProbe.Registry},
      {DynamicSupervisor,
       name: Ankole.Plugins.ConnectionClusterProbe.Supervisor, strategy: :one_for_one},
      {__MODULE__, opts}
    ])
  end

  def start_runtime_link(opts) do
    {:ok, sup} =
      Supervisor.start_link(
        [
          {Registry, keys: :unique, name: Ankole.Plugins.ConnectionClusterProbe.Registry},
          {DynamicSupervisor,
           name: Ankole.Plugins.ConnectionClusterProbe.Supervisor, strategy: :one_for_one},
          {__MODULE__, opts}
        ],
        strategy: :rest_for_one
      )

    Process.unlink(sup)
    {:ok, sup}
  end

  def hold_registry_lock(key, notify_pid) do
    spawn(fn ->
      Registry.lock(
        Ankole.Plugins.ConnectionClusterProbe.Registry,
        {Ankole.Plugins.ConnectionLifecycle.Cluster, key},
        fn ->
          send(notify_pid, {:registry_lock_held, self()})

          receive do
            :release_registry_lock -> :ok
          end
        end
      )
    end)
  end

  @impl true
  def binding_spec(%{config_ref: "blocked"}, _opts),
    do: {:blocked, "handover", :runtime_bot_identity_unavailable}

  def binding_spec(binding, opts) do
    {:ok,
     %{
       config: %{
         "key" => binding.config_ref,
         "secret" => binding.filters["cel"],
         "observer" => Keyword.get(opts, :observer)
       },
       consumers: [%{agent_uid: binding.agent_uid}],
       secret_fingerprint: "same"
     }}
  end

  @impl true
  def connection_key(config, _consumers), do: Map.fetch!(config, "key")

  @impl true
  def owner_child_spec(key, config, consumers) do
    via =
      {:via, Registry,
       {Ankole.Plugins.ConnectionClusterProbe.Registry, key,
        Ankole.Plugins.ConnectionLifecycle.registry_value(config, consumers)}}

    %{
      id: key,
      start: {Owner, :start_link, [[name: via, config: config]]},
      restart: :permanent
    }
  end
end
