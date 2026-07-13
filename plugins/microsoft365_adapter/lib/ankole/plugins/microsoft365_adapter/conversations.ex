defmodule Ankole.Plugins.Microsoft365Adapter.Conversations do
  @moduledoc """
  Teams conversation-id algebra shared by ingress and outbox.

  Channel activities carry `conversation.id` in the form
  `"19:…@thread.tacv2;messageid={threadRootId}"`. The base id (without the
  `;messageid=` suffix) names the channel and becomes the signal channel; the
  message id names the thread root. Personal and group chats have no thread
  segment.
  """

  @signal_prefix "teams:"
  @thread_marker ";messageid="

  @spec base_conversation_id(String.t()) :: String.t()
  def base_conversation_id(conversation_id) when is_binary(conversation_id) do
    case String.split(conversation_id, @thread_marker, parts: 2) do
      [base | _rest] -> base
    end
  end

  @spec thread_root(String.t()) :: String.t() | nil
  def thread_root(conversation_id) when is_binary(conversation_id) do
    case String.split(conversation_id, @thread_marker, parts: 2) do
      [_base, root] when root != "" -> root
      _no_thread -> nil
    end
  end

  @spec thread_conversation_id(String.t(), String.t()) :: String.t()
  def thread_conversation_id(base_conversation_id, thread_root)
      when is_binary(base_conversation_id) and is_binary(thread_root),
      do: base_conversation_id <> @thread_marker <> thread_root

  @spec signal_channel_id(String.t()) :: String.t()
  def signal_channel_id(base_conversation_id),
    do: @signal_prefix <> URI.encode(base_conversation_id, &URI.char_unreserved?/1)

  @spec conversation_id_from_signal(String.t()) :: String.t() | nil
  def conversation_id_from_signal(@signal_prefix <> encoded), do: URI.decode(encoded)
  def conversation_id_from_signal(_signal_channel_id), do: nil

  @spec provider_thread_id(String.t(), String.t()) :: String.t()
  def provider_thread_id(base_conversation_id, thread_root) do
    @signal_prefix <>
      URI.encode(base_conversation_id, &URI.char_unreserved?/1) <>
      ":" <> URI.encode(thread_root, &URI.char_unreserved?/1)
  end

  @doc """
  Extracts the thread root from a provider thread id built by this module.
  """
  @spec thread_root_from_provider_thread_id(String.t() | nil, String.t()) :: String.t() | nil
  def thread_root_from_provider_thread_id(nil, _base_conversation_id), do: nil

  def thread_root_from_provider_thread_id(provider_thread_id, base_conversation_id) do
    prefix =
      @signal_prefix <> URI.encode(base_conversation_id, &URI.char_unreserved?/1) <> ":"

    if String.starts_with?(provider_thread_id, prefix) do
      case String.replace_prefix(provider_thread_id, prefix, "") do
        "" -> nil
        encoded_root -> URI.decode(encoded_root)
      end
    end
  end
end
