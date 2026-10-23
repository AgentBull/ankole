defmodule AnkoleWeb.OIDCClientControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.OIDC

  defmodule SiteSource do
    @behaviour Ankole.IdentityProviders.SiteSources
    def authenticate(_), do: {:error, :invalid_authentication}
    def login_path, do: "/test/site-login"
    def display_name, do: "Test site source"
    def fresh_authentication?, do: false
  end

  test "the Client catalog and allowlist share the reserved site source authority", %{conn: conn} do
    previous = Application.get_env(:ankole, :site_identity_sources, [])
    Application.put_env(:ankole, :site_identity_sources, [{"test-site", SiteSource}])
    on_exit(fn -> Application.put_env(:ankole, :site_identity_sources, previous) end)
    conn = console_conn(conn)

    catalog =
      conn |> recycle_api() |> get("/api/v1/oidc-clients/login-sources") |> json_response(200)

    assert %{"provider_id" => "test-site", "enabled" => true} in catalog["sources"]

    {:ok, %{client: %{id: id}}} =
      OIDC.create_client(%{
        "name" => "Site source client",
        "enabled" => true,
        "type" => "public",
        "redirect_uris" => ["https://client.example.test/callback"],
        "scopes" => ["openid"],
        "allowed_identity_provider_ids" => ["test-site"],
        "allowed_group_ids" => [],
        "allowed_models" => %{}
      })

    {:ok, client} = OIDC.get_active_client(id)
    assert :ok = Ankole.OIDC.LoginPolicy.authorize_source(client, "test-site")

    assert {:error, :identity_provider_not_allowed} =
             Ankole.OIDC.LoginPolicy.authorize_source(
               %{client | allowed_identity_provider_ids: ["other"]},
               "test-site"
             )

    assert {:error, :reserved_identity_provider_id} =
             Ankole.IdentityProviders.save_provider("test-site", "local", %{}, true)
  end

  test "admin rotates a confidential Client secret, and a public Client has none", %{
    conn: conn
  } do
    conn = console_conn(conn)

    attrs = %{
      "name" => "Console-managed Client",
      "enabled" => true,
      "redirect_uris" => ["https://client.example.test/callback"],
      "scopes" => ["openid"]
    }

    {:ok, %{client: client, client_secret: initial_secret}} =
      OIDC.create_client(Map.put(attrs, "type", "confidential"))

    rotate_conn =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients/#{client.id}/secret-rotations", %{})

    rotate = json_response(rotate_conn, 200)

    assert rotate["oidc_client"]["id"] == client.id
    assert is_binary(rotate["client_secret"])
    assert rotate["client_secret"] != initial_secret
    assert get_resp_header(rotate_conn, "cache-control") == ["no-store"]

    {:ok, %{client: public, client_secret: nil}} =
      OIDC.create_client(Map.put(attrs, "type", "public"))

    rotate =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients/#{public.id}/secret-rotations", %{})

    assert %{"error" => %{"code" => "public_client"}} = json_response(rotate, 409)
  end
end
