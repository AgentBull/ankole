defmodule AnkoleWeb.AgentLibraryController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for operator-managed Agent MISSION, SOUL, DESIGN, and
  ConfidentialityPolicy documents.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
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
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  operation(:index,
    summary: "Read the MISSION, SOUL, DESIGN, and ConfidentialityPolicy documents for one agent",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Agent library documents", "application/json", AgentLibraryDocumentsResponse},
      default: {"Error", "application/json", ErrorEnvelope}
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
      default: {"Error", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    with {:ok, agent_uid} <- ConsoleParams.text(params, :agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:library", "read"),
         {:ok, documents} <- Library.list_agent_documents(agent_uid) do
      json(conn, %{library_documents: documents})
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

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "agent was not found")

  defp error(conn, :agent_library_document_conflict) do
    ConsoleErrors.render(
      conn,
      409,
      "agent_library_document_conflict",
      "agent library document changed since it was loaded"
    )
  end

  defp error(conn, {:missing, key}) do
    ConsoleErrors.required_field(conn, key)
  end

  defp error(conn, reason) when reason in [:invalid_document_kind, :invalid_agent_document] do
    ConsoleErrors.render(conn, 422, "validation_failed", "agent library document is invalid")
  end

  defp error(conn, %Ecto.Changeset{} = changeset) do
    ConsoleErrors.changeset(conn, changeset)
  end

  defp error(conn, reason) do
    ConsoleErrors.render(
      conn,
      422,
      "invalid_agent_library_document",
      "agent library document is invalid",
      [
        %{reason: inspect(reason)}
      ]
    )
  end
end
