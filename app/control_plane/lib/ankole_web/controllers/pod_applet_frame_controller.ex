defmodule AnkoleWeb.PodAppletFrameController do
  @moduledoc "Serves Applet modules under one proven browser identity and publication revision."
  use AnkoleWeb, :controller
  alias Ankole.Pod.Files
  alias AnkoleWeb.{Assets, PodResponse}

  def show(conn, %{"id" => id, "revision" => value, "path" => path}) do
    relative = if path == [], do: "index.html", else: Enum.join(path, "/")

    with {:ok, revision} <- Ankole.Pod.Applets.Revisions.parse_ref(value),
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
    tags = shell_tags(conn)

    digest =
      Base.encode16(:crypto.hash(:sha256, [object.sha256 || object.id, tags]), case: :lower)

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

  defp shell_tags(conn) do
    # Desktop proxies `/pod/applet-frame/*` under `tauri://localhost` with an
    # OAuth Bearer header; keep root-relative `/assets/*` paths there so the
    # custom URI scheme does not resolve protocol-relative CDN URLs to `tauri://`.
    asset_opts =
      if get_req_header(conn, "authorization") == [], do: [], else: [static_base: ""]

    IO.iodata_to_binary([
      ~s(<meta name="color-scheme" content="light dark">),
      Assets.applet_frame_tags(asset_opts),
      "<script>parent.__ANKOLE_APPLET_HOST__.prepare(window)</script>"
    ])
  end

  defp shell(html, tags) do
    if Regex.match?(~r/<head\b[^>]*>/i, html),
      do: Regex.replace(~r/<head\b[^>]*>/i, html, "\\0" <> tags, global: false),
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
