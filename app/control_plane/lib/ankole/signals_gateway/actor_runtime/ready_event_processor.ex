defmodule Ankole.SignalsGateway.ActorRuntime.ReadyEventProcessor do
  @moduledoc false

  import Ankole.SignalsGateway.ActorRuntime.Common

  alias Ankole.SignalsGateway.Actors
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.AmbientIntervention
  alias Ankole.SignalsGateway.ActorRuntime.EntryLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.RuntimeCommand
  alias Ankole.SignalsGateway.ActorRuntime.ScheduledTurn
  alias Ankole.SignalsGateway.ActorRuntime.SessionReset
  alias Ankole.BackgroundAgentJobs
  alias Ankole.SignalsGateway.ActorRuntime.BackgroundAgentJobDispatch
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SignalsGateway.ActorRuntime.WorkflowTaskDispatch
  alias Ankole.Repo
  alias Ankole.Workflow

  require Ankole.BackgroundAgentJobs
  require Ankole.Workflow

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Processes the next ready event for one actor session.
  """
  def process_ready_event_for_actor(actor_key, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    live_delivery? = TurnLifecycle.live_delivery_for_session?(Repo, actor_key)

    result =
      case Actors.next_ready_event(actor_key.agent_uid, actor_key.session_id, now,
             live_delivery?: live_delivery?,
             strict_queue_order?: BackgroundAgentJobs.is_job_session_id(actor_key.session_id)
           ) do
        nil ->
          {:ok, %{status: :idle}}

        %ActorEvent{type: "command.new"} = event ->
          RuntimeCommand.process_new_command(actor_key, event, opts)

        %ActorEvent{type: "session.reset_due"} = event ->
          SessionReset.process_due(actor_key, event, opts)

        %ActorEvent{type: "signal.entry.removed"} = event ->
          EntryLifecycle.process(event, opts)

        %ActorEvent{type: "background_agent_job.dispatch"} = event ->
          BackgroundAgentJobDispatch.process(actor_key, event, opts)

        %ActorEvent{type: "command.steer", session_id: session_id} = event
        when BackgroundAgentJobs.is_job_session_id(session_id) ->
          BackgroundAgentJobDispatch.process_steer(actor_key, event, opts)

        %ActorEvent{type: "command.stop", session_id: session_id} = event
        when BackgroundAgentJobs.is_job_session_id(session_id) ->
          RuntimeCommand.process_background_agent_job_stop(actor_key, event, opts)

        %ActorEvent{type: type} = event
        when type in ["command.stop", "command.retry", "command.compress"] ->
          RuntimeCommand.process_runtime_command(actor_key, event, opts)

        %ActorEvent{type: "command.steer"} = event ->
          RuntimeCommand.process_steer_command(actor_key, event, opts)

        %ActorEvent{type: "command.llm_help"} = event ->
          RuntimeCommand.process_llm_help_command(event, opts)

        %ActorEvent{type: "command.llm"} = event ->
          RuntimeCommand.process_llm_command(actor_key, event, opts)

        %ActorEvent{type: type} = event
        when type in ["check_back_later.wakeup", "cron.fire"] ->
          TurnLifecycle.start_worker_turn(actor_key, event, ScheduledTurn.opts(event, opts))

        %ActorEvent{type: "im.message.may_intervene"} = event ->
          AmbientIntervention.process(actor_key, event, opts)

        # Runtime commands above keep their generic handling; every other event
        # for a Workflow task session is a dispatch or a wake and must claim
        # the durable call before a turn can start.
        %ActorEvent{session_id: session_id} = event
        when Workflow.is_workflow_task_session_id(session_id) ->
          WorkflowTaskDispatch.process(actor_key, event, opts)

        %ActorEvent{} = event ->
          TurnLifecycle.start_worker_turn(actor_key, event, opts)
      end

    drain_steers_after_turn_start(result, actor_key, opts)
  end

  # BackgroundAgentJobDispatch already replays pending Job steers with the
  # frozen Job runtime projection. Keep this generic post-start drain scoped to
  # ordinary Actor sessions so it cannot replay a Job steer with normal-turn
  # options after a partial Job-specific replay.
  defp drain_steers_after_turn_start(
         result,
         %{session_id: session_id},
         _opts
       )
       when BackgroundAgentJobs.is_job_session_id(session_id),
       do: result

  defp drain_steers_after_turn_start({:ok, %{envelope: _envelope} = result}, actor_key, opts) do
    case RuntimeCommand.drain_pending_steers(actor_key, opts) do
      :ok -> {:ok, result}
      {:error, _reason} = error -> error
    end
  end

  defp drain_steers_after_turn_start(result, _actor_key, _opts), do: result
end
