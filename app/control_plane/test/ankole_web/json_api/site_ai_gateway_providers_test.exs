defmodule AnkoleWeb.JSONAPI.SiteAIGatewayProvidersTest do
  @moduledoc "Checks the AIGateway provider routes of the site JSON:API."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.AuthZ.Actor
  alias Ankole.Repo
  alias AnkoleWeb.JSONAPI.SiteRouter

  @media_type "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    ModelMetadataCache.clear_for_test()
    :ok
  end

  defp send_v2(conn, method, path, body \\ nil) do
    conn
    |> recycle_api()
    |> put_req_header("accept", @media_type)
    |> put_req_header("content-type", @media_type)
    |> dispatch(@endpoint, method, path, body && Jason.encode!(body))
  end

  defp put_provider(conn, provider_id, attributes),
    do:
      send_v2(conn, :patch, "/api/v2/site/ai-gateway/providers/#{provider_id}", %{
        data: %{type: "ai_gateway_provider", attributes: attributes}
      })

  defp attributes(%{"data" => %{"attributes" => attributes}}), do: attributes

  defp provider_ids(conn) do
    conn
    |> send_v2(:get, "/api/v2/site/ai-gateway/providers")
    |> json_response(200)
    |> Map.fetch!("data")
    |> Enum.map(& &1["attributes"]["provider_id"])
  end

  test "admin configures a provider row and an Agent model profile refers to it", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    response =
      put_provider(conn, "openrouter-main", %{
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Primary key", "api_key" => "sk-test"}]}
      })

    refute response.resp_body =~ "sk-test"

    # The path names the provider; the body cannot name another one.
    drift =
      put_provider(conn, "openrouter-main", %{provider_id: "other", provider_kind: "openrouter"})

    assert %{"errors" => [%{"code" => "invalid_body"}]} = json_response(drift, 400)

    assert %{"data" => %{"type" => "ai_gateway_provider", "id" => id}} =
             body = json_response(response, 200)

    assert id == Repo.get_by!(Provider, provider_id: "openrouter-main").id

    assert %{
             "provider_id" => "openrouter-main",
             "provider_kind" => "openrouter",
             "disabled_at" => nil,
             "provider_metadata" => %{"settings" => [_ | _]},
             "credential_pool" => %{
               "strategy" => "fill_first",
               "entries" => [
                 %{
                   "label" => "Primary key",
                   "credential_present" => true,
                   "present_fields" => ["api_key"],
                   "status" => "ok"
                 }
               ]
             }
           } = attributes(body)

    assert "openrouter-main" in provider_ids(conn)

    shown =
      conn
      |> send_v2(:get, "/api/v2/site/ai-gateway/providers/openrouter-main")
      |> json_response(200)

    assert attributes(shown) == attributes(body)

    missing = conn |> send_v2(:get, "/api/v2/site/ai-gateway/providers/missing-provider")
    assert %{"errors" => [%{"code" => "not_found"}]} = json_response(missing, 404)

    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent.uid, "primary", %{
               provider_id: "openrouter-main",
               model: "z-ai/glm-5.2"
             })

    response =
      conn
      |> send_v2(:delete, "/api/v2/site/ai-gateway/providers/openrouter-main")
      |> json_response(422)

    assert [%{"code" => "provider_in_use", "meta" => %{"details" => [%{"references" => [_]}]}}] =
             response["errors"]
  end

  test "admin enables only a valid disabled provider", %{conn: conn} do
    conn = console_conn(conn)

    assert {:ok, _provider} =
             ProviderConfigs.create_provider(%{
               provider_id: "enable-route",
               provider_kind: "openrouter",
               credential_pool: %{"entries" => []}
             })

    assert {:ok, %{disabled_at: %DateTime{}}} = ProviderConfigs.delete_provider("enable-route")

    enabled =
      conn
      |> send_v2(:post, "/api/v2/site/ai-gateway/providers/enable-route/enable")
      |> json_response(201)

    assert %{"provider_id" => "enable-route", "disabled_at" => nil} = attributes(enabled)

    missing =
      conn
      |> send_v2(:post, "/api/v2/site/ai-gateway/providers/missing-provider/enable")
      |> json_response(404)

    assert %{"errors" => [%{"code" => "not_found"}]} = missing

    Repo.get_by!(Provider, provider_id: "enable-route")
    |> Ecto.Changeset.change(
      provider_kind: "retired_kind",
      disabled_at: DateTime.utc_now(:microsecond)
    )
    |> Repo.update!()

    invalid =
      conn
      |> send_v2(:post, "/api/v2/site/ai-gateway/providers/enable-route/enable")
      |> json_response(422)

    assert [
             %{
               "code" => "unknown_ai_gateway_provider",
               "detail" =>
                 "AIGateway provider configuration is invalid: the provider kind is unknown"
             }
           ] = invalid["errors"]
  end

  test "admin disables an active provider and deletes it on the next request", %{conn: conn} do
    conn = console_conn(conn)

    created =
      put_provider(conn, "openrouter-unused", %{
        provider_kind: "openrouter",
        credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
      })

    assert %{"disabled_at" => nil} = created |> json_response(200) |> attributes()

    disabled =
      conn
      |> send_v2(:delete, "/api/v2/site/ai-gateway/providers/openrouter-unused")
      |> json_response(200)

    assert %{"disabled_at" => disabled_at} = attributes(disabled)
    assert is_binary(disabled_at)

    deleted =
      conn
      |> send_v2(:delete, "/api/v2/site/ai-gateway/providers/openrouter-unused")
      |> json_response(200)

    assert %{"provider_id" => "openrouter-unused"} = attributes(deleted)
    refute "openrouter-unused" in provider_ids(conn)
  end

  test "operator projects present secret fields and decrypts credentials only with decrypt permission",
       %{conn: conn, tenant: tenant} do
    conn = console_conn(conn)

    openrouter =
      put_provider(conn, "openrouter-decrypt", %{
        provider_kind: "openrouter",
        credential_pool: %{
          "entries" => [
            %{"id" => "primary", "label" => "Primary key", "api_key" => "sk-openrouter-secret"}
          ]
        }
      })

    refute openrouter.resp_body =~ "sk-openrouter-secret"

    mimo =
      put_provider(conn, "mimo-decrypt", %{
        provider_kind: "xiaomi_mimo",
        credential_pool: %{
          "entries" => [
            %{
              "id" => "dual",
              "label" => "Dual",
              "api_key" => "mimo-key",
              "access_token" => "mimo-token"
            },
            %{"id" => "key-only", "label" => "Key only", "api_key" => "mimo-only-key"}
          ]
        }
      })
      |> json_response(200)
      |> attributes()

    assert [
             %{"id" => "dual", "present_fields" => ["access_token", "api_key"]},
             %{"id" => "key-only", "present_fields" => ["api_key"]}
           ] = mimo["credential_pool"]["entries"]

    compat =
      put_provider(conn, "compat-default", %{
        provider_kind: "openai_compatible",
        base_url: "https://llm.example.test/v1"
      })
      |> json_response(200)
      |> attributes()

    assert [
             %{
               "source" => "provider_default",
               "credential_present" => true,
               "present_fields" => []
             }
           ] = compat["credential_pool"]["entries"]

    assert %{"data" => %{"type" => "ai_gateway_provider"}} =
             put_provider(conn, "chatgpt-enterprise", %{
               provider_kind: "chatgpt_subscription",
               credential_pool: %{"entries" => []}
             })
             |> json_response(200)

    enterprise =
      conn
      |> send_v2(
        :post,
        "/api/v2/site/ai-gateway/providers/chatgpt-enterprise/chatgpt-enterprise-credentials",
        %{
          data: %{
            credential: %{
              id: "ent-1",
              label: "Enterprise",
              access_token: "Bearer ent-secret-token",
              account_id: "acct_123",
              email: "ops@example.test"
            }
          }
        }
      )
      |> json_response(201)

    refute Jason.encode!(enterprise) =~ "ent-secret-token"

    assert [
             %{
               "id" => "ent-1",
               "auth_type" => "enterprise_access_token",
               "present_fields" => ["access_token", "account_id", "auth_type", "email"]
             }
           ] = enterprise["ai_gateway_provider"]["credential_pool"]["entries"]

    assert %{
             "decrypted_credential" => %{
               "provider_id" => "openrouter-decrypt",
               "credential_id" => "primary",
               "values" => %{"api_key" => "sk-openrouter-secret"}
             }
           } =
             conn
             |> send_v2(
               :post,
               "/api/v2/site/ai-gateway/providers/openrouter-decrypt/credentials/primary/decryptions"
             )
             |> json_response(201)

    assert %{
             "decrypted_credential" => %{
               "provider_id" => "mimo-decrypt",
               "credential_id" => "dual",
               "values" => %{"api_key" => "mimo-key", "access_token" => "mimo-token"}
             }
           } =
             conn
             |> send_v2(
               :post,
               "/api/v2/site/ai-gateway/providers/mimo-decrypt/credentials/dual/decryptions"
             )
             |> json_response(201)

    assert %{
             "decrypted_credential" => %{
               "provider_id" => "chatgpt-enterprise",
               "credential_id" => "ent-1",
               "values" => %{
                 "access_token" => "ent-secret-token",
                 "account_id" => "acct_123",
                 "auth_type" => "enterprise_access_token",
                 "email" => "ops@example.test"
               }
             }
           } =
             conn
             |> send_v2(
               :post,
               "/api/v2/site/ai-gateway/providers/chatgpt-enterprise/credentials/ent-1/decryptions"
             )
             |> json_response(201)

    assert {:ok, %{disabled_at: %DateTime{}}} =
             ProviderConfigs.delete_provider("openrouter-decrypt")

    assert %{
             "decrypted_credential" => %{
               "values" => %{"api_key" => "sk-openrouter-secret"}
             }
           } =
             conn
             |> send_v2(
               :post,
               "/api/v2/site/ai-gateway/providers/openrouter-decrypt/credentials/primary/decryptions"
             )
             |> json_response(201)

    for path <- [
          "/api/v2/site/ai-gateway/providers/missing-provider/credentials/primary/decryptions",
          "/api/v2/site/ai-gateway/providers/openrouter-decrypt/credentials/missing-key/decryptions"
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> send_v2(:post, path) |> json_response(404)
    end

    :ok = Ankole.DataCase.set_privileged_tenant(tenant)
    reader_editor = human_fixture(%{uid: unique_uid("provider-editor")}).principal
    actor = Actor.new(reader_editor)

    for action <- ["read", "update"] do
      assert {:ok, _grant} =
               AuthZ.create_permission_grant(%{
                 principal_uid: reader_editor.uid,
                 resource_pattern: "site_console:ai_gateway_provider:*",
                 action: action
               })
    end

    read_response =
      Plug.Test.conn(:get, "/ai-gateway/providers/openrouter-decrypt")
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", @media_type)
      |> assign(:authz_actor, actor)
      |> SiteRouter.call(SiteRouter.init([]))

    assert read_response.status == 200

    denied_decrypt =
      Plug.Test.conn(
        :post,
        "/ai-gateway/providers/openrouter-decrypt/credentials/primary/decryptions"
      )
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", @media_type)
      |> put_req_header("content-type", @media_type)
      |> assign(:authz_actor, actor)
      |> SiteRouter.call(SiteRouter.init([]))

    assert denied_decrypt.status == 403

    assert {:ok, _grant} =
             AuthZ.create_permission_grant(%{
               principal_uid: reader_editor.uid,
               resource_pattern: "site_console:ai_gateway_provider:openrouter-decrypt",
               action: "decrypt"
             })

    allowed_decrypt =
      Plug.Test.conn(
        :post,
        "/ai-gateway/providers/openrouter-decrypt/credentials/primary/decryptions"
      )
      |> Plug.Test.init_test_session(%{})
      |> put_req_header("accept", @media_type)
      |> put_req_header("content-type", @media_type)
      |> assign(:authz_actor, actor)
      |> SiteRouter.call(SiteRouter.init([]))

    assert allowed_decrypt.status == 201

    assert %{
             "decrypted_credential" => %{
               "values" => %{"api_key" => "sk-openrouter-secret"}
             }
           } = Jason.decode!(allowed_decrypt.resp_body)

    row = Repo.get_by!(Provider, provider_id: "mimo-decrypt")

    broken_entries =
      Enum.map(row.credential_pool["entries"], fn entry ->
        if entry["id"] == "key-only",
          do: Map.put(entry, "encrypted_credential", "corrupted-ciphertext"),
          else: entry
      end)

    row
    |> Ecto.Changeset.change(
      credential_pool: Map.put(row.credential_pool, "entries", broken_entries)
    )
    |> Repo.update!()

    projected =
      conn
      |> send_v2(:get, "/api/v2/site/ai-gateway/providers/mimo-decrypt")
      |> json_response(200)
      |> attributes()

    assert Enum.find(projected["credential_pool"]["entries"], &(&1["id"] == "key-only"))
           |> Map.take(["reauth_required", "present_fields"]) == %{
             "reauth_required" => true,
             "present_fields" => []
           }

    assert %{"errors" => [%{"code" => "credential_decrypt_failed"}]} =
             conn
             |> send_v2(
               :post,
               "/api/v2/site/ai-gateway/providers/mimo-decrypt/credentials/key-only/decryptions"
             )
             |> json_response(422)
  end
end
