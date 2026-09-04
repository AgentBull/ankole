defmodule Ankole.SignalsGateway.ReplyActionToken do
  @moduledoc false

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ReplyPresentation
  alias Ankole.SignalsGateway.ReplyPreviewAdapter

  @type option ::
          {:prefix, String.t()}
          | {:max_bytes, pos_integer()}
          | {:too_long_error, atom()}

  @spec encode(String.t(), non_neg_integer(), map(), [option()]) ::
          {:ok, String.t()} | {:error, term()}
  def encode(actor_event_id, index, action, opts)
      when is_binary(actor_event_id) and is_integer(index) and index >= 0 and is_map(action) and
             is_list(opts) do
    with {:ok, prefix, max_bytes, too_long_error} <- options(opts) do
      token =
        "#{prefix}:#{actor_event_id}:#{Integer.to_string(index, 36)}:#{action_fingerprint(action)}"

      if byte_size(token) <= max_bytes, do: {:ok, token}, else: {:error, too_long_error}
    end
  end

  def encode(_actor_event_id, _index, _action, _opts),
    do: {:error, :invalid_callback_action}

  @spec resolve(String.t(), String.t(), String.t(), String.t(), [option()]) ::
          {:ok, map()} | {:error, term()}
  def resolve(token, agent_uid, binding_name, source_entry_id, opts)
      when is_binary(token) and is_binary(agent_uid) and is_binary(binding_name) and
             is_binary(source_entry_id) and is_list(opts) do
    with {:ok, prefix} <- prefix(opts),
         {:ok, actor_event_id, index, fingerprint} <- decode(token, prefix),
         %ActorEvent{} = event <- Repo.get(ActorEvent, actor_event_id),
         true <- event.agent_uid == agent_uid || {:error, :callback_binding_mismatch},
         true <- event.binding_name == binding_name || {:error, :callback_binding_mismatch},
         true <- source_entry?(event, source_entry_id) || {:error, :callback_message_mismatch},
         %{} = action <- action_at(event.reply_preview_checkpoint || %{}, index),
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

  def resolve(_token, _agent_uid, _binding_name, _source_entry_id, _opts),
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
  # `Repo.get` because Ecto rejects an invalid UUID.
  defp decode(token, prefix) do
    case String.split(token, ":", parts: 4) do
      [^prefix, actor_event_id, encoded_index, fingerprint]
      when byte_size(fingerprint) == 11 ->
        with {:ok, _uuid} <- Ecto.UUID.cast(actor_event_id),
             {index, ""} when index >= 0 <- Integer.parse(encoded_index, 36) do
          {:ok, actor_event_id, index, fingerprint}
        else
          _invalid -> {:error, :invalid_callback_token}
        end

      _invalid ->
        {:error, :invalid_callback_token}
    end
  end

  defp action_at(checkpoint, index) do
    checkpoint
    |> ReplyPreviewAdapter.adapter_checkpoint()
    |> get_in(["presentation", "actions"])
    |> case do
      actions when is_list(actions) -> Enum.at(actions, index)
      _missing -> nil
    end
  end

  defp source_entry?(%ActorEvent{} = event, source_entry_id) do
    event
    |> ReplyPreviewAdapter.for_event()
    |> ReplyPreviewAdapter.surface_entry_ids(event.reply_preview_checkpoint || %{})
    |> Enum.member?(source_entry_id)
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
