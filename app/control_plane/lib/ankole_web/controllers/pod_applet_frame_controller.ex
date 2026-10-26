defmodule AnkoleWeb.PodAppletFrameController do
  @moduledoc "Serves Applet modules under one proven browser identity and publication revision."
  use AnkoleWeb, :controller
  alias Ankole.Pod.Files
  alias AnkoleWeb.{Assets, PodResponse}

  def show(conn, %{"id" => id, "revision" => value, "path" => path}) do
    relative = if path == [], do: "index.html", else: Enum.join(path, "/")

    with {revision, ""} when revision >= 0 <- Integer.parse(value),
         {:ok, {type, digest, bytes}} <-
           Files.resolve_applet_frame_asset(conn.assigns.authz_actor, id, revision, relative) do
      bytes = if relative == "index.html", do: shell(bytes), else: bytes

      digest =
        if relative == "index.html",
          do: Base.encode16(:crypto.hash(:sha256, bytes), case: :lower),
          else: digest

      PodResponse.send_applet_frame_asset(conn, bytes, mime(relative, type), digest)
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

  defp shell(html) do
    tags =
      IO.iodata_to_binary([
        Assets.applet_frame_tags(),
        "<script>parent.__ANKOLE_APPLET_HOST__.prepare(window)</script>"
      ])

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
