defmodule AnkoleWeb.PodAttachmentController do
  @moduledoc "Human chat uploads and frozen Message attachments."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_file: 5]
  alias Ankole.Conversations.Attachments
  alias Ankole.Conversations.Attachments.Native

  def upload(conn, _params) do
    case conn.body_params do
      %{"file" => %Plug.Upload{} = file, "fileID" => id} ->
        respond(
          conn,
          Native.upload(
            conn.assigns.authz_actor,
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

  def download(conn, %{"id" => id, "message_id" => message_id, "path" => path} = params) do
    local = Ankole.Files.temp_path()

    try do
      case Native.read_to_file(conn.assigns.authz_actor, id, message_id, path, local) do
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
