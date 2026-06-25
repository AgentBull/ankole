defmodule Ankole.ActorRuntime.Reconciler do
  @moduledoc """
  Reconciles logged AI-agent state after unlogged runtime projection loss.
  """

  use GenServer

  require Logger

  alias Ankole.ActorRuntime

  @doc """
  Starts the reconciler and runs a startup pass.

  Startup reconciliation handles the case where the BEAM restarted after
  writing a durable AI-agent turn but before rebuilding the actor-runtime
  activation or delivery projections.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Runs one projection-loss reconciliation pass.
  """
  @spec run_once(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def run_once(opts \\ []), do: ActorRuntime.reconcile_projection_lost_started_turns(opts)

  @impl true
  def init(_opts), do: {:ok, %{}, {:continue, :startup_reconcile}}

  @impl true
  def handle_continue(:startup_reconcile, state) do
    case run_once() do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("actor runtime startup reconcile failed: #{inspect(reason)}")
    end

    {:noreply, state}
  end
end
