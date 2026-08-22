defmodule Ankole.Plugins.WeComAdapter.ConnectionReconciler do
  @moduledoc """
  Reconciles enabled WeCom signal bindings into supervised long connections.

  Only the chat face holds a connection: the identity provider is pure REST
  (periodic directory sync, no realtime events), so unlike the DingTalk
  reconciler there are no identity consumers to merge. Bindings sharing one
  bot collapse to a single connection.
  """

  alias Ankole.Logging
  alias Ankole.Plugins.ConnectionLifecycle
  alias Ankole.Plugins.WeComAdapter.Config
  alias Ankole.Plugins.WeComAdapter.ConnectionSupervisor
  alias Ankole.Plugins.WeComAdapter.Inbound
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
    |> connection_specs()
    |> start_connections()
  end

  defp run_reconcile(opts) do
    result = reconcile_once(opts)

    if result.errors != [] do
      Logging.warning(
        "wecom_adapter.connection_reconciliation.completed_with_errors",
        "wecom adapter connection reconciliation completed with errors",
        %{errors: result.errors}
      )
    end

    result
  end

  defp enabled_bindings(opts) do
    SignalsGateway.list_enabled_bindings("wecom", Keyword.take(opts, [:repo]))
  end

  defp connection_specs(bindings) do
    Enum.reduce(bindings, {%{}, []}, fn binding, acc -> add_binding_spec(binding, acc) end)
  end

  defp add_binding_spec(%Binding{} = binding, {specs, errors}) do
    case binding_connection_spec(binding) do
      {:ok, key, spec} ->
        merge_connection_spec(
          specs,
          key,
          spec,
          binding_error(binding, :conflicting_bot_secret),
          errors
        )

      {:error, reason} ->
        {specs, [binding_error(binding, reason) | errors]}
    end
  end

  defp binding_connection_spec(%Binding{} = binding) do
    with {:ok, config} <- Config.load_chat_config_ref(binding.config_ref) do
      context =
        AdapterContext.new(
          agent_uid: binding.agent_uid,
          binding_name: binding.name,
          adapter: binding.adapter,
          user_name: Map.get(config, "userName", "企业微信 / WeCom")
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

  defp start_connections({specs, errors}) do
    stopped = stop_undesired_connections(specs)

    {started, start_errors} =
      specs
      |> Map.values()
      |> Enum.map(&ConnectionSupervisor.ensure_started(&1.config, Enum.reverse(&1.consumers)))
      |> Enum.split_with(&match?({:ok, _pid}, &1))

    %{
      started: length(started),
      stopped: stopped,
      errors:
        Enum.reverse(errors) ++
          Enum.map(start_errors, fn {:error, reason} -> %{reason: reason} end)
    }
  end

  # A live connection whose key left the desired spec map is a zombie (for
  # example a disabled binding) and stops.
  defp stop_undesired_connections(specs) do
    ConnectionLifecycle.stop_undesired(
      specs,
      ConnectionSupervisor.registered_keys(),
      &ConnectionSupervisor.stop/1
    )
  end

  defp binding_error(%Binding{} = binding, reason) do
    %{agent_uid: binding.agent_uid, binding_name: binding.name, reason: reason}
  end
end
