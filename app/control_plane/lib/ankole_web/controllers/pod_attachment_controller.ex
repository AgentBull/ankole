defmodule AnkoleWeb.PodAttachmentController do
  @moduledoc "Human chat uploads and frozen Message attachments."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_object: 5]
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

  def download(conn, %{"id" => id, "message_id" => message_id, "position" => position} = params)
      when is_binary(position) do
    with {position, ""} <- Integer.parse(position),
         true <- position >= 0,
         {:ok, attachment} <-
           Ankole.Conversations.resolve_attachment(
             conn.assigns.authz_actor,
             id,
             message_id,
             position
           ),
         {:ok, object} <- Ankole.Files.fetch_object(attachment["object_id"]) do
      send_sandboxed_object(
        conn,
        object,
        attachment["name"] || "attachment",
        Attachments.content_type(attachment),
        params["download"] == "true"
      )
    else
      {:error, reason} -> error(conn, reason)
      _ -> error(conn, :not_found)
    end
  end

  def download(conn, _params), do: error(conn, :not_found)
end
