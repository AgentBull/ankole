defmodule AnkoleWeb.SignalBindingControllerTest do
  use AnkoleWeb.ConnCase, async: false

  import Ecto.Query
  import Ankole.PrincipalsFixtures
  import Ankole.SignalsFixtures

  alias Ankole.AppConfigure
  alias Ankole.AppConfigure.SiteConfig
  alias Ankole.AppConfigure.Cache
  alias Ankole.AppConfigure.Registry
  alias Ankole.AuthZ.Grant
  alias Ankole.Plugins.DingTalkAdapter.Config, as: DingTalkConfig
  alias Ankole.Plugins.LarkAdapter.Config, as: LarkConfig
  alias Ankole.Plugins.LarkAdapter.ConnectionReconciler, as: LarkConnectionReconciler
  alias Ankole.Repo
  alias Ankole.Setup.Config, as: SetupConfig

  alias Ankole.Signals.Binding
  alias Ankole.Signals.Bindings
  alias Ankole.Conversations.Observe
  alias Ankole.Conversations.Delivery.Intent

  setup do
    connections = LarkConnectionReconciler.registered_keys()
    Registry.clear_for_test()
    Cache.clear_for_test()

    {:ok, true} = Ankole.AppConfigure.put_global(Ankole.Setup.Config.completed_definition(), true)
    :ok = SetupConfig.delete_bootstrap_activation_code()

    # Saved bindings and identity providers start an asynchronous pass. Wait
    # before Sandbox stops, then remove this test's owners to isolate later tests.
    on_exit(fn ->
      :sys.get_state(LarkConnectionReconciler)

      (LarkConnectionReconciler.registered_keys() -- connections)
      |> Enum.each(&LarkConnectionReconciler.stop/1)
    end)

    :ok
  end

  test "admin creates a Lark signal binding with the record-only default", %{conn: conn} do
    %{principal: agent} = agent_fixture()
    config_key = LarkConfig.binding_config_key(agent.uid, "lark-main")
    config_ref = "app-config://#{config_key}"

    conn =
      conn
      |> console_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => %{
          "appID" => "cli_lark_main",
          "appSecret" => "secret-lark-main",
          "domain" => "feishu",
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

    assert {:ok, binding} = Ankole.Signals.Bindings.get_binding(agent.uid, "lark-main")
    assert binding.adapter == "lark"
    assert binding.unaddressed_group_message_policy == :record_only

    assert {:ok, config} = Bindings.binding_config(binding, LarkConfig)
    assert config["appID"] == "cli_lark_main"
    assert config["appSecret"] == "secret-lark-main"
    # The bot identity is resolved automatically at connection time, so the
    # stored binding carries no bot identity fields.
    refute Map.has_key?(config, "botOpenID")
    refute Map.has_key?(config, "botUserID")
    refute Map.has_key?(config, "group_message_mode")

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/signal-bindings?agent=#{agent.uid}")

    assert %{"signal_bindings" => [listed]} = json_response(conn, 200)
    assert listed["agent_uid"] == agent.uid
    assert listed["name"] == "lark-main"
    assert listed["enabled"] == true

    conn = disable_binding(conn, agent.uid, "lark-main")

    assert %{"name" => "lark-main", "enabled" => false} = json_response(conn, 200)

    assert {:error, :binding_disabled} =
             Ankole.Signals.Bindings.get_binding(agent.uid, "lark-main")
  end

  test "a missing required connection field names the field in the error", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => %{"appSecret" => "secret-lark-main", "domain" => "feishu"}
      })

    assert %{
             "error" => %{
               "code" => "validation_failed",
               "message" => "appID is required",
               "details" => [%{"path" => "appID", "kind" => "missing"}]
             }
           } = json_response(conn, 422)

    assert {:error, :binding_not_found} =
             Ankole.Signals.Bindings.get_binding(agent.uid, "lark-main")
  end

  test "admin sees an unsupported operation as a permanent failed delivery", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(agent.uid, "lark", "lark-main", lark_config("delivery-unsupported"))

    assert response(conn, 200)

    assert {:ok, %{status: :accepted, conversation: conversation}} =
             Observe.emit_entry(agent.uid, "lark-main", group_entry(%{explicit: true}),
               now: base_time()
             )

    assert {:ok, %Intent{status: :failed, next_attempt_at: nil} = failed} =
             commit_and_dispatch(
               agent.uid,
               "lark-main",
               %{
                 outbound_key: "ai-reply:console-unsupported",
                 delivery_class: :durable_ai_reply,
                 operation: :edit,
                 conversation_id: conversation.id,
                 target_provider_message_id: "msg-1",
                 fallback_visible_text: "cannot be edited here"
               },
               [:post_entry, :reply_entry],
               %{}
             )

    assert failed.last_error == %{"code" => "unsupported_operation"}
    assert failed.recovery_status == :permanent
    assert failed.recovery_reason == "unsupported_operation"
    assert failed.recovery_state == %{}

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/signal-bindings?agent=#{agent.uid}")

    assert %{
             "delivery_failures" => [
               %{
                 "outbound_key" => "ai-reply:console-unsupported",
                 "status" => "failed",
                 "state" => "permanent",
                 "attempt_count" => 0,
                 "can_retry" => true
               }
             ]
           } = json_response(conn, 200)
  end

  test "admin sees and requeues a stopped durable delivery", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(agent.uid, "lark", "lark-main", lark_config("delivery-failure"))

    assert response(conn, 200)

    assert {:ok, %{status: :accepted, conversation: conversation}} =
             Observe.emit_entry(agent.uid, "lark-main", group_entry(%{explicit: true}),
               now: base_time()
             )

    assert {:ok, _intent} =
             Ankole.SignalsFixtures.commit_delivery(%{
               agent_uid: agent.uid,
               binding_name: "lark-main",
               outbound_key: "ai-reply:console-failure",
               delivery_class: :durable_ai_reply,
               operation: :post,
               conversation_id: conversation.id,
               fallback_visible_text: "provider rejects this"
             })

    assert {:ok, %Intent{status: :failed}} =
             Ankole.Conversations.Delivery.dispatch(
               agent.uid,
               "lark-main",
               "ai-reply:console-failure",
               delivery_adapter([:post_entry], fn _intent ->
                 {:error, {:reply_delivery, :permanent, %{"code" => 40_201}}}
               end),
               now: base_time()
             )

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/signal-bindings?agent=#{agent.uid}")

    assert %{
             "delivery_failures" => [
               %{
                 "agent_uid" => failure_agent_uid,
                 "binding_name" => "lark-main",
                 "outbound_key" => "ai-reply:console-failure",
                 "status" => "failed",
                 "state" => "permanent",
                 "attempt_count" => 1,
                 "max_attempts" => 10,
                 "possible_duplicate" => false,
                 "can_retry" => true
               }
             ]
           } = json_response(conn, 200)

    assert failure_agent_uid == agent.uid

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents/#{agent.uid}/signal-deliveries/requeue", %{
        "binding_name" => "lark-main",
        "outbound_key" => "ai-reply:console-failure"
      })

    assert %{"requeued" => true} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> post(~p"/api/v1/agents/#{agent.uid}/signal-deliveries/requeue", %{
        "binding_name" => "lark-main",
        "outbound_key" => "ai-reply:console-failure"
      })

    assert %{"error" => %{"code" => "conflict"}} = json_response(conn, 409)

    requeued =
      Repo.get_by!(Intent,
        agent_uid: agent.uid,
        binding_name: "lark-main",
        outbound_key: "ai-reply:console-failure"
      )

    assert requeued.attempt_count == 1
    assert requeued.max_attempts == 2
    assert %DateTime{} = requeued.next_attempt_at
    assert requeued.recovery_state == %{}
  end

  test "admin edits a disabled binding without exposing or replacing its secret", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    original_config =
      lark_config("editable")
      |> Map.put("domain", "feishu")

    conn =
      conn
      |> console_conn()
      |> put_binding(agent.uid, "lark", "lark-main", original_config)

    assert response(conn, 200)

    conn = disable_binding(conn, agent.uid, "lark-main")

    assert %{"enabled" => false} = json_response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> get(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main")

    assert %{
             "signal_binding" => %{
               "agent_uid" => agent_uid,
               "name" => "lark-main",
               "adapter" => "lark",
               "enabled" => false
             },
             "config" => %{
               "appID" => "cli_editable",
               "domain" => "feishu",
               "userName" => "Bot editable"
             },
             "stored_secret_paths" => ["appSecret"]
           } = json_response(conn, 200)

    assert agent_uid == agent.uid
    refute conn.resp_body =~ original_config["appSecret"]

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main", %{
        "target_agent_uid" => agent.uid,
        "config" => %{"appSecret" => "", "domain" => "lark"},
        "group_message_mode" => "observe_all"
      })

    assert %{
             "signal_binding" => %{
               "enabled" => true,
               "unaddressed_group_message_policy" => "record_only"
             }
           } = json_response(conn, 200)

    assert {:ok, stored_config} =
             Bindings.binding_config(
               %Binding{
                 config_ref:
                   "app-config://#{LarkConfig.binding_config_key(agent.uid, "lark-main")}"
               },
               LarkConfig
             )

    assert stored_config["appSecret"] == original_config["appSecret"]
    assert stored_config["domain"] == "lark"
  end

  test "unknown signal adapter remains a 404", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/missing/default", %{
        "config" => %{}
      })

    assert %{"error" => %{"code" => "not_found", "message" => "signal adapter was not found"}} =
             json_response(conn, 404)
  end

  test "admin reconfigures a signal binding without changing its agent", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(agent.uid, "lark", "lark-main", lark_config("same-agent"))

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch_binding(agent.uid, agent.uid, "lark-main", lark_config("same-agent-updated"))

    assert %{
             "signal_binding" => %{
               "agent_uid" => agent_uid,
               "name" => "lark-main",
               "unaddressed_group_message_policy" => "may_intervene",
               "enabled" => true
             }
           } = json_response(conn, 200)

    assert agent_uid == agent.uid

    assert {:ok, %{"appID" => "cli_same-agent-updated"}} =
             Bindings.binding_config(
               %Binding{
                 config_ref:
                   "app-config://#{LarkConfig.binding_config_key(agent.uid, "lark-main")}"
               },
               LarkConfig
             )
  end

  test "admin changes binding behavior without replacing stored provider config", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    original_config =
      lark_config("preserved")
      |> Map.merge(%{
        "domain" => "lark",
        "userName" => "Preserved Bot"
      })

    conn =
      conn
      |> console_conn()
      |> put_binding(agent.uid, "lark", "lark-main", original_config)

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main", %{
        "target_agent_uid" => agent.uid,
        "config" => %{},
        "group_message_mode" => "observe_all"
      })

    assert %{
             "signal_binding" => %{
               "agent_uid" => agent_uid,
               "unaddressed_group_message_policy" => "record_only"
             }
           } = json_response(conn, 200)

    assert agent_uid == agent.uid

    assert {:ok, stored_config} =
             Bindings.binding_config(
               %Binding{
                 config_ref:
                   "app-config://#{LarkConfig.binding_config_key(agent.uid, "lark-main")}"
               },
               LarkConfig
             )

    assert stored_config["appID"] == original_config["appID"]
    assert stored_config["appSecret"] == original_config["appSecret"]
    assert stored_config["domain"] == original_config["domain"]

    assert stored_config["userName"] == original_config["userName"]
  end

  test "admin atomically moves a signal binding to another agent", %{conn: conn} do
    %{principal: source_agent} = agent_fixture()
    %{principal: target_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(source_agent.uid, "lark", "lark-main", lark_config("move"))

    assert response(conn, 200)

    assert {:ok, source_binding} =
             Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

    assert {:ok, _binding} =
             Ankole.SignalsFixtures.raw_binding_fixture(source_binding, %{
               filters: %{"cel" => "signal.channel.id == 'lark:chat:allowed'"}
             })

    conn =
      conn
      |> recycle_api()
      |> patch_binding(source_agent.uid, target_agent.uid, "lark-main", lark_config("move"))

    assert %{
             "signal_binding" => %{
               "agent_uid" => target_agent_uid,
               "name" => "lark-main",
               "adapter" => "lark",
               "enabled" => true
             }
           } = json_response(conn, 200)

    assert target_agent_uid == target_agent.uid

    assert {:error, :binding_disabled} =
             Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

    assert {:ok, target_binding} =
             Ankole.Signals.Bindings.get_binding(target_agent.uid, "lark-main")

    assert target_binding.filters == %{"cel" => "signal.channel.id == 'lark:chat:allowed'"}

    assert {:ok, %{"appID" => "cli_move"}} =
             Bindings.binding_config(target_binding, LarkConfig)

    assert {:ok, %{"appID" => "cli_move"}} =
             Bindings.binding_config(source_binding, LarkConfig)
  end

  test "moving a binding keeps the group-message mode when the request omits it", %{conn: conn} do
    %{principal: source_agent} = agent_fixture()
    %{principal: target_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put(~p"/api/v1/agents/#{source_agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => lark_config("group-mode-keep"),
        "group_message_mode" => "may_intervene"
      })

    assert response(conn, 200)

    assert {:ok, source_binding} =
             Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

    assert source_binding.unaddressed_group_message_policy == :may_intervene

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{source_agent.uid}/signal-bindings/lark-main", %{
        "target_agent_uid" => target_agent.uid,
        "config" => lark_config("group-mode-keep")
      })

    assert response(conn, 200)

    assert {:ok, target_binding} =
             Ankole.Signals.Bindings.get_binding(target_agent.uid, "lark-main")

    assert target_binding.unaddressed_group_message_policy == :may_intervene
  end

  test "moving a binding keeps the unmatched-sender policy when the request omits it", %{
    conn: conn
  } do
    %{principal: source_agent} = agent_fixture()
    %{principal: target_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put(~p"/api/v1/agents/#{source_agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => lark_config("policy-keep"),
        "unmatched_sender_policy" => "create_standalone"
      })

    assert response(conn, 200)

    assert {:ok, source_binding} =
             Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

    assert source_binding.unmatched_sender_policy == :create_standalone

    conn =
      conn
      |> recycle_api()
      |> patch(~p"/api/v1/agents/#{source_agent.uid}/signal-bindings/lark-main", %{
        "target_agent_uid" => target_agent.uid,
        "config" => lark_config("policy-keep"),
        "group_message_mode" => "may_intervene"
      })

    assert response(conn, 200)

    assert {:ok, target_binding} =
             Ankole.Signals.Bindings.get_binding(target_agent.uid, "lark-main")

    assert target_binding.unmatched_sender_policy == :create_standalone
  end

  test "moving a binding rejects an enabled target conflict without disabling the source", %{
    conn: conn
  } do
    %{principal: source_agent} = agent_fixture()
    %{principal: target_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(source_agent.uid, "lark", "lark-main", lark_config("source-conflict"))

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put_binding(target_agent.uid, "lark", "lark-main", lark_config("target-conflict"))

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch_binding(
        source_agent.uid,
        target_agent.uid,
        "lark-main",
        lark_config("move-conflict")
      )

    assert %{"error" => %{"code" => "conflict"}} = json_response(conn, 409)
    assert {:ok, _binding} = Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")
    assert {:ok, _binding} = Ankole.Signals.Bindings.get_binding(target_agent.uid, "lark-main")
  end

  test "moving a binding replaces a disabled target binding", %{conn: conn} do
    %{principal: source_agent} = agent_fixture()
    %{principal: target_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(target_agent.uid, "lark", "lark-main", lark_config("disabled-target"))

    assert response(conn, 200)

    conn = disable_binding(conn, target_agent.uid, "lark-main")

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> put_binding(source_agent.uid, "lark", "lark-main", lark_config("replacement"))

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch_binding(
        source_agent.uid,
        target_agent.uid,
        "lark-main",
        lark_config("replacement")
      )

    assert %{"signal_binding" => %{"agent_uid" => agent_uid, "enabled" => true}} =
             json_response(conn, 200)

    assert agent_uid == target_agent.uid

    assert {:error, :binding_disabled} =
             Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

    assert {:ok, _binding} = Ankole.Signals.Bindings.get_binding(target_agent.uid, "lark-main")
  end

  test "moving a binding rejects a missing target agent without changing the source", %{
    conn: conn
  } do
    %{principal: source_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(source_agent.uid, "lark", "lark-main", lark_config("missing-target"))

    assert response(conn, 200)

    conn =
      conn
      |> recycle_api()
      |> patch_binding(
        source_agent.uid,
        "missing-agent",
        "lark-main",
        lark_config("missing-target")
      )

    assert %{"error" => %{"code" => "not_found", "message" => "agent was not found"}} =
             json_response(conn, 404)

    assert {:ok, _binding} = Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")
  end

  test "moving a binding requires delete permission for the source agent", %{conn: conn} do
    %{principal: source_agent} = agent_fixture()
    %{principal: target_agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> put_binding(source_agent.uid, "lark", "lark-main", lark_config("forbidden"))

    assert response(conn, 200)
    Repo.delete_all(from(grant in Grant, where: grant.action == "delete"))

    conn =
      conn
      |> recycle_api()
      |> patch_binding(source_agent.uid, target_agent.uid, "lark-main", lark_config("forbidden"))

    assert %{"error" => %{"code" => "forbidden"}} = json_response(conn, 403)
    assert {:ok, _binding} = Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

    assert {:error, :binding_not_found} =
             Ankole.Signals.Bindings.get_binding(target_agent.uid, "lark-main")
  end

  test "generic AppConfigure updates cannot bypass Lark binding assignment ownership", %{
    conn: conn
  } do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    conn = console_conn(conn)

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
    config_key = LarkConfig.binding_config_key(second_agent.uid, "lark-main")

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
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{config_key}"},
               LarkConfig
             )

    conn = conn |> recycle_api() |> delete(~p"/api/v1/app-configurations/#{config_key}")
    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    assert {:ok, %{"appID" => "cli_second_lark"}} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{config_key}"},
               LarkConfig
             )
  end

  test "generic AppConfigure updates cannot bypass DingTalk binding assignment ownership", %{
    conn: conn
  } do
    %{principal: first_agent} = agent_fixture()
    %{principal: second_agent} = agent_fixture()
    conn = console_conn(conn)

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
    config_key = "signals.dingtalk.bindings." <> second_agent.uid

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
            }} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{config_key}"},
               DingTalkConfig
             )

    conn = conn |> recycle_api() |> delete(~p"/api/v1/app-configurations/#{config_key}")
    assert %{"error" => %{"code" => "not_editable"}} = json_response(conn, 422)

    assert {:ok, %{"clientId" => "ding_second"}} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{config_key}"},
               DingTalkConfig
             )
  end

  test "owner-managed adapter keys reject missing and corrupt rows before generic writes", %{
    conn: conn
  } do
    unique = System.unique_integer([:positive])

    cases = [
      {"signals.lark.bindings." <> "missing-#{unique}",
       %{"appID" => "cli_missing", "appSecret" => "secret"}},
      {"signals.dingtalk.bindings." <> "missing-#{unique}",
       %{"clientId" => "ding_missing", "clientSecret" => "secret"}}
    ]

    Enum.reduce(cases, console_conn(conn), fn {config_key, config}, conn ->
      conn = put_generic_config(conn, config_key, config)

      assert %{
               "error" => %{
                 "code" => "not_editable",
                 "message" => "app configuration is managed through its owning API"
               }
             } = json_response(conn, 422)

      refute Repo.get_by(SiteConfig, scope: "global", key: config_key)

      invalid_envelope = %{"type" => "cipher", "value" => "invalid"}
      put_raw_global_config(config_key, invalid_envelope)

      conn = conn |> recycle_api() |> put_generic_config(config_key, config)

      assert %{
               "error" => %{
                 "code" => "not_editable",
                 "message" => "app configuration is managed through its owning API"
               }
             } = json_response(conn, 422)

      assert %SiteConfig{value: ^invalid_envelope} =
               Repo.get_by(SiteConfig, scope: "global", key: config_key)

      assert {:error, {:storage_error, "global", ^config_key, _decrypt_reason}} =
               AppConfigure.get_by_key(config_key)

      recycle_api(conn)
    end)
  end

  test "concurrent generic writes cannot race owner-managed Lark and DingTalk configs" do
    %{principal: lark_agent} = agent_fixture()
    %{principal: dingtalk_agent} = agent_fixture()
    lark_key = LarkConfig.binding_config_key(lark_agent.uid, "lark-main")
    dingtalk_key = "signals.dingtalk.bindings." <> dingtalk_agent.uid

    assert {:ok, _result} =
             Ankole.Signals.Bindings.put_binding(lark_agent.uid, "lark", "lark-main", %{
               "config" => %{"appID" => "cli_concurrent_owner", "appSecret" => "secret"}
             })

    assert {:ok, _result} =
             Ankole.Signals.Bindings.put_binding(
               dingtalk_agent.uid,
               "dingtalk",
               "dingtalk-main",
               %{
                 "config" => %{
                   "clientId" => "ding_concurrent_owner",
                   "clientSecret" => "secret"
                 },
                 "group_message_mode" => "addressed_only"
               }
             )

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
          receive do: (:write -> AppConfigure.console_update(:global, key, attrs))
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
               {:error, {:key_managed_by_owner, _key}},
               Task.await(task, 1_000)
             )
           end)

    assert {:ok, %{"appID" => "cli_concurrent_owner"}} =
             Bindings.binding_config(%Binding{config_ref: "app-config://#{lark_key}"}, LarkConfig)

    assert {:ok, %{"clientId" => "ding_concurrent_owner"}} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{dingtalk_key}"},
               DingTalkConfig
             )
  end

  test "admin lists signal adapter catalog with provider fields and common group mode field", %{
    conn: conn
  } do
    conn =
      conn
      |> console_conn()
      |> get(~p"/api/v1/signal-adapters")

    assert %{"signal_adapters" => adapters} = json_response(conn, 200)

    adapter = Enum.find(adapters, &(&1["adapter_id"] == "lark"))
    assert adapter["adapter_id"] == "lark"
    assert adapter["adapter_category"] == "enterprise_im"

    assert adapter["group_message_mode_field"]["path"] == "group_message_mode"
    assert adapter["group_message_mode_field"]["advanced"] == false
    assert adapter["group_message_mode_field"]["default"] == "observe_all"

    assert Enum.map(adapter["group_message_mode_field"]["options"], & &1["value"]) == [
             "addressed_only",
             "observe_all",
             "may_intervene"
           ]

    slack = Enum.find(adapters, &(&1["adapter_id"] == "slack"))
    assert slack["group_message_mode_field"] == adapter["group_message_mode_field"]

    assert Enum.all?(
             Enum.filter(adapters, &(&1["adapter_id"] in ~w(dingtalk lark slack teams wecom))),
             &(&1["adapter_category"] == "enterprise_im")
           )

    telegram = Enum.find(adapters, &(&1["adapter_id"] == "telegram"))
    assert telegram["adapter_category"] == "consumer_im"
    assert telegram["display_name"]["default"] == "Telegram"
    assert Enum.map(telegram["fields"], & &1["path"]) == ["botToken"]
  end

  describe "identity provider reference" do
    setup do
      save_lark_provider("feishu")
      :ok
    end

    test "catalog serves the configured providers and the standalone choice", %{conn: conn} do
      conn = conn |> console_conn() |> get(~p"/api/v1/signal-adapters")

      assert %{"signal_adapters" => adapters} = json_response(conn, 200)
      lark = Enum.find(adapters, &(&1["adapter_id"] == "lark"))
      field = Enum.find(lark["fields"], &(&1["path"] == "identityProvider"))

      assert field["type"] == "select"
      assert field["required"] == false
      assert Enum.map(field["options"], & &1["value"]) == ["feishu", ":standalone"]
      refute Map.has_key?(field, "identity_provider_adapter")

      slack = Enum.find(adapters, &(&1["adapter_id"] == "slack"))
      refute Enum.any?(slack["fields"], &(&1["path"] == "identityProvider"))

      save_lark_provider("feishu-2")
      conn = conn |> recycle_api() |> get(~p"/api/v1/signal-adapters")
      assert %{"signal_adapters" => adapters} = json_response(conn, 200)
      lark = Enum.find(adapters, &(&1["adapter_id"] == "lark"))
      field = Enum.find(lark["fields"], &(&1["path"] == "identityProvider"))
      assert field["required"] == true
      assert Enum.map(field["options"], & &1["value"]) == ["feishu", "feishu-2", ":standalone"]
    end

    test "a single provider is adopted when the reference is empty", %{conn: conn} do
      %{principal: agent} = agent_fixture()
      config_key = LarkConfig.binding_config_key(agent.uid, "lark-main")

      conn =
        conn
        |> console_conn()
        |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
          "config" => lark_config("adopted")
        })

      assert %{"signal_binding" => %{"name" => "lark-main"}} = json_response(conn, 200)

      assert {:ok, stored_config} =
               Bindings.binding_config(
                 %Binding{config_ref: "app-config://#{config_key}"},
                 LarkConfig
               )

      assert stored_config["identityProvider"] == nil
      assert LarkConfig.subject_namespace(stored_config) == "feishu"
    end

    test "an explicit or standalone reference is stored and an unknown one is rejected", %{
      conn: conn
    } do
      %{principal: agent} = agent_fixture()
      config_key = LarkConfig.binding_config_key(agent.uid, "lark-main")

      conn =
        conn
        |> console_conn()
        |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
          "config" => Map.put(lark_config("unknown"), "identityProvider", "lark-main")
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)

      assert {:error, :binding_not_found} =
               Ankole.Signals.Bindings.get_binding(agent.uid, "lark-main")

      conn =
        conn
        |> recycle_api()
        |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
          "config" => Map.put(lark_config("explicit"), "identityProvider", "feishu")
        })

      assert %{"signal_binding" => %{"name" => "lark-main"}} = json_response(conn, 200)

      assert {:ok, stored_config} =
               Bindings.binding_config(
                 %Binding{config_ref: "app-config://#{config_key}"},
                 LarkConfig
               )

      assert LarkConfig.subject_namespace(stored_config) == "feishu"

      conn =
        conn
        |> recycle_api()
        |> patch(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main", %{
          "target_agent_uid" => agent.uid,
          "config" => %{"identityProvider" => ":standalone"}
        })

      assert %{"signal_binding" => %{"name" => "lark-main"}} = json_response(conn, 200)

      assert {:ok, stored_config} =
               Bindings.binding_config(
                 %Binding{config_ref: "app-config://#{config_key}"},
                 LarkConfig
               )

      assert LarkConfig.subject_namespace(stored_config) == "lark-main"
    end

    test "several providers need an explicit reference on config writes only", %{conn: conn} do
      %{principal: agent} = agent_fixture()

      conn =
        conn
        |> console_conn()
        |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
          "config" => lark_config("older")
        })

      assert %{"signal_binding" => %{"name" => "lark-main"}} = json_response(conn, 200)

      save_lark_provider("feishu-2")

      conn = disable_binding(conn, agent.uid, "lark-main")

      assert %{"enabled" => false} = json_response(conn, 200)

      # The Console enable action sends an empty config; the binding keeps its reference.
      conn =
        conn
        |> recycle_api()
        |> patch(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main", %{
          "target_agent_uid" => agent.uid,
          "config" => %{},
          "group_message_mode" => "observe_all",
          "unmatched_sender_policy" => "manual_review"
        })

      assert %{"signal_binding" => %{"enabled" => true}} = json_response(conn, 200)

      conn =
        conn
        |> recycle_api()
        |> patch(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark-main", %{
          "target_agent_uid" => agent.uid,
          "config" => %{"userName" => "Renamed"}
        })

      assert %{"error" => %{"code" => "validation_failed", "message" => message}} =
               json_response(conn, 422)

      assert message =~ "identityProvider"

      conn =
        conn
        |> recycle_api()
        |> put(~p"/api/v1/agents/#{agent.uid}/signal-bindings/lark/lark-second", %{
          "config" => lark_config("second")
        })

      assert %{"error" => %{"code" => "validation_failed"}} = json_response(conn, 422)
    end
  end

  defp save_lark_provider(provider_id) do
    {:ok, identity_config} =
      LarkConfig.validate_identity_config(%{
        "appID" => "cli_#{provider_id}",
        "appSecret" => "secret"
      })

    {:ok, ^identity_config} =
      Ankole.IdentityProviders.Config.save_provider(
        %{
          "provider_id" => provider_id,
          "adapter_id" => "lark",
          "plugin_id" => "lark-adapter",
          "config_key" => "principals.identity_providers.lark." <> provider_id,
          "enabled" => true
        },
        identity_config
      )

    :ok
  end

  test "signal adapter catalog returns 503 while the plugin registry is unavailable", %{
    conn: conn
  } do
    conn = console_conn(conn)

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
    conn = console_conn(conn)

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

  defp patch_binding(conn, source_agent_uid, target_agent_uid, binding_name, config) do
    patch(
      conn,
      ~p"/api/v1/agents/#{source_agent_uid}/signal-bindings/#{binding_name}",
      %{
        "target_agent_uid" => target_agent_uid,
        "config" => config,
        "group_message_mode" => "may_intervene"
      }
    )
  end

  defp lark_config(suffix) do
    %{
      "appID" => "cli_#{suffix}",
      "appSecret" => "secret-#{suffix}",
      "userName" => "Bot #{suffix}"
    }
  end

  defp put_generic_config(conn, config_key, config) do
    put(conn, ~p"/api/v1/app-configurations/#{config_key}", %{"value" => config})
  end

  defp put_raw_global_config(key, envelope) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    {1, [row]} =
      Repo.insert_all(
        SiteConfig,
        [
          %{
            scope: "global",
            key: key,
            value: envelope,
            inserted_at: now,
            updated_at: now
          }
        ],
        returning: true
      )

    row
  end

  defp disable_binding(conn, agent_uid, name) do
    conn
    |> recycle_api()
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> delete("/api/v2/agents/#{agent_uid}/signal-bindings/#{name}")
  end
end
