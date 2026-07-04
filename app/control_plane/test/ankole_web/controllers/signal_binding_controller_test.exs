defmodule AnkoleWeb.SignalBindingControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Plugins.LarkAdapter
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig
  alias Ankole.SignalsGateway
  alias AnkoleWeb.Session, as: WebSession

  setup do
    allow_cache_database_access()
    Registry.clear_for_test()
    Cache.clear_for_test()

    :ok = SetupConfig.ensure_registered()
    :ok = AppConfigure.register_patterns(LarkAdapter.app_config_patterns())
    {:ok, true} = SetupConfig.put_completed(true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    :ok
  end

  test "admin creates a Lark signal binding through the console API", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => %{
          "appId" => "cli_lark_main",
          "appSecret" => "secret-lark-main",
          "domain" => "feishu",
          "group_message_mode" => "may_intervene",
          "platformSubjectNamespace" => "lark-main",
          "userName" => "Research Bot",
          "botOpenId" => "ou_bot_main",
          "botUserId" => "bot_user_main"
        }
      })

    assert %{
             "data" => %{
               "agent_uid" => agent_uid,
               "name" => "lark-main",
               "adapter" => "lark",
               "config_key" => "signals_gateway.lark.bindings.lark-main",
               "config_ref" => "app-config://signals_gateway.lark.bindings.lark-main",
               "unaddressed_group_message_policy" => "may_intervene",
               "enabled" => true
             }
           } = json_response(conn, 200)

    assert agent_uid == agent.uid
    refute conn.resp_body =~ "secret-lark-main"

    assert {:ok, binding} = SignalsGateway.get_binding(agent.uid, "lark-main")
    assert binding.adapter == "lark"
    assert binding.unaddressed_group_message_policy == :may_intervene

    assert {:ok, config} = LarkConfig.load_chat_config_ref(binding.config_ref)
    assert config["appId"] == "cli_lark_main"
    assert config["appSecret"] == "secret-lark-main"
    assert config["botOpenId"] == "ou_bot_main"

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent.uid}/signal-bindings")

    assert %{"data" => [listed]} = json_response(conn, 200)
    assert listed["agent_uid"] == agent.uid
    assert listed["name"] == "lark-main"
    assert listed["enabled"] == true

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main")

    assert %{"data" => %{"name" => "lark-main", "enabled" => false}} = json_response(conn, 200)
    assert {:error, :binding_disabled} = SignalsGateway.get_binding(agent.uid, "lark-main")
  end

  test "admin cannot create a Lark binding without bot identity", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => %{
          "appId" => "cli_lark_main",
          "appSecret" => "secret-lark-main",
          "group_message_mode" => "observe_all"
        }
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "botOpenId or botUserId is required"
             }
           } = json_response(conn, 422)

    assert {:error, :binding_not_found} = SignalsGateway.get_binding(agent.uid, "lark-main")
  end

  test "OpenAPI JSON includes signal binding configuration endpoint", %{conn: conn} do
    conn = get(conn, ~p"/api/v1/openapi.json")
    paths = json_response(conn, 200)["paths"]

    assert Map.has_key?(paths, "/api/v1/agents/{agent_uid}/signal-bindings")
    assert Map.has_key?(paths, "/api/v1/agents/{agent_uid}/signal-bindings/lark/{binding_name}")
    assert Map.has_key?(paths, "/api/v1/agents/{agent_uid}/signal-bindings/{binding_name}")
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
    human = human_fixture(%{uid: unique_uid("signal-binding-console-admin")})
    assert {:ok, _root} = AuthZ.root_init_admin(human.principal.uid)

    conn
    |> init_test_session(%{})
    |> WebSession.put_admin_session(%{
      principal_uid: human.principal.uid,
      provider_id: "lark-main",
      external_id: "external-1"
    })
  end

  defp allow_cache_database_access do
    case GenServer.whereis(Cache) do
      nil -> :ok
      pid -> Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), pid)
    end
  end
end
