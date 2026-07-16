defmodule Ankole.SignalsGateway.ActorRuntime.SubagentDispatch do
  @moduledoc false

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.RuntimeCommand
  alias Ankole.SignalsGateway.ActorRuntime.SubagentTurn
  alias Ankole.SignalsGateway.ActorRuntime.TurnLifecycle
  alias Ankole.SubagentDelegations
  alias Ankole.SubagentDelegations.Schemas.Delegation

  @retry_delay_seconds 30

  def process(actor_key, %ActorEvent{} = event, opts) do
    with {:ok, delegation_id} <- delegation_id(event),
         %Delegation{} = delegation <-
           SubagentDelegations.get_delegation_for_agent(delegation_id, actor_key.agent_uid) do
      dispatch_existing(actor_key, event, delegation, opts)
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
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
    cond do
      delegation.status == "stopped" ->
        complete_without_turn(event, delegation)

      true ->
        with :ok <-
               SubagentDelegations.complete_open_dispatch(delegation.id, delegation.agent_uid) do
          RuntimeCommand.process_steer_command(
            actor_key,
            event,
            continuation_opts(event, delegation, opts)
          )
          |> handle_start_result(event, delegation, opts)
        end
    end
  end

  defp dispatch_existing(actor_key, event, delegation, opts) do
    cond do
      delegation.status in Delegation.terminal_statuses() ->
        complete_without_turn(event, delegation)

      delegation.attempts >= 3 ->
        fail_exhausted(event, delegation.id, delegation.agent_uid)

      true ->
        start_turn(actor_key, event, delegation, opts)
    end
  end

  defp start_turn(actor_key, event, delegation, opts) do
    result =
      actor_key
      |> TurnLifecycle.start_worker_turn(event, attempt_opts(event, delegation, opts))
      |> handle_start_result(event, delegation, opts)

    replay_pending_steers(result, actor_key, event, delegation, opts)
  end

  defp attempt_opts(event, %Delegation{} = delegation, opts) do
    expected_attempt = delegation.attempts + 1
    claimed = %{delegation | attempts: expected_attempt}

    event
    |> SubagentTurn.opts(claimed, opts)
    |> Keyword.put(:admit_in_tx, fn repo ->
      case SubagentDelegations.claim_attempt_in_tx(
             repo,
             delegation.id,
             delegation.agent_uid,
             expected_attempt
           ) do
        {:ok, %Delegation{}} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp continuation_opts(event, %Delegation{} = delegation, opts) do
    expected_attempt = delegation.attempts + 1
    claimed = %{delegation | attempts: expected_attempt}

    event
    |> SubagentTurn.opts(claimed, opts)
    |> Keyword.put(:admit_in_tx, fn repo ->
      case SubagentDelegations.claim_continuation_in_tx(
             repo,
             delegation.id,
             delegation.agent_uid,
             expected_attempt
           ) do
        {:ok, %Delegation{}} -> :ok
        {:error, _reason} = error -> error
      end
    end)
  end

  defp replay_pending_steers(
         {:ok, %{send_outcome: "sent_or_queued"} = result},
         actor_key,
         event,
         delegation,
         opts
       ) do
    outcome =
      with {:ok, pending_events} <-
             SubagentDelegations.pending_steer_events(
               delegation.id,
               delegation.agent_uid,
               event.id
             ) do
        replay_steers(actor_key, pending_events, delegation, opts)
      end

    case outcome do
      {:ok, replayed} -> {:ok, Map.put(result, :replayed_steers, replayed)}
      {:error, reason} -> {:ok, Map.put(result, :steer_replay_error, reason)}
    end
  end

  defp replay_pending_steers(result, _actor_key, _event, _delegation, _opts), do: result

  defp replay_steers(actor_key, events, delegation, opts) do
    Enum.reduce_while(events, {:ok, 0}, fn event, {:ok, count} ->
      case RuntimeCommand.process_steer_command(
             actor_key,
             event,
             SubagentTurn.opts(event, delegation, opts)
           ) do
        {:ok, _result} -> {:cont, {:ok, count + 1}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
  end

  defp handle_start_result({:error, :no_worker_available}, event, _delegation, opts),
    do: defer(event, :worker_capacity, opts)

  defp handle_start_result({:error, :subagent_agent_at_capacity}, event, _delegation, opts),
    do: defer(event, :agent_capacity, opts)

  defp handle_start_result(
         {:error, :subagent_codex_account_at_capacity},
         event,
         _delegation,
         opts
       ),
       do: defer(event, :codex_account_capacity, opts)

  defp handle_start_result(
         {:ok, %{send_outcome: outcome}},
         event,
         delegation,
         opts
       )
       when outcome != "sent_or_queued" do
    expected_attempt = delegation.attempts + 1

    with {:ok, _delegation} <-
           SubagentDelegations.requeue_unstarted_attempt(
             delegation.id,
             delegation.agent_uid,
             expected_attempt
           ) do
      defer(event, :worker_delivery, opts)
    end
  end

  defp handle_start_result(
         {:error, {:subagent_delegation_terminal, %Delegation{} = delegation}},
         event,
         _stale_delegation,
         _opts
       ),
       do: complete_without_turn(event, delegation)

  defp handle_start_result(
         {:error, :subagent_delegation_attempts_exhausted},
         event,
         delegation,
         _opts
       ),
       do: fail_exhausted(event, delegation.id, delegation.agent_uid)

  defp handle_start_result(result, _event, _delegation, _opts), do: result

  defp defer(event, reason, opts) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    available_at = DateTime.add(now, @retry_delay_seconds, :second)

    with {:ok, event} <- SubagentDelegations.defer_actor_event(event, available_at) do
      {:ok, %{status: :waiting_for_worker, reason: reason, actor_event: event}}
    end
  end

  defp fail_exhausted(event, delegation_id, agent_uid) do
    with {:ok, %{delegation: delegation}} <-
           SubagentDelegations.commit_status_with_wakeup(
             delegation_id,
             agent_uid,
             %{
               "status" => "failed",
               "error" => %{
                 "code" => "attempts_exhausted",
                 "summary" => "Delegation could not be resumed after three execution attempts."
               }
             },
             turn_interruption: %{
               "code" => "attempts_exhausted",
               "summary" =>
                 "The control plane interrupted this runtime Turn after execution attempts were exhausted."
             }
           ),
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
