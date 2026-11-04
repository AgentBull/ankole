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

        target =
          Ankole.Repo.with_tenant(tenant_id, fn ->
            uri = URI.parse(return_to || "/connectors")
            params = uri.query |> to_string() |> URI.decode_query() |> Map.merge(query)
            path = URI.to_string(%{uri | query: URI.encode_query(params)})
            AnkoleWeb.PodURL.current_tenant_url(path)
          end)

        redirect(conn, external: target)

      {:error, reason} ->
        respond(conn, {:error, reason})
    end
  end
end
