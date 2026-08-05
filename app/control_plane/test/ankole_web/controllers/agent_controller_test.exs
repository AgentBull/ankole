defmodule AnkoleWeb.AgentControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Setup.Config, as: SetupConfig
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    {:ok, false} = SetupConfig.put_completed(false)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin creates, lists, updates, reads, and disables an agent", %{conn: conn} do
    conn = bearer_conn(conn)

    conn =
      post(conn, ~p"/api/v1/agents", %{
        "uid" => "Console-Agent",
        "display_name" => "Console Agent",
        "role" => "Research Operator",
        "options" => %{"ai_agent" => %{"temperature" => 0.2}}
      })

    assert %{
             "agent" => %{
               "uid" => "console-agent",
               "display_name" => "Console Agent",
               "role" => "Research Operator",
               "status" => "active",
               "type" => "ai_colleague",
               "options" => %{"ai_agent" => %{"temperature" => 0.2}},
               "created_by_principal_uid" => admin_uid
             }
           } = json_response(conn, 200)

    assert is_binary(admin_uid)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    assert Enum.any?(agents, &(&1["uid"] == "console-agent"))

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/console-agent", %{
        "display_name" => "Console Agent Updated",
        "role" => "Customer Success Operator",
        "options" => %{"ai_agent" => %{"temperature" => 0.1}}
      })

    assert %{
             "agent" => %{
               "uid" => "console-agent",
               "display_name" => "Console Agent Updated",
               "role" => "Customer Success Operator",
               "options" => %{"ai_agent" => %{"temperature" => 0.1}}
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/console-agent")

    assert %{"agent" => %{"display_name" => "Console Agent Updated"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/console-agent")

    assert %{"agent" => %{"uid" => "console-agent", "status" => "disabled"}} =
             json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents")

    assert %{"agents" => agents} = json_response(conn, 200)
    refute Enum.any?(agents, &(&1["uid"] == "console-agent"))
  end

  test "agent delete does not disable a human principal with the same path shape", %{conn: conn} do
    %{principal: human} = human_fixture(%{uid: unique_uid("not-agent")})

    conn =
      conn
      |> bearer_conn()
      |> delete(~p"/api/v1/agents/#{human.uid}")

    assert %{"error" => %{"code" => "not_found"}} = json_response(conn, 404)
  end

  test "agent creation requires a nonblank display name", %{conn: conn} do
    conn = bearer_conn(conn)

    conn =
      post(conn, ~p"/api/v1/agents", %{
        "uid" => unique_uid("missing-display-name"),
        "role" => "Research Analyst"
      })

    assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents", %{
        "uid" => unique_uid("blank-display-name"),
        "display_name" => "   ",
        "role" => "Research Analyst"
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "display_name is required"
             }
           } = json_response(conn, 422)
  end

  test "legacy agents without a display name remain readable and updatable", %{conn: conn} do
    %{principal: legacy_agent} =
      agent_fixture(%{uid: unique_uid("legacy-agent"), display_name: nil})

    legacy_agent_uid = legacy_agent.uid

    conn =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/agents/#{legacy_agent_uid}")

    assert %{"agent" => %{"display_name" => nil}} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{legacy_agent_uid}", %{"role" => "Legacy Operator"})

    assert %{
             "agent" => %{
               "display_name" => nil,
               "role" => "Legacy Operator",
               "uid" => ^legacy_agent_uid
             }
           } = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{legacy_agent_uid}", %{"display_name" => "   "})

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "display_name is required"
             }
           } = json_response(conn, 422)
  end

  defp bearer_conn(conn) do
    conn
    |> active_admin_conn()
    |> post(~p"/.internal-apis/oauth/token", %{
      "grant_type" => "urn:ankole:params:oauth:grant-type:browser-session"
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
    |> then(fn access_token ->
      conn
      |> recycle()
      |> put_req_header("authorization", "Bearer #{access_token}")
      |> put_req_header("content-type", "application/json")
    end)
  end

  defp recycle_api(conn) do
    conn
    |> recycle()
    |> put_req_header("authorization", get_req_header(conn, "authorization") |> List.first())
    |> put_req_header("content-type", "application/json")
  end

  defp active_admin_conn(conn) do
    {:ok, true} = SetupConfig.put_completed(true)
    human = human_fixture(%{uid: unique_uid("agent-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end
end
