defmodule BullX.Setup.EventRoutingTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.MailBox.{DeliveryRule, Matcher, RoutingContext}
  alias BullX.Repo
  alias BullX.Setup.{AIAgents, EventRouting}

  @sources_key "bullx.plugins.feishu.im_gateway_sources"

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

  test "save creates one source-scoped MailBox delivery rule for the setup AIAgent" do
    agent_id = setup_agent_id()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_principal_id: agent_id})

    assert rule.name == "setup.default.feishu.main.channel"

    assert rule.match_expr ==
             "type.startsWith(\"bullx.im.message.\") && channel.adapter == \"feishu\" && channel.id == \"main\""

    assert rule.target_type == "ai_agent"
    assert rule.target_ref == agent_id
    assert rule.receiver_type == "ai_agent"
    assert rule.receiver_ref == agent_id
    assert rule.attention == "addressed"
    assert Repo.aggregate(DeliveryRule, :count) == 1

    assert_setup_rule_matches("bullx.im.message.received", agent_id)
    refute_setup_rule_matches("bullx.action.submitted")
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

  test "save updates the existing MailBox delivery rule instead of adding another rule" do
    agent_id = setup_agent_id()

    existing =
      %DeliveryRule{}
      |> DeliveryRule.changeset(%{
        name: "setup.default.feishu.main.channel",
        priority: 1000,
        match_expr: ~s(type == "bullx.im.message.received"),
        receiver_type: "blackhole",
        receiver_ref: "old",
        attention: :ambient,
        available_delay_ms: 0,
        metadata: %{}
      })
      |> Repo.insert!()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_principal_id: agent_id})

    assert rule.id == existing.id
    assert rule.name == "setup.default.feishu.main.channel"
    assert rule.priority == 1000

    assert rule.match_expr ==
             "type.startsWith(\"bullx.im.message.\") && channel.adapter == \"feishu\" && channel.id == \"main\""

    assert rule.receiver_type == "ai_agent"
    assert rule.receiver_ref == agent_id
    assert rule.attention == "addressed"
    assert Repo.aggregate(DeliveryRule, :count) == 1
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
    rule = Repo.get_by!(DeliveryRule, name: "setup.default.feishu.main.channel")

    assert {:ok, {:matched, _rule_id, _diagnostics}} =
             Matcher.match([rule], routing_context(type, routing_facts))

    assert rule.name == "setup.default.feishu.main.channel"
    assert rule.receiver_type == "ai_agent"
    assert rule.receiver_ref == agent_id
  end

  defp refute_setup_rule_matches(type, routing_facts \\ %{}) do
    rule = Repo.get_by!(DeliveryRule, name: "setup.default.feishu.main.channel")

    assert {:ok, {:no_match, _diagnostics}} =
             Matcher.match([rule], routing_context(type, routing_facts))
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
        "reply_address" => %{"adapter" => "feishu", "channel_id" => "main"},
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
