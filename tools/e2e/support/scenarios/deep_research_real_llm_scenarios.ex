defmodule Ankole.E2E.Scenarios.DeepResearchRealLLM do
  @moduledoc """
  Live Deep Research scenarios through the parent `subagent` tool and Docker worker path.
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
  alias Ankole.E2E.FakeFeishu
  alias Ankole.Repo
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AgentConfig
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery
  alias Ankole.SignalsGateway.Bindings
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @base_time ~U[2026-07-15 00:00:00.000000Z]
  @default_real_coding_model "minimax/minimax-m2.7"
  @turn_timeout_ms 1_200_000
  @submission_grace_ms 120_000
  @completion_persistence_grace_ms 30_000
  @delegation_completion_timeout_ms @turn_timeout_ms + @submission_grace_ms +
                                      @completion_persistence_grace_ms
  @worker_recovery_timeout_ms 90_000
  @data_source_skill "e2e-research-source"

  def run_deep_research_modes(
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
    put_research_policy!(agent.uid)
    install_data_source_skill!(container, agent.uid)

    general = run_delegation!(ctx, "general", general_task())
    forecast = run_delegation!(ctx, "forecast", forecast_task())

    assert get_in(general.result, ["conclusion", "answer"]) ==
             "Aurora's approved budget is 10 units."

    assert get_in(forecast.result, ["dossier", "schema_version"]) == "forecast_dossier_v1"
    assert is_number(get_in(forecast.result, ["conclusion", "outcome_estimate", "probability"]))

    for delegation <- [general, forecast] do
      turns = SubagentDelegations.list_turns(delegation.id)
      terminal_turn = List.last(turns)
      assert delegation.status == "succeeded"
      assert delegation.runtime == "deep_research"
      assert terminal_turn.status == "completed"
      assert terminal_turn.trajectory["format"] == "ankole_chatml"
      assert terminal_turn.trajectory["version"] == 1
      assert terminal_turn.trajectory["messages"] != []
      assert get_in(delegation.result, ["verification", "status"]) == "formally_valid"
    end

    %{general: general, forecast: forecast}
  end

  defp run_delegation!(
         %{fake_feishu: fake_feishu, agent: agent, container: container},
         mode,
         task
       ) do
    event_id = "evt_deep_research_#{mode}"
    message_id = "om_deep_research_#{mode}"

    start_arguments =
      %{
        "action" => "start",
        "runtime" => "deep_research",
        "mode" => mode,
        "title" => "Deep Research E2E #{mode}",
        "task" => task
      }
      |> Ankole.JSON.encode!()

    assert :ok =
             FakeFeishu.State.user_sends_message(fake_feishu.state,
               event_id: event_id,
               message_id: message_id,
               chat_id: "oc_deep_research_#{mode}",
               chat_type: "p2p",
               text: parent_task(start_arguments),
               mentions: [lark_bot_mention()],
               create_time_ms:
                 DateTime.to_unix(
                   DateTime.add(@base_time, mode_offset(mode), :second),
                   :millisecond
                 )
             )

    input = actor_event_by_source_entry_id!(agent.uid, message_id)

    assert {:ok, %{send_outcome: "sent_or_queued"}} =
             process_ready_event_for_actor!(input, DateTime.add(input.available_at, 1, :second))

    assert {:ok, %ActorEvent{}} =
             wait_for_actor_event_completed(container, input.id, deadline(300_000))

    start_tool_results = ai_messages_for_actor_event(input.id) |> tool_results("subagent")
    assert Enum.any?(start_tool_results, &(&1.arguments["action"] == "start"))
    assert Enum.all?(start_tool_results, &(not tool_result_error?(&1)))

    delegation =
      Repo.one!(
        from(delegation in Delegation,
          where: delegation.agent_uid == ^agent.uid,
          where: delegation.actor_event_id == ^input.id
        )
      )

    assert delegation.runtime == "deep_research"
    assert delegation.mode == mode

    dispatch_event =
      Repo.one!(
        from(event in ActorEvent,
          where: event.agent_uid == ^agent.uid,
          where: event.session_id == ^"subagent:#{delegation.id}",
          where: event.type == "subagent.delegation.dispatch"
        )
      )

    process_if_open!(dispatch_event)

    completed =
      review_until_complete!(
        agent.uid,
        input.session_id,
        delegation.id,
        mode,
        container,
        deadline(@delegation_completion_timeout_ms)
      )

    assert_actor_event_completed!(input.id)
    completed
  end

  defp parent_task(start_arguments) do
    """
    @_user_1 Exercise the configured Deep Research runtime through the subagent tool.

    Start one delegation using this JSON as the subagent arguments, then tell the user it is running:
    <subagent_start_arguments_json>
    #{start_arguments}
    </subagent_start_arguments_json>

    Whenever this delegation completes or fails, call subagent(status) and verify the actual
    deliverables. You may directly make and verify a small mechanical correction. If completing the
    task needs the existing research context, call subagent(steer) on this same delegation with concise
    continuation instructions, then say that continuation is running. Otherwise, deliver the completed
    result to the user. Never create a replacement delegation.
    Never perform the delegated research in the caller conversation.
    """
  end

  defp review_until_complete!(
         agent_uid,
         parent_session_id,
         delegation_id,
         mode,
         container,
         overall_deadline,
         minimum_attempt \\ 1
       ) do
    settled = wait_for_settled_attempt!(delegation_id, mode, minimum_attempt, overall_deadline)

    wakeup =
      settlement_wakeup!(
        agent_uid,
        parent_session_id,
        delegation_id,
        settled.status,
        settled.attempts,
        overall_deadline
      )

    process_if_open!(wakeup)

    assert {:ok, %ActorEvent{}} =
             wait_for_actor_event_completed(container, wakeup.id, deadline(300_000))

    results = ai_messages_for_actor_event(wakeup.id) |> tool_results("subagent")
    assert Enum.any?(results, &(&1.arguments["action"] == "status"))
    assert Enum.all?(results, &(not tool_result_error?(&1)))

    if Enum.any?(results, &(&1.arguments["action"] == "steer")) do
      process_latest_continuation_if_open!(delegation_id)

      review_until_complete!(
        agent_uid,
        parent_session_id,
        delegation_id,
        mode,
        container,
        overall_deadline,
        settled.attempts + 1
      )
    else
      Repo.get!(Delegation, delegation_id)
    end
  end

  defp wait_for_settled_attempt!(delegation_id, mode, minimum_attempt, overall_deadline) do
    assert {:ok, %Delegation{} = completed} =
             wait_until(overall_deadline, fn ->
               case Repo.get(Delegation, delegation_id) do
                 %Delegation{status: status, attempts: attempts} = completed
                 when status in ["succeeded", "failed"] and attempts >= minimum_attempt ->
                   completed

                 %Delegation{status: "stopped"} = stopped ->
                   flunk("""
                   Deep Research #{mode} delegation was explicitly stopped.
                   error=#{inspect(stopped.error, limit: :infinity, printable_limit: 12_000)}
                   result=#{inspect(stopped.result, limit: :infinity, printable_limit: 12_000)}
                   """)

                 _pending ->
                   nil
               end
             end)

    completed
  end

  defp settlement_wakeup!(agent_uid, session_id, delegation_id, status, attempt, overall_deadline) do
    event_type =
      if status == "succeeded",
        do: "subagent.delegation.completed",
        else: "subagent.delegation.failed"

    source_event_id = "subagent_delegation:#{delegation_id}:#{status}:#{attempt}"

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

  defp process_latest_continuation_if_open!(delegation_id) do
    event =
      Repo.one(
        from(event in ActorEvent,
          where: event.session_id == ^"subagent:#{delegation_id}",
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

  defp put_research_policy!(agent_uid) do
    definition = Ankole.SubagentDelegations.Config.definition()
    assert :ok = Ankole.SubagentDelegations.Config.ensure_registered()

    assert {:ok, _policy} =
             AppConfigure.put_for_agent(agent_uid, definition, %{
               "wallclock_budget" => @turn_timeout_ms,
               "submission_grace" => @submission_grace_ms,
               "retention_days" => 30
             })
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

      Run `scripts/query.sh aurora_budget`. Archive the complete JSON stdout before using it.
      Record provenance with skill `#{@data_source_skill}` and query `{\"dataset\":\"aurora_budget\"}`.
      This fixture has no public URL: set `source` and omit `url` from its evidence index entry.
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

    Preserve and cite the complete source record with its skill/query provenance. One independent
    normal-risk primary record is sufficient for this question. The report and
    general_conclusion_v1.answer must state exactly "Aurora's approved budget is 10 units.", and
    the report must also state that the record's decision is approved. Complete the Deep Research
    evidence and conclusion contracts, use native subagents for a fresh challenge if useful, and
    run the final delivery preflight before submitting.
    """
  end

  defp forecast_task do
    """
    Produce a domain-neutral ACH forecast for this resolution rule: "True iff the current launch is
    publicly reported complete by 2026-12-31." The horizon is `2026-12-31`. Use only the following
    three authoritative task fixtures and archive them separately; do not browse the web:

    E01 base rate: "Six of ten comparable resolved launches completed by their deadline."
    E02 leading signal: "The current launch passed its final readiness review."
    E03 counter-signal: "One non-critical supplier item remains open."

    Treat the event as predictable and the fixture as the complete bounded evidence set. Use the
    required naive, historical-conditioned, and current-consensus priors and preserve all plausible
    mechanism classes, including base-rate and residual alternatives. An unresolved discriminator
    for which this bounded fixture supplies no differentiating observation should have equal
    possible-outcome grades, so it does not create imaginary information value. Report the fresh
    deterministic estimate at scale 0.01 with evidence-backed triggers and limitations. Before
    finalizing, use one native Codex subagent to challenge the evidence grades independently; treat
    its findings as advice, then run the final delivery preflight.
    """
  end

  defp mode_offset("general"), do: 1
  defp mode_offset("forecast"), do: 2

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
