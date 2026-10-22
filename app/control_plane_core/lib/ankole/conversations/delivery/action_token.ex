defmodule Ankole.Conversations.Delivery.ActionToken do
  @moduledoc false

  alias Ankole.Conversations.Delivery.PreviewState
  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Delivery.ReplyPresentation
  alias Ankole.Conversations.Delivery.PreviewAdapter

  @type option ::
          {:prefix, String.t()}
          | {:max_bytes, pos_integer()}
          | {:too_long_error, atom()}

  @spec encode(String.t(), non_neg_integer(), map(), [option()]) ::
          {:ok, String.t()} | {:error, term()}
  def encode(signal_id, index, action, opts)
      when is_binary(signal_id) and is_integer(index) and index >= 0 and is_map(action) and
             is_list(opts) do
    with {:ok, prefix, max_bytes, too_long_error} <- options(opts) do
      token =
        "#{prefix}:#{signal_id}:#{Integer.to_string(index, 36)}:#{action_fingerprint(action)}"

      if byte_size(token) <= max_bytes, do: {:ok, token}, else: {:error, too_long_error}
    end
  end

  def encode(_signal_id, _index, _action, _opts),
    do: {:error, :invalid_callback_action}

  @doc """
  Resolves one provider callback token to its exact callback value.

  `provider_message_id` names the provider message that carried the button. A
  provider whose callback names no message (a LINE postback) passes `nil`; the
  token then binds to the Signal, the binding, and the action fingerprint
  only, because no adapter surface can tie it to one provider message.
  """
  @spec resolve(String.t(), String.t(), String.t(), String.t() | nil, [option()]) ::
          {:ok, map()} | {:error, term()}
  def resolve(token, agent_uid, binding_name, provider_message_id, opts)
      when is_binary(token) and is_binary(agent_uid) and is_binary(binding_name) and
             (is_binary(provider_message_id) or is_nil(provider_message_id)) and is_list(opts) do
    with {:ok, prefix} <- prefix(opts),
         {:ok, signal_id, index, fingerprint} <- decode(token, prefix),
         %Signal{} = event <- PreviewState.load_signal(signal_id),
         true <- event.agent_uid == agent_uid || {:error, :callback_binding_mismatch},
         true <- event.reply_binding_name == binding_name || {:error, :callback_binding_mismatch},
         true <- source_entry?(event, provider_message_id) || {:error, :callback_message_mismatch},
         %{} = action <-
           action_at(
             PreviewState.get(event).checkpoint || %{},
             index
           ),
         true <- action_fingerprint(action) == fingerprint || {:error, :invalid_callback_action},
         {:ok, value} <- ReplyPresentation.callback_value(event.id, action) do
      {:ok, value}
    else
      nil -> {:error, :callback_source_not_found}
      false -> {:error, :invalid_callback_token}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_callback_action}
    end
  end

  def resolve(_token, _agent_uid, _binding_name, _provider_message_id, _opts),
    do: {:error, :invalid_callback_token}

  defp options(opts) do
    with {:ok, prefix} <- prefix(opts),
         max_bytes when is_integer(max_bytes) and max_bytes > 0 <- Keyword.get(opts, :max_bytes),
         too_long_error when is_atom(too_long_error) <- Keyword.get(opts, :too_long_error) do
      {:ok, prefix, max_bytes, too_long_error}
    else
      _invalid -> {:error, :invalid_callback_action}
    end
  end

  defp prefix(opts) do
    case Keyword.get(opts, :prefix) do
      prefix when is_binary(prefix) and prefix != "" ->
        if String.contains?(prefix, ":"),
          do: {:error, :invalid_callback_token},
          else: {:ok, prefix}

      _invalid ->
        {:error, :invalid_callback_token}
    end
  end

  # A callback token arrives from the network. Validate every segment before
  # the Signal read because the read rejects an invalid UUID.
  defp decode(token, prefix) do
    case String.split(token, ":", parts: 4) do
      [^prefix, signal_id, encoded_index, fingerprint]
      when byte_size(fingerprint) == 11 ->
        with {:ok, _uuid} <- Ecto.UUID.cast(signal_id),
             {index, ""} when index >= 0 <- Integer.parse(encoded_index, 36) do
          {:ok, signal_id, index, fingerprint}
        else
          _invalid -> {:error, :invalid_callback_token}
        end

      _invalid ->
        {:error, :invalid_callback_token}
    end
  end

  defp action_at(checkpoint, index) do
    checkpoint
    |> PreviewAdapter.adapter_checkpoint()
    |> get_in(["presentation", "actions"])
    |> case do
      actions when is_list(actions) -> Enum.at(actions, index)
      _missing -> nil
    end
  end

  defp source_entry?(%Signal{}, nil), do: true

  defp source_entry?(%Signal{} = event, provider_message_id) do
    event
    |> PreviewAdapter.for_event()
    |> PreviewAdapter.surface_entry_ids(PreviewState.get(event).checkpoint || %{})
    |> Enum.member?(provider_message_id)
  end

  defp action_fingerprint(action) do
    action
    |> Map.take([
      "interaction_id",
      "control_id",
      "selected_option_id",
      "option_value",
      "revision"
    ])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 8)
    |> Base.url_encode64(padding: false)
  end
end
