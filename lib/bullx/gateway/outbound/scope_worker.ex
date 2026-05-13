defmodule BullX.Gateway.Outbound.ScopeWorker do
  @moduledoc false

  use GenServer

  alias BullX.Gateway.{
    Delivery,
    Outcome,
    Outbound.Finalizer,
    Outbound.Retry,
    Outbound.Store,
    Sources
  }

  @spec start_link(map()) :: GenServer.on_start()
  def start_link(scope) when is_map(scope) do
    GenServer.start_link(__MODULE__, scope, name: via(scope))
  end

  @spec child_spec(map()) :: Supervisor.child_spec()
  def child_spec(scope) do
    %{
      id: {__MODULE__, scope_key(scope)},
      start: {__MODULE__, :start_link, [scope]},
      restart: :transient,
      type: :worker
    }
  end

  @impl true
  def init(scope) do
    send(self(), :work)

    {:ok,
     %{
       scope: scope,
       worker_id: worker_id(),
       stale_lock_ms: gateway_config(:outbound_dispatch_stale_lock_ms, 60_000)
     }}
  end

  @impl true
  def handle_info(:work, state) do
    case do_work(state) do
      :continue ->
        send(self(), :work)
        {:noreply, state}

      :stop ->
        {:stop, :normal, state}
    end
  end

  defp do_work(state) do
    case Store.terminalizing_for_scope(state.scope) do
      %{} = row ->
        row
        |> Finalizer.finalize_dispatch()
        |> continue_after_result()

      nil ->
        claim_and_process(state)
    end
  end

  defp claim_and_process(state) do
    case Store.claim_due(state.scope, state.worker_id, state.stale_lock_ms) do
      %{} = row -> process_row(row)
      nil -> :stop
    end
  end

  defp process_row(row) do
    with {:ok, delivery} <- Delivery.normalize(row["delivery"]),
         {:ok, source} <- fetch_source(row),
         result <- call_adapter(source, delivery),
         :ok <- handle_adapter_result(row, delivery, source, result) do
      :continue
    else
      {:error, error} when is_map(error) ->
        terminal_result(handle_terminal_error(row, error))

      {:error, _reason} ->
        row
        |> handle_terminal_error(%{"kind" => "contract", "message" => "invalid dispatch row"})
        |> terminal_result()
    end
  end

  defp fetch_source(%{"adapter" => adapter, "channel_id" => channel_id}) do
    case Sources.fetch_enabled(adapter, channel_id) do
      {:ok, source} ->
        {:ok, source}

      {:error, :unknown_source} ->
        {:error, %{"kind" => "not_found", "message" => "Gateway source no longer exists"}}
    end
  end

  defp call_adapter(source, delivery) do
    metadata = %{
      adapter: delivery.adapter,
      channel_id: delivery.channel_id,
      scope_id: delivery.scope_id,
      delivery_id: delivery.id,
      generation: delivery.generation
    }

    :telemetry.span([:bullx, :gateway, :delivery], metadata, fn ->
      result = safe_adapter_call(source.adapter_module, delivery, source)
      {result, metadata}
    end)
  end

  defp safe_adapter_call(adapter_module, delivery, source) when is_atom(adapter_module) do
    adapter_module.deliver(delivery, source)
  catch
    :exit, reason -> {:error, exception_error(:exit, reason)}
    kind, reason -> {:error, exception_error(kind, reason)}
  end

  defp handle_adapter_result(row, delivery, _source, {:ok, outcome}) do
    case Outcome.from_adapter(delivery, outcome) do
      {:ok, outcome} ->
        capture_and_finalize(row, delivery, outcome)

      {:error, error} ->
        handle_terminal_error(row, error)
    end
  end

  defp handle_adapter_result(row, _delivery, source, {:error, error}) when is_map(error) do
    policy = Retry.policy(source.outbound_retry)

    case Retry.retry?(policy, error, row["attempts"]) do
      true ->
        backoff_ms = BullX.Retry.backoff_ms(policy, error, row["attempts"])
        Store.release_for_retry(row, error, backoff_ms)

      false ->
        handle_terminal_error(row, error)
    end
  end

  defp handle_adapter_result(row, _delivery, _source, _other) do
    handle_terminal_error(row, %{
      "kind" => "contract",
      "message" => "adapter returned invalid delivery result"
    })
  end

  defp handle_terminal_error(row, error) do
    with {:ok, delivery} <- Delivery.normalize(row["delivery"]),
         outcome <-
           Outcome.failed(delivery, error, attempts_exhausted?: attempts_exhausted?(error)),
         :ok <- capture_and_finalize(row, delivery, outcome) do
      :ok
    else
      _other -> {:error, :terminal_capture_failed}
    end
  end

  defp capture_and_finalize(row, delivery, outcome) do
    payload = Finalizer.terminal_payload(delivery, outcome, row["attempts"], true)

    with :ok <- Store.capture_dispatch_terminal(row, payload) do
      %{row | "terminal_outcome" => payload}
      |> Finalizer.finalize_dispatch()
      |> case do
        :ok -> :ok
        {:error, _reason} -> :ok
      end
    end
  end

  defp continue_after_result(:ok), do: :continue
  defp continue_after_result({:error, _reason}), do: :stop

  defp terminal_result(:ok), do: :continue
  defp terminal_result({:error, _reason}), do: :stop

  defp attempts_exhausted?(%{"details" => %{"attempts_exhausted" => true}}), do: true
  defp attempts_exhausted?(_error), do: false

  defp exception_error(kind, reason) do
    %{
      "kind" => "exception",
      "message" => "Gateway adapter delivery failed",
      "details" => %{"kind" => inspect(kind), "reason" => inspect(reason)}
    }
  end

  defp via(scope), do: {:via, Registry, {BullX.Gateway.ScopeRegistry, scope_key(scope)}}

  defp scope_key(scope), do: {scope.adapter, scope.channel_id, scope.scope_id}

  defp worker_id do
    node = node() |> Atom.to_string()
    "#{node}:#{inspect(self())}"
  end

  defp gateway_config(key, default) do
    :bullx
    |> Application.get_env(:gateway, [])
    |> Keyword.get(key, default)
  end
end
