defmodule Ankole.Sessions.ConversationContext do
  @moduledoc "Adds unread public statements to the next model request without storing a cursor."
  alias Ankole.{AIGateway, Conversations}
  alias Ankole.Sessions.{Key, Prompt.Input, WakeBriefing}

  def append(run, request) do
    if WakeBriefing.should_inject?(run) do
      WakeBriefing.append(run, request)
    else
      case Key.parse(run.session_id) do
        {:conversation, id} -> append_conversation(run, request, id)
        _ -> request
      end
    end
  end

  def read_seq(agent_uid, model_id, conversation_id) do
    with {:ok, metadata} <- AIGateway.visible_response_metadata(agent_uid, model_id) do
      metadata
      |> Enum.map(fn caller ->
        case caller["conversation_read"] do
          %{"id" => ^conversation_id, "max_seq" => seq} when is_integer(seq) -> seq
          _ -> 0
        end
      end)
      |> Enum.max(fn -> 0 end)
    else
      _ -> 0
    end
  end

  defp append_conversation(run, request, id) do
    signal_ids = [run.signal_id | run.steer_event_ids]

    inputs =
      Ankole.Signals.list_signals!(
        query: [filter: [id: [in: signal_ids], producer: :kernel, conversation_id: id]]
      )

    input_ids =
      Enum.flat_map(inputs, fn event ->
        declared = if is_map(event.data), do: List.wrap(event.data["message_ids"]), else: []
        [event.message_id | declared]
      end)
      |> Enum.filter(&is_binary/1)
      |> Enum.uniq()

    quoted_ids =
      Enum.flat_map(inputs, fn event ->
        if is_map(event.data),
          do: List.wrap(get_in(event.data, ["entry", "reply_to", "message_id"])),
          else: []
      end)

    watermark = read_seq(run.agent_uid, run.conversation.id, id)

    case Conversations.context_snapshot(
           id,
           %{agent_uid: run.agent_uid, session_id: run.session_id},
           watermark,
           Enum.uniq(input_ids ++ quoted_ids)
         ) do
      {:ok, snapshot} ->
        read = %{
          "id" => id,
          "max_seq" => snapshot.max_seq,
          "message_ids" =>
            Enum.uniq(input_ids ++ quoted_ids ++ Enum.map(snapshot.messages, & &1.id))
        }

        request
        |> Map.update!("metadata", &Map.put(&1, "conversation_read", read))
        |> Map.update!("input", &(Input.context_messages(snapshot.messages) ++ &1))

      {:error, _} ->
        request
    end
  end
end
