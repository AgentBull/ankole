defmodule Ankole.BackgroundAgentJobs.Queries do
  @moduledoc false

  import Ecto.Query

  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Principals
  alias Ankole.Repo

  @statuses Job.statuses()
  @list_cursor_version "1"
  @list_page_size 32
  @list_query_limit @list_page_size + 1
  @ambient_candidate_limit 8
  @ambient_candidate_query_limit @ambient_candidate_limit + 1
  @list_statuses %{
    "live" => ~w(queued running waiting_on_user),
    "stop" => ~w(succeeded failed stopped)
  }
  @result_read_columns [:id, :agent_uid, :owner_session_id, :status, :title, :reply_route]
  @result_window_bytes 16_384

  @type list_item :: %{
          job_id: pos_integer(),
          title: String.t(),
          status: String.t()
        }

  @spec list_for_agent(String.t(), keyword()) ::
          {:ok, %{jobs: [list_item()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_for_agent(agent_uid, opts \\ []) when is_binary(agent_uid) and is_list(opts) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         {:ok, status} <- list_status(Keyword.get(opts, :status)),
         {:ok, cursor} <- decode_list_cursor(Keyword.get(opts, :cursor), status) do
      statuses = Map.fetch!(@list_statuses, status)

      rows =
        Job
        |> where([job], job.agent_uid == ^agent_uid)
        |> where([job], job.status in ^statuses)
        |> maybe_before_list_cursor(cursor)
        |> order_by([job], desc: job.updated_at, desc: job.id)
        |> limit(@list_query_limit)
        |> Repo.all()

      page = Enum.take(rows, @list_page_size)
      jobs = Enum.map(page, &list_projection/1)

      next_cursor =
        if length(rows) > @list_page_size do
          page |> List.last() |> encode_list_cursor(status)
        end

      {:ok, %{jobs: jobs, next_cursor: next_cursor}}
    end
  end

  @doc false
  @spec ambient_candidates_in_tx(
          module(),
          String.t(),
          String.t(),
          String.t(),
          String.t()
        ) :: %{complete: boolean(), jobs: [map()]}
  def ambient_candidates_in_tx(
        repo,
        agent_uid,
        owner_session_id,
        signal_channel_id,
        binding_name
      )
      when is_binary(agent_uid) and is_binary(owner_session_id) and
             is_binary(signal_channel_id) and is_binary(binding_name) do
    rows =
      Job
      |> where([job], job.agent_uid == ^agent_uid)
      |> where([job], job.owner_session_id == ^owner_session_id)
      |> where([job], job.status in ~w(queued running waiting_on_user))
      |> where(
        [job],
        fragment("?->>'signal_channel_id' = ?", job.reply_route, ^signal_channel_id)
      )
      |> where([job], fragment("?->>'binding_name' = ?", job.reply_route, ^binding_name))
      |> excluding_reflection_jobs()
      |> order_by([job], desc: job.updated_at, desc: job.id)
      |> limit(@ambient_candidate_query_limit)
      |> select([job], %{
        job_id: job.id,
        title: job.title,
        status: job.status,
        task_excerpt: fragment("left(?, 600)", job.task)
      })
      |> repo.all()

    %{
      complete: length(rows) <= @ambient_candidate_limit,
      jobs: Enum.take(rows, @ambient_candidate_limit)
    }
  end

  # A Console list page holds up to 100 jobs and reloads every few seconds, so it
  # reads only the columns the board and the home panel draw. The queued prompt,
  # the result, the error, and the metadata are unbounded in the work the job
  # did, and none of them reach the screen before the operator opens one card.
  @console_list_columns [
    :id,
    :agent_uid,
    :title,
    :status,
    :attempts,
    :execution_failures,
    :workspace_template_id,
    :queued_at,
    :started_at,
    :completed_at,
    :inserted_at
  ]

  @spec list_for_console(keyword()) ::
          {:ok, %{jobs: [map()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_for_console(opts \\ []) when is_list(opts) do
    with {:ok, agent_uid} <- console_agent_uid(Keyword.get(opts, :agent_uid)),
         {:ok, status} <- console_status(Keyword.get(opts, :status)),
         {:ok, search} <- console_search(Keyword.get(opts, :search)),
         {:ok, cursor} <- decode_console_cursor(Keyword.get(opts, :cursor)) do
      limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)

      rows =
        Job
        |> maybe_filter_console_agent(agent_uid)
        |> maybe_filter_console_status(status)
        |> maybe_filter_console_search(search)
        |> maybe_before_console_cursor(cursor)
        |> order_by([job], desc: job.queued_at, desc: job.id)
        |> limit(^(limit + 1))
        |> select([job], map(job, ^@console_list_columns))
        |> Repo.all()

      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          page |> List.last() |> encode_console_cursor()
        end

      {:ok, %{jobs: page, next_cursor: next_cursor}}
    end
  end

  @spec get(pos_integer()) :: Job.t() | nil
  def get(job_id) when is_integer(job_id) and job_id > 0, do: Repo.get(Job, job_id)

  @doc "Lists live Job ids owned by any of the given actor sessions."
  @spec live_job_ids_for_owner_sessions([String.t()], String.t()) :: [pos_integer()]
  def live_job_ids_for_owner_sessions([], _agent_uid), do: []

  def live_job_ids_for_owner_sessions(session_ids, agent_uid)
      when is_list(session_ids) and is_binary(agent_uid) do
    Job
    |> where(
      [job],
      job.agent_uid == ^agent_uid and job.owner_session_id in ^session_ids and
        job.status in ["queued", "running", "waiting_on_user"]
    )
    |> order_by([job], asc: job.id)
    |> select([job], job.id)
    |> Repo.all()
  end

  @spec get_for_agent(pos_integer() | nil, String.t()) :: Job.t() | nil
  def get_for_agent(nil, _agent_uid), do: nil

  def get_for_agent(job_id, agent_uid)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) do
    get_for_agent(Repo, job_id, agent_uid, [])
  end

  @doc false
  @spec get_for_agent(module(), pos_integer(), String.t(), keyword()) :: Job.t() | nil
  def get_for_agent(repo, job_id, agent_uid, opts)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) do
    query =
      from job in Job,
        where: job.id == ^job_id and job.agent_uid == ^agent_uid

    query
    |> maybe_lock(Keyword.get(opts, :lock))
    |> repo.one()
  end

  @spec get_result_window_for_agent(pos_integer(), String.t(), non_neg_integer()) ::
          %{job: Job.t(), output_window: binary() | nil, total_bytes: non_neg_integer() | nil}
          | nil
  def get_result_window_for_agent(job_id, agent_uid, offset)
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and is_integer(offset) and
             offset >= 0 do
    query =
      from job in Job,
        where: job.id == ^job_id and job.agent_uid == ^agent_uid,
        select: {
          map(job, ^@result_read_columns),
          fragment(
            "substring(convert_to(?->>'output_text', 'UTF8') from ? for ?)",
            job.result,
            ^(offset + 1),
            ^@result_window_bytes
          ),
          fragment("octet_length(?->>'output_text')", job.result)
        }

    case Repo.one(query) do
      {job, output_window, total_bytes} ->
        %{job: struct(Job, job), output_window: output_window, total_bytes: total_bytes}

      nil ->
        nil
    end
  end

  @spec get_summary_for_agent(pos_integer(), String.t(), keyword()) ::
          {:ok,
           %{
             job: Job.t(),
             execution: map(),
             attempt_history: [map()]
           }}
          | {:error, term()}
  def get_summary_for_agent(job_id, agent_uid, opts \\ [])
      when is_integer(job_id) and job_id > 0 and is_binary(agent_uid) and is_list(opts) do
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
    job
    |> base_projection()
    |> Map.merge(%{
      duration_seconds: duration_seconds(job),
      inserted_at: iso8601(job.inserted_at),
      updated_at: iso8601(job.updated_at)
    })
  end

  @doc "Projects one `list_for_console/1` row into the named Console list contract."
  @spec console_list_projection(map()) :: map()
  def console_list_projection(row) do
    %{
      id: row.id,
      agent_uid: row.agent_uid,
      title: row.title,
      status: row.status,
      attempts: row.attempts,
      execution_failures: row.execution_failures,
      workspace_template_id: row.workspace_template_id,
      duration_seconds: duration_seconds(row),
      inserted_at: iso8601(row.inserted_at)
    }
  end

  # Console field list; the RuntimeFabric RPC view is the generated
  # BackgroundAgentJobResponse message built by the RPC broker.
  defp base_projection(%Job{} = job) do
    %{
      id: job.id,
      agent_uid: job.agent_uid,
      owner_session_id: job.owner_session_id,
      source_actor_event_id: job.source_actor_event_id,
      source_tool_call_id: job.source_tool_call_id,
      runtime_thread_id: job.runtime_thread_id,
      title: job.title,
      task: job.task,
      status: job.status,
      attempts: job.attempts,
      execution_failures: job.execution_failures,
      workspace_template_id: job.workspace_template_id,
      model_profile: job.model_profile,
      reply_route: job.reply_route || %{},
      result: job.result || %{},
      error: job.error || %{},
      metadata: job.metadata || %{},
      queued_at: iso8601(job.queued_at),
      started_at: iso8601(job.started_at),
      completed_at: iso8601(job.completed_at)
    }
  end

  defp list_status(nil), do: {:ok, "live"}
  defp list_status(""), do: {:ok, "live"}
  defp list_status(status) when is_map_key(@list_statuses, status), do: {:ok, status}
  defp list_status(_status), do: {:error, :invalid_background_agent_job_list_status}

  defp maybe_before_list_cursor(query, nil), do: query

  defp maybe_before_list_cursor(query, {updated_at, id}) do
    where(
      query,
      [job],
      job.updated_at < ^updated_at or
        (job.updated_at == ^updated_at and job.id < ^id)
    )
  end

  defp encode_list_cursor(%Job{} = job, status) do
    [@list_cursor_version, status, DateTime.to_iso8601(job.updated_at), job.id]
    |> Enum.join("|")
    |> Base.url_encode64(padding: false)
  end

  defp decode_list_cursor(nil, _status), do: {:ok, nil}
  defp decode_list_cursor("", _status), do: {:ok, nil}

  defp decode_list_cursor(cursor, status) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [@list_cursor_version, ^status, updated_at_text, id] <-
           String.split(decoded, "|", parts: 4),
         {:ok, updated_at, _offset} <- DateTime.from_iso8601(updated_at_text),
         {:ok, id} <- parse_cursor_id(id) do
      {:ok, {updated_at, id}}
    else
      _reason -> {:error, :invalid_background_agent_job_cursor}
    end
  end

  defp decode_list_cursor(_cursor, _status),
    do: {:error, :invalid_background_agent_job_cursor}

  defp list_projection(%Job{} = job) do
    %{
      job_id: job.id,
      title: job.title,
      status: job.status
    }
  end

  defp console_agent_uid(nil), do: {:ok, nil}
  defp console_agent_uid(""), do: {:ok, nil}
  defp console_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp console_status(nil), do: {:ok, nil}
  defp console_status(""), do: {:ok, nil}
  defp console_status(status) when status in @statuses, do: {:ok, status}
  defp console_status(_status), do: {:error, :invalid_background_agent_job_status}

  defp console_search(nil), do: {:ok, nil}

  defp console_search(search) when is_binary(search) do
    case String.trim(search) do
      "" ->
        {:ok, nil}

      text ->
        if(String.length(text) <= 200,
          do: {:ok, text},
          else: {:error, :invalid_background_agent_job_search}
        )
    end
  end

  defp console_search(_search), do: {:error, :invalid_background_agent_job_search}

  defp maybe_filter_console_agent(query, nil), do: query

  defp maybe_filter_console_agent(query, agent_uid),
    do: where(query, [job], job.agent_uid == ^agent_uid)

  defp maybe_filter_console_status(query, nil), do: query

  defp maybe_filter_console_status(query, status),
    do: where(query, [job], job.status == ^status)

  defp maybe_filter_console_search(query, nil), do: query

  defp maybe_filter_console_search(query, search) do
    pattern = "%#{escape_like(search)}%"

    case Integer.parse(search) do
      {id, ""} when id in 1000..9_007_199_254_740_991 ->
        where(query, [job], job.id == ^id or ilike(job.title, ^pattern))

      _not_an_id ->
        where(query, [job], ilike(job.title, ^pattern))
    end
  end

  defp escape_like(text) do
    text
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

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

  defp encode_console_cursor(%{queued_at: queued_at, id: id}) do
    "#{DateTime.to_iso8601(queued_at)}|#{id}"
    |> Base.url_encode64(padding: false)
  end

  defp decode_console_cursor(nil), do: {:ok, nil}
  defp decode_console_cursor(""), do: {:ok, nil}

  defp decode_console_cursor(cursor) when is_binary(cursor) do
    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         [queued_at_text, id] <- String.split(decoded, "|", parts: 2),
         {:ok, queued_at, _offset} <- DateTime.from_iso8601(queued_at_text),
         {:ok, id} <- parse_cursor_id(id) do
      {:ok, {queued_at, id}}
    else
      _reason -> {:error, :invalid_background_agent_job_cursor}
    end
  end

  defp decode_console_cursor(_cursor), do: {:error, :invalid_background_agent_job_cursor}

  defp parse_cursor_id(value) do
    case Integer.parse(value) do
      {id, ""} when id in 1000..9_007_199_254_740_991 -> {:ok, id}
      _parsed -> :error
    end
  end

  defp duration_seconds(job) do
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

  @doc """
  Keeps only skill-lesson reflection Jobs: the system Jobs the Brain runs to
  reflect on finished work. The metadata flag at
  `Ankole.Brain.SkillLessons` is the writer.
  """
  @spec reflection_jobs(Ecto.Queryable.t()) :: Ecto.Query.t()
  def reflection_jobs(query) do
    where(query, [job], fragment("(? ->> 'skill_lesson_reflection') = 'true'", job.metadata))
  end

  @doc """
  Excludes skill-lesson reflection Jobs, so user-facing listings and budgets
  see only real work.
  """
  @spec excluding_reflection_jobs(Ecto.Queryable.t()) :: Ecto.Query.t()
  def excluding_reflection_jobs(query) do
    where(
      query,
      [job],
      fragment("coalesce(? ->> 'skill_lesson_reflection', 'false') <> 'true'", job.metadata)
    )
  end
end
