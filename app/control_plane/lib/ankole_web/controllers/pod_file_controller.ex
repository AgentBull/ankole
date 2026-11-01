defmodule AnkoleWeb.PodFileController do
  @moduledoc "Files accessed through their owning Pod page."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_object: 5]

  alias Ankole.Pod.Files

  def download(conn, %{"id" => id, "path" => path} = params) do
    with {:ok, file} <- Files.resolve_read(actor(conn), id, path, params["sha256"]),
         {:ok, object} <- Ankole.Files.fetch_object(file.object_id) do
      send_sandboxed_object(
        conn,
        object,
        Path.basename(path),
        file.content_type,
        params["download"] == "true"
      )
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def download(conn, _params), do: error(conn, :invalid_path)

  def upload(conn, %{"id" => id}) do
    body = conn.body_params

    with %Plug.Upload{} = file <- Ankole.Attrs.get(body, :file),
         :ok <- assert_upload_size(file) do
      respond(
        conn,
        Files.upload(
          actor(conn),
          id,
          Ankole.Attrs.get(body, :role, "file"),
          Ankole.Attrs.get(body, :base_object_id),
          file.filename,
          {:file, file.path},
          file.content_type
        )
      )
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :missing_file)
    end
  end

  def create(conn, _params) do
    body = conn.body_params

    with %Plug.Upload{} = file <- Ankole.Attrs.get(body, :file),
         :ok <- assert_upload_size(file) do
      attrs = Map.take(body, ["parent_id", "private_owner_uid"])

      result =
        Files.create_from_upload(
          actor(conn),
          attrs,
          file.filename,
          {:file, file.path},
          file.content_type
        )

      respond(
        conn,
        case result do
          {:ok, page} -> {:ok, %{page: page}}
          error -> error
        end
      )
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :missing_file)
    end
  end

  defp assert_upload_size(%Plug.Upload{path: path}) do
    with {:ok, maximum} <- Ankole.Files.upload_limit(),
         {:ok, stat} <- File.stat(path) do
      if stat.size <= maximum, do: :ok, else: {:error, :file_too_large}
    end
  end

  defp actor(conn), do: conn.assigns.authz_actor
end
