defmodule AnkoleWeb.AIGatewayFilesController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  OpenAI-compatible Files API subset for AIGateway vision inputs.
  """

  use AnkoleWeb, :controller
  use OpenAPISpex.ControllerSpecs

  alias Ankole.AIGateway.Artifacts
  alias Ankole.AIGateway.OpenAIError
  alias OpenAPISpex.Schema

  @json_object %Schema{type: :object, additionalProperties: true}
  @expires_after %Schema{
    type: :object,
    required: [:anchor, :seconds],
    properties: %{
      anchor: %Schema{type: :string, enum: ["created_at"]},
      seconds: %Schema{type: :integer, minimum: 3_600, maximum: 2_592_000}
    }
  }
  @file_upload %Schema{
    type: :object,
    required: [:file, :purpose],
    properties: %{
      file: %Schema{type: :string, format: :binary},
      purpose: %Schema{type: :string, enum: ["vision"]},
      expires_after: @expires_after
    }
  }
  @file_object %Schema{
    type: :object,
    required: [:id, :object, :bytes, :created_at, :filename, :purpose, :status],
    properties: %{
      id: %Schema{type: :string},
      object: %Schema{type: :string, enum: ["file"]},
      bytes: %Schema{type: :integer, minimum: 0},
      created_at: %Schema{type: :integer},
      expires_at: %Schema{type: :integer, nullable: true},
      filename: %Schema{type: :string},
      purpose: %Schema{type: :string, enum: ["vision"]},
      status: %Schema{type: :string, enum: ["processed"]}
    }
  }
  @file_list %Schema{
    type: :object,
    required: [:object, :data, :first_id, :last_id, :has_more],
    properties: %{
      object: %Schema{type: :string, enum: ["list"]},
      data: %Schema{type: :array, items: @file_object},
      first_id: %Schema{type: :string, nullable: true},
      last_id: %Schema{type: :string, nullable: true},
      has_more: %Schema{type: :boolean}
    }
  }
  @deleted_file %Schema{
    type: :object,
    required: [:id, :object, :deleted],
    properties: %{
      id: %Schema{type: :string},
      object: %Schema{type: :string, enum: ["file"]},
      deleted: %Schema{type: :boolean}
    }
  }

  tags(["AIGateway Files"])
  security([%{"aiGatewayBearer" => []}, %{"consoleBearer" => []}])

  operation(:create,
    summary: "Upload an AIGateway vision file",
    request_body: {"Vision file", "multipart/form-data", @file_upload, required: true},
    responses: [
      ok: {"File object", "application/json", @file_object},
      bad_request: {"Invalid file", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def create(conn, _params) do
    params = conn.body_params || %{}
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case upload(params) do
      %Plug.Upload{} = upload ->
        case Artifacts.create_uploaded_file(subject_uid, upload, params) do
          {:ok, artifact} -> json(conn, Artifacts.file_object(artifact))
          {:error, reason} -> error(conn, reason)
        end

      _missing ->
        error(
          conn,
          OpenAIError.invalid("file", "missing_required_parameter", "file is required.")
        )
    end
  end

  operation(:index,
    summary: "List AIGateway vision files",
    parameters: [
      after: [in: :query, type: :string, required: false],
      limit: [in: :query, type: :integer, required: false],
      order: [
        in: :query,
        schema: %Schema{type: :string, enum: ["asc", "desc"]},
        required: false
      ],
      purpose: [
        in: :query,
        schema: %Schema{type: :string, enum: ["vision"]},
        required: false
      ]
    ],
    responses: [
      ok: {"File list", "application/json", @file_list},
      bad_request: {"Invalid pagination", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def index(conn, params) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.list_files(subject_uid, params) do
      {:ok, body} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:show,
    summary: "Retrieve an AIGateway vision file",
    parameters: [file_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"File object", "application/json", @file_object},
      not_found: {"Not found", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def show(conn, %{"file_id" => file_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.get_file(subject_uid, file_id) do
      {:ok, artifact} -> json(conn, Artifacts.file_object(artifact))
      {:error, reason} -> error(conn, reason)
    end
  end

  operation(:content,
    summary: "Download AIGateway vision file content",
    parameters: [file_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"File bytes", "application/octet-stream", %Schema{type: :string, format: :binary}},
      not_found: {"Not found", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def content(conn, %{"file_id" => file_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.get_file(subject_uid, file_id, payload?: true) do
      {:ok, artifact} ->
        conn
        |> put_resp_header("content-type", artifact.mime_type)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename*=UTF-8''" <>
            URI.encode(artifact.filename || "image", &URI.char_unreserved?/1)
        )
        |> send_resp(200, artifact.payload)

      {:error, reason} ->
        error(conn, reason)
    end
  end

  operation(:delete,
    summary: "Delete an AIGateway vision file",
    parameters: [file_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Deleted file", "application/json", @deleted_file},
      not_found: {"Not found", "application/json", @json_object},
      unauthorized: {"Unauthorized", "application/json", @json_object}
    ]
  )

  def delete(conn, %{"file_id" => file_id}) do
    subject_uid = conn.assigns.current_ai_gateway_subject_uid

    case Artifacts.delete_file(subject_uid, file_id) do
      {:ok, body} -> json(conn, body)
      {:error, reason} -> error(conn, reason)
    end
  end

  defp upload(params) when is_map(params), do: Map.get(params, "file") || Map.get(params, :file)

  defp error(conn, %OpenAIError{} = error) do
    conn
    |> put_status(error.status)
    |> json(OpenAIError.envelope(error))
  end

  defp error(conn, _reason) do
    error(
      conn,
      %OpenAIError{
        status: 500,
        message: "The file request could not be completed.",
        type: "server_error",
        code: "server_error",
        param: nil
      }
    )
  end
end
