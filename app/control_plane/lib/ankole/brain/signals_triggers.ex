defmodule Ankole.Brain.SignalsTriggers do
  @moduledoc """
  Learning triggers from conversation lifecycle events.

  A conversation whose key is an IM Signal Channel triggers slice
  processing when it ends; the idle-time sweep in Self-healing is the
  fallback trigger for channels without conversation endings.
  """

  alias Ankole.Brain.Config
  alias Ankole.Brain.Jobs.ProcessChannelSlice
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Utils

  @doc """
  Enqueues slice processing when an ended conversation belongs to one IM
  channel. Runs inside the caller's transaction, so the trigger commits
  atomically with `ended_at`. Non-channel conversation keys and disabled
  Brain no-op.
  """
  @spec conversation_ended_in_tx(module(), String.t()) :: :ok
  def conversation_ended_in_tx(repo, conversation_key) when is_binary(conversation_key) do
    # The conversation key is "signal-channel:" plus the Channel id; the
    # Channel table stores only the id.
    with channel_id when is_binary(channel_id) <-
           Utils.signal_channel_id_from_session_id(conversation_key),
         true <- Config.enabled?(),
         %Channel{kind: kind} when kind in [:im_dm, :im_group] <-
           repo.get(Channel, channel_id) do
      {:ok, _job} = ProcessChannelSlice.enqueue(channel_id)

      :ok
    else
      _not_a_learning_channel -> :ok
    end
  end

  def conversation_ended_in_tx(_repo, _conversation_key), do: :ok
end
