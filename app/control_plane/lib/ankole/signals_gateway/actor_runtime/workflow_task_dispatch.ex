defmodule Ankole.SignalsGateway.ActorRuntime.WorkflowTaskDispatch do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.Workflow
  alias Ankole.Workflow.Schemas.AgentCall
  alias Ankole.Workflow.Schemas.Run
  alias Ankole.Workflow.WorkerConfig

  @retry_delay_seconds 30

  @spec process(map(), ActorEvent.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def process(actor_key, %ActorEvent{} = event, opts) when is_map(actor_key) and is_list(opts) do
    with true <-
           actor_key.session_id == event.session_id ||
             {:error, :workflow_task_session_mismatch},
         {:ok, call_id} <- Workflow.parse_task_session_id(event.session_id),
         {:ok, %{call: %AgentCall{} = call, run: %Run{} = run}} <-
           Workflow.get_task_for_agent(call_id, actor_key.agent_uid) do
      dispatch_existing(actor_key, event, call, run, opts)
    else
      :error -> {:error, :invalid_workflow_task_session}
      {:error, _reason} = error -> error
    end
  end

  defp dispatch_existing(_actor_key, event, call, %Run{status: status} = run, opts)
       when status != "running",
       do: complete_without_turn(event, call, run, opts)

  defp dispatch_existing(_actor_key, event, %AgentCall{status: status} = call, run, opts)
       when status in ["succeeded", "failed", "cancelled"],
       do: complete_without_turn(event, call, run, opts)

  defp dispatch_existing(_actor_key, event, %AgentCall{status: "running"}, _run, opts),
    do: defer(event, :task_running, opts)

  defp dispatch_existing(
         actor_key,
         %ActorEvent{type: "workflow.task.dispatch"} = event,
         %AgentCall{status: "queued"} = call,
         run,
         opts
       ),
       do: claim_task_turn(actor_key, event, call, run, opts)

  # A wake or message event reached the task before its dispatch claim. Keep
  # mailbox meaning by retrying after the dispatch has started the task.
  defp dispatch_existing(_actor_key, event, %AgentCall{status: "queued"}, _run, opts),
    do: defer(event, :task_not_started, opts)

  # Any ready event wakes a sleeping task: the deadline wakeup, an owner
  # message, or a lifecycle event from a Job the task created.
  defp dispatch_existing(actor_key, event, %AgentCall{status: "sleeping"} = call, run, opts),
    do: claim_task_turn(actor_key, event, call, run, opts)

  defp dispatch_existing(_actor_key, _event, %AgentCall{status: status}, _run, _opts),
    do: {:error, {:invalid_workflow_task_status, status}}

  defp claim_task_turn(actor_key, event, call, run, opts) do
    max_running_per_agent = WorkerConfig.max_running_per_agent()

    actor_key
    |> TurnLifecycle.start_worker_turn(
      event,
      turn_opts(event, call, run, max_running_per_agent, opts)
    )
    |> handle_start_result(event, call, run, opts)
  end

  defp turn_opts(event, call, run, max_running_per_agent, opts) do
    base_context = Keyword.get(opts, :request_context, %{})

    # Wake turns start from events whose payload is not the dispatch shape, so
    # the turn context always carries the durable task identity and contract.
    request_context =
      Map.merge(base_context, %{
        "run_id" => run.id,
        "call_id" => call.id,
        "prompt" => Map.fetch!(call.arguments, "prompt"),
        "label" => call.label,
        "schema" => Map.get(call.arguments, "schema", %{"type" => "string"})
      })

    opts
    |> Keyword.merge(
      kind: "workflow_task",
      conversation: :required,
      profile: call.model_profile || run.model_profile || "primary",
      request_context: request_context
    )
    |> Keyword.put(:admit_in_tx, fn repo, _turn_start_spec ->
      case Workflow.claim_task_for_dispatch_in_tx(
             repo,
             event,
             call.id,
             call.agent_uid,
             max_running_per_agent
           ) do
        {:ok, %{call: %AgentCall{attempts: attempts}}} ->
          {:ok, %{workflow_task_attempt: attempts}}

        {:error, _reason} = error ->
          error
      end
    end)
  end

  defp handle_start_result({:error, :no_worker_available}, event, _call, _run, opts),
    do: defer(event, :worker_capacity, opts)

  defp handle_start_result(
         {:error, :workflow_agent_at_capacity},
         event,
         _call,
         _run,
         opts
       ),
       do: defer(event, :agent_capacity, opts)

  defp handle_start_result(
         {:error, {:workflow_task_not_queued, "running"}},
         event,
         _call,
         _run,
         opts
       ),
       do: defer(event, :task_running, opts)

  defp handle_start_result(
         {:error, {:workflow_task_not_queued, status}},
         event,
         call,
         run,
         opts
       )
       when status in ["succeeded", "failed", "cancelled"],
       do: complete_without_turn(event, call, run, opts)

  defp handle_start_result(
         {:error, {:workflow_run_terminal, _status}},
         event,
         call,
         run,
         opts
       ),
       do: complete_without_turn(event, call, run, opts)

  defp handle_start_result(
         {:ok, %{status: :model_profile_unavailable, profile: profile} = result},
         event,
         call,
         _run,
         opts
       ) do
    now = now(opts)
    summary = "Workflow task model profile #{profile} is unavailable."

    with {:ok, %{call: failed_call, run: run}} <-
           Workflow.fail_unstarted_task(
             call.id,
             call.agent_uid,
             "workflow_model_profile_unavailable",
             summary,
             now
           ),
         {:ok, completed_event} <- Workflow.complete_task_event(event, now) do
      {:ok,
       result
       |> Map.put(:actor_event, completed_event)
       |> Map.put(:call, failed_call)
       |> Map.put(:run, run)}
    end
  end

  defp handle_start_result(
         {:ok, %{send_outcome: outcome} = result},
         event,
         call,
         _run,
         opts
       )
       when outcome != "sent_or_queued" do
    available_at = retry_at(opts)

    with {:ok, claimed_attempt} <- claimed_attempt(result) do
      case Workflow.requeue_unstarted_task(
             call.id,
             call.agent_uid,
             claimed_attempt,
             available_at
           ) do
        {:ok, %{run: %Run{status: "running"}}} ->
          defer_at(event, :worker_delivery, available_at)

        {:ok, %{call: current_call, run: %Run{} = terminal_run}} ->
          complete_without_turn(event, current_call, terminal_run, opts)

        {:error, _reason} = error ->
          error
      end
    end
  end

  defp handle_start_result(result, _event, _call, _run, _opts), do: result

  defp claimed_attempt(%{turn_start_spec: %{workflow_task_attempt: attempts}})
       when is_integer(attempts) and attempts > 0,
       do: {:ok, attempts}

  defp claimed_attempt(_result), do: {:error, :workflow_task_claimed_attempt_missing}

  defp complete_without_turn(event, call, run, opts) do
    with {:ok, event} <- Workflow.complete_task_event(event, now(opts)) do
      {:ok, %{status: :idle, actor_event: event, call: call, run: run}}
    end
  end

  defp defer(event, reason, opts), do: defer_at(event, reason, retry_at(opts))

  defp defer_at(event, reason, available_at) do
    with {:ok, event} <- Workflow.defer_task_event(event, available_at, reason) do
      {:ok, %{status: :waiting_for_worker, reason: reason, actor_event: event}}
    end
  end

  defp retry_at(opts), do: DateTime.add(now(opts), @retry_delay_seconds, :second)
  defp now(opts), do: Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
end
