defmodule Ankole.Pod.Chat.Presentation do
  @moduledoc "The browser projection of a room, its members, and its execution history."
  require Ash.Expr
  alias Ankole.BackgroundAgentJobs.Schemas.{Job, Turn}
  alias Ankole.BackgroundAgentJobs.TrajectoryReader
  alias Ankole.Conversations.{Executions, ModelPreferences, Native, NativeRoom}
  alias Ankole.Pod.Chat.JobItemProjection

  def detail(detail) do
    artifacts = detail.artifacts
    saved = detail.saved_pages
    assistant_names = detail.assistant_names

    messages =
      Enum.map(
        detail.messages,
        &Map.put(
          message_json(
            &1,
            detail.interaction_states,
            Map.get(detail, :action_card_states, %{}),
            assistant_names
          ),
          :savedPages,
          Map.get(saved, &1.id, [])
        )
      )

    queues =
      Enum.map(detail.agents, fn agent ->
        inputs = Enum.filter(detail.pending_inputs, &(&1.agent_uid == agent.uid))

        %{
          agentUID: agent.uid,
          retryableMessageID: detail.retryable_message_ids[agent.uid],
          queueVersion: Map.fetch!(detail.queue_versions, agent.uid),
          paused: queue_paused?(detail.conversation, agent.uid),
          workStatus: %{
            state: detail.statuses[agent.uid].state,
            retryAt: timestamp(detail.statuses[agent.uid].retry_at)
          },
          inputs:
            Enum.map(inputs, &queued_input(&1, detail.queued_messages, detail.mention_names))
        }
      end)

    latest_input = detail.latest_input

    %{
      conversation: conversation(detail),
      artifacts: room_artifacts(detail.conversation, artifacts, saved),
      messages: messages,
      olderMessagesBeforeSeq: detail.older_messages_before_seq,
      removedMessageIDs: detail.removed_message_ids,
      messageRange: %{
        firstSeq: detail.message_range.first_seq,
        lastSeq: detail.message_range.last_seq
      },
      pendingQueues: queues,
      latestInput:
        if(latest_input,
          do: %{
            messageID: latest_input.id,
            authorUID: latest_input.author_uid,
            agentUIDs: detail.latest_input_agent_uids
          }
        ),
      activities: detail.activities,
      pendingInteractions: pending_interactions(detail),
      linkedRuns: linked_runs(detail)
    }
  end

  def conversations(details), do: Enum.map(details, &conversation/1)

  def conversation(
        %{conversation: conversation, participants: participants, viewer: viewer} =
          detail
      ) do
    members = Enum.reject(participants, &(&1.role == :observer))

    projected =
      Enum.map(members, fn member ->
        principal = Map.fetch!(detail.member_principals, member.principal_uid)

        Map.merge(
          project_agent(principal, principal.agent, detail.member_names[principal.uid]),
          %{
            canChat: MapSet.member?(detail.callable_agents, principal.uid),
            role: to_string(member.role),
            mayIntervene: member.may_intervene,
            modelProfile:
              if(member.role == :agent, do: ModelPreferences.logical(conversation, principal.uid))
          }
        )
      end)

    %{
      id: conversation.id,
      title: conversation.title,
      pageID: conversation.page_id,
      roomMode: conversation.room_mode,
      conversationKind:
        cond do
          Enum.any?(projected, &(&1.agentType == "personal_assistant")) -> :assistant_task
          not is_nil(conversation.dm_colleague_uid) -> :colleague_dm
          true -> :group
        end,
      accessScope: conversation.native_access_scope,
      createdBy: conversation.created_by,
      canDelete: detail.owner?,
      canManage: detail.owner?,
      titleCustomized: conversation.title_customized,
      lastMessageSeq: conversation.sequence_high_water,
      latestMessagePreview: Map.get(detail, :latest_message_preview, ""),
      searchMatch: Map.get(detail, :search_match),
      viewer: %{
        uid: detail.viewer_uid,
        pinned: (viewer && not is_nil(viewer.pinned_at)) || false,
        muted: (viewer && viewer.muted) || false,
        lastReadSeq: (viewer && viewer.last_read_seq) || 0,
        lastVisitedAt: viewer && timestamp(viewer.last_visited_at)
      },
      agents: Enum.filter(projected, &(&1.type == "agent")),
      participants: projected,
      agent:
        case Map.get(detail, :agent) do
          nil ->
            nil

          principal ->
            project_agent(principal, principal.agent, detail.member_names[principal.uid])
        end,
      lastActivityAt: timestamp(conversation.last_activity_at),
      rowStatus: row_status(detail)
    }
  end

  def agent(principal) do
    agent = if principal.type == :agent, do: Ankole.Principals.get_agent_record!(principal.uid)
    project_agent(principal, agent, NativeRoom.display_name(principal))
  end

  defp project_agent(principal, agent, name) do
    %{
      uid: principal.uid,
      displayName: name,
      avatarURL: principal.avatar_url,
      type: to_string(principal.type),
      agentType: if(agent, do: to_string(agent.type)),
      role: if(agent, do: agent.role),
      aliases:
        if(agent && agent.type == :personal_assistant,
          do: Ankole.Principals.assistant_aliases(principal),
          else: []
        ),
      active: principal.status == :active,
      mayIntervene: false,
      modelProfile: nil
    }
  end

  defp row_status(%{conversation: conversation, agents: agents, viewer: viewer} = detail) do
    cond do
      pending_interactions(detail) != [] or Map.get(detail, :has_prepared_action_card?, false) ->
        "waiting_choice"

      Enum.any?(
        agents,
        &(detail.statuses[&1.uid].state in [
            :running,
            :retrying
          ])
      ) ->
        "streaming"

      Map.get(detail, :peer_running?, false) or
        Enum.any?(detail.linked_jobs, &(&1.status in [:queued, :running, :waiting_on_user])) or
          Enum.any?(detail.linked_workflows, &(&1.status == :running)) ->
        "running_background"

      not is_nil(viewer) and not viewer.muted and
          conversation.last_notifiable_seq > viewer.last_read_seq ->
        "unread"

      true ->
        "idle"
    end
  end

  defp queue_paused?(conversation, uid),
    do: conversation.metadata["queue_paused:" <> uid] == true

  defp queued_input(input, messages, names),
    do: %{
      messageID: input.message_id,
      agentUID: input.agent_uid,
      authorUID: input.human_uid,
      text: input.data["text"] || "",
      attachments: attachments_with_positions(get_in(input.data, ["entry", "attachments"]) || []),
      links: Map.get(messages, input.message_id, %{links: []}).links,
      mentions:
        Enum.map(Map.get(messages, input.message_id, %{mentions: []}).mentions, fn mention ->
          %{
            type: mention["type"],
            uid: mention["uid"],
            displayName: mention["displayName"] || names[mention["uid"]]
          }
        end),
      modelProfile: input.data["model_profile"] || "primary",
      deliveryMode: input.data["delivery_mode"] || "steer"
    }

  defp message_json(message, interactions, action_cards, assistant_names) do
    rich = message.rich_content || %{}

    rich =
      case rich["clarify"] do
        %{} = clarify ->
          Map.put(
            rich,
            "clarify",
            Map.merge(clarify, Map.get(interactions, message.id, %{"state" => "superseded"}))
          )

        _ ->
          rich
      end

    rich =
      case rich["action_card"] do
        %{} = card ->
          Map.put(
            rich,
            "action_card",
            Map.merge(card, Map.get(action_cards, message.id, %{}))
          )

        _ ->
          rich
      end

    %{
      id: message.id,
      seq: message.seq,
      authorType: to_string(message.author_type),
      authorUID: message.author_uid,
      authorDisplayName: assistant_names[message.author_uid] || message.author_display_name || "",
      authorArchived: message.author_type == :agent and is_nil(message.author_uid),
      kind: to_string(message.kind),
      text: message.text || "",
      links: message.links,
      mentions:
        Enum.map(message.mentions, fn mention ->
          case assistant_names[mention["uid"]] do
            nil -> mention
            name -> Map.put(mention, "displayName", name)
          end
        end),
      richContent: rich,
      attachments: attachments_with_positions(message.attachments),
      createdAt: timestamp(message.created_at),
      signalID: message.signal_id,
      replyToMessageID: message.reply_to_message_id
    }
  end

  defp pending_interactions(detail) do
    detail.pending_questions
    |> Enum.sort_by(& &1.seq)
    |> Enum.flat_map(fn message ->
      clarify = message.rich_content["clarify"]

      case Map.merge(
             clarify,
             Map.get(detail.interaction_states, message.id, %{"state" => "superseded"})
           ) do
        %{"state" => "pending"} = pending ->
          [Map.merge(pending, %{"messageID" => message.id, "agentUID" => message.author_uid})]

        _ ->
          []
      end
    end)
  end

  defp room_artifacts(conversation, messages, saved) do
    page_ids =
      Enum.flat_map(messages, fn message ->
        referenced = for %{"kind" => "page", "id" => id} <- message.links, do: id
        referenced ++ Enum.map(Map.get(saved, message.id, []), & &1.id)
      end)

    %{
      pageIDs: Enum.uniq(Enum.reject([conversation.page_id | page_ids], &is_nil/1)),
      attachments:
        for message <- messages, message.attachments != [] do
          %{messageID: message.id, attachments: attachments_with_positions(message.attachments)}
        end
    }
  end

  defp attachments_with_positions(attachments),
    do: Enum.with_index(attachments, &Map.put(&1, "position", &2))

  def execution(actor, id, kind, run_id, cursor \\ nil) do
    Ankole.Repo.transact_repeatable_read_only(fn ->
      with {:ok, _room} <- Ankole.Conversations.visible_native_conversation(actor, id),
           run when not is_nil(run) <- execution_run(kind, run_id),
           true <- linked_to_room?(run, id) do
        can_act? =
          match?(
            %Ankole.Conversations.Participant{role: :agent},
            NativeRoom.participant(id, run.agent_uid)
          ) and Native.authorize_agent(actor, run.agent_uid) == :ok

        execution_page(run, kind, cursor, can_act?)
      else
        false -> {:error, :execution_not_found}
        nil -> {:error, :execution_not_found}
        error -> error
      end
    end)
  end

  defp linked_runs(detail) do
    id = detail.conversation.id
    metrics = Map.get(detail, :execution_metrics, %{jobs: %{}, workflows: %{}})
    callable = Map.get(detail, :callable_agents, MapSet.new())

    agents =
      detail.participants
      |> Enum.filter(&(&1.role == :agent))
      |> MapSet.new(& &1.principal_uid)

    Enum.map(
      Enum.filter(detail.linked_jobs, &linked_to_room?(&1, id, agents, detail.source_signals)),
      fn job ->
        can_act? =
          MapSet.member?(agents, job.agent_uid) and MapSet.member?(callable, job.agent_uid)

        job_run_summary(
          job,
          detail.source_signals[job.source_signal_id],
          Map.get(metrics.jobs, job.id, %{}),
          can_act?
        )
      end
    ) ++
      Enum.map(
        Enum.filter(
          detail.linked_workflows,
          &linked_to_room?(&1, id, agents, detail.source_signals)
        ),
        fn wf ->
          workflow_run_summary(
            wf,
            detail.source_signals[wf.source_signal_id],
            Map.get(metrics.workflows, wf.id)
          )
        end
      )
  end

  defp execution_run(:background_agent_job, id) do
    case Ankole.BackgroundAgentJobs.get_job(id) do
      %Job{metadata: %{"skill_lesson_reflection" => true}} -> nil
      job -> job
    end
  end

  defp execution_run(:workflow, id), do: Ankole.Workflow.get_run!(id)

  defp linked_to_room?(run, id, agents \\ nil, sources \\ nil) do
    member? =
      if agents,
        do: MapSet.member?(agents, run.agent_uid),
        else:
          match?(
            %Ankole.Conversations.Participant{role: :agent},
            NativeRoom.participant(id, run.agent_uid)
          )

    run.owner_session_id == Ankole.Sessions.Key.conversation(id) and
      (member? or historical_source?(run, id, sources))
  end

  defp historical_source?(run, id, sources) do
    source =
      if sources,
        do: sources[run.source_signal_id],
        else: run.source_signal_id && Ankole.Signals.get_signal!(run.source_signal_id)

    match?(%{conversation_id: ^id, agent_uid: uid} when uid == run.agent_uid, source)
  end

  defp execution_page(%Job{} = job, :background_agent_job, cursor, can_act?) do
    turns = Ankole.BackgroundAgentJobs.list_turns(job.id)
    projector = &JobItemProjection.project_row(&1, &2, job.runtime_thread_id)

    with {:ok, page} <-
           TrajectoryReader.page(job, {:projected_items, turns, projector}, cursor, %{
             groups: 25,
             bytes: 32 * 1_024
           }) do
      successor_id = Ankole.BackgroundAgentJobs.successor_job_id(job.id)
      step_count = Ankole.BackgroundAgentJobs.count_visible_turn_items(turns)
      items = Enum.map(page.units, & &1.item)

      {:ok,
       %{
         id: to_string(job.id),
         kind: :background_agent_job,
         title: job.title || "",
         agentUID: job.agent_uid,
         status: to_string(job.status),
         task: non_empty_text(job.task),
         createdAt: timestamp(job.inserted_at),
         startedAt: timestamp(job.started_at),
         completedAt: timestamp(job.completed_at),
         updatedAt: timestamp(job.updated_at),
         stoppable: job.status in [:queued, :running, :waiting_on_user],
         canMessage: job_can_message?(job, successor_id, can_act?),
         continuedFromJobID: job.continued_from_job_id && to_string(job.continued_from_job_id),
         successorJobID: successor_id && to_string(successor_id),
         outcomeText: job_outcome_text(job),
         errorText: job_error_text(job),
         stepCount: step_count,
         pendingQuestions: extract_pending_questions(job),
         plan: extract_job_plan(turns, job.runtime_thread_id),
         threads: extract_job_threads(turns, job.runtime_thread_id),
         workflowCounts: nil,
         items: items,
         nextCursor: page.next_cursor
       }}
    else
      {:error, :invalid_background_agent_job_trajectory_cursor} ->
        {:error, :invalid_execution_cursor}

      {:error, :background_agent_job_trajectory_cursor_stale} ->
        {:error, :invalid_execution_cursor}
    end
  end

  defp execution_page(workflow, :workflow, cursor, _can_act?) do
    with {:ok, after_seq} <- workflow_cursor(cursor) do
      filter = Ash.Expr.expr(run_id == ^workflow.id and call_seq > ^after_seq)

      calls =
        Ankole.Workflow.list_agent_calls!(
          query: [filter: filter, sort: [call_seq: :asc], limit: 51]
        )

      selected = Enum.take(calls, 50)
      next = if length(calls) > 50, do: to_string(List.last(selected).call_seq)
      counts = Executions.room_metrics([], [workflow]).workflows[workflow.id]

      items =
        Enum.map(selected, fn call ->
          %{
            id: "call:#{call.call_seq}",
            kind: "workflow_call",
            callSeq: call.call_seq,
            title: call.label || "Task #{call.call_seq}",
            status: workflow_call_status(call.status),
            attempts: call.attempts,
            sleepNote: non_empty_text(call.sleep_note),
            attention: call.attention == true,
            output: format_workflow_call_result(call.result),
            error: format_workflow_error(call.error)
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
        end)

      {:ok,
       %{
         id: to_string(workflow.id),
         kind: :workflow,
         title: workflow.title || "",
         agentUID: workflow.agent_uid,
         status: to_string(workflow.status),
         task: nil,
         createdAt: timestamp(workflow.inserted_at),
         startedAt: timestamp(workflow.inserted_at),
         completedAt: timestamp(workflow.completed_at),
         updatedAt: timestamp(workflow.updated_at),
         stoppable: workflow.status == :running,
         canMessage: false,
         continuedFromJobID: nil,
         successorJobID: nil,
         outcomeText: non_empty_text(workflow.result_text),
         errorText: format_workflow_error(workflow.error),
         stepCount: counts.total,
         pendingQuestions: [],
         plan: nil,
         threads: [],
         workflowCounts: counts,
         items: items,
         nextCursor: next
       }}
    end
  end

  defp workflow_cursor(nil), do: {:ok, -1}

  defp workflow_cursor(cursor) do
    case Integer.parse(cursor) do
      {value, ""} when value >= 0 -> {:ok, value}
      _ -> {:error, :invalid_execution_cursor}
    end
  end

  defp workflow_call_status(:succeeded), do: "completed"
  defp workflow_call_status(:cancelled), do: "stopped"
  defp workflow_call_status(status), do: to_string(status)

  defp format_workflow_call_result(nil), do: nil
  defp format_workflow_call_result(value) when value == %{}, do: nil

  defp format_workflow_call_result(value) when is_binary(value) do
    non_empty_text(value)
  end

  defp format_workflow_call_result(value) do
    value |> Ankole.JSON.plain() |> Ankole.JSON.encode!()
  end

  defp format_workflow_error(nil), do: nil
  defp format_workflow_error(error) when error == %{}, do: nil

  defp format_workflow_error(error) when is_map(error) do
    summary =
      non_empty_text(error["summary"]) ||
        non_empty_text(error["message"]) ||
        non_empty_text(error["reason"]) ||
        non_empty_text(error["code"])

    if summary do
      strip_internal_uuids(summary)
    else
      error |> Ankole.JSON.plain() |> Ankole.JSON.encode!()
    end
  end

  defp format_workflow_error(_), do: nil

  defp job_can_message?(job, successor_id, true) do
    cond do
      job.status in [:queued, :running, :waiting_on_user] ->
        true

      job.status in [:succeeded, :failed, :stopped] ->
        is_binary(job.runtime_thread_id) and is_integer(job.workspace_owner_job_id) and
          is_nil(successor_id)

      true ->
        false
    end
  end

  defp job_can_message?(_job, _successor_id, _can_act), do: false

  defp job_outcome_text(%Job{result: result}) when is_map(result) do
    non_empty_text(result["summary"]) || non_empty_text(result["output_text"])
  end

  defp job_outcome_text(_job), do: nil

  defp job_error_text(%Job{status: :failed, error: error}) when is_map(error) do
    summary =
      non_empty_text(error["summary"]) ||
        non_empty_text(error["reason"]) ||
        non_empty_text(error["message"]) ||
        non_empty_text(error["code"])

    summary && strip_internal_uuids(summary)
  end

  defp job_error_text(_job), do: nil

  defp extract_pending_questions(%Job{status: :waiting_on_user, metadata: metadata})
       when is_map(metadata) do
    case metadata["pending_user_input"] do
      %{"questions" => questions} when is_list(questions) ->
        questions
        |> Enum.with_index()
        |> Enum.flat_map(fn {q, index} ->
          case is_map(q) && non_empty_text(q["question"]) do
            nil ->
              []

            question_text ->
              options =
                q["options"]
                |> List.wrap()
                |> Enum.flat_map(fn
                  %{"label" => label} = opt when is_binary(label) and label != "" ->
                    [
                      %{label: label, description: non_empty_text(opt["description"])}
                      |> Map.reject(fn {_k, v} -> is_nil(v) end)
                    ]

                  _ ->
                    []
                end)

              [
                %{
                  id: non_empty_text(q["id"]) || "q_#{index + 1}",
                  header: non_empty_text(q["header"]),
                  question: question_text,
                  isOther: q["isOther"] == true,
                  isSecret: q["isSecret"] == true,
                  options: options
                }
                |> Map.reject(fn {_k, v} -> is_nil(v) end)
              ]
          end
        end)

      %{"question" => question} when is_binary(question) ->
        case non_empty_text(question) do
          nil -> []
          text -> [%{id: "q_1", question: text, options: []}]
        end

      _ ->
        []
    end
  end

  defp extract_pending_questions(_job), do: []

  defp extract_job_plan(turns, lead_thread_id) do
    turns
    |> Enum.filter(&Turn.lead?(&1, lead_thread_id))
    |> Enum.reverse()
    |> Enum.find_value(fn
      %Turn{progress: %{"plan" => %{"steps" => steps} = plan}}
      when is_list(steps) and steps != [] ->
        normalized_steps =
          Enum.flat_map(steps, fn
            %{"step" => step} = entry when is_binary(step) and step != "" ->
              [%{step: step, status: non_empty_text(entry["status"]) || "pending"}]

            _ ->
              []
          end)

        if normalized_steps != [] do
          %{
            explanation: non_empty_text(plan["explanation"]),
            steps: normalized_steps
          }
          |> Map.reject(fn {_k, v} -> is_nil(v) end)
        end

      _ ->
        nil
    end)
  end

  defp extract_job_threads([], _lead_thread_id), do: []

  defp extract_job_threads(turns, lead_thread_id) do
    turns
    |> Enum.group_by(& &1.runtime_thread_id)
    |> Enum.map(fn {thread_id, thread_turns} ->
      latest = List.last(thread_turns)

      %{
        id: thread_id,
        isLead: Turn.lead?(latest, lead_thread_id),
        status: to_string(latest.status),
        turnCount: length(thread_turns)
      }
    end)
    |> Enum.sort_by(fn thread -> {not thread.isLead, thread.id} end)
  end

  defp job_run_summary(job, source, metric, can_act?) do
    successor_id = metric[:successor_job_id]
    pending_question = job |> extract_pending_questions() |> List.first()

    summary =
      cond do
        job.status == :waiting_on_user and not is_nil(pending_question) ->
          pending_question.question

        job.status in [:queued, :running] ->
          metric[:live_summary]

        job.status == :succeeded ->
          job_outcome_text(job)

        job.status == :failed ->
          job_error_text(job)

        true ->
          nil
      end

    %{
      kind: :background_agent_job,
      id: to_string(job.id),
      title: job.title || "",
      status: to_string(job.status),
      agentUID: job.agent_uid,
      sourceSignalID: job.source_signal_id,
      sourceMessageID: source && source.message_id,
      sourceToolCallID: job.source_tool_call_id,
      continuedFromJobID: job.continued_from_job_id && to_string(job.continued_from_job_id),
      successorJobID: successor_id && to_string(successor_id),
      stoppable: job.status in [:queued, :running, :waiting_on_user],
      canMessage: job_can_message?(job, successor_id, can_act?),
      summary: summary && String.slice(summary, 0, 240),
      stepCount: metric[:step_count] || 0,
      planCompleted: metric[:plan_completed],
      planTotal: metric[:plan_total],
      startedAt: timestamp(job.started_at),
      completedAt: timestamp(job.completed_at),
      createdAt: timestamp(job.inserted_at),
      updatedAt: timestamp(job.updated_at)
    }
  end

  defp workflow_run_summary(workflow, source, counts) do
    summary =
      cond do
        workflow.status == :completed -> non_empty_text(workflow.result_text)
        workflow.status == :failed -> format_workflow_error(workflow.error)
        true -> nil
      end

    %{
      kind: :workflow,
      id: to_string(workflow.id),
      title: workflow.title || "",
      status: to_string(workflow.status),
      agentUID: workflow.agent_uid,
      sourceSignalID: workflow.source_signal_id,
      sourceMessageID: source && source.message_id,
      sourceToolCallID: workflow.source_tool_call_id,
      stoppable: workflow.status == :running,
      canMessage: false,
      summary: summary && String.slice(summary, 0, 240),
      stepCount: if(counts, do: counts.total, else: 0),
      taskCounts: counts,
      startedAt: timestamp(workflow.inserted_at),
      completedAt: timestamp(workflow.completed_at),
      createdAt: timestamp(workflow.inserted_at),
      updatedAt: timestamp(workflow.updated_at)
    }
  end

  defp non_empty_text(value) when is_binary(value) do
    trimmed = String.trim(value)
    if trimmed == "", do: nil, else: value
  end

  defp non_empty_text(_), do: nil

  defp strip_internal_uuids(text) when is_binary(text) do
    Regex.replace(~r/\b[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}\b/i, text, "[internal-id]")
  end

  defp timestamp(nil), do: nil
  defp timestamp(%DateTime{} = value), do: DateTime.to_iso8601(value)
end
