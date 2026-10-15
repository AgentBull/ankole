defmodule Ankole.Sessions.ConversationContext do
  @moduledoc "Adds unread public statements to the next model request without storing a cursor."
  import Ecto.Query
  alias Ankole.{AIGateway, Conversations, Repo}
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.{Key, Prompt.Input}

  def append(run, request) do
    case Key.parse(run.session_id) do
      {:conversation, id} -> append_conversation(run, request, id)
      _ -> request
    end
  end

  def read_seq(agent_uid, model_id, conversation_id) do
    with {:ok, rows} <-
           AIGateway.visible_response_chain(agent_uid, model_id, stop_at_checkpoint: false) do
      rows
      |> Enum.map(fn row ->
        case AIGateway.response_metadata(row)["conversation_read"] do
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
      Repo.all(
        from s in Signal,
          where: s.id in ^signal_ids and s.producer == :kernel and s.conversation_id == ^id
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
        :ok =
          Ankole.Conversations.Attachments.link_payload(
            run.agent_uid,
            %{
              "data" => %{
                "entries" => Enum.map(snapshot.messages, &%{"attachments" => &1.attachments})
              }
            },
            id
          )

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
