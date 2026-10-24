defmodule AnkoleWeb.AgentFileController do
  @moduledoc "Multipart uploads and byte downloads for an Agent drive."
  use AnkoleWeb, :controller
  action_fallback :fallback
  alias Ankole.{Attrs, Files, WorkerFiles}
  alias Ankole.Files.Schemas.DriveFile
  alias AnkoleWeb.ConsoleErrors

  def download(conn, params) do
    local_path = Files.temp_path()

    try do
      with {:ok, agent_uid} <-
             Attrs.required_text(Map.get(params, "agent_uid"), {:missing, :agent_uid}),
           {:ok, %DriveFile{} = file} <-
             Files.console_download(
               conn.assigns.authz_actor,
               agent_uid,
               Map.get(params, "path"),
               local_path
             ) do
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

  def upload(conn, params) do
    body = conn.body_params

    with {:ok, agent_uid} <-
           Attrs.required_text(Map.get(params, "agent_uid"), {:missing, :agent_uid}),
         {:ok, upload} <- upload_param(body),
         :ok <- assert_upload_size(upload),
         {:ok, file} <-
           Files.console_upload(
             conn.assigns.authz_actor,
             agent_uid,
             Map.get(body, "path"),
             upload.path,
             upload.content_type
           ) do
      json(conn, %{uploaded_file: Files.ConsoleActions.file_json(file)})
    end
  end

  defp upload_param(body) do
    case Map.get(body, "file") do
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
