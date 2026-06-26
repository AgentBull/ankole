defmodule Ankole.Plugins.LarkAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled Lark signal bindings into supervised long connections.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias Ankole.Plugins.LarkAdapter.Config
  alias Ankole.Plugins.LarkAdapter.ConnectionSupervisor
  alias Ankole.Plugins.LarkAdapter.IdentityProvider
  alias Ankole.Plugins.LarkAdapter.Inbound
  alias Ankole.Repo
  alias Ankole.IdentityProviders.Config, as: IdentityProviderConfig
  alias Ankole.SignalsGateway.AdapterContext
  alias Ankole.SignalsGateway.SignalBinding

  # Background cadence for re-deriving live connections from the database. This
  # is only drift correction: binding edits also fire an explicit reconcile_once/1,
  # so the timer just needs to catch anything that was missed, not be the primary
  # path — hence a relaxed 60s rather than a tight poll.
  @default_interval_ms 60_000
  # A reconcile pass reads bindings and starts supervised connections (DB plus
  # supervisor calls), so the synchronous reconcile/1 uses a long timeout well
  # above the 5s GenServer default.
  @call_timeout 30_000

  @doc """
  Starts the periodic connection reconciler.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Reconciles immediately through the supervised process.
  """
  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, @call_timeout)

  @doc """
  Reconciles enabled bindings once.

  This function is public so setup flows and tests can force a reconciliation
  after changing binding configuration without waiting for the periodic tick.
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
    # Reconcile once on startup so connections come up immediately, before the
    # first periodic tick, then fall into the timer-driven schedule.
    run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  @impl true
  def handle_call(:reconcile, _from, state) do
    {:reply, run_reconcile(state), state}
  end

  @impl true
  def handle_info(:reconcile, state) do
    run_reconcile(state)
    {:noreply, schedule_next(state)}
  end

  defp run_reconcile(state) do
    result = reconcile_once(state.reconcile_opts)

    if result.errors != [] do
      Logger.warning(
        "lark adapter connection reconciliation completed with errors=#{inspect(result.errors)}"
      )
    end

    result
  end

  defp schedule_next(%{interval_ms: interval_ms} = state) do
    Process.send_after(self(), :reconcile, interval_ms)
    state
  end

  # Loads the bindings that should currently have a live connection: this adapter
  # only, switched on, and not parked with an unavailable_reason (e.g. credentials
  # that previously failed). Ordering keeps the derived set stable across runs.
  defp enabled_bindings(opts) do
    repo = Keyword.get(opts, :repo, Repo)

    SignalBinding
    |> where([binding], binding.adapter == "lark")
    |> where([binding], binding.enabled == true)
    |> where([binding], is_nil(binding.unavailable_reason))
    |> order_by([binding], asc: binding.agent_uid, asc: binding.name)
    |> repo.all()
  end

  # Collapses bindings down to one spec per connection key, so several bindings
  # served by the same Lark app share a SINGLE long connection with a merged
  # consumer list instead of each opening a duplicate websocket. Returns the spec
  # map alongside any per-binding errors gathered along the way.
  defp connection_specs(bindings, opts) do
    bindings
    |> Enum.reduce({%{}, []}, &add_binding_spec/2)
    |> add_identity_provider_specs(opts)
  end

  defp add_binding_spec(%SignalBinding{} = binding, {specs, errors}) do
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
    case IdentityProviderConfig.active_providers() do
      {:ok, providers} ->
        providers
        |> Enum.filter(&lark_identity_provider?/1)
        |> Enum.reduce({specs, errors}, &add_identity_provider_spec/2)

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

  defp binding_connection_spec(%SignalBinding{} = binding) do
    with {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      context =
        AdapterContext.new(
          agent_uid: binding.agent_uid,
          binding_name: binding.name,
          adapter: binding.adapter,
          user_name: Map.get(config, "userName", "Lark / Feishu")
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
         true <- get_in(config, ["sync", "websocket"]) != false || :skip do
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
        # Same connection key but a different app secret means two configs
        # disagree about which Lark app owns this connection. Refuse instead of
        # letting one config's credentials silently win over the other's.
        {specs, [conflict_error | errors]}
    end
  end

  defp start_connections({specs, errors}, opts) do
    supervisor = Keyword.get(opts, :connection_supervisor, ConnectionSupervisor)

    supervisor_opts =
      Keyword.take(opts, [:registry, :supervisor, :start_client?, :client_opts, :ws_client_module])

    # Start each deduplicated connection, then partition successes from failures
    # so the caller receives a started-count plus a flat list of per-binding and
    # per-start errors.
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

  defp binding_error(%SignalBinding{} = binding, reason) do
    %{
      agent_uid: binding.agent_uid,
      binding_name: binding.name,
      reason: reason
    }
  end

  defp identity_provider_error(%{"provider_id" => provider_id}, reason) do
    %{
      provider_id: provider_id,
      reason: reason
    }
  end

  defp start_error({:error, reason}), do: %{reason: reason}

  defp lark_identity_provider?(%{"adapter_id" => "lark", "enabled" => enabled}),
    do: enabled != false

  defp lark_identity_provider?(_provider), do: false
end
