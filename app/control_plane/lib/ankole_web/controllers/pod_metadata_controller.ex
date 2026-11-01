defmodule AnkoleWeb.PodMetadataController do
  @moduledoc "Tenant-wide Pod metadata files, such as the shared custom-emoji library."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_object: 5]

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
    with {:ok, file} <- Metadata.resolve(conn.assigns.authz_actor, path),
         {:ok, object} <- Ankole.Files.fetch_object(file.object_id) do
      send_sandboxed_object(
        conn,
        object,
        Path.basename(file.path),
        file.content_type,
        params["download"] == "true"
      )
    else
      {:error, reason} -> error(conn, reason)
    end
  end

  def download(conn, _params), do: error(conn, :invalid_path)
end
