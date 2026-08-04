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
  alias Ankole.Repo

  require Ankole.BackgroundAgentJobs

  @type actor_key :: %{agent_uid: String.t(), session_id: String.t()}

  @doc """
  Processes the next ready event for one actor session.
  """
  def process_ready_event_for_actor(actor_key, opts \\ []) do
    actor_key = normalize_actor_key(actor_key)
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    live_delivery? = TurnLifecycle.live_delivery_for_session?(Repo, actor_key)

    case Actors.next_ready_event(actor_key.agent_uid, actor_key.session_id, now,
           live_delivery?: live_delivery?
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

      %ActorEvent{type: "brain.source.learn"} = event ->
        TurnLifecycle.start_worker_turn(
          actor_key,
          event,
          Keyword.update(
            opts,
            :request_context,
            %{"tool_profile" => "brain_source_learning"},
            &Map.put(&1, "tool_profile", "brain_source_learning")
          )
        )

      %ActorEvent{} = event ->
        TurnLifecycle.start_worker_turn(actor_key, event, opts)
    end
  end
end
