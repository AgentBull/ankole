defmodule Ankole.LarkAgentChaos.E2E.ComputerStateScenarios do
  @moduledoc """
  Cross-turn computer state scenarios for the Docker worker chaos suite.
  """

  import ExUnit.Assertions

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      deadline: 1,
      wait_for_outbox_for_input: 4,
      wait_for_turn_status: 4
    ]

  import Ankole.LarkAgentChaos.E2E.Harness

  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.LarkAgentChaos.FeishuServer
  alias Ankole.Repo

  @base_time ~U[2026-06-24 08:00:00.000000Z]

  @doc """
  Verifies a tmux-backed interactive terminal survives across separate turns.
  """
  def run_interactive_terminal_persistence(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    start_input = actor_input_by_provider_entry_id!(agent_uid, "om_terminal_persist_start_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: start_turn}} =
             process_ready_input_for_actor!(
               start_input,
               DateTime.add(start_input.available_at, 1, :second)
             )

    assert {:ok, start_outbox} =
             wait_for_outbox_for_input(container, start_input.id, deadline(90_000), start_turn.id)

    assert start_outbox.payload["text"] =~ "CHAOS_TERMINAL_PERSIST_START_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_start_turn} =
             wait_for_turn_status(container, start_turn.id, "succeeded", deadline(10_000))

    start_actions =
      persisted_start_turn.tool_results
      |> successful_tool_results("interactive_terminal")
      |> Enum.map(&get_in(&1, ["result", "details", "action"]))

    assert start_actions == ~w(start send)
    refute Repo.get(ActorInput, start_input.id)

    dispatch_and_assert_lark_outbox(
      persisted_start_turn,
      "CHAOS_TERMINAL_PERSIST_START_OK",
      :reply,
      "om_terminal_persist_start_1"
    )

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    read_input = actor_input_by_provider_entry_id!(agent_uid, "om_terminal_persist_read_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: read_turn}} =
             process_ready_input_for_actor!(
               read_input,
               DateTime.add(read_input.available_at, 1, :second)
             )

    assert {:ok, read_outbox} =
             wait_for_outbox_for_input(container, read_input.id, deadline(90_000), read_turn.id)

    assert read_outbox.payload["text"] =~ "CHAOS_TERMINAL_PERSIST_READ_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_read_turn} =
             wait_for_turn_status(container, read_turn.id, "succeeded", deadline(10_000))

    terminal_results =
      successful_tool_results(persisted_read_turn.tool_results, "interactive_terminal")

    assert Enum.map(terminal_results, &get_in(&1, ["result", "details", "action"])) ==
             ~w(send capture kill)

    assert terminal_results
           |> Enum.find(&(get_in(&1, ["result", "details", "action"]) == "capture"))
           |> inspect()
           |> String.contains?("CHAOS_TERMINAL_PERSISTED")

    refute Repo.get(ActorInput, read_input.id)
    persisted_read_turn
  end

  @doc """
  Verifies background command start, status, and kill all use the real worker process table.
  """
  def run_background_command_lifecycle(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
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

    input = actor_input_by_provider_entry_id!(agent_uid, "om_background_lifecycle_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_BACKGROUND_LIFECYCLE_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    command_results = successful_tool_results(persisted_turn.tool_results, "command")
    assert length(command_results) == 3

    statuses = Enum.map(command_results, &get_in(&1, ["result", "details", "status"]))
    assert "running" in statuses
    assert "killed" in statuses
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end
end
