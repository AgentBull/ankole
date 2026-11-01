defmodule AnkoleWeb.JSONAPI.AgentModelsTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AIGateway.Schemas.UsageRecord
  alias Ankole.AppConfigure.Registry
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  setup do
    Registry.clear_for_test()

    {:ok, false} =
      Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), false)

    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin reads, sets, resets, and clears an agent token quota", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn = send_v2(conn, :get, ~p"/api/v2/agents/#{agent.uid}/token-quota")
    assert %{"token_quota" => nil, "usage" => nil} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/token-quota", %{
        "period_days" => 7,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000_000
      })

    assert %{
             "token_quota" => %{
               "period_days" => 7,
               "period_start_at" => "2026-09-09T00:00:00Z",
               "limit_tokens" => 1_000_000
             },
             "usage" => %{
               "window_started_at" => window_started_at,
               "window_ends_at" => window_ends_at,
               "used_tokens" => 0,
               "exceeded" => false
             }
           } = json_response(conn, 200)

    assert {:ok, window_started_at, _offset} = DateTime.from_iso8601(window_started_at)
    assert {:ok, window_ends_at, _offset} = DateTime.from_iso8601(window_ends_at)
    assert DateTime.diff(window_ends_at, window_started_at, :second) == 7 * 86_400

    record_agent_usage(agent.uid, 900_000, 200_000)

    conn = conn |> recycle_api() |> send_v2(:get, ~p"/api/v2/agents/#{agent.uid}/token-quota")

    assert %{"usage" => %{"used_tokens" => 1_100_000, "exceeded" => true}} =
             json_response(conn, 200)

    conn =
      conn |> recycle_api() |> send_v2(:post, ~p"/api/v2/agents/#{agent.uid}/token-quota/reset")

    assert %{
             "token_quota" => %{
               "period_days" => 7,
               "period_start_at" => reset_start_at,
               "limit_tokens" => 1_000_000
             },
             "usage" => %{"used_tokens" => 0, "exceeded" => false}
           } = json_response(conn, 201)

    refute reset_start_at == "2026-09-09T00:00:00Z"

    conn = conn |> recycle_api() |> send_v2(:delete, ~p"/api/v2/agents/#{agent.uid}/token-quota")
    assert %{"token_quota" => nil, "usage" => nil} = json_response(conn, 200)

    # A reset keeps the ledger, so the removed limit does not delete audit rows.
    assert Repo.aggregate(UsageRecord, :count) == 1
  end

  test "an invalid token quota is rejected", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn =
      send_v2(conn, :put, ~p"/api/v2/agents/#{agent.uid}/token-quota", %{
        "period_days" => 0,
        "period_start_at" => "2026-09-09T00:00:00Z",
        "limit_tokens" => 1_000
      })

    assert %{"errors" => [%{"code" => "invalid_period_days"}]} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/agents/#{agent.uid}/token-quota", %{
        "period_days" => 7,
        "period_start_at" => "not-an-instant",
        "limit_tokens" => 1_000
      })

    assert %{"errors" => [%{"code" => "invalid_period_start_at"}]} = json_response(conn, 422)

    conn =
      conn |> recycle_api() |> send_v2(:post, ~p"/api/v2/agents/#{agent.uid}/token-quota/reset")

    assert %{"errors" => [%{"code" => "token_quota_not_configured"}]} = json_response(conn, 422)
  end

  test "capability switches keep the other setting and persist in the profile view", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}"

    assert %{
             "provider_hosted" => %{
               "effective" => %{
                 "web_search" => %{"value" => true, "source" => "default"},
                 "image_generate" => %{"value" => true, "source" => "default"}
               }
             }
           } = conn |> send_v2(:get, path <> "/model-profiles") |> json_response(200)

    assert %{"provider_hosted" => %{"web_search" => false, "image_generate" => true}} =
             conn
             |> send_v2(:put, path <> "/provider-hosted", %{"web_search" => false})
             |> json_response(200)

    assert %{
             "provider_hosted" => %{
               "overrides" => %{"web_search" => false},
               "effective" => %{
                 "web_search" => %{"value" => false, "source" => "agent"},
                 "image_generate" => %{"value" => true, "source" => "default"}
               }
             }
           } = conn |> send_v2(:get, path <> "/model-profiles") |> json_response(200)
  end

  test "Pod and Site defaults expose inheritance and restore it through DELETE", %{conn: conn} do
    assert {:ok, _provider} =
             Ankole.AIGateway.ProviderConfigs.create_provider(%{
               provider_id: "default-model-profiles",
               provider_kind: "openrouter",
               credential_pool: %{
                 "entries" => [%{"label" => "Default", "api_key" => "sk-test"}]
               }
             })

    conn = console_conn(conn)

    conn =
      send_v2(conn, :put, ~p"/api/v2/model-profiles/primary", %{
        "defaults_scope" => "global",
        "attrs" => %{"provider_id" => "default-model-profiles", "model" => "site-primary"}
      })

    assert %{
             "overrides" => %{"primary" => %{"model" => "site-primary"}},
             "effective" => %{
               "primary" => %{"source" => "global", "resolved_from_profile" => "primary"},
               "light" => %{"source" => "global", "resolved_from_profile" => "primary"}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/model-profiles/primary", %{
        "defaults_scope" => "tenant",
        "attrs" => %{"provider_id" => "default-model-profiles", "model" => "pod-primary"}
      })

    assert %{
             "inherited" => %{
               "primary" => %{
                 "source" => "global",
                 "value" => %{"model" => "site-primary"}
               }
             },
             "effective" => %{
               "primary" => %{
                 "source" => "tenant",
                 "value" => %{"model" => "pod-primary"}
               }
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:delete, ~p"/api/v2/model-profiles/primary?defaults_scope=tenant")

    assert %{
             "overrides" => %{},
             "effective" => %{
               "primary" => %{"source" => "global", "resolved_from_profile" => "primary"}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:delete, ~p"/api/v2/model-profiles/primary?defaults_scope=global")

    assert %{
             "overrides" => %{},
             "effective" => %{
               "primary" => %{
                 "source" => "default",
                 "resolved_from_profile" => "primary",
                 "value" => nil
               }
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/model-profiles/provider-hosted", %{
        "defaults_scope" => "tenant",
        "web_search" => false
      })

    assert %{
             "provider_hosted" => %{
               "overrides" => %{"web_search" => false},
               "effective" => %{"web_search" => %{"value" => false, "source" => "tenant"}}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> send_v2(:put, ~p"/api/v2/model-profiles/provider-hosted", %{
        "defaults_scope" => "tenant",
        "web_search" => nil
      })

    assert %{
             "provider_hosted" => %{
               "overrides" => %{},
               "effective" => %{"web_search" => %{"value" => true, "source" => "default"}}
             }
           } = json_response(conn, 200)
  end

  test "Agent profile writes return effective fallbacks and DELETE returns the inherited model",
       %{conn: conn} do
    %{principal: agent} = agent_fixture()
    provider_id = "agent-inheritance-console"

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.create_provider(%{
               provider_id: provider_id,
               provider_kind: "openai",
               credential_pool: %{"entries" => [%{"label" => "Default", "api_key" => "sk-test"}]}
             })

    for profile <- Ankole.AIGateway.ModelProfiles.agent_profiles() do
      assert {:ok, _} = Ankole.AIGateway.ModelProfiles.put_model_profile(agent.uid, profile, nil)
    end

    assert {:ok, _} =
             Ankole.AIGateway.ModelProfiles.put_default_model_profile(:tenant, "primary", %{
               provider_id: provider_id,
               model: "pod-primary"
             })

    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}/model-profiles/primary"

    saved =
      conn
      |> send_v2(:put, path, %{
        "attrs" => %{"provider_id" => provider_id, "model" => "agent-primary"}
      })
      |> json_response(200)

    assert saved["overrides"]["primary"]["model"] == "agent-primary"
    assert saved["effective"]["light"]["value"]["model"] == "agent-primary"
    assert saved["effective"]["coding"]["resolved_from_profile"] == "primary"

    deleted = conn |> send_v2(:delete, path) |> json_response(200)
    refute Map.has_key?(deleted["overrides"], "primary")

    assert %{"value" => %{"model" => "pod-primary"}, "source" => "tenant"} =
             deleted["effective"]["primary"]

    assert deleted["effective"]["light"]["value"]["model"] == "pod-primary"
  end

  test "an operator cannot read or change an Agent from another tenant", %{conn: conn} do
    other = Ankole.DataCase.create_tenant()
    %{principal: agent} = Repo.with_tenant(other.id, fn -> agent_fixture() end)
    conn = console_conn(conn)
    path = "/api/v2/agents/#{agent.uid}"

    for {method, suffix, params} <- [
          {:get, "/model-profiles", %{}},
          {:put, "/provider-hosted", %{"web_search" => false}},
          {:get, "/token-quota", %{}},
          {:delete, "/token-quota", %{}}
        ] do
      assert %{"errors" => [%{"code" => "not_found"}]} =
               conn |> send_v2(method, path <> suffix, params) |> json_response(404)
    end

    assert {:ok, capabilities} =
             Repo.with_tenant(other.id, fn ->
               Ankole.AIGateway.ModelProfiles.provider_hosted_capabilities(agent.uid)
             end)

    assert capabilities == %{"web_search" => true, "image_generate" => true}
  end

  test "operators configure each registered system Principal through the Pod permissions", %{
    conn: conn
  } do
    conn = console_conn(conn)

    assert %{"system_principals" => services} =
             conn |> send_v2(:get, "/api/v2/system-principals") |> json_response(200)

    assert Enum.map(services, & &1["uid"]) == Ankole.Principals.SystemServices.uids()

    assert {:ok, _} =
             Ankole.AIGateway.ProviderConfigs.create_provider(%{
               provider_id: "system-profiles",
               provider_kind: "openrouter",
               credential_pool: %{"entries" => [%{"label" => "Test", "api_key" => "test"}]}
             })

    for uid <- Ankole.Principals.SystemServices.uids() do
      path = "/api/v2/system-principals/#{uid}/model-profiles"
      assert %{"overrides" => overrides} = conn |> send_v2(:get, path) |> json_response(200)
      assert overrides == %{}

      assert %{
               "overrides" => %{"rerank" => %{"model" => "rerank"}},
               "effective" => %{"rerank" => %{"source" => "system"}}
             } =
               conn
               |> send_v2(:put, path <> "/rerank", %{
                 "attrs" => %{"provider_id" => "system-profiles", "model" => "rerank"}
               })
               |> json_response(200)

      assert %{"overrides" => overrides} =
               conn |> send_v2(:delete, path <> "/rerank") |> json_response(200)

      assert overrides == %{}

      assert %{"errors" => [_ | _]} =
               conn
               |> send_v2(:put, path <> "/custom", %{
                 "attrs" => %{"provider_id" => "system-profiles", "model" => "llm"}
               })
               |> json_response(422)
    end

    for method <- [:get, :put, :delete] do
      suffix = if method == :get, do: "", else: "/primary"

      assert %{"errors" => [_ | _]} =
               conn
               |> send_v2(method, "/api/v2/system-principals/unknown/model-profiles" <> suffix, %{
                 "attrs" => %{"provider_id" => "system-profiles", "model" => "llm"}
               })
               |> json_response(422)
    end
  end

  test "a non-admin browser cannot read or change system model profiles", %{conn: conn} do
    console_conn(conn)
    member = human_fixture().principal

    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> AnkoleWeb.Session.put_tenant_session(%{
        principal_uid: member.uid,
        provider_id: "local",
        external_id: member.uid
      })
      |> with_console_csrf()
      |> get(~p"/api/v2/browser/session")

    assert conn.status == 200

    for {method, path} <- [
          {:get, "/api/v2/system-principals"},
          {:get, "/api/v2/system-principals/ankole_brain/model-profiles"},
          {:put, "/api/v2/system-principals/ankole_brain/model-profiles/light"},
          {:delete, "/api/v2/system-principals/ankole_brain/model-profiles/light"}
        ] do
      assert %{"error" => %{"code" => "forbidden"}} =
               conn
               |> send_v2(method, path, %{
                 "attrs" => %{"provider_id" => "unused", "model" => "unused"}
               })
               |> json_response(403)
    end

    assert {:ok, %{overrides: overrides}} =
             Repo.with_tenant(member.tenant_id, fn ->
               Ankole.AIGateway.ModelProfiles.system_model_profile_configuration("ankole_brain")
             end)

    assert overrides == %{}
  end

  defp record_agent_usage(agent_uid, input_tokens, output_tokens) do
    assert {:ok, _record} =
             Ankole.Ash.create(UsageRecord, :record_round, %{
               subject_uid: agent_uid,
               origin: :agent,
               model: "test-provider/test-model",
               input_tokens: input_tokens,
               output_tokens: output_tokens
             })
  end

  defp send_v2(conn, method, path, params \\ %{}) do
    conn =
      conn
      |> recycle_api()
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")

    body = if method in [:get, :delete], do: nil, else: Jason.encode!(%{data: params})
    Phoenix.ConnTest.dispatch(conn, AnkoleWeb.Endpoint, method, path, body)
  end
end
