defmodule Ankole.LarkAgentChaos.E2E.ScheduleAndToolScenarios do
  @moduledoc """
  Schedule, file, and computer-tool scenarios for the Docker worker chaos suite.
  """

  import ExUnit.Assertions

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      checkback_by_idempotency!: 2,
      command_tool_succeeded?: 1,
      cron_event_for_schedule!: 1,
      cron_schedule_by_idempotency!: 2,
      deadline: 1,
      tool_result_succeeded?: 2,
      wait_for_outbox_for_input: 4,
      wait_for_turn_status: 4
    ]

  import Ankole.LarkAgentChaos.E2E.Harness

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.LarkAgentChaos.FeishuServer
  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.SignalsGateway.SignalEntry

  @base_time ~U[2026-06-24 08:00:00.000000Z]

  def run_checkback_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_checkback_tool_1",
               message_id: "om_checkback_tool_1",
               chat_id: "oc_chaos_schedule",
               text:
                 "@_user_1 Run CHAOS_CHECKBACK_TOOL. Use the schedule tool, then reply exactly CHAOS_CHECKBACK_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 2, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_checkback_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_CHECKBACK_OK"

    persisted_turn = Repo.get!(LlmTurn, turn.id)
    assert persisted_turn.status == "succeeded"
    assert tool_result_succeeded?(persisted_turn.tool_results, "check_back_later")

    checkback = checkback_by_idempotency!(agent_uid, "lark-chaos-checkback-1")
    assert checkback.status == "scheduled"
    assert checkback.binding_name == "lark-chaos-primary"
    assert checkback.source_actor_input_id == input.id
    assert checkback.source_llm_turn_id == turn.id
    assert checkback.signal_channel_id == "lark:oc_chaos_schedule"
    assert checkback.provider_thread_id == "lark:oc_chaos_schedule:om_checkback_tool_1"
    assert checkback.provider_entry_id == "om_checkback_tool_1"
    assert checkback.wake_payload["reason"] == "Lark chaos checkback"
    assert checkback.wake_payload["check"] == "Confirm CHAOS_CHECKBACK_WAKE_OK"
    assert DateTime.diff(checkback.due_at, checkback.requested_at, :second) in 295..305

    refute Repo.get(ActorInput, input.id)
    turn
  end

  def run_checkback_fire(agent_uid, container) do
    checkback = checkback_by_idempotency!(agent_uid, "lark-chaos-checkback-1")

    assert {:ok, %{status: :fired, actor_input: wake_input}} =
             Schedule.fire_due_event(checkback.id, now: checkback.due_at)

    assert wake_input.type == "check_back_later.wakeup"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(
               wake_input,
               DateTime.add(checkback.due_at, 1, :second)
             )

    assert Repo.get!(LlmTurn, turn.id).kind == "checkback_generation"

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, wake_input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_CHECKBACK_WAKE_OK"
    assert outbox.source_provider_entry_id == "om_checkback_tool_1"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, wake_input.id)
    persisted_turn
  end

  def run_cron_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_cron_tool_1",
               message_id: "om_cron_tool_1",
               chat_id: "oc_chaos_schedule",
               text:
                 "@_user_1 Run CHAOS_CRON_TOOL. Use the cron tool, then reply exactly CHAOS_CRON_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 3, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_cron_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_CRON_OK"

    persisted_turn = Repo.get!(LlmTurn, turn.id)
    assert persisted_turn.status == "succeeded"
    assert tool_result_succeeded?(persisted_turn.tool_results, "cron")

    cron_schedule = cron_schedule_by_idempotency!(agent_uid, "lark-chaos-cron-1")
    assert cron_schedule.status == "active"
    assert cron_schedule.binding_name == "lark-chaos-primary"
    assert cron_schedule.name == "lark-chaos-cron"
    assert cron_schedule.schedule["kind"] == "every"
    assert cron_schedule.schedule["every_ms"] == 60_000
    assert cron_schedule.payload == %{"task" => "CHAOS_CRON_WAKE_OK"}
    assert cron_schedule.delivery["signal_channel_id"] == "lark:oc_chaos_schedule"
    assert cron_schedule.delivery["provider_thread_id"] == "lark:oc_chaos_schedule:om_cron_tool_1"

    cron_event = cron_event_for_schedule!(cron_schedule.id)
    assert cron_event.status == "scheduled"
    assert cron_event.signal_channel_id == "lark:oc_chaos_schedule"
    assert cron_event.provider_thread_id == "lark:oc_chaos_schedule:om_cron_tool_1"
    assert cron_event.wake_payload["payload"] == %{"task" => "CHAOS_CRON_WAKE_OK"}

    refute Repo.get(ActorInput, input.id)
    turn
  end

  def run_cron_fire(agent_uid, container) do
    cron_schedule = cron_schedule_by_idempotency!(agent_uid, "lark-chaos-cron-1")
    cron_event = cron_event_for_schedule!(cron_schedule.id)

    assert {:ok, %{status: :fired, actor_input: fire_input}} =
             Schedule.fire_due_event(cron_event.id, now: cron_event.due_at)

    assert fire_input.type == "cron.fire"

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(
               fire_input,
               DateTime.add(cron_event.due_at, 1, :second)
             )

    assert Repo.get!(LlmTurn, turn.id).kind == "scheduled_task"

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, fire_input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_CRON_WAKE_OK"
    assert outbox.operation == :post
    assert outbox.signal_channel_id == "lark:oc_chaos_schedule"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, fire_input.id)
    persisted_turn
  end

  def run_file_attachment_roundtrip(agent_uid, dispatcher, container) do
    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_file_1")
    assert input.type == "im.message.addressed"

    assert %SignalEntry{text: nil, attachments: [attachment]} =
             Repo.get_by!(SignalEntry,
               signal_channel_id: "lark:oc_chaos_file",
               provider_entry_id: "om_file_1"
             )

    assert attachment == %{
             "provider_ref" => "lark:file:file_1",
             "provider" => "lark",
             "source_message_id" => "om_file_1",
             "file_key" => "file_1",
             "download_type" => "file",
             "resource_type" => "file",
             "name" => "deck.pdf"
           }

    assert get_in(input.payload, ["data", "entry", "attachments"]) == [attachment]

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(60_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_GENERIC_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, input.id)
    turn
  end

  def run_reply_attachment_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_reply_attachment_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_REPLY_ATTACHMENT_OK"

    assert [
             %{
               "agent_computer_path" => "/workspace/user-files/reports/chaos-report.txt",
               "user_files_relative_path" => "reports/chaos-report.txt",
               "name" => "chaos-report.txt",
               "mime_type" => "text/plain"
             } = attachment
           ] = outbox.payload["attachments"]

    assert attachment["size"] > 0

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert command_tool_succeeded?(persisted_turn.tool_results)
    assert tool_result_succeeded?(persisted_turn.tool_results, "reply_attachment")
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_todo_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_todo_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_TODO_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    todo_results = successful_tool_results(persisted_turn.tool_results, "todo")
    assert length(todo_results) == 2
    assert get_in(List.last(todo_results), ["result", "details", "summary", "total"]) == 3
    assert get_in(List.last(todo_results), ["result", "details", "summary", "completed"]) == 3
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_browser_doctor_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_browser_doctor_1",
               message_id: "om_browser_doctor_1",
               chat_id: "oc_chaos_browser",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_BROWSER_DOCTOR. Use browser_doctor once without fetching a browser binary, then reply exactly CHAOS_BROWSER_DOCTOR_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_750, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_browser_doctor_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(120_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_BROWSER_DOCTOR_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert [
             %{
               "result" => %{"details" => %{"exitCode" => 0}}
             }
           ] = successful_tool_results(persisted_turn.tool_results, "browser_doctor")

    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_background_command_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_background_command_1",
               message_id: "om_background_command_1",
               chat_id: "oc_chaos_background",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_BACKGROUND_COMMAND. Start a background command once, then reply exactly CHAOS_BACKGROUND_COMMAND_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_850, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_background_command_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_BACKGROUND_COMMAND_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert [
             %{
               "result" => %{"details" => %{"backgroundId" => background_id, "status" => status}}
             }
           ] = successful_tool_results(persisted_turn.tool_results, "command")

    assert is_binary(background_id)
    assert status in ["running", "exited"]
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_interactive_terminal_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_interactive_terminal_1",
               message_id: "om_interactive_terminal_1",
               chat_id: "oc_chaos_terminal",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_INTERACTIVE_TERMINAL. Use interactive_terminal start/send/capture/kill, then reply exactly CHAOS_INTERACTIVE_TERMINAL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_900, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_interactive_terminal_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_INTERACTIVE_TERMINAL_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    terminal_results =
      successful_tool_results(persisted_turn.tool_results, "interactive_terminal")

    assert Enum.map(terminal_results, &get_in(&1, ["result", "details", "action"])) ==
             ~w(start send capture kill)

    assert terminal_results
           |> Enum.find(&(get_in(&1, ["result", "details", "action"]) == "capture"))
           |> get_in(["result", "content"])
           |> inspect()
           |> String.contains?("CHAOS_INTERACTIVE_TERMINAL_SCREEN")

    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_browser_open_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_browser_open_1",
               message_id: "om_browser_open_1",
               chat_id: "oc_chaos_browser",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_BROWSER_OPEN. Use browser_open on https://example.com once, then reply exactly CHAOS_BROWSER_OPEN_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_950, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_browser_open_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(120_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_BROWSER_OPEN_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert [
             %{
               "result" => %{
                 "details" => %{
                   "exitCode" => 0,
                   "result" => %{
                     "ok" => true,
                     "url" => "https://example.com",
                     "screenshot_path" => screenshot_path
                   }
                 }
               }
             }
           ] = successful_tool_results(persisted_turn.tool_results, "browser_open")

    assert screenshot_path =~ "/workspace/temp/browser/"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_browser_run_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_browser_run_1",
               message_id: "om_browser_run_1",
               chat_id: "oc_chaos_browser",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_BROWSER_RUN. Use browser_run once with a tiny Python script, then reply exactly CHAOS_BROWSER_RUN_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_browser_run_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(120_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_BROWSER_RUN_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert [
             %{
               "result" => %{
                 "details" => %{
                   "exitCode" => 0,
                   "result" => %{"ok" => true, "stdout" => stdout}
                 }
               }
             }
           ] = successful_tool_results(persisted_turn.tool_results, "browser_run")

    assert stdout =~ "CHAOS_BROWSER_RUN_SCRIPT_OK"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  def run_browser_extract_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_browser_extract_1",
               message_id: "om_browser_extract_1",
               chat_id: "oc_chaos_browser",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_BROWSER_EXTRACT. Use browser_extract on https://example.com once, then reply exactly CHAOS_BROWSER_EXTRACT_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_025, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_browser_extract_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(120_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_BROWSER_EXTRACT_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert [
             %{
               "result" => %{
                 "details" => %{"exitCode" => 0, "result" => %{"ok" => true} = result}
               }
             }
           ] = successful_tool_results(persisted_turn.tool_results, "browser_extract")

    assert inspect(result) =~ "Example Domain"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  @doc """
  Runs `read_file` after a command-created file inside the Docker worker workspace.
  """
  def run_read_file_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_read_file_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_READ_FILE_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert command_tool_succeeded?(persisted_turn.tool_results)
    assert [read_result] = successful_tool_results(persisted_turn.tool_results, "read_file")
    assert inspect(read_result) =~ "CHAOS_READ_FILE_CONTENT"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  @doc """
  Runs `patch` against a Docker-worker file and verifies the edited contents.
  """
  def run_patch_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_patch_tool_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_PATCH_TOOL_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert command_tool_succeeded?(persisted_turn.tool_results)
    assert [patch_result] = successful_tool_results(persisted_turn.tool_results, "patch")
    assert inspect(patch_result) =~ "CHAOS_PATCH_NEW"

    read_results = successful_tool_results(persisted_turn.tool_results, "read_file")
    assert read_results |> List.last() |> inspect() =~ "CHAOS_PATCH_NEW"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  @doc """
  Verifies `/workspace/user-files` survives across separate Docker worker turns.
  """
  def run_workspace_file_persistence(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    write_input = actor_input_by_provider_entry_id!(agent_uid, "om_workspace_write_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: write_turn}} =
             process_ready_input_for_actor!(
               write_input,
               DateTime.add(write_input.available_at, 1, :second)
             )

    assert {:ok, write_outbox} =
             wait_for_outbox_for_input(container, write_input.id, deadline(90_000), write_turn.id)

    assert write_outbox.payload["text"] =~ "CHAOS_WORKSPACE_WRITE_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_write_turn} =
             wait_for_turn_status(container, write_turn.id, "succeeded", deadline(10_000))

    assert command_tool_succeeded?(persisted_write_turn.tool_results)
    refute Repo.get(ActorInput, write_input.id)

    dispatch_and_assert_lark_outbox(
      persisted_write_turn,
      "CHAOS_WORKSPACE_WRITE_OK",
      :reply,
      "om_workspace_write_1"
    )

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    read_input = actor_input_by_provider_entry_id!(agent_uid, "om_workspace_read_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: read_turn}} =
             process_ready_input_for_actor!(
               read_input,
               DateTime.add(read_input.available_at, 1, :second)
             )

    assert {:ok, read_outbox} =
             wait_for_outbox_for_input(container, read_input.id, deadline(90_000), read_turn.id)

    assert read_outbox.payload["text"] =~ "CHAOS_WORKSPACE_READ_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_read_turn} =
             wait_for_turn_status(container, read_turn.id, "succeeded", deadline(10_000))

    assert [read_result] = successful_tool_results(persisted_read_turn.tool_results, "read_file")
    assert inspect(read_result) =~ "CHAOS_WORKSPACE_PERSISTED"
    refute Repo.get(ActorInput, read_input.id)
    persisted_read_turn
  end
end
