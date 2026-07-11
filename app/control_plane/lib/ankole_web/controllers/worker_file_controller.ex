defmodule AnkoleWeb.WorkerFileController do
  @moduledoc """
  Console REST API for S3-style file management on one agent computer worker.

  File paths carry slashes, so the relative path is always a query or body
  parameter, never a path segment. The workspace is installation-shared RWX
  storage; operations still target one worker so Console exposes the selected
  runtime's actual mount reachability instead of silently falling back.
  """

  use AnkoleWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Ankole.WorkerFiles
  alias AnkoleWeb.ConsoleErrors
  alias AnkoleWeb.ConsolePolicy
  alias AnkoleWeb.Schemas.ConsoleApi.ErrorEnvelope
  alias AnkoleWeb.Schemas.ConsoleApi.WorkerFileDeleteResponse
  alias AnkoleWeb.Schemas.ConsoleApi.WorkerFileListResponse
  alias AnkoleWeb.Schemas.ConsoleApi.WorkerFileMoveRequest
  alias AnkoleWeb.Schemas.ConsoleApi.WorkerFileMoveResponse
  alias AnkoleWeb.Schemas.ConsoleApi.WorkerFileUploadRequest
  alias AnkoleWeb.Schemas.ConsoleApi.WorkerFileUploadResponse

  alias OpenApiSpex.Schema

  tags(["Workers"])
  security([%{"consoleBearer" => []}])

  plug OpenApiSpex.Plug.CastAndValidate,
    render_error: AnkoleWeb.OpenApiValidationErrorRenderer

  @list_max_entries 1000

  @file_roots Ankole.WorkerFiles.roots()

  operation(:index,
    summary: "List files in one worker filesystem root",
    parameters: [
      worker_id: [in: :path, type: :string, required: true],
      root: [
        in: :query,
        schema: %Schema{type: :string, enum: @file_roots},
        required: true,
        description: "Worker filesystem root"
      ],
      path: [
        in: :query,
        type: :string,
        required: false,
        description: "Directory path relative to the root"
      ]
    ],
    responses: [
      ok: {"Files", "application/json", WorkerFileListResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Worker not ready", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid request", "application/json", ErrorEnvelope}
    ]
  )

  operation(:download,
    summary: "Download one file from a worker filesystem root",
    parameters: [
      worker_id: [in: :path, type: :string, required: true],
      root: [
        in: :query,
        schema: %Schema{type: :string, enum: @file_roots},
        required: true,
        description: "Worker filesystem root"
      ],
      path: [
        in: :query,
        type: :string,
        required: true,
        description: "File path relative to the root"
      ]
    ],
    responses: [
      ok:
        {"File content", "application/octet-stream",
         %Schema{
           type: :string,
           format: :binary
         }},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Worker not ready", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid request", "application/json", ErrorEnvelope}
    ]
  )

  operation(:upload,
    summary: "Upload one file into a worker filesystem root",
    parameters: [worker_id: [in: :path, type: :string, required: true]],
    request_body:
      {"multipart form", "multipart/form-data", WorkerFileUploadRequest, required: true},
    responses: [
      ok: {"Uploaded file", "application/json", WorkerFileUploadResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Worker not ready", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid request", "application/json", ErrorEnvelope}
    ]
  )

  operation(:move,
    summary: "Rename or move a path in a worker filesystem root",
    parameters: [worker_id: [in: :path, type: :string, required: true]],
    request_body: {"Move", "application/json", WorkerFileMoveRequest, required: true},
    responses: [
      ok: {"Moved file", "application/json", WorkerFileMoveResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Worker not ready", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid request", "application/json", ErrorEnvelope}
    ]
  )

  operation(:delete,
    summary: "Delete one file or directory from a worker filesystem root",
    parameters: [
      worker_id: [in: :path, type: :string, required: true],
      root: [
        in: :query,
        schema: %Schema{type: :string, enum: @file_roots},
        required: true,
        description: "Worker filesystem root"
      ],
      path: [
        in: :query,
        type: :string,
        required: true,
        description: "Path relative to the root"
      ],
      recursive: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Required for directories"
      ]
    ],
    responses: [
      ok: {"Deleted file", "application/json", WorkerFileDeleteResponse},
      unauthorized: {"Unauthorized", "application/json", ErrorEnvelope},
      forbidden: {"Forbidden", "application/json", ErrorEnvelope},
      not_found: {"Not found", "application/json", ErrorEnvelope},
      conflict: {"Worker not ready", "application/json", ErrorEnvelope},
      unprocessable_entity: {"Invalid request", "application/json", ErrorEnvelope}
    ]
  )

  def index(conn, params) do
    worker_id = params[:worker_id] || params["worker_id"]
    root = params[:root] || params["root"]
    path = Map.get(params, :path) || Map.get(params, "path") || ""

    with :ok <- authorize(conn, worker_id, "read"),
         {:ok, result} <-
           WorkerFiles.list(root, path, worker_id: worker_id, max_entries: @list_max_entries) do
      json(conn, %{
        data: %{
          root: result["root"],
          path: result["relative_path"],
          entries: result["entries"],
          truncated: result["truncated"]
        }
      })
    else
      {:error, reason} -> error(conn, reason, :read)
    end
  end

  def download(conn, params) do
    worker_id = params[:worker_id] || params["worker_id"]
    root = params[:root] || params["root"]
    path = params[:path] || params["path"]

    with :ok <- authorize(conn, worker_id, "read"),
         {:ok, %{"content" => content}} <- WorkerFiles.get(root, path, worker_id: worker_id) do
      filename = Path.basename(path)

      conn
      |> put_resp_content_type("application/octet-stream")
      |> put_resp_header(
        "content-disposition",
        "attachment; filename*=UTF-8''" <> URI.encode(filename, &URI.char_unreserved?/1)
      )
      |> send_resp(200, content)
    else
      {:error, reason} -> error(conn, reason, :read)
    end
  end

  def upload(conn, params) do
    worker_id = params[:worker_id] || params["worker_id"]
    body = conn.body_params || params

    root = key(body, :root)
    path = key(body, :path)

    with :ok <- authorize(conn, worker_id, "update"),
         {:ok, upload} <- upload_param(body),
         :ok <- assert_upload_size(upload),
         {:ok, content} <- File.read(upload.path),
         {:ok, result} <- WorkerFiles.put(root, path, content, worker_id: worker_id) do
      json(conn, %{
        data: %{
          root: result["root"],
          relative_path: result["relative_path"],
          size: result["size"],
          xxh3_128: result["xxh3_128"]
        }
      })
    else
      {:error, reason} -> error(conn, reason, :mutate)
    end
  end

  def move(conn, params) do
    worker_id = params[:worker_id] || params["worker_id"]

    body = conn.body_params || params

    root = key(body, :root)
    from_path = key(body, :from_path)
    to_path = key(body, :to_path)
    overwrite = key(body, :overwrite, false)

    with :ok <- authorize(conn, worker_id, "update"),
         {:ok, result} <-
           WorkerFiles.move(root, from_path, to_path,
             worker_id: worker_id,
             overwrite: overwrite
           ) do
      json(conn, %{
        data: %{
          root: result["root"],
          from_relative_path: result["from_relative_path"],
          to_relative_path: result["to_relative_path"],
          moved: result["moved"]
        }
      })
    else
      {:error, reason} -> error(conn, reason, :mutate)
    end
  end

  def delete(conn, params) do
    worker_id = params[:worker_id] || params["worker_id"]
    root = params[:root] || params["root"]
    path = params[:path] || params["path"]
    recursive = Map.get(params, :recursive) || Map.get(params, "recursive") || false

    with :ok <- authorize(conn, worker_id, "delete"),
         {:ok, result} <-
           WorkerFiles.delete(root, path, worker_id: worker_id, recursive: recursive) do
      json(conn, %{
        data: %{
          root: result["root"],
          relative_path: result["relative_path"],
          deleted: result["deleted"]
        }
      })
    else
      {:error, reason} -> error(conn, reason, :mutate)
    end
  end

  defp authorize(conn, worker_id, action) do
    with {:ok, worker_id} <- present(worker_id, "worker_id"),
         :ok <- ConsolePolicy.authorize(conn, "agent_computer_worker:#{worker_id}:files", action) do
      :ok
    end
  end

  defp key(map, name, default \\ nil) when is_map(map) do
    Map.get(map, name) || Map.get(map, Atom.to_string(name)) || default
  end

  defp upload_param(body) do
    case Map.get(body, :file) || Map.get(body, "file") do
      %Plug.Upload{} = upload -> {:ok, upload}
      _value -> {:error, :missing_file}
    end
  end

  # Rejecting before `File.read/1` keeps an oversize multipart temp file out of
  # memory; the byte bound itself is owned and re-enforced by `WorkerFiles.put/4`.
  defp assert_upload_size(%Plug.Upload{path: path}) do
    max_bytes = WorkerFiles.max_transfer_bytes()

    case File.stat!(path).size do
      size when size > max_bytes -> {:error, {:file_too_large, size, max_bytes}}
      _size -> :ok
    end
  end

  defp present(value, _label) when is_binary(value) and value != "", do: {:ok, value}
  defp present(_value, label), do: {:error, {:missing, label}}

  defp error(conn, :forbidden, _kind), do: render_error(conn, 403, "forbidden", "access denied")

  defp error(conn, {:missing, label}, _kind) do
    render_error(conn, 422, "validation_failed", "#{label} is required")
  end

  defp error(conn, :missing_file, _kind) do
    render_error(conn, 422, "validation_failed", "file is required")
  end

  defp error(conn, {:file_too_large, _size, _max_bytes}, _kind) do
    render_error(conn, 422, "file_too_large", "file exceeds the transfer limit")
  end

  defp error(conn, reason, kind) do
    {status, code, message, details} = error_descriptor(reason, kind)

    render_error(conn, status, code, message, details)
  end

  defp error_descriptor(:worker_not_found, _kind),
    do: {404, "worker_not_found", "worker was not found", []}

  defp error_descriptor(:worker_not_ready, _kind),
    do: {409, "worker_not_ready", "worker is not ready", []}

  defp error_descriptor(:timeout, _kind),
    do: {504, "worker_timeout", "worker did not respond in time", []}

  defp error_descriptor(:not_started, _kind),
    do: {503, "file_lane_unavailable", "file lane is unavailable", []}

  defp error_descriptor(%{"code" => code, "message" => message}, :read) do
    {404, "worker_file_error", message, [%{code: code}]}
  end

  defp error_descriptor(%{"code" => code, "message" => message}, :mutate) do
    {422, "worker_file_error", message, [%{code: code}]}
  end

  defp error_descriptor({:unsupported_file_root, root}, _kind) do
    {422, "validation_failed", "unsupported file root", [%{root: root}]}
  end

  defp error_descriptor({:invalid_relative_path, value}, _kind) do
    {422, "validation_failed", "invalid relative path", [%{value: value}]}
  end

  defp error_descriptor({:invalid_virtual_path, value}, _kind) do
    {422, "validation_failed", "invalid virtual path", [%{value: value}]}
  end

  defp error_descriptor(reason, _kind) do
    {422, "worker_file_error", "worker file operation failed", [%{reason: inspect(reason)}]}
  end

  defp render_error(conn, status, code, message, details \\ []) do
    ConsoleErrors.render(conn, status, code, message, details)
  end
end
