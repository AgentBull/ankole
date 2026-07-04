defmodule Ankole.E2E.Scenarios.ComputerState do
  @moduledoc """
  Cross-turn computer state scenarios for the Docker worker suites.
  """

  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_for_completed_final_reply: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.E2E.FakeFeishu

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  @doc """
  Verifies a tmux-backed interactive terminal survives across separate turns.
  """
  def run_interactive_terminal_persistence(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_terminal_persist_start_1",
               message_id: "om_terminal_persist_start_1",
               chat_id: "oc_chaos_terminal_persist",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_TERMINAL_PERSIST_START. Start the persistent terminal, seed its cwd and file, then reply exactly CHAOS_TERMINAL_PERSIST_START_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_400, :millisecond), :millisecond)
             )

    start_input = actor_event_by_source_entry_id!(agent.uid, "om_terminal_persist_start_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               start_input,
               DateTime.add(start_input.available_at, 1, :second)
             )

    assert {:ok, start_reply, _start_message} =
             wait_for_completed_final_reply(container, start_input.id, deadline(90_000))

    assert start_reply.text =~ "CHAOS_TERMINAL_PERSIST_START_OK"

    start_actions =
      ai_messages_for_actor_event(start_input.id)
      |> tool_results("interactive_terminal")
      |> Enum.reject(&tool_result_error?/1)
      |> Enum.map(&tool_detail(&1.arguments, ["action"]))

    assert start_actions == ~w(start send)
    assert_actor_event_completed!(start_input.id)

    assert_lark_final_reply(
      fake_feishu,
      start_reply,
      "CHAOS_TERMINAL_PERSIST_START_OK",
      :reply,
      "om_terminal_persist_start_1"
    )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_terminal_persist_read_1",
               message_id: "om_terminal_persist_read_1",
               chat_id: "oc_chaos_terminal_persist",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_TERMINAL_PERSIST_READ. Reuse the existing terminal, prove its cwd/file persisted, kill it, then reply exactly CHAOS_TERMINAL_PERSIST_READ_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_500, :millisecond), :millisecond)
             )

    read_input = actor_event_by_source_entry_id!(agent.uid, "om_terminal_persist_read_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               read_input,
               DateTime.add(read_input.available_at, 1, :second)
             )

    assert {:ok, read_reply, _read_message} =
             wait_for_completed_final_reply(container, read_input.id, deadline(90_000))

    assert read_reply.text =~ "CHAOS_TERMINAL_PERSIST_READ_OK"

    terminal_results =
      ai_messages_for_actor_event(read_input.id)
      |> tool_results("interactive_terminal")
      |> Enum.reject(&tool_result_error?/1)

    assert Enum.map(terminal_results, &tool_detail(&1.arguments, ["action"])) ==
             ~w(send capture kill)

    capture = Enum.find(terminal_results, &(tool_detail(&1.arguments, ["action"]) == "capture"))
    assert inspect(capture.result) =~ "CHAOS_TERMINAL_PERSISTED"

    assert_actor_event_completed!(read_input.id)
    %{input: read_input, reply: read_reply}
  end

  @doc """
  Verifies background command start, status, and kill all use the real worker process table.
  """
  def run_background_command_lifecycle(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_background_lifecycle_1",
               message_id: "om_background_lifecycle_1",
               chat_id: "oc_chaos_background",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_BACKGROUND_LIFECYCLE. Start a background command, check its status, kill it, then reply exactly CHAOS_BACKGROUND_LIFECYCLE_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_600, :millisecond), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_background_lifecycle_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_BACKGROUND_LIFECYCLE_OK"

    command_results =
      ai_messages_for_actor_event(input.id)
      |> successful_tool_results("command")

    assert length(command_results) == 3

    statuses = Enum.map(command_results, &tool_detail(&1, ["status"]))
    assert "running" in statuses
    assert "killed" in statuses

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end
end
