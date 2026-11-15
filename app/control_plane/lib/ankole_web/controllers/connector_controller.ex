defmodule AnkoleWeb.ConnectorController do
  use AnkoleWeb, :controller
  alias Ankole.Connectors.OAuth
  import AnkoleWeb.PodResponse, only: [respond: 2]

  def callback(conn, params) do
    case OAuth.callback(params) do
      {:ok, %{return_to: return_to, tenant_id: tenant_id} = result} ->
        query =
          case result do
            %{completion_code: code} -> %{"connector_completion" => code}
            %{error: error} -> %{"connector_error" => error}
          end

        {desktop?, path, pod_origin, target} =
          Ankole.Repo.with_tenant(tenant_id, fn ->
            uri = URI.parse(return_to || "/connectors")
            decoded = uri.query |> to_string() |> URI.decode_query()
            desktop? = decoded["desktop"] == "1"
            merged = decoded |> Map.delete("desktop") |> Map.merge(query)
            encoded = URI.encode_query(merged)
            path = URI.to_string(%{uri | query: if(encoded == "", do: nil, else: encoded)})

            {:ok, tenant} = Ankole.Tenants.get(tenant_id)
            pod_origin = AnkoleWeb.PodURL.origin(conn, tenant)
            {desktop?, path, pod_origin, AnkoleWeb.PodURL.current_tenant_url(path)}
          end)

        if desktop? do
          render_desktop_return(conn, path, pod_origin, tenant_id, Map.get(result, :actor_uid))
        else
          redirect(conn, external: target)
        end

      {:error, reason} ->
        respond(conn, {:error, reason})
    end
  end

  defp render_desktop_return(conn, href, pod_origin, tenant_id, actor_uid) do
    deep_link_params =
      %{
        "href" => href,
        "pod_origin" => pod_origin,
        "tenant_id" => tenant_id,
        "principal_uid" => actor_uid
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) or value == "" end)
      |> URI.encode_query()

    deep_link = "ankole://open?" <> deep_link_params
    escaped_href = Phoenix.HTML.html_escape(deep_link) |> Phoenix.HTML.safe_to_string()
    js_url = Ankole.JSON.encode!(deep_link) |> String.replace("</", "<\\/")
    nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)

    body = """
    <!doctype html>
    <html lang="en">
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>Return to Ankole Desktop</title>
        <style>
          body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; margin: 0; min-height: 100vh; display: grid; place-items: center; background: #fafafa; color: #111827; }
          main { max-width: 26rem; padding: 2rem; text-align: center; }
          h1 { font-size: 1.125rem; font-weight: 600; margin: 0 0 0.5rem; }
          p { font-size: 0.875rem; line-height: 1.5; color: #4b5563; margin: 0 0 1.25rem; }
          a { display: inline-block; padding: 0.5rem 1rem; border-radius: 0.5rem; background: #111827; color: #ffffff; text-decoration: none; font-size: 0.875rem; font-weight: 500; }
        </style>
      </head>
      <body>
        <main>
          <h1>Returning to Ankole Desktop</h1>
          <p>You can close this browser tab once Ankole Desktop opens.</p>
          <a href="#{escaped_href}">Open Ankole Desktop</a>
        </main>
        <script nonce="#{nonce}">window.location.replace(#{js_url});</script>
      </body>
    </html>
    """

    conn
    |> put_resp_header("cache-control", "private, no-store")
    |> put_resp_header(
      "content-security-policy",
      "default-src 'none'; style-src 'unsafe-inline'; script-src 'nonce-#{nonce}'"
    )
    |> put_resp_content_type("text/html")
    |> send_resp(200, body)
  end
end
