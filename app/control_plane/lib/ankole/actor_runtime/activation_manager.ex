defmodule Ankole.ActorRuntime.ActivationManager do
  @moduledoc """
  Polls the durable actor input journal and wakes session controllers.
  """

  use GenServer

  require Logger

  alias Ankole.Actors
  alias Ankole.ActorRuntime.SessionController

  @default_interval_ms 500
  @default_limit 25

  @doc """
  Starts the activation manager.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one ready-input polling pass.
  """
  @spec run_once(keyword()) :: {:ok, [term()]}
  def run_once(opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    limit = Keyword.get(opts, :limit, @default_limit)

    results =
      now
      |> Actors.list_ready_actor_keys(limit)
      |> Enum.map(&SessionController.process_ready(&1, opts))

    {:ok, results}
  end

  @doc """
  Best-effort wakeup after ingress commits actor input.
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
      limit: Keyword.get(opts, :limit, @default_limit)
    }

    {:ok, state, {:continue, :initial_poll}}
  end

  @impl true
  def handle_continue(:initial_poll, state) do
    poll(state)
    schedule_next(state)
    {:noreply, state}
  end

  @impl true
  def handle_cast(:wake, state) do
    poll(state)
    {:noreply, state}
  end

  @impl true
  def handle_info(:poll, state) do
    poll(state)
    schedule_next(state)
    {:noreply, state}
  end

  defp poll(state) do
    {:ok, _results} = run_once(limit: state.limit)
    :ok
  rescue
    error ->
      Logger.warning("actor runtime activation poll failed: #{Exception.message(error)}")
  end

  defp schedule_next(state) do
    Process.send_after(self(), :poll, state.interval_ms)
  end
end
