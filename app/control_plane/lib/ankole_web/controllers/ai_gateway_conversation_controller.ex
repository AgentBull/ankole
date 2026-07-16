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
      active: [in: :query, schema: %Schema{type: :boolean}, required: false],
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
             subject_uid: param(params, "subject"),
             conversation_key: param(params, "key"),
             active: active_param(params),
             cursor: param(params, "cursor"),
             limit: integer_param(params, "limit", 50)
           ) do
      json(conn, %{
        conversations: Enum.map(page.conversations, &ConsoleQueries.console_projection/1),
        next_cursor: page.next_cursor
      })
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def show(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_conversations", "read"),
         %Conversation{} = conversation <- conversation(params) do
      json(conn, %{conversation: ConsoleQueries.console_projection(conversation)})
    else
      nil -> error(conn, :not_found)
      {:error, reason} -> error(conn, reason)
    end
  end

  def messages(conn, params) do
    with :ok <- ConsolePolicy.authorize(conn, "ai_gateway_conversations", "read") do
      # A missing or unknown conversation yields an empty page rather than 404,
      # so the read-only browser keeps rendering when navigating stale links.
      case ConsoleQueries.list_messages(param(params, "conversation_id"),
             cursor: param(params, "cursor"),
             limit: integer_param(params, "limit", 200)
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

  defp conversation(params) do
    case param(params, "conversation_id") do
      id when is_binary(id) -> ConsoleQueries.get_conversation(id)
      _value -> nil
    end
  end

  defp param(params, key), do: Map.get(params, key) || Map.get(params, param_atom(key))

  defp param_atom("subject"), do: :subject
  defp param_atom("key"), do: :key
  defp param_atom("active"), do: :active
  defp param_atom("cursor"), do: :cursor
  defp param_atom("limit"), do: :limit
  defp param_atom("conversation_id"), do: :conversation_id

  defp active_param(params) do
    case param(params, "active") do
      value when is_boolean(value) -> value
      _value -> nil
    end
  end

  defp integer_param(params, key, default) do
    case param(params, key) do
      value when is_integer(value) -> value
      value when is_binary(value) -> parse_integer(value, default)
      _value -> default
    end
  end

  defp parse_integer(value, default) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _value -> default
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
