defmodule AnkoleWeb.PodAttachmentController do
  @moduledoc "Human chat uploads and frozen Message attachments."
  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_file: 5]
  alias Ankole.Conversations.Attachments
  alias Ankole.Conversations.Attachments.Native
  alias AnkoleWeb.Schemas.InternalAPI
  alias OpenApiSpex.Schema

  tags(["Pod"])

  operation(:upload,
    operation_id: "uploadConversationAttachment",
    summary: "Prepare a Human chat attachment",
    request_body:
      {"Request", "multipart/form-data", InternalAPI.ConversationAttachmentUpload, required: true},
    responses: %{
      200 => {"Success", "application/json", InternalAPI.ConversationAttachmentReceipt},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.InternalAPI.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.InternalAPI.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.InternalAPI.ErrorEnvelope}
    }
  )

  def upload(conn, _params) do
    case conn.body_params do
      %{"file" => %Plug.Upload{} = file, "fileID" => id} ->
        respond(
          conn,
          Native.upload(
            conn.assigns.current_principal_uid,
            id,
            file.filename,
            {:file, file.path},
            file.content_type
          )
        )

      _ ->
        error(conn, :missing_file)
    end
  end

  operation(:download,
    operation_id: "conversationAttachmentDownload",
    summary: "Read a visible Message attachment",
    parameters: [
      id: [in: :path, type: :string, required: true],
      message_id: [in: :path, type: :string, required: true],
      path: [in: :query, schema: %Schema{type: :string}, required: true],
      download: [
        in: :query,
        schema: %Schema{type: :string, enum: ["true", "false"]},
        required: false
      ]
    ],
    responses: %{
      200 => {"File", "application/octet-stream", %Schema{type: :string, format: :binary}},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.InternalAPI.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.InternalAPI.ErrorEnvelope}
    }
  )

  def download(conn, %{"id" => id, "message_id" => message_id, "path" => path} = params) do
    local = Ankole.Files.temp_path()

    try do
      case Native.read_to_file(conn.assigns.current_principal_uid, id, message_id, path, local) do
        {:ok, attachment} ->
          send_sandboxed_file(
            conn,
            local,
            attachment["name"] || Path.basename(path),
            Attachments.content_type(attachment),
            params["download"] == "true"
          )

        error_result ->
          respond(conn, error_result)
      end
    after
      File.rm(local)
    end
  end

  def download(conn, _params), do: error(conn, :not_found)
end
