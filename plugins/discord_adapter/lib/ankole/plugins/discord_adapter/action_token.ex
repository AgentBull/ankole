defmodule Ankole.Plugins.DiscordAdapter.ActionToken do
  @moduledoc false

  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent

  @prefix "dc1"
  @action_protocol "ankole.interactive_output.action.v1"

  # Discord rejects a component whose `custom_id` is longer than 100 bytes.
  @custom_id_bytes 100

  @spec encode(String.t(), non_neg_integer(), map()) :: {:ok, String.t()} | {:error, term()}
  def encode(actor_event_id, index, action)
      when is_binary(actor_event_id) and is_integer(index) and index >= 0 and is_map(action) do
    token =
      "#{@prefix}:#{actor_event_id}:#{Integer.to_string(index, 36)}:#{action_fingerprint(action)}"

    if byte_size(token) <= @custom_id_bytes, do: {:ok, token}, else: {:error, :custom_id_too_long}
  end

  def encode(_actor_event_id, _index, _action), do: {:error, :invalid_callback_action}

  @spec resolve(String.t(), String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def resolve(token, agent_uid, binding_name, source_entry_id)
      when is_binary(token) and is_binary(agent_uid) and is_binary(binding_name) and
             is_binary(source_entry_id) do
    with {:ok, actor_event_id, index, fingerprint} <- decode(token),
         %ActorEvent{} = event <- Repo.get(ActorEvent, actor_event_id),
         true <- event.agent_uid == agent_uid || {:error, :callback_binding_mismatch},
         true <- event.binding_name == binding_name || {:error, :callback_binding_mismatch},
         true <-
           source_entry?(event.reply_preview_checkpoint || %{}, source_entry_id) ||
             {:error, :callback_message_mismatch},
         %{} = action <- action_at(event.reply_preview_checkpoint || %{}, index),
         true <- action_fingerprint(action) == fingerprint || {:error, :invalid_callback_action},
         {:ok, value} <- callback_value(event.id, action) do
      {:ok, value}
    else
      nil -> {:error, :callback_source_not_found}
      false -> {:error, :invalid_callback_token}
      {:error, _reason} = error -> error
      _invalid -> {:error, :invalid_callback_action}
    end
  end

  def resolve(_token, _agent_uid, _binding_name, _source_entry_id),
    do: {:error, :invalid_callback_token}

  defp decode(token) do
    case String.split(token, ":", parts: 4) do
      [@prefix, actor_event_id, encoded_index, fingerprint] when byte_size(fingerprint) == 11 ->
        case Integer.parse(encoded_index, 36) do
          {index, ""} when index >= 0 -> {:ok, actor_event_id, index, fingerprint}
          _invalid -> {:error, :invalid_callback_token}
        end

      _invalid ->
        {:error, :invalid_callback_token}
    end
  end

  defp action_at(checkpoint, index) do
    checkpoint
    |> get_in(["presentation", "actions"])
    |> case do
      actions when is_list(actions) -> Enum.at(actions, index)
      _missing -> nil
    end
  end

  defp source_entry?(checkpoint, source_entry_id) do
    checkpoint["message_id"] == source_entry_id or
      Enum.any?(checkpoint["messages"] || [], fn
        %{"message_id" => ^source_entry_id} -> true
        _message -> false
      end)
  end

  defp action_fingerprint(action) do
    action
    |> Map.take(["interaction_id", "control_id", "selected_option_id", "option_value", "revision"])
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> binary_part(0, 8)
    |> Base.url_encode64(padding: false)
  end

  defp callback_value(actor_event_id, action) do
    with interaction_id when is_binary(interaction_id) <- action["interaction_id"],
         control_id when is_binary(control_id) <- action["control_id"],
         selected_option_id when is_binary(selected_option_id) <- action["selected_option_id"],
         option_value when is_binary(option_value) <- action["option_value"],
         revision when is_integer(revision) <- action["revision"] do
      {:ok,
       %{
         "version" => @action_protocol,
         "answerKind" => "choice",
         "interactionId" => interaction_id,
         "interactionVersion" => revision,
         "controlId" => control_id,
         "selectedOptionId" => selected_option_id,
         "optionValue" => option_value,
         "sourceActorEventId" => actor_event_id
       }}
    else
      _invalid -> {:error, :invalid_callback_action}
    end
  end
end
