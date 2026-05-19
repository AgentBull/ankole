defmodule BullX.AIAgent.Steering do
  @moduledoc """
  Ephemeral delivery path for `/steer` notes into an active generation lease.

  Steering text is control-plane input, not Conversation truth by itself. The
  runner consumes it at a tool boundary and persists the note with the next tool
  result so restart recovery never depends on process memory.
  """

  @table __MODULE__

  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(lease_id, command_entry_id, text)
      when is_binary(lease_id) and is_binary(command_entry_id) and is_binary(text) do
    ensure_table()
    :ets.insert(@table, {lease_id, %{command_entry_id: command_entry_id, text: text}})
    :ok
  end

  @spec pop(String.t() | nil) :: map() | nil
  def pop(lease_id) when is_binary(lease_id) do
    ensure_table()

    case :ets.take(@table, lease_id) do
      [{^lease_id, payload}] -> payload
      [] -> nil
    end
  end

  def pop(_lease_id), do: nil

  defp ensure_table do
    case :ets.whereis(@table) do
      :undefined ->
        try do
          :ets.new(@table, [:named_table, :public, read_concurrency: true])
        rescue
          ArgumentError -> @table
        end

      _tid ->
        @table
    end
  end
end
