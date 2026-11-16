defmodule Ankole.Pod.JobsBoard.Queries do
  @moduledoc """
  Projects the Pod `/jobs` board, lightweight sidebar counts, routine run
  histories, and direct execution details for one Pod member.
  """

  require Ash.Query

  alias Ankole.AIGateway.ModelProfiles
  alias Ankole.AuthZ.Actor
  alias Ankole.AutomationJobs.Applet
  alias Ankole.AutomationJobs.Schemas.Job, as: AutomationJob
  alias Ankole.AutomationJobs.Schemas.Run, as: AutomationRun
  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Queries, as: AgentJobQueries
  alias Ankole.BackgroundAgentJobs.Schemas.Job, as: AgentJob
  alias Ankole.Conversations
  alias Ankole.Conversations.{Executions, Native, NativeRoom, Participant}
  alias Ankole.Pod.Chat.Presentation
  alias Ankole.Principals
  alias Ankole.Schedule
  alias Ankole.Schedule.Schemas.{AgentRoutine, ScheduledEvent}
  alias Ankole.Sessions
  alias Ankole.Sessions.Key
  alias Ankole.Signals
  alias Ankole.Signals.Webhooks
  alias Ankole.Workflow
  alias Ankole.Workflow.Queries, as: WorkflowQueries
  alias Ankole.Workflow.Schemas.Run, as: WorkflowRun

  @terminal_limit 120
  @routine_history_limit 30
  @fresh_failure_seconds 48 * 3_600

  @doc "Returns lightweight counts for the Pod sidebar badge."
  def summary(%Actor{} = actor) do
    if Native.active_human?(actor) do
      cards = project_member_cards(actor, DateTime.utc_now(:microsecond), :summary)

      {:ok,
       %{
         scheduledCount: Enum.count(cards, &(&1.column == :scheduled)),
         runningCount: Enum.count(cards, &(&1.column == :running)),
         attentionCount: Enum.count(cards, & &1.attention)
       }}
    else
      {:ok, %{scheduledCount: 0, runningCount: 0, attentionCount: 0}}
    end
  end

  @doc "Lists projected cards on `/jobs` together with candidate Agents for `+ New Job`."
  def list(%Actor{} = actor) do
    if Native.active_human?(actor) do
      {:ok,
       %{
         items: project_member_cards(actor, DateTime.utc_now(:microsecond), :board),
         agents: candidate_agents(actor)
       }}
    else
      {:ok, %{items: [], agents: []}}
    end
  end

  @doc "Reads one projected card on `/jobs` by its board ID (`job:`, `cron:`, `checkback:`, or `automation:`)."
  def get_card(%Actor{} = actor, card_id) when is_binary(card_id) do
    case load_card_with_source(actor, card_id) do
      {:ok, card, _source} -> {:ok, card}
      {:error, _} = error -> error
    end
  end

  def get_card(_actor, _card_id), do: {:error, :job_not_found}

  @doc "Reads one routine card (`cron`, `automation_job`, or `checkback`) and its run history."
  def routine_detail(%Actor{} = actor, kind, raw_id)
      when kind in [:cron, :automation_job, :checkback, "cron", "automation_job", "checkback"] do
    kind = normalize_routine_kind(kind)

    with {:ok, item, source} <- load_card_with_source(actor, routine_card_id(kind, raw_id)) do
      build_routine_detail(kind, source, item)
    else
      _ -> {:error, :job_not_found}
    end
  end

  def routine_detail(_actor, _kind, _raw_id), do: {:error, :job_not_found}

  @doc "Reads a BackgroundAgentJob or Workflow execution page directly from `/jobs`."
  def execution_detail(actor, kind, run_id, cursor \\ nil)

  def execution_detail(%Actor{} = actor, kind, run_id, cursor)
      when kind in [:background_agent_job, :workflow, "background_agent_job", "workflow"] do
    kind = normalize_exec_kind(kind)

    Ankole.Repo.transact_repeatable_read_only(fn ->
      with {:ok, run, can_act?} <- authorize_execution_read(actor, kind, run_id) do
        Presentation.execution_page(run, kind, cursor, can_act?)
      end
    end)
  end

  def execution_detail(_actor, _kind, _run_id, _cursor), do: {:error, :execution_not_found}

  @doc false
  def authorize_execution_read(%Actor{} = actor, kind, run_id) do
    with true <- Native.active_human?(actor),
         {:ok, parsed_id} <- Ankole.ModelIntegerID.parse(run_id),
         run when not is_nil(run) <- fetch_execution_run(kind, parsed_id),
         :ok <- reject_foreign_pa(Actor.uid(actor), run.agent_uid),
         {:ok, can_act?} <- check_run_visibility(actor, run) do
      {:ok, run, can_act?}
    else
      _ -> {:error, :execution_not_found}
    end
  end

  defp fetch_execution_run(:background_agent_job, id) do
    case BackgroundAgentJobs.get_job(id) do
      %AgentJob{} = job ->
        if get_in(job.metadata || %{}, ["skill_lesson_reflection"]) == true, do: nil, else: job

      nil ->
        nil
    end
  end

  defp fetch_execution_run(:workflow, id), do: Workflow.get_run!(id)

  defp check_run_visibility(actor, run) do
    uid = Actor.uid(actor)

    case Key.parse(run.owner_session_id) do
      {:conversation, conv_id} ->
        with {:ok, _room} <- Conversations.visible_native_conversation(actor, conv_id) do
          can_act? =
            match?(
              %Participant{role: :agent},
              NativeRoom.participant(conv_id, run.agent_uid)
            ) and Native.authorize_agent(actor, run.agent_uid) == :ok

          {:ok, can_act?}
        else
          _ -> {:error, :execution_not_found}
        end

      {:pod_job, _} ->
        if run.human_uid == uid do
          {:ok, Native.authorize_agent(actor, run.agent_uid) == :ok}
        else
          {:error, :execution_not_found}
        end

      {:routine, routine_id} ->
        case Schedule.get_routine(routine_id) do
          {:ok, %AgentRoutine{} = routine} ->
            if routine_visible_to?(actor, routine) do
              can_act? =
                routine_manageable?(actor, routine) and
                  Native.authorize_agent(actor, run.agent_uid) == :ok

              {:ok, can_act?}
            else
              {:error, :execution_not_found}
            end

          _ ->
            if run.human_uid == uid do
              {:ok, Native.authorize_agent(actor, run.agent_uid) == :ok}
            else
              {:error, :execution_not_found}
            end
        end

      _ ->
        {:error, :execution_not_found}
    end
  end

  @doc false
  def routine_visible_to?(%Actor{} = actor, %AgentRoutine{} = routine) do
    uid = Actor.uid(actor)

    with :ok <- reject_foreign_pa(uid, routine.agent_uid) do
      if routine.human_uid == uid do
        true
      else
        candidate_ids = Schedule.routine_room_ids(routine)
        visible_rooms = visible_room_titles(actor, uid, nil, candidate_ids)
        Enum.any?(candidate_ids, &Map.has_key?(visible_rooms, &1))
      end
    else
      _ -> false
    end
  end

  @doc false
  def routine_manageable?(%Actor{} = actor, %AgentRoutine{} = routine) do
    uid = Actor.uid(actor)

    case reject_foreign_pa(uid, routine.agent_uid) do
      :ok ->
        routine.human_uid == uid or
          (Ankole.AuthZ.pod_admin?(uid) and routine_visible_to?(actor, routine))

      _ ->
        false
    end
  end

  defp load_card_with_source(%Actor{} = actor, card_id) do
    if Native.active_human?(actor) do
      now = DateTime.utc_now(:microsecond)
      cutoff = DateTime.add(now, -@fresh_failure_seconds, :second)
      load_single_card(actor, card_id, now, cutoff)
    else
      {:error, :job_not_found}
    end
  end

  defp load_single_card(actor, "job:" <> raw_id, now, _cutoff) do
    uid = Actor.uid(actor)

    with {:ok, %AgentJob{} = job, _can_act?} <-
           authorize_execution_read(actor, :background_agent_job, raw_id) do
      candidate_rooms =
        [
          session_room_id(job.owner_session_id),
          get_in(job.reply_route || %{}, ["conversation_id"])
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()

      room_titles = visible_room_titles(actor, uid, nil, candidate_rooms)
      agent_uids = if is_binary(job.agent_uid), do: [job.agent_uid], else: []
      agent_names = principal_names(agent_uids)
      callable_agents = callable_agent_set(actor, agent_uids)
      metrics = Executions.room_metrics([job], [])
      chain_lengths = job_chain_lengths([job])

      card =
        project_job_card(
          job,
          uid,
          agent_names,
          room_titles,
          callable_agents,
          Map.get(metrics.jobs, job.id, %{}),
          Map.get(chain_lengths, job.workspace_owner_job_id, 1),
          now
        )

      {:ok, card, job}
    else
      _ -> {:error, :job_not_found}
    end
  end

  defp load_single_card(actor, "cron:" <> raw_id, _now, cutoff) do
    uid = Actor.uid(actor)
    pod_admin? = Ankole.AuthZ.pod_admin?(uid)

    with {:ok, %AgentRoutine{status: status} = routine} when status in [:active, :paused] <-
           Schedule.get_routine(raw_id),
         :ok <- reject_foreign_pa(uid, routine.agent_uid),
         candidate_ids = Schedule.routine_room_ids(routine),
         room_titles = visible_room_titles(actor, uid, nil, candidate_ids),
         true <-
           routine.human_uid == uid or
             Enum.any?(candidate_ids, &Map.has_key?(room_titles, &1)) do
      session_id = Schedule.routine_execution_session_id(routine.id)
      cron_jobs = AgentJobQueries.cron_board_jobs([session_id], cutoff)
      cron_wfs = WorkflowQueries.cron_board_runs([session_id])
      agent_names = principal_names([routine.agent_uid])

      [card] =
        project_cron_cards(
          [routine],
          uid,
          pod_admin?,
          agent_names,
          room_titles,
          %{routine.id => cron_jobs},
          %{routine.id => cron_wfs}
        )

      {:ok, card, routine}
    else
      _ -> {:error, :job_not_found}
    end
  end

  defp load_single_card(actor, "checkback:" <> raw_id, _now, cutoff) do
    uid = Actor.uid(actor)

    with {:ok, parsed_id} <- Ankole.ModelIntegerID.parse(raw_id),
         %ScheduledEvent{kind: "check_back_later"} = event <-
           Schedule.Store.get_scheduled_event(parsed_id),
         true <-
           event.status == :scheduled or
             (event.status == :failed and DateTime.compare(event.updated_at, cutoff) in [:gt, :eq]),
         :ok <- reject_foreign_pa(uid, event.agent_uid) do
      room_id = event.conversation_id || session_room_id(event.session_id)
      room_titles = visible_room_titles(actor, uid, nil, if(room_id, do: [room_id], else: []))

      if event.human_uid == uid or (room_id != nil and Map.has_key?(room_titles, room_id)) do
        agent_names = principal_names(if(event.agent_uid, do: [event.agent_uid], else: []))
        {:ok, project_checkback_card(event, uid, agent_names, room_titles), event}
      else
        {:error, :job_not_found}
      end
    else
      _ -> {:error, :job_not_found}
    end
  end

  defp load_single_card(actor, "automation:" <> raw_id, _now, _cutoff) do
    uid = Actor.uid(actor)
    authority_uid = Principals.authority_uid(uid)

    with {:ok, parsed_id} <- Ankole.ModelIntegerID.parse(raw_id) do
      visible_page_ids =
        case Ankole.Pod.Access.reachable_anchors(actor) do
          {:ok, reachable} -> Ankole.Pod.visible_node_ids(reachable)
          _ -> []
        end

      case Enum.find(
             Applet.list_visible_active_jobs(authority_uid, visible_page_ids),
             &(&1.id == parsed_id)
           ) do
        %AutomationJob{} = job ->
          titles = page_titles([job.page_id])
          [card] = project_automation_cards({[job], titles}, authority_uid)
          {:ok, card, job}

        nil ->
          {:error, :job_not_found}
      end
    else
      _ -> {:error, :job_not_found}
    end
  end

  defp load_single_card(_actor, _card_id, _now, _cutoff), do: {:error, :job_not_found}

  # Shared projection pipeline for both `summary/1` (`:summary`) and `list/1` (`:board`).
  # Visibility, continuation-chain head selection, and Cron child grouping run
  # before `@terminal_limit` caps `Completed`. `:summary` skips completed runs
  # and skips name/metric hydration while classifying the exact same active set.
  defp project_member_cards(actor, now, mode) when mode in [:summary, :board] do
    uid = Actor.uid(actor)
    authority_uid = Principals.authority_uid(uid)
    cutoff = DateTime.add(now, -@fresh_failure_seconds, :second)
    scope = build_visibility_scope(actor, uid, authority_uid, cutoff)

    standalone_live_jobs = AgentJobQueries.standalone_active_jobs(scope, cutoff)
    standalone_live_wfs = WorkflowQueries.standalone_active_runs(scope, cutoff)

    {standalone_jobs, standalone_wfs, cron_jobs_by_id, cron_wfs_by_id} =
      case mode do
        :summary ->
          {
            standalone_live_jobs,
            standalone_live_wfs,
            scope.live_cron_sessions
            |> AgentJobQueries.cron_active_jobs(cutoff)
            |> group_runs_by_cron(scope.cron_by_session),
            scope.live_cron_sessions
            |> WorkflowQueries.cron_active_runs()
            |> group_runs_by_cron(scope.cron_by_session)
          }

        :board ->
          completed_jobs =
            AgentJobQueries.standalone_completed_jobs(scope, cutoff, @terminal_limit)

          completed_wfs =
            WorkflowQueries.standalone_completed_runs(scope, cutoff, @terminal_limit)

          {
            Enum.uniq_by(standalone_live_jobs ++ completed_jobs, & &1.id),
            Enum.uniq_by(standalone_live_wfs ++ completed_wfs, & &1.id),
            scope.live_cron_sessions
            |> AgentJobQueries.cron_board_jobs(cutoff)
            |> group_runs_by_cron(scope.cron_by_session),
            scope.live_cron_sessions
            |> WorkflowQueries.cron_board_runs()
            |> group_runs_by_cron(scope.cron_by_session)
          }
      end

    {agent_names, callable_agents, metrics, chain_lengths, auto_page_titles} =
      case mode do
        :summary ->
          {%{}, MapSet.new(), %{jobs: %{}, workflows: %{}}, %{}, %{}}

        :board ->
          agent_uids =
            (Enum.map(standalone_jobs, & &1.agent_uid) ++
               Enum.map(standalone_wfs, & &1.agent_uid) ++
               Enum.map(scope.visible_crons, & &1.agent_uid) ++
               Enum.map(scope.visible_checkbacks, & &1.agent_uid))
            |> Enum.reject(&is_nil/1)
            |> Enum.uniq()

          {
            principal_names(agent_uids),
            callable_agent_set(actor, agent_uids),
            Executions.room_metrics(standalone_jobs, standalone_wfs),
            job_chain_lengths(standalone_jobs),
            page_titles(Enum.map(scope.auto_jobs, & &1.page_id))
          }
      end

    one_off_cards =
      Enum.map(standalone_jobs, fn job ->
        project_job_card(
          job,
          uid,
          agent_names,
          scope.room_titles,
          callable_agents,
          Map.get(metrics.jobs, job.id, %{}),
          Map.get(chain_lengths, job.workspace_owner_job_id, 1),
          now
        )
      end) ++
        Enum.map(standalone_wfs, fn wf ->
          project_workflow_card(
            wf,
            agent_names,
            scope.room_titles,
            Map.get(metrics.workflows, wf.id),
            now
          )
        end)

    pod_admin? = Ankole.AuthZ.pod_admin?(uid)

    cron_cards =
      project_cron_cards(
        scope.visible_crons,
        uid,
        pod_admin?,
        agent_names,
        scope.room_titles,
        cron_jobs_by_id,
        cron_wfs_by_id
      )

    checkback_cards =
      Enum.map(
        scope.visible_checkbacks,
        &project_checkback_card(&1, uid, agent_names, scope.room_titles)
      )

    automation_cards =
      project_automation_cards({scope.auto_jobs, auto_page_titles}, authority_uid)

    cards = one_off_cards ++ cron_cards ++ checkback_cards ++ automation_cards

    case mode do
      :summary -> cards
      :board -> cards |> bound_completed_cards() |> sort_board_cards()
    end
  end

  defp build_visibility_scope(actor, uid, authority_uid, cutoff) do
    visible_page_ids =
      case Ankole.Pod.Access.reachable_anchors(actor) do
        {:ok, reachable} -> Ankole.Pod.visible_node_ids(reachable)
        _ -> []
      end

    room_titles = visible_room_titles(actor, uid, visible_page_ids, nil)
    visible_room_ids = Enum.map(Map.keys(room_titles), &to_string/1)
    visible_conv_sessions = Enum.map(visible_room_ids, &Key.conversation/1)

    foreign_pa_uids = Principals.foreign_personal_assistant_uids(uid)
    foreign_pa_set = MapSet.new(foreign_pa_uids)

    visible_crons =
      Schedule.list_board_routines()
      |> Enum.filter(fn routine ->
        not MapSet.member?(foreign_pa_set, routine.agent_uid) and
          (routine.human_uid == uid or
             Enum.any?(Schedule.routine_room_ids(routine), &Map.has_key?(room_titles, &1)))
      end)

    visible_checkbacks =
      Schedule.list_board_checkbacks(cutoff)
      |> Enum.filter(fn event ->
        not MapSet.member?(foreign_pa_set, event.agent_uid) and
          (event.human_uid == uid or
             Map.has_key?(room_titles, event.conversation_id || session_room_id(event.session_id)))
      end)

    auto_jobs = Applet.list_visible_active_jobs(authority_uid, visible_page_ids)

    %{
      uid: uid,
      room_titles: room_titles,
      visible_room_ids: visible_room_ids,
      visible_conv_sessions: visible_conv_sessions,
      foreign_pa_uids: foreign_pa_uids,
      visible_crons: visible_crons,
      cron_by_session:
        Map.new(visible_crons, &{Schedule.routine_execution_session_id(&1.id), &1.id}),
      live_cron_sessions: Enum.map(visible_crons, &Schedule.routine_execution_session_id(&1.id)),
      visible_checkbacks: visible_checkbacks,
      auto_jobs: auto_jobs
    }
  end

  defp visible_room_titles(_actor, _uid, _visible_page_ids, []), do: %{}

  defp visible_room_titles(actor, uid, visible_page_ids, only_ids) do
    page_ids =
      case visible_page_ids do
        ids when is_list(ids) ->
          ids

        nil ->
          case Ankole.Pod.Access.reachable_anchors(actor) do
            {:ok, reachable} -> Ankole.Pod.visible_node_ids(reachable)
            _ -> []
          end
      end

    NativeRoom.visible_room_titles(uid, page_ids, only_ids)
  end

  defp group_runs_by_cron(runs, cron_by_session) do
    Enum.group_by(runs, &Map.get(cron_by_session, &1.owner_session_id))
    |> Map.delete(nil)
  end

  defp job_chain_lengths([]), do: %{}

  defp job_chain_lengths(jobs) do
    jobs
    |> Enum.map(& &1.workspace_owner_job_id)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> AgentJobQueries.chain_lengths()
  end

  defp page_titles([]), do: %{}

  defp page_titles(ids) do
    ids = Enum.uniq(ids)

    Ankole.Pod.Page
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.select([:id, :title])
    |> Ankole.Ash.read!()
    |> Map.new(&{&1.id, &1.title || ""})
  end

  defp project_job_card(
         %AgentJob{} = job,
         uid,
         agent_names,
         room_titles,
         callable_agents,
         metric,
         chain_length,
         now
       ) do
    room_id = run_room_id(job, room_titles)
    {column, attention?, attention_reason} = job_card_placement(job, now)
    can_act? = job_card_manageable?(job, uid, room_id, callable_agents)

    %{
      id: "job:#{job.id}",
      rawID: to_string(job.id),
      kind: :background_agent_job,
      cardType: :one_off,
      column: column,
      status: to_string(job.status),
      attention: attention?,
      attentionReason: attention_reason,
      title: non_empty(job.title) || excerpt(job.task, 80) || "Job ##{job.id}",
      summary: job_card_summary(job, metric),
      agentUID: job.agent_uid,
      agentName: agent_names[job.agent_uid] || job.agent_uid,
      conversationID: room_id,
      conversationTitle: room_id && room_titles[room_id],
      pageID: nil,
      pageTitle: nil,
      manageable: can_act?,
      stoppable: can_act? and job.status in [:queued, :running, :waiting_on_user],
      canMessage: job_card_messageable?(job, can_act?),
      stepCount: metric[:step_count] || 0,
      planCompleted: metric[:plan_completed],
      planTotal: metric[:plan_total],
      chainLength: max(chain_length, 1),
      activeExecutionKind: :background_agent_job,
      activeExecutionID: to_string(job.id),
      schedule: nil,
      timezone: nil,
      nextRunAt: nil,
      lastRunAt: job.completed_at || job.started_at,
      lastRunStatus: to_string(job.status),
      triggerSummary: nil,
      createdAt: job.inserted_at,
      updatedAt: job.updated_at
    }
  end

  defp job_card_placement(%AgentJob{} = job, now) do
    fresh_failed? =
      job.status == :failed and fresh_terminal?(job.completed_at || job.updated_at, now)

    column =
      cond do
        job.status == :queued -> :scheduled
        job.status in [:running, :waiting_on_user] or fresh_failed? -> :running
        true -> :completed
      end

    cond do
      job.status == :waiting_on_user -> {column, true, "waiting_on_user"}
      fresh_failed? -> {column, true, "failed"}
      true -> {column, false, nil}
    end
  end

  defp job_card_manageable?(%AgentJob{} = job, uid, room_id, callable_agents) do
    MapSet.member?(callable_agents, job.agent_uid) and
      (not is_nil(room_id) or job.human_uid == uid)
  end

  defp job_card_messageable?(_job, false), do: false

  defp job_card_messageable?(%AgentJob{} = job, true) do
    job.status in [:queued, :running, :waiting_on_user] or
      (job.status in [:succeeded, :failed, :stopped] and is_binary(job.runtime_thread_id) and
         is_integer(job.workspace_owner_job_id))
  end

  defp project_workflow_card(%WorkflowRun{} = wf, agent_names, room_titles, counts, now) do
    room_id = run_room_id(wf, room_titles)

    fresh_failed? =
      wf.status == :failed and fresh_terminal?(wf.completed_at || wf.updated_at, now)

    column =
      cond do
        wf.status == :running or fresh_failed? -> :running
        true -> :completed
      end

    summary =
      cond do
        wf.status == :completed -> excerpt(wf.result_text, 200)
        wf.status == :failed -> workflow_error_excerpt(wf.error)
        counts && counts.running > 0 -> "#{counts.completed}/#{counts.total}"
        true -> nil
      end

    %{
      id: "workflow:#{wf.id}",
      rawID: to_string(wf.id),
      kind: :workflow,
      cardType: :one_off,
      column: column,
      status: to_string(wf.status),
      attention: fresh_failed?,
      attentionReason: if(fresh_failed?, do: "failed"),
      title: non_empty(wf.title) || "Workflow ##{wf.id}",
      summary: summary,
      agentUID: wf.agent_uid,
      agentName: agent_names[wf.agent_uid] || wf.agent_uid,
      conversationID: room_id,
      conversationTitle: room_id && room_titles[room_id],
      pageID: nil,
      pageTitle: nil,
      manageable: wf.status == :running,
      stoppable: wf.status == :running,
      canMessage: false,
      stepCount: if(counts, do: counts.total, else: 0),
      planCompleted: counts && counts.completed,
      planTotal: counts && counts.total,
      chainLength: 1,
      activeExecutionKind: :workflow,
      activeExecutionID: to_string(wf.id),
      schedule: nil,
      timezone: nil,
      nextRunAt: nil,
      lastRunAt: wf.completed_at || wf.inserted_at,
      lastRunStatus: to_string(wf.status),
      triggerSummary: nil,
      createdAt: wf.inserted_at,
      updatedAt: wf.updated_at
    }
  end

  defp project_cron_cards(
         [],
         _uid,
         _pod_admin?,
         _agent_names,
         _room_titles,
         _cron_jobs,
         _cron_wfs
       ),
       do: []

  defp project_cron_cards(
         routines,
         uid,
         pod_admin?,
         agent_names,
         room_titles,
         cron_jobs,
         cron_wfs
       ) do
    routine_ids = Enum.map(routines, & &1.id)
    schedules_by_routine = Schedule.schedules_by_owner_routines(routine_ids)
    bindings_by_routine = Schedule.bindings_by_owner_routines(routine_ids)

    session_keys =
      Enum.map(routines, &{&1.agent_uid, Schedule.routine_execution_session_id(&1.id)})

    session_statuses = Sessions.statuses(session_keys)
    signal_rollups = Signals.routine_session_rollups(session_keys)

    {latest_unlinked_events, pending_manual_ids} =
      Schedule.routine_cron_fire_rollups(schedules_by_routine)

    Enum.map(routines, fn routine ->
      session_key = {routine.agent_uid, Schedule.routine_execution_session_id(routine.id)}

      project_single_cron_card(
        routine,
        uid,
        pod_admin?,
        agent_names,
        room_titles,
        Map.get(schedules_by_routine, routine.id, []),
        Map.get(bindings_by_routine, routine.id, []),
        session_statuses[session_key],
        Map.get(signal_rollups, session_key, %{latest_signal: nil, latest_summary: nil}),
        Map.get(latest_unlinked_events, routine.id),
        MapSet.member?(pending_manual_ids, routine.id),
        Map.get(cron_jobs, routine.id, []),
        Map.get(cron_wfs, routine.id, [])
      )
    end)
  end

  defp project_single_cron_card(
         %AgentRoutine{} = routine,
         uid,
         pod_admin?,
         agent_names,
         room_titles,
         crons,
         bindings,
         session_status,
         signal_rollup,
         latest_unlinked_event,
         pending_fire?,
         child_jobs,
         child_wfs
       ) do
    room_id = Enum.find(Schedule.routine_room_ids(routine), &Map.has_key?(room_titles, &1))
    waiting_job = Enum.find(child_jobs, &(&1.status == :waiting_on_user))
    live_job = Enum.find(child_jobs, &(&1.status in [:queued, :running]))
    live_wf = Enum.find(child_wfs, &(&1.status == :running))

    primary_cron =
      Enum.find(crons, &(&1.status == :active)) || Enum.find(crons, &(&1.status == :paused))

    enabled_bindings = Enum.filter(bindings, & &1.enabled)
    latest_outcome = latest_routine_outcome(signal_rollup[:latest_signal], latest_unlinked_event)

    {column, status, attention?, attention_reason} =
      cron_card_placement(
        routine,
        session_status,
        latest_outcome,
        pending_fire?,
        waiting_job,
        live_job,
        live_wf
      )

    {exec_kind, exec_id} =
      cron_active_execution(waiting_job, live_job, live_wf, child_jobs, child_wfs)

    %{
      id: "cron:#{routine.id}",
      rawID: routine.id,
      kind: :cron,
      cardType: :routine,
      column: column,
      status: status,
      attention: attention?,
      attentionReason: attention_reason,
      title: routine.name,
      summary:
        cron_card_summary(routine, waiting_job, latest_outcome, signal_rollup[:latest_summary]),
      agentUID: routine.agent_uid,
      agentName: agent_names[routine.agent_uid] || routine.agent_uid,
      conversationID: room_id,
      conversationTitle: room_id && room_titles[room_id],
      pageID: nil,
      pageTitle: nil,
      manageable: routine.human_uid == uid or pod_admin?,
      stoppable: false,
      canMessage: false,
      stepCount: 0,
      planCompleted: nil,
      planTotal: nil,
      chainLength: 1,
      activeExecutionKind: exec_kind,
      activeExecutionID: exec_id,
      schedule: primary_cron && primary_cron.schedule,
      timezone: primary_cron && primary_cron.timezone,
      nextRunAt: primary_cron && primary_cron.next_fire_at,
      lastRunAt: latest_outcome.at || (primary_cron && primary_cron.last_fire_at),
      lastRunStatus: latest_outcome.status,
      triggerSummary: routine_trigger_summary(primary_cron, length(enabled_bindings)),
      createdAt: routine.inserted_at,
      updatedAt: routine.updated_at
    }
  end

  defp cron_card_placement(
         routine,
         session_status,
         latest_outcome,
         pending_fire?,
         waiting_job,
         live_job,
         live_wf
       ) do
    session_live? = session_status != nil and session_status.state != :idle

    cond do
      not is_nil(waiting_job) ->
        {:running, "waiting_on_user", true, "waiting_on_user"}

      session_live? or pending_fire? or not is_nil(live_job) or not is_nil(live_wf) ->
        {:running, "running", false, nil}

      latest_outcome.failed? ->
        {:running, "failed", true, "failed"}

      true ->
        {:scheduled, to_string(routine.status), false, nil}
    end
  end

  defp cron_active_execution(waiting_job, live_job, live_wf, child_jobs, child_wfs) do
    cond do
      waiting_job -> {:background_agent_job, to_string(waiting_job.id)}
      live_job -> {:background_agent_job, to_string(live_job.id)}
      live_wf -> {:workflow, to_string(live_wf.id)}
      child_jobs != [] -> {:background_agent_job, to_string(hd(child_jobs).id)}
      child_wfs != [] -> {:workflow, to_string(hd(child_wfs).id)}
      true -> {nil, nil}
    end
  end

  defp project_checkback_card(%ScheduledEvent{} = event, uid, agent_names, room_titles) do
    room_id = event.conversation_id || session_room_id(event.session_id)
    room_id = if room_id && Map.has_key?(room_titles, room_id), do: room_id
    payload = event.wake_payload || %{}
    failed? = event.status == :failed

    column = if failed?, do: :running, else: :scheduled

    %{
      id: "checkback:#{event.id}",
      rawID: to_string(event.id),
      kind: :checkback,
      cardType: :routine,
      column: column,
      status: to_string(event.status),
      attention: failed?,
      attentionReason: if(failed?, do: "failed"),
      title: non_empty(payload["reason"]) || excerpt(payload["check"], 80) || "Check back later",
      summary:
        if(failed?,
          do: map_error_reason(event.last_fire_error),
          else: excerpt(payload["check"], 180)
        ),
      agentUID: event.agent_uid,
      agentName: agent_names[event.agent_uid] || event.agent_uid,
      conversationID: room_id,
      conversationTitle: room_id && room_titles[room_id],
      pageID: nil,
      pageTitle: nil,
      manageable: event.status == :scheduled and event.human_uid == uid,
      stoppable: false,
      canMessage: false,
      stepCount: 0,
      planCompleted: nil,
      planTotal: nil,
      chainLength: 1,
      activeExecutionKind: nil,
      activeExecutionID: nil,
      schedule: payload["schedule"],
      timezone: event.timezone,
      nextRunAt: event.due_at,
      lastRunAt: event.fired_at,
      lastRunStatus: if(failed?, do: "failed"),
      triggerSummary: nil,
      createdAt: event.inserted_at,
      updatedAt: event.updated_at
    }
  end

  defp project_automation_cards({[], _page_titles}, _authority_uid), do: []

  defp project_automation_cards({jobs, page_titles}, authority_uid) do
    job_ids = Enum.map(jobs, & &1.id)
    schedules_by_job = Schedule.schedules_by_owner_jobs(job_ids)
    webhook_counts = Webhooks.counts_by_owner_jobs(job_ids)
    {live_runs, latest_runs} = Applet.run_rollups_by_jobs(job_ids)

    Enum.map(jobs, fn job ->
      project_single_automation_card(
        job,
        authority_uid,
        page_titles,
        Map.get(schedules_by_job, job.id, []),
        Map.get(webhook_counts, job.id, 0),
        Map.get(live_runs, job.id, []),
        Map.get(latest_runs, job.id)
      )
    end)
  end

  defp project_single_automation_card(
         job,
         authority_uid,
         page_titles,
         job_schedules,
         webhooks,
         live,
         latest
       ) do
    primary_schedule =
      Enum.find(job_schedules, &(&1.status == :active)) || List.first(job_schedules)

    {column, status, attention?, attention_reason, summary} =
      automation_card_placement(job, live, latest)

    %{
      id: "automation:#{job.id}",
      rawID: to_string(job.id),
      kind: :automation_job,
      cardType: :routine,
      column: column,
      status: status,
      attention: attention?,
      attentionReason: attention_reason,
      title: non_empty(job.label) || job.action_key,
      summary: summary,
      agentUID: nil,
      agentName: nil,
      conversationID: nil,
      conversationTitle: nil,
      pageID: job.page_id,
      pageTitle: page_titles[job.page_id] || "",
      manageable: job.authorization_kind != "human" or job.human_uid == authority_uid,
      stoppable: false,
      canMessage: false,
      stepCount: length(live),
      planCompleted: nil,
      planTotal: nil,
      chainLength: 1,
      activeExecutionKind: nil,
      activeExecutionID: nil,
      schedule: primary_schedule && primary_schedule.schedule,
      timezone: primary_schedule && primary_schedule.timezone,
      nextRunAt: primary_schedule && primary_schedule.next_fire_at,
      lastRunAt: latest && (latest.finished_at || latest.started_at || latest.inserted_at),
      lastRunStatus: latest && to_string(latest.status),
      triggerSummary: automation_trigger_summary(length(job_schedules), webhooks),
      createdAt: job.inserted_at,
      updatedAt: job.updated_at
    }
  end

  defp automation_card_placement(job, live, latest) do
    unavailable? = is_binary(job.unavailable_reason) and job.unavailable_reason != ""
    latest_failed? = match?(%AutomationRun{status: :failed}, latest)

    cond do
      unavailable? ->
        {:running, "unavailable", true, "unavailable", job.unavailable_reason}

      live != [] ->
        {:running, "running", false, nil, job.action_key}

      latest_failed? ->
        {:running, "failed", true, "failed", excerpt(latest.error, 180) || job.action_key}

      true ->
        {:scheduled, "active", false, nil, job.action_key}
    end
  end

  defp build_routine_detail(:cron, %AgentRoutine{} = routine, item) do
    session_id = Schedule.routine_execution_session_id(routine.id)
    entries = Schedule.list_routine_run_entries(routine, @routine_history_limit)

    stopped_signal_ids =
      for({:signal, signal} <- entries, do: signal.id)
      |> Conversations.stopped_delivery_signal_ids()

    runs =
      Enum.map(entries, fn
        {:signal, signal} ->
          %{
            id: signal.id,
            status: routine_signal_status(signal),
            trigger: routine_signal_trigger(signal),
            startedAt: signal.last_attempt_at || signal.inserted_at,
            finishedAt: signal.completed_at || signal.dead_letter_at,
            summary: non_empty(signal.turn_summary),
            error: routine_signal_error(signal),
            deliveryWarning: MapSet.member?(stopped_signal_ids, signal.id)
          }

        {:event, event} ->
          %{
            id: to_string(event.id),
            status: to_string(event.status),
            trigger: get_in(event.wake_payload || %{}, ["trigger"]) || "scheduled",
            startedAt: event.due_at,
            finishedAt: event.fired_at || event.cancelled_at,
            summary: nil,
            error: map_error_reason(event.last_fire_error),
            deliveryWarning: false
          }
      end)

    child_jobs = AgentJobQueries.session_head_jobs(session_id, 20)
    child_wfs = WorkflowQueries.session_runs(session_id, 20)

    child_executions =
      Enum.map(child_jobs, fn job ->
        %{
          id: to_string(job.id),
          kind: :background_agent_job,
          title: non_empty(job.title) || "Job ##{job.id}",
          status: to_string(job.status),
          summary: job_card_summary(job, %{}),
          startedAt: job.started_at,
          completedAt: job.completed_at,
          createdAt: job.inserted_at
        }
      end) ++
        Enum.map(child_wfs, fn wf ->
          %{
            id: to_string(wf.id),
            kind: :workflow,
            title: non_empty(wf.title) || "Workflow ##{wf.id}",
            status: to_string(wf.status),
            summary:
              if(wf.status == :failed,
                do: workflow_error_excerpt(wf.error),
                else: excerpt(wf.result_text, 180)
              ),
            startedAt: wf.inserted_at,
            completedAt: wf.completed_at,
            createdAt: wf.inserted_at
          }
        end)

    {:ok,
     %{
       item: item,
       instructions: routine.task || "",
       quietSuccess: get_in(routine.delivery || %{}, ["quiet_success"]) == true,
       unavailableReason: nil,
       runs: runs,
       childExecutions: child_executions
     }}
  end

  defp build_routine_detail(:checkback, %ScheduledEvent{} = event, item) do
    payload = event.wake_payload || %{}

    instructions =
      [non_empty(payload["check"]), non_empty(payload["context_summary"])]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n\n")

    {:ok,
     %{
       item: item,
       instructions: instructions,
       quietSuccess: payload["quiet_success"] == true,
       unavailableReason: nil,
       runs: [],
       childExecutions: []
     }}
  end

  defp build_routine_detail(:automation_job, %AutomationJob{} = job, item) do
    runs =
      job.id
      |> Applet.recent_runs_for_job(@routine_history_limit)
      |> Enum.map(fn run ->
        %{
          id: to_string(run.id),
          status: to_string(run.status),
          trigger: get_in(run.event || %{}, ["type"]),
          startedAt: run.started_at || run.inserted_at,
          finishedAt: run.finished_at,
          summary: excerpt(run.stdout, 240),
          error: excerpt(run.error, 240),
          deliveryWarning: false
        }
      end)

    {:ok,
     %{
       item: item,
       instructions: job.action_key,
       quietSuccess: nil,
       unavailableReason: job.unavailable_reason,
       runs: runs,
       childExecutions: []
     }}
  end

  defp candidate_agents(%Actor{} = actor) do
    uid = Actor.uid(actor)

    own_pa =
      case Principals.personal_assistant(uid) do
        %{principal: %Principals.Principal{} = principal} -> [principal]
        _ -> []
      end

    colleagues = Conversations.agents(actor)

    (own_pa ++ colleagues)
    |> Enum.filter(&(&1.status == :active))
    |> Enum.uniq_by(& &1.uid)
    |> Enum.map(fn principal ->
      agent_record =
        Map.get(principal, :agent) || Principals.get_agent_record!(principal.uid)

      agent_type =
        case agent_record do
          %{type: type} when not is_nil(type) -> to_string(type)
          _ -> "ai_colleague"
        end

      can_run_job? =
        match?({:ok, _}, ModelProfiles.resolve_runtime_profile(principal.uid, "heavy"))

      %{
        uid: principal.uid,
        displayName: Principals.display_name(principal),
        agentType: agent_type,
        avatarURL: principal.avatar_url,
        canRunBackgroundJob: can_run_job?
      }
    end)
  end

  defp bound_completed_cards(cards) do
    {completed, active} = Enum.split_with(cards, &(&1.column == :completed))

    kept_completed =
      completed
      |> Enum.sort_by(&(&1.lastRunAt || &1.updatedAt), {:desc, DateTime})
      |> Enum.take(@terminal_limit)

    active ++ kept_completed
  end

  defp sort_board_cards(cards) do
    Enum.sort_by(cards, fn card ->
      case card.column do
        :scheduled ->
          due_unix =
            if card.nextRunAt,
              do: DateTime.to_unix(card.nextRunAt, :microsecond),
              else: 9_999_999_999_999_999

          {0, due_unix, -DateTime.to_unix(card.updatedAt, :microsecond)}

        :running ->
          {1, if(card.attention, do: 0, else: 1), -DateTime.to_unix(card.updatedAt, :microsecond)}

        :completed ->
          ts = card.lastRunAt || card.updatedAt
          {2, 0, -DateTime.to_unix(ts, :microsecond)}
      end
    end)
  end

  defp reject_foreign_pa(viewer_uid, agent_uid) when is_binary(agent_uid) do
    case Principals.get_agent_record!(agent_uid) do
      %{type: :personal_assistant, owner_principal_uid: owner} when owner != viewer_uid ->
        {:error, :forbidden}

      _ ->
        :ok
    end
  end

  defp reject_foreign_pa(_viewer_uid, _agent_uid), do: :ok

  defp principal_names([]), do: %{}

  defp principal_names(uids) do
    Principals.list_principals!(query: [filter: [uid: [in: uids]]])
    |> Map.new(&{&1.uid, Principals.display_name(&1)})
  end

  defp callable_agent_set(_actor, []), do: MapSet.new()

  defp callable_agent_set(actor, agent_uids) do
    Enum.reduce(agent_uids, MapSet.new(), fn uid, acc ->
      if Native.authorize_agent(actor, uid) == :ok, do: MapSet.put(acc, uid), else: acc
    end)
  end

  defp run_room_id(run, room_titles) do
    candidates = [
      session_room_id(run.owner_session_id),
      get_in(run.reply_route || %{}, ["conversation_id"])
    ]

    Enum.find(candidates, fn id -> is_binary(id) and Map.has_key?(room_titles, id) end)
  end

  defp session_room_id(session_id) when is_binary(session_id) do
    case Key.parse(session_id) do
      {:conversation, id} -> id
      _ -> nil
    end
  end

  defp session_room_id(_), do: nil

  defp job_card_summary(%AgentJob{} = job, metric) do
    cond do
      job.status == :waiting_on_user ->
        pending_question_text(job) || excerpt(job.task, 180)

      job.status in [:queued, :running] ->
        metric[:live_summary] || excerpt(job.task, 180)

      job.status == :succeeded ->
        map_text(job.result, ["summary", "output_text"]) || excerpt(job.task, 180)

      job.status == :failed ->
        map_text(job.error, ["summary", "reason", "message", "code"])

      true ->
        excerpt(job.task, 180)
    end
  end

  defp cron_card_summary(routine, waiting_job, latest_outcome, latest_summary) do
    cond do
      waiting_job != nil ->
        pending_question_text(waiting_job) || excerpt(routine.task, 180)

      latest_outcome.failed? ->
        latest_outcome.error || excerpt(routine.task, 180)

      non_empty(latest_summary) != nil ->
        excerpt(latest_summary, 180)

      true ->
        excerpt(routine.task, 180)
    end
  end

  defp latest_routine_outcome(nil, nil) do
    %{at: nil, status: nil, failed?: false, error: nil}
  end

  defp latest_routine_outcome(signal, nil), do: signal_outcome_snapshot(signal)
  defp latest_routine_outcome(nil, event), do: event_outcome_snapshot(event)

  defp latest_routine_outcome(signal, event) do
    sig = signal_outcome_snapshot(signal)
    evt = event_outcome_snapshot(event)

    case {sig.at, evt.at} do
      {%DateTime{} = sig_at, %DateTime{} = evt_at} ->
        if DateTime.compare(sig_at, evt_at) in [:gt, :eq], do: sig, else: evt

      {%DateTime{}, nil} ->
        sig

      _ ->
        evt
    end
  end

  defp signal_outcome_snapshot(signal) do
    failed? = routine_signal_failed?(signal)

    %{
      at:
        signal.completed_at || signal.dead_letter_at || signal.last_attempt_at ||
          signal.inserted_at,
      status: routine_signal_status(signal),
      failed?: failed?,
      error: if(failed?, do: routine_signal_error(signal))
    }
  end

  defp event_outcome_snapshot(%ScheduledEvent{} = event) do
    failed? = event.status == :failed

    %{
      at: event.fired_at || event.cancelled_at || event.due_at,
      status: to_string(event.status),
      failed?: failed?,
      error: if(failed?, do: map_error_reason(event.last_fire_error))
    }
  end

  defp routine_signal_status(%{status: :queued}), do: "queued"
  defp routine_signal_status(%{status: :running}), do: "running"
  defp routine_signal_status(%{status: :completed}), do: "succeeded"

  defp routine_signal_status(%{status: :dead_letter, dead_letter_reason: %{"reason" => reason}})
       when reason in ["routine_paused", "routine_deleted"],
       do: "cancelled"

  defp routine_signal_status(%{status: :dead_letter}), do: "failed"
  defp routine_signal_status(%{status: status}), do: to_string(status)

  defp routine_signal_failed?(%{status: :dead_letter, dead_letter_reason: %{"reason" => reason}})
       when reason in ["routine_paused", "routine_deleted"],
       do: false

  defp routine_signal_failed?(%{status: :dead_letter}), do: true
  defp routine_signal_failed?(_), do: false

  defp routine_signal_error(signal) do
    if routine_signal_failed?(signal) do
      map_error_reason(signal.dead_letter_reason)
    end
  end

  defp routine_signal_trigger(%{type: "cron.fire", data: data}) do
    get_in(data || %{}, ["wake_payload", "trigger"]) || "scheduled"
  end

  defp routine_signal_trigger(%{type: "routine.manual_run"}), do: "manual"
  defp routine_signal_trigger(%{type: "check_back_later.wakeup"}), do: "checkback"

  defp routine_signal_trigger(signal) do
    case Ankole.Signals.Coalesce.batch_size(signal) do
      count when count > 1 -> "#{signal.type} (×#{count})"
      _ -> signal.type
    end
  end

  defp routine_trigger_summary(nil, 0), do: nil
  defp routine_trigger_summary(nil, event_count), do: "event:#{event_count}"

  defp routine_trigger_summary(cron, 0), do: cron_expression_label(cron.schedule)

  defp routine_trigger_summary(cron, event_count) do
    [cron_expression_label(cron.schedule), "event:#{event_count}"]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" + ")
  end

  defp pending_question_text(%AgentJob{metadata: metadata}) when is_map(metadata) do
    case metadata["pending_user_input"] do
      %{"questions" => [%{"question" => q} | _]} when is_binary(q) -> excerpt(q, 180)
      %{"question" => q} when is_binary(q) -> excerpt(q, 180)
      _ -> nil
    end
  end

  defp pending_question_text(_), do: nil

  defp cron_expression_label(%{"expression" => expr}) when is_binary(expr), do: expr
  defp cron_expression_label(_), do: nil

  defp automation_trigger_summary(schedules, webhooks) do
    parts =
      [
        if(schedules > 0, do: "cron:#{schedules}"),
        if(webhooks > 0, do: "webhook:#{webhooks}")
      ]
      |> Enum.reject(&is_nil/1)

    if parts == [], do: "signal", else: Enum.join(parts, ",")
  end

  defp workflow_error_excerpt(error) when is_map(error),
    do: map_text(error, ["message", "summary", "reason", "code"])

  defp workflow_error_excerpt(_), do: nil

  defp map_error_reason(error) when is_map(error),
    do: map_text(error, ["reason", "message", "summary", "code"])

  defp map_error_reason(_), do: nil

  defp map_text(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key ->
      case Map.get(map, key) do
        value when is_binary(value) -> excerpt(value, 200)
        _ -> nil
      end
    end)
  end

  defp map_text(_, _), do: nil

  defp fresh_terminal?(%DateTime{} = at, %DateTime{} = now) do
    DateTime.diff(now, at, :second) <= @fresh_failure_seconds
  end

  defp fresh_terminal?(_, _), do: false

  defp routine_card_id(:cron, raw_id), do: "cron:#{raw_id}"
  defp routine_card_id(:automation_job, raw_id), do: "automation:#{raw_id}"
  defp routine_card_id(:checkback, raw_id), do: "checkback:#{raw_id}"

  defp normalize_routine_kind(kind) when kind in [:cron, "cron"], do: :cron

  defp normalize_routine_kind(kind) when kind in [:automation_job, "automation_job"],
    do: :automation_job

  defp normalize_routine_kind(kind) when kind in [:checkback, "checkback"], do: :checkback

  defp normalize_exec_kind(kind)
       when kind in [:background_agent_job, "background_agent_job"],
       do: :background_agent_job

  defp normalize_exec_kind(kind) when kind in [:workflow, "workflow"], do: :workflow

  defp non_empty(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty(_), do: nil

  defp excerpt(value, max) when is_binary(value) do
    case non_empty(value) do
      nil -> nil
      trimmed -> String.slice(trimmed, 0, max)
    end
  end

  defp excerpt(_, _), do: nil
end
