defmodule Ankole.ActorRuntime.SubagentDispatch do
  @moduledoc false

  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.RuntimeCommand
  alias Ankole.ActorRuntime.SubagentTurn
  alias Ankole.ActorRuntime.TurnLifecycle
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @retry_delay_seconds 30

  def process(actor_key, %ActorEvent{} = event, opts) do
    with {:ok, delegation_id} <- delegation_id(event) do
      case SubagentDelegations.prepare_attempt(delegation_id, actor_key.agent_uid) do
        {:ok, {:terminal, %Delegation{} = delegation}} ->
          complete_without_turn(event, delegation)

        {:ok, :at_capacity} ->
          defer(event, :agent_capacity, opts)

        {:ok, {:ready, %Delegation{} = delegation}} ->
          start_turn(actor_key, event, delegation, opts)

        {:error, :subagent_delegation_attempts_exhausted} ->
          fail_exhausted(event, delegation_id, actor_key.agent_uid)

        {:error, _reason} = error ->
          error
      end
    end
  end

  def process_steer(actor_key, %ActorEvent{} = event, opts) do
    with {:ok, delegation_id} <- delegation_id(event),
         %Delegation{} = delegation <-
           SubagentDelegations.get_delegation_for_agent(delegation_id, actor_key.agent_uid) do
      case TurnLifecycle.live_delivery_for_session?(Ankole.Repo, actor_key) do
        true ->
          RuntimeCommand.process_steer_command(
            actor_key,
            event,
            SubagentTurn.opts(event, delegation, opts)
          )

        false ->
          process_inactive_steer(actor_key, event, delegation, opts)
      end
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp process_inactive_steer(actor_key, event, delegation, opts) do
    case SubagentDelegations.prepare_attempt(delegation.id, actor_key.agent_uid) do
      {:ok, {:terminal, %Delegation{} = terminal}} ->
        complete_without_turn(event, terminal)

      {:ok, :at_capacity} ->
        defer(event, :agent_capacity, opts)

      {:ok, {:ready, %Delegation{} = ready}} ->
        with :ok <- SubagentDelegations.complete_open_dispatch(ready.id, ready.agent_uid) do
          RuntimeCommand.process_steer_command(
            actor_key,
            event,
            SubagentTurn.opts(event, ready, opts)
          )
          |> maybe_defer_no_worker(event, opts)
        end

      {:error, :subagent_delegation_attempts_exhausted} ->
        fail_exhausted(event, delegation.id, actor_key.agent_uid)

      {:error, _reason} = error ->
        error
    end
  end

  defp start_turn(actor_key, event, delegation, opts) do
    actor_key
    |> TurnLifecycle.start_worker_turn(event, SubagentTurn.opts(event, delegation, opts))
    |> maybe_defer_no_worker(event, opts)
  end

  defp maybe_defer_no_worker({:error, :no_worker_available}, event, opts),
    do: defer(event, :worker_capacity, opts)

  defp maybe_defer_no_worker(result, _event, _opts), do: result

  defp defer(event, reason, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    available_at = DateTime.add(now, @retry_delay_seconds, :second)

    with {:ok, event} <- SubagentDelegations.defer_actor_event(event, available_at) do
      {:ok, %{status: :waiting_for_worker, reason: reason, actor_event: event}}
    end
  end

  defp fail_exhausted(event, delegation_id, agent_uid) do
    with {:ok, %{delegation: delegation}} <-
           SubagentDelegations.commit_status_with_wakeup(delegation_id, agent_uid, %{
             "status" => "failed",
             "error" => %{
               "code" => "attempts_exhausted",
               "summary" => "Delegation could not be resumed after three execution attempts."
             }
           }),
         {:ok, event} <- SubagentDelegations.complete_actor_event(event) do
      {:ok, %{status: :attempts_exhausted, delegation: delegation, actor_event: event}}
    end
  end

  defp complete_without_turn(event, delegation) do
    with {:ok, event} <- SubagentDelegations.complete_actor_event(event) do
      {:ok, %{status: :idle, delegation: delegation, actor_event: event}}
    end
  end

  defp delegation_id(%ActorEvent{session_id: "subagent:" <> delegation_id})
       when delegation_id != "",
       do: {:ok, delegation_id}

  defp delegation_id(%ActorEvent{}), do: {:error, :invalid_subagent_session}
end
