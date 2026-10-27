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
      |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
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
      |> api_get(~p"/api/v2/signal-bindings?agent=#{agent.uid}")

    assert %{"signal_bindings" => [listed]} = json_response(conn, 200)
    assert listed["agent_uid"] == agent.uid
    assert listed["name"] == "lark-main"
    assert listed["enabled"] == true

    conn = disable_binding(conn, agent.uid, "lark-main")

    assert %{"name" => "lark-main", "enabled" => false} = json_response(conn, 200)

    assert {:error, :binding_disabled} =
             Ankole.Signals.Bindings.get_binding(agent.uid, "lark-main")
  end

  test "changing adapters resets omitted filters and accepts explicit replacement filters", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()

    assert {:ok, endpoint} =
             Ankole.Signals.Webhooks.create_endpoint(%{
               label: "Adapter filter replacement",
               mode: "standing",
               event_format: "cloudevents",
               expires_at: DateTime.add(DateTime.utc_now(:microsecond), 1, :hour)
             })

    conn = console_conn(conn)

    for {name, attributes, expected} <- [
          {"adapter-reset", %{}, %{}},
          {"adapter-explicit", %{"filters" => %{"cel" => "false"}}, %{"cel" => "false"}}
        ] do
      assert {:ok, %{binding: previous}} =
               Bindings.put_binding(agent.uid, "cloudevents", name, %{
                 "config" => %{"webhook_endpoint_id" => endpoint.webhook_endpoint.id},
                 "target" => %{"session_id" => "issue-triage"},
                 "filters" => %{"cel" => "signal.type == 'issue.changed'"}
               })

      assert previous.filters == %{"cel" => "signal.type == 'issue.changed'"}

      updated =
        conn
        |> recycle_api()
        |> api_put(
          ~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/#{name}",
          Map.put(attributes, "config", lark_config(name))
        )

      assert %{"signal_binding" => %{"adapter" => "lark", "filters" => ^expected}} =
               json_response(updated, 200)

      assert Repo.get_by!(Binding, agent_uid: agent.uid, name: name).filters == expected
    end
  end

  test "messaging filter writes persist replacements, preserve omissions, and allow clearing", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    create_url = ~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/filters"
    edit_url = ~p"/api/v2/agents/#{agent.uid}/signal-bindings/filters"
    config = lark_config("filters")
    initial = %{"cel" => "signal.channel.id == 'lark:chat:allowed'"}

    conn =
      conn
      |> console_conn()
      |> api_put(create_url, %{"config" => config, "filters" => initial})

    assert %{"signal_binding" => %{"filters" => ^initial}} = json_response(conn, 200)
    assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters").filters == initial

    for filters <- [%{"cel" => "false"}, %{}] do
      updated =
        conn
        |> recycle_api()
        |> api_put(create_url, %{"config" => config, "filters" => filters})

      assert %{"signal_binding" => %{"filters" => ^filters}} = json_response(updated, 200)
      assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters").filters == filters

      omitted = updated |> recycle_api() |> api_put(create_url, %{"config" => config})
      assert %{"signal_binding" => %{"filters" => ^filters}} = json_response(omitted, 200)
      assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters").filters == filters
    end

    for filters <- [%{"cel" => "true"}, %{}] do
      updated =
        conn
        |> recycle_api()
        |> api_patch(edit_url, %{
          "target_agent_uid" => agent.uid,
          "config" => %{},
          "filters" => filters
        })

      assert %{"signal_binding" => %{"filters" => ^filters}} = json_response(updated, 200)
      assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters").filters == filters

      omitted =
        updated
        |> recycle_api()
        |> api_patch(edit_url, %{"target_agent_uid" => agent.uid, "config" => %{}})

      assert %{"signal_binding" => %{"filters" => ^filters}} = json_response(omitted, 200)
      assert Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters").filters == filters
    end
  end

  test "invalid CEL cannot create or replace a messaging binding or its configuration", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    url = ~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/filters"
    config = lark_config("invalid-filters")
    config_key = LarkConfig.binding_config_key(agent.uid, "filters")
    invalid = %{"cel" => "signal.channel."}

    rejected =
      conn
      |> console_conn()
      |> api_put(url, %{"config" => config, "filters" => invalid})

    assert %{
             "errors" => [
               %{
                 "code" => "invalid_attribute",
                 "source" => %{"pointer" => "/data/attributes/filters"},
                 "detail" => detail
               }
             ]
           } = json_response(rejected, 400)

    assert detail =~ "cel must be a valid filter"
    refute Repo.get_by(Binding, agent_uid: agent.uid, name: "filters")
    refute Repo.get_by(SiteConfig, scope: "global", key: config_key)

    filters = %{"cel" => "true"}

    created =
      rejected
      |> recycle_api()
      |> api_put(url, %{"config" => config, "filters" => filters})

    assert response(created, 200)
    original = Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters")
    assert {:ok, original_config} = Bindings.binding_config(original, LarkConfig)

    rejected =
      created
      |> recycle_api()
      |> api_put(url, %{
        "config" => Map.put(config, "userName", "Rejected replacement"),
        "filters" => invalid
      })

    assert %{
             "errors" => [
               %{
                 "code" => "invalid_attribute",
                 "source" => %{"pointer" => "/data/attributes/filters"},
                 "detail" => detail
               }
             ]
           } = json_response(rejected, 400)

    assert detail =~ "cel must be a valid filter"
    stored = Repo.get_by!(Binding, agent_uid: agent.uid, name: "filters")
    assert stored.filters == filters
    assert stored.enabled == original.enabled
    assert {:ok, ^original_config} = Bindings.binding_config(stored, LarkConfig)
  end

  test "invalid CEL rolls back a messaging binding move", %{conn: conn} do
    %{principal: source} = agent_fixture()
    %{principal: target} = agent_fixture()
    filters = %{"cel" => "true"}

    created =
      conn
      |> console_conn()
      |> api_put(~p"/api/v2/agents/#{source.uid}/signal-bindings/lark/filters", %{
        "config" => lark_config("invalid-filter-move"),
        "filters" => filters
      })

    assert response(created, 200)
    original = Repo.get_by!(Binding, agent_uid: source.uid, name: "filters")
    assert {:ok, original_config} = Bindings.binding_config(original, LarkConfig)

    rejected =
      created
      |> recycle_api()
      |> api_patch(~p"/api/v2/agents/#{source.uid}/signal-bindings/filters", %{
        "target_agent_uid" => target.uid,
        "config" => %{"userName" => "Rejected move"},
        "filters" => %{"cel" => "signal.channel."}
      })

    assert %{
             "errors" => [
               %{
                 "code" => "invalid_attribute",
                 "source" => %{"pointer" => "/data/attributes/filters"},
                 "detail" => detail
               }
             ]
           } = json_response(rejected, 400)

    assert detail =~ "cel must be a valid filter"
    assert {:ok, stored} = Bindings.get_binding(source.uid, "filters")
    assert stored.filters == filters
    assert {:ok, ^original_config} = Bindings.binding_config(stored, LarkConfig)
    refute Repo.get_by(Binding, agent_uid: target.uid, name: "filters")

    refute Repo.get_by(SiteConfig,
             scope: "global",
             key: LarkConfig.binding_config_key(target.uid, "filters")
           )
  end

  test "a missing required connection field names the field in the error", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn
      |> console_conn()
      |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => %{"appSecret" => "secret-lark-main", "domain" => "feishu"}
      })

    assert %{
             "errors" => [
               %{
                 "code" => "missing",
                 "detail" => "appID is required",
                 "meta" => %{"details" => [%{"path" => "appID", "kind" => "missing"}]}
               }
             ]
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
      |> api_get(~p"/api/v2/signal-bindings?agent=#{agent.uid}")

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
      |> api_get(~p"/api/v2/signal-bindings?agent=#{agent.uid}")

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
      |> api_post(~p"/api/v2/agents/#{agent.uid}/signal-deliveries/requeue", %{
        "binding_name" => "lark-main",
        "outbound_key" => "ai-reply:console-failure"
      })

    assert %{"requeued" => true} = json_response(conn, 201)

    conn =
      conn
      |> recycle_api()
      |> api_post(~p"/api/v2/agents/#{agent.uid}/signal-deliveries/requeue", %{
        "binding_name" => "lark-main",
        "outbound_key" => "ai-reply:console-failure"
      })

    assert %{"errors" => [%{"code" => "intent_not_requeueable"}]} = json_response(conn, 409)

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
      |> api_get(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark-main")

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
      |> api_patch(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark-main", %{
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
      |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/missing/default", %{
        "config" => %{}
      })

    assert %{"errors" => [%{"code" => "not_found"}]} =
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
      |> api_patch(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark-main", %{
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
      |> api_put(~p"/api/v2/agents/#{source_agent.uid}/signal-bindings/lark/lark-main", %{
        "config" => lark_config("move"),
        "filters" => %{"cel" => "signal.channel.id == 'lark:chat:allowed'"}
      })

    assert response(conn, 200)

    assert {:ok, source_binding} =
             Ankole.Signals.Bindings.get_binding(source_agent.uid, "lark-main")

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
      |> api_put(~p"/api/v2/agents/#{source_agent.uid}/signal-bindings/lark/lark-main", %{
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
      |> api_patch(~p"/api/v2/agents/#{source_agent.uid}/signal-bindings/lark-main", %{
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
      |> api_put(~p"/api/v2/agents/#{source_agent.uid}/signal-bindings/lark/lark-main", %{
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
      |> api_patch(~p"/api/v2/agents/#{source_agent.uid}/signal-bindings/lark-main", %{
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

    assert %{"errors" => [%{"code" => "binding_target_conflict"}]} = json_response(conn, 409)
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

    assert %{"errors" => [%{"code" => "not_found"}]} =
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

    assert %{"errors" => [%{"code" => "forbidden"}]} = json_response(conn, 403)
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
      |> put_app_configuration(~p"/api/v2/app-configurations/#{config_key}", %{
        "value" => %{
          "appID" => "cli_shared_lark",
          "appSecret" => "secret-bypassed-lark"
        }
      })

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

    assert {:ok, %{"appID" => "cli_second_lark", "appSecret" => "secret-second-lark"}} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{config_key}"},
               LarkConfig
             )

    conn =
      conn
      |> recycle_api()
      |> delete_app_configuration(~p"/api/v2/app-configurations/#{config_key}")

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

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
      |> put_app_configuration(~p"/api/v2/app-configurations/#{config_key}", %{
        "value" => %{
          "clientId" => "ding_shared",
          "clientSecret" => "secret-bypassed-dingtalk"
        }
      })

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

    assert {:ok,
            %{
              "clientId" => "ding_second",
              "clientSecret" => "secret-second-dingtalk"
            }} =
             Bindings.binding_config(
               %Binding{config_ref: "app-config://#{config_key}"},
               DingTalkConfig
             )

    conn =
      conn
      |> recycle_api()
      |> delete_app_configuration(~p"/api/v2/app-configurations/#{config_key}")

    assert %{"errors" => [%{"code" => "key_managed_by_owner"}]} = json_response(conn, 422)

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
               "errors" => [
                 %{
                   "code" => "key_managed_by_owner",
                   "detail" => "Use the owning settings page to change this value"
                 }
               ]
             } = json_response(conn, 422)

      refute Repo.get_by(SiteConfig, scope: "global", key: config_key)

      invalid_envelope = %{"type" => "cipher", "value" => "invalid"}
      put_raw_global_config(config_key, invalid_envelope)

      conn = conn |> recycle_api() |> put_generic_config(config_key, config)

      assert %{
               "errors" => [
                 %{
                   "code" => "key_managed_by_owner",
                   "detail" => "Use the owning settings page to change this value"
                 }
               ]
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
      |> api_get(~p"/api/v2/signal-adapters")

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
      conn = conn |> console_conn() |> api_get(~p"/api/v2/signal-adapters")

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
      conn = conn |> recycle_api() |> api_get(~p"/api/v2/signal-adapters")
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
        |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
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
        |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
          "config" => Map.put(lark_config("unknown"), "identityProvider", "lark-main")
        })

      assert %{"errors" => [%{"code" => "invalid_enum"}]} = json_response(conn, 422)

      assert {:error, :binding_not_found} =
               Ankole.Signals.Bindings.get_binding(agent.uid, "lark-main")

      conn =
        conn
        |> recycle_api()
        |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
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
        |> api_patch(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark-main", %{
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
        |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-main", %{
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
        |> api_patch(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark-main", %{
          "target_agent_uid" => agent.uid,
          "config" => %{},
          "group_message_mode" => "observe_all",
          "unmatched_sender_policy" => "manual_review"
        })

      assert %{"signal_binding" => %{"enabled" => true}} = json_response(conn, 200)

      conn =
        conn
        |> recycle_api()
        |> api_patch(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark-main", %{
          "target_agent_uid" => agent.uid,
          "config" => %{"userName" => "Renamed"}
        })

      assert %{"errors" => [%{"code" => "missing", "detail" => message}]} =
               json_response(conn, 422)

      assert message =~ "identityProvider"

      conn =
        conn
        |> recycle_api()
        |> api_put(~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/lark-second", %{
          "config" => lark_config("second")
        })

      assert %{"errors" => [%{"code" => "missing", "detail" => "identityProvider is required"}]} =
               json_response(conn, 422)
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

  test "signal adapter catalog gives a recovery error while the plugin registry is unavailable",
       %{
         conn: conn
       } do
    conn = console_conn(conn)

    conn =
      without_plugin_registry(fn ->
        api_get(conn, ~p"/api/v2/signal-adapters")
      end)

    assert %{
             "errors" => [
               %{
                 "code" => "signal_adapter_registry_unavailable",
                 "detail" => "The Signal adapter registry is unavailable; retry when it is ready"
               }
             ]
           } = json_response(conn, 422)
  end

  test "signal binding save gives a recovery error while the plugin registry is unavailable", %{
    conn: conn
  } do
    %{principal: agent} = agent_fixture()
    conn = console_conn(conn)

    conn =
      without_plugin_registry(fn ->
        api_put(conn, ~p"/api/v2/agents/#{agent.uid}/signal-bindings/lark/unavailable", %{
          "config" => %{}
        })
      end)

    assert %{
             "errors" => [
               %{
                 "code" => "signal_adapter_registry_unavailable",
                 "detail" => "The Signal adapter registry is unavailable; retry when it is ready"
               }
             ]
           } = json_response(conn, 422)
  end

  test "a move needs exactly source delete and target update permissions", %{conn: conn} do
    %{principal: source} = agent_fixture()
    %{principal: target} = agent_fixture()
    {conn, uid} = console_conn_with_principal(conn)
    conn = put_binding(conn, source.uid, "lark", "permission-move", lark_config("permitted-move"))
    assert response(conn, 200)
    Repo.delete_all(Grant)

    grant = fn resource, action ->
      assert {:ok, permission} =
               Ankole.AuthZ.create_permission_grant(%{
                 principal_uid: uid,
                 resource_pattern: resource,
                 action: action,
                 condition: "true"
               })

      permission
    end

    permissions = [
      {"site_console:agent:#{source.uid}:signal_bindings", "delete"},
      {"site_console:agent:#{target.uid}:signal_bindings", "update"}
    ]

    for {resource, action} <- permissions do
      _permission = grant.(resource, action)

      assert %{"errors" => [%{"code" => "forbidden"}]} =
               conn
               |> recycle_api()
               |> patch_binding(
                 source.uid,
                 target.uid,
                 "permission-move",
                 lark_config("permitted-move")
               )
               |> json_response(403)

      assert {:ok, %{agent_uid: source_uid}} = Bindings.get_binding(source.uid, "permission-move")
      assert source_uid == source.uid
      assert {:error, :binding_not_found} = Bindings.get_binding(target.uid, "permission-move")
      Repo.delete_all(Grant)
    end

    for {resource, action} <- permissions, do: grant.(resource, action)

    assert %{"signal_binding" => %{"agent_uid" => target_uid}} =
             conn
             |> recycle_api()
             |> patch_binding(
               source.uid,
               target.uid,
               "permission-move",
               lark_config("permitted-move")
             )
             |> json_response(200)

    assert target_uid == target.uid
    assert {:error, :binding_disabled} = Bindings.get_binding(source.uid, "permission-move")
  end

  test "a query target cannot bypass the permissions of a binding move", %{conn: conn} do
    %{principal: source} = agent_fixture()
    %{principal: target} = agent_fixture()
    {conn, uid} = console_conn_with_principal(conn)
    conn = put_binding(conn, source.uid, "lark", "query-move", lark_config("query-move"))
    assert response(conn, 200)
    Repo.delete_all(Grant)

    assert {:ok, _grant} =
             Ankole.AuthZ.create_permission_grant(%{
               principal_uid: uid,
               resource_pattern: "site_console:agent:#{source.uid}:signal_bindings",
               action: "update",
               condition: "true"
             })

    conn =
      conn
      |> recycle_api()
      |> api_patch(
        "/api/v2/agents/#{source.uid}/signal-bindings/query-move?target_agent_uid=#{target.uid}",
        %{target_agent_uid: source.uid, config: %{}}
      )

    assert %{"errors" => [%{"code" => "forbidden"}]} = json_response(conn, 403)
    assert {:ok, %{agent_uid: source_uid}} = Bindings.get_binding(source.uid, "query-move")
    assert source_uid == source.uid
    assert {:error, :binding_not_found} = Bindings.get_binding(target.uid, "query-move")
  end

  test "HTTP standing orders persist and enter the next runtime Signal snapshot", %{conn: conn} do
    %{principal: agent} = agent_fixture()

    conn =
      conn |> console_conn() |> put_binding(agent.uid, "lark", "orders", lark_config("orders"))

    conn = conn |> recycle_api() |> patch_binding(agent.uid, agent.uid, "orders", %{})
    assert response(conn, 200)
    now = base_time()

    assert {:ok, %{signal: first}} =
             Ankole.SessionsCase.emit_entry(
               agent.uid,
               "orders",
               group_entry(%{provider_message_id: "orders-seed", text: "seed"}),
               now: now
             )

    path = "/api/v2/conversations/#{first.conversation_id}/standing-orders"
    orders = "Investigate each failed deployment."

    assert %{"standing_orders" => %{"orders" => ^orders, "set_by" => set_by}} =
             conn |> recycle_api() |> api_put(path, %{orders: orders}) |> json_response(200)

    assert is_binary(set_by)

    assert %{"standing_orders" => %{"orders" => ^orders}} =
             conn |> recycle_api() |> api_get(path) |> json_response(200)

    assert {:ok, %{signal: next}} =
             Ankole.SessionsCase.emit_entry(
               agent.uid,
               "orders",
               group_entry(%{provider_message_id: "orders-next", text: "The deployment failed."}),
               now: DateTime.add(now, 30, :second)
             )

    assert next.data["channel"]["standing_orders"] == orders

    assert %{"standing_orders" => %{"orders" => nil}} =
             conn |> recycle_api() |> api_put(path, %{orders: ""}) |> json_response(200)

    assert {:ok, %{signal: cleared}} =
             Ankole.SessionsCase.emit_entry(
               agent.uid,
               "orders",
               group_entry(%{
                 provider_message_id: "orders-clear",
                 text: "The deployment failed again."
               }),
               now: DateTime.add(now, 60, :second)
             )

    refute cleared.data["channel"]["standing_orders"]
  end

  defp without_plugin_registry(fun) do
    key = {Ankole.Plugins.Registry, Ankole.Plugins.Registry}
    snapshot = :persistent_term.get(key)
    :persistent_term.erase(key)

    try do
      fun.()
    after
      :persistent_term.put(key, snapshot)
    end
  end

  defp put_binding(conn, agent_uid, adapter_id, binding_name, config) do
    attrs =
      case adapter_id do
        "dingtalk" -> %{"config" => config, "group_message_mode" => "addressed_only"}
        _adapter_id -> %{"config" => config}
      end

    api_put(
      conn,
      ~p"/api/v2/agents/#{agent_uid}/signal-bindings/#{adapter_id}/#{binding_name}",
      attrs
    )
  end

  defp patch_binding(conn, source_agent_uid, target_agent_uid, binding_name, config) do
    api_patch(
      conn,
      ~p"/api/v2/agents/#{source_agent_uid}/signal-bindings/#{binding_name}",
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
    put_app_configuration(conn, ~p"/api/v2/app-configurations/#{config_key}", %{"value" => config})
  end

  defp put_app_configuration(conn, path, attrs) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> api_put(path, Jason.encode!(%{data: attrs}))
  end

  defp delete_app_configuration(conn, path) do
    conn
    |> put_req_header("accept", "application/vnd.api+json")
    |> put_req_header("content-type", "application/vnd.api+json")
    |> api_delete(path)
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
    |> api_delete("/api/v2/agents/#{agent_uid}/signal-bindings/#{name}")
  end

  defp api_request(conn, method, path, body \\ nil) do
    if String.starts_with?(path, "/api/v2/") do
      body =
        case body do
          nil ->
            nil

          value when is_binary(value) ->
            value

          value ->
            Jason.encode!(
              if Map.has_key?(value, :data) or Map.has_key?(value, "data"),
                do: value,
                else: %{data: value}
            )
        end

      conn
      |> put_req_header("accept", "application/vnd.api+json")
      |> put_req_header("content-type", "application/vnd.api+json")
      |> dispatch(@endpoint, method, path, body)
    else
      conn |> dispatch(@endpoint, method, path, body)
    end
  end

  defp api_get(conn, path), do: api_request(conn, :get, path)
  defp api_post(conn, path, body), do: api_request(conn, :post, path, body)
  defp api_put(conn, path, body), do: api_request(conn, :put, path, body)
  defp api_patch(conn, path, body), do: api_request(conn, :patch, path, body)
  defp api_delete(conn, path), do: api_request(conn, :delete, path)
end
