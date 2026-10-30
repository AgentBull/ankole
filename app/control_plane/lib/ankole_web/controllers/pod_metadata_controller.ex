defmodule AnkoleWeb.PodMetadataController do
  @moduledoc "Tenant-wide Pod metadata files, such as the shared custom-emoji library."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_file: 5]

  alias Ankole.Pod.Metadata

  def custom_emojis(conn, _params) do
    respond(conn, Metadata.custom_emojis(conn.assigns.authz_actor))
  end

  def upload_custom_emoji(conn, _params) do
    body = conn.body_params

    case Ankole.Attrs.get(body, :file) do
      %Plug.Upload{} = file ->
        name = Ankole.Attrs.get(body, :name)

        respond(
          conn,
          Metadata.upload_custom_emoji(
            conn.assigns.authz_actor,
            name,
            {:file, file.path},
            file.content_type
          )
        )

      _ ->
        error(conn, :missing_file)
    end
  end

  def download(conn, %{"path" => path} = params) do
    local = Ankole.Files.temp_path()

    try do
      case Metadata.read_to_file(conn.assigns.authz_actor, path, local) do
        {:ok, file} ->
          send_sandboxed_file(
            conn,
            local,
            file.name,
            file.content_type,
            params["download"] == "true"
          )

        error_result ->
          respond(conn, error_result)
      end
    after
      File.rm(local)
    end
  end

  def download(conn, _params), do: error(conn, :invalid_path)
end
