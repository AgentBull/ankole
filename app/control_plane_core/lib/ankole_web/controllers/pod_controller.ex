defmodule AnkoleWeb.PodController do
  @moduledoc "Browser API for the current Human's native conversations."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias AnkoleWeb.Schemas.InternalAPI

  operation(:events,
    operation_id: "podConversationEvents",
    summary: "Stream conversation events",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Events", "text/event-stream", %OpenApiSpex.Schema{type: :string}},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      413 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  alias Ankole.Conversations
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.PodStream

  operation(:agents,
    operation_id: "podAgents",
    summary: "podAgents",
    responses: %{
      200 => {"Success", "application/json", InternalAPI.PodAgents},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  def agents(conn, _params) do
    json(conn, %{agents: Enum.map(Conversations.agents(), &agent_json/1)})
  end

  operation(:index,
    operation_id: "podConversations",
    summary: "podConversations",
    parameters: [pageID: [in: :query, type: :string, required: false]],
    responses: %{
      200 => {"Success", "application/json", InternalAPI.Conversations},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  def index(conn, params) do
    uid = conn.assigns.current_principal_uid

    result =
      if Map.has_key?(params, "pageID"),
        do: Conversations.list_for_page(uid, params["pageID"]),
        else: {:ok, Conversations.list(uid)}

    case result do
      {:ok, conversations} ->
        json(conn, %{conversations: Enum.map(conversations, &conversation_json/1)})

      {:error, reason} ->
        error(conn, reason)
    end
  end

  operation(:create,
    operation_id: "createConversation",
    summary: "createConversation",
    request_body: {"Request", "application/json", InternalAPI.ConversationCreateRequest},
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  def create(conn, _params) do
    with {:ok, attrs} <- create_attrs(conn.body_params),
         {:ok, detail} <- Conversations.create(conn.assigns.current_principal_uid, attrs) do
      json(conn, detail_json(detail))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:show,
    operation_id: "conversationDetail",
    summary: "conversationDetail",
    parameters: [
      id: [in: :path, type: :string, required: true],
      loadedFirstSeq: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1},
        required: false
      ],
      beforeSeq: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1},
        required: false
      ]
    ],
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  def show(conn, %{"id" => id} = params) do
    with {:ok, before} <- history_sequence(params["beforeSeq"]),
         {:ok, loaded_first} <- history_sequence(params["loadedFirstSeq"]),
         {:ok, detail} <-
           Conversations.get(conn.assigns.current_principal_uid, id,
             before_seq: before,
             loaded_first_seq: loaded_first
           ) do
      json(conn, detail_json(detail))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp history_sequence(nil), do: {:ok, nil}
  defp history_sequence(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp history_sequence(value) when is_binary(value) do
    case Integer.parse(value) do
      {sequence, ""} when sequence > 0 -> {:ok, sequence}
      _ -> {:error, :invalid_request}
    end
  end

  defp history_sequence(_value), do: {:error, :invalid_request}

  operation(:post_message,
    operation_id: "postConversationMessage",
    summary: "postConversationMessage",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", InternalAPI.ConversationMessageRequest},
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  def post_message(conn, %{"id" => id}) do
    with {:ok, attrs} <- message_attrs(conn.body_params),
         {:ok, detail} <- Conversations.post(conn.assigns.current_principal_uid, id, attrs) do
      json(conn, detail_json(detail))
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:update_queue,
    operation_id: "updateConversationQueue",
    summary: "Update pending conversation inputs or stop and resume the queue",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", InternalAPI.ConversationQueueRequest},
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      403 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      409 => {"Error", "application/json", InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", InternalAPI.ErrorEnvelope}
    }
  )

  def update_queue(conn, %{"id" => id}) do
    params = conn.body_params

    attrs = %{
      action: params["action"],
      message_id: params["messageID"],
      message_ids: params["messageIDs"],
      text: params["text"],
      command_id: params["commandID"],
      expected_version: params["expectedVersion"],
      expected_text: params["expectedText"]
    }

    case Conversations.update_queue(conn.assigns.current_principal_uid, id, attrs) do
      {:ok, detail} -> json(conn, detail_json(detail))
      {:error, reason} -> error(conn, reason)
    end
  end

  def events(conn, %{"id" => id}) do
    with {:ok, detail} <- Conversations.get(conn.assigns.current_principal_uid, id),
         {:ok, conn} <- PodStream.open(conn, detail) do
      conn
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:delete,
    operation_id: "deleteConversation",
    summary: "deleteConversation",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      unauthorized: {"Error", "application/json", InternalAPI.ErrorEnvelope},
      not_found: {"Error", "application/json", InternalAPI.ErrorEnvelope},
      conflict: {"Error", "application/json", InternalAPI.ErrorEnvelope}
    ]
  )

  def delete(conn, %{"id" => id}) do
    case Conversations.delete(conn.assigns.current_principal_uid, id) do
      {:ok, _} ->
        send_resp(conn, 204, "")

      {:error, :conversation_busy} ->
        conn
        |> put_status(409)
        |> json(%{
          error: %{
            code: "conversation_busy",
            message: "Wait for the current work to finish before deleting this conversation."
          }
        })

      {:error, reason} ->
        error(conn, reason)
    end
  end

  defp create_attrs(
         %{
           "conversationID" => conversation_id,
           "agentUID" => agent_uid,
           "messageID" => message_id,
           "text" => text
         } = params
       ) do
    {:ok,
     %{
       conversation_id: conversation_id,
       agent_uid: agent_uid,
       message_id: message_id,
       text: text,
       attachments: params["attachments"],
       model_profile: params["modelProfile"],
       delivery_mode: params["deliveryMode"],
       page_id: params["pageID"]
     }}
  end

  defp create_attrs(_params), do: {:error, :invalid_request}

  defp message_attrs(%{"messageID" => message_id, "text" => text} = params),
    do:
      {:ok,
       %{
         message_id: message_id,
         text: text,
         delivery_mode: params["deliveryMode"],
         attachments: params["attachments"]
       }}

  defp message_attrs(_params), do: {:error, :invalid_request}

  defp detail_json(detail) do
    %{
      conversation: conversation_json(detail),
      messages: Enum.map(detail.messages, &message_json/1),
      olderMessagesBeforeSeq: detail.older_messages_before_seq,
      removedMessageIDs: detail.removed_message_ids,
      messageRange: %{
        firstSeq: detail.message_range.first_seq,
        lastSeq: detail.message_range.last_seq
      },
      queueVersion: detail.queue_version,
      retryableMessageID: detail.retryable_message_id,
      queuePaused: detail.conversation.metadata["queue_paused"] == true,
      pendingInputs:
        Enum.map(detail.pending_inputs, fn input ->
          %{
            messageID: input.message_id,
            text: input.data["text"] || "",
            attachments: get_in(input.data, ["entry", "attachments"]) || [],
            modelProfile: input.data["model_profile"] || "primary",
            deliveryMode: input.data["delivery_mode"] || "steer"
          }
        end),
      status: %{
        state: to_string(detail.status.state),
        retryAt: timestamp(detail.status.retry_at),
        activity:
          elem(
            Ankole.Sessions.Activity.current(%{
              agent_uid: detail.agent.uid,
              session_id: detail.session_id
            }),
            0
          )
      }
    }
  end

  defp conversation_json(%{conversation: conversation, agent: agent}) do
    %{
      id: conversation.id,
      title: conversation.title,
      pageID: conversation.page_id,
      agent: Map.put(agent_json(agent), :active, agent.status == :active),
      lastActivityAt: timestamp(conversation.last_activity_at)
    }
  end

  defp agent_json(agent), do: %{uid: agent.uid, displayName: agent.display_name}

  defp message_json(message) do
    %{
      id: message.id,
      seq: message.seq,
      authorType: to_string(message.author_type),
      authorUID: message.author_uid,
      kind: to_string(message.kind),
      text: message.text || "",
      links: message.links,
      attachments: message.attachments,
      createdAt: timestamp(message.created_at),
      signalID: message.signal_id,
      replyToMessageID: message.reply_to_message_id
    }
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp error(conn, :conversation_not_found),
    do: ConsoleErrors.render(conn, 404, "conversation_not_found", "Conversation not found")

  defp error(conn, :agent_unavailable),
    do: ConsoleErrors.render(conn, 409, "agent_unavailable", "Agent is unavailable")

  defp error(conn, :page_unavailable),
    do:
      ConsoleErrors.render(
        conn,
        403,
        "page_unavailable",
        "The page is unavailable or you no longer have access to it"
      )

  defp error(conn, :conversation_conflict),
    do: ConsoleErrors.render(conn, 409, "conversation_conflict", "Conversation facts conflict")

  defp error(conn, :invalid_id),
    do: ConsoleErrors.render(conn, 422, "invalid_id", "ID is invalid")

  defp error(conn, :invalid_text),
    do: ConsoleErrors.render(conn, 422, "invalid_text", "Message text is invalid")

  defp error(conn, :invalid_attachment),
    do: ConsoleErrors.render(conn, 422, "invalid_attachment", "The attachment upload is invalid")

  defp error(conn, :attachment_expired),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "attachment_expired",
        "The attachment upload expired. Upload it again"
      )

  defp error(conn, {:blob_missing, _}), do: error(conn, :attachment_expired)

  defp error(conn, :invalid_request),
    do: ConsoleErrors.render(conn, 422, "invalid_request", "Request is invalid")

  defp error(conn, :reply_unavailable),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "reply_unavailable",
        "Only the latest completed turn can be changed"
      )

  defp error(conn, :requires_queue_for_profile),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "requires_queue_for_profile",
        "Queue this message to use a different model after the current reply"
      )

  defp error(conn, :model_profile_unavailable),
    do:
      ConsoleErrors.render(
        conn,
        422,
        "model_profile_unavailable",
        "The selected model profile is unavailable"
      )

  defp error(conn, :input_already_started),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "input_already_started",
        "This input has already started or is no longer pending"
      )

  defp error(conn, :queue_changed),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "queue_changed",
        "The pending queue changed. Reload it before reordering"
      )
end
