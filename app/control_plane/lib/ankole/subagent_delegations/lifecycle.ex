defmodule Ankole.SubagentDelegations.Lifecycle do
  @moduledoc false

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.Actors
  alias Ankole.Actors.ActorEvent
  alias Ankole.ActorRuntime.WorkerPool
  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.RuntimeEvents
  alias Ankole.SignalsGateway.AIReplyPreview
  alias Ankole.SubagentDelegations.Attrs
  alias Ankole.SubagentDelegations.Queries
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Text

  @max_running_per_agent 3
  @max_event_payload_bytes 16_384
  @truncation_suffix "...[truncated]"
  @terminal_statuses Delegation.terminal_statuses()
  @running_statuses Delegation.running_statuses()

  @spec prepare_attempt(String.t(), String.t()) ::
          {:ok, {:ready, Delegation.t()} | {:terminal, Delegation.t()} | :at_capacity}
          | {:error, term()}
  def prepare_attempt(delegation_id, agent_uid)
      when is_binary(delegation_id) and is_binary(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      now = now()

      Repo.transact(fn repo ->
        with :ok <- lock_agent_slots(repo, agent_uid),
             %Delegation{} = delegation <-
               Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE") do
          cond do
            delegation.status in @terminal_statuses ->
              {:ok, {:terminal, delegation}}

            delegation.attempts >= 3 ->
              {:error, :subagent_delegation_attempts_exhausted}

            delegation.status not in @running_statuses and
                running_count(repo, delegation.agent_uid, delegation.id) >=
                  @max_running_per_agent ->
              {:ok, :at_capacity}

            true ->
              delegation
              |> Delegation.changeset(%{
                status: "running",
                attempts: delegation.attempts + 1,
                started_at: delegation.started_at || now
              })
              |> repo.update()
              |> case do
                {:ok, delegation} -> {:ok, {:ready, delegation}}
                {:error, reason} -> {:error, reason}
              end
          end
        else
          nil -> {:error, :delegation_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  @spec commit_status_with_wakeup(String.t(), String.t(), map()) ::
          {:ok, %{delegation: Delegation.t(), wakeup_event: ActorEvent.t() | nil}}
          | {:error, term()}
  def commit_status_with_wakeup(delegation_id, agent_uid, attrs)
      when is_binary(delegation_id) and is_binary(agent_uid) and is_map(attrs) do
    result =
      with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
        now = now()

        Repo.transact(fn repo ->
          with :ok <- lock_agent_slots(repo, agent_uid),
               %Delegation{} = delegation <-
                 Queries.get_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE"),
               attrs <- Attrs.normalize(attrs),
               :ok <- enforce_status_transition(delegation, attrs),
               :ok <- enforce_running_limit(repo, delegation, attrs),
               {:ok, delegation} <-
                 delegation
                 |> Delegation.changeset(
                   attrs
                   |> preserve_metadata(delegation)
                   |> lifecycle_timestamps(delegation, now)
                 )
                 |> repo.update(),
               :ok <- maybe_release_worker_assignment(repo, delegation),
               {:ok, wakeup_event} <- append_wakeup_event(repo, delegation, now),
               :ok <- nudge_queued_after_slot_release(repo, delegation, now) do
            {:ok, %{delegation: delegation, wakeup_event: wakeup_event}}
          else
            nil -> {:error, :delegation_not_found}
            {:error, _reason} = error -> error
          end
        end)
      end

    case result do
      {:ok, %{wakeup_event: %ActorEvent{} = event}} = success ->
        _ = AIReplyPreview.maybe_start_for(event)
        success

      other ->
        other
    end
  end

  @doc false
  @spec nudge_queued_after_slot_release(module(), Delegation.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def nudge_queued_after_slot_release(repo, %Delegation{status: status} = delegation, now)
      when status in @terminal_statuses do
    Delegation
    |> where([row], row.agent_uid == ^delegation.agent_uid)
    |> where([row], row.status == "queued")
    |> select([row], row.id)
    |> repo.all()
    |> Enum.reduce_while(:ok, fn delegation_id, :ok ->
      case RuntimeEvents.notify_actor_session_ready(
             repo,
             delegation.agent_uid,
             "subagent:#{delegation_id}",
             now
           ) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  def nudge_queued_after_slot_release(_repo, %Delegation{}, _now), do: :ok

  defp maybe_release_worker_assignment(repo, %Delegation{status: status} = delegation)
       when status in @terminal_statuses or status == "waiting_on_user" do
    WorkerPool.release_assignment_for_actor_in_tx(repo, %{
      agent_uid: delegation.agent_uid,
      session_id: "subagent:#{delegation.id}"
    })
  end

  defp maybe_release_worker_assignment(_repo, %Delegation{}), do: :ok

  defp append_wakeup_event(repo, %Delegation{} = delegation, now) do
    case wakeup_event_type(delegation.status) do
      nil ->
        {:ok, nil}

      event_type ->
        source_event_id = wakeup_source_event_id(delegation)
        reply_route = delegation.reply_route || %{}

        with binding_name when is_binary(binding_name) <- Attrs.text(reply_route, "binding_name") do
          Actors.append_actor_event_in_tx(repo, %{
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
    "subagent_delegation:#{delegation.id}:#{delegation.status}"
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
          "attempts" => delegation.attempts,
          "result_summary" => result_summary(delegation),
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

  defp lock_agent_slots(repo, agent_uid) do
    lock_key = "subagent_delegations:running_slots:#{agent_uid}"

    case SQL.query(repo, "SELECT pg_advisory_xact_lock(hashtext($1::text))", [lock_key]) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

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
