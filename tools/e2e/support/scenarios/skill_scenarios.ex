defmodule Ankole.E2E.Scenarios.Skill do
  @moduledoc """
  Skill-tool scenarios for the control plane and Docker Worker suites.
  """

  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      deadline: 1,
      wait_for_completed_final_reply: 3,
      ai_messages_for_signal: 1
    ]

  alias Ankole.AIAgent.Library
  alias Ankole.AIAgent.Library.Schemas.AgentSkill
  alias Ankole.Repo

  @base_time ~U[2026-07-02 01:34:05.000000Z]

  @doc """
  Runs `skill_view` through the control plane and verifies the enabled Skill.
  """
  def run_skill_view_tool_loop(%{fake_feishu: fake_feishu, agent: agent}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_skill_view_1",
               message_id: "om_skill_view_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_VIEW. Use skill_view for pdf once, then reply exactly CHAOS_SKILL_VIEW_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_050, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_skill_view_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(%{agent_uid: agent.uid}, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_SKILL_VIEW_OK"

    messages = ai_messages_for_signal(input.id)
    assert [skill_result] = successful_tool_results(messages, "skill_view")
    rendered = inspect(skill_result)
    assert rendered =~ "pdf Skill is a background-task capability"
    assert rendered =~ "create_background_job"
    refute rendered =~ "skill://"
    refute rendered =~ "directory="
    refute rendered =~ "# PDF"

    assert_signal_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies that the main Agent receives the routing for background-task Skills.
  """
  def run_all_builtin_skill_views(%{fake_feishu: fake_feishu, agent: agent}) do
    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_skill_view_all_1",
               message_id: "om_skill_view_all_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_VIEW_ALL. Use skill_view for jupyter-live-kernel and pdf, then reply exactly CHAOS_SKILL_VIEW_ALL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_060, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_skill_view_all_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(%{agent_uid: agent.uid}, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_SKILL_VIEW_ALL_OK"

    messages = ai_messages_for_signal(input.id)
    skill_results = successful_tool_results(messages, "skill_view")
    assert length(skill_results) == 2
    rendered = inspect(skill_results)

    # One Skill of each runtime. `pdf` is background-job-only, so the main agent
    # receives the routing and never its body or location. `jupyter-live-kernel`
    # runs in the main agent, so it receives the real instructions.
    assert rendered =~ "pdf Skill is a background-task capability"
    assert rendered =~ "create_background_job"
    refute rendered =~ "skill://enabled/pdf"
    refute rendered =~ "# PDF"

    assert rendered =~ "# Jupyter Live Kernel"

    assert_signal_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies that disabled Skills are absent from the model's enabled Skill set.
  """
  def run_disabled_skill_guardrail(%{
        fake_feishu: fake_feishu,
        agent: agent
      }) do
    mention = lark_bot_mention()

    assert {:ok, _result} = Library.sync_agent_skills(agent.uid)

    assert {:ok, %AgentSkill{enabled_override: false}} =
             Library.set_agent_skill_override(agent.uid, "pdf", false)

    assert {:ok, enabled_skills} = Library.enabled_skills_for_agent(agent.uid)
    refute Enum.any?(enabled_skills, &(&1["skill_name"] == "pdf"))

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_skill_disabled_1",
               message_id: "om_skill_disabled_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_SKILL_DISABLED. Try skill_view for pdf once, then reply exactly CHAOS_SKILL_DISABLED_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_090, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_skill_disabled_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(%{agent_uid: agent.uid}, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_SKILL_DISABLED_OK"

    messages = ai_messages_for_signal(input.id)

    assert Enum.any?(tool_results(messages, "skill_view"), fn call ->
             tool_result_error?(call) and inspect(call.result) =~ "skill is not enabled"
           end)

    assert_signal_completed!(input.id)
    %{input: input, reply: reply}
  end

  @doc """
  Verifies that the control plane reads an installed Skill from the Agent's
  drive before context resolve, and removes it from the catalog after its
  drive folder is deleted. The real Worker uses that catalog.
  """
  def run_installed_skill_registry_loop(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    put_drive_file!(
      agent.uid,
      "skills/e2e-installed/SKILL.md",
      """
      ---
      name: e2e-installed
      description: E2E installed skill.
      default_enabled: true
      category: custom
      ---

      # E2E Installed Skill

      E2E_INSTALLED_SKILL_BODY
      """
    )

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_installed_skill_1",
               message_id: "om_installed_skill_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_INSTALLED_SKILL. Use skill_view for e2e-installed once, then reply exactly CHAOS_INSTALLED_SKILL_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_100, :millisecond), :millisecond)
             )

    input = signal_by_provider_message_id!(agent.uid, "om_installed_skill_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.message.text =~ "CHAOS_INSTALLED_SKILL_OK"

    messages = ai_messages_for_signal(input.id)
    skill_tool_results = tool_results(messages, "skill_view")

    successful_results =
      skill_tool_results
      |> Enum.reject(&tool_result_error?/1)
      |> Enum.map(& &1.result)

    if successful_results == [] do
      flunk("""
      expected e2e-installed skill_view to succeed
      tool_results=#{inspect(skill_tool_results, limit: :infinity, printable_limit: 4_000)}
      messages=#{inspect(messages, limit: :infinity, printable_limit: 4_000)}
      """)
    end

    assert [skill_result] = successful_results

    assert inspect(skill_result) =~ "E2E_INSTALLED_SKILL_BODY"

    assert %AgentSkill{source_kind: "installed"} =
             Repo.get_by!(AgentSkill, agent_uid: agent.uid, skill_name: "e2e-installed")

    # Removing the drive folder uninstalls the Skill: the next context read
    # removes its catalog row, and the Worker removes its cached files.
    assert {:ok, 1} = Ankole.Files.delete(agent.uid, "skills/e2e-installed")

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_installed_skill_deleted_1",
               message_id: "om_installed_skill_deleted_1",
               chat_id: "oc_chaos_skill",
               chat_type: "p2p",
               text:
                 "@_user_1 Run CHAOS_INSTALLED_SKILL_DELETED. Try skill_view for e2e-installed once, then reply exactly CHAOS_INSTALLED_SKILL_DELETED_OK.",
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 5_110, :millisecond), :millisecond)
             )

    deleted_input = signal_by_provider_message_id!(agent.uid, "om_installed_skill_deleted_1")

    assert {:ok, %{status: :driving}} =
             ensure_input_driver!(
               deleted_input,
               DateTime.add(deleted_input.available_at, 1, :second)
             )

    assert {:ok, deleted_reply, _message} =
             wait_for_completed_final_reply(container, deleted_input.id, deadline(90_000))

    assert deleted_reply.message.text =~ "CHAOS_INSTALLED_SKILL_DELETED_OK"

    deleted_messages = ai_messages_for_signal(deleted_input.id)

    assert Enum.any?(tool_results(deleted_messages, "skill_view"), fn call ->
             tool_result_error?(call) and inspect(call.result) =~ "skill is not enabled"
           end)

    refute Repo.get_by(AgentSkill, agent_uid: agent.uid, skill_name: "e2e-installed")

    assert_signal_completed!(input.id)
    assert_signal_completed!(deleted_input.id)
    %{input: input, reply: reply, deleted_input: deleted_input, deleted_reply: deleted_reply}
  end
end
