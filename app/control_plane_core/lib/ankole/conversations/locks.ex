defmodule Ankole.Conversations.Locks do
  @moduledoc """
  Locks the Signal rows that a Conversations operation reads.

  The read uses the code interface of the Signals domain and gives its rows to
  the lock-order check, as `Ankole.Ash.read/2` does in the owning domain. Use
  this function only inside a transaction.
  """

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
