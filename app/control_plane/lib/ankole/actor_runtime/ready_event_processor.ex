defmodule Ankole.ActorRuntime.ReadyEventProcessor do
  @moduledoc false

  import Ankole.ActorRuntime.Common

  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.EntryLifecycle
  alias Ankole.ActorRuntime.RuntimeCommand
  alias Ankole.ActorRuntime.ScheduledTurn
  alias Ankole.ActorRuntime.SessionReset
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.Repo

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

      %ActorEvent{type: type} = event
      when type in ["command.stop", "command.retry", "command.compress"] ->
        RuntimeCommand.process_runtime_command(actor_key, event, opts)

      %ActorEvent{type: "command.steer"} = event ->
        RuntimeCommand.process_steer_command(actor_key, event, opts)

      %ActorEvent{type: type} = event
      when type in ["check_back_later.wakeup", "cron.fire"] ->
        TurnLifecycle.start_worker_turn(actor_key, event, ScheduledTurn.opts(event, opts))

      %ActorEvent{type: "im.message.may_intervene"} = event ->
        TurnLifecycle.start_worker_turn(
          actor_key,
          event,
          Keyword.put_new(opts, :profile, "light")
        )

      %ActorEvent{} = event ->
        TurnLifecycle.start_worker_turn(actor_key, event, opts)
    end
  end
end
