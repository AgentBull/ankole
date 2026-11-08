defmodule AnkoleWeb.PodAvatarController do
  @moduledoc "Member and space profile pictures backed by tenant objects."
  use AnkoleWeb, :controller
  import AnkoleWeb.PodResponse, only: [respond: 2, error: 2, send_sandboxed_object: 5]

  def upload_member(conn, _params) do
    with %Plug.Upload{} = file <- conn.body_params["file"] do
      respond(
        conn,
        Ankole.Principals.upload_member_avatar(
          conn.assigns.authz_actor,
          {:file, file.path},
          file.content_type
        )
      )
    else
      _ -> error(conn, :missing_file)
    end
  end

  def upload_space(conn, _params) do
    with %Plug.Upload{} = file <- conn.body_params["file"] do
      respond(
        conn,
        Ankole.Principals.upload_space_avatar(
          conn.assigns.authz_actor,
          {:file, file.path},
          file.content_type
        )
      )
    else
      _ -> error(conn, :missing_file)
    end
  end

  def download(conn, %{"key" => key}) do
    with {:ok, avatar} <- Ankole.Principals.fetch_avatar(key),
         {:ok, object} <- Ankole.Files.fetch_object(avatar.object_id) do
      send_sandboxed_object(conn, object, "avatar", avatar.content_type, false)
    else
      {:error, reason} -> error(conn, reason)
    end
  end
end
