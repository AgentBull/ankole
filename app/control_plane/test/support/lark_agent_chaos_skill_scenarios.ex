defmodule Ankole.LarkAgentChaos.E2E.SkillScenarios do
  @moduledoc """
  Skill-tool scenarios for the Docker worker chaos suite.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  import Ankole.ActorRuntimeWorkerE2E.Scenarios,
    only: [
      deadline: 1,
      tool_result_succeeded?: 2,
      wait_for_outbox_for_input: 4,
      wait_for_turn_status: 4
    ]

  import Ankole.LarkAgentChaos.E2E.Harness

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.AIAgent.Schemas.LlmTurn
  alias Ankole.Actors.ActorInput
  alias Ankole.LarkAgentChaos.FeishuServer
  alias Ankole.Repo

  @base_time ~U[2026-06-24 08:00:00.000000Z]

  @doc """
  Runs `skill_view` through the Docker worker and verifies it reads a real skill file.
  """
  def run_skill_view_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_skill_view_1",
               message_id: "om_skill_view_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_VIEW. Use skill_view for nano-pdf once, then reply exactly CHAOS_SKILL_VIEW_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_050, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_skill_view_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_SKILL_VIEW_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert [skill_result] = successful_tool_results(persisted_turn.tool_results, "skill_view")
    assert inspect(skill_result) =~ "# nano-pdf"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  @doc """
  Verifies every phase-one built-in skill is visible to the real Docker worker.
  """
  def run_all_builtin_skill_views(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_skill_view_all_1",
               message_id: "om_skill_view_all_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_VIEW_ALL. Use skill_view for jupyter-live-kernel, nano-pdf, and powerpoint, then reply exactly CHAOS_SKILL_VIEW_ALL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_060, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_skill_view_all_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_SKILL_VIEW_ALL_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    skill_results = successful_tool_results(persisted_turn.tool_results, "skill_view")
    assert length(skill_results) == 3
    rendered = inspect(skill_results)
    assert rendered =~ "# Jupyter Live Kernel"
    assert rendered =~ "# nano-pdf"
    assert rendered =~ "# Powerpoint Skill"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  @doc """
  Runs `skill_append` through RuntimeFabric and verifies the DB-backed overlay.
  """
  def run_skill_append_tool_loop(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_skill_append_1",
               message_id: "om_skill_append_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_APPEND. Use skill_append for nano-pdf once, then reply exactly CHAOS_SKILL_APPEND_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_075, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_skill_append_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_SKILL_APPEND_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert tool_result_succeeded?(persisted_turn.tool_results, "skill_append")

    assert %AgentSkillOverlay{overlay_json: %{"text" => overlay_text}} =
             Repo.one(
               from(overlay in AgentSkillOverlay,
                 where: overlay.agent_uid == ^agent_uid,
                 where: overlay.skill_name == "nano-pdf",
                 where: is_nil(overlay.deleted_at)
               )
             )

    assert overlay_text == "Lark fake overlay: CHAOS_SKILL_APPEND_OK"
    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end

  @doc """
  Verifies disabled skills are absent from the worker-visible enabled skill set.
  """
  def run_disabled_skill_guardrail(agent_uid, dispatcher, container) do
    mention = lark_bot_mention()

    assert {:ok, _result} = Library.sync_agent_skills(agent_uid)

    disabled_skill =
      Repo.get_by!(AgentSkill,
        agent_uid: String.downcase(agent_uid),
        skill_name: "nano-pdf"
      )

    assert {:ok, %AgentSkill{enabled: false}} =
             disabled_skill
             |> AgentSkill.changeset(%{enabled: false})
             |> Repo.update()

    assert {:ok, enabled_skills} = Library.enabled_skills_for_agent(agent_uid)
    refute Enum.any?(enabled_skills, &(&1["skill_name"] == "nano-pdf"))

    assert {:ok, :ok} =
             FeishuServer.push_message(dispatcher,
               event_id: "evt_skill_disabled_1",
               message_id: "om_skill_disabled_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_DISABLED. Try skill_view for nano-pdf once, then reply exactly CHAOS_SKILL_DISABLED_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_090, :millisecond), :millisecond)
             )

    input = actor_input_by_provider_entry_id!(agent_uid, "om_skill_disabled_1")

    assert {:ok, %{send_outcome: "sent_or_queued", llm_turn: turn}} =
             process_ready_input_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, outbox} =
             wait_for_outbox_for_input(container, input.id, deadline(90_000), turn.id)

    assert outbox.payload["text"] =~ "CHAOS_SKILL_DISABLED_OK"

    assert {:ok, %LlmTurn{status: "succeeded"} = persisted_turn} =
             wait_for_turn_status(container, turn.id, "succeeded", deadline(10_000))

    assert Enum.any?(persisted_turn.tool_results, fn
             %{"tool_name" => "skill_view", "is_error" => true} = result ->
               inspect(result) =~ "skill is not enabled"

             _result ->
               false
           end)

    refute Repo.get(ActorInput, input.id)
    persisted_turn
  end
end
