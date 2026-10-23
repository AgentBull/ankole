defmodule AnkoleWeb.JSONAPI.SiteAIGatewayProvidersTest do
  @moduledoc "Checks the AIGateway provider routes of the site JSON:API."
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AIGateway.ModelMetadata.Cache, as: ModelMetadataCache
  alias Ankole.AIGateway.ProviderConfigs
  alias Ankole.AIGateway.ProviderConfigs.Provider
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo

  @media_type "application/vnd.api+json"

  setup do
    Registry.clear_for_test()
    Cache.clear_for_test()
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
                 %{"label" => "Primary key", "credential_present" => true, "status" => "ok"}
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
end
