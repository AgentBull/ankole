defmodule Ankole.Plugins.TelegramAdapter.ConnectionReconciler do
  @moduledoc false

  alias Ankole.Logging
  alias Ankole.Plugins.ConnectionLifecycle
  alias Ankole.Plugins.TelegramAdapter.{Config, ConnectionSupervisor, Inbound}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{AdapterContext, Binding}

  @default_interval_ms 30_000

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

  @spec reconcile_once(keyword()) :: map()
  def reconcile_once(opts \\ []) do
    bindings = SignalsGateway.list_enabled_bindings("telegram", Keyword.take(opts, [:repo]))
    {specs, config_errors} = build_specs(bindings)

    stopped =
      ConnectionLifecycle.stop_undesired(
        {:complete, specs},
        ConnectionSupervisor.registered_keys(),
        &ConnectionSupervisor.stop/1
      )

    results =
      Enum.map(specs, fn {_key, %{config: config, consumer: consumer}} ->
        ConnectionSupervisor.ensure_started(config, [consumer])
      end)

    {started, failed} = Enum.split_with(results, &match?({:ok, _pid}, &1))

    %{
      started: length(started),
      stopped: stopped,
      errors:
        Enum.reverse(config_errors) ++
          Enum.map(failed, fn {:error, reason} -> %{reason: reason} end)
    }
  end

  defp run_reconcile(opts) do
    result = reconcile_once(opts)

    if result.errors != [] do
      Logging.warning(
        "telegram_adapter.connection_reconciliation.completed_with_errors",
        "Telegram connection reconciliation completed with errors",
        %{errors: result.errors}
      )
    end

    result
  end

  defp build_specs(bindings) do
    Enum.reduce(bindings, {%{}, []}, fn %Binding{} = binding, {specs, errors} ->
      case Config.load_config_ref(binding.config_ref) do
        {:ok, config} ->
          context =
            AdapterContext.new(
              agent_uid: binding.agent_uid,
              binding_name: binding.name,
              adapter: binding.adapter,
              user_name: "Telegram"
            )

          key = {binding.agent_uid, binding.name}
          consumer = Inbound.chat_consumer(context, config)
          {Map.put(specs, key, %{config: config, consumer: consumer}), errors}

        :error ->
          {specs,
           [
             %{
               agent_uid: binding.agent_uid,
               binding_name: binding.name,
               reason: :config_not_found
             }
             | errors
           ]}

        {:error, reason} ->
          {specs,
           [%{agent_uid: binding.agent_uid, binding_name: binding.name, reason: reason} | errors]}
      end
    end)
  end
end
