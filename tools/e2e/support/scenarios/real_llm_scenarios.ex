# FUTURE AGENT GUARDRAIL: this module is a synthetic real-provider scenario that
# enters through fake Feishu frames; it is NOT a real user-facing end-to-end test.
# Unless the user explicitly asks to modify this exact file, changing it to make
# acceptance checks, regressions, or coverage pass is reward hacking. Fix the
# business code and validate through the real Feishu web UI instead.
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
      wait_until: 2,
      wait_for_completed_actor_event_message: 3,
      wait_for_completed_final_reply: 3,
      wait_for_completed_outbox: 3,
      ai_messages_for_actor_event: 1
    ]

  alias Ankole.AIAgent.Library.Schemas.AgentSkillOverlay
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig
  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.AppConfigure
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: BackgroundAgentJob
  alias Ankole.BackgroundAgentJobs.Schemas.Turn, as: BackgroundAgentJobTurn
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.Entry

  @base_time ~U[2026-07-02 01:34:05.000000Z]
  @real_coding_model "z-ai/glm-5.2"
  @real_vision_model "google/gemini-3.1-flash-lite"
  @real_tool_model "z-ai/glm-5.2"
  @real_text_only_model "z-ai/glm-5.2"
  @codex_real_llm_inactivity_timeout_ms 300_000
  @todolist_owner_workdir "/workspace/user-files/background-agent-jobs/ankole-codex-todolist-real"
  @todolist_job_workdir "/workspace/workspaces/workspace"
  @pptx_owner_workdir "/workspace/user-files/background-agent-jobs/ankole-codex-pptx-real"
  @pptx_job_workdir "/workspace/workspaces/workspace"
  @pptx_name "ankole-skill-handoff.pptx"
  @pptx_path Path.join(@pptx_owner_workdir, @pptx_name)
  @pptx_job_path Path.join(@pptx_job_workdir, @pptx_name)
  @pptx_container_path "/workspace/shared/user-files/background-agent-jobs/ankole-codex-pptx-real/ankole-skill-handoff.pptx"
  @pptx_background "The audience is Ankole maintainers evaluating whether BackgroundAgentJob execution preserves explicitly selected capabilities."
  @pptx_notes "Keep the delivery concise and do not create unrelated files. Execution-context marker: ANKOLE_PPTX_AGENTS_CONTEXT."
  @pptx_task """
  Create exactly one PowerPoint file at #{@pptx_job_path}.

  Requirements and acceptance criteria:
  1. Use the $pptx skill through Codex's native skill support and follow its SKILL.md instructions.
  2. Create exactly two slides. Slide 1 title must be "Ankole Job" and its body must contain exactly "Codex shares enabled skills." Slide 2 title must be "Verified Handoff" and its body must contain exactly "Parent verifies before delivery."
  3. Give both slides an intentional, readable visual layout and speaker notes. Do not create any other deliverable files.
  4. Run officecli save, officecli validate, and officecli view of the final deck in outline mode. Resolve every validation error before finishing.
  5. In the final report, include the exact marker ANKOLE_CODEX_PPTX_JOB_DONE, the output path, the validation result, and the execution-context marker supplied by the task-level AGENTS Notes. Do not guess that marker from this task; read the AGENTS guidance.
  """
  @vision_expected_answer "false"
  @vision_fixture_path Path.expand("../../fixtures/vision-dog.jpeg", __DIR__)

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

  def run_real_lark_web_fetch_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_tool_model, %{})

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_web_fetch_rendered_fallback_1",
               message_id: "om_real_web_fetch_rendered_fallback_1",
               chat_id: "oc_real_llm_web_fetch",
               text: """
               @_user_1 Web fetch task. Use web_fetch exactly once for https://example.com.

               Use only web_fetch for the page read; do not use command, read_file, external APIs, direct fetches, or prior knowledge.
               After the web_fetch tool result is visible, reply with one line in this exact format:
               ANKOLE_WEB_FETCH_LIVE_OK title=<page title> evidence=<short fetched text proving the page content>
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 9, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_web_fetch_rendered_fallback_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(240_000))

    assert reply.text =~ "ANKOLE_WEB_FETCH_LIVE_OK"
    assert reply.text =~ "Example Domain"

    messages = ai_messages_for_actor_event(input.id)
    assert [fetch_call] = tool_results(messages, "web_fetch")
    assert fetch_call.arguments == %{"urls" => ["https://example.com"]}
    refute tool_result_error?(fetch_call)

    fetch_result = fetch_call.result
    assert %{"raw" => fetch_output} = fetch_result
    assert fetch_output =~ "Example Domain"
    assert fetch_output =~ "documentation examples"

    called_tools =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])

    assert called_tools == ["web_fetch"]

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_terminal_tools_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_tool_model, %{})

    mention = lark_bot_mention()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_terminal_tools_1",
               message_id: "om_real_terminal_tools_1",
               chat_id: "oc_real_llm_terminal_tools",
               text: """
               @_user_1 Terminal tools task in the isolated Ankole Agent Computer workspace. Do not use browser tools, external APIs, or prior knowledge.

               User story: I need a small reproducible pickup report for today's operations handoff.

               Required path:
               1. Use the command tool to create the directory /workspace/temp/ankole-terminal-tools-real.
               2. Use the patch tool in replace mode with old_string exactly "" to create /workspace/temp/ankole-terminal-tools-real/orders.csv with exactly this CSV content:
                  region,owner,items
                  north,Ada,2
                  south,Bo,5
                  north,Cy,4
                  west,Dee,3
               3. Use the patch tool in replace mode with old_string exactly "" to create /workspace/temp/ankole-terminal-tools-real/summarize.js. The script must read orders.csv, compute item totals by region, and write report.md.
               4. Run the script with the command tool from /workspace/temp/ankole-terminal-tools-real.
               5. Use read_file to inspect /workspace/temp/ankole-terminal-tools-real/report.md.
               6. Only after the read_file result proves the report, reply exactly:
                  ANKOLE_TERMINAL_TOOLS_REAL_OK north=6 south=5 west=3 total=14

               The report.md content must include these exact lines:
               north: 6
               south: 5
               west: 3
               total: 14
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 10, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_terminal_tools_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply_with_trace(container, input.id, deadline(360_000))

    messages = ai_messages_for_actor_event(input.id)

    assert_text_contains_with_trace!(
      reply.text,
      "ANKOLE_TERMINAL_TOOLS_REAL_OK",
      input.id,
      messages
    )

    assert_text_contains_with_trace!(reply.text, "north=6", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "south=5", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "west=3", input.id, messages)
    assert_text_contains_with_trace!(reply.text, "total=14", input.id, messages)

    assert replace_create_patch_calls(messages) >= 2
    assert command_tool_succeeded?(messages)

    read_results = successful_tool_results(messages, "read_file")
    assert read_results != []
    final_report = read_results |> List.last() |> inspect()
    assert final_report =~ "north: 6"
    assert final_report =~ "south: 5"
    assert final_report =~ "west: 3"
    assert final_report =~ "total: 14"

    called_tools =
      messages
      |> function_call_items()
      |> Enum.map(& &1["name"])

    refute Enum.any?(called_tools, &String.starts_with?(&1, "browser_"))

    assert_actor_event_completed!(input.id)
    %{input: input, reply: reply, message: message}
  end

  def run_real_lark_codex_todolist_turn(
        %{
          fake_feishu: fake_feishu,
          agent: agent,
          container: container,
          provider_id: provider_id
        } = ctx
      ) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_coding_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "heavy", @real_coding_model, %{})

    case ctx do
      %{codex_account_id: account_id} ->
        assert {:ok, _profile} =
                 ModelProfiles.put_model_profile(agent.uid, "coding", %{
                   "codex_account_id" => account_id
                 })

      _ctx ->
        put_real_model_profile!(agent.uid, provider_id, "coding", @real_coding_model, %{})
    end

    put_agent_inactivity_timeout!(agent.uid, @codex_real_llm_inactivity_timeout_ms)

    mention = lark_bot_mention()

    task = """
    Create the smallest possible Vite + React TypeScript in-memory todolist demo in #{@todolist_job_workdir}.
    Keep the source tiny and write only package.json plus index.html, src/App.tsx, and src/index.scss.
    The app only needs React useState, add/toggle/delete todo behavior, and a visible remaining count.
    No polish, no extra files, and no tests. Run bun install and bun run build. The final answer must
    include ANKOLE_CODEX_TODOLIST_JOB_DONE.
    """

    start_arguments =
      Ankole.JSON.encode!(%{
        "action" => "start",
        "title" => "Build the real todolist demo",
        "task" => task,
        "workspace_mounts" => [
          %{
            "id" => "workspace",
            "source" => @todolist_owner_workdir,
            "access" => "read_write"
          }
        ]
      })

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_codex_todolist_1",
               message_id: "om_real_codex_todolist_1",
               chat_id: "oc_real_llm_codex_todolist",
               text: """
               @_user_1 Run this implementation as a BackgroundAgentJob.

               Call background_agent_job exactly once. Its decoded arguments must equal this JSON object:
               <background_agent_job_start_arguments_json>
               #{start_arguments}
               </background_agent_job_start_arguments_json>

               Immediately after background_agent_job(start) returns, reply exactly ANKOLE_CODEX_TODOLIST_STARTED.
               When the Job completion notification later wakes this conversation, call background_agent_job(status), verify ANKOLE_CODEX_TODOLIST_JOB_DONE, then reply exactly:
                  ANKOLE_CODEX_TODOLIST_REAL_OK build=passed verified=job

               Do not implement the app in this conversation and do not use web research.
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 12, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_codex_todolist_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, start_message} =
             wait_for_completed_actor_event_message(container, input.id, deadline(300_000))

    messages = ai_messages_for_actor_event(input.id)

    start_reply =
      case wait_for_completed_final_reply(container, input.id, deadline(60_000)) do
        {:ok, %Entry{} = reply, %{id: message_id}} when message_id == start_message.id ->
          reply

        {:ok, %Entry{} = _reply, other_message} ->
          flunk("""
          real background agent job start turn mirrored a different final message.
          expected_message_id=#{start_message.id}
          actual_message_id=#{other_message.id}
          final_message_text=#{inspect(message_text(start_message), printable_limit: 4_000)}
          tool_results=#{inspect(tool_results(messages), limit: :infinity, printable_limit: 4_000)}
          background_agent_jobs=#{inspect(background_agent_job_debug(input.id), limit: :infinity, printable_limit: 4_000)}
          """)
      end

    assert start_reply.text =~ "ANKOLE_CODEX_TODOLIST_STARTED"
    assert tool_result_succeeded?(messages, "background_agent_job")

    called_tools = messages |> function_call_items() |> Enum.map(& &1["name"])
    assert "background_agent_job" in called_tools

    job =
      Repo.one!(
        from(job in BackgroundAgentJob,
          where: job.agent_uid == ^agent.uid,
          where: job.source_actor_event_id == ^input.id
        )
      )

    assert job.workspace_mounts == [
             %{
               "id" => "workspace",
               "source" => @todolist_owner_workdir,
               "access" => "read_write"
             }
           ]

    dispatch_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^BackgroundAgentJobs.job_session_id(job.id),
          where: event.type == "background_agent_job.dispatch"
        )
      )

    assert {:ok, _result} =
             process_ready_event_for_actor!(
               dispatch_event,
               DateTime.add(dispatch_event.available_at, 1, :second)
             )

    assert {:ok, %BackgroundAgentJob{} = job} =
             wait_until(deadline(1_500_000), fn ->
               case Repo.get(BackgroundAgentJob, job.id) do
                 %BackgroundAgentJob{status: "succeeded"} = completed ->
                   completed

                 %BackgroundAgentJob{status: status} = failed
                 when status in ["failed", "stopped"] ->
                   flunk("""
                   real background agent job todolist job ended as #{status}.
                   background_agent_jobs=#{inspect(background_agent_job_debug(input.id), limit: :infinity, printable_limit: 8_000)}
                   failure=#{inspect(failed.error, printable_limit: 4_000)}
                   """)

                 _pending ->
                   nil
               end
             end)

    wakeup_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^input.session_id,
          where: event.type == "background_agent_job.completed",
          where:
            event.source_event_id ==
              ^"background_agent_job:#{job.id}:succeeded:#{job.attempts}"
        )
      )

    if is_nil(wakeup_event.completed_at) do
      assert {:ok, _result} =
               process_ready_event_for_actor!(
                 wakeup_event,
                 DateTime.add(wakeup_event.available_at, 1, :second)
               )
    end

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, wakeup_event.id, deadline(300_000))

    assert reply.text =~ "ANKOLE_CODEX_TODOLIST_REAL_OK"
    assert reply.text =~ "build=passed"
    assert reply.text =~ "verified=job"

    assert get_in(job.result, ["output_text"]) =~ "ANKOLE_CODEX_TODOLIST_JOB_DONE",
           """
           real Codex todolist job succeeded without the expected marker.
           background_agent_jobs=#{inspect(background_agent_job_debug(input.id), limit: :infinity, printable_limit: 8_000)}
           """

    turns =
      Repo.all(
        from(turn in BackgroundAgentJobTurn,
          where: turn.job_id == ^job.id,
          order_by: [asc: turn.started_at, asc: turn.id]
        )
      )

    assert turns != []
    assert List.last(turns).status == "completed"
    assert Enum.all?(turns, &(&1.trajectory["format"] == "ankole_chatml"))

    assert Enum.any?(turns, fn turn ->
             Enum.any?(turn.trajectory["messages"], fn message ->
               message["role"] == "assistant" and
                 is_binary(message["content"]) and
                 String.contains?(message["content"], "ANKOLE_CODEX_TODOLIST_JOB_DONE")
             end)
           end)

    assert_actor_event_completed!(input.id)
    assert_actor_event_completed!(dispatch_event.id)
    assert_actor_event_completed!(wakeup_event.id)
    %{input: input, reply: reply, message: message, job: job}
  end

  def run_real_lark_codex_pptx_skill_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_coding_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "heavy", @real_coding_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "coding", @real_coding_model, %{})
    put_agent_inactivity_timeout!(agent.uid, @codex_real_llm_inactivity_timeout_ms)

    mention = lark_bot_mention()

    start_arguments =
      Ankole.JSON.encode!(%{
        "action" => "start",
        "title" => "Create the real PPTX skill artifact",
        "task" => @pptx_task,
        "background" => @pptx_background,
        "notes" => @pptx_notes,
        "agent_plugin_ids" => ["office"],
        "workspace_mounts" => [
          %{
            "id" => "workspace",
            "source" => @pptx_owner_workdir,
            "access" => "read_write"
          }
        ]
      })

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: "evt_real_codex_pptx_1",
               message_id: "om_real_codex_pptx_1",
               chat_id: "oc_real_llm_codex_pptx",
               text: """
               @_user_1 Run this PowerPoint task as a BackgroundAgentJob.

               Initial-turn state machine:
               1. Call background_agent_job exactly once. Its decoded arguments must equal the JSON object below. Copy the complete strings; do not summarize, shorten, repair, or regenerate any field. The task value is intentionally long because it contains every requirement.
               2. After that one background_agent_job(start) result succeeds, do not call any more tools and never call background_agent_job(start) again. Your very next response must be exactly ANKOLE_CODEX_PPTX_STARTED.

               <background_agent_job_start_arguments_json>
               #{start_arguments}
               </background_agent_job_start_arguments_json>

               When the job completion notification wakes this conversation:
               1. Call background_agent_job(status) and verify both ANKOLE_CODEX_PPTX_JOB_DONE and ANKOLE_PPTX_AGENTS_CONTEXT in the result.
               2. Independently run officecli validate and officecli view in outline mode against #{@pptx_path} with the command tool.
               3. Call reply_attachment with path=#{inspect(@pptx_path)}, name=#{inspect(@pptx_name)}, and mimeType="application/vnd.openxmlformats-officedocument.presentationml.presentation".
               4. Reply exactly ANKOLE_CODEX_PPTX_REAL_OK slides=2 validate=passed attached=yes.

               Do not create the deck yourself and do not use web research.
               """,
               mentions: [mention],
               create_time_ms:
                 DateTime.to_unix(DateTime.add(@base_time, 13, :second), :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, "om_real_codex_pptx_1")

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, start_message} =
             wait_for_completed_actor_event_message(container, input.id, deadline(300_000))

    start_messages = ai_messages_for_actor_event(input.id)

    assert {:ok, %Entry{} = start_reply, %{id: start_message_id}} =
             wait_for_completed_final_reply(container, input.id, deadline(60_000))

    assert start_message_id == start_message.id
    assert start_reply.text =~ "ANKOLE_CODEX_PPTX_STARTED"
    assert tool_result_succeeded?(start_messages, "background_agent_job")

    background_agent_job_calls = function_call_items(start_messages, "background_agent_job")

    assert length(background_agent_job_calls) == 1,
           "expected exactly one background_agent_job call, got: #{inspect(background_agent_job_calls, limit: :infinity, printable_limit: 12_000)}"

    job =
      Repo.one!(
        from(job in BackgroundAgentJob,
          where: job.agent_uid == ^agent.uid,
          where: job.source_actor_event_id == ^input.id
        )
      )

    assert job.title == "Create the real PPTX skill artifact"

    assert job.skill_names == []

    assert job.agent_plugin_ids == ["office"]

    assert job.workspace_mounts == [
             %{
               "id" => "workspace",
               "source" => @pptx_owner_workdir,
               "access" => "read_write"
             }
           ]

    assert String.trim(job.task) == String.trim(@pptx_task)
    assert job.background == @pptx_background
    assert job.notes == @pptx_notes

    dispatch_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^BackgroundAgentJobs.job_session_id(job.id),
          where: event.type == "background_agent_job.dispatch"
        )
      )

    assert {:ok, _result} =
             process_ready_event_for_actor!(
               dispatch_event,
               DateTime.add(dispatch_event.available_at, 1, :second)
             )

    assert {:ok, %BackgroundAgentJob{} = job} =
             wait_until(deadline(1_500_000), fn ->
               case Repo.get(BackgroundAgentJob, job.id) do
                 %BackgroundAgentJob{status: "succeeded"} = completed ->
                   completed

                 %BackgroundAgentJob{status: status} = failed
                 when status in ["failed", "stopped"] ->
                   flunk("""
                   real background agent job PPTX job ended as #{status}.
                   background_agent_jobs=#{inspect(background_agent_job_debug(input.id), limit: :infinity, printable_limit: 12_000)}
                   failure=#{inspect(failed.error, printable_limit: 4_000)}
                   """)

                 _pending ->
                   nil
               end
             end)

    output_text = get_in(job.result, ["output_text"]) || ""
    assert output_text =~ "ANKOLE_CODEX_PPTX_JOB_DONE"
    assert output_text =~ "ANKOLE_PPTX_AGENTS_CONTEXT"

    turns =
      Repo.all(
        from(turn in BackgroundAgentJobTurn,
          where: turn.job_id == ^job.id,
          order_by: [asc: turn.started_at, asc: turn.id]
        )
      )

    assert turns != []
    assert List.last(turns).status == "completed"

    assert Enum.any?(turns, fn turn ->
             Enum.any?(turn.trajectory["messages"], fn message ->
               message["role"] == "assistant" and
                 is_binary(message["content"]) and
                 String.contains?(message["content"], "ANKOLE_CODEX_PPTX_JOB_DONE")
             end)
           end)

    trajectory_text = turns |> Enum.map(& &1.trajectory) |> Ankole.JSON.encode!()
    # Codex 0.144 native skill injection leaves no literal SKILL.md read in the
    # trajectory; the OfficeCLI workflow below is the evidence the skill governed
    # the work, and the artifact checks prove the outcome.
    assert trajectory_text =~ "officecli"

    validate_output = docker_exec!(container, ["officecli", "validate", @pptx_container_path])

    outline_output =
      docker_exec!(container, ["officecli", "view", @pptx_container_path, "outline"])

    text_output = docker_exec!(container, ["officecli", "view", @pptx_container_path, "text"])

    assert is_binary(validate_output)
    assert outline_output =~ "2 slides"
    assert text_output =~ "Ankole Job"
    assert text_output =~ "Verified Handoff"
    assert text_output =~ "Codex shares enabled skills."
    assert text_output =~ "Parent verifies before delivery."
    assert pptx_slide_count!(container, @pptx_container_path) == 2

    wakeup_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^input.session_id,
          where: event.type == "background_agent_job.completed",
          where:
            event.source_event_id ==
              ^"background_agent_job:#{job.id}:succeeded:#{job.attempts}"
        )
      )

    if is_nil(wakeup_event.completed_at) do
      assert {:ok, _result} =
               process_ready_event_for_actor!(
                 wakeup_event,
                 DateTime.add(wakeup_event.available_at, 1, :second)
               )
    end

    assert {:ok, outbox, _message} =
             wait_for_completed_outbox(container, wakeup_event.id, deadline(300_000))

    assert outbox.payload["text"] =~
             "ANKOLE_CODEX_PPTX_REAL_OK slides=2 validate=passed attached=yes"

    assert [attachment] = outbox.payload["attachments"]
    assert attachment["agent_computer_path"] == @pptx_path

    assert attachment["user_files_relative_path"] ==
             "background-agent-jobs/ankole-codex-pptx-real/#{@pptx_name}"

    assert attachment["name"] == @pptx_name

    assert attachment["mime_type"] ==
             "application/vnd.openxmlformats-officedocument.presentationml.presentation"

    assert attachment["size"] > 1_000

    wakeup_messages = ai_messages_for_actor_event(wakeup_event.id)
    assert command_tool_succeeded?(wakeup_messages)
    assert tool_result_succeeded?(wakeup_messages, "reply_attachment")

    sent = dispatch_outbox_succeeded!(outbox)
    platform_message = platform_message!(fake_feishu, sent.created_source_entry_id)
    assert platform_message.sender == :bot
    assert platform_message.msg_type == "file"
    assert platform_message.reply_to == "om_real_codex_pptx_1"
    assert {:ok, %{"file_key" => file_key}} = Ankole.JSON.decode(platform_message.content)

    assert %{name: @pptx_name, content: uploaded_content} =
             FakeFeishu.State.uploaded_file(fake_feishu.state, file_key)

    assert byte_size(uploaded_content) == attachment["size"]
    assert binary_part(uploaded_content, 0, 2) == "PK"
    assert [%{"provider_file_key" => ^file_key}] = sent.payload["attachments"]

    assert_actor_event_completed!(input.id)
    assert_actor_event_completed!(dispatch_event.id)
    assert_actor_event_completed!(wakeup_event.id)

    %{
      input: input,
      job: job,
      outbox: sent,
      platform_message: platform_message,
      outline: outline_output,
      text: text_output
    }
  end

  def run_real_lark_post_image_direct_vision_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_vision_model, %{})

    run_post_image_code_turn(
      fake_feishu,
      agent,
      container,
      event_id: "evt_real_image_direct_1",
      message_id: "om_real_image_direct_1",
      chat_id: "oc_real_llm_image_direct",
      file_key: "img_real_image_direct_1",
      create_time: DateTime.add(@base_time, 4, :second),
      prompt:
        "@_user_1 If the animal in the attached image is herbivorous, reply exactly true. Otherwise reply exactly false. Do not call tools."
    )
  end

  def run_real_lark_post_image_vision_fallback_turn(%{
        fake_feishu: fake_feishu,
        agent: agent,
        container: container,
        provider_id: provider_id
      }) do
    put_real_model_profile!(agent.uid, provider_id, "primary", @real_text_only_model, %{})
    put_real_model_profile!(agent.uid, provider_id, "vision_fallback", @real_vision_model, %{})

    result =
      run_post_image_code_turn(
        fake_feishu,
        agent,
        container,
        event_id: "evt_real_image_fallback_1",
        message_id: "om_real_image_fallback_1",
        chat_id: "oc_real_llm_image_fallback",
        file_key: "img_real_image_fallback_1",
        create_time: DateTime.add(@base_time, 6, :second),
        prompt:
          "@_user_1 If an <image_summary> block describes the attached image, decide whether the animal is herbivorous. Reply exactly true or false. If no animal is described, reply exactly UNKNOWN. Do not call tools."
      )

    assert_false_answer_text!(result.reply.text)
    assert fallback_summary_recorded?(result.input.id)

    result
  end

  defp run_post_image_code_turn(fake_feishu, agent, container, opts) do
    mention = lark_bot_mention()
    event_id = Keyword.fetch!(opts, :event_id)
    message_id = Keyword.fetch!(opts, :message_id)
    chat_id = Keyword.fetch!(opts, :chat_id)
    file_key = Keyword.fetch!(opts, :file_key)
    create_time = Keyword.fetch!(opts, :create_time)
    prompt = Keyword.fetch!(opts, :prompt)

    assert :ok =
             FakeFeishu.State.put_inbound_file(
               fake_feishu.state,
               file_key,
               vision_image_jpeg(),
               "vision-dog.jpeg"
             )

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: event_id,
               message_id: message_id,
               chat_id: chat_id,
               message_type: "post",
               content: %{
                 "content" => [
                   [
                     %{"tag" => "text", "text" => prompt <> "\n"},
                     %{"tag" => "img", "image_key" => file_key}
                   ]
                 ]
               },
               mentions: [mention],
               create_time_ms: DateTime.to_unix(create_time, :millisecond)
             )

    input = actor_event_by_source_entry_id!(agent.uid, message_id)
    assert input.type == "im.message.addressed"

    assert %Entry{text: text, attachments: [attachment]} =
             Repo.get_by!(Entry,
               signal_channel_id: "lark:#{chat_id}",
               source_entry_id: message_id
             )

    assert text =~ "attached image"
    assert text =~ "[image]"

    assert %{
             "provider_ref" => "lark:image:" <> ^file_key,
             "provider" => "lark",
             "source_message_id" => ^message_id,
             "file_key" => ^file_key,
             "download_type" => "image",
             "resource_type" => "image"
           } =
             Map.take(
               attachment,
               ~w(provider_ref provider source_message_id file_key download_type resource_type)
             )

    assert is_binary(attachment["agent_computer_path"])

    assert String.ends_with?(
             attachment["user_files_relative_path"],
             "/#{file_key}/vision-dog.jpeg"
           )

    assert get_in(input.payload, ["data", "entry", "attachments"]) == [attachment]

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, reply, message} =
             wait_for_completed_final_reply(container, input.id, deadline(180_000))

    assert_false_answer_text!(reply.text)
    assert_actor_event_completed!(input.id)

    %{input: input, reply: reply, message: message}
  end

  defp put_real_model_profile!(agent_uid, provider_id, profile, model, provider_options) do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, profile, %{
               provider_id: provider_id,
               model: model,
               provider_options: provider_options
             })
  end

  defp put_agent_inactivity_timeout!(agent_uid, timeout_ms) do
    assert {:ok, ^timeout_ms} =
             AppConfigure.put_for_agent(
               agent_uid,
               AgentConfig.inactivity_timeout_ms_definition(),
               timeout_ms
             )
  end

  defp background_agent_job_debug(actor_event_id) do
    BackgroundAgentJob
    |> where([job], job.source_actor_event_id == ^actor_event_id)
    |> Repo.all()
    |> Enum.map(fn job ->
      turns =
        BackgroundAgentJobTurn
        |> where([turn], turn.job_id == ^job.id)
        |> order_by([turn], asc: turn.started_at, asc: turn.id)
        |> limit(40)
        |> Repo.all()
        |> Enum.map(&background_agent_job_turn_debug/1)

      %{
        id: job.id,
        status: job.status,
        runtime_thread_id: job.runtime_thread_id,
        result: job.result,
        error: job.error,
        metadata: job.metadata,
        turns: turns
      }
    end)
  end

  defp background_agent_job_turn_debug(%BackgroundAgentJobTurn{} = turn) do
    %{
      attempt: turn.attempt,
      runtime_turn_id: turn.runtime_turn_id,
      kind: turn.kind,
      status: turn.status,
      revision: turn.revision,
      trajectory: background_agent_job_debug_payload(turn.trajectory),
      error: background_agent_job_debug_payload(turn.error)
    }
  end

  defp background_agent_job_debug_payload(payload) when is_map(payload) do
    payload
    |> Map.take(~w(error message codex_turn_status output_text text max_running_per_agent))
    |> truncate_debug_strings()
  end

  defp truncate_debug_strings(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, truncate_debug_strings(nested)} end)
  end

  defp truncate_debug_strings(value) when is_list(value),
    do: Enum.map(value, &truncate_debug_strings/1)

  defp truncate_debug_strings(value) when is_binary(value) do
    if String.length(value) > 1_000 do
      String.slice(value, 0, 1_000) <> "...[truncated]"
    else
      value
    end
  end

  defp truncate_debug_strings(value), do: value

  defp fallback_summary_recorded?(actor_event_id) do
    actor_event_id
    |> ai_messages_for_actor_event()
    |> Enum.any?(fn message ->
      message
      |> Map.get(:content, [])
      |> Enum.any?(
        &(request_item_text(&1) =~ "<image_summary>" and
            image_summary_text?(request_item_text(&1)))
      )
    end)
  end

  defp request_item_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.map(fn
      %{"text" => text} when is_binary(text) -> text
      %{"type" => "input_text", "text" => text} when is_binary(text) -> text
      _part -> ""
    end)
    |> Enum.join("\n")
  end

  defp request_item_text(%{"content" => text}) when is_binary(text), do: text
  defp request_item_text(_item), do: ""

  defp assert_false_answer_text!(text) do
    normalized = text |> to_string() |> String.downcase()

    assert String.contains?(normalized, @vision_expected_answer),
           "expected vision answer to say false, got: #{inspect(text)}"

    refute Regex.match?(~r/\btrue\b/, normalized),
           "expected vision answer not to say true, got: #{inspect(text)}"
  end

  defp image_summary_text?(text) when is_binary(text) do
    normalized = String.downcase(text)

    String.contains?(normalized, "dog") or String.contains?(normalized, "labrador") or
      String.contains?(normalized, "canine")
  end

  defp image_summary_text?(_text), do: false

  defp vision_image_jpeg, do: File.read!(@vision_fixture_path)

  defp pptx_slide_count!(container, path) do
    script =
      "import re,sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); print(sum(1 for n in z.namelist() if re.fullmatch(r'ppt/slides/slide[0-9]+[.]xml', n)))"

    container
    |> docker_exec!(["python3", "-c", script, path])
    |> String.trim()
    |> String.to_integer()
  end

  defp docker_exec!(container, args) do
    {output, status} =
      System.cmd(docker_path(), ["exec", container.name | args], stderr_to_stdout: true)

    assert status == 0, output
    output
  end

  defp docker_path do
    System.find_executable("docker") || flunk("docker executable was not found on PATH")
  end

  defp wait_for_completed_final_reply_with_trace(container, actor_event_id, deadline) do
    wait_for_completed_final_reply(container, actor_event_id, deadline)
  rescue
    error ->
      messages = ai_messages_for_actor_event(actor_event_id)

      raise """
      #{Exception.message(error)}

      actor_event_id=#{actor_event_id}
      ai_message_trace=#{inspect(ai_message_trace(messages), limit: :infinity, printable_limit: 4000)}
      """
  end

  defp ai_message_trace(messages) do
    Enum.map(messages, fn message ->
      %{
        id: message.id,
        status: message.status,
        type: message.type,
        tool_calls: function_call_items([message]) |> Enum.map(&function_call_trace/1),
        text: message_text_excerpt(message.content || [])
      }
    end)
  end

  defp function_call_trace(call) do
    %{
      name: call["name"],
      call_id: call["call_id"],
      arguments: call["arguments"] |> inspect(printable_limit: 1000) |> String.slice(0, 1000)
    }
  end

  defp message_text_excerpt(items) when is_list(items) do
    items
    |> Enum.flat_map(&content_texts/1)
    |> Enum.join("\n")
    |> String.slice(0, 1200)
  end

  defp message_text_excerpt(_items), do: ""

  defp content_texts(%{"text" => text}) when is_binary(text), do: [text]

  defp content_texts(%{"content" => nested}) when is_list(nested),
    do: Enum.flat_map(nested, &content_texts/1)

  defp content_texts(%{"output" => output}) when is_binary(output), do: [output]
  defp content_texts(_item), do: []

  defp assert_text_contains_with_trace!(text, needle, actor_event_id, messages) do
    assert text =~ needle,
           """
           expected reply to contain #{inspect(needle)}, got #{inspect(text)}

           actor_event_id=#{actor_event_id}
           ai_message_trace=#{inspect(ai_message_trace(messages), limit: :infinity, printable_limit: 4000)}
           """
  end

  defp replace_create_patch_calls(messages) do
    messages
    |> tool_results("patch")
    |> Enum.count(fn
      %{arguments: %{"old_string" => "", "new_string" => new_string}}
      when is_binary(new_string) ->
        true

      _other ->
        false
    end)
  end
end
