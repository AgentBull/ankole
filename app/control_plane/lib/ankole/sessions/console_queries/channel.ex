defmodule Ankole.Sessions.ConsoleQueries.Channel do
  @moduledoc """
  Gives one display fact of AIGateway conversations for the operator console.

  The facts come from the Session key and from the external channel of each
  conversation (`Ankole.Conversations.ExternalTarget`):

    * `:kind` - the origin of the conversation, from the key constructors
      (signal ingress, background Jobs, cron executions, managed Responses).
      A custom Session id of a channel chat is a `signal` conversation when its
      origin is recorded.
    * `:display_name` - the label of the channel.
    * `:channel_kind`, `:signal_adapter` - the kind and the adapter of a
      channel that a Signal opened.
  """
  use Ash.Resource.Calculation

  alias Ankole.Conversations.ExternalTarget

  @impl true
  def init(opts) do
    if opts[:field] in [:kind, :display_name, :channel_kind, :signal_adapter],
      do: {:ok, opts},
      else: {:error, "field must be :kind, :display_name, :channel_kind, or :signal_adapter"}
  end

  @impl true
  def load(_query, _opts, _context), do: [:conversation_key, :subject_uid, :metadata]

  @impl true
  def calculate(conversations, opts, _context) do
    channels = ExternalTarget.resolve_many(conversations)
    Enum.map(conversations, &value(opts[:field], &1, Map.get(channels, &1.id, %{})))
  end

  defp value(:kind, conversation, channel) do
    case Ankole.Sessions.Key.parse(conversation.conversation_key) do
      {:conversation, _} -> :conversation
      {:job, _} -> :job
      {:cron, _} -> :cron
      {:named, "stateful-responses-api:" <> _rest} -> :responses_api
      _custom -> if Map.get(channel, :signal_origin?, false), do: :signal, else: :custom
    end
  end

  defp value(:display_name, _conversation, channel), do: Map.get(channel, :label)
  defp value(:channel_kind, _conversation, channel), do: signal_value(channel, :kind)
  defp value(:signal_adapter, _conversation, channel), do: signal_value(channel, :adapter)

  defp signal_value(%{signal_origin?: true} = channel, key), do: Map.get(channel, key)
  defp signal_value(_channel, _key), do: nil
end
