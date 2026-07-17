defmodule Ankole.BackgroundAgentJobs.Queries do
  @moduledoc false

  import Ecto.Query

  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Turns

  @statuses Job.statuses()

  @spec list_for_channel(String.t(), String.t(), String.t() | nil) :: [Job.t()]
  def list_for_channel(agent_uid, owner_session_id, signal_channel_id)
      when is_binary(agent_uid) and is_binary(owner_session_id) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      Job
      |> where([job], job.agent_uid == ^agent_uid)
      |> visible_from_owner(owner_session_id, signal_channel_id)
      |> order_by([job], desc: job.queued_at, desc: job.inserted_at)
      |> limit(100)
      |> Repo.all()
    else
      {:error, _reason} -> []
    end
  end

  @spec list_for_console(keyword()) ::
          {:ok, %{jobs: [Job.t()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_for_console(opts \\ []) when is_list(opts) do
    with {:ok, agent_uid} <- console_agent_uid(Keyword.get(opts, :agent_uid)),
         {:ok, status} <- console_status(Keyword.get(opts, :status)),
         {:ok, cursor} <- decode_console_cursor(Keyword.get(opts, :cursor)) do
      limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)

      rows =
        Job
        |> maybe_filter_console_agent(agent_uid)
        |> maybe_filter_console_status(status)
        |> maybe_before_console_cursor(cursor)
        |> order_by([job], desc: job.queued_at, desc: job.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          page |> List.last() |> encode_console_cursor()
        end

      {:ok, %{jobs: page, next_cursor: next_cursor}}
    end
  end

  @spec get(String.t()) :: Job.t() | nil
  def get(job_id) when is_binary(job_id) do
    case Ecto.UUID.cast(job_id) do
      {:ok, job_id} ->
        Repo.get(Job, job_id)

      :error ->
        nil
    end
  end

  @spec get_for_agent(String.t() | nil, String.t()) :: Job.t() | nil
  def get_for_agent(nil, _agent_uid), do: nil

  def get_for_agent(job_id, agent_uid)
      when is_binary(job_id) and is_binary(agent_uid) do
    get_for_agent(Repo, job_id, agent_uid, [])
  end

  @doc false
  @spec get_for_agent(module(), String.t(), String.t(), keyword()) :: Job.t() | nil
  def get_for_agent(repo, job_id, agent_uid, opts)
      when is_binary(job_id) and is_binary(agent_uid) do
    case Ecto.UUID.cast(job_id) do
      {:ok, job_id} ->
        query =
          from job in Job,
            where: job.id == ^job_id and job.agent_uid == ^agent_uid

        query
        |> maybe_lock(Keyword.get(opts, :lock))
        |> repo.one()

      :error ->
        nil
    end
  end

  @spec get_summary_for_agent(String.t(), String.t(), keyword()) ::
          {:ok,
           %{
             job: Job.t(),
             execution: map(),
             attempt_history: [map()]
           }}
          | {:error, term()}
  def get_summary_for_agent(job_id, agent_uid, opts \\ [])
      when is_binary(job_id) and is_binary(agent_uid) and is_list(opts) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         %Job{} = job <- get_for_agent(job_id, agent_uid),
         {:ok, execution} <- Turns.execution_projection(job, opts) do
      {:ok,
       %{
         job: job,
         execution: execution,
         attempt_history: Turns.attempt_history(job)
       }}
    else
      nil -> {:error, :job_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec console_projection(Job.t()) :: map()
  def console_projection(%Job{} = job) do
    %{
      id: job.id,
      agent_uid: job.agent_uid,
      owner_session_id: job.owner_session_id,
      source_actor_event_id: job.source_actor_event_id,
      source_tool_call_id: job.source_tool_call_id,
      codex_account_id: job.codex_account_id,
      runtime_thread_id: job.runtime_thread_id,
      title: job.title,
      task: job.task,
      background: job.background,
      notes: job.notes,
      status: job.status,
      attempts: job.attempts,
      agent_plugin_ids: job.agent_plugin_ids,
      skill_names: job.skill_names,
      workspace_mounts: job.workspace_mounts,
      model: job.model,
      reasoning_effort: job.reasoning_effort,
      reply_route: job.reply_route || %{},
      result: job.result || %{},
      error: job.error || %{},
      metadata: job.metadata || %{},
      duration_seconds: duration_seconds(job),
      queued_at: iso8601(job.queued_at),
      started_at: iso8601(job.started_at),
      completed_at: iso8601(job.completed_at),
      inserted_at: iso8601(job.inserted_at),
      updated_at: iso8601(job.updated_at)
    }
  end

  defp visible_from_owner(query, owner_session_id, signal_channel_id)
       when is_binary(signal_channel_id) and signal_channel_id != "" do
    where(
      query,
      [job],
      job.owner_session_id == ^owner_session_id or
        fragment("?->>'signal_channel_id' = ?", job.reply_route, ^signal_channel_id)
    )
  end

  defp visible_from_owner(query, owner_session_id, _signal_channel_id) do
    where(query, [job], job.owner_session_id == ^owner_session_id)
  end

  defp console_agent_uid(nil), do: {:ok, nil}
  defp console_agent_uid(""), do: {:ok, nil}
  defp console_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp console_status(nil), do: {:ok, nil}
  defp console_status(""), do: {:ok, nil}
  defp console_status(status) when status in @statuses, do: {:ok, status}
  defp console_status(_status), do: {:error, :invalid_background_agent_job_status}

  defp maybe_filter_console_agent(query, nil), do: query

  defp maybe_filter_console_agent(query, agent_uid),
    do: where(query, [job], job.agent_uid == ^agent_uid)

  defp maybe_filter_console_status(query, nil), do: query

  defp maybe_filter_console_status(query, status),
    do: where(query, [job], job.status == ^status)

  defp maybe_before_console_cursor(query, nil), do: query

  defp maybe_before_console_cursor(query, {queued_at, id}) do
    where(
      query,
      [job],
      job.queued_at < ^queued_at or
        (job.queued_at == ^queued_at and job.id < ^id)
    )
  end

  defp encode_console_cursor(nil), do: nil

  defp encode_console_cursor(%Job{} = job) do
    "#{DateTime.to_iso8601(job.queued_at)}|#{job.id}"
    |> Base.url_encode64(padding: false)
  end

  defp decode_console_cursor(nil), do: {:ok, nil}
  defp decode_console_cursor(""), do: {:ok, nil}

  defp decode_console_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [queued_at_text, id] <- String.split(decoded, "|", parts: 2),
         {:ok, queued_at, _offset} <- DateTime.from_iso8601(queued_at_text),
         {:ok, id} <- Ecto.UUID.cast(id) do
      {:ok, {queued_at, id}}
    else
      _reason -> {:error, :invalid_background_agent_job_cursor}
    end
  end

  defp decode_console_cursor(_cursor), do: {:error, :invalid_background_agent_job_cursor}

  defp duration_seconds(%Job{} = job) do
    case {job.started_at || job.queued_at, job.completed_at} do
      {%DateTime{} = started_at, %DateTime{} = completed_at} ->
        max(DateTime.diff(completed_at, started_at, :second), 0)

      {%DateTime{} = started_at, nil} ->
        max(DateTime.diff(now(), started_at, :second), 0)

      _value ->
        0
    end
  end

  defp iso8601(nil), do: nil
  defp iso8601(%DateTime{} = datetime), do: DateTime.to_iso8601(datetime)

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")
  defp now, do: DateTime.utc_now(:microsecond)
end
