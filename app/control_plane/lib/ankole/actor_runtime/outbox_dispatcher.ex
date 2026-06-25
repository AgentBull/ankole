defmodule Ankole.ActorRuntime.OutboxDispatcher do
  @moduledoc """
  Periodically dispatches provider-visible outbox rows through SignalsGateway.

  When a turn commits a side effect (a message to send, etc.) it records a
  durable outbox row inside the same transaction; this loop is what actually
  performs those effects against external providers. Polling is the source of
  truth for delivery — `wake/0` only shaves latency. The outbox row stays the
  durable record and carries its own retry metadata, so a crash or a missed tick
  just means the effect goes out on a later pass, never that it is lost.
  """

  use GenServer

  require Logger

  alias Ankole.SignalsGateway

  # Poll every 500ms: low enough that a freshly committed side effect reaches its
  # provider promptly even if the wake/0 nudge is missed, cheap enough to run
  # continuously.
  @default_interval_ms 500
  # Cap rows per pass so one busy tick can't monopolize provider calls or the DB;
  # leftover due rows are simply picked up on the next tick.
  @default_limit 25

  @doc """
  Starts the dispatcher.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one due-outbox dispatch pass.
  """
  @spec run_once(keyword()) :: [term()]
  def run_once(opts \\ []) do
    adapter_resolver = Keyword.get(opts, :adapter_resolver, &resolve_adapter/1)
    limit = Keyword.get(opts, :limit, @default_limit)

    SignalsGateway.dispatch_due_outbox(adapter_resolver, limit: limit)
  end

  @doc """
  Best-effort wakeup after a final proposal commits an outbox row.

  Periodic dispatch remains the recovery path. Waking only reduces latency after
  the commit transaction creates provider-visible work.
  """
  @spec wake() :: :ok
  def wake do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :wake)
    end
  end

  @impl true
  def init(opts) do
    state = %{
      interval_ms: Keyword.get(opts, :interval_ms, @default_interval_ms),
      limit: Keyword.get(opts, :limit, @default_limit),
      adapter_resolver: Keyword.get(opts, :adapter_resolver, &resolve_adapter/1)
    }

    {:ok, state, {:continue, :initial_dispatch}}
  end

  @impl true
  def handle_continue(:initial_dispatch, state) do
    dispatch(state)
    schedule_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    dispatch(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:dispatch, state) do
    dispatch(state)
    schedule_next(state)
    {:noreply, state}
  end

  # Dispatch failures are logged and retried by the next tick because outbox
  # rows are already durable and carry their own retry metadata.
  defp dispatch(state) do
    run_once(limit: state.limit, adapter_resolver: state.adapter_resolver)
    :ok
  rescue
    error ->
      Logger.warning("actor runtime outbox dispatch failed: #{Exception.message(error)}")
  end

  defp schedule_next(state) do
    Process.send_after(self(), :dispatch, state.interval_ms)
  end

  # Resolves the signal adapter at dispatch time. ActorRuntime stores the intent;
  # SignalsGateway and plugin registration decide how to perform it.
  defp resolve_adapter(outbox) do
    with {:ok, binding} <- SignalsGateway.get_binding(outbox.agent_uid, outbox.binding_name),
         {:ok, module} <- outbox_module_for_adapter(binding.adapter) do
      {:ok, module}
    end
  end

  defp outbox_module_for_adapter(adapter_id) do
    case Process.whereis(Ankole.Plugins.Registry) do
      nil ->
        {:error, :plugin_registry_not_started}

      _pid ->
        "signals_gateway.adapter"
        |> Ankole.Plugins.adapter_declarations()
        |> Enum.find(fn declaration ->
          declaration[:id] == adapter_id or declaration["id"] == adapter_id
        end)
        |> case do
          %{outbox_module: module} when is_atom(module) -> {:ok, module}
          %{"outbox_module" => module} when is_atom(module) -> {:ok, module}
          _declaration -> {:error, {:outbox_adapter_not_found, adapter_id}}
        end
    end
  end
end
