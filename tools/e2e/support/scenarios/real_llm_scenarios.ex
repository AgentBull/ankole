defmodule Ankole.E2E.Scenarios.RealLLM do
  @moduledoc """
  Live OpenRouter scenarios that still enter through fake Feishu WS frames.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_for_completed_final_reply: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  def run_real_lark_direct_turn(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_1",
               message_id: "om_real_1",
               chat_id: "oc_real_llm",
               text: "@_user_1 Reply exactly ANKOLE_LARK_REAL_OK. Do not call tools.",
               mentions: [mention],
               create_time_ms: DateTime.to_unix(@base_time, :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(120_000))

    assert reply.text =~ "ANKOLE_LARK_REAL_OK"
    assert_actor_event_completed!(input.id)

    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_skill_tool_loop(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_skill_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(180_000))

    assert reply.text =~ "ANKOLE_LARK_REAL_SKILL_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert tool_result_succeeded?(messages, "skill_append")

    assert %AgentSkillOverlay{overlay_json: %{"text" => content}} =
             AgentSkillOverlay
             |> where([overlay], overlay.agent_uid == ^agent.uid)
             |> where([overlay], overlay.skill_name == "nano-pdf")
             |> where([overlay], is_nil(overlay.deleted_at))
             |> Repo.one()

    assert content == "Lark real overlay: ANKOLE_LARK_REAL_SKILL_OK"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end
end
