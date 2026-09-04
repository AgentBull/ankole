defmodule AnkoleWeb.AIGatewayConversationController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Read-only console API for browsing AIGateway conversations and their messages.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIGateway.ConsoleQueries
  alias Ankole.AIGateway.Schemas.Conversation
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayConversationResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AIGatewayMessageListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias OpenAPISpex.Schema

  tags(["AI Gateway Conversations"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "List AIGateway conversations",
    parameters: [
      subject: [in: :query, type: :string, required: false],
      key: [in: :query, type: :string, required: false],
      q: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Matches an exact subject UID, a conversation-key fragment, or a fragment of a channel or DM peer name."
      ],
      active: [in: :query, schema: %Schema{type: :boolean}, required: false],
      min_messages: [in: :query, schema: %Schema{type: :integer, minimum: 1}, required: false],
      cursor: [in: :query, type: :string, required: false],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 100},
        required: false
      ]
    ],
    responses: [
      ok: {"Conversations", "application/json", AIGatewayConversationListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  operation(:show,
    summary: "Read one AIGateway conversation",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Conversation", "application/json", AIGatewayConversationResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:messages,
    summary: "List the messages of one AIGateway conversation",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      cursor: [in: :query, type: :string, required: false],
      limit: [
        in: :query,
        schema: %Schema{type: :integer, minimum: 1, maximum: 500},
        required: false
      ]
    ],
    responses: [
      ok: {"Messages", "application/json", AIGatewayMessageListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid filters", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_conversations", "read"),
         {:ok, page} <-
           ConsoleQueries.list_conversations(
             subject_uid: params[:subject],
             conversation_key: params[:key],
             search: params[:q],
             active: ConsoleParams.boolean(params, :active, nil),
             min_messages: ConsoleParams.integer(params, :min_messages, nil),
             cursor: params[:cursor],
             limit: ConsoleParams.integer(params, :limit, 50)
           ) do
      json(conn, %{
        conversations: ConsoleQueries.console_projections(page.conversations),
        next_cursor: page.next_cursor
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, %{conversation_id: conversation_id}) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_conversations", "read"),
         %Conversation{} = conversation <- ConsoleQueries.get_conversation(conversation_id) do
      json(conn, %{conversation: ConsoleQueries.console_projection(conversation)})
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  def messages(conn, %{conversation_id: conversation_id} = params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_conversations", "read") do
      # A missing or unknown conversation yields an empty page rather than 404,
      # so the read-only browser keeps rendering when navigating stale links.
      case ConsoleQueries.list_messages(conversation_id,
             cursor: params[:cursor],
             limit: ConsoleParams.integer(params, :limit, 200)
           ) do
        {:ok, page} ->
          json(conn, %{
            messages: Enum.map(page.messages, &ConsoleQueries.console_projection/1),
            next_cursor: page.next_cursor
          })

        {:error, reason} ->
          error(conn, reason)
      end
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "conversation was not found")

  defp error(conn, reason) do
    error(conn, 422, "invalid_conversation_request", "conversation request is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
