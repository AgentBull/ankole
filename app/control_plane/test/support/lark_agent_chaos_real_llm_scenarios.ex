defmodule Ankole.LarkAgentChaos.E2E.RealLLMScenarios do
  @moduledoc """
  Live OpenRouter scenarios that still enter through fake Feishu WS frames.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      deadline: 1,
      tool_result_succeeded?: 2,
      wait_for_outbox_for_input: 4,
      wait_for_turn_status: 4
    ]

  import Ankole.LarkAgentChaos.E2E.Harness

  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.LarkAgentChaos.FeishuServer
  alias Ankole.Repo

  @base_time ~U[2026-06-24 08:00:00.000000Z]

  def run_real_lark_direct_turn(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_real_1",
               message_id: "om_real_1",
               chat_id: "oc_real_llm",
               text: "@_user_1 Reply exactly ANKOLE_LARK_REAL_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms: DateTime.to_unix(@base_time, :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_real_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(120_000), turn.id)

    assert outbox.payload["text"] =~ "ANKOLE_LARK_REAL_OK"

    assert {:ok, %LlmTurn{status: "succeeded"}} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    refute Repo.get(ActorInput, input.id)
    turn
  end

  def run_real_lark_skill_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_real_skill_1",
               message_id: "om_real_skill_1",
               chat_id: "oc_real_llm",
               text: """
               @_user_1 This is a two-step skill_append test.
               Step 1: If you have not yet received a skill_append tool result in this conversation, call skill_append exactly once with name exactly "nano-pdf" and content exactly "Lark real overlay: ANKOLE_LARK_REAL_SKILL_OK".
               Step 2: After the first successful skill_append tool result is visible, do not call any more tools. Reply exactly ANKOLE_LARK_REAL_SKILL_OK.
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 2, :second), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_real_skill_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(180_000), turn.id)

    assert outbox.payload["text"] =~ "ANKOLE_LARK_REAL_SKILL_OK"

    persisted_turn = Repo.get!(LlmTurn, turn.id)
    assert persisted_turn.status == "succeeded"
    assert tool_result_succeeded?(persisted_turn.tool_results, "skill_append")

    assert %AgentSkillOverlay{overlay_json: %{"text" => content}} =
             AgentSkillOverlay
             |> where([overlay], overlay.agent_uid == ^agent_uid)
             |> where([overlay], overlay.skill_name == "nano-pdf")
             |> where([overlay], is_nil(overlay.deleted_at))
             |> Repo.one()

    assert content == "Lark real overlay: ANKOLE_LARK_REAL_SKILL_OK"

    refute Repo.get(ActorInput, input.id)
    turn
  end
end
