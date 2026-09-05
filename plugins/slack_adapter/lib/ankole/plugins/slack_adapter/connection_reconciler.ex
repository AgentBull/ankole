defmodule Ankole.Plugins.SlackAdapter.ConnectionReconciler do
  @moduledoc false

  alias Ankole.{IdentityProviders, Logging, SignalsGateway}
  alias Ankole.Plugins.ConnectionLifecycle
  alias Ankole.Plugins.SlackAdapter.{Config, ConnectionSupervisor, IdentityProvider, Inbound}
  alias Ankole.SignalsGateway.{AdapterContext, Binding}

  @default_interval_ms 60_000

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}, type: :worker}
  end

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    ConnectionLifecycle.start_link(opts,
      name: __MODULE__,
      default_interval_ms: @default_interval_ms,
      reconcile_opts: Keyword.take(opts, [:repo]),
      reconcile: &run_reconcile/1
    )
  end

  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server \\ __MODULE__), do: ConnectionLifecycle.reconcile(server)

  @spec reconcile_async(GenServer.server()) :: :ok
  def reconcile_async(server \\ __MODULE__), do: ConnectionLifecycle.reconcile_async(server)

  @spec reconcile_once(keyword()) :: map()
  def reconcile_once(opts \\ []) do
    SignalsGateway.list_enabled_bindings("slack", Keyword.take(opts, [:repo]))
    |> connection_specs(opts)
    |> start_connections(opts)
  end

  defp run_reconcile(opts) do
    result = reconcile_once(opts)

    if result.errors != [],
      do:
        Logging.warning(
          "slack_adapter.connection_reconciliation.completed_with_errors",
          "Slack connection reconciliation completed with errors",
          %{errors: result.errors}
        )

    result
  end

  defp connection_specs(bindings, opts) do
    bindings
    |> Enum.reduce({%{}, []}, fn binding, acc -> add_binding(binding, acc, opts) end)
    |> add_identity_providers()
  end

  defp add_binding(%Binding{} = binding, {specs, errors}, _opts) do
    case binding_spec(binding) do
      {:ok, key, spec} ->
        merge_spec(
          specs,
          key,
          spec,
          %{
            agent_uid: binding.agent_uid,
            binding_name: binding.name,
            reason: :conflicting_app_secret
          },
          errors
        )

      {:error, reason} ->
        {specs,
         [%{agent_uid: binding.agent_uid, binding_name: binding.name, reason: reason} | errors]}
    end
  end

  defp add_identity_providers({specs, errors}) do
    case IdentityProviders.list_active_provider_refs("slack") do
      {:ok, providers} -> Enum.reduce(providers, {specs, errors}, &add_identity_provider/2)
      {:error, reason} -> {specs, [%{provider_id: nil, reason: reason} | errors]}
    end
  end

  defp add_identity_provider(provider, {specs, errors}) do
    case identity_spec(provider) do
      {:ok, key, spec} ->
        merge_spec(
          specs,
          key,
          spec,
          %{provider_id: provider["provider_id"], reason: :conflicting_app_secret},
          errors
        )

      :skip ->
        {specs, errors}

      {:error, reason} ->
        {specs, [%{provider_id: provider["provider_id"], reason: reason} | errors]}
    end
  end

  defp binding_spec(%Binding{} = binding) do
    with {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      context =
        AdapterContext.new(
          agent_uid: binding.agent_uid,
          binding_name: binding.name,
          adapter: binding.adapter,
          user_name: Map.get(config, "userName", "Slack")
        )

      {:ok, Config.connection_key(config),
       %{
         config: config,
         secret_fingerprint: Config.secret_fingerprint(config),
         consumers: [Inbound.chat_consumer(context, config)]
       }}
    else
      :error -> {:error, :chat_config_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp identity_spec(%{"provider_id" => provider_id, "config_key" => config_key}) do
    with {:ok, config} <- Config.load_identity_config_key(config_key),
         true <- realtime_identity_sync_enabled?(config) || :skip do
      {:ok, Config.connection_key(config),
       %{
         config: config,
         secret_fingerprint: Config.secret_fingerprint(config),
         consumers: [IdentityProvider.identity_consumer(provider_id, config)]
       }}
    else
      :skip -> :skip
      :error -> {:error, :identity_config_not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  defp realtime_identity_sync_enabled?(config) do
    get_in(config, ["sync", "contacts"]) != false and
      get_in(config, ["sync", "websocket"]) != false and
      is_binary(Map.get(config, "appToken"))
  end

  defp merge_spec(specs, key, spec, _conflict, errors) when not is_map_key(specs, key),
    do: {Map.put(specs, key, spec), errors}

  defp merge_spec(specs, key, spec, conflict, errors) do
    existing = Map.fetch!(specs, key)

    if existing.secret_fingerprint == spec.secret_fingerprint do
      {Map.put(specs, key, %{existing | consumers: spec.consumers ++ existing.consumers}), errors}
    else
      {specs, [conflict | errors]}
    end
  end

  defp start_connections({specs, errors}, _opts) do
    snapshot = ConnectionLifecycle.desired_snapshot(specs, errors)
    stopped = stop_undesired_connections(snapshot)

    results =
      Enum.map(
        Map.values(specs),
        &ConnectionSupervisor.ensure_started(&1.config, Enum.reverse(&1.consumers))
      )

    {started, failed} = Enum.split_with(results, &match?({:ok, _pid}, &1))

    %{
      started: length(started),
      stopped: stopped,
      errors:
        Enum.reverse(errors) ++ Enum.map(failed, fn {:error, reason} -> %{reason: reason} end)
    }
  end

  # Only a complete snapshot can prove that a registered connection is no
  # longer desired. A read error keeps the last live connection until recovery.
  defp stop_undesired_connections(snapshot) do
    ConnectionLifecycle.stop_undesired(
      snapshot,
      ConnectionSupervisor.registered_keys(),
      &ConnectionSupervisor.stop/1
    )
  end
end
