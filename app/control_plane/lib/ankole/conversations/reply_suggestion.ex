defmodule Ankole.Conversations.ReplySuggestion do
  @moduledoc """
  Suggests the next message that a Human may send after an Agent's reply.

  Pod asks for a suggestion once a reply has completed in a conversation where
  the Human is the only human participant. The Agent that wrote the latest
  message drafts one line with its `light` model profile from the recent
  transcript. Ankole stores nothing: the suggestion only fills the Human's
  draft when the Human adopts it.
  """

  require Ash.Query
  require Logger

  alias Ankole.AIGateway
  alias Ankole.AuthZ.Actor
  alias Ankole.Conversations.{Message, NativeRoom}

  @transcript_messages 8
  @message_chars 1_500
  @max_chars 120

  @doc """
  Returns `%{message_id: id, text: text}` for the latest message of a room that
  the Human can read. `text` is nil when the room has another human
  participant, when the latest message is not an Agent reply, or when the model
  gives no usable line.
  """
  @spec suggest(Actor.t(), String.t(), keyword()) ::
          {:ok, %{message_id: String.t() | nil, text: String.t() | nil}} | {:error, :not_found}
  def suggest(%Actor{} = actor, conversation_id, opts \\ []) do
    case NativeRoom.visible(actor, conversation_id) do
      nil ->
        {:error, :not_found}

      conversation ->
        messages = recent_messages(conversation)

        case List.last(messages) do
          %Message{author_type: :agent, kind: :message, author_uid: agent_uid} = latest
          when is_binary(agent_uid) ->
            text =
              if only_human?(conversation.id, Actor.uid(actor)),
                do: draft(agent_uid, messages, Keyword.get(opts, :locale))

            {:ok, %{message_id: latest.id, text: text}}

          latest ->
            {:ok, %{message_id: latest && latest.id, text: nil}}
        end
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

  defp only_human?(conversation_id, uid) do
    conversation_id
    |> NativeRoom.participants()
    |> Enum.reject(&(&1.role == :agent))
    |> Enum.map(& &1.principal_uid)
    |> Kernel.==([uid])
  end

  defp draft(agent_uid, messages, locale) do
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
             caller: "reply_suggestion"
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
