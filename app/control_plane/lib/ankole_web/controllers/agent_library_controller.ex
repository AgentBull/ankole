defmodule AnkoleWeb.AgentLibraryController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed Agent MISSION, SOUL, DESIGN, and
  ConfidentialityPolicy documents.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIAgent.Library
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsoleParams
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentsResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentLibraryDocumentWriteRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope
  alias OpenAPISpex.Schema

  @document_kinds ~w(mission soul design confidentiality_policy)

  tags(["Agents"])
  security([%{"consoleBearer" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "Read the MISSION, SOUL, DESIGN, and ConfidentialityPolicy documents for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent library documents", "application/json", AgentLibraryDocumentsResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope}
    ]
  )

  operation(:update,
    summary: "Replace one agent MISSION, SOUL, DESIGN, or ConfidentialityPolicy document",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      document_kind: [
        in: :path,
        schema: %Schema{type: :string, enum: @document_kinds},
        required: true
      ]
    ],
    request_body:
      {"Agent library document", "application/json", AgentLibraryDocumentWriteRequest,
       required: true},
    responses: [
      ok: {"Agent library document", "application/json", AgentLibraryDocumentResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Document changed", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid document", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "read"),
         {:ok, documents} <- Library.list_agent_documents(agent_uid) do
      json(conn, %{library_documents: documents})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def update(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         {:ok, document_kind} <- document_kind_param(params),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "update"),
         {:ok, content} <- body_text(conn.body_params, :content),
         {:ok, expected_content_hash} <- body_text(conn.body_params, :expected_content_hash),
         {:ok, document} <-
           Library.replace_agent_document(
             agent_uid,
             document_kind,
             content,
             expected_content_hash
           ) do
      json(conn, %{library_document: document})
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  defp document_kind_param(params) do
    with {:ok, kind} <- ConsoleParams.text(params, :document_kind),
         true <- kind in @document_kinds do
      {:ok, kind}
    else
      false -> {:error, :invalid_document_kind}
      {:error, _reason} = error -> error
    end
  end

  defp body_text(params, key) when is_map(params) do
    case Map.get(params, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing, Atom.to_string(key)}}
    end
  end

  defp body_text(_params, key), do: {:error, {:missing, Atom.to_string(key)}}

  defp error(conn, :forbidden), do: error(conn, 403, "forbidden", "access denied")
  defp error(conn, :not_found), do: error(conn, 404, "not_found", "agent was not found")

  defp error(conn, :agent_library_document_conflict) do
    error(
      conn,
      409,
      "agent_library_document_conflict",
      "agent library document changed since it was loaded"
    )
  end

  defp error(conn, {:missing, key}) do
    error(conn, 422, "validation_failed", "#{key} is required")
  end

  defp error(conn, reason) when reason in [:invalid_document_kind, :invalid_agent_document] do
    error(conn, 422, "validation_failed", "agent library document is invalid")
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    error(
      conn,
      422,
      "validation_failed",
      "request validation failed",
      ConsoleErrors.changeset_details(changeset)
    )
  end

  defp error(conn, reason) do
    error(conn, 422, "invalid_agent_library_document", "agent library document is invalid", [
      %{reason: inspect(reason)}
    ])
  end

  defp error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
