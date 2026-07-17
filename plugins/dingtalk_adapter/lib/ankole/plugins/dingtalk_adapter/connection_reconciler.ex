defmodule Ankole.Plugins.DingTalkAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled DingTalk signal bindings into supervised Stream connections.

  Bindings sharing one DingTalk app collapse to a single connection with a merged
  consumer list. Identity-provider consumers join the same connection so chat and
  login share one Stream socket.
  """

  use GenServer

  alias Ankole.IdentityProviders
  alias Ankole.Logging
  alias Ankole.Plugins.DingTalkAdapter.Config
  alias Ankole.Plugins.DingTalkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.DingTalkAdapter.IdentityProvider
  alias Ankole.Plugins.DingTalkAdapter.Inbound
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.Binding

  @default_interval_ms 60_000
  @call_timeout 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, @call_timeout)

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

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      reconcile_opts: Keyword.drop(opts, [:name, :interval_ms])
    }

    {:ok, state, {:continue, :reconcile}}
  end

  @impl true
  def handle_continue(:reconcile, state) do
    run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state), do: {:reply, run_reconcile(state), state}

  @impl true
  def handle_info(:reconcile, state) do
    run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  defp run_reconcile(state) do
    result = reconcile_once(state.reconcile_opts)

    if result.errors != [] do
      Logging.warning(
        "dingtalk_adapter.connection_reconciliation.completed_with_errors",
        "dingtalk adapter connection reconciliation completed with errors",
        %{errors: result.errors}
      )
    end

    result
  end

  defp schedule_next(%{interval_ms: interval_ms} = state) do
    Process.send_after(self(), :reconcile, interval_ms)
    state
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
         consumers: [Inbound.chat_consumer(context, config, materialize_attachments: true)]
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

  defp start_connections({specs, errors}, opts) do
    supervisor = Keyword.get(opts, :connection_supervisor, ConnectionSupervisor)

    supervisor_opts =
      Keyword.take(opts, [:registry, :supervisor, :start_client?, :client_opts, :ws_client_module])

    {started, start_errors} =
      specs
      |> Map.values()
      |> Enum.map(&start_connection(supervisor, &1, supervisor_opts))
      |> Enum.split_with(&match?({:ok, _pid}, &1))

    %{
      started: length(started),
      errors: Enum.reverse(errors) ++ Enum.map(start_errors, &start_error/1)
    }
  end

  defp start_connection(supervisor, spec, supervisor_opts) do
    supervisor.ensure_started(spec.config, Enum.reverse(spec.consumers), supervisor_opts)
  end

  defp binding_error(%Binding{} = binding, reason) do
    %{agent_uid: binding.agent_uid, binding_name: binding.name, reason: reason}
  end

  defp identity_provider_error(%{"provider_id" => provider_id}, reason) do
    %{provider_id: provider_id, reason: reason}
  end

  defp start_error({:error, reason}), do: %{reason: reason}
end
