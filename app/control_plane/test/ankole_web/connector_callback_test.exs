defmodule AnkoleWeb.ConnectorCallbackTest do
  use AnkoleWeb.ConnCase, async: false
  import Ankole.PrincipalsFixtures

  setup do
    Ankole.AppConfigure.Registry.clear_for_test()
    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    principal = human_fixture().principal
    {:ok, _} = Ankole.Repo.transact(fn -> Ankole.AuthZ.add_pod_admin_in_tx(principal.uid) end)

    {:ok, config} =
      Ankole.Connectors.Store.create_auth_config(principal, %{
        "plugin_id" => "github",
        "slug" => "callback",
        "auth_scheme" => "oauth2",
        "secret" => %{"clientID" => "callback-client", "clientSecret" => "callback-secret"}
      })

    %{principal: principal, config: config}
  end

  test "cancelled OAuth returns to the original query and fragment through Endpoint", ctx do
    {:ok, %{authorization_url: url}} =
      Ankole.Connectors.OAuth.begin(ctx.principal, %{
        "connection" => ctx.config.slug,
        "return_to" => "/connectors?connection=callback#personal"
      })

    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    conn = get(ctx.conn, "/oauth/connectors/callback", %{state: state, error: "access_denied"})
    location = conn |> redirected_to() |> URI.parse()
    assert location.path == "/connectors"
    assert location.fragment == "personal"

    assert URI.decode_query(location.query) == %{
             "connection" => "callback",
             "connector_error" => "oauth_authorization_cancelled"
           }
  end

  test "unknown and suspended tenants reject provider delivery without retryable errors", ctx do
    missing = Ash.UUIDv7.generate()

    assert ctx.conn
           |> post("/webhooks/connectors/#{missing}/auth/#{ctx.config.id}")
           |> response(404) == "not_found"

    {:ok, tenant} = Ankole.Tenants.get(ctx.config.tenant_id)
    {:ok, _} = Ankole.Tenants.suspend(tenant)

    assert ctx.conn
           |> post("/webhooks/connectors/#{tenant.id}/auth/#{ctx.config.id}")
           |> response(410) == "tenant_not_accepting_work"
  end
end
