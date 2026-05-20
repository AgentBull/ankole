defmodule BullX.EventBus.CommandTargetTest do
  use BullX.DataCase, async: false

  import ExUnit.CaptureLog

  alias BullX.EventBus

  alias BullX.EventBus.{
    Accepted,
    CommandTarget,
    EventRoutingRule,
    RoutingTable,
    RuleWriter,
    TargetSession,
    TargetSessionEntry
  }

  alias BullX.EventBus.CommandTarget.Registry, as: CommandRegistry
  alias BullX.EventBus.TargetSession.Worker
  alias BullX.Plugins.{Discovery, Registry}
  alias BullX.Repo

  setup do
    previous_targets = Application.get_env(:bullx, :event_bus_targets)
    previous_pid = Application.get_env(:bullx, :event_bus_test_pid)
    previous_adapter_registry = Application.get_env(:bullx, :event_bus_channel_adapter_registry)

    {:ok, plugin} =
      Discovery.discover_app(:eventbus_test_plugin, modules: [BullX.EventBus.TestAdapterPlugin])

    registry = :"command_target_adapter_registry_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Registry, plugins: [plugin], enabled_plugins: ["eventbus_test_plugin"], name: registry}
    )

    Application.put_env(:bullx, :event_bus_targets, ai_agent: BullX.EventBus.TestTarget)
    Application.put_env(:bullx, :event_bus_test_pid, self())
    Application.put_env(:bullx, :event_bus_channel_adapter_registry, registry)
    :ok = RoutingTable.refresh()

    on_exit(fn ->
      restore_env(:event_bus_targets, previous_targets)
      restore_env(:event_bus_test_pid, previous_pid)
      restore_env(:event_bus_channel_adapter_registry, previous_adapter_registry)
    end)

    :ok
  end

  test "stable command registry resolves handlers without dynamic module lookup" do
    assert {:ok, BullX.EventBus.CommandTarget.SystemCommands} =
             CommandRegistry.fetch_handler("bullx.system.status")

    assert {:error, {:command_handler_missing, "Elixir.System.halt"}} =
             CommandRegistry.fetch_handler("Elixir.System.halt")
  end

  test "status command reaches Command Target, replies through Channel Adapter, and closes" do
    {:ok, _fallback_rule} = create_ai_agent_fallback(priority: 1)

    assert {:ok, %Accepted{status: :accepted} = accepted} =
             EventBus.accept(command_event("status"))

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    assert_receive {:event_bus_adapter_delivered, source, reply_channel, outbound}

    assert source["id"] == "default"
    assert reply_channel["adapter"] == "eventbus_test"

    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) ==
             "BullX status:\nrunning: yes\nenv: test\nversion: #{app_version()}"

    refute_receive {:event_bus_target_called, _invocation, _entry}, 20

    session = Repo.get!(TargetSession, accepted.target_session_id)
    entry = Repo.get!(TargetSessionEntry, accepted.side_channel_entry_id)

    assert session.status == :closed
    assert session.last_processed_entry_seq == entry.entry_seq
  end

  test "command list returns the current EventBus command catalog" do
    assert {:ok, %Accepted{status: :accepted} = accepted} =
             EventBus.accept(command_event("command"))

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, outbound}

    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) ==
             Enum.join(
               [
                 "Available commands:",
                 "/command - list available commands",
                 "/status - show BullX runtime status, environment, and version",
                 "/new - start a new conversation session",
                 "/compress - compress previous conversation history",
                 "/retry - retry the previous assistant reply",
                 "/steer - add a steering note to the active generation",
                 "/stop - stop the active generation",
                 "/undo - undo the previous exchange"
               ],
               "\n"
             )
  end

  test "command list localizes aliases and descriptions" do
    BullX.I18n.with_locale(:"zh-Hans-CN", fn ->
      assert {:ok, %Accepted{status: :accepted} = accepted} =
               EventBus.accept(command_event("command"))

      assert :ok =
               Worker.perform(%Oban.Job{
                 args: %{"target_session_id" => accepted.target_session_id}
               })

      assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, outbound}

      assert get_in(outbound, ["content", Access.at(0), "body", "text"]) ==
               Enum.join(
                 [
                   "可用命令：",
                   "/命令 (/command) - 列出可用命令",
                   "/状态 (/status) - 显示 BullX 运行状态、环境和版本",
                   "/新会话 (/new) - 开启新的会话",
                   "/压缩 (/compress) - 压缩前面的历史对话",
                   "/重试 (/retry) - 重试上一条助手回复",
                   "/引导 (/steer) - 给当前正在生成的回复追加方向调整",
                   "/停止 (/stop) - 停止当前正在生成的回复",
                   "/撤销 (/undo) - 撤销上一轮对话"
                 ],
                 "\n"
               )
    end)
  end

  test "target redelivery uses the same outbound idempotency key" do
    assert {:ok, %Accepted{status: :accepted} = accepted} =
             EventBus.accept(command_event("status"))

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, first_outbound}

    session = Repo.get!(TargetSession, accepted.target_session_id)
    entry = Repo.get!(TargetSessionEntry, accepted.side_channel_entry_id)

    assert :ok = CommandTarget.handle_event(invocation(session), side_channel_entry(entry))
    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, second_outbound}

    assert first_outbound["id"] == second_outbound["id"]
  end

  test "EventBus does not parse slash text from ordinary message content" do
    assert {:error, :no_match} =
             EventBus.accept(
               command_event("status", %{
                 "id" => "ordinary-message-status",
                 "type" => "bullx.im.message.addressed",
                 "data" => %{
                   "content" => [%{"type" => "text", "text" => "/status"}],
                   "routing_facts" => %{}
                 }
               })
             )
  end

  test "system command routes are code-owned builtins merged ahead of PG rules" do
    assert Repo.aggregate(EventRoutingRule, :count) == 0

    assert {:ok, rules} = RoutingTable.snapshot()

    system_rules = Enum.take(rules, 2)

    assert Enum.map(system_rules, & &1.target_ref) == [
             "bullx.system.command_list",
             "bullx.system.status"
           ]

    assert Enum.map(system_rules, & &1.priority) == [-20, -19]
    assert Repo.aggregate(EventRoutingRule, :count) == 0
  end

  test "unmatched command events fall back to the matching addressed route" do
    {:ok, addressed_rule} = create_addressed_ai_agent_route(priority: 1, target_ref: "agent-1")

    assert {:ok, %Accepted{status: :accepted} = accepted} =
             EventBus.accept(command_event("stop"))

    assert accepted.rule_id == addressed_rule.id

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    assert_receive {:event_bus_target_called, invocation, entry}
    assert invocation.target_type == :ai_agent
    assert invocation.target_ref == "agent-1"
    assert entry.cloud_event["type"] == "bullx.command.invoked"
    assert entry.routing_context["type"] == "bullx.im.message.addressed"
    assert get_in(entry.cloud_event, ["data", "routing_facts", "command_name"]) == "stop"
  end

  test "unmatched command events are ignored with a warning when no addressed route matches" do
    log =
      capture_log(fn ->
        assert {:ok, %Accepted{status: :accepted_ignored} = accepted} =
                 EventBus.accept(command_event("stop"))

        assert accepted.rule_id == nil
        assert accepted.target_session_id == nil
        assert Repo.aggregate(TargetSession, :count) == 0
        assert Repo.aggregate(TargetSessionEntry, :count) == 0
      end)

    assert log =~ "EventBus command fallback ignored unmatched command"
  end

  defp create_ai_agent_fallback(opts) do
    RuleWriter.create_rule(%{
      name: "ai agent fallback",
      priority: Keyword.fetch!(opts, :priority),
      match_expr: "type == \"bullx.command.invoked\"",
      target_type: :ai_agent,
      target_ref: BullX.Ext.gen_uuid_v7(),
      scope_fields: ["channel.adapter", "channel.id", "scope.id"]
    })
  end

  defp create_addressed_ai_agent_route(opts) do
    RuleWriter.create_rule(%{
      name: "addressed ai agent",
      priority: Keyword.fetch!(opts, :priority),
      match_expr:
        ~s(type == "bullx.im.message.addressed" && channel.adapter == "eventbus_test" && channel.id == "default"),
      target_type: :ai_agent,
      target_ref: Keyword.fetch!(opts, :target_ref),
      scope_fields: ["channel.adapter", "channel.id", "scope.id"]
    })
  end

  defp command_event(command_name, overrides \\ %{}) do
    data =
      Map.merge(
        %{
          "content" => [
            %{"type" => "text", "text" => "/" <> command_name}
          ],
          "channel" => %{"adapter" => "eventbus_test", "id" => "default", "kind" => "dm"},
          "scope" => %{"id" => "scope-1", "thread_id" => nil},
          "actor" => %{
            "external_account_id" => "user-1",
            "display_name" => "Alice",
            "principal" => nil
          },
          "refs" => [],
          "reply_channel" => %{
            "adapter" => "eventbus_test",
            "channel_id" => "default",
            "scope_id" => "scope-1",
            "thread_id" => nil,
            "reply_to_external_id" => "provider-message-1"
          },
          "routing_facts" => %{
            "command_name" => command_name,
            "command_surface" => "slash_text",
            "command_args_kind" => "none"
          },
          "raw_ref" => nil
        },
        get_in(overrides, ["data"]) || %{}
      )

    %{
      "specversion" => "1.0",
      "id" => command_name <> "-event-1",
      "source" => "test://source/default",
      "type" => "bullx.command.invoked",
      "time" => "2026-05-18T10:00:00Z",
      "datacontenttype" => "application/json",
      "data" => data
    }
    |> Map.merge(Map.delete(overrides, "data"))
  end

  defp invocation(%TargetSession{} = session) do
    %{
      target_session_id: session.id,
      event_routing_rule_id: session.event_routing_rule_id,
      target_type: session.target_type,
      target_ref: session.target_ref,
      scope_key: session.scope_key
    }
  end

  defp side_channel_entry(%TargetSessionEntry{} = entry) do
    %{
      id: entry.id,
      entry_seq: entry.entry_seq,
      target_session_id: entry.target_session_id,
      event_source: entry.event_source,
      event_id: entry.event_id,
      cloud_event: entry.cloud_event,
      routing_context: entry.routing_context,
      appended_at: entry.appended_at
    }
  end

  defp app_version do
    :bullx
    |> Application.spec(:vsn)
    |> List.to_string()
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
