defmodule Ankole.AutomationJobs do
  @moduledoc """
  Owns automation job definitions, durable runs, and emitted Agent events.

  Trigger domains keep their own claim and recurrence rules. They call
  `enqueue_run_in_tx/5` inside that existing transaction when a trigger names
  an automation job.
  """

  import Ecto.Query, warn: false

  alias Ankole.AutomationJobs.Jobs.ExecuteRun
  alias Ankole.AutomationJobs.Schemas.Job
  alias Ankole.AutomationJobs.Schemas.Run
  alias Ankole.Ecto.JSONPayload
  alias Ankole.Repo
  alias Ankole.SignalsGateway

  @log_max_bytes 65_536
  @payload_max_bytes 1_048_576

  @type enqueue_result :: %{
          status: :queued | :failed,
          automation_job_run: Run.t()
        }

  @doc """
  Creates one non-idempotent automation job.
  """
  @spec create_job(map()) :: {:ok, Job.t()} | {:error, term()}
  def create_job(attrs) when is_map(attrs) do
    %Job{}
    |> Job.changeset(normalize_agent_uid(attrs))
    |> Repo.insert()
  end

  @doc """
  Lists recent automation jobs owned by one Agent session, or by every session
  of the Agent when `owner_session_id` is `nil`.
  """
  @spec list_jobs(String.t(), String.t() | nil, keyword()) :: [Job.t()]
  def list_jobs(agent_uid, owner_session_id, opts \\ [])
      when is_binary(agent_uid) and (is_binary(owner_session_id) or is_nil(owner_session_id)) do
    limit = opts |> Keyword.get(:limit, 100) |> bounded_limit(500, 100)

    Job
    |> where([job], job.agent_uid == ^String.downcase(agent_uid))
    |> maybe_where_owner_session(owner_session_id)
    |> order_by([job], desc: job.inserted_at, desc: job.id)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Gets one automation job only when the Agent session owns it. A `nil`
  `owner_session_id` accepts any session of the Agent.
  """
  @spec get_job(String.t(), String.t() | nil, pos_integer()) ::
          {:ok, Job.t()} | {:error, :automation_job_not_found}
  def get_job(agent_uid, owner_session_id, job_id)
      when is_binary(agent_uid) and (is_binary(owner_session_id) or is_nil(owner_session_id)) and
             is_integer(job_id) and job_id > 0 do
    query =
      Job
      |> where([job], job.id == ^job_id and job.agent_uid == ^String.downcase(agent_uid))
      |> maybe_where_owner_session(owner_session_id)

    case Repo.one(query) do
      %Job{} = job -> {:ok, job}
      nil -> {:error, :automation_job_not_found}
    end
  end

  def get_job(_agent_uid, _owner_session_id, _job_id),
    do: {:error, :automation_job_not_found}

  @doc """
  Cancels one job and every queued run in the same transaction.

  Running attempts keep their current fence and may finish or emit events.
  """
  @spec cancel_job(String.t(), String.t(), pos_integer(), keyword()) ::
          {:ok, %{status: :cancelled | :already_terminal, automation_job: Job.t()}}
          | {:error, term()}
  def cancel_job(agent_uid, owner_session_id, job_id, opts \\ [])

  def cancel_job(agent_uid, owner_session_id, job_id, opts)
      when is_binary(agent_uid) and is_binary(owner_session_id) and is_integer(job_id) and
             job_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_owned_job(repo, agent_uid, owner_session_id, job_id) do
        %Job{status: "active"} = job ->
          with {:ok, job} <-
                 job
                 |> Job.changeset(%{status: "cancelled", cancelled_at: now})
                 |> repo.update() do
            Run
            |> where([run], run.automation_job_id == ^job.id and run.status == "queued")
            |> repo.update_all(
              set: [
                status: "cancelled",
                attempt_id: nil,
                finished_at: now,
                error: "automation job was cancelled",
                updated_at: now
              ]
            )

            {:ok, %{status: :cancelled, automation_job: job}}
          end

        %Job{} = job ->
          {:ok, %{status: :already_terminal, automation_job: job}}

        nil ->
          {:error, :automation_job_not_found}
      end
    end)
  end

  def cancel_job(_agent_uid, _owner_session_id, _job_id, _opts),
    do: {:error, :automation_job_not_found}

  @doc """
  Confirms that an active job belongs to the Agent that owns a trigger.
  """
  @spec validate_bindable_in_tx(module(), pos_integer() | nil, String.t(), DateTime.t()) ::
          :ok | {:error, term()}
  def validate_bindable_in_tx(_repo, nil, _agent_uid, _now), do: :ok

  def validate_bindable_in_tx(repo, job_id, agent_uid, now)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) do
    normalized_agent_uid = String.downcase(agent_uid)

    case lock_job(repo, job_id) do
      %Job{agent_uid: owner_uid} = job when owner_uid == normalized_agent_uid ->
        case effective_status(repo, job, now) do
          {:ok, %Job{status: "active"}} -> :ok
          {:ok, %Job{status: status}} -> {:error, {:automation_job_not_active, status}}
          {:error, _reason} = error -> error
        end

      %Job{} ->
        {:error, :automation_job_not_owned}

      nil ->
        {:error, :automation_job_not_found}
    end
  end

  def validate_bindable_in_tx(_repo, _job_id, _agent_uid, _now),
    do: {:error, :invalid_automation_job_id}

  @doc """
  Inserts one durable run and its Oban wake edge in the caller's transaction.
  """
  @spec enqueue_run_in_tx(module(), pos_integer(), String.t(), map(), keyword()) ::
          {:ok, enqueue_result()} | {:error, term()}
  def enqueue_run_in_tx(repo, job_id, agent_uid, event, opts \\ [])

  def enqueue_run_in_tx(repo, job_id, agent_uid, event, opts)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and is_map(event) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    with %Job{} = job <- lock_job(repo, job_id),
         true <- job.agent_uid == String.downcase(agent_uid),
         {:ok, job} <- effective_status(repo, job, now),
         {:ok, event} <- normalize_event(event) do
      enqueue_for_status(repo, job, event, now, opts)
    else
      nil -> {:error, :automation_job_not_found}
      false -> {:error, :automation_job_not_owned}
      {:error, _reason} = error -> error
    end
  end

  def enqueue_run_in_tx(_repo, _job_id, _agent_uid, _event, _opts),
    do: {:error, :invalid_automation_job_run}

  @doc false
  @spec start_attempt(pos_integer(), keyword()) ::
          {:ok, :noop | %{automation_job: Job.t(), run: Run.t()}} | {:error, term()}
  def start_attempt(run_id, opts \\ []) when is_integer(run_id) and run_id > 0 do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      case lock_run(repo, run_id) do
        %Run{status: status} when status in ~w(succeeded failed cancelled) ->
          {:ok, :noop}

        %Run{} = run ->
          with %Job{} = job <- lock_job(repo, run.automation_job_id),
               {:ok, job} <- effective_status(repo, job, now) do
            start_for_status(repo, job, run, now)
          else
            nil -> {:error, :automation_job_not_found}
            {:error, _reason} = error -> error
          end

        nil ->
          {:error, :automation_job_run_not_found}
      end
    end)
  end

  @doc false
  @spec finish_attempt(pos_integer(), Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Run.t() | :stale} | {:error, term()}
  def finish_attempt(run_id, attempt_id, result, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_binary(attempt_id) and is_map(result) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %Run{} = run <- lock_run(repo, run_id),
           true <- active_attempt?(run, attempt_id),
           %Job{} = job <- lock_job(repo, run.automation_job_id),
           {:ok, attrs} <- completion_attrs(result, now),
           {:ok, run} <- run |> Run.changeset(attrs) |> repo.update(),
           :ok <- maybe_append_failure_event(repo, job, run, now) do
        {:ok, run}
      else
        nil -> {:error, :automation_job_run_not_found}
        false -> {:ok, :stale}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc false
  @spec infrastructure_failure(
          pos_integer(),
          Ecto.UUID.t(),
          term(),
          :retry | :exhausted,
          keyword()
        ) :: {:ok, Run.t() | :stale} | {:error, term()}
  def infrastructure_failure(run_id, attempt_id, reason, disposition, opts \\ [])
      when is_integer(run_id) and run_id > 0 and is_binary(attempt_id) and
             disposition in [:retry, :exhausted] do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))
    error = bounded_text("infrastructure dispatch failed: #{inspect(reason)}", @log_max_bytes)

    Repo.transact(fn repo ->
      with %Run{} = run <- lock_run(repo, run_id),
           true <- active_attempt?(run, attempt_id),
           %Job{} = job <- lock_job(repo, run.automation_job_id),
           {:ok, run} <-
             run
             |> Run.changeset(infrastructure_failure_attrs(disposition, error, now))
             |> repo.update(),
           :ok <- maybe_append_failure_event(repo, job, run, now) do
        {:ok, run}
      else
        nil -> {:error, :automation_job_run_not_found}
        false -> {:ok, :stale}
        {:error, _reason} = error -> error
      end
    end)
  end

  @doc """
  Appends one durable owner-session event from a live run attempt.
  """
  @spec emit_event(
          String.t(),
          pos_integer(),
          Ecto.UUID.t(),
          term(),
          keyword()
        ) :: {:ok, Ankole.SignalsGateway.ActorEvent.t()} | {:error, term()}
  def emit_event(agent_uid, run_id, attempt_id, payload, opts \\ [])

  def emit_event(agent_uid, run_id, attempt_id, payload, opts)
      when is_binary(agent_uid) and is_integer(run_id) and run_id > 0 and
             is_binary(attempt_id) do
    now = Keyword.get(opts, :now, DateTime.utc_now(:microsecond))

    Repo.transact(fn repo ->
      with %Run{} = run <- lock_run(repo, run_id),
           true <- active_attempt?(run, attempt_id),
           %Job{} = job <- lock_job(repo, run.automation_job_id),
           true <- job.agent_uid == String.downcase(agent_uid),
           {:ok, payload} <- normalize_emitted_payload(payload),
           {:ok, actor_event} <-
             append_owner_event(repo, job, "automation_job.emitted", now, %{
               "automation_job" => %{"id" => job.id, "label" => job.label},
               "automation_job_run_id" => run.id,
               "payload" => payload
             }) do
        {:ok, actor_event}
      else
        nil -> {:error, :automation_job_run_not_found}
        false -> {:error, :automation_job_attempt_not_active}
        {:error, _reason} = error -> error
      end
    end)
  end

  def emit_event(_agent_uid, _run_id, _attempt_id, _payload, _opts),
    do: {:error, :invalid_automation_job_emit}

  @doc """
  Returns one job and its recent run history for the owning Agent session, or
  for any session of the Agent when `owner_session_id` is `nil`.
  """
  @spec show_job(String.t(), String.t() | nil, pos_integer(), keyword()) ::
          {:ok, %{automation_job: Job.t(), runs: [Run.t()]}} | {:error, term()}
  def show_job(agent_uid, owner_session_id, job_id, opts \\ []) do
    with {:ok, %Job{} = job} <- get_job(agent_uid, owner_session_id, job_id) do
      limit = opts |> Keyword.get(:runs, 20) |> bounded_limit(100, 20)

      runs =
        Run
        |> where([run], run.automation_job_id == ^job.id)
        |> order_by([run], desc: run.inserted_at, desc: run.id)
        |> limit(^limit)
        |> Repo.all()

      {:ok, %{automation_job: job, runs: runs}}
    end
  end

  @doc """
  Returns the model-safe summary of one automation job.
  """
  @spec model_projection(Job.t()) :: map()
  def model_projection(%Job{} = job) do
    %{
      "id" => job.id,
      "label" => job.label,
      "status" => job.status,
      "wake_on_failure" => job.wake_on_failure,
      "created_at" => iso8601(job.inserted_at)
    }
    |> maybe_put("expires_at", iso8601(job.expires_at))
  end

  @doc """
  Returns the model-safe detail and bounded run history.
  """
  @spec model_detail_projection(Job.t(), [Run.t()]) :: map()
  def model_detail_projection(%Job{} = job, runs) when is_list(runs) do
    %{
      "automation_job" => %{
        "id" => job.id,
        "agent_uid" => job.agent_uid,
        "owner_session_id" => job.owner_session_id,
        "source_actor_event_id" => job.source_actor_event_id,
        "source_entry_id" => job.source_entry_id,
        "source_provenance" => job.source_provenance || %{},
        "reply_route" => job.reply_route || %{},
        "directory_path" => job.directory_path,
        "label" => job.label,
        "wake_on_failure" => job.wake_on_failure,
        "status" => job.status,
        "expires_at" => iso8601(job.expires_at),
        "cancelled_at" => iso8601(job.cancelled_at),
        "created_at" => iso8601(job.inserted_at),
        "updated_at" => iso8601(job.updated_at)
      },
      "runs" => Enum.map(runs, &run_projection/1)
    }
  end

  @doc """
  Returns a Console-safe detail projection.
  """
  @spec console_projection(Job.t(), [Run.t()]) :: map()
  def console_projection(%Job{} = job, runs \\ []) do
    detail = model_detail_projection(job, runs)
    Map.put(detail["automation_job"], "runs", detail["runs"])
  end

  defp enqueue_for_status(repo, %Job{status: "active"} = job, event, _now, opts) do
    with {:ok, run} <-
           %Run{}
           |> Run.changeset(%{
             automation_job_id: job.id,
             event: event,
             status: "queued",
             attempts: 0
           })
           |> repo.insert(),
         {:ok, oban_job} <- insert_execution_job(run, opts),
         {:ok, run} <-
           run
           |> Run.changeset(%{oban_job_id: oban_job.id})
           |> repo.update() do
      {:ok, %{status: :queued, automation_job_run: run}}
    end
  end

  defp enqueue_for_status(repo, %Job{status: status} = job, event, now, _opts) do
    error = "automation job is #{status}"

    with {:ok, run} <-
           %Run{}
           |> Run.changeset(%{
             automation_job_id: job.id,
             event: event,
             status: "failed",
             attempts: 0,
             finished_at: now,
             error: error
           })
           |> repo.insert(),
         :ok <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, %{status: :failed, automation_job_run: run}}
    end
  end

  defp insert_execution_job(%Run{} = run, opts) do
    insert = Keyword.get(opts, :wake_insert, &Oban.insert/1)

    run.id
    |> then(&ExecuteRun.new(%{"automation_job_run_id" => &1}))
    |> insert.()
  end

  defp start_for_status(repo, %Job{status: "active"} = job, run, now) do
    attempt_id = Ecto.UUID.generate()

    with {:ok, run} <-
           run
           |> Run.changeset(%{
             status: "running",
             attempts: run.attempts + 1,
             attempt_id: attempt_id,
             started_at: run.started_at || now,
             last_attempt_at: now,
             finished_at: nil,
             error: nil
           })
           |> repo.update() do
      {:ok, %{automation_job: job, run: run}}
    end
  end

  defp start_for_status(repo, %Job{status: status} = job, run, now) do
    with {:ok, run} <-
           run
           |> Run.changeset(%{
             status: "failed",
             attempt_id: nil,
             finished_at: now,
             error: "automation job is #{status}"
           })
           |> repo.update(),
         :ok <- maybe_append_failure_event(repo, job, run, now) do
      {:ok, :noop}
    end
  end

  defp completion_attrs(result, now) do
    status = value(result, "status")

    if status in ["succeeded", "failed"] do
      {:ok,
       %{
         status: status,
         attempt_id: nil,
         finished_at: now,
         exit_code: value(result, "exit_code"),
         error: bounded_nullable_text(value(result, "error"), @log_max_bytes),
         stdout: bounded_text(value(result, "stdout") || "", @log_max_bytes),
         stderr: bounded_text(value(result, "stderr") || "", @log_max_bytes),
         stdout_truncated: value(result, "stdout_truncated") == true,
         stderr_truncated: value(result, "stderr_truncated") == true
       }}
    else
      {:error, :invalid_automation_job_result}
    end
  end

  defp infrastructure_failure_attrs(:retry, error, _now) do
    %{status: "queued", attempt_id: nil, error: error}
  end

  defp infrastructure_failure_attrs(:exhausted, error, now) do
    %{status: "failed", attempt_id: nil, finished_at: now, error: error}
  end

  defp maybe_append_failure_event(_repo, _job, %Run{status: status}, _now)
       when status != "failed",
       do: :ok

  defp maybe_append_failure_event(_repo, %Job{wake_on_failure: false}, %Run{}, _now),
    do: :ok

  defp maybe_append_failure_event(repo, %Job{} = job, %Run{} = run, now) do
    case append_owner_event(repo, job, "automation_job.run_failed", now, %{
           "automation_job" => %{"id" => job.id, "label" => job.label},
           "automation_job_run_id" => run.id,
           "attempts" => run.attempts,
           "error" => run.error || "automation job run failed"
         }) do
      {:ok, _actor_event} -> :ok
      {:error, _reason} = error -> error
    end
  end

  defp append_owner_event(repo, job, type, now, data) do
    source_event_id =
      "automation-job:#{job.id}:run:#{data["automation_job_run_id"]}:#{type}:#{Ecto.UUID.generate()}"

    SignalsGateway.append_actor_event_in_tx(repo, %{
      agent_uid: job.agent_uid,
      binding_name: route_text(job.reply_route, "binding_name"),
      session_id: job.owner_session_id,
      source_event_id: source_event_id,
      signal_channel_id: route_text(job.reply_route, "signal_channel_id"),
      provider_thread_id: route_text(job.reply_route, "provider_thread_id"),
      source_entry_id: route_text(job.reply_route, "source_entry_id") || job.source_entry_id,
      type: type,
      available_at: now,
      sender_key: nil,
      payload: %{
        "specversion" => "1.0",
        "id" => source_event_id,
        "source" => "control-plane://automation-jobs/#{job.id}",
        "subject" => "automation_job_run:#{data["automation_job_run_id"]}",
        "time" => DateTime.to_iso8601(now),
        "type" => type,
        "data" => data
      }
    })
  end

  defp normalize_event(event) do
    with {:ok, event} <- JSONPayload.normalize_map(event),
         true <- byte_size(Ankole.JSON.encode!(event)) <= @payload_max_bytes do
      {:ok, event}
    else
      false -> {:error, :automation_job_event_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp normalize_emitted_payload(payload) do
    with {:ok, payload} <- JSONPayload.normalize(payload),
         true <- byte_size(Ankole.JSON.encode!(payload)) <= @payload_max_bytes do
      {:ok, payload}
    else
      false -> {:error, :automation_job_payload_too_large}
      {:error, _reason} = error -> error
    end
  end

  defp effective_status(
         repo,
         %Job{status: "active", expires_at: %DateTime{} = expires_at} = job,
         now
       ) do
    if DateTime.compare(expires_at, now) == :gt do
      {:ok, job}
    else
      job
      |> Job.changeset(%{status: "expired"})
      |> repo.update()
    end
  end

  defp effective_status(_repo, %Job{} = job, _now), do: {:ok, job}

  defp lock_owned_job(repo, agent_uid, owner_session_id, job_id) do
    Job
    |> where(
      [job],
      job.id == ^job_id and job.agent_uid == ^String.downcase(agent_uid) and
        job.owner_session_id == ^owner_session_id
    )
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_job(repo, job_id) do
    Job
    |> where([job], job.id == ^job_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp lock_run(repo, run_id) do
    Run
    |> where([run], run.id == ^run_id)
    |> lock("FOR UPDATE")
    |> repo.one()
  end

  defp active_attempt?(%Run{status: "running", attempt_id: attempt_id}, attempt_id), do: true
  defp active_attempt?(_run, _attempt_id), do: false

  defp run_projection(%Run{} = run) do
    %{
      "id" => run.id,
      "status" => run.status,
      "attempts" => run.attempts,
      "started_at" => iso8601(run.started_at),
      "finished_at" => iso8601(run.finished_at),
      "exit_code" => run.exit_code,
      "error" => first_line(run.error),
      "stdout" => with_truncation_marker(run.stdout, run.stdout_truncated),
      "stderr" => with_truncation_marker(run.stderr, run.stderr_truncated)
    }
  end

  defp with_truncation_marker(text, true), do: (text || "") <> "\n...[truncated]"
  defp with_truncation_marker(text, false), do: text || ""

  defp first_line(nil), do: nil
  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  defp bounded_nullable_text(nil, _max_bytes), do: nil
  defp bounded_nullable_text(text, max_bytes), do: bounded_text(text, max_bytes)

  defp bounded_text(text, max_bytes) when is_binary(text) and byte_size(text) <= max_bytes,
    do: text

  defp bounded_text(text, max_bytes) when is_binary(text) do
    text
    |> binary_part(byte_size(text) - max_bytes, max_bytes)
    |> trim_invalid_utf8_prefix()
  end

  defp bounded_text(text, max_bytes), do: text |> inspect() |> bounded_text(max_bytes)

  defp trim_invalid_utf8_prefix(<<>>), do: ""

  defp trim_invalid_utf8_prefix(text) do
    if String.valid?(text) do
      text
    else
      <<_byte, rest::binary>> = text
      trim_invalid_utf8_prefix(rest)
    end
  end

  defp route_text(route, key) when is_map(route) do
    case Map.get(route, key) || Map.get(route, String.to_atom(key)) do
      value when is_binary(value) and value != "" -> value
      _value -> nil
    end
  end

  defp route_text(_route, _key), do: nil

  defp normalize_agent_uid(attrs) do
    case value(attrs, "agent_uid") do
      agent_uid when is_binary(agent_uid) ->
        attrs
        |> Map.delete("agent_uid")
        |> Map.delete(:agent_uid)
        |> Map.put(:agent_uid, String.downcase(agent_uid))

      _value ->
        attrs
    end
  end

  defp value(map, key) when is_map(map),
    do: Map.get(map, key) || Map.get(map, String.to_atom(key))

  defp bounded_limit(value, max, _default) when is_integer(value) and value > 0,
    do: min(value, max)

  defp bounded_limit(_value, _max, default), do: default

  defp maybe_where_owner_session(query, nil), do: query

  defp maybe_where_owner_session(query, owner_session_id),
    do: where(query, [job], job.owner_session_id == ^owner_session_id)

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp iso8601(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp iso8601(_value), do: nil
end
