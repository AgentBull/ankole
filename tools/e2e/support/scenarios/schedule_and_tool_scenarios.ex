defmodule Ankole.E2E.Scenarios.ScheduleAndTool do
  @moduledoc """
  Schedule, file, and computer-tool scenarios for the Docker worker suites.
  """

  import ExUnit.Assertions
  import Ecto.Query

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      cron_event_for_schedule!: 1,
      deadline: 1,
      wait_until: 2,
      wait_for_completed_actor_event_message: 3,
      wait_for_completed_final_reply: 3,
      wait_for_completed_outbox: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.{CronSchedule, ScheduledEvent}
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.Channel
  alias Ankole.SignalsGateway.Entry
  alias Ankole.SignalsGateway.OutboxEntry

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def run_checkback_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_checkback_tool_1",
               message_id: "om_checkback_tool_1",
               chat_id: "oc_chaos_schedule",
               text:
                 "@_user_1 Run CHAOS_CHECKBACK_TOOL. Use the schedule tool, then reply exactly CHAOS_CHECKBACK_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 2, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_checkback_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.text =~ "CHAOS_CHECKBACK_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert tool_result_succeeded?(messages, "check_back_later")

    checkback = Repo.get_by!(ScheduledEvent, source_actor_event_id: input.id)
    assert checkback.status == "scheduled"
    assert checkback.binding_name == "lark-chaos-primary"
    assert checkback.source_actor_event_id == input.id
    assert checkback.origin_ai_message_id in Enum.map(messages, & &1.id)
    assert checkback.signal_channel_id == "lark:oc_chaos_schedule"
    assert is_nil(checkback.provider_thread_id)
    assert checkback.source_entry_id == "om_checkback_tool_1"
    assert checkback.wake_payload["reason"] == "Lark chaos checkback"
    assert checkback.wake_payload["check"] == "Confirm CHAOS_CHECKBACK_WAKE_OK"
    assert DateTime.diff(checkback.due_at, checkback.requested_at, :second) in 295..305

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, checkback: checkback}
  end

  def run_checkback_fire(%{fake_feishu: _fake_feishu, container: container}, checkback) do
    assert {:ok, %{status: :fired, actor_event: wake_input}} =
             Schedule.fire_due_event(checkback.id, now: checkback.due_at)

    assert wake_input.type == "check_back_later.wakeup"

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               wake_input,
               DateTime.add(checkback.due_at, 1, :second)
             )

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, wake_input.id, deadline(60_000))

    assert reply.text =~ "CHAOS_CHECKBACK_WAKE_OK"

    assert_actor_event_completed!(wake_input.id)
    %{input: wake_input, reply: reply, message: message}
  end

  def run_cron_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_cron_tool_1",
               message_id: "om_cron_tool_1",
               chat_id: "oc_chaos_schedule",
               text:
                 "@_user_1 Run CHAOS_CRON_TOOL. Use the cron tool, then reply exactly CHAOS_CRON_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 3, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_cron_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.text =~ "CHAOS_CRON_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert tool_result_succeeded?(messages, "cron")

    cron_schedule = Repo.get_by!(CronSchedule, agent_uid: agent.uid, name: "lark-chaos-cron")
    assert cron_schedule.status == "active"
    assert cron_schedule.binding_name == "lark-chaos-primary"
    assert cron_schedule.name == "lark-chaos-cron"
    assert cron_schedule.schedule["kind"] == "every"
    assert cron_schedule.schedule["every_ms"] == 60_000
    assert cron_schedule.payload == %{"task" => "CHAOS_CRON_WAKE_OK"}
    assert [primary_target] = cron_schedule.delivery["targets"]
    assert primary_target["binding_name"] == "lark-chaos-primary"
    assert primary_target["signal_channel_id"] == "lark:oc_chaos_schedule"
    assert is_nil(primary_target["provider_thread_id"])

    cron_event = cron_event_for_schedule!(cron_schedule.id)
    assert cron_event.status == "scheduled"
    assert cron_event.signal_channel_id == "lark:oc_chaos_schedule"
    assert is_nil(cron_event.provider_thread_id)
    assert cron_event.wake_payload["payload"] == %{"task" => "CHAOS_CRON_WAKE_OK"}

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, cron_schedule: cron_schedule}
  end

  def configure_cron_fanout(
        %{fake_feishu: fake_feishu, primary_binding: primary, record_binding: secondary},
        cron_schedule
      ) do
    secondary_channel_id = "lark:oc_chaos_schedule_secondary"

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_cron_target_secondary_1",
               message_id: "om_cron_target_secondary_1",
               chat_id: "oc_chaos_schedule_secondary",
               chat_type: "group",
               text: "Seed the secondary cron delivery channel.",
               mentions: [],
               to_app: record_app_id(),
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 3_500, :millisecond), :millisecond)
             )

    assert %Entry{} =
             wait_for_signal_entry!(secondary_channel_id, "om_cron_target_secondary_1")

    assert %Channel{reply_mode: :entry} = Repo.get!(Channel, secondary_channel_id)

    targets = [
      %{
        "binding_name" => primary.name,
        "signal_channel_id" => "lark:oc_chaos_schedule"
      },
      %{
        "binding_name" => secondary.name,
        "signal_channel_id" => secondary_channel_id
      }
    ]

    assert {:ok, %CronSchedule{} = updated} =
             Schedule.update_cron_schedule(cron_schedule.id, %{
               "delivery" => %{"targets" => targets}
             })

    assert updated.delivery == %{"targets" => targets}

    cron_event = cron_event_for_schedule!(updated.id)
    assert cron_event.binding_name == primary.name
    assert cron_event.signal_channel_id == "lark:oc_chaos_schedule"
    assert cron_event.wake_payload["delivery"] == %{"targets" => targets}

    updated
  end

  def run_cron_fire(%{fake_feishu: fake_feishu, container: container}, cron_schedule) do
    cron_event = cron_event_for_schedule!(cron_schedule.id)

    assert {:ok, %{status: :fired, actor_event: fire_input}} =
             Schedule.fire_due_event(cron_event.id, now: cron_event.due_at)

    assert fire_input.type == "cron.fire"

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               fire_input,
               DateTime.add(cron_event.due_at, 1, :second)
             )

    assert {:ok, message} =
             wait_for_completed_actor_event_message(container, fire_input.id, deadline(60_000))

    assert {:ok, [_primary, _secondary] = outboxes} =
             wait_until(deadline(10_000), fn ->
               case final_outboxes(fire_input.id, message.id) do
                 [_, _] = outboxes -> outboxes
                 _other -> nil
               end
             end)

    assert Enum.all?(outboxes, &(&1.status == :created))
    assert Enum.map(outboxes, & &1.ai_message_id) |> Enum.uniq() == [message.id]
    assert Enum.map(outboxes, & &1.payload["text"]) |> Enum.uniq() == ["CHAOS_CRON_WAKE_OK"]

    # One provider route rejects one request. Each target is a separate outbox
    # row, so the other route succeeds and is never sent again when this row retries.
    assert :ok =
             FakeFeishu.State.fail_next(
               fake_feishu.state,
               :post_message,
               {:code, 500_100}
             )

    first_attempts =
      Enum.map(outboxes, fn outbox ->
        assert {:ok, %OutboxEntry{} = dispatched} =
                 SignalsGateway.dispatch_outbox_by_key(
                   outbox.agent_uid,
                   outbox.binding_name,
                   outbox.outbound_key
                 )

        dispatched
      end)

    assert [%OutboxEntry{status: :failed} = failed] =
             Enum.filter(first_attempts, &(&1.status == :failed))

    assert [%OutboxEntry{status: :succeeded, attempt_count: 1}] =
             Enum.filter(first_attempts, &(&1.status == :succeeded))

    assert %DateTime{} = failed.next_attempt_at

    assert {:ok, %OutboxEntry{status: :succeeded, attempt_count: 2}} =
             SignalsGateway.dispatch_outbox_by_key(
               failed.agent_uid,
               failed.binding_name,
               failed.outbound_key,
               now: DateTime.add(failed.next_attempt_at, 1, :second)
             )

    final_outboxes = final_outboxes(fire_input.id, message.id)
    assert Enum.all?(final_outboxes, &(&1.status == :succeeded))
    assert Enum.sort(Enum.map(final_outboxes, & &1.attempt_count)) == [1, 2]

    assert {:ok, reply, ^message} =
             wait_for_completed_final_reply(container, fire_input.id, deadline(10_000))

    secondary =
      Enum.find(final_outboxes, fn outbox ->
        get_in(outbox.payload, ["metadata", "delivery_target", "primary"]) == false
      end)

    secondary_source_entry_id =
      secondary.created_source_entry_id || secondary.target_source_entry_id

    secondary_reply =
      Repo.get_by!(Entry,
        signal_channel_id: secondary.signal_channel_id,
        source_entry_id: secondary_source_entry_id
      )

    assert reply.text =~ "CHAOS_CRON_WAKE_OK"
    assert reply.signal_channel_id == "lark:oc_chaos_schedule"
    assert secondary_reply.text == reply.text
    assert secondary_reply.ai_message_id == reply.ai_message_id

    assert_actor_event_completed!(fire_input.id)

    %{
      input: fire_input,
      reply: reply,
      secondary_reply: secondary_reply,
      message: message,
      outboxes: final_outboxes
    }
  end

  defp final_outboxes(actor_event_id, ai_message_id) do
    OutboxEntry
    |> where([outbox], outbox.source_actor_event_id == ^actor_event_id)
    |> where([outbox], outbox.ai_message_id == ^ai_message_id)
    |> Repo.all()
    |> Enum.filter(&(get_in(&1.payload, ["metadata", "source"]) == "ai_gateway_final_reply"))
    |> Enum.sort_by(&get_in(&1.payload, ["metadata", "delivery_target", "primary"]), :desc)
  end

  def run_file_attachment_roundtrip(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    # Seed the platform-side file so the real inbound download endpoint can
    # serve it during attachment materialization.
    assert :ok =
             FakeFeishu.State.put_inbound_file(
               fake_feishu.state,
               "file_1",
               "CHAOS_INBOUND_FILE_BYTES deck",
               "deck.pdf"
             )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_file_1",
               message_id: "om_file_1",
               chat_id: "oc_chaos_file",
               chat_type: "p2p",
               message_type: "file",
               content: %{"file_key" => "file_1", "file_name" => "deck.pdf"},
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_file_1")
    assert input.type == "im.message.addressed"

    assert {:ok, %Entry{text: nil, attachments: [attachment]}} =
             wait_until(deadline(10_000), fn ->
               case Repo.get_by!(Entry,
                      signal_channel_id: "lark:oc_chaos_file",
                      source_entry_id: "om_file_1"
                    ) do
                 %Entry{attachments: [%{"agent_computer_path" => path}]} = entry
                 when is_binary(path) ->
                   entry

                 %Entry{} ->
                   nil
               end
             end)

    # Materialized attachments carry extra worker-file keys on top of the
    # provider identity, so assert the provider identity as a subset.
    assert %{
             "provider_ref" => "lark:file:file_1",
             "provider" => "lark",
             "source_message_id" => "om_file_1",
             "file_key" => "file_1",
             "download_type" => "file",
             "resource_type" => "file",
             "name" => "deck.pdf"
           } =
             Map.take(
               attachment,
               ~w(provider_ref provider source_message_id file_key download_type resource_type name)
             )

    assert {:ok, %ActorEvent{} = input} =
             wait_until(deadline(10_000), fn ->
               refreshed = Repo.get!(ActorEvent, input.id)

               if get_in(refreshed.payload, ["data", "entry", "attachments"]) == [attachment],
                 do: refreshed,
                 else: nil
             end)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.text =~ "CHAOS_GENERIC_OK"
    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_reply_attachment_tool_loop(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_reply_attachment_1",
               message_id: "om_reply_attachment_1",
               chat_id: "oc_chaos_reply_attachment",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_REPLY_ATTACHMENT. Create the file, register it with reply_attachment, then reply exactly CHAOS_REPLY_ATTACHMENT_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_500, :millisecond), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_reply_attachment_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox, message} =
             wait_for_completed_outbox(container, input.id, deadline(90_000))

    # One completion commits two rows. The visible answer belongs to the final
    # reply; the attachment row carries the file and no text, so no adapter
    # posts the same wall twice. Both rows commit in the same transaction, so
    # the final reply is already durable here.
    final_reply =
      Repo.get_by!(OutboxEntry,
        source_actor_event_id: input.id,
        outbound_key: "ai-reply:#{message.id}"
      )

    assert final_reply.payload["text"] =~ "CHAOS_REPLY_ATTACHMENT_OK"
    assert is_nil(outbox.payload["text"])

    expected_attachment_path =
      Ankole.AgentHomePaths.user_files(agent.uid) <> "/reports/chaos-report.txt"

    assert [
             %{
               "agent_computer_path" => ^expected_attachment_path,
               "user_files_relative_path" => "reports/chaos-report.txt",
               "name" => "chaos-report.txt",
               "mime_type" => "text/plain"
             } = attachment
           ] = outbox.payload["attachments"]

    assert attachment["size"] > 0

    messages = ai_messages_for_actor_event(input.id)
    assert command_tool_succeeded?(messages)
    assert tool_result_succeeded?(messages, "reply_attachment")

    assert_actor_event_completed!(input.id)
    %{input: input, outbox: outbox}
  end

  def run_todo_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_todo_tool_1",
               message_id: "om_todo_tool_1",
               chat_id: "oc_chaos_todo",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_TODO_TOOL. Use the todo tool to track three steps, mark every step completed, then reply exactly CHAOS_TODO_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_650, :millisecond), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_todo_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_TODO_OK"

    messages = ai_messages_for_actor_event(input.id)
    todo_results = successful_tool_results(messages, "todo")
    assert length(todo_results) == 2
    assert tool_detail(List.last(todo_results), ["summary", "total"]) == 3
    assert tool_detail(List.last(todo_results), ["summary", "completed"]) == 3

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Runs `read_file` after a command-created file inside the Docker worker workspace.
  """
  def run_read_file_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_read_file_1",
               message_id: "om_read_file_1",
               chat_id: "oc_chaos_files",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_READ_FILE. Create the file, read it with read_file, then reply exactly CHAOS_READ_FILE_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_100, :millisecond), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_read_file_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_READ_FILE_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert command_tool_succeeded?(messages)
    assert [read_result] = successful_tool_results(messages, "read_file")
    assert inspect(read_result) =~ "CHAOS_READ_FILE_CONTENT"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Runs `apply_patch` against a Docker-worker file and verifies the edited contents.
  """
  def run_patch_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_patch_tool_1",
               message_id: "om_patch_tool_1",
               chat_id: "oc_chaos_files",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_PATCH_TOOL. Create a file, patch CHAOS_PATCH_OLD into CHAOS_PATCH_NEW, read it back, then reply exactly CHAOS_PATCH_TOOL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_150, :millisecond), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_patch_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_PATCH_TOOL_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert command_tool_succeeded?(messages)

    assert [_patch_result] = successful_tool_results(messages, "apply_patch"),
           "apply_patch results: #{inspect(tool_results(messages, "apply_patch"))}"

    read_results = successful_tool_results(messages, "read_file")
    assert read_results |> List.last() |> inspect() =~ "CHAOS_PATCH_NEW"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies Agent `user-files` survives across separate Docker worker turns.
  """
  def run_workspace_file_persistence(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_workspace_write_1",
               message_id: "om_workspace_write_1",
               chat_id: "oc_chaos_workspace",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_WORKSPACE_WRITE. Create the persisted file, then reply exactly CHAOS_WORKSPACE_WRITE_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_200, :millisecond), :millisecond)
             )

    write_input = actor_event_by_source_entry_id!(agent.uid, "om_workspace_write_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               write_input,
               DateTime.add(write_input.available_at, 1, :second)
             )

    assert {:ok, write_reply, _write_message} =
             wait_for_completed_final_reply(container, write_input.id, deadline(90_000))

    assert write_reply.text =~ "CHAOS_WORKSPACE_WRITE_OK"
    assert command_tool_succeeded?(ai_messages_for_actor_event(write_input.id))
    assert_actor_event_completed!(write_input.id)

    assert_lark_final_reply(
      fake_feishu,
      write_reply,
      "CHAOS_WORKSPACE_WRITE_OK",
      :reply,
      "om_workspace_write_1"
    )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_workspace_read_1",
               message_id: "om_workspace_read_1",
               chat_id: "oc_chaos_workspace",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_WORKSPACE_READ. Read the persisted file with read_file, then reply exactly CHAOS_WORKSPACE_READ_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_300, :millisecond), :millisecond)
             )

    read_input = actor_event_by_source_entry_id!(agent.uid, "om_workspace_read_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               read_input,
               DateTime.add(read_input.available_at, 1, :second)
             )

    assert {:ok, read_reply, _read_message} =
             wait_for_completed_final_reply(container, read_input.id, deadline(90_000))

    assert read_reply.text =~ "CHAOS_WORKSPACE_READ_OK"

    assert [read_result] =
             successful_tool_results(ai_messages_for_actor_event(read_input.id), "read_file")

    assert inspect(read_result) =~ "CHAOS_WORKSPACE_PERSISTED"

    assert_actor_event_completed!(read_input.id)
    %{input: read_input, reply: read_reply}
  end
end
