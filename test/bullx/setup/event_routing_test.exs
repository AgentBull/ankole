defmodule BullX.Setup.EventRoutingTest do
  use BullX.DataCase, async: false

  alias BullX.EventBus.{EventRoutingRule, RoutingContext, RoutingTable, RuleWriter}
  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.Repo
  alias BullX.Setup.{AIAgents, EventRouting}

  @sources_key "bullx.plugins.feishu.eventbus_sources"

  setup do
    ReqLLM.Providers.initialize()
    PluginProviders.sync_builtin_extensions()
    allow_process(BullX.Config.Cache)
    allow_process(BullX.LLM.Catalog.Cache)

    :ok =
      BullX.Config.put(
        @sources_key,
        Jason.encode!([
          %{
            "id" => "main",
            "app_id" => "cli_setup",
            "app_secret" => "app_secret",
            "enabled" => true,
            "domain" => "feishu",
            "im_listen_mode" => "all_messages",
            "start_transport" => false
          }
        ])
      )

    assert {:ok, %{sources: [%{id: "main", ready: true}]}} =
             Feishu.SourceSetup.reconcile_sources()

    {:ok, _provider} =
      Writer.put_provider(%{
        provider_id: "openai_proxy",
        req_llm_provider: "openai",
        api_key: "sk-test",
        provider_options: %{"auth_mode" => "api_key"}
      })

    BullX.LLM.Catalog.Cache.refresh_all()

    on_exit(fn ->
      BullX.Config.Cache.delete_raw(@sources_key)
      _ = Feishu.SourceSetup.reconcile_sources()
      BullX.LLM.Catalog.Cache.refresh_all()
    end)

    :ok
  end

  test "save creates one broad source-scoped BullX route for the setup AIAgent" do
    agent_id = setup_agent_id()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_principal_id: agent_id})

    assert rule.name == "setup.default.feishu.main.channel"

    assert rule.match_expr ==
             "type.startsWith(\"bullx.\") && channel.adapter == \"feishu\" && channel.id == \"main\""

    assert rule.target_type == "ai_agent"
    assert rule.target_ref == agent_id
    assert Repo.aggregate(EventRoutingRule, :count) == 1

    assert_setup_rule_matches("bullx.im.message.addressed", agent_id)
    assert_setup_rule_matches("bullx.im.message.ambient", agent_id)
    assert_setup_rule_matches("bullx.action.submitted", agent_id)
    assert_setup_rule_matches("bullx.command.invoked", agent_id, %{"command_name" => "new"})

    assert {:ok, {:matched, system_rule, _diagnostics}} =
             RoutingTable.match(
               routing_context("bullx.command.invoked", %{"command_name" => "status"})
             )

    assert system_rule.target_type == :command
    assert system_rule.target_ref == "bullx.system.status"
  end

  test "status projects the pending setup route without leaking raw runtime internals" do
    agent_id = setup_agent_id()

    status = EventRouting.status(%{agent_principal_id: agent_id})

    refute status.complete?
    assert status.state == "missing"
    assert status.reason == "setup_rule_missing"
    assert status.source.adapter_id == "feishu"
    assert status.source.source_id == "main"
    assert status.source.runtime.ready == true
    refute Map.has_key?(status.source, :setup_module)
    assert status.target.principal_id == agent_id
    assert status.expected_rule.name == "setup.default.feishu.main.channel"
    assert status.expected_rule.target_type == "ai_agent"
    assert status.expected_rule.target_ref == agent_id
    assert {:ok, _json} = Jason.encode(status)
  end

  test "status reports a live route after save" do
    agent_id = setup_agent_id()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_principal_id: agent_id})

    status = EventRouting.status(%{agent_principal_id: agent_id})

    assert status.complete?
    assert status.state == "live"
    assert status.reason == nil
    assert status.live_rule.name == rule.name
    assert status.conflict_rule == nil
  end

  test "save migrates legacy split setup routes instead of adding another route" do
    agent_id = setup_agent_id()

    {:ok, legacy_addressed} =
      RuleWriter.create_rule(%{
        name: "setup.default.feishu.main.addressed",
        priority: 1000,
        match_expr:
          ~s(type == "bullx.im.message.addressed" && channel.adapter == "feishu" && channel.id == "main"),
        target_type: :ai_agent,
        target_ref: agent_id,
        scope_fields: ["channel.adapter", "channel.id", "scope.id"]
      })

    {:ok, _legacy_ambient} =
      RuleWriter.create_rule(%{
        name: "setup.default.feishu.main.ambient",
        priority: 1001,
        match_expr:
          ~s(type == "bullx.im.message.ambient" && channel.adapter == "feishu" && channel.id == "main"),
        target_type: :ai_agent,
        target_ref: agent_id,
        scope_fields: ["channel.adapter", "channel.id", "scope.id"]
      })

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_principal_id: agent_id})

    assert rule.id == legacy_addressed.id
    assert rule.name == "setup.default.feishu.main.channel"
    assert rule.priority == 1000

    assert rule.match_expr ==
             "type.startsWith(\"bullx.\") && channel.adapter == \"feishu\" && channel.id == \"main\""

    assert Repo.aggregate(EventRoutingRule, :count) == 1
    refute Repo.get_by(EventRoutingRule, name: "setup.default.feishu.main.addressed")
    refute Repo.get_by(EventRoutingRule, name: "setup.default.feishu.main.ambient")
  end

  defp setup_agent_id do
    assert {:ok, %{agent: %{principal_id: agent_id}}} =
             AIAgents.save(%{
               "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
               "display_name" => "BullX Agent",
               "mission" => "Handle setup-routed messages."
             })

    agent_id
  end

  defp assert_setup_rule_matches(type, agent_id, routing_facts \\ %{}) do
    assert {:ok, {:matched, rule, _diagnostics}} =
             RoutingTable.match(routing_context(type, routing_facts))

    assert rule.name == "setup.default.feishu.main.channel"
    assert rule.target_type == :ai_agent
    assert rule.target_ref == agent_id
  end

  defp routing_context(type, routing_facts) do
    %{
      "id" => "#{type}-event",
      "source" => "feishu://main/test",
      "type" => type,
      "time" => "2026-05-20T00:00:00Z",
      "data" => %{
        "channel" => %{"adapter" => "feishu", "id" => "main", "kind" => "group"},
        "scope" => %{"id" => "scope-1", "thread_id" => nil},
        "actor" => %{"external_account_id" => "ou_1"},
        "refs" => [],
        "reply_channel" => %{"adapter" => "feishu", "channel_id" => "main"},
        "routing_facts" => routing_facts
      }
    }
    |> RoutingContext.project()
  end

  defp allow_process(name) do
    case GenServer.whereis(name) do
      pid when is_pid(pid) -> Ecto.Adapters.SQL.Sandbox.allow(BullX.Repo, self(), pid)
      nil -> :ok
    end
  end
end
