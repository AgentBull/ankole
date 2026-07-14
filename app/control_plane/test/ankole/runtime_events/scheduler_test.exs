defmodule Ankole.RuntimeEvents.SchedulerTest do
  use Ankole.SignalsGateway.ActorRuntimeCase

  alias Ankole.AIGateway.StatefulResponses
  alias Ankole.PluginFixtures.MockSignalProvider.Outbox, as: MockOutbox
  alias Ankole.PluginFixtures.MockSignalProviderPlugin
  alias Ankole.Plugins.Spec
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.RuntimeEvents.Event
  alias Ankole.RuntimeEvents.Scheduler
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.OutboxEntry

  setup :use_mock_signal_provider_plugin

  describe "steady-state sweep" do
    test "dispatches a due outbox that missed its notification" do
      capture_mock_outbox()
      %{message: message, turn_ref: turn_ref} = start_im_visible_response_run()

      assert {:ok, completed} =
               StatefulResponses.commit_complete(message, assistant_content("sweep final"))

      assert_turn_completed(turn_ref, completed)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      _scheduler = start_scheduler!(sweep_interval_ms: 50)

      key = outbox.outbound_key
      assert_receive {:mock_provider_outbox_sent, %OutboxEntry{outbound_key: ^key}}, 1_000

      assert %Entry{ai_message_id: ai_message_id, text: "sweep final"} =
               wait_for_entry!(completed.id)

      assert ai_message_id == completed.id
    end

    test "keeps existing deadline timers alive when sweep snapshot fails" do
      capture_mock_outbox()
      parent = self()
      %{message: message, turn_ref: turn_ref} = start_im_visible_response_run()

      assert {:ok, _completed} =
               StatefulResponses.commit_complete(message, assistant_content("deadline final"))

      assert_turn_completed(turn_ref, message)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      scheduler = start_scheduler!(sweep_interval_ms: 40)

      :sys.replace_state(scheduler, fn state ->
        Map.put(state, :snapshot_events, fn ->
          send(parent, :snapshot_called)
          raise "snapshot unavailable"
        end)
      end)

      Scheduler.notify(scheduler, RuntimeEvents.outbox_due_channel(), %{
        "agent_uid" => outbox.agent_uid,
        "binding_name" => outbox.binding_name,
        "outbound_key" => outbox.outbound_key,
        "due_at" =>
          DateTime.utc_now(:microsecond)
          |> DateTime.add(120, :millisecond)
          |> RuntimeEvents.encode_datetime()
      })

      assert_receive :snapshot_called, 500
      assert_receive :snapshot_called, 500

      key = outbox.outbound_key
      assert_receive {:mock_provider_outbox_sent, %OutboxEntry{outbound_key: ^key}}, 1_000
      assert scheduler_pid = Process.whereis(scheduler)
      assert Process.alive?(scheduler_pid)
    end

    test "does not redeliver an outbox already dispatched by notification" do
      capture_mock_outbox()
      %{message: message, turn_ref: turn_ref} = start_im_visible_response_run()

      assert {:ok, _completed} =
               StatefulResponses.commit_complete(message, assistant_content("single delivery"))

      assert_turn_completed(turn_ref, message)

      outbox = Repo.get_by!(OutboxEntry, outbound_key: "ai-reply:#{message.id}")
      scheduler = start_scheduler!(sweep_interval_ms: 300)

      Scheduler.notify(scheduler, RuntimeEvents.outbox_due_channel(), %{
        "agent_uid" => outbox.agent_uid,
        "binding_name" => outbox.binding_name,
        "outbound_key" => outbox.outbound_key,
        "due_at" => nil
      })

      key = outbox.outbound_key
      assert_receive {:mock_provider_outbox_sent, %OutboxEntry{outbound_key: ^key}}, 1_000
      refute_receive {:mock_provider_outbox_sent, %OutboxEntry{outbound_key: ^key}}, 500
    end

    test "repeated sweeps keep one timer per runtime event key" do
      parent = self()
      scheduler = start_scheduler!(sweep_interval_ms: 40)
      due_at = DateTime.add(DateTime.utc_now(:microsecond), 2, :second)
      channel = RuntimeEvents.outbox_due_channel()
      timer_key = {channel, "agent-a", "mock", "future-outbox"}

      payload = %{
        "agent_uid" => "agent-a",
        "binding_name" => "mock",
        "outbound_key" => "future-outbox",
        "due_at" => RuntimeEvents.encode_datetime(due_at)
      }

      :sys.replace_state(scheduler, fn state ->
        Map.put(state, :snapshot_events, fn ->
          send(parent, :snapshot_called)
          [{channel, payload}]
        end)
      end)

      assert_receive :snapshot_called, 500
      assert_receive :snapshot_called, 500

      state = :sys.get_state(scheduler)
      assert map_size(state.timers) == 1
      assert %{event: %Event{timer_key: ^timer_key}} = Map.fetch!(state.timers, timer_key)
    end
  end

  test "rejects invalid sweep intervals" do
    previous_flag = Process.flag(:trap_exit, true)

    try do
      assert {:error, {:invalid_sweep_interval_ms, 0}} =
               Scheduler.start_link(name: unique_name("scheduler"), sweep_interval_ms: 0)
    after
      Process.flag(:trap_exit, previous_flag)
    end
  end

  test "rounds future deadlines up so handlers never run before the durable due time" do
    now = ~U[2026-07-13 15:37:57.146641Z]

    assert Scheduler.delay_ms_until(DateTime.add(now, 1, :microsecond), now) == 1
    assert Scheduler.delay_ms_until(DateTime.add(now, 999, :microsecond), now) == 1
    assert Scheduler.delay_ms_until(DateTime.add(now, 1_000, :microsecond), now) == 1
    assert Scheduler.delay_ms_until(DateTime.add(now, 1_001, :microsecond), now) == 2
    assert Scheduler.delay_ms_until(DateTime.add(now, -1, :microsecond), now) == 0
  end

  defp capture_mock_outbox do
    MockOutbox.put_recipient(self())

    on_exit(fn ->
      MockOutbox.delete_recipient()
    end)
  end

  defp start_scheduler!(opts) do
    suffix = System.unique_integer([:positive])
    task_supervisor = unique_name("task_supervisor_#{suffix}")
    scheduler = unique_name("scheduler_#{suffix}")

    start_supervised!({Task.Supervisor, name: task_supervisor})

    start_supervised!(
      {Scheduler, Keyword.merge(opts, name: scheduler, task_supervisor: task_supervisor)}
    )

    scheduler
  end

  defp start_im_visible_response_run do
    %{principal: agent} = agent_fixture()
    binding_fixture(agent.uid, "mock", :ignore, adapter: "mock-provider")
    route = unique_route()
    :ok = Broker.register_local_worker(route, self())
    on_exit(fn -> Broker.unregister_local_worker(route) end)
    assert {:ok, _worker} = admit_worker(route)

    assert {:ok, %{actor_event: event}} =
             emit_entry(
               agent.uid,
               "mock",
               group_entry(%{
                 explicit: true,
                 source_event_id: "evt-#{System.unique_integer([:positive])}",
                 source_entry_id: "msg-#{System.unique_integer([:positive])}"
               }),
               now: @base_time
             )

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_events_once(
               now: DateTime.add(@base_time, 1, :second),
               lease_seconds: @long_lease_seconds
             )

    assert_receive {:actor_lane, envelope}
    turn_ref = envelope["body"]["turn_start"]["turn"]

    assert {:ok, [_delivery]} =
             ActorRuntime.handle_turn_accepted(%{
               "turn_accepted" => %{"turn" => turn_ref}
             })

    assert {:ok, conversation} =
             StatefulResponses.ensure_conversation(agent.uid, event.session_id)

    assert {:ok, message} =
             StatefulResponses.start_response_run(%{
               subject_uid: agent.uid,
               conversation_id: conversation.id,
               metadata: %{"request_metadata" => %{"actor_event_id" => event.id}}
             })

    %{agent: agent, event: event, message: message, turn_ref: turn_ref}
  end

  defp assert_turn_completed(turn_ref, message) do
    assert {:ok, %{status: :turn_completed}} =
             ActorRuntime.handle_turn_completed(%{
               "turn_completed" => %{
                 "turn" => turn_ref,
                 "final_response_id" => "resp_#{message.id}",
                 "outcome" => "loop_finished"
               }
             })
  end

  defp assistant_content(text) do
    [
      %{
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "output_text", "text" => text}]
      }
    ]
  end

  defp wait_for_entry!(ai_message_id, attempts_left \\ 20)

  defp wait_for_entry!(ai_message_id, attempts_left) when attempts_left > 0 do
    case Repo.get_by(Entry, ai_message_id: ai_message_id) do
      %Entry{} = entry ->
        entry

      nil ->
        Process.sleep(10)
        wait_for_entry!(ai_message_id, attempts_left - 1)
    end
  end

  defp wait_for_entry!(ai_message_id, 0) do
    flunk("expected final reply mirror for ai_message_id=#{ai_message_id}")
  end

  defp use_mock_signal_provider_plugin(_context) do
    original_state = :sys.get_state(Ankole.Plugins.Registry)
    {:ok, spec} = Spec.from_module(MockSignalProviderPlugin)

    :sys.replace_state(Ankole.Plugins.Registry, fn _state ->
      %{
        discovered: %{spec.id => spec},
        active: %{spec.id => spec},
        disabled_ids: MapSet.new()
      }
    end)

    on_exit(fn ->
      :sys.replace_state(Ankole.Plugins.Registry, fn _state -> original_state end)
    end)

    :ok
  end

  defp unique_name(prefix) do
    :"runtime_events_scheduler_test_#{prefix}_#{System.unique_integer([:positive])}"
  end
end
