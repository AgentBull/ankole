defmodule AnkoleWeb.PodFileController do
  @moduledoc "Files accessed through their owning Pod page."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_file: 5]
  use OpenApiSpex.ControllerSpecs
  alias OpenApiSpex.Schema
  alias AnkoleWeb.Schemas.PodContent

  tags(["Pod content"])

  alias Ankole.Pod.Files
  alias Ankole.WorkerFiles

  operation(:index,
    operation_id: "podFiles",
    summary: "podFiles",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: %{
      200 => {"Success", "application/json", PodContent.FileManifest},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def index(conn, %{"id" => id}), do: respond(conn, Files.manifest(uid(conn), id))

  operation(:download,
    operation_id: "podFileDownload",
    summary: "podFileDownload",
    parameters: [
      id: [in: :path, type: :string, required: true],
      path: [in: :query, schema: %Schema{type: :string}, required: true],
      sha256: [in: :query, schema: %Schema{type: :string}, required: false],
      download: [
        in: :query,
        schema: %Schema{type: :string, enum: ["true", "false"]},
        required: false
      ]
    ],
    responses: %{
      200 =>
        {"File", "application/octet-stream", %OpenApiSpex.Schema{type: :string, format: :binary}},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def download(conn, %{"id" => id, "path" => path} = params) do
    local_path = Ankole.Files.temp_path()

    try do
      case Files.read_to_file(uid(conn), id, path, local_path, params["sha256"]) do
        {:ok, file} ->
          send_sandboxed_file(
            conn,
            local_path,
            Path.basename(path),
            file.content_type,
            params["download"] == "true"
          )

        {:error, reason} ->
          error(conn, reason)
      end
    after
      File.rm(local_path)
    end
  end

  def download(conn, _params), do: error(conn, :invalid_path)

  operation(:upload,
    operation_id: "podFileUpload",
    summary: "podFileUpload",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "multipart/form-data", PodContent.FileUpload, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.FileWriteResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def upload(conn, %{"id" => id}) do
    body = conn.body_params

    with %Plug.Upload{} = file <- Ankole.Attrs.get(body, :file),
         {:ok, stat} <- File.stat(file.path),
         true <- stat.size <= WorkerFiles.max_transfer_bytes() do
      respond(
        conn,
        Files.upload(
          uid(conn),
          id,
          Ankole.Attrs.get(body, :role, "file"),
          revision(body),
          file.filename,
          {:file, file.path},
          file.content_type
        )
      )
    else
      false -> error(conn, :file_too_large)
      _ -> error(conn, :missing_file)
    end
  end

  operation(:publish,
    operation_id: "podAppletPublish",
    summary: "podAppletPublish",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.PublishRequest, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.FileManifest},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      503 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def publish(conn, %{"id" => id}) do
    respond(
      conn,
      Files.publish(
        uid(conn),
        id,
        revision(conn.body_params),
        Ankole.Attrs.get(conn.body_params, :files)
      )
    )
  end

  operation(:copy,
    operation_id: "podFileCopy",
    summary: "podFileCopy",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body: {"Request", "application/json", PodContent.FileCopyRequest, required: true},
    responses: %{
      200 => {"Success", "application/json", PodContent.FileWriteResult},
      401 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      403 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      404 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      409 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      413 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope},
      422 => {"Error", "application/json", AnkoleWeb.Schemas.PodContent.ErrorEnvelope}
    }
  )

  def copy(conn, %{"id" => id}) do
    body = conn.body_params

    respond(
      conn,
      Files.copy_from_message(
        uid(conn),
        id,
        revision(body),
        Ankole.Attrs.get(body, :message_id),
        Ankole.Attrs.get(body, :path)
      )
    )
  end

  defp uid(conn), do: conn.assigns.current_principal_uid

  defp revision(body),
    do: body |> Ankole.Attrs.get(:base_revision) |> Ankole.Attrs.integer_value()
end
