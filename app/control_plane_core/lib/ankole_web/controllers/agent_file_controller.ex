defmodule AnkoleWeb.AgentFileController do
  alias OpenApiSpex, as: OpenAPISpex

  @moduledoc """
  Console REST API for one Agent's drive.

  The drive lives in the control plane, so every operation works while the
  Agent has no running Worker. File paths carry slashes, so a path is always a
  query or body parameter, never a path segment.
  """

  use AnkoleWeb, :controller

  action_fallback :fallback
  use OpenAPISpex.ControllerSpecs

  alias Ankole.Files
  alias Ankole.Files.Schemas.DriveFile
  alias Ankole.Principals
  alias Ankole.WorkerFiles
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileDeleteResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileListResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileMoveRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileMoveResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileUploadRequest
  alias AnkoleWeb.Schemas.ConsoleAPI.AgentFileUploadResponse
  alias AnkoleWeb.Schemas.ConsoleAPI.ErrorEnvelope

  alias OpenAPISpex.Schema

  tags(["Agents"])
  security([%{"consoleSession" => []}])

  plug OpenAPISpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenAPIValidationErrorRenderer

  @errors [
    default: {"Error", "application/json", ErrorEnvelope}
  ]

  operation(:index,
    summary: "List the files and subfolders of one folder in an Agent's drive",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      path: [
        in: :query,
        type: :string,
        required: false,
        description: "Folder path; empty lists the drive root"
      ]
    ],
    responses: [ok: {"Folder listing", "application/json", AgentFileListResponse}] ++ @errors
  )

  operation(:download,
    summary: "Download one file from an Agent's drive",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      path: [in: :query, type: :string, required: true, description: "File path"]
    ],
    responses:
      [
        ok: {"File content", "application/octet-stream", %Schema{type: :string, format: :binary}}
      ] ++ @errors
  )

  operation(:upload,
    summary: "Upload one file into an Agent's drive",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body:
      {"multipart form", "multipart/form-data", AgentFileUploadRequest, required: true},
    responses: [ok: {"Uploaded file", "application/json", AgentFileUploadResponse}] ++ @errors
  )

  operation(:move,
    summary: "Rename or move a file or folder in an Agent's drive",
    parameters: [agent_uid: [in: :path, type: :string, required: true]],
    request_body: {"Move", "application/json", AgentFileMoveRequest, required: true},
    responses: [ok: {"Moved files", "application/json", AgentFileMoveResponse}] ++ @errors
  )

  operation(:delete,
    summary: "Delete a file, or a folder and every file in it, from an Agent's drive",
    parameters: [
      agent_uid: [in: :path, type: :string, required: true],
      path: [in: :query, type: :string, required: true, description: "File or folder path"]
    ],
    responses: [ok: {"Deleted files", "application/json", AgentFileDeleteResponse}] ++ @errors
  )

  def index(conn, %{agent_uid: agent_uid} = params) do
    path = Map.get(params, :path, "")

    with {:ok, agent_uid} <- authorize(conn, agent_uid, "read"),
         {:ok, %{folders: folders, files: files, truncated: truncated}} <-
           Files.list_children(agent_uid, path) do
      json(conn, %{
        file_listing: %{
          path: path,
          folders:
            Enum.map(folders, &%{name: &1, path: if(path == "", do: &1, else: path <> "/" <> &1)}),
          files: Enum.map(files, &file_json/1),
          truncated: truncated
        }
      })
    end
  end

  def download(conn, %{agent_uid: agent_uid, path: path}) do
    local_path = Files.temp_path()

    try do
      with {:ok, agent_uid} <- authorize(conn, agent_uid, "read"),
           {:ok, %DriveFile{} = file} <- Files.read_to_file(agent_uid, path, local_path) do
        conn
        |> put_resp_content_type(file.content_type)
        |> put_resp_header(
          "content-disposition",
          "attachment; filename*=UTF-8''" <>
            URI.encode(Path.basename(file.path), &URI.char_unreserved?/1)
        )
        |> send_file(200, local_path)
      end
    after
      File.rm(local_path)
    end
  end

  def upload(conn, %{agent_uid: agent_uid}) do
    %{path: path} = body = conn.body_params

    with {:ok, agent_uid} <- authorize(conn, agent_uid, "update"),
         {:ok, upload} <- upload_param(body),
         :ok <- assert_upload_size(upload),
         {:ok, %{sha256: sha256}} <- Files.store({:file, upload.path}),
         {:ok, %{files: [file]}} <-
           Files.commit(agent_uid, [
             %{
               path: path,
               sha256: sha256,
               source: "console",
               content_type: upload.content_type
             }
           ]) do
      json(conn, %{uploaded_file: file_json(file)})
    end
  end

  def move(conn, %{agent_uid: agent_uid}) do
    %{from_path: from_path, to_path: to_path} = conn.body_params

    with {:ok, agent_uid} <- authorize(conn, agent_uid, "update"),
         {:ok, moved} <- Files.move(agent_uid, from_path, to_path) do
      json(conn, %{moved_files: moved})
    end
  end

  def delete(conn, %{agent_uid: agent_uid, path: path}) do
    with {:ok, agent_uid} <- authorize(conn, agent_uid, "delete"),
         {:ok, deleted} <- Files.delete(agent_uid, path) do
      json(conn, %{deleted_files: deleted})
    end
  end

  defp file_json(%DriveFile{} = file) do
    %{
      path: file.path,
      size: file.size,
      content_type: file.content_type,
      source: file.source,
      conversation_id: file.conversation_id,
      message_id: file.message_id,
      updated_at: DateTime.to_iso8601(file.updated_at)
    }
  end

  # Returns the canonical Agent UID. A permitted caller learns that an Agent
  # does not exist, instead of seeing an empty drive or a failed write.
  defp authorize(conn, agent_uid, action) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         :ok <- ConsolePolicy.authorize(conn, "agent:#{agent_uid}:files", action),
         {:ok, _agent} <- Principals.get_agent(agent_uid) do
      {:ok, agent_uid}
    else
      {:error, :invalid_uid} -> {:error, {:missing, "agent_uid"}}
      {:error, :not_found} -> {:error, :agent_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp upload_param(body) do
    case Map.get(body, :file) do
      %Plug.Upload{} = upload -> {:ok, upload}
      _value -> {:error, :missing_file}
    end
  end

  # One bound for every file that moves between the drive and a Worker.
  defp assert_upload_size(%Plug.Upload{path: path}) do
    max_bytes = WorkerFiles.max_transfer_bytes()

    case File.stat!(path).size do
      size when size > max_bytes -> {:error, {:file_too_large, size, max_bytes}}
      _size -> :ok
    end
  end

  defp fallback(conn, failure), do: ConsoleErrors.fallback(conn, failure, &error/2)

  defp error(conn, :not_found), do: ConsoleErrors.not_found(conn, "file not found")

  defp error(conn, :agent_not_found),
    do: ConsoleErrors.render(conn, 404, "agent_not_found", "agent not found")

  defp error(conn, :already_exists),
    do:
      ConsoleErrors.render(
        conn,
        409,
        "already_exists",
        "a file already exists at the target path"
      )

  defp error(conn, {:path_conflict, parent, child}),
    do:
      ConsoleErrors.render(conn, 409, "path_conflict", "a file cannot also be a folder", [
        %{parent: parent, child: child}
      ])

  defp error(conn, {:missing, label}),
    do: ConsoleErrors.required_field(conn, label)

  defp error(conn, :missing_file),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "file is required")

  defp error(conn, {:file_too_large, _size, max_bytes}) do
    ConsoleErrors.render(conn, 422, "file_too_large", "file exceeds the transfer limit", [
      %{max_bytes: max_bytes}
    ])
  end

  defp error(conn, {:invalid_path, value}),
    do: ConsoleErrors.render(conn, 422, "validation_failed", "invalid path", [%{value: value}])

  defp error(conn, reason) when reason in [:same_path, :move_into_itself],
    do: ConsoleErrors.render(conn, 422, "validation_failed", "invalid move target")

  defp error(conn, reason) do
    ConsoleErrors.unexpected(
      conn,
      "files.agent_file_api.unexpected_error",
      reason,
      "file_operation_failed",
      "file operation failed"
    )
  end
end
