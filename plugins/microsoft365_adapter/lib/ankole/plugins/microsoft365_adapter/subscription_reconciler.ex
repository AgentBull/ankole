defmodule Ankole.Plugins.Microsoft365Adapter.SubscriptionReconciler do
  @moduledoc """
  Keeps Graph directory subscriptions aligned with active Entra providers.

  Runs at boot, on a periodic interval, and through the host's save-time
  reconcile hook (`connection_reconciler` in the identity declaration).
  Providers with realtime sync enabled get their subscriptions ensured and
  renewed; providers with it disabled get their subscriptions deleted. The
  interval sits far inside the 48-hour renewal window, so several missed runs
  cost nothing.
  """

  use GenServer

  alias Ankole.{IdentityProviders, Logging}
  alias Ankole.Plugins.Microsoft365Adapter.{Config, GraphSubscriptions}

  @default_interval_ms :timer.hours(6)
  @call_timeout 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @spec reconcile(GenServer.server()) :: map()
  def reconcile(server \\ __MODULE__), do: GenServer.call(server, :reconcile, @call_timeout)

  @spec reconcile_once(keyword()) :: map()
  def reconcile_once(opts \\ []) do
    case IdentityProviders.list_active_provider_refs("entra-id") do
      {:ok, providers} ->
        providers
        |> Enum.map(&reconcile_provider(&1, opts))
        |> Enum.reduce(%{ensured: 0, removed: 0, skipped: 0, errors: []}, &merge_result/2)

      {:error, reason} ->
        %{ensured: 0, removed: 0, skipped: 0, errors: [%{provider_id: nil, reason: reason}]}
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
       reconcile_opts: Keyword.take(opts, [:now])
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

    if result.errors != [],
      do:
        Logging.warning(
          "microsoft365_adapter.subscription_reconciliation.completed_with_errors",
          "Entra Graph subscription reconciliation completed with errors",
          %{errors: Enum.map(result.errors, &inspect/1)}
        )

    result
  end

  defp schedule_next(state) do
    Process.send_after(self(), :reconcile, state.interval_ms)
    state
  end

  defp reconcile_provider(%{"provider_id" => provider_id, "config_key" => config_key}, opts) do
    with {:ok, config} <- Config.load_identity_config_key(config_key) do
      if realtime_enabled?(config) do
        case GraphSubscriptions.ensure(provider_id, config, opts) do
          {:ok, _result} -> {:ensured, provider_id}
          {:error, reason} -> {:error, %{provider_id: provider_id, reason: reason}}
        end
      else
        case GraphSubscriptions.delete_all(provider_id, config) do
          {:ok, %{deleted: 0}} -> {:skipped, provider_id}
          {:ok, _result} -> {:removed, provider_id}
          {:error, reason} -> {:error, %{provider_id: provider_id, reason: reason}}
        end
      end
    else
      {:error, reason} -> {:error, %{provider_id: provider_id, reason: reason}}
    end
  end

  defp realtime_enabled?(config) do
    get_in(config, ["sync", "contacts"]) != false and
      get_in(config, ["sync", "realtime"]) == true
  end

  defp merge_result({:ensured, _provider_id}, acc), do: %{acc | ensured: acc.ensured + 1}
  defp merge_result({:removed, _provider_id}, acc), do: %{acc | removed: acc.removed + 1}
  defp merge_result({:skipped, _provider_id}, acc), do: %{acc | skipped: acc.skipped + 1}
  defp merge_result({:error, error}, acc), do: %{acc | errors: [error | acc.errors]}
end
