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
                 "@_user_1 Run CHAOS_SKILL_VIEW_ALL. Use skill_view for docx, jupyter-live-kernel, nano-pdf, pptx, and xlsx, then reply exactly CHAOS_SKILL_VIEW_ALL_OK.",
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
    assert length(skill_results) == 5
    rendered = inspect(skill_results)
    assert rendered =~ "# OfficeCLI DOCX Skill"
    assert rendered =~ "# Jupyter Live Kernel"
    assert rendered =~ "# nano-pdf"
    assert rendered =~ "# OfficeCLI PPTX Skill"
    assert rendered =~ "# OfficeCLI XLSX Skill"

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

    assert {:ok, %AgentSkill{enabled: false}} =
             Library.set_agent_skill_enabled(agent.uid, "nano-pdf", false)

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

  @doc """
  Verifies worker-scanned installed skills are registered before context resolve
  and removed authoritatively after the worker directory is deleted.
  """
  def run_installed_skill_registry_loop(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container
      }) do
    skill_dir = "/workspace/shared/skills/agents/#{agent.uid}/e2e-installed"
    docker_exec!(container, ["mkdir", "-p", skill_dir])

    docker_write_text!(
      container,
      "#{skill_dir}/SKILL.md",
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

    input = actor_event_by_source_entry_id!(agent.uid, "om_installed_skill_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, _message} =
             wait_for_completed_final_reply(container, input.id, deadline(90_000))

    assert reply.text =~ "CHAOS_INSTALLED_SKILL_OK"

    messages = ai_messages_for_actor_event(input.id)
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

    docker_exec!(container, ["rm", "-rf", skill_dir])

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

    deleted_input = actor_event_by_source_entry_id!(agent.uid, "om_installed_skill_deleted_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(
               deleted_input,
               DateTime.add(deleted_input.available_at, 1, :second)
             )

    assert {:ok, deleted_reply, _message} =
             wait_for_completed_final_reply(container, deleted_input.id, deadline(90_000))

    assert deleted_reply.text =~ "CHAOS_INSTALLED_SKILL_DELETED_OK"

    deleted_messages = ai_messages_for_actor_event(deleted_input.id)

    assert Enum.any?(tool_results(deleted_messages, "skill_view"), fn call ->
             tool_result_error?(call) and inspect(call.result) =~ "skill is not enabled"
           end)

    refute Repo.get_by(AgentSkill, agent_uid: agent.uid, skill_name: "e2e-installed")

    assert_actor_event_completed!(input.id)
    assert_actor_event_completed!(deleted_input.id)
    %{input: input, reply: reply, deleted_input: deleted_input, deleted_reply: deleted_reply}
  end

  defp docker_exec!(container, args) do
    {output, status} =
      System.cmd(docker_path(), ["exec", container.name | args], stderr_to_stdout: true)

    assert status == 0, output
    output
  end

  defp docker_write_text!(container, path, text) do
    script = "cat > #{shell_quote(path)} <<'EOF'\n#{text}\nEOF\n"
    docker_exec!(container, ["sh", "-lc", script])
  end

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end

  defp shell_quote(value) do
    "'" <> String.replace(value, "'", "'\"'\"'") <> "'"
  end
end
