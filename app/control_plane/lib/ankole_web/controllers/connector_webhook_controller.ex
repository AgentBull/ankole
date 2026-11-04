defmodule AnkoleWeb.ConnectorWebhookController do
  use AnkoleWeb, :controller
  alias AnkoleWeb.Plugs.ProviderWebhookBodyReader

  def auth(conn, %{"tenant_id" => tenant, "auth_config_id" => id}),
    do: receive_event(conn, tenant, :auth, id)

  def trigger(conn, %{"tenant_id" => tenant, "trigger_id" => id}),
    do: receive_event(conn, tenant, :trigger, id)

  defp receive_event(conn, tenant, kind, id) do
    with {:ok, tenant} <- Ecto.UUID.cast(tenant),
         {:ok, record} <- Ankole.Tenants.get(tenant),
         true <- Ankole.Tenants.accepting_work?(record) do
      Ankole.Repo.with_tenant(tenant, fn ->
        case Ankole.Connectors.Ingress.receive_event(
               kind,
               id,
               ProviderWebhookBodyReader.body(conn),
               conn.req_headers
             ) do
          {:ok, response} ->
            json(conn, response)

          {:error, :invalid_webhook_signature} ->
            send_resp(conn, 401, "invalid_signature")

          {:error, reason} when reason in [:connection_disabled, :connector_trigger_inactive] ->
            send_resp(conn, 410, Atom.to_string(reason))

          {:error, :not_found} ->
            send_resp(conn, 404, "not_found")

          {:error, _} ->
            send_resp(conn, 503, "event_not_accepted")
        end
      end)
    else
      false -> send_resp(conn, 410, "tenant_not_accepting_work")
      _ -> send_resp(conn, 404, "not_found")
    end
  end
end
