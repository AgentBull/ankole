defmodule Ankole.BackgroundAgentJobs do
  @moduledoc """
  Durable BackgroundAgentJob work items and normalized runtime-turn trajectories.

  This module is the stable context facade. PostgreSQL owns work lifecycle and
  trajectory truth; the internal modules keep dispatch, lifecycle transitions,
  control actions, queries, and turn persistence as separate responsibilities.
  """

  @behaviour Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit

  alias Ankole.I18n
  alias Ankole.SignalsGateway.ActorEvent
  alias Ankole.BackgroundAgentJobs.Control
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.BackgroundAgentJobs.TurnWatchdog

  @job_session_prefix "job:"
  @job_session_prefix_size byte_size(@job_session_prefix)
  @minimum_job_id 1000
  @maximum_job_id 9_007_199_254_740_991
  # Provider-class failures keep the long ladder so the five-failure budget
  # spans a realistic upstream outage window (about 3.7 hours). Infrastructure
  # interruptions restart in seconds and never consume that budget, so they
  # retry on the short ladder instead of holding the Job for hours.
  @turn_error_retry_seconds [60, 600, 1_800, 3_600, 7_200]
  @infrastructure_retry_seconds [15, 30, 60, 120, 300]
  @infrastructure_error_codes ~w(
    background_agent_job_runtime_exception
    agent_codex_runtime_busy
    background_agent_job_steer_delivery_failed
    codex_app_server_request_timeout
  )

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
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  @spec turn_error_retry_at(map(), pos_integer(), DateTime.t()) :: DateTime.t()
  def turn_error_retry_at(reason, delivery_attempt_no, %DateTime{} = now)
      when is_map(reason) and is_integer(delivery_attempt_no) and delivery_attempt_no > 0 do
    credential_pool_retry_at(reason, now) ||
      DateTime.add(now, ladder_seconds(turn_error_class(reason), delivery_attempt_no), :second)
  end

  @doc false
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  def dead_letter_after_turn_error?(%ActorEvent{}, _reason, recoverable?)
      when is_boolean(recoverable?),
      do: not recoverable?

  @background_job_wakeup_notice_keys %{
    "background_agent_job.completed" => "background_agent_job_dead_letter_succeeded",
    "background_agent_job.failed" => "background_agent_job_dead_letter_failed",
    "background_agent_job.waiting" => "background_agent_job_dead_letter_waiting"
  }

  @doc false
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
  def dead_letter_notice_text(%ActorEvent{type: type} = event)
      when is_map_key(@background_job_wakeup_notice_keys, type) do
    data = get_in(event.payload || %{}, ["data"]) || %{}

    detail =
      [
        text_value(data["result_summary"]),
        artifacts_notice_line(data["artifacts"]),
        successor_notice_line(data["successor_job_id"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    I18n.t(
      "signals_gateway.reply.#{Map.fetch!(@background_job_wakeup_notice_keys, type)}",
      %{
        "job_id" => data["job_id"] || 0,
        "title" => text_value(data["title"]) || "",
        "detail" => detail
      }
    )
  end

  def dead_letter_notice_text(%ActorEvent{}), do: nil

  defp ladder_seconds(:infrastructure, delivery_attempt_no) do
    Enum.at(
      @infrastructure_retry_seconds,
      min(delivery_attempt_no, length(@infrastructure_retry_seconds)) - 1
    )
  end

  defp ladder_seconds(:execution, delivery_attempt_no) do
    Enum.at(
      @turn_error_retry_seconds,
      min(delivery_attempt_no, length(@turn_error_retry_seconds)) - 1
    )
  end

  # Splits worker turn failures into the two retry accounts. Infrastructure
  # interruptions (runtime loss, the shared-runtime lock, steer transport) are
  # not the task failing, so they never consume the execution-failure budget.
  # Everything else, including provider and model failures, is an execution
  # failure charged against the bounded budget.
  @doc false
  @spec turn_error_class(map()) :: :infrastructure | :execution
  def turn_error_class(reason) when is_map(reason) do
    details = reason["details_json"] || %{}

    if reason["code"] in @infrastructure_error_codes or
         details["error_code"] in @infrastructure_error_codes do
      :infrastructure
    else
      :execution
    end
  end

  @doc "Creates one durable work item and its isolated dispatch event atomically."
  defdelegate create_with_dispatch(attrs), to: Dispatch

  @doc "Creates one durable successor for a terminal Job and dispatches it atomically."
  defdelegate respawn_with_dispatch(source_job_id, attrs), to: Dispatch

  @doc false
  defdelegate claim_attempt_in_tx(
                repo,
                job_id,
                agent_uid,
                expected_attempt,
                turn_start_spec,
                max_running_per_agent
              ),
              to: Lifecycle

  @doc false
  defdelegate claim_continuation_in_tx(
                repo,
                job_id,
                agent_uid,
                expected_attempt,
                turn_start_spec,
                max_running_per_agent
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
  @impl Ankole.SignalsGateway.ActorRuntime.AsyncWorkUnit
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

  # A retryable attempt failure returns the Job to `queued` so `running` always
  # means an active runtime Turn. The Job stops holding an Agent slot and a
  # Worker assignment while its actor event waits on the retry ladder; the next
  # delivery claims a fresh attempt through the ordinary capacity checks.
  def compensate_turn_error_in_tx(
        repo,
        %ActorEvent{
          agent_uid: agent_uid,
          session_id: session_id,
          input_state: "open"
        },
        reason,
        %DateTime{}
      )
      when is_map(reason) do
    case parse_job_session_id(session_id) do
      {:ok, job_id} ->
        case Lifecycle.requeue_retryable_attempt_in_tx(
               repo,
               job_id,
               agent_uid,
               charge: charged_turn_error?(reason)
             ) do
          {:ok, %Job{} = job} -> {:ok, %{kind: :retryable_requeued, job: job}}
          {:ok, nil} -> {:ok, nil}
          {:error, _reason} = error -> error
        end

      :error ->
        {:ok, nil}
    end
  end

  def compensate_turn_error_in_tx(_repo, %ActorEvent{}, _reason, %DateTime{}),
    do: {:ok, nil}

  defp text_value(value) when is_binary(value) and value != "", do: value
  defp text_value(_value), do: nil

  defp artifacts_notice_line(%{"paths" => paths}) when is_list(paths) and paths != [] do
    I18n.t("signals_gateway.reply.background_agent_job_dead_letter_artifacts", %{
      "paths" => Enum.join(paths, ", ")
    })
  end

  defp artifacts_notice_line(_artifacts), do: nil

  defp successor_notice_line(successor_job_id) when is_integer(successor_job_id) do
    I18n.t("signals_gateway.reply.background_agent_job_dead_letter_successor", %{
      "successor_job_id" => successor_job_id
    })
  end

  defp successor_notice_line(_successor), do: nil

  # Context overflow is an automatic compact-and-retry recovery, not the task
  # failing, so it consumes no execution-failure budget.
  defp charged_turn_error?(%{"code" => "context_overflow"}), do: false
  defp charged_turn_error?(reason), do: turn_error_class(reason) == :execution

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
        if DateTime.compare(parsed, now) == :gt, do: parsed

      _error ->
        nil
    end
  end

  defp parse_pool_retry_at(_retry_at, _now), do: nil

  @doc false
  def finalize_turn_error(
        {:ok,
         %{
           turn_error_compensation: %{kind: kind} = compensation
         } = result}
      )
      when kind in [:credential_pool_requeued, :retryable_requeued] do
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
  defdelegate runtime_event_snapshot(), to: TurnWatchdog

  @doc "Fails or retries one Job whose runtime Turn stopped recording progress."
  def reconcile_stuck_job(job_id, opts \\ []), do: TurnWatchdog.reconcile_stuck_job(job_id, opts)

  @doc false
  defdelegate pending_steer_events(job_id, agent_uid, excluded_event_id), to: Dispatch

  @doc "Lists a page of work owned by one Agent."
  def list_for_agent(agent_uid, opts \\ []), do: Queries.list_for_agent(agent_uid, opts)

  @doc "Lists installation-wide Console work with a stable keyset cursor."
  def list_for_console(opts \\ []), do: Queries.list_for_console(opts)

  @doc "Returns operator reliability metrics for the Console health panel."
  defdelegate health_metrics(), to: Ankole.BackgroundAgentJobs.Health, as: :metrics

  @doc "Fetches one job without chat visibility constraints for Console."
  defdelegate get_job(job_id), to: Queries, as: :get

  @doc "Projects a job into the named Console API contract."
  defdelegate console_projection(job), to: Queries

  @doc "Projects one `list_for_console/1` row into the named Console list contract."
  defdelegate console_list_projection(row), to: Queries

  @doc false
  defdelegate worker_turn_projection(turn), to: Turns, as: :worker_projection

  @doc "Projects complete runtime turns for Console."
  defdelegate console_turn_projections(turns), to: Turns, as: :console_projections

  @doc "Durably requests cancellation without trusting worker-local state."
  defdelegate request_stop(job_id, attrs), to: Control

  @doc """
  Lists live Job ids whose owner session is one of the given sessions.

  Workflow terminal cleanup uses this to stop the Jobs its task sessions
  delegated. The owner session is the creation-time parent link, so no extra
  binding storage exists.
  """
  defdelegate live_job_ids_for_owner_sessions(session_ids, agent_uid), to: Queries

  @doc "Commits an externally verified completion with the caller's result summary."
  defdelegate request_complete(job_id, attrs), to: Control

  @doc "Journals one message for a live Job."
  defdelegate send_message(job_id, attrs), to: Control

  @doc false
  defdelegate lock_ambient_handoff_target_in_tx(repo, agent_uid, job_id), to: Control

  @doc false
  defdelegate handoff_ambient_message_in_tx(repo, source_event, job, message, now),
    to: Control

  @doc false
  defdelegate message_result(job, command_event_id, caller_session_id), to: Turns

  @doc false
  defdelegate upsert_turn_from_worker(job_id, agent_uid, attrs, turn_ref, route),
    to: Lifecycle

  @doc "Lists normalized runtime turns for one job."
  defdelegate list_turns(job_id, opts \\ []), to: Turns, as: :list_for_job

  @doc "Pages the lead-thread turn items of one job's workspace lineage for thread replay."
  defdelegate replay_items_page(job, cursor), to: Turns

  @doc "Fetches one job for an agent."
  defdelegate get_job_for_agent(job_id, agent_uid), to: Queries, as: :get_for_agent

  @doc false
  defdelegate get_result_window_for_agent(job_id, agent_uid, offset), to: Queries

  @doc "Fetches one job with its orchestrator-facing execution projection."
  def get_job_summary_for_agent(job_id, agent_uid, opts \\ []),
    do: Queries.get_summary_for_agent(job_id, agent_uid, opts)
end
