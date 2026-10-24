defmodule Ankole.E2E.Scenarios.ScheduleAndTool do
  @moduledoc """
  Schedule, file, and computer-tool scenarios for the Docker worker suites.
  """

  import ExUnit.Assertions
  import Ecto.Query

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_until: 2,
      wait_for_completed_signal_message: 3,
      wait_for_completed_final_reply: 3,
      wait_for_completed_intent: 3,
      ai_messages_for_signal: 1
    ]

  alias Ankole.Repo
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.CronSchedule
  alias Ankole.Schedule.Schemas.ScheduledEvent

  alias Ankole.Signals.Signal
  alias Ankole.Conversations.Conversation
  alias Ankole.Conversations.Message, as: ConversationMessage
  alias Ankole.Conversations.External
  alias Ankole.Conversations.Delivery.Intent

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

    input = signal_by_provider_message_id!(agent.uid, "om_checkback_tool_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_CHECKBACK_OK"

    messages = ai_messages_for_signal(input.id)
    assert tool_result_succeeded?(messages, "check_back_later")

    checkback = Repo.get_by!(ScheduledEvent, source_signal_id: input.id)
    assert checkback.status == :scheduled
    assert checkback.binding_name == "lark-chaos-primary"
    assert checkback.source_signal_id == input.id
    assert checkback.origin_ai_message_id in Enum.map(messages, & &1.id)

    assert checkback.conversation_id ==
             External.get_conversation("lark:oc_chaos_schedule").id

    assert is_nil(checkback.provider_thread_id)
    assert checkback.provider_message_id == "om_checkback_tool_1"
    assert checkback.wake_payload["reason"] == "Lark chaos checkback"
    assert checkback.wake_payload["check"] == "Confirm CHAOS_CHECKBACK_WAKE_OK"
    assert DateTime.diff(checkback.due_at, checkback.requested_at, :second) == 5

    assert_signal_completed!(input.id)
    %{input: input, reply: reply, checkback: checkback}
  end

  def run_checkback_fire(%{fake_feishu: _fake_feishu, container: container}, checkback) do
    assert {:ok, :due} =
             wait_until(deadline(60_000), fn ->
               if DateTime.compare(checkback.due_at, DateTime.utc_now(:microsecond)) != :gt,
                 do: :due
             end)

    assert {:ok, %{status: :fired, signal: wake_input}} =
             Schedule.fire_due_event(checkback.id)

    assert wake_input.type == "check_back_later.wakeup"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               wake_input,
               DateTime.add(checkback.due_at, 1, :second)
             )

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, wake_input.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_CHECKBACK_WAKE_OK"

    assert_signal_completed!(wake_input.id)
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

    input = signal_by_provider_message_id!(agent.uid, "om_cron_tool_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_CRON_OK"

    messages = ai_messages_for_signal(input.id)
    assert tool_result_succeeded?(messages, "cron")

    cron_schedule = Repo.get_by!(CronSchedule, agent_uid: agent.uid, name: "lark-chaos-cron")
    assert cron_schedule.status == :active
    assert cron_schedule.binding_name == "lark-chaos-primary"
    assert cron_schedule.name == "lark-chaos-cron"
    assert cron_schedule.schedule["kind"] == "every"
    assert cron_schedule.schedule["every_ms"] == 60_000
    assert cron_schedule.payload == %{"task" => "CHAOS_CRON_WAKE_OK"}
    assert [primary_target] = cron_schedule.delivery["targets"]
    assert primary_target["binding_name"] == "lark-chaos-primary"

    assert primary_target["conversation_id"] ==
             External.get_conversation("lark:oc_chaos_schedule").id

    assert is_nil(primary_target["provider_thread_id"])

    assert %DateTime{} = cron_schedule.next_fire_at
    assert Schedule.list_cron_runs(cron_schedule.id) == []

    assert_signal_completed!(input.id)
    %{input: input, reply: reply, cron_schedule: cron_schedule}
  end

  def configure_cron_fanout(
        %{fake_feishu: fake_feishu, primary_binding: primary, record_binding: secondary},
        cron_schedule
      ) do
    secondary_provider_conversation_id = "lark:oc_chaos_schedule_secondary"

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

    assert %{message: %ConversationMessage{}} =
             wait_for_message_observation!(
               secondary_provider_conversation_id,
               "om_cron_target_secondary_1"
             )

    assert %Conversation{reply_mode: :entry} =
             External.get_conversation(secondary_provider_conversation_id)

    targets = [
      %{
        "binding_name" => primary.name,
        "conversation_id" => External.get_conversation("lark:oc_chaos_schedule").id
      },
      %{
        "binding_name" => secondary.name,
        "conversation_id" => External.get_conversation(secondary_provider_conversation_id).id
      }
    ]

    assert {:ok, %CronSchedule{} = updated} =
             Schedule.update_cron_schedule(cron_schedule.id, %{
               "delivery" => %{"targets" => targets}
             })

    assert updated.delivery == %{"targets" => targets}

    assert updated.binding_name == primary.name
    assert updated.next_fire_at == cron_schedule.next_fire_at
    assert Schedule.list_cron_runs(updated.id) == []

    updated
  end

  def run_cron_fire(%{fake_feishu: fake_feishu, container: container}, cron_schedule) do
    due_at = cron_schedule.next_fire_at

    assert {:ok, :due} =
             wait_until(deadline(60_000), fn ->
               if DateTime.compare(due_at, DateTime.utc_now(:microsecond)) != :gt,
                 do: :due
             end)

    assert {:ok, %{status: :fired, signal: fire_input}} =
             Schedule.fire_cron(cron_schedule.id)

    assert fire_input.type == "cron.fire"

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               fire_input,
               DateTime.add(due_at, 1, :second)
             )

    # This scenario owns delivery attempts. Wait without draining the intent
    # queue before the provider fault and retry assertions are in place.
    assert {:ok, %Signal{}} =
             wait_until(deadline(60_000), fn ->
               case Repo.get(Signal, fire_input.id) do
                 %Signal{status: :completed, completed_at: %DateTime{}} = event -> event
                 _other -> nil
               end
             end)

    assert {:ok, message} =
             wait_for_completed_signal_message(container, fire_input.id, deadline(60_000))

    assert {:ok, [_primary, _secondary] = intents} =
             wait_until(deadline(10_000), fn ->
               case final_intents(fire_input.id, message.id) do
                 [_, _] = intents -> intents
                 _other -> nil
               end
             end)

    assert Enum.all?(intents, &(&1.status == :pending))
    assert Enum.map(intents, & &1.ai_message_id) |> Enum.uniq() == [message.id]
    assert Enum.map(intents, & &1.payload["text"]) |> Enum.uniq() == ["CHAOS_CRON_WAKE_OK"]

    # One provider route rejects one request. Each target is a separate intent
    # row, so the other route succeeds and is never sent again when this row retries.
    assert :ok =
             FakeFeishu.State.fail_next(
               fake_feishu.state,
               :post_message,
               {:code, 500_100}
             )

    first_attempts =
      Enum.map(intents, fn intent ->
        assert {:ok, %Intent{} = dispatched} =
                 Ankole.Conversations.Delivery.dispatch_by_key(
                   intent.agent_uid,
                   intent.binding_name,
                   intent.outbound_key
                 )

        dispatched
      end)

    assert [%Intent{status: :failed} = failed] =
             Enum.filter(first_attempts, &(&1.status == :failed))

    assert [%Intent{status: :sent, attempt_count: 1}] =
             Enum.filter(first_attempts, &(&1.status == :sent))

    assert %DateTime{} = failed.next_attempt_at

    assert {:ok, %Intent{status: :sent, attempt_count: 2}} =
             Ankole.Conversations.Delivery.dispatch_by_key(
               failed.agent_uid,
               failed.binding_name,
               failed.outbound_key,
               now: DateTime.add(failed.next_attempt_at, 1, :second)
             )

    final_intents = final_intents(fire_input.id, message.id)
    assert Enum.all?(final_intents, &(&1.status == :sent))
    assert Enum.sort(Enum.map(final_intents, & &1.attempt_count)) == [1, 2]

    assert {:ok, reply, ^message} =
             wait_for_completed_final_reply(container, fire_input.id, deadline(10_000))

    secondary =
      Enum.find(final_intents, fn intent ->
        get_in(intent.payload, ["metadata", "delivery_target", "primary"]) == false
      end)

    secondary_provider_message_id =
      secondary.created_provider_message_id || secondary.target_provider_message_id

    secondary_reply =
      External.get_message(secondary.conversation_id, secondary_provider_message_id)

    assert reply.message.text =~ "CHAOS_CRON_WAKE_OK"

    assert reply.message.conversation_id ==
             External.get_conversation("lark:oc_chaos_schedule").id

    assert secondary_reply.message.text == reply.message.text
    assert secondary_reply.external_ref.ai_message_id == reply.external_ref.ai_message_id

    assert_signal_completed!(fire_input.id)

    %{
      input: fire_input,
      reply: reply,
      secondary_reply: secondary_reply,
      message: message,
      intents: final_intents
    }
  end

  defp final_intents(signal_id, ai_message_id) do
    Intent
    |> where([intent], intent.source_signal_id == ^signal_id)
    |> where([intent], intent.ai_message_id == ^ai_message_id)
    |> Repo.all()
    |> Enum.filter(&(get_in(&1.payload, ["metadata", "source"]) == "ai_gateway_final_reply"))
    |> Enum.sort_by(&get_in(&1.payload, ["metadata", "delivery_target", "primary"]), :desc)
  end

  def run_file_attachment_roundtrip(
        %{fake_feishu: fake_feishu, agent: agent},
        message_type \\ "file"
      ) do
    file = %{"file_key" => "file_1", "file_name" => "deck.pdf"}

    {content, expected_text} =
      case message_type do
        "file" ->
          {file, nil}

        "post" ->
          text = "Please read the attached report."

          {%{
             "title" => "",
             "content" => [[%{"tag" => "text", "text" => text}]],
             "files" => [file]
           }, text}
      end

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
               message_type: message_type,
               content: content,
               mentions: [],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4, :second), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_file_1")
    assert input.type == "conversation.message.addressed"

    assert {:ok,
            %{message: %ConversationMessage{text: ^expected_text, attachments: [attachment]}}} =
             wait_until(deadline(10_000), fn ->
               case message_observation("lark:oc_chaos_file", "om_file_1") do
                 %{
                   message: %ConversationMessage{
                     attachments: [%{"blob_ref" => blob_ref, "path" => path}]
                   }
                 } = entry
                 when is_binary(blob_ref) and is_binary(path) ->
                   entry

                 %{message: %ConversationMessage{}} ->
                   nil
               end
             end)

    # Stored attachments carry `blob_ref`, `path`, and `size` on top of the
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

    assert {:ok, %Signal{} = input} =
             wait_until(deadline(10_000), fn ->
               refreshed = Repo.get!(Signal, input.id)

               if get_in(refreshed.data, ["entry", "attachments"]) == [attachment],
                 do: refreshed,
                 else: nil
             end)

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(%{agent_uid: agent.uid}, input.id, deadline(60_000))

    assert reply.message.text =~ "CHAOS_GENERIC_OK"
    assert_signal_completed!(input.id)
    %{input: input, reply: reply, message: message, attachment: attachment}
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
                 "@_user_1 Run CHAOS_REPLY_ATTACHMENT. Create the file, save it with ankole-files put, register its drive_path with reply_attachment, then reply exactly CHAOS_REPLY_ATTACHMENT_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 4_500, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_reply_attachment_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    {:ok, intent, message} =
      try do
        wait_for_completed_intent(container, input.id, deadline(90_000))
      rescue
        error in ExUnit.AssertionError ->
          IO.inspect(
            Enum.filter(Ankole.E2E.FakeOpenAIState.requests(), &(&1.kind == :reply_attachment)),
            label: "reply attachment actual upstream requests",
            limit: :infinity,
            printable_limit: :infinity
          )

          reraise error, __STACKTRACE__
      end

    # One completion commits two rows. The visible answer belongs to the final
    # reply; the attachment row carries the file and no text, so no adapter
    # posts the same wall twice. Both rows commit in the same transaction, so
    # the final reply is already durable here.
    final_reply =
      Repo.get_by!(Intent,
        source_signal_id: input.id,
        outbound_key: "ai-reply:#{message.id}"
      )

    assert final_reply.payload["text"] =~ "CHAOS_REPLY_ATTACHMENT_OK"
    assert is_nil(intent.payload["text"])

    # The command saves the file in the drive. reply_attachment preserves
    # that original path and records its content digest for provider delivery.
    content = "CHAOS_REPLY_ATTACHMENT_FILE"
    blob_ref = Base.encode16(:crypto.hash(:sha256, content), case: :lower)
    expected_path = "reports/chaos-report.txt"

    assert [
             %{
               "path" => ^expected_path,
               "blob_ref" => ^blob_ref,
               "name" => "chaos-report.txt",
               "mime_type" => "text/plain"
             } = attachment
           ] = intent.payload["attachments"]

    assert attachment["size"] == byte_size(content)
    assert {:ok, _file, ^content} = Ankole.Files.read(agent.uid, expected_path)

    messages = ai_messages_for_signal(input.id)
    assert command_tool_succeeded?(messages)
    assert tool_result_succeeded?(messages, "reply_attachment")

    assert_signal_completed!(input.id)
    %{input: input, intent: intent}
  end

  def run_todo_tool_loop(%{fake_feishu: fake_feishu, agent: agent}) do
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

    input = signal_by_provider_message_id!(agent.uid, "om_todo_tool_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(%{agent_uid: agent.uid}, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_TODO_OK"

    messages = ai_messages_for_signal(input.id)
    todo_results = successful_tool_results(messages, "todo")
    assert length(todo_results) == 2
    assert tool_detail(List.last(todo_results), ["summary", "total"]) == 3
    assert tool_detail(List.last(todo_results), ["summary", "completed"]) == 3

    assert_signal_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Runs `read_file` after a command creates a file in the Worker workspace.
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

    input = signal_by_provider_message_id!(agent.uid, "om_read_file_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_READ_FILE_OK"

    messages = ai_messages_for_signal(input.id)
    assert command_tool_succeeded?(messages)
    assert [read_result] = successful_tool_results(messages, "read_file")
    assert inspect(read_result) =~ "CHAOS_READ_FILE_CONTENT"

    assert_signal_completed!(input.id)
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

    input = signal_by_provider_message_id!(agent.uid, "om_patch_tool_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_PATCH_TOOL_OK"

    messages = ai_messages_for_signal(input.id)
    assert command_tool_succeeded?(messages)

    assert [_patch_result] = successful_tool_results(messages, "apply_patch"),
           "apply_patch results: #{inspect(tool_results(messages, "apply_patch"))}"

    read_results = successful_tool_results(messages, "read_file")
    assert read_results |> List.last() |> inspect() =~ "CHAOS_PATCH_NEW"

    assert_signal_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies that a folder put in the Agent's drive arrives in one bundled
  transfer and that its file comes back in a later turn.
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

    write_input = signal_by_provider_message_id!(agent.uid, "om_workspace_write_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               write_input,
               DateTime.add(write_input.available_at, 1, :second)
             )

    assert {:ok, write_reply, _write_message} =
             wait_for_completed_final_reply(container, write_input.id, deadline(90_000))

    assert write_reply.message.text =~ "CHAOS_WORKSPACE_WRITE_OK"
    assert command_tool_succeeded?(ai_messages_for_signal(write_input.id))
    assert_signal_completed!(write_input.id)

    # The two files of the folder travel in one bundled transfer.
    assert {:ok, _file, "CHAOS_WORKSPACE_PERSISTED\n"} =
             Ankole.Files.read(agent.uid, "chaos/persisted.txt")

    assert {:ok, _file, "CHAOS_WORKSPACE_SECOND\n"} =
             Ankole.Files.read(agent.uid, "chaos/second.txt")

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

    read_input = signal_by_provider_message_id!(agent.uid, "om_workspace_read_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               read_input,
               DateTime.add(read_input.available_at, 1, :second)
             )

    assert {:ok, read_reply, _read_message} =
             wait_for_completed_final_reply(container, read_input.id, deadline(90_000))

    assert read_reply.message.text =~ "CHAOS_WORKSPACE_READ_OK"

    assert [read_result] =
             successful_tool_results(ai_messages_for_signal(read_input.id), "read_file")

    assert inspect(read_result) =~ "CHAOS_WORKSPACE_PERSISTED"

    assert_signal_completed!(read_input.id)
    %{input: read_input, reply: read_reply}
  end
end
