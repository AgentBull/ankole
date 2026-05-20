defmodule BullX.EventBus.CoreTest do
  use BullX.DataCase, async: false

  import Ecto.Query

  alias BullX.EventBus

  alias BullX.EventBus.{
    Accepted,
    AppendFailed,
    RoutingContext,
    RuleWriter,
    TargetSession,
    TargetSessionEntry
  }

  alias BullX.EventBus.TargetSession.Worker
  alias BullX.Repo

  setup do
    previous_targets = Application.get_env(:bullx, :event_bus_targets)
    previous_pid = Application.get_env(:bullx, :event_bus_test_pid)

    Application.put_env(:bullx, :event_bus_targets, ai_agent: BullX.EventBus.TestTarget)
    Application.put_env(:bullx, :event_bus_test_pid, self())

    on_exit(fn ->
      restore_env(:event_bus_targets, previous_targets)
      restore_env(:event_bus_test_pid, previous_pid)
    end)

    :ok
  end

  test "accepts Blackhole without TargetSession, entry, or Oban job" do
    {:ok, rule} =
      RuleWriter.create_rule(%{
        name: "ignore all",
        priority: 10,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :blackhole
      })

    assert {:ok, %Accepted{status: :accepted_ignored, rule_id: rule_id}} =
             EventBus.accept(event())

    assert rule_id == rule.id
    assert Repo.aggregate(TargetSession, :count) == 0
    assert Repo.aggregate(TargetSessionEntry, :count) == 0
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "Blackhole routing bypasses dedupe even when the event was previously accepted" do
    target_ref = BullX.Ext.gen_uuid_v7()
    event = event(%{"id" => "rerouted-to-blackhole"})

    {:ok, _rule} =
      RuleWriter.create_rule(%{
        name: "first route",
        priority: 10,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :ai_agent,
        target_ref: target_ref,
        scope_fields: ["channel.adapter", "channel.id", "scope.id"]
      })

    assert {:ok, %Accepted{status: :accepted}} = EventBus.accept(event)

    {:ok, blackhole} =
      RuleWriter.create_rule(%{
        name: "ignore later",
        priority: 5,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :blackhole
      })

    assert {:ok, %Accepted{status: :accepted_ignored, rule_id: rule_id}} = EventBus.accept(event)
    assert rule_id == blackhole.id
    assert Repo.aggregate(TargetSessionEntry, :count) == 1
  end

  test "accepts a non-Blackhole Event, dedupes redelivery, and keeps payload out of Oban args" do
    target_ref = BullX.Ext.gen_uuid_v7()

    {:ok, rule} =
      RuleWriter.create_rule(%{
        name: "route message",
        priority: 20,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :ai_agent,
        target_ref: target_ref,
        scope_fields: ["channel.adapter", "channel.id", "scope.id", "scope.thread_id"]
      })

    assert {:ok, %Accepted{status: :accepted} = first} = EventBus.accept(event())
    assert first.rule_id == rule.id
    assert first.target_session_id
    assert first.side_channel_entry_id

    assert {:ok, %Accepted{status: :duplicate} = duplicate} = EventBus.accept(event())
    assert duplicate.target_session_id == first.target_session_id
    assert duplicate.side_channel_entry_id == first.side_channel_entry_id

    assert Repo.aggregate(TargetSession, :count) == 1
    assert Repo.aggregate(TargetSessionEntry, :count) == 1

    job = Repo.one!(from j in Oban.Job, where: j.worker == "BullX.EventBus.TargetSession.Worker")
    assert job.args == %{"target_session_id" => first.target_session_id}
  end

  test "reused active TargetSession replaces stale Oban job association" do
    target_ref = BullX.Ext.gen_uuid_v7()

    {:ok, _rule} =
      RuleWriter.create_rule(%{
        name: "route with stale job",
        priority: 25,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :ai_agent,
        target_ref: target_ref,
        scope_fields: ["channel.adapter", "channel.id", "scope.id"]
      })

    assert {:ok, %Accepted{status: :accepted} = first} =
             EventBus.accept(event(%{"id" => "stale-job-1"}))

    session = Repo.get!(TargetSession, first.target_session_id)
    old_job_id = session.oban_job_id
    assert is_integer(old_job_id)

    Repo.update_all(from(j in Oban.Job, where: j.id == ^old_job_id), set: [state: "completed"])

    assert {:ok, %Accepted{status: :accepted, target_session_id: target_session_id}} =
             EventBus.accept(event(%{"id" => "stale-job-2"}))

    assert target_session_id == first.target_session_id
    refreshed = Repo.get!(TargetSession, first.target_session_id)
    assert refreshed.oban_job_id != old_job_id

    assert Repo.exists?(
             from(j in Oban.Job,
               where: j.id == ^refreshed.oban_job_id,
               where: j.state in ["available", "scheduled", "executing", "retryable"]
             )
           )
  end

  test "TargetSession worker invokes Target one entry at a time and advances progress before close" do
    target_ref = BullX.Ext.gen_uuid_v7()

    {:ok, _rule} =
      RuleWriter.create_rule(%{
        name: "one shot",
        priority: 30,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :ai_agent,
        target_ref: target_ref,
        scope_fields: ["channel.adapter", "channel.id", "scope.id"]
      })

    {:ok, %Accepted{} = accepted} = EventBus.accept(event(%{"id" => "worker-event"}))

    assert :ok =
             Worker.perform(%Oban.Job{args: %{"target_session_id" => accepted.target_session_id}})

    assert_receive {:event_bus_target_called, invocation, entry}
    assert invocation.target_session_id == accepted.target_session_id
    assert entry.event_id == "worker-event"

    session = Repo.get!(TargetSession, accepted.target_session_id)
    entry = Repo.get!(TargetSessionEntry, accepted.side_channel_entry_id)

    assert session.last_processed_entry_seq == entry.entry_seq
    assert session.status == :closed
  end

  test "TargetSession worker keeps a close-requested lane reusable during idle grace" do
    previous_event_bus_config = Application.get_env(:bullx, :event_bus, [])

    Application.put_env(
      :bullx,
      :event_bus,
      Keyword.put(previous_event_bus_config, :target_session_idle_grace_ms, 200)
    )

    on_exit(fn -> restore_env(:event_bus, previous_event_bus_config) end)

    target_ref = BullX.Ext.gen_uuid_v7()

    {:ok, _rule} =
      RuleWriter.create_rule(%{
        name: "idle grace reuse",
        priority: 35,
        match_expr: "type == \"bullx.im.message.addressed\"",
        target_type: :ai_agent,
        target_ref: target_ref,
        scope_fields: ["channel.adapter", "channel.id", "scope.id"]
      })

    assert {:ok, %Accepted{} = first} = EventBus.accept(event(%{"id" => "grace-event-1"}))

    task =
      Task.async(fn ->
        Worker.perform(%Oban.Job{args: %{"target_session_id" => first.target_session_id}})
      end)

    assert_receive {:event_bus_target_called, _first_invocation, first_entry}
    assert first_entry.event_id == "grace-event-1"

    assert {:ok, %Accepted{} = second} = EventBus.accept(event(%{"id" => "grace-event-2"}))
    assert second.target_session_id == first.target_session_id

    assert_receive {:event_bus_target_called, _second_invocation, second_entry}
    assert second_entry.event_id == "grace-event-2"

    assert :ok = Task.await(task, 1_000)

    session = Repo.get!(TargetSession, first.target_session_id)
    second_entry = Repo.get!(TargetSessionEntry, second.side_channel_entry_id)

    assert session.last_processed_entry_seq == second_entry.entry_seq
    assert session.status == :closed
  end

  test "scope resolution failure returns AppendFailed without appending" do
    {:ok, _rule} =
      RuleWriter.create_rule(%{
        name: "missing fact",
        priority: 40,
        match_expr: "true",
        target_type: :ai_agent,
        target_ref: BullX.Ext.gen_uuid_v7(),
        scope_fields: ["routing_facts.missing"]
      })

    assert {:error, %AppendFailed{code: :scope_resolution_failed}} = EventBus.accept(event())
    assert Repo.aggregate(TargetSessionEntry, :count) == 0
  end

  test "active rules cannot target an unconfigured handler" do
    assert {:error, changeset} =
             RuleWriter.create_rule(%{
               name: "workflow before handler",
               priority: 45,
               match_expr: "true",
               target_type: :workflow,
               target_ref: "workflow:missing",
               scope_fields: []
             })

    assert {"has no configured handler", _metadata} = changeset.errors[:target_type]
  end

  test "inactive rules may keep future target configuration without entering the snapshot" do
    assert {:ok, rule} =
             RuleWriter.create_rule(%{
               name: "inactive future workflow",
               active: false,
               priority: 46,
               match_expr: "true",
               target_type: :workflow,
               target_ref: "workflow:future",
               scope_fields: []
             })

    assert {:ok, rules} = BullX.EventBus.RoutingTable.snapshot()
    refute Enum.any?(rules, &(&1.id == rule.id))
  end

  test "RoutingContext omits subject and CloudEvents extensions" do
    context =
      event(%{"subject" => "debug", "traceparent" => "trace"})
      |> RoutingContext.project()

    refute Map.has_key?(context, "subject")
    refute Map.has_key?(context, "traceparent")

    assert context["event"]["identity"] == %{
             "source" => "feishu://connected-realm/default",
             "id" => "event-1"
           }
  end

  defp event(overrides \\ %{}) do
    Map.merge(
      %{
        "specversion" => "1.0",
        "id" => "event-1",
        "source" => "feishu://connected-realm/default",
        "type" => "bullx.im.message.addressed",
        "time" => "2026-05-17T10:00:00Z",
        "datacontenttype" => "application/json",
        "data" => %{
          "content" => [%{"type" => "text", "text" => "hello"}],
          "channel" => %{"adapter" => "feishu", "id" => "default", "kind" => "dm"},
          "scope" => %{"id" => "chat-1", "thread_id" => nil},
          "actor" => %{
            "external_account_id" => "user-1",
            "display_name" => "Alice",
            "principal" => nil
          },
          "refs" => [],
          "reply_channel" => %{
            "adapter" => "feishu",
            "channel_id" => "default",
            "scope_id" => "chat-1",
            "thread_id" => nil
          },
          "routing_facts" => %{},
          "raw_ref" => nil
        }
      },
      overrides
    )
  end

  defp restore_env(key, nil), do: Application.delete_env(:bullx, key)
  defp restore_env(key, value), do: Application.put_env(:bullx, key, value)
end
