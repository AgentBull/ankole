defmodule Ankole.Plugins.DingTalkAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled DingTalk signal bindings into supervised Stream connections.

  Bindings sharing one DingTalk app collapse to a single connection with a merged
  consumer list. Identity-provider consumers join the same connection so chat and
  login share one Stream socket.
  """

  alias Ankole.IdentityProviders
  alias Ankole.Logging
  alias Ankole.Plugins.ConnectionLifecycle
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.DingTalkAdapter.IdentityProvider
  alias Ankole.Plugins.DingTalkAdapter.Inbound
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Binding

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

  @doc """
  Reconciles enabled bindings once. Public so setup flows and tests can force a
  reconciliation without waiting for the periodic tick.
  """
  @spec reconcile_once(keyword()) :: map()
  def reconcile_once(opts \\ []) do
    opts
    |> enabled_bindings()
    |> connection_specs(opts)
    |> start_connections(opts)
  end

  defp run_reconcile(opts) do
    result = reconcile_once(opts)

    if result.errors != [] do
      Logging.warning(
        "dingtalk_adapter.connection_reconciliation.completed_with_errors",
        "dingtalk adapter connection reconciliation completed with errors",
        %{errors: result.errors}
      )
    end

    result
  end

  defp enabled_bindings(opts) do
    SignalsGateway.list_enabled_bindings("dingtalk", Keyword.take(opts, [:repo]))
  end

  defp connection_specs(bindings, opts) do
    bindings
    |> Enum.reduce({%{}, []}, fn binding, acc -> add_binding_spec(binding, acc, opts) end)
    |> add_identity_provider_specs(opts)
  end

  defp add_binding_spec(%Binding{} = binding, {specs, errors}, _opts) do
    case binding_connection_spec(binding) do
      {:ok, key, spec} ->
        merge_connection_spec(
          specs,
          key,
          spec,
          binding_error(binding, :conflicting_app_secret),
          errors
        )

      {:error, reason} ->
        {specs, [binding_error(binding, reason) | errors]}
    end
  end

  defp add_identity_provider_specs({specs, errors}, _opts) do
    case IdentityProviders.list_active_provider_refs("dingtalk") do
      {:ok, providers} ->
        Enum.reduce(providers, {specs, errors}, &add_identity_provider_spec/2)

      {:error, reason} ->
        {specs, [%{provider_id: nil, reason: reason} | errors]}
    end
  end

  defp add_identity_provider_spec(provider, {specs, errors}) do
    case identity_provider_connection_spec(provider) do
      {:ok, key, spec} ->
        merge_connection_spec(
          specs,
          key,
          spec,
          identity_provider_error(provider, :conflicting_app_secret),
          errors
        )

      :skip ->
        {specs, errors}

      {:error, reason} ->
        {specs, [identity_provider_error(provider, reason) | errors]}
    end
  end

  defp binding_connection_spec(%Binding{} = binding) do
    with {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      context =
        AdapterContext.new(
          agent_uid: binding.agent_uid,
          binding_name: binding.name,
          adapter: binding.adapter,
          user_name: Map.get(config, "userName", "钉钉 / DingTalk")
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

  defp identity_provider_connection_spec(%{
         "provider_id" => provider_id,
         "config_key" => config_key
       }) do
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

  defp realtime_identity_sync_enabled?(config) when is_map(config) do
    get_in(config, ["sync", "contacts"]) != false and
      get_in(config, ["sync", "websocket"]) != false
  end

  defp merge_connection_spec(specs, key, spec, _conflict_error, errors)
       when not is_map_key(specs, key) do
    {Map.put(specs, key, spec), errors}
  end

  defp merge_connection_spec(specs, key, spec, conflict_error, errors) do
    existing = Map.fetch!(specs, key)

    case existing.secret_fingerprint == spec.secret_fingerprint do
      true ->
        {Map.put(specs, key, %{existing | consumers: spec.consumers ++ existing.consumers}),
         errors}

      false ->
        {specs, [conflict_error | errors]}
    end
  end

  defp start_connections({specs, errors}, _opts) do
    snapshot = ConnectionLifecycle.desired_snapshot(specs, errors)
    stopped = stop_undesired_connections(snapshot)

    {started, start_errors} =
      specs
      |> Map.values()
      |> Enum.map(&start_connection/1)
      |> Enum.split_with(&match?({:ok, _pid}, &1))

    %{
      started: length(started),
      stopped: stopped,
      errors: Enum.reverse(errors) ++ Enum.map(start_errors, &start_error/1)
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

  defp start_connection(spec),
    do: ConnectionSupervisor.ensure_started(spec.config, Enum.reverse(spec.consumers))

  defp binding_error(%Binding{} = binding, reason) do
    %{agent_uid: binding.agent_uid, binding_name: binding.name, reason: reason}
  end

  defp identity_provider_error(%{"provider_id" => provider_id}, reason) do
    %{provider_id: provider_id, reason: reason}
  end

  defp start_error({:error, reason}), do: %{reason: reason}
end
