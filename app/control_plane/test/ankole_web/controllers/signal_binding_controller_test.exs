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

  test "admin creates a Lark signal binding with the record-only default", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    config_key = "signals_gateway.lark.bindings.#{agent.uid}"
    config_ref = "app-config://#{config_key}"

    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => %{
          "appID" => "cli_lark_main",
          "appSecret" => "secret-lark-main",
          "domain" => "feishu",
          "platformSubjectNamespace" => "lark-main",
          "userName" => "Research Bot"
        }
      })

    assert %{
             "signal_binding" => %{
               "agent_uid" => agent_uid,
               "name" => "lark-main",
               "adapter" => "lark",
               "config_key" => ^config_key,
               "config_ref" => ^config_ref,
               "unaddressed_group_message_policy" => "record_only",
               "enabled" => true
             }
           } = json_response(conn, 200)

    assert agent_uid == agent.uid
    refute conn.resp_body =~ "secret-lark-main"

    assert {:ok, binding} = SignalsGateway.get_binding(agent.uid, "lark-main")
    assert binding.adapter == "lark"
    assert binding.unaddressed_group_message_policy == :record_only

    assert {:ok, config} = LarkConfig.load_chat_config_ref(binding.config_ref)
    assert config["appID"] == "cli_lark_main"
    assert config["appSecret"] == "secret-lark-main"
    # The bot identity is resolved automatically at connection time, so the
    # stored binding carries no hand-entered bot open_id.
    assert config["botOpenID"] == nil
    refute Map.has_key?(config, "group_message_mode")

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent.uid}/signal-bindings")

    assert %{"signal_bindings" => [listed]} = json_response(conn, 200)
    assert listed["agent_uid"] == agent.uid
    assert listed["name"] == "lark-main"
    assert listed["enabled"] == true

    conn =
      conn
      |> recycle_api()
      |> delete(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main")

    assert %{"signal_binding" => %{"name" => "lark-main", "enabled" => false}} =
             json_response(conn, 200)

    assert {:error, :binding_disabled} = SignalsGateway.get_binding(agent.uid, "lark-main")
  end

  test "unknown signal adapter remains a 404", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> bearer_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/missing/default", %{
        "config" => %{}
      })

    assert %{"error" => %{"code" => "not_found", "message" => "signal adapter was not found"}} =
             json_response(conn, 404)
  end

  test "admin lists signal adapter catalog with provider fields and common group mode field", %{
    conn: conn
  } do
    conn =
      conn
      |> bearer_conn()
      |> get(~p"/api/v1/signal-adapters")

    assert %{"signal_adapters" => adapters} = json_response(conn, 200)
    assert Enum.map(adapters, & &1["adapter_id"]) == ["dingtalk", "lark", "slack", "teams"]

    adapter = Enum.find(adapters, &(&1["adapter_id"] == "lark"))
    assert adapter["adapter_id"] == "lark"
    assert adapter["display_name"]["default"] == "Lark"

    assert Enum.map(adapter["fields"], & &1["path"]) == [
             "appID",
             "appSecret",
             "domain",
             "baseURL",
             "platformSubjectNamespace",
             "userName"
           ]

    assert Enum.all?(adapter["fields"], &(&1["advanced"] == false))

    assert adapter["group_message_mode_field"]["path"] == "group_message_mode"
    assert adapter["group_message_mode_field"]["advanced"] == false
    assert adapter["group_message_mode_field"]["default"] == "observe_all"

    assert Enum.map(adapter["group_message_mode_field"]["options"], & &1["value"]) == [
             "addressed_only",
             "observe_all",
             "may_intervene"
           ]

    slack = Enum.find(adapters, &(&1["adapter_id"] == "slack"))
    assert slack["display_name"]["default"] == "Slack"

    assert Enum.map(slack["fields"], & &1["path"]) == [
             "botToken",
             "appToken",
             "platformSubjectNamespace",
             "userName",
             "baseURL"
           ]

    assert slack["group_message_mode_field"] == adapter["group_message_mode_field"]
  end

  test "signal adapter catalog returns 503 while the plugin registry is unavailable", %{
    conn: conn
  } do
    conn = bearer_conn(conn)

    conn =
      without_plugin_registry(fn ->
        get(conn, ~p"/api/v1/signal-adapters")
      end)

    assert %{
             "error" => %{
               "code" => "service_unavailable",
               "message" => "signal adapter registry is unavailable"
             }
           } = json_response(conn, 503)
  end

  test "signal binding save returns 503 while the plugin registry is unavailable", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn =
      without_plugin_registry(fn ->
        put(conn, ~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/unavailable", %{
          "config" => %{}
        })
      end)

    assert %{
             "error" => %{
               "code" => "service_unavailable",
               "message" => "signal adapter registry is unavailable"
             }
           } = json_response(conn, 503)
  end

  defp without_plugin_registry(fun) do
    registry = Process.whereis(Ankole.Plugins.Registry)
    true = Process.unregister(Ankole.Plugins.Registry)

    try do
      fun.()
    after
      true = Process.register(registry, Ankole.Plugins.Registry)
    end
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
