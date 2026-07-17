defmodule Ankole.E2E.Scenarios.DeepResearchRealLLM do
  @moduledoc """
  Live Deep Research scenarios through the parent `background_agent_job` tool and Docker worker path.
  """

  import Ecto.Query
  import ExUnit.Assertions

  import Ankole.E2E.Harness

  import Ankole.E2E.WaitHelpers,
    only: [
      ai_messages_for_actor_event: 1,
      deadline: 1,
      wait_for_actor_event_completed: 3,
      wait_until: 2
    ]

  alias Ankole.AIAgent.ModelProfiles
  alias Ankole.AppConfigure
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.Bindings

  @base_time ~U[2026-07-15 00:00:00.000000Z]
  @default_real_coding_model "minimax/minimax-m2.7"
  @turn_timeout_ms 1_200_000
  @completion_persistence_grace_ms 30_000
  @job_completion_timeout_ms @turn_timeout_ms + @completion_persistence_grace_ms
  @worker_recovery_timeout_ms 90_000
  @data_source_skill "e2e-research-source"

  def run_deep_research_plugin(
        %{
          agent: agent,
          provider_id: provider_id,
          container: container,
          record_binding: record_binding,
          ambient_binding: ambient_binding
        } = ctx
      ) do
    for binding <- [record_binding, ambient_binding] do
      assert {:ok, _binding} = Bindings.disable_binding(agent.uid, binding.name)
    end

    put_model_profile!(agent.uid, provider_id, "primary")
    put_model_profile!(agent.uid, provider_id, "coding")
    put_model_profile!(agent.uid, provider_id, "light")
    put_inactivity_timeout!(agent.uid)
    install_data_source_skill!(container, agent.uid)

    job = run_job!(ctx, general_task())
    report = read_report!(container, job)
    terminal_turn = job.id |> BackgroundAgentJobs.list_turns() |> List.last()

    assert report =~ "Aurora's approved budget is 10 units."
    assert report =~ "approved"
    assert job.status == "succeeded"
    assert is_binary(job.result["output_text"])
    assert terminal_turn.status == "completed"
    assert terminal_turn.trajectory["format"] == "ankole_chatml"
    assert terminal_turn.trajectory["version"] == 1
    assert terminal_turn.trajectory["messages"] != []

    %{job: job, report: report}
  end

  defp run_job!(%{fake_feishu: fake_feishu, agent: agent, container: container}, task) do
    event_id = "evt_deep_research_plugin"
    message_id = "om_deep_research_plugin"

    start_arguments =
      %{
        "action" => "start",
        "title" => "Deep Research Plugin E2E",
        "task" => task,
        "agent_plugin_ids" => ["deep-research"],
        "skill_names" => [@data_source_skill]
      }
      |> Ankole.JSON.encode!()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: event_id,
               message_id: message_id,
               chat_id: "oc_deep_research_plugin",
               chat_type: "p2p",
               text: parent_task(start_arguments),
               mentions: [lark_bot_mention()],
               create_time_ms:
                 DateTime.to_unix(
                   DateTime.add(@base_time, 1, :second),
                   :millisecond
                 )
             )

    input = actor_event_by_source_entry_id!(agent.uid, message_id)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, %ActorEvent{}} =
             wait_for_actor_event_completed(container, input.id, deadline(300_000))

    start_tool_results =
      ai_messages_for_actor_event(input.id) |> tool_results("background_agent_job")

    assert Enum.any?(start_tool_results, &(&1.arguments["action"] == "start"))
    assert Enum.all?(start_tool_results, &(not tool_result_error?(&1)))

    job =
      Repo.one!(
        from(job in Job,
          where: job.agent_uid == ^agent.uid,
          where: job.source_actor_event_id == ^input.id
        )
      )

    assert job.agent_plugin_ids == ["deep-research"]
    assert job.skill_names == [@data_source_skill]

    dispatch_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^BackgroundAgentJobs.job_session_id(job.id),
          where: event.type == "background_agent_job.dispatch"
        )
      )

    process_if_open!(dispatch_event)

    completed =
      review_until_complete!(
        agent.uid,
        input.session_id,
        job.id,
        "plugin",
        container,
        deadline(@job_completion_timeout_ms)
      )

    assert_actor_event_completed!(input.id)
    completed
  end

  defp parent_task(start_arguments) do
    """
    @_user_1 Exercise the enabled Deep Research Codex Plugin through the background_agent_job tool.

    Start one job using this JSON as the background_agent_job arguments, then tell the user it is running:
    <background_agent_job_start_arguments_json>
    #{start_arguments}
    </background_agent_job_start_arguments_json>

    Whenever this job completes or fails, call background_agent_job(status) and verify the actual
    deliverables. You may directly make and verify a small mechanical correction. If completing the
    task needs the existing research context, call background_agent_job(steer) on this same job with concise
    continuation instructions, then say that continuation is running. Otherwise, deliver the completed
    result to the user. Never create a replacement job.
    Never perform the Job's research in the caller conversation.
    """
  end

  defp review_until_complete!(
         agent_uid,
         owner_session_id,
         job_id,
         mode,
         container,
         overall_deadline,
         minimum_attempt \\ 1
       ) do
    settled = wait_for_settled_attempt!(job_id, mode, minimum_attempt, overall_deadline)

    wakeup =
      settlement_wakeup!(
        agent_uid,
        owner_session_id,
        job_id,
        settled.status,
        settled.attempts,
        overall_deadline
      )

    process_if_open!(wakeup)

    assert {:ok, %ActorEvent{}} =
             wait_for_actor_event_completed(container, wakeup.id, deadline(300_000))

    results = ai_messages_for_actor_event(wakeup.id) |> tool_results("background_agent_job")
    assert Enum.any?(results, &(&1.arguments["action"] == "status"))
    assert Enum.all?(results, &(not tool_result_error?(&1)))

    if Enum.any?(results, &(&1.arguments["action"] == "steer")) do
      process_latest_continuation_if_open!(job_id)

      review_until_complete!(
        agent_uid,
        owner_session_id,
        job_id,
        mode,
        container,
        overall_deadline,
        settled.attempts + 1
      )
    else
      Repo.get!(Job, job_id)
    end
  end

  defp wait_for_settled_attempt!(job_id, mode, minimum_attempt, overall_deadline) do
    assert {:ok, %Job{} = completed} =
             wait_until(overall_deadline, fn ->
               case Repo.get(Job, job_id) do
                 %Job{status: status, attempts: attempts} = completed
                 when status in ["succeeded", "failed"] and attempts >= minimum_attempt ->
                   completed

                 %Job{status: "stopped"} = stopped ->
                   flunk("""
                   Deep Research #{mode} job was explicitly stopped.
                   error=#{inspect(stopped.error, limit: :infinity, printable_limit: 12_000)}
                   result=#{inspect(stopped.result, limit: :infinity, printable_limit: 12_000)}
                   """)

                 _pending ->
                   nil
               end
             end)

    completed
  end

  defp settlement_wakeup!(agent_uid, session_id, job_id, status, attempt, overall_deadline) do
    event_type =
      if status == "succeeded",
        do: "background_agent_job.completed",
        else: "background_agent_job.failed"

    source_event_id = "background_agent_job:#{job_id}:#{status}:#{attempt}"

    assert {:ok, %ActorEvent{} = event} =
             wait_until(overall_deadline, fn ->
               Repo.one(
                 from(event in ActorEvent,
                   where: event.agent_uid == ^agent_uid,
                   where: event.session_id == ^session_id,
                   where: event.type == ^event_type,
                   where: event.source_event_id == ^source_event_id
                 )
               )
             end)

    event
  end

  defp process_latest_continuation_if_open!(job_id) do
    event =
      Repo.one(
        from(event in ActorEvent,
          where: event.session_id == ^BackgroundAgentJobs.job_session_id(job_id),
          where: event.type == "command.steer",
          order_by: [desc: event.queue_sequence],
          limit: 1
        )
      )

    if event, do: process_if_open!(event)
  end

  defp process_if_open!(%ActorEvent{id: id}),
    do: process_if_open!(id, deadline(@worker_recovery_timeout_ms))

  defp process_if_open!(id, worker_recovery_deadline) do
    case Repo.get!(ActorEvent, id) do
      %ActorEvent{completed_at: %DateTime{}} ->
        :ok

      %ActorEvent{} = event ->
        case process_ready_event_for_actor!(
               event,
               DateTime.add(event.available_at, 1, :second)
             ) do
          {:ok, %{send_outcome: "sent_or_queued"}} ->
            :ok

          {:ok, %{status: :idle}} ->
            assert {:ok, :claimed_or_completed} =
                     wait_until(deadline(10_000), fn ->
                       event = Repo.get!(ActorEvent, id)

                       live_delivery? =
                         Repo.exists?(
                           from(delivery in ActorEventDelivery,
                             where: delivery.actor_event_id == ^id,
                             where: delivery.state in ^ActorEventDelivery.live_states()
                           )
                         )

                       if match?(%DateTime{}, event.completed_at) or live_delivery?,
                         do: :claimed_or_completed
                     end)

            :ok

          {:ok, %{status: :waiting_for_worker}} = result ->
            if worker_recovery_deadline > System.monotonic_time(:millisecond) do
              Process.sleep(500)
              process_if_open!(id, worker_recovery_deadline)
            else
              flunk(
                "worker did not recover before Actor event retry deadline: #{inspect(result)}"
              )
            end

          other ->
            flunk("unexpected Actor event processing result: #{inspect(other)}")
        end
    end
  end

  defp put_model_profile!(agent_uid, provider_id, profile) do
    assert {:ok, _profile} =
             ModelProfiles.put_model_profile(agent_uid, profile, %{
               provider_id: provider_id,
               model: real_coding_model(),
               provider_options: %{}
             })
  end

  defp real_coding_model do
    System.get_env("ANKOLE_DEEP_RESEARCH_E2E_MODEL", @default_real_coding_model)
  end

  defp put_inactivity_timeout!(agent_uid) do
    definition = AgentConfig.inactivity_timeout_ms_definition()
    assert {:ok, 300_000} = AppConfigure.put_for_agent(agent_uid, definition, 300_000)
  end

  defp read_report!(container, %Job{id: job_id}) do
    docker_exec!(container, [
      "cat",
      "/workspace/shared/user-files/background-agent-jobs/#{job_id}/project/report/report.md"
    ])
  end

  defp install_data_source_skill!(container, agent_uid) do
    skill_dir = "/workspace/shared/skills/agents/#{agent_uid}/#{@data_source_skill}"
    docker_exec!(container, ["mkdir", "-p", "#{skill_dir}/scripts"])

    docker_write_text!(
      container,
      "#{skill_dir}/SKILL.md",
      """
      ---
      name: #{@data_source_skill}
      description: Deterministic first-party E2E research data source.
      default_enabled: true
      category: data_source
      tags: [DataSource, Research, E2E]
      ---

      # E2E research source

      Run `scripts/query.sh aurora_budget`. Use the complete JSON stdout as the source record.
      Cite its skill name and the query `{\"dataset\":\"aurora_budget\"}` in the report.
      """
    )

    docker_write_text!(
      container,
      "#{skill_dir}/scripts/query.sh",
      """
      #!/bin/sh
      set -eu
      test "${1:-}" = "aurora_budget"
      printf '%s\n' '{"project":"Aurora","decision":"approved","budget_units":10,"decided_at":"2026-07-01"}'
      """
    )

    docker_exec!(container, ["chmod", "0755", "#{skill_dir}/scripts/query.sh"])
  end

  defp general_task do
    """
    Determine Aurora's approved budget and the decision status of that budget record. Use only the
    mounted `#{@data_source_skill}` first-party data source; web research is outside this bounded
    task.

    Cite the complete source record with its skill/query provenance. Write the result to
    `report/report.md`. The report must state exactly "Aurora's approved budget is 10 units." and
    must also state that the record's decision is approved. Review the report before submitting.
    """
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
