defmodule Ankole.Conversations.Locks do
  @moduledoc """
  Locks the Principal and Signal rows that a Conversations operation reads.

  The reads use the code interface of the owning domain. Each read gives its
  rows to the lock-order check, as `Ankole.Ash.read/2` does in the owning
  domain. Use these functions only inside a transaction.
  """

  @doc "Locks the Principals of the UIDs in UID order."
  def principals(uids) when is_list(uids) do
    uids = uids |> Enum.uniq() |> Enum.sort()

    Ankole.LockOrder.with_identity({"principals", uids}, fn ->
      Ankole.Principals.Domain.list_principals!(
        query: [filter: [uid: [in: uids]], sort: [uid: :asc], lock: :for_update]
      )
    end)
  end

  @doc "Locks the Signals that a code interface query selects."
  def signals(query) when is_list(query) do
    rows =
      Ankole.LockOrder.with_identity({:rows, "signals", :id}, fn ->
        Ankole.Signals.Domain.list_signals!(query: Keyword.put(query, :lock, :for_update))
      end)

    Ankole.LockOrder.check_rows("signals", Enum.map(rows, & &1.id))
    rows
  end
end
