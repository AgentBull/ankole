defmodule Ankole.Sessions.WorkflowTask do
  use Ankole.Sessions.RunType
  @moduledoc "Owns one Workflow task's admission and terminal result contract."
  alias Ankole.{Repo, Workflow}
  alias Ankole.Sessions.Prompt
  alias Ankole.Sessions.Run
  alias Ankole.Signals.Signal
  alias Ankole.Sessions.Queue

  def prepare_input(event, now) do
    case Repo.get(Signal, event.id) do
      %Signal{status: :completed} = current ->
        {:closed, %{status: :completed, signal: current}}

      %Signal{} = current ->
        prepare_current_input(current, now)

      nil ->
        {:error, :input_unavailable}
    end
  end

  defp prepare_current_input(event, now) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(event.session_id),
         {:ok, %{call: call, run: workflow}} <-
           Workflow.get_task_for_agent(call_id, event.agent_uid) do
      if call.status in Ankole.Workflow.Schemas.AgentCall.terminal_statuses() or
           workflow.status != :running do
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
                %Signal{} = current <- Ankole.Signals.lock_signal_in_tx(repo, event.id),
                {:ok, completed} <- Queue.mark_event_completed_in_tx(repo, current, now) do
             {:ok, %{status: :completed, signal: completed}}
           else
             {:ok, %{status: :completed} = result} -> {:ok, result}
             error -> error
           end
         end) do
      {:ok, value} -> {:closed, value}
      error -> error
    end
  end

  def finalize_input_in_tx(
        repo,
        %Signal{last_attempt_at: %DateTime{}} = event,
        %{kind: :workflow_task}
      ),
      do: Run.finalize_committed_workflow_input_in_tx(repo, event)

  def finalize_input_in_tx(_repo, _event, _plan), do: {:ok, :not_committed}

  def fail_exhausted_in_tx(repo, event, %{kind: :workflow_task, call_id: id}, reason) do
    failure =
      Map.merge(reason, %{
        "ok" => false,
        "summary" => "The task exhausted its input retry budget.",
        "retryable" => false
      })

    Workflow.TaskLifecycle.submit_result_in_tx(
      repo,
      id,
      event.agent_uid,
      event.session_id,
      failure
    )
  end

  def plan(event, opts) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(event.session_id) do
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
    end
  end

  def admit_in_tx(repo, event, %{kind: :workflow_task} = plan) do
    with {:ok, %{call: call, run: run}} <-
           Workflow.TaskLifecycle.claim_task_in_tx(
             repo,
             plan.call_id,
             event.agent_uid,
             Ankole.Workflow.WorkerConfig.max_running_per_agent(),
             adopt_running: true
           ),
         :ok <-
           Queue.lock_sessions_in_tx(repo, [
             {event.agent_uid, event.session_id},
             {event.agent_uid, run.owner_session_id}
           ]) do
      {:ok, Map.put(plan.context, "attempt", call.attempts)}
    end
  end

  def instructions(run), do: Prompt.workflow_system(run)

  def input(%{event: %{type: "workflow.task.dispatch"}} = run),
    do: [Run.user(run.spec.request_context["prompt"])]

  def input(run), do: super(run)
  def nudge?, do: false

  @repair "You did not end this Workflow task turn. Call submit_result with the final result, or call sleep when you wait for a delegated job or a later condition. Do not call another tool and do not return prose."
  def repair(run, text),
    do:
      {@repair,
       %{
         run
         | tools: Enum.filter(run.tools, & &1.ends_run),
           hosted_tools: [],
           repair_failure: failure_code(text)
       }}

  def finish(run) do
    code = run.repair_failure || failure_code(Run.text(run))

    {:workflow_failure, run,
     %{
       "ok" => false,
       "code" => code,
       "summary" => "The Workflow task ended without submit_result or sleep.",
       "retryable" => code == "empty_output"
     }}
  end

  def failure(reason) do
    error =
      if is_map(reason),
        do: reason,
        else: %{"code" => "workflow_task_turn_failed", "message" => inspect(reason)}

    {:workflow_failure, error}
  end

  defp failure_code(text),
    do: if(String.trim(text) == "", do: "empty_output", else: "schema_noncompliance")

  def tools(_run, tools, hosted) do
    hosted =
      Enum.flat_map(hosted, fn
        %{"type" => "brain"} -> [%{"type" => "brain", "operations" => ~w(recall get_page)}]
        %{"type" => "web_search"} = tool -> [tool]
        _ -> []
      end)

    {tools, hosted}
  end

  def lock_progress_in_tx(repo, run) do
    with {:ok, call_id} <- Workflow.parse_task_session_id(run.session_id),
         do:
           Workflow.TaskLifecycle.lock_task_progress_in_tx(
             repo,
             call_id,
             run.agent_uid,
             run.session_id,
             run.spec.request_context["attempt"]
           )
  end

  def restore_attempt(run, latest, state) do
    if latest && state.workflow_attempt != run.spec.request_context["attempt"] do
      %{
        run
        | model_response: nil,
          calls: [],
          round_calls: [],
          results: %{},
          iteration: 0,
          repaired: false,
          repair_failure: nil,
          nudged: false,
          truncated_rounds: 0,
          saw_tool_results: false
      }
    else
      run
    end
  end
end
