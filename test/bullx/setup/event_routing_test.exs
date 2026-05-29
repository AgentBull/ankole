defmodule BullX.Setup.EventRoutingTest do
  use BullX.DataCase, async: false

  alias BullX.LLM.{PluginProviders, Writer}
  alias BullX.MailBox.{DeliveryRule, Matcher, RoutingContext}
  alias BullX.Repo
  alias BullX.Setup.{AIAgents, EventRouting}

  @sources_key "bullx.plugins.feishu.im_gateway_sources"
  @setup_match_expr [
                      "(",
                      ~s(type == "bullx.message.received"),
                      " || ",
                      ~s(type == "bullx.message.edited"),
                      " || ",
                      ~s(type == "bullx.message.recalled"),
                      " || ",
                      ~s(type == "bullx.message.deleted"),
                      " || ",
                      ~s(type == "bullx.command.invoked"),
                      ") && ",
                      ~s(channel.adapter == "feishu"),
                      " && ",
                      ~s(channel.id == "main")
                    ]
                    |> IO.iodata_to_binary()

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
            "group_message_mode" => "engage_all",
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
    agent_uid = setup_agent_uid()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_uid: agent_uid})

    assert rule.name == "setup.default.feishu.main.channel"

    assert rule.match_expr == @setup_match_expr

    assert rule.target_type == "agent"
    assert rule.target_ref == agent_uid
    assert rule.agent_uid == agent_uid
    assert Repo.aggregate(DeliveryRule, :count) == 1

    assert_setup_rule_matches("bullx.message.received", agent_uid)
    assert_setup_rule_matches("bullx.message.edited", agent_uid)
    assert_setup_rule_matches("bullx.message.recalled", agent_uid)
    assert_setup_rule_matches("bullx.message.deleted", agent_uid)
    assert_setup_rule_matches("bullx.command.invoked", agent_uid)
    refute_setup_rule_matches("bullx.action.submitted")
    refute_setup_rule_matches("bullx.agent.abort")
    refute_setup_rule_matches("bullx.reaction.changed")
  end

  test "status projects the pending setup route without leaking raw runtime internals" do
    agent_uid = setup_agent_uid()

    status = EventRouting.status(%{agent_uid: agent_uid})

    refute status.complete?
    assert status.state == "missing"
    assert status.reason == "setup_rule_missing"
    assert status.source.adapter_id == "feishu"
    assert status.source.source_id == "main"
    assert status.source.runtime.ready == true
    refute Map.has_key?(status.source, :setup_module)
    assert status.target.principal_uid == agent_uid
    assert status.expected_rule.name == "setup.default.feishu.main.channel"
    assert status.expected_rule.target_type == "agent"
    assert status.expected_rule.target_ref == agent_uid
    assert {:ok, _json} = Jason.encode(status)
  end

  test "status reports a live route after save" do
    agent_uid = setup_agent_uid()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_uid: agent_uid})

    status = EventRouting.status(%{agent_uid: agent_uid})

    assert status.complete?
    assert status.state == "live"
    assert status.reason == nil
    assert status.live_rule.name == rule.name
    assert status.conflict_rule == nil
  end

  test "save updates the legacy IM MailBox delivery rule instead of adding another rule" do
    agent_uid = setup_agent_uid()

    existing =
      %DeliveryRule{}
      |> DeliveryRule.changeset(%{
        name: "setup.default.feishu.main.channel",
        priority: 1000,
        match_expr:
          ~S|type.startsWith("bullx.im.message.") && channel.adapter == "feishu" && channel.id == "main"|,
        agent_uid: ai_agent_uid!("old-route"),
        metadata: %{}
      })
      |> Repo.insert!()

    assert {:ok, %{rule: rule}} = EventRouting.save(%{agent_uid: agent_uid})

    assert rule.id == existing.id
    assert rule.name == "setup.default.feishu.main.channel"
    assert rule.priority == 1000

    assert rule.match_expr == @setup_match_expr

    assert rule.agent_uid == agent_uid
    assert Repo.aggregate(DeliveryRule, :count) == 1
  end

  defp setup_agent_uid do
    assert {:ok, %{agent: %{principal_uid: agent_uid}}} =
             AIAgents.save(%{
               "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
               "display_name" => "BullX Agent",
               "mission" => "Handle setup-routed messages."
             })

    agent_uid
  end

  defp assert_setup_rule_matches(type, agent_uid, routing_facts \\ %{}) do
    rule = Repo.get_by!(DeliveryRule, name: "setup.default.feishu.main.channel")

    assert {:ok, {:matched, _rule_id, _diagnostics}} =
             Matcher.match([rule], routing_context(type, routing_facts))

    assert rule.name == "setup.default.feishu.main.channel"
    assert rule.agent_uid == agent_uid
  end

  defp ai_agent_uid!(uid) do
    {:ok, %{principal: principal}} =
      BullX.Principals.create_agent(%{
        principal: %{uid: "setup-agent-#{uid}", display_name: "Setup Agent #{uid}"},
        agent: %{
          profile: %{
            "ai_agent" => %{
              "main_llm" => %{"provider_id" => "openai_proxy", "model" => "gpt-test"},
              "mission" => "Handle setup routing tests."
            }
          }
        }
      })

    principal.uid
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
