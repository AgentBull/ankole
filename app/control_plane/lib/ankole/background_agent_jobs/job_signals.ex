defmodule Ankole.BackgroundAgentJobs.JobSignals do
  @moduledoc """
  Reads the Signals of Job sessions through the Signals domain.

  The Signals domain owns the Signal resource. This module is the one place
  where this domain reads Signal rows; it uses only the Signals code interface
  and the Signals composition functions.
  """

  alias Ankole.BackgroundAgentJobs
  alias Ankole.Signals.Signal

  @open_statuses [:queued, :running]

  @doc "Lists the Signals that match a keyword filter."
  @spec list(keyword(), keyword()) :: [Signal.t()]
  def list(filter, query \\ []),
    do: Ankole.Signals.list_signals!(query: [{:filter, filter} | query])

  @doc "Gives the first Signal that matches a keyword filter, or `nil`."
  @spec first(keyword()) :: Signal.t() | nil
  def first(filter), do: filter |> list(limit: 1) |> List.first()

  @doc "Tells if an open Signal of a Job session matches the types and is not in `except_ids`."
  @spec open?(pos_integer(), String.t(), [String.t()], [Ecto.UUID.t()]) :: boolean()
  def open?(job_id, agent_uid, types, except_ids) do
    job_id
    |> open_filter(agent_uid, types)
    |> Keyword.put(:not, id: [in: except_ids])
    |> list(limit: 1, select: [:id])
    |> Enum.any?()
  end

  @doc """
  Locks the open Signals of a Job session with the given types, in queue order,
  inside the caller's transaction.
  """
  @spec lock_open_in_tx(pos_integer(), String.t(), [String.t()]) :: [Signal.t()]
  def lock_open_in_tx(job_id, agent_uid, types) do
    signals =
      Ankole.LockOrder.with_identity({:rows, "signals", :id}, fn ->
        job_id
        |> open_filter(agent_uid, types)
        |> list(sort: [queue_sequence: :asc], lock: :for_update)
      end)

    Ankole.LockOrder.check_rows("signals", Enum.map(signals, & &1.id))
    signals
  end

  @doc "Locks one Signal while it is open, inside the caller's transaction."
  @spec lock_open_signal_in_tx(Ecto.UUID.t()) :: Signal.t() | nil
  def lock_open_signal_in_tx(signal_id) do
    case Ankole.Signals.lock_signal_in_tx(signal_id) do
      %Signal{status: status} = signal when status in @open_statuses -> signal
      _closed_or_missing -> nil
    end
  end

  defp open_filter(job_id, agent_uid, types) do
    [
      agent_uid: agent_uid,
      session_id: BackgroundAgentJobs.job_session_id(job_id),
      type: [in: types],
      status: [in: @open_statuses]
    ]
  end
end
