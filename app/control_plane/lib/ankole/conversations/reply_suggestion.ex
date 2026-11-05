defmodule Ankole.Conversations.ReplySuggestion do
  @moduledoc """
  Suggests the next message that a Human may send after an Agent's reply.

  Pod asks for a suggestion once a reply has completed in an idle conversation
  where the Human is the only human participant and no question, confirmation
  card, queued input, Agent turn, linked Background Agent Job, Workflow, or
  delegated colleague exchange remains active. The Agent that wrote the latest
  message drafts one line with its `light` model profile from the recent
  transcript. Ankole stores nothing: the suggestion only fills the Human's
  draft when the Human adopts it.
  """

  require Ash.Query
  require Logger

  alias Ankole.{AIGateway, BackgroundAgentJobs, Conversations, Repo, Sessions, Signals, Workflow}
  alias Ankole.AuthZ.Actor
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.Conversations.{ActionCards, Delivery, Message, Native, NativeRoom, Peers}

  @transcript_messages 8
  @message_chars 1_500
  @max_chars 120

  @doc """
  Returns `%{message_id: id, text: text}` for the latest message of a room that
  the Human can read. `text` is nil when the room has another human
  participant, when the latest message is not an Agent reply, when any turn,
  queued input, pending question, confirmation card, or background/delegated
  task is still active, or when the model gives no usable line.
  """
  @spec suggest(Actor.t(), String.t(), keyword()) ::
          {:ok, %{message_id: String.t() | nil, text: String.t() | nil}} | {:error, :not_found}
  def suggest(%Actor{} = actor, conversation_id, opts \\ []) do
    snapshot =
      Repo.transact_repeatable_read_only(fn ->
        case NativeRoom.visible(actor, conversation_id) do
          nil ->
            {:error, :not_found}

          conversation ->
            participants = NativeRoom.participants(conversation.id)
            messages = recent_messages(conversation)

            case List.last(messages) do
              %Message{author_type: :agent, kind: :message, author_uid: agent_uid} = latest
              when is_binary(agent_uid) ->
                eligible? =
                  only_human?(participants, Actor.uid(actor)) and
                    idle_room?(conversation.id, participants)

                {:ok,
                 %{
                   latest: latest,
                   agent_uid: agent_uid,
                   messages: messages,
                   eligible?: eligible?
                 }}

              latest ->
                {:ok, %{latest: latest, eligible?: false}}
            end
        end
      end)

    case snapshot do
      {:error, :not_found} ->
        {:error, :not_found}

      {:ok, %{latest: latest, agent_uid: agent_uid, messages: messages, eligible?: true}} ->
        text =
          draft(agent_uid, messages, Keyword.get(opts, :locale), %{
            "human_uid" => Actor.uid(actor),
            "session_id" => Sessions.Key.conversation(conversation_id)
          })

        {:ok, %{message_id: latest.id, text: text}}

      {:ok, %{latest: latest}} ->
        {:ok, %{message_id: latest && latest.id, text: nil}}
    end
  end

  defp recent_messages(conversation) do
    high_water = conversation.sequence_high_water

    Message
    |> Ash.Query.filter(
      conversation_id == ^conversation.id and seq <= ^high_water and not withdrawn
    )
    |> Ash.Query.sort(seq: :desc)
    |> Ash.Query.limit(@transcript_messages)
    |> Ankole.Ash.read!()
    |> Enum.reverse()
  end

  defp only_human?(participants, uid) do
    participants
    |> Enum.reject(&(&1.role == :agent))
    |> Enum.map(& &1.principal_uid)
    |> Kernel.==([uid])
  end

  defp idle_room?(conversation_id, participants) do
    session = Sessions.Key.conversation(conversation_id)
    agent_uids = for %{role: :agent, principal_uid: uid} <- participants, do: uid
    peers = Peers.exchanges([conversation_id])
    peer_ids = Enum.map(peers, & &1.id)
    peer_sessions = Enum.map(peer_ids, &Sessions.Key.conversation/1)
    all_sessions = [session | peer_sessions]

    session_keys =
      Enum.map(agent_uids, &{&1, session}) ++
        Enum.map(peers, &{&1.peer_target_uid, Sessions.Key.conversation(&1.id)})

    session_keys
    |> Sessions.statuses()
    |> Enum.all?(fn {_key, %{state: state}} -> state == :idle end) and
      not queued_inputs?(conversation_id) and
      not active_jobs?(all_sessions) and
      not active_workflows?(all_sessions) and
      not pending_questions?([conversation_id | peer_ids]) and
      not prepared_action_cards?(conversation_id)
  end

  defp queued_inputs?(conversation_id) do
    Signals.list_signals!(
      query: [filter: Native.pending_filter(conversation_id), limit: 1, select: [:id]]
    ) != []
  end

  defp active_jobs?(sessions) do
    BackgroundAgentJobs.list_jobs!(
      query: [
        filter: [
          owner_session_id: [in: sessions],
          status: [in: Job.live_statuses()],
          skill_lesson_reflection?: false
        ],
        limit: 1,
        select: [:id]
      ]
    ) != []
  end

  defp active_workflows?(sessions) do
    Workflow.list_runs!(
      query: [
        filter: [owner_session_id: [in: sessions], status: :running],
        limit: 1,
        select: [:id]
      ]
    ) != []
  end

  defp pending_questions?(conversation_ids) do
    conversation_ids
    |> Conversations.latest_native_questions()
    |> Delivery.Interactions.native_interactions()
    |> Enum.any?(fn {_message_id, state} -> state["state"] == "pending" end)
  end

  defp prepared_action_cards?(conversation_id) do
    MapSet.member?(ActionCards.prepared_conversation_ids([conversation_id]), conversation_id)
  end

  defp draft(agent_uid, messages, locale, request_context) do
    request = %{
      "model" => "light",
      "instructions" => instructions(locale),
      "input" => [
        %{
          "role" => "user",
          "content" => [%{"type" => "input_text", "text" => transcript(messages)}]
        }
      ],
      "max_output_tokens" => 200,
      "text" => %{
        "format" => %{
          "type" => "json_schema",
          "name" => "pod_reply_suggestion",
          "strict" => true,
          "schema" => %{
            "type" => "object",
            "additionalProperties" => false,
            "required" => ["suggestion"],
            "properties" => %{"suggestion" => %{"type" => ["string", "null"]}}
          }
        }
      }
    }

    with {:ok, %{body: body}} <-
           AIGateway.create_response(agent_uid, request,
             subject_type: "agent",
             caller: "reply_suggestion",
             request_context: request_context
           ),
         {:ok, text} <- AIGateway.completed_output_text(body),
         {:ok, %{"suggestion" => suggestion}} <- Ankole.JSON.decode(text) do
      usable(suggestion, last_human_text(messages))
    else
      other ->
        Logger.info("reply suggestion unavailable: #{inspect(other)}")
        nil
    end
  end

  @doc false
  # One trimmed line within the length limit that does not repeat what the
  # Human last wrote.
  def usable(suggestion, last_human_text) when is_binary(suggestion) do
    line = String.trim(suggestion)

    cond do
      line == "" or String.contains?(line, ["\n", "\r"]) -> nil
      String.length(line) > @max_chars -> nil
      normalize(line) == normalize(last_human_text || "") -> nil
      true -> line
    end
  end

  def usable(_suggestion, _last_human_text), do: nil

  defp normalize(text), do: text |> String.trim() |> String.downcase()

  defp last_human_text(messages) do
    Enum.find_value(Enum.reverse(messages), fn
      %Message{author_type: :human, text: text} -> text
      _message -> nil
    end)
  end

  defp transcript(messages) do
    Enum.map_join(messages, "\n\n", fn message ->
      speaker =
        case message.author_type do
          :human -> "Human"
          _other -> message.author_display_name || "Agent"
        end

      "#{speaker}: #{String.slice(message.text || "", 0, @message_chars)}"
    end)
  end

  # The line is the Human's next message, so it follows the language the Human
  # writes in this conversation; the interface locale only breaks a tie.
  defp instructions(locale) do
    fallback =
      if is_binary(locale) and locale != "",
        do: "the language of the locale #{locale}",
        else: "the language the Agent uses"

    language =
      "Write it in the language the Human writes in this conversation, or in #{fallback} when the Human has not written yet."

    """
    Suggest the single message that the Human would most plausibly send next
    in this conversation, written as the Human would type it to the Agent.
    Keep it to one line of at most 80 characters. Prefer a concrete follow-up
    that moves the work forward, such as a next request, a decision, or a
    clarification the reply invites. Do not greet, thank, or repeat what the
    Human already said. Return null when no natural follow-up exists.
    #{language}
    """
  end
end
