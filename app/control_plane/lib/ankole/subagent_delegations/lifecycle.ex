defmodule Ankole.SubagentDelegations.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.AIAgent.CodexAccounts.Account
  alias Ankole.SignalsGateway
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.ActorSessionWorkerAssignment
  alias Ankole.SignalsGateway.ActorRuntime.Schemas.AgentComputerWorker
  alias Ankole.SignalsGateway.ActorRuntime.TurnRef
  alias Ankole.SignalsGateway.ActorRuntime.WorkerRouteAuth
  alias Ankole.SignalsGateway.ActorRuntime.WorkerPool
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SubagentDelegations.Attrs
  alias Ankole.SubagentDelegations.Queries
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Text
  alias Ankole.SubagentDelegations.Turns

  @max_running_per_agent 3
  @max_event_payload_bytes 16_384
  @truncation_suffix "...[truncated]"
  @terminal_statuses Delegation.terminal_statuses()
  @running_statuses Delegation.running_statuses()

  @doc false
  @spec claim_attempt_in_tx(module(), String.t(), String.t(), pos_integer()) ::
          {:ok, Delegation.t()} | {:error, term()}
  def claim_attempt_in_tx(repo, delegation_id, agent_uid, expected_attempt)
      when is_binary(delegation_id) and is_binary(agent_uid) and expected_attempt > 0 do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Delegation{} = delegation <-
           Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE"),
         :ok <- claim_codex_account_slot(repo, delegation) do
      claim_attempt(repo, delegation, expected_attempt)
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec claim_continuation_in_tx(module(), String.t(), String.t(), pos_integer()) ::
          {:ok, Delegation.t()} | {:error, term()}
  def claim_continuation_in_tx(repo, delegation_id, agent_uid, expected_attempt)
      when is_binary(delegation_id) and is_binary(agent_uid) and expected_attempt > 0 do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Delegation{} = delegation <-
           Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE"),
         :ok <- claim_codex_account_slot(repo, delegation) do
      claim_continuation(repo, delegation, expected_attempt)
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  @doc false
  @spec requeue_unstarted_attempt(String.t(), String.t(), pos_integer()) ::
          {:ok, Delegation.t()} | {:error, term()}
  def requeue_unstarted_attempt(delegation_id, agent_uid, expected_attempt)
      when is_binary(delegation_id) and is_binary(agent_uid) and expected_attempt > 0 do
    Repo.transact(fn repo ->
      with :ok <- lock_agent_slots(repo, agent_uid),
           %Delegation{status: "running", attempts: ^expected_attempt} = delegation <-
             Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE") do
        delegation
        |> Delegation.changeset(%{
          status: "queued",
          attempts: expected_attempt - 1,
          started_at: if(expected_attempt == 1, do: nil, else: delegation.started_at)
        })
        |> repo.update()
      else
        nil -> {:error, :delegation_not_found}
        %Delegation{} -> {:error, :subagent_delegation_attempt_changed}
        {:error, _reason} = error -> error
      end
    end)
  end

  @spec commit_status_with_wakeup(String.t(), String.t(), map(), keyword()) ::
          {:ok, %{delegation: Delegation.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup(delegation_id, agent_uid, attrs, opts \\ [])
      when is_binary(delegation_id) and is_binary(agent_uid) and is_map(attrs) and
             is_list(opts) do
    result =
      with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
        now = now()

        Repo.transact(fn repo ->
          turn_ref = Keyword.get(opts, :turn_ref)

          commit_status_with_wakeup_in_tx(
            repo,
            delegation_id,
            agent_uid,
            attrs,
            now,
            turn_ref,
            Keyword.get(opts, :worker_route),
            Keyword.get(opts, :turn_interruption)
          )
        end)
      end

    result
  end

  @doc false
  @spec commit_status_with_wakeup_in_tx(
          module(),
          String.t(),
          String.t(),
          map(),
          DateTime.t(),
          Ankole.SignalsGateway.ActorRuntime.TurnRef.t() | nil,
          String.t() | nil,
          map() | nil
        ) ::
          {:ok, %{delegation: Delegation.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup_in_tx(
        repo,
        delegation_id,
        agent_uid,
        attrs,
        %DateTime{} = now,
        turn_ref \\ nil,
        worker_route \\ nil,
        turn_interruption \\ nil
      ) do
    # Every transition locks any live worker/assignment prefix before taking the
    # agent/delegation locks. Worker writes additionally validate activation and
    # revision through their turn fence.
    with :ok <- lock_runtime_prefix_in_tx(repo, delegation_id, agent_uid, turn_ref, worker_route),
         {:ok, result} <-
           commit_status_after_runtime_prefix_in_tx(
             repo,
             delegation_id,
             agent_uid,
             attrs,
             now,
             turn_ref,
             turn_interruption
           ) do
      {:ok, result}
    end
  end

  @doc false
  @spec commit_status_after_runtime_prefix_in_tx(
          module(),
          String.t(),
          String.t(),
          map(),
          DateTime.t(),
          Ankole.SignalsGateway.ActorRuntime.TurnRef.t() | nil,
          map() | nil
        ) ::
          {:ok, %{delegation: Delegation.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_after_runtime_prefix_in_tx(
        repo,
        delegation_id,
        agent_uid,
        attrs,
        %DateTime{} = now,
        turn_ref,
        turn_interruption \\ nil
      ) do
    with :ok <- lock_agent_slots(repo, agent_uid),
         %Delegation{} = delegation <-
           Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE"),
         attrs <- Attrs.normalize(attrs),
         :ok <- enforce_status_transition(delegation, attrs),
         :ok <- enforce_running_limit(repo, delegation, attrs),
         :ok <- enforce_no_unapplied_terminal_steer(repo, delegation, attrs, turn_ref),
         :ok <- maybe_interrupt_active_turns(repo, delegation, turn_interruption, now),
         :ok <- enforce_turn_trajectory_completion(repo, delegation, attrs),
         {:ok, delegation} <-
           delegation
           |> Delegation.changeset(
             attrs
             |> preserve_metadata(delegation)
             |> lifecycle_timestamps(delegation, now)
           )
           |> repo.update(),
         :ok <- maybe_release_worker_assignment(repo, delegation, turn_ref),
         {:ok, wakeup_event} <- append_wakeup_event(repo, delegation, now),
         :ok <- maybe_nudge_queued_after_status_commit(repo, delegation, now, turn_ref) do
      {:ok, %{delegation: delegation, wakeup_event: wakeup_event}}
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp enforce_no_unapplied_terminal_steer(
         repo,
         %Delegation{} = delegation,
         %{"status" => status},
         %Ankole.SignalsGateway.ActorRuntime.TurnRef{} = turn_ref
       )
       when status in ["succeeded", "failed"] do
    unapplied? =
      ActorEvent
      |> where([event], event.agent_uid == ^delegation.agent_uid)
      |> where([event], event.session_id == ^"subagent:#{delegation.id}")
      |> where([event], event.type == "command.steer")
      |> where([event], event.input_state == "open")
      |> where([event], is_nil(event.completed_at))
      |> join(
        :left,
        [event],
        delivery in Ankole.SignalsGateway.ActorRuntime.Schemas.ActorEventDelivery,
        on:
          delivery.actor_event_id == event.id and delivery.state == "accepted" and
            delivery.activation_uid == ^turn_ref.activation_uid and
            delivery.actor_epoch == ^turn_ref.actor_epoch and
            delivery.actor_event_id_fence == ^turn_ref.actor_event_id
      )
      |> where([_event, delivery], is_nil(delivery.id))
      |> repo.exists?()

    if unapplied?, do: {:error, :subagent_pending_steer}, else: :ok
  end

  defp enforce_no_unapplied_terminal_steer(_repo, %Delegation{}, _attrs, _turn_ref),
    do: :ok

  defp enforce_turn_trajectory_completion(
         repo,
         %Delegation{} = delegation,
         %{"status" => status}
       )
       when status in ["waiting_on_user", "succeeded"],
       do:
         Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, delegation,
           require_turn: true,
           latest_status: if(status == "waiting_on_user", do: "interrupted", else: "completed"),
           latest_error_code: if(status == "waiting_on_user", do: "request_user_input"),
           require_pending_tool_call: if(status == "waiting_on_user", do: "request_user_input")
         )

  defp enforce_turn_trajectory_completion(
         repo,
         %Delegation{attempts: attempts} = delegation,
         %{"status" => status}
       )
       when attempts > 0 and status in ["failed", "stopped"],
       do: Turns.ensure_lead_closed_for_current_attempt_in_tx(repo, delegation)

  defp enforce_turn_trajectory_completion(_repo, %Delegation{}, _attrs), do: :ok

  defp maybe_interrupt_active_turns(
         repo,
         %Delegation{} = delegation,
         %{"code" => code, "summary" => summary} = error,
         %DateTime{} = now
       )
       when is_binary(code) and is_binary(summary) do
    Turns.interrupt_active_for_current_attempt_in_tx(repo, delegation, error, now)
  end

  defp maybe_interrupt_active_turns(_repo, %Delegation{}, nil, %DateTime{}), do: :ok

  defp lock_runtime_prefix_in_tx(
         repo,
         _delegation_id,
         _agent_uid,
         %TurnRef{} = turn_ref,
         route
       )
       when is_binary(route) do
    case WorkerRouteAuth.authorize_turn_route_in_tx(repo, turn_ref, route, :write, lock: true) do
      {:ok, :authorized} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp lock_runtime_prefix_in_tx(repo, delegation_id, agent_uid, _turn_ref, _route) do
    actor_key = %{agent_uid: agent_uid, session_id: "subagent:#{delegation_id}"}

    with :ok <- WorkerPool.lock_actor_assignment_in_tx(repo, actor_key) do
      case live_assignment_snapshot(repo, actor_key) do
        %ActorSessionWorkerAssignment{} = assignment ->
          _worker = lock_assignment_worker(repo, assignment.worker_id)
          _assignment = lock_live_assignment(repo, assignment, actor_key)
          :ok

        nil ->
          :ok
      end
    end
  end

  defp live_assignment_snapshot(repo, actor_key) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^actor_key.agent_uid)
    |> where([assignment], assignment.session_id == ^actor_key.session_id)
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.one()
  end

  defp lock_assignment_worker(repo, worker_id) do
    AgentComputerWorker
    |> where([worker], worker.worker_id == ^worker_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_live_assignment(repo, assignment, actor_key) do
    ActorSessionWorkerAssignment
    |> where([stored], stored.id == ^assignment.id)
    |> where([stored], stored.agent_uid == ^actor_key.agent_uid)
    |> where([stored], stored.session_id == ^actor_key.session_id)
    |> where([stored], stored.worker_id == ^assignment.worker_id)
    |> where([stored], stored.status in ["assigned", "draining"])
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  @doc false
  @spec nudge_queued_after_slot_release(module(), Delegation.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def nudge_queued_after_slot_release(repo, %Delegation{status: status} = delegation, now)
      when status in @terminal_statuses or status == "waiting_on_user" do
    Delegation
    |> where(
      [row],
      row.agent_uid == ^delegation.agent_uid or
        (^delegation.codex_account_id != "aigateway" and
           row.codex_account_id == ^delegation.codex_account_id)
    )
    |> where([row], row.status == "queued")
    |> select([row], {row.id, row.agent_uid})
    |> repo.all()
    |> Enum.reduce_while(:ok, fn {delegation_id, agent_uid}, :ok ->
      case RuntimeEvents.notify_actor_session_ready(
             repo,
             agent_uid,
             "subagent:#{delegation_id}",
             now
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def nudge_queued_after_slot_release(_repo, %Delegation{}, _now), do: :ok

  @doc false
  @spec finalize_worker_turn_in_tx(module(), TurnRef.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def finalize_worker_turn_in_tx(
        repo,
        %TurnRef{agent_uid: agent_uid, session_id: "subagent:" <> delegation_id},
        %DateTime{} = now
      ) do
    case Queries.get_for_agent(repo, delegation_id, agent_uid, []) do
      %Delegation{status: status} = delegation
      when status in @terminal_statuses or status == "waiting_on_user" ->
        with :ok <- release_worker_assignment(repo, delegation),
             :ok <- nudge_queued_after_slot_release(repo, delegation, now) do
          :ok
        end

      %Delegation{} ->
        :ok

      nil ->
        WorkerPool.release_assignment_for_actor_in_tx(repo, %{
          agent_uid: agent_uid,
          session_id: "subagent:#{delegation_id}"
        })
    end
  end

  def finalize_worker_turn_in_tx(_repo, %TurnRef{}, %DateTime{}), do: :ok

  defp maybe_nudge_queued_after_status_commit(_repo, %Delegation{}, _now, %TurnRef{}),
    do: :ok

  defp maybe_nudge_queued_after_status_commit(repo, %Delegation{} = delegation, now, nil),
    do: nudge_queued_after_slot_release(repo, delegation, now)

  defp maybe_release_worker_assignment(_repo, %Delegation{}, %TurnRef{}), do: :ok

  defp maybe_release_worker_assignment(repo, %Delegation{status: "stopped"} = delegation, nil) do
    case live_worker_assignment?(repo, delegation) do
      true -> :ok
      false -> release_worker_assignment(repo, delegation)
    end
  end

  defp maybe_release_worker_assignment(repo, %Delegation{status: status} = delegation, _turn_ref)
       when status in @terminal_statuses or status == "waiting_on_user" do
    release_worker_assignment(repo, delegation)
  end

  defp maybe_release_worker_assignment(_repo, %Delegation{}, _turn_ref), do: :ok

  defp release_worker_assignment(repo, delegation) do
    WorkerPool.release_assignment_for_actor_in_tx(repo, %{
      agent_uid: delegation.agent_uid,
      session_id: "subagent:#{delegation.id}"
    })
  end

  defp live_worker_assignment?(repo, delegation) do
    ActorSessionWorkerAssignment
    |> where([assignment], assignment.agent_uid == ^delegation.agent_uid)
    |> where([assignment], assignment.session_id == ^"subagent:#{delegation.id}")
    |> where([assignment], assignment.status in ["assigned", "draining"])
    |> repo.exists?()
  end

  defp claim_attempt(_repo, %Delegation{status: status} = delegation, _expected_attempt)
       when status in @terminal_statuses,
       do: {:error, {:subagent_delegation_terminal, delegation}}

  defp claim_attempt(_repo, %Delegation{attempts: attempts}, _expected_attempt)
       when attempts >= 3,
       do: {:error, :subagent_delegation_attempts_exhausted}

  defp claim_attempt(_repo, %Delegation{attempts: attempts}, expected_attempt)
       when attempts + 1 != expected_attempt,
       do: {:error, :subagent_delegation_attempt_changed}

  defp claim_attempt(repo, %Delegation{} = delegation, expected_attempt) do
    start_attempt(repo, delegation, expected_attempt)
  end

  defp claim_continuation(_repo, %Delegation{status: "stopped"} = delegation, _expected_attempt),
    do: {:error, {:subagent_delegation_terminal, delegation}}

  defp claim_continuation(_repo, %Delegation{attempts: attempts}, expected_attempt)
       when attempts + 1 != expected_attempt,
       do: {:error, :subagent_delegation_attempt_changed}

  defp claim_continuation(repo, %Delegation{} = delegation, expected_attempt) do
    start_attempt(repo, delegation, expected_attempt)
  end

  defp start_attempt(repo, %Delegation{} = delegation, expected_attempt) do
    if delegation.status not in @running_statuses and
         running_count(repo, delegation.agent_uid, delegation.id) >= @max_running_per_agent do
      {:error, :subagent_agent_at_capacity}
    else
      now = now()

      with :ok <- Turns.interrupt_before_attempt_in_tx(repo, delegation, expected_attempt, now) do
        delegation
        |> Delegation.changeset(%{
          status: "running",
          attempts: expected_attempt,
          started_at: delegation.started_at || now,
          completed_at: nil
        })
        |> repo.update()
      end
    end
  end

  defp claim_codex_account_slot(_repo, %Delegation{codex_account_id: "aigateway"}), do: :ok

  defp claim_codex_account_slot(repo, %Delegation{codex_account_id: account_id, id: id}) do
    account =
      Account
      |> where([row], row.account_id == ^account_id)
      |> lock("FOR UPDATE")
      |> repo.one()

    cond do
      is_nil(account) ->
        {:error, :codex_account_not_found}

      subscription_account_running?(repo, account_id, id) ->
        {:error, :subagent_codex_account_at_capacity}

      true ->
        :ok
    end
  end

  defp subscription_account_running?(repo, account_id, delegation_id) do
    Delegation
    |> join(:inner, [row], assignment in ActorSessionWorkerAssignment,
      on:
        assignment.agent_uid == row.agent_uid and
          assignment.session_id == fragment("'subagent:' || ?", row.id) and
          assignment.status in ["assigned", "draining"]
    )
    |> where([row, _assignment], row.codex_account_id == ^account_id)
    |> where([row, _assignment], row.id != ^delegation_id)
    |> repo.exists?()
  end

  defp append_wakeup_event(repo, %Delegation{} = delegation, now) do
    case wakeup_event_type(delegation.status) do
      nil ->
        {:ok, nil}

      event_type ->
        source_event_id = wakeup_source_event_id(delegation)
        reply_route = delegation.reply_route || %{}

        with binding_name when is_binary(binding_name) <- Attrs.text(reply_route, "binding_name") do
          SignalsGateway.append_actor_event_in_tx(repo, %{
            agent_uid: delegation.agent_uid,
            binding_name: binding_name,
            session_id: delegation.session_id,
            source_event_id: source_event_id,
            signal_channel_id: Map.get(reply_route, "signal_channel_id"),
            provider_thread_id: Map.get(reply_route, "provider_thread_id"),
            source_entry_id: Map.get(reply_route, "source_entry_id"),
            type: event_type,
            available_at: now,
            payload: wakeup_payload(delegation, source_event_id, event_type, now)
          })
        else
          nil -> {:error, :subagent_reply_route_binding_missing}
        end
    end
  end

  defp wakeup_event_type("succeeded"), do: "subagent.delegation.completed"
  defp wakeup_event_type("failed"), do: "subagent.delegation.failed"
  defp wakeup_event_type("waiting_on_user"), do: "subagent.delegation.waiting"
  defp wakeup_event_type(_status), do: nil

  defp wakeup_source_event_id(%Delegation{status: "waiting_on_user"} = delegation) do
    "subagent_delegation:#{delegation.id}:waiting:#{delegation.attempts}"
  end

  defp wakeup_source_event_id(%Delegation{} = delegation) do
    "subagent_delegation:#{delegation.id}:#{delegation.status}:#{delegation.attempts}"
  end

  defp wakeup_payload(delegation, source_event_id, event_type, now) do
    %{
      "specversion" => "1.0",
      "id" => source_event_id,
      "source" => "control-plane://subagent/delegation",
      "subject" => "subagent-delegation:#{delegation.id}",
      "time" => DateTime.to_iso8601(now),
      "type" => event_type,
      "data" =>
        Attrs.reject_nil_values(%{
          "delegation_id" => delegation.id,
          "title" => delegation.title,
          "status" => delegation.status,
          "runtime" => delegation.runtime,
          "mode" => delegation.mode,
          "attempts" => delegation.attempts,
          "result_summary" => result_summary(delegation),
          "delivery_status" => delivery_status(delegation),
          "delivery_issue_count" => delivery_issue_count(delegation),
          "workdir" => delegation.workdir,
          "reply_route" => delegation.reply_route || %{},
          "pending_user_input" => get_in(delegation.metadata || %{}, ["pending_user_input"])
        })
    }
  end

  defp result_summary(%Delegation{status: "succeeded", result: result}),
    do: map_summary(result, ~w(summary output_text))

  defp result_summary(%Delegation{status: "failed", error: error}),
    do: map_summary(error, ~w(summary reason message code))

  defp result_summary(%Delegation{}), do: nil

  defp delivery_status(%Delegation{result: %{"verification" => verification}})
       when is_map(verification),
       do: Map.get(verification, "status")

  defp delivery_status(%Delegation{}), do: nil

  defp delivery_issue_count(%Delegation{result: result}) when is_map(result) do
    verification = Map.get(result, "verification")

    case if(is_map(verification), do: Map.get(verification, "issues")) do
      issues when is_list(issues) and issues != [] -> length(issues)
      _value -> nil
    end
  end

  defp delivery_issue_count(%Delegation{}), do: nil

  defp map_summary(value, preferred_keys) when is_map(value) do
    preferred_keys
    |> Enum.find_value(fn key ->
      case Map.get(value, key) do
        text when is_binary(text) and text != "" -> text
        _value -> nil
      end
    end)
    |> case do
      nil when map_size(value) == 0 -> nil
      nil -> Ankole.JSON.encode!(value)
      text -> text
    end
    |> truncate_summary()
  end

  defp map_summary(_value, _preferred_keys), do: nil
  defp truncate_summary(nil), do: nil

  defp truncate_summary(summary) when is_binary(summary) do
    if byte_size(summary) <= @max_event_payload_bytes do
      summary
    else
      Text.truncate_utf8(summary, @max_event_payload_bytes, @truncation_suffix)
    end
  end

  @doc false
  @spec lock_agent_slots_in_tx(module(), String.t()) :: :ok | {:error, term()}
  def lock_agent_slots_in_tx(repo, agent_uid) do
    lock_key = "subagent_delegations:running_slots:#{agent_uid}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp lock_agent_slots(repo, agent_uid), do: lock_agent_slots_in_tx(repo, agent_uid)

  defp enforce_running_limit(repo, %Delegation{} = delegation, attrs) do
    status = Map.get(attrs, "status")

    cond do
      status not in @running_statuses ->
        :ok

      delegation.status in @running_statuses ->
        :ok

      running_count(repo, delegation.agent_uid, delegation.id) < @max_running_per_agent ->
        :ok

      true ->
        {:error, {:subagent_agent_running_limit_exceeded, @max_running_per_agent}}
    end
  end

  defp enforce_status_transition(%Delegation{status: current}, attrs) do
    case Map.get(attrs, "status") do
      nil ->
        {:error, :subagent_delegation_status_missing}

      next
      when next in @terminal_statuses and current in @terminal_statuses and next != current ->
        {:error, :subagent_delegation_terminal}

      next ->
        if Delegation.transition_allowed?(current, next) do
          :ok
        else
          {:error, {:invalid_subagent_status_transition, current, next}}
        end
    end
  end

  defp preserve_metadata(attrs, %Delegation{metadata: metadata}) do
    case Map.get(attrs, "metadata") do
      %{} = next_metadata -> Map.put(attrs, "metadata", Map.merge(metadata || %{}, next_metadata))
      _value -> attrs
    end
  end

  defp running_count(repo, agent_uid, delegation_id) do
    repo.aggregate(
      from(delegation in Delegation,
        where:
          delegation.agent_uid == ^agent_uid and delegation.status in ^@running_statuses and
            delegation.id != ^delegation_id
      ),
      :count
    )
  end

  defp lifecycle_timestamps(attrs, delegation, now) do
    case Map.get(attrs, "status") do
      status when status in @running_statuses ->
        Map.put_new(attrs, "started_at", delegation.started_at || now)

      status when status in @terminal_statuses ->
        attrs
        |> Map.put_new("started_at", delegation.started_at || now)
        |> Map.put_new("completed_at", now)

      _status ->
        attrs
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
