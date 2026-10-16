defmodule AnkoleWeb.PodController do
  @moduledoc "Browser API for the current Human's native conversations."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  alias AnkoleWeb.Schemas.{ConsoleAPI, InternalAPI}

  operation(:events, false)

  alias Ankole.Conversations
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.PodStream

  operation(:agents,
    operation_id: "podAgents",
    summary: "podAgents",
    responses: %{
      200 => {"Success", "application/json", InternalAPI.PodAgents},
      401 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      403 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      404 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      409 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      422 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope}
    }
  )

  def agents(conn, _params) do
    json(conn, %{agents: Enum.map(Conversations.agents(), &agent_json/1)})
  end

  operation(:index,
    operation_id: "podConversations",
    summary: "podConversations",
    responses: %{
      200 => {"Success", "application/json", InternalAPI.Conversations},
      401 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      403 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      404 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      409 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      422 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope}
    }
  )

  def index(conn, _params) do
    conversations =
      conn.assigns.current_principal_uid
      |> Conversations.list()
      |> Enum.map(&conversation_json/1)

    json(conn, %{conversations: conversations})
  end

  operation(:create,
    operation_id: "createConversation",
    summary: "createConversation",
    request_body: {"Request", "application/json", InternalAPI.ConversationCreateRequest},
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      403 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      404 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      409 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      422 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope}
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
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      403 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      404 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      409 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      422 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope}
    }
  )

  def show(conn, %{"id" => id}) do
    case Conversations.get(conn.assigns.current_principal_uid, id) do
      {:ok, detail} -> json(conn, detail_json(detail))
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:post_message,
    operation_id: "postConversationMessage",
    summary: "postConversationMessage",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", InternalAPI.ConversationMessageRequest},
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationDetail},
      401 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      403 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      404 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      409 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope},
      422 => {"Error", "application/json", ConsoleAPI.ErrorEnvelope}
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

  def events(conn, %{"id" => id}) do
    with {:ok, detail} <- Conversations.get(conn.assigns.current_principal_uid, id),
         detail = with_execution_status(detail),
         {:ok, conn} <- PodStream.open(conn, detail) do
      conn
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp create_attrs(%{
         "conversationID" => conversation_id,
         "agentUID" => agent_uid,
         "messageID" => message_id,
         "text" => text
       }) do
    {:ok,
     %{conversation_id: conversation_id, agent_uid: agent_uid, message_id: message_id, text: text}}
  end

  defp create_attrs(_params), do: {:error, :invalid_request}

  defp message_attrs(%{"messageID" => message_id, "text" => text}),
    do: {:ok, %{message_id: message_id, text: text}}

  defp message_attrs(_params), do: {:error, :invalid_request}

  defp detail_json(detail) do
    detail = with_execution_status(detail)

    %{
      conversation: conversation_json(detail),
      messages: Enum.map(detail.messages, &message_json/1),
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

  defp with_execution_status(detail) do
    Map.put(
      detail,
      :status,
      Ankole.Sessions.status(%{
        agent_uid: detail.agent.uid,
        session_id: detail.session_id
      })
    )
  end

  defp conversation_json(%{conversation: conversation, agent: agent}) do
    %{
      id: conversation.id,
      title: conversation.title,
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
      text: message.text,
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

  defp error(conn, :conversation_conflict),
    do: ConsoleErrors.render(conn, 409, "conversation_conflict", "Conversation facts conflict")

  defp error(conn, :invalid_id),
    do: ConsoleErrors.render(conn, 422, "invalid_id", "ID is invalid")

  defp error(conn, :invalid_text),
    do: ConsoleErrors.render(conn, 422, "invalid_text", "Message text is invalid")

  defp error(conn, :invalid_request),
    do: ConsoleErrors.render(conn, 422, "invalid_request", "Request is invalid")
end
