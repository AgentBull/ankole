defmodule BullX.EventBus.CommandTargetTest do
  use BullX.DataCase, async: false

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

  test "command list returns exactly the current system command catalog" do
    assert {:ok, %Accepted{status: :accepted} = accepted} =
             EventBus.accept(command_event("command"))

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    assert_receive {:event_bus_adapter_delivered, _source, _reply_channel, outbound}

    assert get_in(outbound, ["content", Access.at(0), "body", "text"]) ==
             "Available commands:\n/command - list available system commands\n/status - show BullX runtime status, environment, and version"
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
    assert Enum.all?(system_rules, &(&1.window_type == :new_per_event))
    assert Repo.aggregate(EventRoutingRule, :count) == 0
  end

  defp create_ai_agent_fallback(opts) do
    RuleWriter.create_rule(%{
      name: "ai agent fallback",
      priority: Keyword.fetch!(opts, :priority),
      match_expr: "type == \"bullx.command.invoked\"",
      target_type: :ai_agent,
      target_ref: BullX.Ext.gen_uuid_v7(),
      scope_fields: ["channel.adapter", "channel.id", "scope.id"],
      window_type: :new_per_event
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
      scope_key: session.scope_key,
      window_key: session.window_key
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
