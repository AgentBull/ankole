defmodule AnkoleWeb.JSONAPI.OIDCClientsTest do
  @moduledoc "Checks the OIDC Client and Back-Channel Logout delivery routes of `/api/v2`."
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query

  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Grant
  alias Ankole.OIDC
  alias Ankole.Repo

  @json_api "application/vnd.api+json"

  test "admin creates, reads, updates, and deletes OIDC Clients", %{conn: conn} do
    conn = console_conn(conn)

    {:ok, group} =
      AuthZ.create_principal_group(%{
        name: "oidc-users-#{System.unique_integer([:positive])}",
        display_name: "OIDC Users",
        kind: "static"
      })

    provider_id = create_provider!("oidc-console")
    aliases = %{"assistant" => model_alias(provider_id)}

    create =
      request(conn, :post, "/api/v2/oidc-clients", %{
        name: "Console-managed Client",
        enabled: true,
        client_type: "confidential",
        redirect_uris: ["https://client.example.test/callback"],
        scopes: ["openid", "profile", "ai_gateway.write"],
        allowed_group_ids: [group.id],
        model_aliases: aliases
      })

    assert %{
             "oidc_client" => %{
               "id" => client_id,
               "client_type" => "confidential",
               "allowed_group_ids" => [group_id],
               "model_aliases" => ^aliases,
               "inserted_at" => inserted_at
             },
             "client_secret" => initial_secret
           } = json_response(create, 201)

    assert group_id == group.id
    assert is_binary(initial_secret)
    assert {:ok, _datetime, 0} = DateTime.from_iso8601(inserted_at)
    assert get_resp_header(create, "cache-control") == ["private, no-store"]
    refute Map.has_key?(json_response(create, 201)["oidc_client"], "secret_ciphertext")

    show = conn |> request(:get, "/api/v2/oidc-clients/#{client_id}") |> json_response(200)

    assert %{"data" => %{"id" => ^client_id, "type" => "oidc_client", "attributes" => attributes}} =
             show

    assert attributes["allowed_group_ids"] == [group.id]
    refute inspect(show) =~ initial_secret
    refute Map.has_key?(attributes, "secret_ciphertext")

    listing = conn |> request(:get, "/api/v2/oidc-clients") |> json_response(200)
    assert Enum.any?(listing["data"], &(&1["id"] == client_id))
    refute inspect(listing) =~ initial_secret

    update =
      request(conn, :patch, "/api/v2/oidc-clients/#{client_id}", %{
        name: "OIDC without Gateway",
        scopes: ["openid", "email"],
        allowed_group_ids: [group.id],
        model_aliases: aliases
      })

    assert %{
             "id" => ^client_id,
             "name" => "OIDC without Gateway",
             "scopes" => ["openid", "email"],
             "allowed_group_ids" => [],
             "model_aliases" => %{}
           } = json_response(update, 200)

    deleted = conn |> request(:delete, "/api/v2/oidc-clients/#{client_id}") |> json_response(200)

    assert deleted["id"] == client_id
    assert {:error, :not_found} = OIDC.get_client(client_id)

    for {method, path, data} <- [
          {:get, "/api/v2/oidc-clients/#{client_id}", nil},
          {:patch, "/api/v2/oidc-clients/#{client_id}", %{name: "Gone"}},
          {:delete, "/api/v2/oidc-clients/#{client_id}", nil}
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> request(method, path, data) |> json_response(404)
    end
  end

  test "a public Client has no secret, and validation rejects unsafe input", %{conn: conn} do
    conn = console_conn(conn)

    created =
      conn
      |> request(:post, "/api/v2/oidc-clients", %{
        name: "Public Client",
        client_type: "public",
        redirect_uris: ["http://LOCALHOST:5173/callback"],
        scopes: ["openid"]
      })
      |> json_response(201)

    assert created["client_secret"] == nil
    assert OIDC.origin_allowed?(created["oidc_client"]["id"], "http://localhost:5173")

    assert %{"errors" => [_ | _]} =
             conn
             |> request(:post, "/api/v2/oidc-clients", %{
               name: "Unsafe Client",
               client_type: "public",
               redirect_uris: ["javascript:alert(1)"],
               scopes: ["openid"]
             })
             |> json_response(400)

    assert %{"errors" => [%{"code" => "allowed_group_required"}]} =
             conn
             |> request(:post, "/api/v2/oidc-clients", %{
               name: "Incomplete Gateway Client",
               client_type: "public",
               redirect_uris: ["https://client.example.test/callback"],
               scopes: ["openid", "ai_gateway.write"],
               allowed_group_ids: [],
               model_aliases: %{}
             })
             |> json_response(422)
  end

  test "a Console route needs the AuthZ grant of its rule", %{conn: conn} do
    {conn, admin_uid} = console_conn_with_principal(conn)

    {:ok, %{client: client}} =
      OIDC.create_client(%{
        name: "Granted Client",
        type: "public",
        enabled: true,
        redirect_uris: ["https://client.example.test/callback"],
        scopes: ["openid"]
      })

    Repo.delete_all(
      from grant in Grant,
        where: grant.resource_pattern == "**" or grant.principal_uid == ^admin_uid
    )

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn |> request(:get, "/api/v2/oidc-clients/#{client.id}") |> json_response(403)

    assert %{"errors" => [%{"code" => "forbidden"}]} =
             conn
             |> request(:delete, "/api/v2/oidc-clients/#{client.id}")
             |> json_response(403)

    assert {:ok, _client} = OIDC.get_client(client.id)

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: admin_uid,
               resource_pattern: "oidc_client:#{client.id}",
               action: "read",
               condition: "true",
               metadata: %{}
             })

    assert conn |> request(:get, "/api/v2/oidc-clients/#{client.id}") |> json_response(200)
  end

  test "logout delivery routes list and retry the deliveries of one Client", %{conn: conn} do
    Ankole.AppConfigure.Registry.clear_for_test()
    Ankole.AppConfigure.Cache.clear_for_test()
    conn = console_conn(conn)
    %{principal: human} = Ankole.PrincipalsFixtures.human_fixture()

    attrs = %{
      name: "Logout controls",
      type: "confidential",
      enabled: true,
      redirect_uris: ["https://client.example.test/callback"],
      scopes: ["openid"],
      backchannel_logout_uri: "https://client.example.test/logout"
    }

    {:ok, %{client: client}} = OIDC.create_client(attrs)
    {:ok, %{client: other}} = OIDC.create_client(attrs)
    {:ok, session} = Ankole.OIDCFixtures.session(human.uid, client.id, "openid")

    {:ok, _} =
      Ankole.Principals.HumanAccess.restrict_from_provider(
        human.uid,
        "test",
        "departure",
        "logout-controls"
      )

    list =
      conn
      |> request(:get, "/api/v2/oidc-clients/#{client.id}/logout-deliveries")
      |> json_response(200)

    assert [%{"id" => id, "attributes" => attributes}] = list["data"]
    assert %{"session_id" => sid, "status" => "pending", "principal_uid" => uid} = attributes
    assert sid == session.id
    assert uid == human.uid
    refute Map.has_key?(attributes, "endpoint")

    assert %{"data" => []} =
             conn
             |> request(:get, "/api/v2/oidc-clients/#{other.id}/logout-deliveries")
             |> json_response(200)

    assert %{"errors" => [%{"code" => "not_found"}]} =
             conn
             |> request(:post, "/api/v2/oidc-clients/#{other.id}/logout-deliveries/#{id}/retries")
             |> json_response(404)

    assert {:ok, _} =
             Repo.transact(fn _repo ->
               Ankole.Ash.update(Repo.get!(Ankole.OIDC.LogoutDelivery, id), :exhaust_in_tx, %{})
             end)

    assert %{"id" => ^id, "status" => "pending", "principal_uid" => ^uid} =
             conn
             |> request(
               :post,
               "/api/v2/oidc-clients/#{client.id}/logout-deliveries/#{id}/retries"
             )
             |> json_response(201)
  end

  defp request(conn, method, path, data \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @json_api)
    |> put_req_header("content-type", @json_api)
    |> dispatch(@endpoint, method, path, if(data, do: Jason.encode!(%{data: data}), else: ""))
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
