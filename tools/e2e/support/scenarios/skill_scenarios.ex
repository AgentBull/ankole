defmodule Ankole.E2E.Scenarios.Skill do
  @moduledoc """
  Skill-tool scenarios for the Docker worker suites.
  """

  import Ecto.Query, only: [from: 2]
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_for_completed_final_reply: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  @doc """
  Runs `skill_view` through the Docker worker and verifies it reads a real skill file.
  """
  def run_skill_view_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    input = actor_event_by_source_entry_id!(agent.uid, "om_skill_view_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_SKILL_VIEW_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert [skill_result] = successful_tool_results(messages, "skill_view")
    assert inspect(skill_result) =~ "# nano-pdf"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies every phase-one built-in skill is visible to the real Docker worker.
  """
  def run_all_builtin_skill_views(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    input = actor_event_by_source_entry_id!(agent.uid, "om_skill_view_all_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_SKILL_VIEW_ALL_OK"

    messages = ai_messages_for_actor_event(input.id)
    skill_results = successful_tool_results(messages, "skill_view")
    assert length(skill_results) == 3
    rendered = inspect(skill_results)
    assert rendered =~ "# Jupyter Live Kernel"
    assert rendered =~ "# nano-pdf"
    assert rendered =~ "# Powerpoint Skill"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Runs `skill_append` through RuntimeFabric and verifies the DB-backed overlay.
  """
  def run_skill_append_tool_loop(%{fake_feishu: fake_feishu, agent: agent, container: container}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    input = actor_event_by_source_entry_id!(agent.uid, "om_skill_append_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_SKILL_APPEND_OK"

    messages = ai_messages_for_actor_event(input.id)
    assert tool_result_succeeded?(messages, "skill_append")

    assert %AgentSkillOverlay{overlay_json: %{"text" => overlay_text}} =
             Repo.one(
               from(overlay in AgentSkillOverlay,
                 where: overlay.agent_uid == ^agent.uid,
                 where: overlay.skill_name == "nano-pdf",
                 where: is_nil(overlay.deleted_at)
               )
             )

    assert overlay_text == "Lark fake overlay: CHAOS_SKILL_APPEND_OK"

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies disabled skills are absent from the worker-visible enabled skill set.
  """
  def run_disabled_skill_guardrail(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    mention = lark_bot_mention()

    assert {:ok, _result} = Library.sync_agent_skills(agent.uid)

    disabled_skill =
      Repo.get_by!(AgentSkill,
        agent_uid: String.downcase(agent.uid),
        skill_name: "nano-pdf"
      )

    assert {:ok, %AgentSkill{enabled: false}} =
             disabled_skill
             |> AgentSkill.changeset(%{enabled: false})
             |> Repo.update()

    assert {:ok, enabled_skills} = Library.enabled_skills_for_agent(agent.uid)
    refute Enum.any?(enabled_skills, &(&1["skill_name"] == "nano-pdf"))

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
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

    input = actor_event_by_source_entry_id!(agent.uid, "om_skill_disabled_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_SKILL_DISABLED_OK"

    messages = ai_messages_for_actor_event(input.id)

    assert Enum.any?(tool_results(messages, "skill_view"), fn call ->
             tool_result_error?(call) and inspect(call.result) =~ "skill is not enabled"
           end)

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply}
  end
end
