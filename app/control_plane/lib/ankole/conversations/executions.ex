defmodule Ankole.Conversations.Executions do
  @moduledoc """
  Controls and summarizes room-linked BackgroundAgentJob and Workflow executions.
  """

  alias Ankole.BackgroundAgentJobs
  alias Ankole.BackgroundAgentJobs.Control
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.Schemas.{Job, Turn}
  alias Ankole.Conversations
  alias Ankole.Conversations.{Native, NativeRoom}
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.Sessions
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.Run

  def stop(actor, conversation_id, kind, run_id)
      when kind in [:background_agent_job, :workflow, "background_agent_job", "workflow"] do
    kind = to_string(kind)

    with {:ok, parsed_id} <- Ankole.ModelIntegerID.parse(run_id) do
      result =
        Repo.transact_top_level(
          fn ->
            with :ok <- Ankole.Pod.lock_tree_in_tx(),
                 {:ok, conversation} <-
                   Conversations.visible_native_conversation(actor, conversation_id),
                 {:ok, run} <- linked_run(kind, parsed_id, conversation.id),
                 {:ok, _} <-
                   Principals.lock_principals_in_tx(
                     [Ankole.AuthZ.Actor.uid(actor), run.agent_uid]
                     |> Enum.uniq()
                     |> Enum.sort()
                   ),
                 :ok <- Native.check_human_in_tx(actor) do
              stop_in_tx(kind, run, actor.principal)
            end
          end,
          after_commit: &publish_stop/1
        )

      case result do
        {:ok, %{kind: "background_agent_job", job: job}} ->
          {:ok, %{runID: to_string(job.id), status: to_string(job.status)}}

        {:ok, %{kind: "workflow", run: run}} ->
          {:ok, %{runID: to_string(run.id), status: to_string(run.status)}}

        {:error, _} = error ->
          error
      end
    else
      :error -> {:error, :execution_not_found}
    end
  end

  def stop(_actor, _conversation_id, _kind, _run_id), do: {:error, :execution_not_found}

  def message(actor, conversation_id, run_id, request_id, text) do
    trimmed = if is_binary(text), do: String.trim(text), else: ""

    with {:ok, parsed_id} <- Ankole.ModelIntegerID.parse(run_id),
         {:ok, normalized_request_id} <- Ecto.UUID.cast(request_id),
         true <- trimmed != "" do
      result =
        Repo.transact_top_level(
          fn ->
            with :ok <- Ankole.Pod.lock_tree_in_tx(),
                 {:ok, conversation} <-
                   Conversations.visible_native_conversation(actor, conversation_id),
                 {:ok, %Job{} = job} <-
                   linked_run("background_agent_job", parsed_id, conversation.id),
                 true <- room_agent?(conversation.id, job.agent_uid),
                 {:ok, _} <-
                   Principals.lock_principals_in_tx(
                     [Ankole.AuthZ.Actor.uid(actor), job.agent_uid, job.human_uid]
                     |> Enum.reject(&is_nil/1)
                     |> Enum.uniq()
                     |> Enum.sort()
                   ),
                 :ok <- Native.check_human_in_tx(actor),
                 :ok <- active_agent_in_tx(job.agent_uid),
                 :ok <- Native.authorize_agent(actor, job.agent_uid) do
              message_or_respawn_in_tx(
                job,
                actor.principal,
                conversation.id,
                normalized_request_id,
                trimmed
              )
            else
              false -> {:error, :agent_unavailable}
              {:error, _} = error -> error
            end
          end,
          after_commit: fn %{commit: commit} ->
            BackgroundAgentJobs.Lifecycle.publish_status_commit(commit)
          end
        )

      case result do
        {:ok, %{mode: mode, commit: %{job: job}}} ->
          {:ok,
           %{
             runID: to_string(job.id),
             status: to_string(job.status),
             respawned: mode == :respawn
           }}

        {:error, {:background_agent_job_already_respawned, _successor_id}} ->
          {:error, :execution_already_continued}

        {:error, reason}
        when reason in [
               :background_agent_job_runtime_thread_missing,
               :background_agent_job_workspace_owner_missing
             ] ->
          {:error, :execution_not_continuable}

        {:error, _} = error ->
          error
      end
    else
      false -> {:error, :invalid_text}
      :error -> {:error, :execution_not_found}
    end
  end

  defp stop_in_tx("background_agent_job", %Job{} = job, principal) do
    if job.status in Job.terminal_statuses() do
      {:ok, %{kind: "background_agent_job", job: job, turn: nil, noop: true}}
    else
      with {:ok, sessions, commit} <-
             Control.prepare_stop_in_tx(job.id, %{
               "agent_uid" => job.agent_uid,
               "cancel_requested_by" => operator_ref(principal),
               "reason" => "Stopped from Pod conversation"
             }),
           :ok <- Sessions.Queue.lock_sessions_in_tx(sessions),
           {:ok, value} <- commit.() do
        {:ok, Map.put(value, :kind, "background_agent_job")}
      end
    end
  end

  defp stop_in_tx("workflow", %Run{} = run, _principal) do
    if run.status in [:completed, :failed, :cancelled] do
      {:ok, %{kind: "workflow", run: run, noop: true}}
    else
      with {:ok, value} <- Workflow.Lifecycle.cancel_in_tx(run.id, run.agent_uid) do
        {:ok, Map.put(value, :kind, "workflow")}
      end
    end
  end

  defp publish_stop(%{noop: true}), do: :ok

  defp publish_stop(%{kind: "background_agent_job"} = result) do
    BackgroundAgentJobs.Lifecycle.publish_status_commit(result)
    Sessions.stop_job_turn(result.job, result.turn)
  end

  defp publish_stop(%{kind: "workflow"} = result) do
    Workflow.cleanup_terminal_transition({:ok, result})
  end

  defp message_or_respawn_in_tx(job, principal, conversation_id, request_id, text) do
    if job.status in Job.terminal_statuses() do
      respawn_in_tx(job, principal, conversation_id, request_id, text)
    else
      case Control.prepare_message_in_tx(job.id, %{
             "agent_uid" => job.agent_uid,
             "request_id" => request_id,
             "message" => text
           }) do
        {:ok, sessions, commit} ->
          with :ok <- Sessions.Queue.lock_sessions_in_tx(sessions),
               {:ok, value} <- commit.() do
            {:ok, %{mode: :steer, commit: value}}
          end

        {:error, {:background_agent_job_message_status_invalid, _terminal_status}} ->
          respawn_in_tx(job, principal, conversation_id, request_id, text)

        {:error, _} = error ->
          error
      end
    end
  end

  defp respawn_in_tx(job, principal, conversation_id, request_id, text) do
    attrs = %{
      "agent_uid" => job.agent_uid,
      "created_by" => %{"principal_uid" => operator_ref(principal)},
      "owner_session_id" => job.owner_session_id,
      "source_tool_call_id" => "pod-followup:#{request_id}",
      "reply_route" => normalize_reply_route(job.reply_route, conversation_id),
      "message" => text
    }

    with {:ok, sessions, commit} <- Dispatch.prepare_respawn_in_tx(job.id, attrs),
         :ok <- Sessions.Queue.lock_sessions_in_tx(sessions),
         {:ok, value} <- commit.() do
      {:ok, %{mode: :respawn, commit: value}}
    end
  end

  defp normalize_reply_route(route, conversation_id) when is_map(route) do
    if is_binary(route["binding_name"]) or is_binary(route["conversation_id"]) do
      route
    else
      Map.put(route, "conversation_id", conversation_id)
    end
  end

  defp normalize_reply_route(_route, conversation_id),
    do: %{"conversation_id" => conversation_id}

  defp linked_run("background_agent_job", id, conversation_id) do
    case BackgroundAgentJobs.get_job(id) do
      %Job{} = job ->
        if get_in(job.metadata || %{}, ["skill_lesson_reflection"]) != true and
             linked_to_room?(job, conversation_id),
           do: {:ok, job},
           else: {:error, :execution_not_found}

      nil ->
        {:error, :execution_not_found}
    end
  end

  defp linked_run("workflow", id, conversation_id) do
    case Workflow.get_run!(id) do
      %Run{} = run ->
        if linked_to_room?(run, conversation_id),
          do: {:ok, run},
          else: {:error, :execution_not_found}

      nil ->
        {:error, :execution_not_found}
    end
  end

  defp linked_to_room?(run, conversation_id) do
    run.owner_session_id == Sessions.Key.conversation(conversation_id) and
      (room_agent?(conversation_id, run.agent_uid) or historical_source?(run, conversation_id))
  end

  defp historical_source?(run, conversation_id) do
    source = run.source_signal_id && Ankole.Signals.get_signal!(run.source_signal_id)
    match?(%{conversation_id: ^conversation_id, agent_uid: uid} when uid == run.agent_uid, source)
  end

  defp room_agent?(conversation_id, agent_uid) do
    Enum.any?(NativeRoom.participants(conversation_id), fn member ->
      member.role == :agent and member.principal_uid == agent_uid
    end)
  end

  defp active_agent_in_tx(agent_uid) do
    case Principals.lock_principals_in_tx([agent_uid]) do
      {:ok, [%{type: :agent, status: :active}]} -> :ok
      _ -> {:error, :agent_unavailable}
    end
  end

  defp operator_ref(principal), do: principal |> Ankole.ActorRef.from_principal() |> to_string()

  @doc false
  def room_metrics(jobs, workflows) do
    job_metrics = build_job_metrics(jobs)
    workflow_metrics = build_workflow_metrics(workflows)
    %{jobs: job_metrics, workflows: workflow_metrics}
  end

  defp build_job_metrics([]), do: %{}

  defp build_job_metrics(jobs) do
    job_ids = Enum.map(jobs, & &1.id)

    successors =
      Map.new(
        for job <- jobs,
            is_integer(job.continued_from_job_id),
            do: {job.continued_from_job_id, job.id}
      )

    %{
      turns_by_job: turns_by_job,
      item_counts: item_counts,
      latest_live_items: latest_live_items
    } = BackgroundAgentJobs.turn_summary_snapshots(job_ids)

    Map.new(jobs, fn job ->
      job_turns = Map.get(turns_by_job, job.id, [])
      lead_turns = Enum.filter(job_turns, &Turn.lead?(&1, job.runtime_thread_id))
      latest_lead = List.last(lead_turns) || List.last(job_turns)
      step_count = Enum.reduce(job_turns, 0, fn t, acc -> acc + Map.get(item_counts, t.id, 0) end)
      {plan_completed, plan_total} = plan_counts(latest_lead)

      live_label =
        latest_lead && live_item_summary(Map.get(latest_live_items, latest_lead.id), latest_lead)

      {job.id,
       %{
         successor_job_id: Map.get(successors, job.id),
         step_count: step_count,
         plan_completed: plan_completed,
         plan_total: plan_total,
         live_summary: live_label
       }}
    end)
  end

  defp plan_counts(%Turn{progress: %{"plan" => %{"steps" => steps}}})
       when is_list(steps) and steps != [] do
    completed = Enum.count(steps, &(is_map(&1) and &1["status"] == "completed"))
    {completed, length(steps)}
  end

  defp plan_counts(_turn), do: {nil, nil}

  defp live_item_summary(%{"type" => "agentMessage", "text" => text}, _turn)
       when is_binary(text) do
    trimmed = String.trim(text)
    if trimmed != "", do: String.slice(trimmed, 0, 160)
  end

  defp live_item_summary(%{"type" => "commandExecution", "command" => cmd}, _turn)
       when is_binary(cmd) do
    clean = Sessions.Presentation.Execution.unwrap_shell_command(cmd)
    if clean != "", do: String.slice(clean, 0, 120)
  end

  defp live_item_summary(%{"type" => "fileChange", "changes" => [%{"path" => path} | _]}, _turn)
       when is_binary(path),
       do: path

  defp live_item_summary(
         %{"type" => "dynamicToolCall", "tool" => "skill_view", "arguments" => %{"name" => name}},
         _turn
       )
       when is_binary(name),
       do: name

  defp live_item_summary(%{"type" => "webSearch", "query" => query}, _turn) when is_binary(query),
    do: String.slice(query, 0, 120)

  defp live_item_summary(_item, %Turn{progress: %{"plan" => %{"steps" => steps}}})
       when is_list(steps) do
    Enum.find_value(steps, fn
      %{"status" => "in_progress", "step" => step} when is_binary(step) and step != "" ->
        String.slice(step, 0, 140)

      _ ->
        nil
    end)
  end

  defp live_item_summary(_item, _turn), do: nil

  defp build_workflow_metrics([]), do: %{}

  defp build_workflow_metrics(workflows) do
    counts_by_run =
      workflows
      |> Enum.map(& &1.id)
      |> Workflow.run_counts()

    Map.new(workflows, fn run ->
      counts = Map.get(counts_by_run, run.id, %{})

      {run.id,
       %{
         total: Map.get(counts, "total", 0),
         completed: Map.get(counts, "succeeded", 0),
         running: Map.get(counts, "running", 0),
         queued: Map.get(counts, "queued", 0),
         sleeping: Map.get(counts, "sleeping", 0),
         failed: Map.get(counts, "failed", 0)
       }}
    end)
  end
end
