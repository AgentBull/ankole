defmodule Ankole.BackgroundAgentJobs do
  @moduledoc """
  Durable BackgroundAgentJob work items and normalized runtime-turn trajectories.

  This module is the stable context facade. PostgreSQL owns work lifecycle and
  trajectory truth; the internal modules keep dispatch, lifecycle transitions,
  control actions, queries, and turn persistence as separate responsibilities.
  """

  @behaviour Ankole.Sessions.AsyncWorkUnit

  alias Ankole.I18n
  alias Ankole.Signals.Signal
  alias Ankole.BackgroundAgentJobs.Control
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Dispatch
  alias Ankole.BackgroundAgentJobs.Lifecycle
  alias Ankole.BackgroundAgentJobs.Queries
  alias Ankole.BackgroundAgentJobs.TurnEvidence
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Sessions.TurnErrorClassifier

  @minimum_job_id 1000
  @maximum_job_id 9_007_199_254_740_991
  @doc """
  Builds the durable Session id for one BackgroundAgentJob.

  The `job:<id>` format is a frozen public contract: it is persisted in
  `signals.session_id` and AIGateway
  `conversations.conversation_key`; documented in the Console API session
  schema; and typed by operators in the Console session picker. See
  `docs/design-docs/BackgroundAgentJob.md`. Changing it means a data migration
  plus an API change, not an edit here.
  """
  @spec job_session_id(pos_integer()) :: String.t()
  def job_session_id(job_id)
      when is_integer(job_id) and job_id >= @minimum_job_id and job_id <= @maximum_job_id,
      do: Ankole.Sessions.Key.job(job_id)

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
  def parse_job_session_id(key) do
    case Ankole.Sessions.Key.parse(key) do
      {:job, id} -> parse_job_id(id)
      _ -> :error
    end
  end

  @doc "The raw prefix, only for storage-boundary prefix matching (SQL `LIKE`, key filters)."
  @spec job_session_prefix() :: String.t()
  def job_session_prefix, do: Ankole.Sessions.Key.job("")

  @doc false
  @spec turn_error_retry_at(map(), pos_integer(), DateTime.t()) :: DateTime.t()
  def turn_error_retry_at(reason, delivery_attempt_no, %DateTime{} = now)
      when is_map(reason) and is_integer(delivery_attempt_no) and delivery_attempt_no > 0 do
    TurnErrorClassifier.credential_pool_retry_at(reason, now) ||
      DateTime.add(
        now,
        TurnErrorClassifier.delay_seconds(
          :job,
          delivery_attempt_no,
          TurnErrorClassifier.classify(reason)
        ),
        :second
      )
  end

  @background_job_wakeup_notice_keys %{
    "background_agent_job.completed" => "background_agent_job_dead_letter_succeeded",
    "background_agent_job.failed" => "background_agent_job_dead_letter_failed",
    "background_agent_job.waiting" => "background_agent_job_dead_letter_waiting"
  }

  @doc false
  @impl Ankole.Sessions.AsyncWorkUnit
  def dead_letter_notice_text(%Signal{type: type} = event)
      when is_map_key(@background_job_wakeup_notice_keys, type) do
    data = event.data

    detail =
      [
        text_value(data["result_summary"]),
        artifacts_notice_line(data["artifacts"]),
        successor_notice_line(data["successor_job_id"])
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join("\n")

    I18n.t(
      "conversations.delivery.reply.#{Map.fetch!(@background_job_wakeup_notice_keys, type)}",
      %{
        "job_id" => data["job_id"] || 0,
        "title" => text_value(data["title"]) || "",
        "detail" => detail
      }
    )
  end

  def dead_letter_notice_text(%Signal{}), do: nil

  @doc "Creates one durable work item and its isolated dispatch event atomically."
  defdelegate create_with_dispatch(attrs), to: Dispatch

  @doc "Creates one durable successor for a terminal Job and dispatches it atomically."
  defdelegate respawn_with_dispatch(source_job_id, attrs), to: Dispatch

  @doc false
  defdelegate requeue_credential_pool_exhausted_attempt_in_tx(repo, job_id, agent_uid),
    to: Lifecycle

  @doc "Delays one still-open job Signal without consuming it."
  defdelegate defer_signal(signal, available_at), to: Dispatch

  @doc "Completes a job Signal that no longer needs execution."
  defdelegate complete_signal(signal), to: Dispatch

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
        %Signal{
          agent_uid: agent_uid,
          session_id: session_id,
          input_state: "open"
        },
        %{
          "details_json" => %{"error_code" => "credential_pool_exhausted"}
        } = reason,
        %DateTime{} = now
      ) do
    case parse_job_session_id(session_id) do
      {:ok, job_id} -> compensate_credential_pool_exhaustion(repo, job_id, agent_uid, reason, now)
      :error -> {:ok, nil}
    end
  end

  def compensate_turn_error_in_tx(
        repo,
        %Signal{agent_uid: agent_uid, session_id: session_id},
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
        %Signal{
          agent_uid: agent_uid,
          session_id: session_id,
          input_state: "dead_letter"
        },
        %{"code" => code, "message" => message, "details_json" => details},
        %DateTime{} = now
      )
      when is_binary(code) and is_binary(message) and is_map(details) do
    code = terminal_failure_code(code, details)

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
  # means an active runtime Turn. The Job stops holding an Agent slot while its
  # Signal waits on the retry ladder; the next delivery claims a fresh
  # attempt through the ordinary capacity checks.
  def compensate_turn_error_in_tx(
        repo,
        %Signal{
          agent_uid: agent_uid,
          session_id: session_id,
          input_state: "open"
        },
        reason,
        %DateTime{}
      )
      when is_map(reason) do
    case parse_job_session_id(session_id) do
      {:ok, job_id} -> requeue_retryable_attempt(repo, job_id, agent_uid, reason)
      :error -> {:ok, nil}
    end
  end

  def compensate_turn_error_in_tx(_repo, %Signal{}, _reason, %DateTime{}),
    do: {:ok, nil}

  @doc "Returns a terminal Job error when the Agent quota is exhausted."
  @spec quota_terminal_error(map(), String.t()) :: map()
  def quota_terminal_error(error, agent_uid) do
    if get_in(error, ["details_json", "error_code"]) == "credential_pool_exhausted" and
         match?(
           {:error, {:agent_token_quota_exceeded, _}},
           Ankole.AIAgent.TokenQuota.ensure_available(agent_uid)
         ) do
      %{
        "code" => "worker_turn_failed",
        "message" => "The Agent has used its token quota for the current period.",
        "details_json" => %{
          "runtime" => "bun",
          "retryable" => false,
          "error_code" => "agent_token_quota_exceeded"
        }
      }
    else
      error
    end
  end

  # A quota rejection is the Job's own verdict, not a generic Worker turn
  # failure, so the stored code names it for every reader of the Job.
  defp terminal_failure_code(code, details) do
    if details["error_code"] == "agent_token_quota_exceeded",
      do: "agent_token_quota_exceeded",
      else: code
  end

  # A declared pool recovery time is AIGateway backpressure, so the requeue
  # keeps the claim and charges no execution-failure budget. A stale or missing
  # time is an ordinary capacity failure: the Job returns to `queued` and this
  # attempt charges the budget like any other provider-capacity failure.
  defp compensate_credential_pool_exhaustion(repo, job_id, agent_uid, reason, now) do
    case TurnErrorClassifier.credential_pool_retry_at(reason, now) do
      %DateTime{} ->
        case Lifecycle.requeue_credential_pool_exhausted_attempt_in_tx(repo, job_id, agent_uid) do
          {:ok, job} -> {:ok, %{kind: :credential_pool_requeued, job: job}}
          {:error, _reason} = error -> error
        end

      nil ->
        requeue_retryable_attempt(repo, job_id, agent_uid, reason)
    end
  end

  defp requeue_retryable_attempt(repo, job_id, agent_uid, reason) do
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
  end

  defp text_value(value) when is_binary(value) and value != "", do: value
  defp text_value(_value), do: nil

  defp artifacts_notice_line(%{"paths" => paths}) when is_list(paths) and paths != [] do
    I18n.t("conversations.delivery.reply.background_agent_job_dead_letter_artifacts", %{
      "paths" => Enum.join(paths, ", ")
    })
  end

  defp artifacts_notice_line(_artifacts), do: nil

  defp successor_notice_line(successor_job_id) when is_integer(successor_job_id) do
    I18n.t("conversations.delivery.reply.background_agent_job_dead_letter_successor", %{
      "successor_job_id" => successor_job_id
    })
  end

  defp successor_notice_line(_successor), do: nil

  # Context overflow is an automatic compact-and-retry recovery, not the task
  # failing, so it consumes no execution-failure budget. Every other
  # non-infrastructure failure is charged, including a provider-capacity
  # failure whose credential pool gave no usable recovery time.
  defp charged_turn_error?(%{"code" => "context_overflow"}), do: false
  defp charged_turn_error?(reason), do: TurnErrorClassifier.classify(reason) != :infrastructure

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

  @doc "Projects one bounded page of a job's runtime turns for Console."
  defdelegate console_turn_page(job, cursor), to: Turns, as: :console_page

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
  defdelegate upsert_turn_from_worker(job_id, agent_uid, attrs, turn_ref, worker_id),
    to: Lifecycle

  @doc "Lists normalized runtime turns for one job."
  defdelegate list_turns(job_id, opts \\ []), to: Turns, as: :list_for_job

  @doc "Returns recent finished Jobs that carry skill-lesson evidence."
  defdelegate evidence_signals(agent_uid, since_job_id, completed_after), to: TurnEvidence

  @doc "Renders bounded skill-lesson evidence sections for the given Jobs."
  defdelegate evidence_sections(job_ids), to: TurnEvidence

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
