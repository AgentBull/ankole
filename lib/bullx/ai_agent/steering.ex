defmodule BullX.AIAgent.Steering do
  @moduledoc """
  Ephemeral delivery path for `/steer` notes into an active generation lease.

  Steering text is control-plane input, not Conversation truth by itself. The
  runner consumes it at a tool boundary and persists the note with the next tool
  result so restart recovery never depends on process memory.
  """

  @ttl_seconds 3_600

  @spec put(String.t(), String.t(), String.t()) :: :ok
  def put(lease_id, command_entry_id, text)
      when is_binary(lease_id) and is_binary(command_entry_id) and is_binary(text) do
    _result =
      BullX.Cache.put(
        cache_key(lease_id),
        %{command_entry_id: command_entry_id, text: text},
        @ttl_seconds
      )

    :ok
  end

  @spec pop(String.t() | nil) :: map() | nil
  def pop(lease_id) when is_binary(lease_id) do
    case BullX.Cache.take(cache_key(lease_id)) do
      {:ok, payload} -> payload
      {:error, _reason} -> nil
    end
  end

  def pop(_lease_id), do: nil

  defp cache_key(lease_id), do: "ai_agent:steering:#{lease_id}"
end
