defmodule AnkoleWeb.SignalBindingControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ankole.PrincipalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.AppConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ
  alias Ankole.Plugins.DingTalkAdapter
  alias Ankole.Plugins.DingTalkAdapter.Config, as: DingTalkConfig
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
    :ok = AppConfigure.register_patterns(DingTalkAdapter.app_config_patterns())
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

  test "generic AppConfigure updates cannot bypass Lark binding assignment ownership", %{
    conn: conn
  } do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn =
      put_binding(conn, first_agent.uid, "lark", "lark-main", %{
        "appID" => "cli_shared_lark",
        "appSecret" => "secret-first-lark"
      })

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put_binding(second_agent.uid, "lark", "lark-main", %{
        "appID" => "cli_second_lark",
        "appSecret" => "secret-second-lark"
      })

    assert response(conn, 200)
    config_key = LarkConfig.chat_config_key(second_agent.uid)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{config_key}", %{
        "value" => %{
          "appID" => "cli_shared_lark",
          "appSecret" => "secret-bypassed-lark"
        }
      })

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    assert {:ok, %{"appID" => "cli_second_lark", "appSecret" => "secret-second-lark"}} =
             LarkConfig.load_chat_config_ref(config_key)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/app-configurations/#{config_key}")
    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)
    assert {:ok, %{"appID" => "cli_second_lark"}} = LarkConfig.load_chat_config_ref(config_key)
  end

  test "generic AppConfigure updates cannot bypass DingTalk binding assignment ownership", %{
    conn: conn
  } do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    conn = bearer_conn(conn)

    conn =
      put_binding(conn, first_agent.uid, "dingtalk", "dingtalk-main", %{
        "clientId" => "ding_shared",
        "clientSecret" => "secret-first-dingtalk"
      })

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put_binding(second_agent.uid, "dingtalk", "dingtalk-main", %{
        "clientId" => "ding_second",
        "clientSecret" => "secret-second-dingtalk"
      })

    assert response(conn, 200)
    config_key = DingTalkConfig.chat_config_key(second_agent.uid)

    conn =
      conn
      |> recycle_api()
      |> put(~p"/api/v1/app-configurations/#{config_key}", %{
        "value" => %{
          "clientId" => "ding_shared",
          "clientSecret" => "secret-bypassed-dingtalk"
        }
      })

    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    assert {:ok,
            %{
              "clientId" => "ding_second",
              "clientSecret" => "secret-second-dingtalk"
            }} = DingTalkConfig.load_chat_config_ref(config_key)

    conn = conn |> recycle_api() |> delete(~p"/api/v1/app-configurations/#{config_key}")
    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)
    assert {:ok, %{"clientId" => "ding_second"}} = DingTalkConfig.load_chat_config_ref(config_key)
  end

  test "owner-managed adapter keys reject missing and corrupt rows before generic writes", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])

    cases = [
      {LarkConfig.chat_config_key("missing-#{unique}"),
       %{"appID" => "cli_missing", "appSecret" => "secret"}},
      {DingTalkConfig.chat_config_key("missing-#{unique}"),
       %{"clientId" => "ding_missing", "clientSecret" => "secret"}}
    ]

    Enum.reduce(cases, bearer_conn(conn), fn {config_key, config}, conn ->
      conn = put_generic_config(conn, config_key, config)

      assert %{
               "error" => %{
                 "code" => "not_editable",
                 "message" => "app configuration is managed through its owning API"
               }
             } = json_response(conn, 422)

      refute Repo.get_by(AppConfig, scope: "global", key: config_key)

      invalid_envelope = %{"type" => "cipher", "value" => "invalid"}
      put_raw_global_config(config_key, invalid_envelope)

      conn = conn |> recycle_api() |> put_generic_config(config_key, config)

      assert %{
               "error" => %{
                 "code" => "not_editable",
                 "message" => "app configuration is managed through its owning API"
               }
             } = json_response(conn, 422)

      assert %AppConfig{value: ^invalid_envelope} =
               Repo.get_by(AppConfig, scope: "global", key: config_key)

      assert {:error, {:storage_error, "global", ^config_key, _decrypt_reason}} =
               AppConfigure.get_by_key(config_key)

      recycle_api(conn)
    end)
  end

  test "concurrent generic writes cannot race owner-managed Lark and DingTalk configs" do
    %{principal: lark_agent} = agent_fixture()
    %{principal: dingtalk_agent} = agent_fixture()
    lark_key = LarkConfig.chat_config_key(lark_agent.uid)
    dingtalk_key = DingTalkConfig.chat_config_key(dingtalk_agent.uid)

    assert {:ok, _result} =
             SignalsGateway.put_binding(lark_agent.uid, "lark", "lark-main", %{
               "config" => %{"appID" => "cli_concurrent_owner", "appSecret" => "secret"}
             })

    assert {:ok, _result} =
             SignalsGateway.put_binding(dingtalk_agent.uid, "dingtalk", "dingtalk-main", %{
               "config" => %{
                 "clientId" => "ding_concurrent_owner",
                 "clientSecret" => "secret"
               },
               "group_message_mode" => "addressed_only"
             })

    parent = self()

    tasks =
      [
        {lark_key, %{"value" => %{"appID" => "cli_bypass_a", "appSecret" => "secret"}}},
        {lark_key, %{"value" => %{"appID" => "cli_bypass_b", "appSecret" => "secret"}}},
        {dingtalk_key,
         %{"value" => %{"clientId" => "ding_bypass_a", "clientSecret" => "secret"}}},
        {dingtalk_key, %{"value" => %{"clientId" => "ding_bypass_b", "clientSecret" => "secret"}}}
      ]
      |> Enum.map(fn {key, attrs} ->
        Task.async(fn ->
          send(parent, {:generic_writer_ready, self()})
          receive do: (:write -> AppConfigure.console_update_global_by_key(key, attrs))
        end)
      end)

    task_pids = MapSet.new(tasks, & &1.pid)

    Enum.each(tasks, fn _task ->
      assert_receive {:generic_writer_ready, pid}, 1_000
      assert MapSet.member?(task_pids, pid)
    end)

    Enum.each(tasks, &send(&1.pid, :write))

    assert Enum.all?(tasks, fn task ->
             match?(
               {:error, {:pattern_key_managed_by_owner, _key}},
               Task.await(task, 1_000)
             )
           end)

    assert {:ok, %{"appID" => "cli_concurrent_owner"}} =
             LarkConfig.load_chat_config_ref(lark_key)

    assert {:ok, %{"clientId" => "ding_concurrent_owner"}} =
             DingTalkConfig.load_chat_config_ref(dingtalk_key)
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

  defp put_binding(conn, agent_uid, adapter_id, binding_name, config) do
    attrs =
      case adapter_id do
        "dingtalk" -> %{"config" => config, "group_message_mode" => "addressed_only"}
        _adapter_id -> %{"config" => config}
      end

    put(
      conn,
      ~p"/api/v1/agents/#{agent_uid}/signal-bindings/#{adapter_id}/#{binding_name}",
      attrs
    )
  end

  defp put_generic_config(conn, config_key, config) do
    put(conn, ~p"/api/v1/app-configurations/#{config_key}", %{"value" => config})
  end

  defp put_raw_global_config(key, envelope) do
    %AppConfig{}
    |> AppConfig.changeset(%{scope: "global", key: key, value: envelope})
    |> Repo.insert!()
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
