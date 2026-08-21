defmodule Ankole.Plugins.TelegramAdapter.ConnectionReconciler do
  @moduledoc false

  use GenServer

  alias Ankole.Logging
  alias Ankole.Plugins.TelegramAdapter.{Config, ConnectionSupervisor, Inbound}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.{AdapterContext, Binding}

  @default_interval_ms 30_000
  @call_timeout 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, @call_timeout)

  @spec reconcile_once(keyword()) :: map()
  def reconcile_once(opts \\ []) do
    bindings = SignalsGateway.list_enabled_bindings("telegram", Keyword.take(opts, [:repo]))
    {specs, config_errors} = build_specs(bindings)
    desired_keys = Map.keys(specs) |> MapSet.new()

    stopped =
      ConnectionSupervisor.registered_keys()
      |> Enum.reject(&MapSet.member?(desired_keys, &1))
      |> Enum.count(fn key -> ConnectionSupervisor.stop(key) == :ok end)

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

  @impl true
  def init(opts) do
    {:ok,
     %{
       interval_ms:
         Keyword.get(
           opts,
           :interval_ms,
           Application.get_env(
             :ankole,
             :signal_connection_reconcile_interval_ms,
             @default_interval_ms
           )
         ),
       reconcile_opts: Keyword.take(opts, [:repo])
     }, {:continue, :reconcile}}
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
        "telegram_adapter.connection_reconciliation.completed_with_errors",
        "Telegram connection reconciliation completed with errors",
        %{errors: result.errors}
      )
    end

    result
  end

  defp schedule_next(%{interval_ms: nil} = state), do: state

  defp schedule_next(state) do
    Process.send_after(self(), :reconcile, state.interval_ms)
    state
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
