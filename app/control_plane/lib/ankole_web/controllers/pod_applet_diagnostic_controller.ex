defmodule AnkoleWeb.PodAppletDiagnosticController do
  @moduledoc "A ticket-authenticated Applet shell and its read-only Pod transport."
  use AnkoleWeb, :controller
  alias Ankole.Pod.Applets
  alias AnkoleWeb.PodResponse

  def show(conn, %{"ticket" => ticket} = params) do
    with {:ok, diagnostic} <- Applets.Diagnostics.authenticate(ticket) do
      conn =
        conn
        |> assign(:authz_actor, diagnostic.actor)
        |> put_resp_header("cache-control", "no-store")
        |> put_resp_header("referrer-policy", "no-referrer")

      dispatch(conn, Map.get(params, "path", []), diagnostic, ticket)
    else
      {:error, reason} -> PodResponse.error(conn, reason)
    end
  end

  defp dispatch(%{method: "GET"} = conn, [], diagnostic, ticket) do
    with {:ok, snapshot} <- Applets.Diagnostics.snapshot(diagnostic) do
      config = %{
        page: snapshot.page,
        bindings: snapshot.bindings,
        bindings_digest: snapshot.bindings_digest,
        revision: diagnostic.target_ref,
        principal: %{uid: diagnostic.actor.principal.uid},
        prefix: "/pod/applet-diagnostic/" <> ticket
      }

      encoded = config |> JSON.encode!() |> String.replace("<", "\\u003c")
      tags = AnkoleWeb.Assets.entry_tags(conn, "applet-diagnostic")

      title =
        Phoenix.HTML.html_escape(snapshot.page.title || "Applet") |> Phoenix.HTML.safe_to_string()

      conn
      |> put_secure_browser_headers(%{})
      |> put_resp_header("referrer-policy", "no-referrer")
      |> html(
        IO.iodata_to_binary([
          "<!doctype html><html lang=\"en\" data-theme=\"light\"><head><meta charset=\"utf-8\">",
          "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
          "<meta name=\"referrer\" content=\"no-referrer\"><title>",
          title,
          "</title>",
          tags,
          "</head><body style=\"margin:0\"><div id=\"applet-diagnostic\" style=\"min-height:100dvh\"></div>",
          "<script type=\"application/json\" id=\"applet-diagnostic-config\">",
          encoded,
          "</script></body></html>"
        ])
      )
    else
      {:error, reason} -> PodResponse.error(conn, reason)
    end
  end

  defp dispatch(%{method: "GET"} = conn, ["frame" | path], diagnostic, _ticket) do
    revision = diagnostic.target_ref |> to_string() |> String.replace_prefix("draft:", "draft-")

    AnkoleWeb.PodAppletFrameController.show(conn, %{
      "id" => diagnostic.page_id,
      "revision" => revision,
      "path" => path
    })
  end

  defp dispatch(
         %{method: "GET"} = conn,
         ["api", "pages", id, "routes" | _path],
         %{page_id: id} = diagnostic,
         _ticket
       ) do
    with {:ok, request} <- AnkoleWeb.PodAppletController.route_request(conn),
         {:ok, task} <-
           Applets.start(diagnostic.actor, id, request,
             revision: diagnostic.target_ref,
             read_only: true,
             diagnostic: true
           ) do
      case AnkoleWeb.AppletRequest.await(conn, task) do
        {conn, {:ok, %{"status" => 204}}} -> send_resp(conn, 204, "")
        {conn, {:ok, result}} -> conn |> put_status(result["status"]) |> json(result["body"])
        {conn, {:error, reason}} -> PodResponse.error(conn, reason)
      end
    else
      {:error, reason} -> PodResponse.error(conn, reason)
    end
  end

  defp dispatch(%{method: "GET"} = conn, ["api", "files", id | rest], _diagnostic, _ticket)
       when rest != [] do
    download_file(conn, id, Path.join(rest))
  end

  defp dispatch(%{method: "GET"} = conn, ["files", id | rest], _diagnostic, _ticket)
       when rest != [] do
    download_file(conn, id, Path.join(rest))
  end

  defp dispatch(
         %{method: "GET"} = conn,
         ["api", "pages", id, "files", "content"],
         _diagnostic,
         _ticket
       ) do
    conn = fetch_query_params(conn)
    AnkoleWeb.PodFileController.download(conn, Map.put(conn.query_params, "id", id))
  end

  defp dispatch(conn, ["api" | path], diagnostic, _ticket) do
    if read_request?(conn.method, path, diagnostic.page_id) do
      conn = fetch_query_params(conn)

      conn = %{
        conn
        | path_info: path,
          script_name: ["api", "v2", "pod"],
          path_params: %{},
          params: Map.merge(conn.query_params, conn.body_params)
      }

      AnkoleWeb.JSONAPI.PodRouter.call(conn, AnkoleWeb.JSONAPI.PodRouter.init([]))
    else
      readonly(conn)
    end
  end

  defp dispatch(conn, _path, _diagnostic, _ticket), do: readonly(conn)

  defp download_file(conn, id, relative_path) do
    conn = fetch_query_params(conn)

    params =
      conn.query_params
      |> Map.put("id", id)
      |> Map.put("path", relative_path)

    AnkoleWeb.PodFileController.download(conn, params)
  end

  defp read_request?("POST", ["tables", _id, operation], _page)
       when operation in ["query", "aggregate"],
       do: true

  defp read_request?("GET", ["tables", _id], _page), do: true
  defp read_request?("GET", ["pages", id | subpath], id), do: read_page_subpath?(subpath)
  defp read_request?("GET", ["subjects"], _page), do: true
  defp read_request?(_, _, _), do: false

  defp read_page_subpath?([]), do: true
  defp read_page_subpath?(["applet-bindings"]), do: true
  defp read_page_subpath?(["runs", _run_id]), do: true
  defp read_page_subpath?(["job-actions"]), do: true
  defp read_page_subpath?(["jobs"]), do: true

  defp read_page_subpath?(["jobs", _job_id, sub])
       when sub in ["runs", "schedules", "webhooks"],
       do: true

  defp read_page_subpath?(["jobs", _job_id, "schedules", _schedule_id, "runs"]), do: true
  defp read_page_subpath?(_), do: false

  defp readonly(conn),
    do:
      conn
      |> put_status(403)
      |> json(%{
        error: %{code: "diagnostic_read_only", message: "Applet diagnostics are read-only"}
      })
end
