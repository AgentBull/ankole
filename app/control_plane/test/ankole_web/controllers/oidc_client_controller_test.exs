defmodule AnkoleWeb.OIDCClientControllerTest do
  use AnkoleWeb.ConnCase, async: false

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AuthZ
  alias Ankole.OIDC

  test "admin creates, reads, updates, rotates, and deletes OIDC Clients", %{conn: conn} do
    conn = bearer_conn(conn)

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "oidc-users-#{System.unique_integer([:positive])}",
        display_name: "OIDC Users",
        kind: "static"
      })

    provider_id = create_provider!("oidc-console")
    aliases = %{"assistant" => model_alias(provider_id)}

    create =
      conn
      |> post("/api/v1/oidc-clients", %{
        "name" => "Console-managed Client",
        "enabled" => true,
        "type" => "confidential",
        "redirect_uris" => ["https://client.example.test/callback"],
        "scopes" => ["openid", "profile", "ai_gateway.write"],
        "allowed_group_ids" => [group.id],
        "allowed_models" => aliases
      })

    assert %{
             "oidc_client" => %{
               "id" => client_id,
               "type" => "confidential",
               "allowed_group_ids" => [group_id],
               "allowed_models" => ^aliases,
               "inserted_at" => inserted_at,
               "updated_at" => updated_at
             },
             "client_secret" => initial_secret
           } = json_response(create, 201)

    assert group_id == group.id
    assert is_binary(initial_secret)
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(inserted_at)
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(updated_at)
    assert get_resp_header(create, "cache-control") == ["no-store"]

    show = conn |> recycle_api() |> get("/api/v1/oidc-clients/#{client_id}")
    refute Map.has_key?(json_response(show, 200)["oidc_client"], "client_secret")

    listing = conn |> recycle_api() |> get("/api/v1/oidc-clients") |> json_response(200)
    assert Enum.any?(listing["oidc_clients"], &(&1["id"] == client_id))
    refute Enum.any?(listing["oidc_clients"], &Map.has_key?(&1, "client_secret"))

    update =
      conn
      |> recycle_api()
      |> patch("/api/v1/oidc-clients/#{client_id}", %{
        "name" => "OIDC without Gateway",
        "scopes" => ["openid", "email"],
        "allowed_group_ids" => [group.id],
        "allowed_models" => aliases
      })

    assert %{
             "oidc_client" => %{
               "name" => "OIDC without Gateway",
               "scopes" => ["openid", "email"],
               "allowed_group_ids" => [],
               "allowed_models" => %{}
             }
           } = json_response(update, 200)

    rotate_conn =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients/#{client_id}/secret-rotations", %{})

    rotate = json_response(rotate_conn, 200)

    assert is_binary(rotate["client_secret"])
    assert rotate["client_secret"] != initial_secret
    assert get_resp_header(rotate_conn, "cache-control") == ["no-store"]

    deleted =
      conn
      |> recycle_api()
      |> delete("/api/v1/oidc-clients/#{client_id}")
      |> json_response(200)

    assert deleted["oidc_client"]["id"] == client_id
    assert {:error, :not_found} = OIDC.get_client(client_id)
  end

  test "public Client has no secret and cannot rotate one", %{conn: conn} do
    conn = bearer_conn(conn)

    create =
      conn
      |> post("/api/v1/oidc-clients", %{
        "name" => "Public Client",
        "enabled" => true,
        "type" => "public",
        "redirect_uris" => ["http://LOCALHOST:5173/callback"],
        "scopes" => ["openid"],
        "allowed_group_ids" => [],
        "allowed_models" => %{}
      })
      |> json_response(201)

    assert create["client_secret"] == nil
    client_id = create["oidc_client"]["id"]
    assert OIDC.origin_allowed?(client_id, "http://localhost:5173")

    rotate =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients/#{client_id}/secret-rotations", %{})

    assert %{"error" => %{"code" => "public_client"}} = json_response(rotate, 409)
  end

  test "Client validation rejects unsafe redirects and incomplete Gateway policy", %{conn: conn} do
    conn = bearer_conn(conn)

    unsafe_redirect =
      conn
      |> post("/api/v1/oidc-clients", %{
        "name" => "Unsafe Client",
        "enabled" => true,
        "type" => "public",
        "redirect_uris" => ["javascript:alert(1)"],
        "scopes" => ["openid"],
        "allowed_group_ids" => [],
        "allowed_models" => %{}
      })

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(unsafe_redirect, 422)

    incomplete_gateway =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients", %{
        "name" => "Incomplete Gateway Client",
        "enabled" => true,
        "type" => "public",
        "redirect_uris" => ["https://client.example.test/callback"],
        "scopes" => ["openid", "ai_gateway.write"],
        "allowed_group_ids" => [],
        "allowed_models" => %{}
      })

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(incomplete_gateway, 422)

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "oidc-alias-users-#{System.unique_integer([:positive])}",
        display_name: "OIDC Alias Users",
        kind: "static"
      })

    provider_id = create_provider!("oidc-alias-validation")

    raw_selector =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients", %{
        "name" => "Raw selector Client",
        "enabled" => true,
        "type" => "public",
        "redirect_uris" => ["https://client.example.test/callback"],
        "scopes" => ["openid", "ai_gateway.write"],
        "allowed_group_ids" => [group.id],
        "allowed_models" => ["#{provider_id}/gpt-4o-mini"]
      })

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(raw_selector, 422)

    fixed_alias =
      conn
      |> recycle_api()
      |> post("/api/v1/oidc-clients", %{
        "name" => "Fixed alias Client",
        "enabled" => true,
        "type" => "public",
        "redirect_uris" => ["https://client.example.test/callback"],
        "scopes" => ["openid", "ai_gateway.write"],
        "allowed_group_ids" => [group.id],
        "allowed_models" => %{"primary" => model_alias(provider_id)}
      })

    assert %{"error" => %{"code" => "validation_failed"}} =
             json_response(fixed_alias, 422)
  end

  defp create_provider!(prefix) do
    provider_id = "#{prefix}-#{System.unique_integer([:positive])}"

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    provider_id
  end

  defp model_alias(provider_id) do
    %{
      "provider_id" => provider_id,
      "model" => "gpt-4o-mini",
      "description" => "Client assistant model",
      "provider_options" => %{}
    }
  end
end
