defmodule Ankole.Conversations.Admission do
  @moduledoc "Admits durable input without reserving an Agent Computer."

  import Ecto.Query
  alias Ankole.AIAgent.TokenQuota
  alias Ankole.AIGateway.FailureDiagnostics
  alias Ankole.Conversations.{Commands, Context, Notices, Run}
  alias Ankole.Principals.{Principal, WorkAccess}
  alias Ankole.Repo
  alias Ankole.SignalsGateway.{ActorEvent, Actors, AIGatewayLink, ChannelContext}
  alias Ankole.SignalsGateway.ActorRuntime.{SessionWorkspaces, TurnRuntimeEnv}
  alias Ankole.Conversations.Scheduled
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkspace
  alias Ankole.Workflow

  @spec admit(map(), ActorEvent.t(), keyword()) :: {:ok, Run.t() | map()} | {:error, term()}
  def admit(key, event, opts \\ []) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    if Run.kind(key.session_id) == :job do
      Ankole.Conversations.CodexJob.admit(key, event, opts)
    else
      with {:ok, event} <- prepare_input(event, now),
           {:ok, plan} <- plan(event, opts) do
        prepared =
          with :ok <- TokenQuota.ensure_available(key.agent_uid),
               do: Context.runtime(key, plan.opts)

        Repo.transact(fn repo -> admit_in_tx(repo, key, event, plan, prepared, now) end)
      else
        {:closed, result} -> {:ok, result}
        error -> error
      end
      |> defer_workflow(event, now)
      |> Notices.finalize(event, now)
      |> Run.after_finalization()
    end
  end

  @spec authorize_event(ActorEvent.t()) :: {:ok, ActorEvent.t()} | {:error, term()}
  def authorize_event(event) do
    Repo.transact(fn repo -> authorize_event_in_tx(repo, event) end)
  end

  @spec authorize_event_in_tx(module(), ActorEvent.t()) ::
          {:ok, ActorEvent.t()} | {:error, term()}
  def authorize_event_in_tx(_repo, %ActorEvent{last_attempt_at: %DateTime{}} = event),
    do: {:ok, event}

  def authorize_event_in_tx(repo, event) do
    case authorize_new_in_tx(repo, event) do
      :ok ->
        {:ok, event}

      {:error, :tenant_suspended} ->
        with {:ok, %{actor_event: completed}} <-
               Notices.reject_suspended_input_in_tx(repo, event, DateTime.utc_now(:microsecond)),
             do: {:ok, completed}

      {:error, reason} ->
        Actors.mark_event_dead_letter_in_tx(
          repo,
          event,
          DateTime.utc_now(:microsecond),
          %{"code" => to_string(reason)}
        )
    end
  end

  defp defer_workflow({:error, :workflow_agent_at_capacity}, event, now) do
    with {:ok, event} <- Workflow.defer_task_event(event, DateTime.add(now, 30), :agent_capacity),
         do: {:ok, %{status: :deferred, actor_event: event}}
  end

  defp defer_workflow(result, _event, _now), do: result

  defp prepare_input(event, now) do
    case Run.kind(event) do
      :ambient -> prepare_ambient(event, now)
      :workflow_task -> prepare_workflow(event, now)
      _ -> {:ok, event}
    end
  end

  defp prepare_ambient(event, now) do
    case Ankole.Conversations.Ambient.resolve(event, now) do
      {:ok, %{status: :ambient_fresh, actor_event: event}} -> {:ok, event}
      {:ok, result} -> {:closed, result}
      error -> error
    end
  end

  defp prepare_workflow(event, now) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(event.session_id),
         {:ok, %{call: call, run: workflow}} <-
           Workflow.get_task_for_agent(call_id, event.agent_uid) do
      if call.status in Ankole.Workflow.Schemas.AgentCall.terminal_statuses() or
           workflow.status != "running" do
        complete_workflow_input(event, now)
      else
        {:ok, event}
      end
    end
  end

  defp complete_workflow_input(event, now) do
    case Repo.transact(fn repo ->
           with {:ok, :not_committed} <-
                  Run.finalize_committed_workflow_input_in_tx(repo, event),
                %ActorEvent{} = current <- Actors.lock_actor_event_in_tx(repo, event.id),
                {:ok, completed} <- Actors.mark_event_completed_in_tx(repo, current, now) do
             {:ok, %{status: :completed, actor_event: completed}}
           else
             {:ok, %{status: :completed} = result} -> {:ok, result}
             error -> error
           end
         end) do
      {:ok, value} -> {:closed, value}
      error -> error
    end
  end

  defp admit_in_tx(repo, key, snapshot, plan, prepared, now) do
    with {:ok, _} <- SessionWorkspaces.ensure_in_tx(repo, key.agent_uid, key.session_id),
         %ActorSessionWorkspace{} = workspace <-
           repo.one(
             from(w in ActorSessionWorkspace,
               where: w.agent_uid == ^key.agent_uid and w.session_id == ^key.session_id,
               lock: "FOR UPDATE"
             )
           ),
         %ActorEvent{agent_uid: uid, session_id: session} =
           event <-
           Actors.lock_actor_event_in_tx(repo, snapshot.id),
         true <- uid == key.agent_uid and session == key.session_id,
         {:ok, :not_committed} <- finalize_workflow_input_in_tx(repo, event, plan),
         true <- is_nil(event.completed_at) and event.input_state == "open",
         :ok <- authorize_attempt_in_tx(repo, event),
         :ok <- agent_active(repo, uid),
         {:ok, spec} <- prepared_spec(prepared, plan.kind),
         {:ok, kind_context} <- admit_kind_in_tx(repo, event, plan),
         :ok <- Commands.prepare_new_in_tx(repo, event, now),
         {:ok, conversation} <-
           AIGatewayLink.ensure_and_lock_conversation_in_tx(repo, uid, session, event),
         {:ok, workspace} <-
           workspace |> Ecto.Changeset.change(epoch: workspace.epoch + 1) |> repo.update(),
         {:ok, event} <-
           event
           |> ActorEvent.changeset(%{
             attempt_count: event.attempt_count + 1,
             last_attempt_at: now
           })
           |> repo.update() do
      run = %Run{
        agent_uid: uid,
        session_id: session,
        actor_event_id: event.id,
        epoch: workspace.epoch,
        event: event,
        conversation: conversation,
        workspace_id: workspace.id,
        spec: spec,
        kind: plan.kind
      }

      finish_admission_in_tx(repo, run, plan, kind_context, now)
    else
      {:ok, %{status: :completed} = result} -> {:ok, result}
      nil -> {:error, :input_unavailable}
      false -> {:error, :input_unavailable}
      {:error, :human_access_revoked} -> reject_access_in_tx(repo, snapshot, now)
      {:error, _} = error -> error
      _closed -> {:error, :input_unavailable}
    end
  end

  defp prepared_spec({:error, {:model_profile_unavailable, _profile, reason}} = error, kind)
       when kind in [:main, :scheduled, :ambient] do
    if FailureDiagnostics.provider_capacity?(reason),
      do: {:ok, {:provider_capacity, reason}},
      else: error
  end

  defp prepared_spec(prepared, _kind), do: prepared

  defp finish_admission_in_tx(
         _repo,
         %Run{spec: {:provider_capacity, reason}} = run,
         _plan,
         _kind_context,
         now
       ) do
    with {:ok, event} <- Run.defer_retry(%{run | spec: nil}, reason, now),
         do: {:ok, %{status: :deferred, actor_event: event}}
  end

  defp finish_admission_in_tx(repo, run, plan, kind_context, _now) do
    event = run.event
    visible = AIGatewayLink.visible_channel_context_refs(run.agent_uid, run.session_id)
    delivered = %{event | payload: ChannelContext.drop_visible_messages(event.payload, visible)}

    spec =
      run.spec
      |> Map.put(:workspace_id, run.workspace_id)
      |> Map.put(:runtime_env, TurnRuntimeEnv.resolve(event))
      |> Map.update!(:request_context, &Map.merge(&1, kind_context))

    run = %{run | delivered_event: delivered, spec: spec}

    if event.attempt_count - event.provider_capacity_attempt_count > 5 do
      reason = %{
        "code" => "conversation_attempts_exhausted",
        "attempt_count" => event.attempt_count
      }

      with :ok <- fail_exhausted_task_in_tx(repo, event, plan, reason),
           {:ok, result} <- Run.finalize_recovered_in_tx(repo, run, "dead_letter", reason) do
        {:ok, %{result | status: :dead_letter}}
      end
    else
      {:ok, run}
    end
  end

  defp finalize_workflow_input_in_tx(
         repo,
         %ActorEvent{last_attempt_at: %DateTime{}} = event,
         %{kind: :workflow_task}
       ),
       do: Run.finalize_committed_workflow_input_in_tx(repo, event)

  defp finalize_workflow_input_in_tx(_repo, _event, _plan), do: {:ok, :not_committed}

  # The durable attempt marker admits recovery after suspension. New input
  # still checks the tenant and its retained human authorization here.
  defp authorize_attempt_in_tx(_repo, %ActorEvent{last_attempt_at: %DateTime{}}), do: :ok
  defp authorize_attempt_in_tx(repo, event), do: authorize_new_in_tx(repo, event)

  defp authorize_new_in_tx(repo, %{type: "command.stop"} = event),
    do: WorkAccess.check_in_tx(repo, event)

  defp authorize_new_in_tx(repo, event) do
    with :ok <- Ankole.Tenants.check_work_admission(Repo.tenant_id!()),
         do: WorkAccess.check_in_tx(repo, event)
  end

  defp fail_exhausted_task_in_tx(repo, event, %{kind: :workflow_task, call_id: id}, reason) do
    failure =
      Map.merge(reason, %{
        "ok" => false,
        "summary" => "The task exhausted its input retry budget.",
        "retryable" => false
      })

    with {:ok, _} <-
           Workflow.submit_result_in_tx(repo, id, event.agent_uid, event.session_id, failure),
         do: :ok
  end

  defp fail_exhausted_task_in_tx(_repo, _event, _plan, _reason), do: :ok

  defp plan(event, opts) do
    case Workflow.parse_task_session_id(event.session_id) do
      {:ok, call_id} ->
        with {:ok, %{call: call, run: workflow}} <-
               Workflow.get_task_for_agent(call_id, event.agent_uid) do
          context = %{
            "run_id" => workflow.id,
            "call_id" => call.id,
            "prompt" => call.arguments["prompt"],
            "label" => call.label,
            "schema" => call.arguments["schema"] || %{"type" => "string"}
          }

          {:ok,
           %{
             kind: :workflow_task,
             call_id: call_id,
             context: context,
             opts:
               Keyword.merge(opts,
                 profile: call.model_profile || workflow.model_profile || "primary",
                 request_context: context
               )
           }}
        end

      :error ->
        main_plan(event, opts)
    end
  end

  defp main_plan(%ActorEvent{type: type} = event, opts)
       when type in ["cron.fire", "check_back_later.wakeup"] do
    {:ok, %{kind: :scheduled, opts: Scheduled.opts(event, opts)}}
  end

  defp main_plan(%ActorEvent{type: "im.message.may_intervene"}, opts),
    do: {:ok, %{kind: :ambient, opts: Keyword.put_new(opts, :profile, "light")}}

  defp main_plan(event, opts) do
    opts =
      if Commands.profile(event),
        do: Keyword.put(opts, :profile, Commands.profile(event)),
        else: opts

    if event.type == "command.llm" and Commands.profile(event) do
      case Ankole.AIAgent.ModelProfiles.get_custom_model_profile(
             event.agent_uid,
             Commands.profile(event)
           ) do
        {:ok, _} ->
          {:ok, %{kind: :main, opts: opts}}

        {:error, reason} ->
          {:error, {:model_profile_unavailable, Commands.profile(event), reason}}
      end
    else
      {:ok, %{kind: :main, opts: opts}}
    end
  end

  defp admit_kind_in_tx(repo, event, %{kind: :workflow_task} = plan) do
    with {:ok, %{call: call}} <-
           Workflow.claim_task_for_dispatch_in_tx(
             repo,
             event,
             plan.call_id,
             event.agent_uid,
             Ankole.Workflow.WorkerConfig.max_running_per_agent(),
             adopt_running: true
           ) do
      {:ok, Map.put(plan.context, "attempt", call.attempts)}
    end
  end

  defp admit_kind_in_tx(repo, event, %{kind: :ambient}),
    do:
      {:ok,
       %{"ambient_work_candidates" => Ankole.Conversations.Ambient.candidates_in_tx(repo, event)}}

  defp admit_kind_in_tx(_repo, _event, _plan), do: {:ok, %{}}

  defp reject_access_in_tx(repo, snapshot, _now) do
    with {:ok, result} <-
           Run.reject_input_in_tx(repo, snapshot, "dead_letter", :human_access_revoked),
         do: {:ok, Map.put(result, :status, :access_revoked)}
  end

  defp agent_active(repo, uid) do
    case repo.get(Principal, uid) do
      %Principal{type: :agent, status: :active} -> :ok
      _inactive -> {:error, :agent_not_active}
    end
  end
end
