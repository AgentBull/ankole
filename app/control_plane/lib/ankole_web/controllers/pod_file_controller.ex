defmodule AnkoleWeb.PodFileController do
  @moduledoc "Files accessed through their owning Pod page."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_file: 5]

  alias Ankole.Pod.Files
  alias Ankole.WorkerFiles

  def download(conn, %{"id" => id, "path" => path} = params) do
    local_path = Ankole.Files.temp_path()

    try do
      case Files.read_to_file(actor(conn), id, path, local_path, params["sha256"]) do
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

  def upload(conn, %{"id" => id}) do
    body = conn.body_params

    with %Plug.Upload{} = file <- Ankole.Attrs.get(body, :file),
         {:ok, stat} <- File.stat(file.path),
         true <- stat.size <= WorkerFiles.max_transfer_bytes() do
      respond(
        conn,
        Files.upload(
          actor(conn),
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

  defp actor(conn), do: conn.assigns.authz_actor

  defp revision(body),
    do: body |> Ankole.Attrs.get(:base_revision) |> Ankole.Attrs.integer_value()
end
