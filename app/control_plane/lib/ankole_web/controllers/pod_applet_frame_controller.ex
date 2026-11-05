defmodule AnkoleWeb.PodAppletFrameController do
  @moduledoc "Serves Applet modules under one proven browser identity and publication revision."
  use AnkoleWeb, :controller
  alias Ankole.Pod.Files
  alias AnkoleWeb.{Assets, PodResponse}

  def show(conn, %{"id" => id, "revision" => value, "path" => path}) do
    relative = if path == [], do: "index.html", else: Enum.join(path, "/")

    with {revision, ""} when revision >= 0 <- Integer.parse(value),
         {:ok, file} <-
           Files.resolve_applet_frame_object(conn.assigns.authz_actor, id, revision, relative),
         {:ok, object} <- Ankole.Files.fetch_object(file.object_id) do
      if relative == "index.html" do
        serve_applet_index(conn, file, object)
      else
        PodResponse.send_applet_frame_object(conn, object, mime(relative, file.content_type))
      end
    else
      {:error, {:applet_revision_changed, _}} ->
        conn
        |> put_resp_content_type("text/html")
        |> send_resp(409, "<script>parent.__ANKOLE_APPLET_HOST__?.changed(window)</script>")

      {:error, reason} ->
        PodResponse.error(conn, reason)

      _ ->
        PodResponse.error(conn, :invalid_request)
    end
  end

  defp serve_applet_index(conn, file, object) do
    tags = shell_tags()
    digest = Base.encode16(:crypto.hash(:sha256, [object.sha256, tags]), case: :lower)
    content_type = mime("index.html", file.content_type)

    if PodResponse.applet_frame_unchanged?(conn, digest) do
      PodResponse.send_applet_frame_not_modified(conn, content_type, digest)
    else
      case Ankole.Files.read_object(file.object_id) do
        {:ok, bytes} ->
          PodResponse.send_applet_frame_asset(conn, shell(bytes, tags), content_type, digest)

        {:error, reason} ->
          PodResponse.error(conn, reason)
      end
    end
  end

  defp shell_tags do
    IO.iodata_to_binary([
      ~s(<meta name="color-scheme" content="light dark">),
      Assets.applet_frame_tags(),
      "<script>parent.__ANKOLE_APPLET_HOST__.prepare(window)</script>"
    ])
  end

  defp shell(html, tags) do
    if String.contains?(html, "<head>"),
      do: String.replace(html, "<head>", "<head>" <> tags, global: false),
      else: tags <> html
  end

  defp mime(path, fallback) do
    case Path.extname(path) do
      ".html" -> "text/html"
      ext when ext in [".js", ".mjs"] -> "text/javascript"
      ".css" -> "text/css"
      ".wasm" -> "application/wasm"
      _ -> fallback || "application/octet-stream"
    end
  end
end
