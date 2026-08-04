defmodule Ankole.BackgroundAgentJobs do
  @moduledoc """
  Durable BackgroundAgentJob work items and normalized runtime-turn trajectories.

  This module is the stable context facade. PostgreSQL owns work lifecycle and
  trajectory truth; the internal modules keep dispatch, lifecycle transitions,
  control actions, queries, and turn persistence as separate responsibilities.
  """

  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.Control
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Turns

  @job_session_prefix "job:"
  @job_session_prefix_size byte_size(@job_session_prefix)
  @minimum_job_id 1000
  @maximum_job_id 9_007_199_254_740_991
  @turn_error_retry_seconds [60, 600, 1_800, 3_600, 7_200]

  @doc """
  Builds the durable actor-session id for one BackgroundAgentJob.

  The `"job:" <> Integer.to_string(job_id)` format is a frozen public contract: it is persisted in
  `actor_events.session_id`, worker assignments, and AIGateway
  `conversations.conversation_key`; documented in the Console API session
  schema; and typed by operators in the Console session picker. See
  `docs/design-docs/BackgroundAgentJob.md`. Changing it means a data migration
  plus an API change, not an edit here.
  """
  @spec job_session_id(pos_integer()) :: String.t()
  def job_session_id(job_id)
      when is_integer(job_id) and job_id >= @minimum_job_id and job_id <= @maximum_job_id,
      do: @job_session_prefix <> Integer.to_string(job_id)

  @doc "True when the value is a BackgroundAgentJob session id. Usable in guards."
  defguard is_job_session_id(session_id)
           when is_binary(session_id) and
                  byte_size(session_id) > @job_session_prefix_size and
                  binary_part(session_id, 0, @job_session_prefix_size) == @job_session_prefix

  @doc "Parses a canonical model-safe Job id from its RuntimeFabric decimal string."
  @spec parse_job_id(term()) :: {:ok, pos_integer()} | :error
  def parse_job_id(job_id)
      when is_integer(job_id) and job_id >= @minimum_job_id and job_id <= @maximum_job_id,
      do: {:ok, job_id}

  def parse_job_id(job_id) when is_binary(job_id) do
    case Integer.parse(job_id) do
      {parsed, ""}
      when parsed >= @minimum_job_id and parsed <= @maximum_job_id ->
        if Integer.to_string(parsed) == job_id, do: {:ok, parsed}, else: :error

      _parsed ->
        :error
    end
  end

  def parse_job_id(_other), do: :error

  @doc "Extracts the integer Job id from a Job session id; `:error` for any other term."
  @spec parse_job_session_id(term()) :: {:ok, pos_integer()} | :error
  def parse_job_session_id(@job_session_prefix <> job_id), do: parse_job_id(job_id)

  def parse_job_session_id(_other), do: :error

  @doc "The raw prefix, only for storage-boundary prefix matching (SQL `LIKE`, key filters)."
  @spec job_session_prefix() :: String.t()
  def job_session_prefix, do: @job_session_prefix

  @doc false
  @spec turn_error_retry_at(map(), pos_integer(), DateTime.t()) :: DateTime.t()
  def turn_error_retry_at(reason, delivery_attempt_no, %DateTime{} = now)
      when is_map(reason) and is_integer(delivery_attempt_no) and delivery_attempt_no > 0 do
    credential_pool_retry_at(reason, now) ||
      DateTime.add(
        now,
        Enum.at(
          @turn_error_retry_seconds,
          min(delivery_attempt_no, length(@turn_error_retry_seconds)) - 1
        ),
        :second
      )
  end

  @doc "Creates one durable work item and its isolated dispatch event atomically."
  defdelegate create_with_dispatch(attrs), to: Dispatch

  @doc "Creates one durable successor for a terminal Job and dispatches it atomically."
  defdelegate respawn_with_dispatch(source_job_id, attrs), to: Dispatch

  @doc false
  defdelegate claim_attempt_in_tx(repo, job_id, agent_uid, expected_attempt, turn_start_spec),
    to: Lifecycle

  @doc false
  defdelegate claim_continuation_in_tx(
                repo,
                job_id,
                agent_uid,
                expected_attempt,
                turn_start_spec
              ),
              to: Lifecycle

  @doc false
  defdelegate requeue_unstarted_attempt(job_id, agent_uid, expected_attempt),
    to: Lifecycle

  @doc false
  defdelegate requeue_credential_pool_exhausted_attempt_in_tx(repo, job_id, agent_uid),
    to: Lifecycle

  @doc false
  defdelegate finalize_worker_turn_in_tx(repo, turn_ref, now), to: Lifecycle

  @doc "Delays one still-open job actor event without consuming it."
  defdelegate defer_actor_event(actor_event, available_at), to: Dispatch

  @doc "Completes a job actor event that no longer needs execution."
  defdelegate complete_actor_event(actor_event), to: Dispatch

  @doc "Consumes a superseded initial dispatch before a queued steer starts work."
  defdelegate complete_open_dispatch(job_id, agent_uid), to: Dispatch

  @doc "Commits one lifecycle transition and its parent wakeup atomically."
  def commit_status_with_wakeup(job_id, agent_uid, attrs, opts \\ []),
    do: Lifecycle.commit_status_with_wakeup(job_id, agent_uid, attrs, opts)

  defp fail_turn_persistence_rejection_in_tx(
         repo,
         job_id,
         agent_uid,
         %DateTime{} = now
       ) do
    with {:ok, result} <-
           Lifecycle.commit_status_after_runtime_prefix_in_tx(
             repo,
             job_id,
             agent_uid,
             %{
               "status" => "failed",
               "error" => %{
                 "code" => "turn_persistence_rejected",
                 "summary" => "Job Turn trajectory persistence was rejected by the control plane."
               }
             },
             now,
             nil,
             %{
               "code" => "turn_persistence_rejected",
               "summary" =>
                 "The control plane interrupted this runtime Turn after rejecting its checkpoint."
             }
           ),
         {:ok, :ok} <-
           Dispatch.complete_all_open_events_in_tx(repo, job_id, agent_uid, now) do
      {:ok, result}
    end
  end

  @doc false
  def compensate_turn_error_in_tx(
        repo,
        %ActorEvent{
          agent_uid: agent_uid,
          session_id: session_id,
          input_state: "open"
        },
        %{
          "details_json" => %{"error_code" => "credential_pool_exhausted"}
        } = reason,
        %DateTime{} = now
      ) do
    with %DateTime{} <- credential_pool_retry_at(reason, now) || :invalid_retry_at,
         {:ok, job_id} <- parse_job_session_id(session_id),
         {:ok, job} <-
           Lifecycle.requeue_credential_pool_exhausted_attempt_in_tx(
             repo,
             job_id,
             agent_uid
           ) do
      {:ok, %{kind: :credential_pool_requeued, job: job}}
    else
      :invalid_retry_at -> {:ok, nil}
      :error -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  def compensate_turn_error_in_tx(
        repo,
        %ActorEvent{agent_uid: agent_uid, session_id: session_id},
        %{"details_json" => %{"error_code" => "background_agent_job_turn_persistence_rejected"}},
        %DateTime{} = now
      ) do
    case parse_job_session_id(session_id) do
      {:ok, job_id} -> fail_turn_persistence_rejection_in_tx(repo, job_id, agent_uid, now)
      :error -> {:ok, nil}
    end
  end

  def compensate_turn_error_in_tx(
        repo,
        %ActorEvent{
          agent_uid: agent_uid,
          session_id: session_id,
          input_state: "dead_letter"
        },
        %{"code" => code, "message" => message, "details_json" => details},
        %DateTime{} = now
      )
      when is_binary(code) and is_binary(message) and is_map(details) do
    with {:ok, job_id} <- parse_job_session_id(session_id),
         {:ok, result} <-
           Lifecycle.commit_status_after_runtime_prefix_in_tx(
             repo,
             job_id,
             agent_uid,
             %{
               "status" => "failed",
               "error" => %{
                 "code" => code,
                 "summary" => message,
                 "details" => details
               }
             },
             now,
             nil,
             %{"code" => code, "summary" => message}
           ),
         {:ok, :ok} <-
           Dispatch.complete_all_open_events_in_tx(repo, job_id, agent_uid, now) do
      {:ok, result}
    else
      :error -> {:ok, nil}
      {:error, _reason} = error -> error
    end
  end

  def compensate_turn_error_in_tx(_repo, %ActorEvent{}, _reason, %DateTime{}),
    do: {:ok, nil}

  defp credential_pool_retry_at(%{"details_json" => details}, now) when is_map(details) do
    if credential_pool_exhausted_details?(details) do
      details
      |> pool_retry_at_value()
      |> parse_pool_retry_at(now)
    end
  end

  defp credential_pool_retry_at(_reason, _now), do: nil

  defp credential_pool_exhausted_details?(details) do
    details["error_code"] == "credential_pool_exhausted" or
      get_in(details, ["aigateway", "code"]) == "credential_pool_exhausted"
  end

  defp pool_retry_at_value(details) do
    details["retry_at"] ||
      get_in(details, ["aigateway", "details_json", "retry_at"])
  end

  defp parse_pool_retry_at(retry_at, now) when is_binary(retry_at) do
    case DateTime.from_iso8601(retry_at) do
      {:ok, parsed, _offset} ->
        if DateTime.compare(parsed, now) == :lt, do: now, else: parsed

      _error ->
        nil
    end
  end

  defp parse_pool_retry_at(_retry_at, _now), do: nil

  @doc false
  def finalize_turn_error(
        {:ok,
         %{
           turn_error_compensation: %{kind: :credential_pool_requeued} = compensation
         } = result}
      ) do
    {:ok,
     result
     |> Map.delete(:turn_error_compensation)
     |> Map.put(:status, :background_agent_job_requeued)
     |> Map.put(:background_agent_job_requeue, compensation)}
  end

  def finalize_turn_error({:ok, %{turn_error_compensation: compensation} = result}) do
    {:ok,
     result
     |> Map.delete(:turn_error_compensation)
     |> Map.put(:status, :background_agent_job_failed)
     |> Map.put(:background_agent_job_failure, compensation)}
  end

  def finalize_turn_error(result), do: result

  @doc false
  defdelegate pending_steer_events(job_id, agent_uid, excluded_event_id), to: Dispatch

  @doc "Lists a page of work visible from the parent session and channel."
  def list_for_channel(agent_uid, owner_session_id, signal_channel_id, opts \\ []),
    do: Queries.list_for_channel(agent_uid, owner_session_id, signal_channel_id, opts)

  @doc "Lists installation-wide Console work with a stable keyset cursor."
  def list_for_console(opts \\ []), do: Queries.list_for_console(opts)

  @doc "Fetches one job without chat visibility constraints for Console."
  defdelegate get_job(job_id), to: Queries, as: :get

  @doc "Projects a job into the named Console API contract."
  defdelegate console_projection(job), to: Queries

  @doc false
  defdelegate worker_turn_projection(turn), to: Turns, as: :worker_projection

  @doc "Durably requests cancellation without trusting worker-local state."
  defdelegate request_stop(job_id, attrs), to: Control

  @doc "Journals one message for a running or waiting Job."
  defdelegate send_message(job_id, attrs), to: Control

  @doc false
  defdelegate message_result(job, command_event_id, caller_session_id), to: Turns

  @doc false
  defdelegate upsert_turn_from_worker(job_id, agent_uid, attrs, turn_ref, route),
    to: Lifecycle

  @doc "Lists normalized runtime turns for one job."
  defdelegate list_turns(job_id, opts \\ []), to: Turns, as: :list_for_job

  @doc "Projects one complete runtime turn for Console."
  defdelegate console_turn_projection(turn), to: Turns, as: :console_projection

  @doc "Fetches one job for an agent."
  defdelegate get_job_for_agent(job_id, agent_uid), to: Queries, as: :get_for_agent

  @doc "Fetches one job with its orchestrator-facing execution projection."
  def get_job_summary_for_agent(job_id, agent_uid, opts \\ []),
    do: Queries.get_summary_for_agent(job_id, agent_uid, opts)
end
