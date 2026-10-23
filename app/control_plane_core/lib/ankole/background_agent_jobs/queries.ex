defmodule Ankole.BackgroundAgentJobs.Queries do
  @moduledoc """
  Normalizes the parameters of the Job read actions and projects their rows.

  The Job resource owns the list reads (`console_list`, `list_for_agent`,
  `ambient_candidates`, `live_for_owner_sessions`). This module validates the
  caller parameters, converts the opaque list cursors to the keyset of the read
  action, and projects records into the Console and tool contracts.
  """

  require Ash.Query
  require Ankole.ModelIntegerID

  alias Ankole.BackgroundAgentJobs.JobState
  alias Ankole.BackgroundAgentJobs.Schemas.Job
  alias Ankole.BackgroundAgentJobs.Turns
  alias Ankole.Principals
  alias Ankole.Repo

  @cursor_version "2"
  @list_page_size 32
  @ambient_candidate_limit 8
  @list_status_groups %{"live" => :live, "stop" => :stop}
  @result_read_columns [
    :id,
    :task,
    :agent_uid,
    :owner_session_id,
    :status,
    :title,
    :reply_route,
    :workspace_owner_job_id
  ]
  @result_path_keys ~w(project_path artifacts artifact_roots)
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
         {:ok, keyset} <- decode_cursor(Keyword.get(opts, :cursor), [status]),
         {:ok, page} <-
           Job
           |> Ash.Query.for_read(:list_for_agent, %{
             agent_uid: agent_uid,
             status_group: Map.fetch!(@list_status_groups, status)
           })
           |> Ash.Query.select([:id, :title, :status, :updated_at])
           |> Ankole.Ash.read(page: page_options(@list_page_size, keyset)) do
      {:ok,
       %{
         jobs: Enum.map(page.results, &list_projection/1),
         next_cursor: next_cursor(page, [status])
       }}
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
        _repo,
        agent_uid,
        owner_session_id,
        conversation_id,
        binding_name
      )
      when is_binary(agent_uid) and is_binary(owner_session_id) and
             is_binary(conversation_id) and is_binary(binding_name) do
    rows =
      Job
      |> Ash.Query.for_read(:ambient_candidates, %{
        agent_uid: agent_uid,
        owner_session_id: owner_session_id,
        conversation_id: conversation_id,
        binding_name: binding_name
      })
      |> Ash.Query.select([:id, :title, :status])
      |> Ash.Query.load(:task_excerpt)
      |> Ash.Query.limit(@ambient_candidate_limit + 1)
      |> Ankole.Ash.read!()

    %{
      complete: length(rows) <= @ambient_candidate_limit,
      jobs:
        rows
        |> Enum.take(@ambient_candidate_limit)
        |> Enum.map(
          &%{job_id: &1.id, title: &1.title, status: &1.status, task_excerpt: &1.task_excerpt}
        )
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
  @activity_columns [:owner_session_id, :source_signal_id, :updated_at]

  @spec list_for_console(keyword()) ::
          {:ok, %{jobs: [Job.t()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_for_console(opts \\ []) when is_list(opts) do
    activity? = Keyword.get(opts, :activity, false)

    with {:ok, agent_uid} <- console_agent_uid(Keyword.get(opts, :agent_uid)),
         {:ok, status} <- console_status(Keyword.get(opts, :status)),
         {:ok, search} <- console_search(Keyword.get(opts, :search)),
         {:ok, keyset} <- decode_cursor(Keyword.get(opts, :cursor), []),
         {:ok, page} <-
           Job
           |> Ash.Query.for_read(:console_list, %{
             agent_uid: agent_uid,
             status: status,
             search: search,
             live_only: activity?
           })
           |> load_activity(activity?)
           |> Ankole.Ash.read(
             page: page_options(opts |> Keyword.get(:limit, 50) |> max(1) |> min(100), keyset)
           ) do
      {:ok, %{jobs: page.results, next_cursor: next_cursor(page, [])}}
    end
  end

  defp load_activity(query, false), do: query
  defp load_activity(query, true), do: Ash.Query.load(query, [:error_code, :error_summary])

  @doc "Reads live background Jobs without task, trajectory or result payloads."
  def list_activity(agent_uid, opts \\ []) do
    with {:ok, page} <-
           list_for_console(Keyword.merge(opts, agent_uid: agent_uid, activity: true)) do
      {:ok,
       %{
         page
         | jobs:
             Enum.map(page.jobs, fn row ->
               row
               |> Map.take([
                 :id,
                 :agent_uid,
                 :title,
                 :status,
                 :owner_session_id,
                 :source_signal_id,
                 :attempts,
                 :error_code,
                 :error_summary,
                 :queued_at,
                 :started_at,
                 :updated_at
               ])
               |> Map.put(:status, to_string(row.status))
               |> Map.put(:resource_kind, "background_job")
             end)
       }}
    end
  end

  @doc """
  Applies the parameters of the `console_list` read action. It reads only the
  list columns, and the activity columns for `live_only`.
  """
  def prepare_console_list(%Ash.Query{arguments: arguments} = query) do
    query
    |> Ash.Query.select(console_columns(arguments[:live_only]))
    |> filter_present(arguments[:agent_uid], fn query, uid ->
      Ash.Query.filter(query, agent_uid == ^uid)
    end)
    |> filter_present(arguments[:status], fn query, status ->
      Ash.Query.filter(query, status == ^status)
    end)
    |> filter_present(arguments[:live_only] && Job.live_statuses(), fn query, statuses ->
      Ash.Query.filter(query, status in ^statuses)
    end)
    |> filter_present(arguments[:search], &filter_search/2)
    |> Ash.Query.sort(queued_at: :desc, id: :desc)
  end

  @doc "Applies the parameters of the `list_for_agent` read action."
  def prepare_agent_list(%Ash.Query{arguments: arguments} = query) do
    statuses =
      case arguments.status_group do
        :live -> Job.live_statuses()
        :stop -> JobState.terminal_statuses()
      end

    query
    |> Ash.Query.filter(agent_uid == ^arguments.agent_uid and status in ^statuses)
    |> Ash.Query.sort(updated_at: :desc, id: :desc)
  end

  defp console_columns(true), do: @console_list_columns ++ @activity_columns
  defp console_columns(_live_only), do: @console_list_columns

  defp filter_present(query, value, _filter) when value in [nil, false], do: query
  defp filter_present(query, value, filter), do: filter.(query, value)

  defp filter_search(query, search) do
    pattern = "%#{Repo.escape_like(search)}%"

    case Ankole.ModelIntegerID.parse(search) do
      {:ok, id} -> Ash.Query.filter(query, id == ^id or ilike(title, ^pattern))
      _not_an_id -> Ash.Query.filter(query, ilike(title, ^pattern))
    end
  end

  @spec get(pos_integer()) :: Job.t() | nil
  def get(job_id) when Ankole.ModelIntegerID.valid?(job_id) do
    Job
    |> Ash.Query.filter(id == ^job_id)
    |> Ankole.Ash.read_one!()
  end

  @doc "Lists live Job ids owned by any of the given Sessions."
  @spec live_job_ids_for_owner_sessions([String.t()], String.t()) :: [pos_integer()]
  def live_job_ids_for_owner_sessions([], _agent_uid), do: []

  def live_job_ids_for_owner_sessions(session_ids, agent_uid)
      when is_list(session_ids) and is_binary(agent_uid) do
    Job
    |> Ash.Query.for_read(:live_for_owner_sessions, %{
      agent_uid: agent_uid,
      owner_session_ids: session_ids
    })
    |> Ash.Query.select([:id])
    |> Ankole.Ash.read!()
    |> Enum.map(& &1.id)
  end

  @spec get_for_agent(pos_integer() | nil, String.t()) :: Job.t() | nil
  def get_for_agent(nil, _agent_uid), do: nil

  def get_for_agent(job_id, agent_uid)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) do
    Job
    |> Ash.Query.filter(id == ^job_id and agent_uid == ^agent_uid)
    |> Ankole.Ash.read_one!()
  end

  @doc "Locks one Job of an Agent inside the caller's transaction."
  @spec lock_for_agent_in_tx(pos_integer(), String.t()) :: Job.t() | nil
  def lock_for_agent_in_tx(job_id, agent_uid)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) do
    Job
    |> Ash.Query.filter(id == ^job_id and agent_uid == ^agent_uid)
    |> Ash.Query.lock(:for_update)
    |> Ankole.Ash.read_one!(lock_identity: {"background_agent_jobs", job_id})
  end

  @doc """
  Reads one bounded window of the persisted result text together with the
  result's path fields, without loading the full result document.
  """
  @spec get_result_window_for_agent(pos_integer(), String.t(), non_neg_integer()) ::
          %{
            job: Job.t(),
            output_window: binary() | nil,
            total_bytes: non_neg_integer() | nil,
            result_paths: map()
          }
          | nil
  def get_result_window_for_agent(job_id, agent_uid, offset)
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and is_integer(offset) and
             offset >= 0 do
    Job
    |> Ash.Query.filter(id == ^job_id and agent_uid == ^agent_uid)
    |> Ash.Query.select(@result_read_columns)
    |> Ash.Query.load(
      result_output_window: %{from: offset + 1, bytes: @result_window_bytes},
      result_output_bytes: %{},
      result_fields: %{}
    )
    |> Ankole.Ash.read_one!()
    |> case do
      %Job{} = job ->
        %{
          job: job,
          output_window: job.result_output_window,
          total_bytes: job.result_output_bytes,
          result_paths: Map.take(job.result_fields, @result_path_keys)
        }

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
      when Ankole.ModelIntegerID.valid?(job_id) and is_binary(agent_uid) and is_list(opts) do
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

  defp list_status(nil), do: {:ok, "live"}
  defp list_status(""), do: {:ok, "live"}
  defp list_status(status) when is_map_key(@list_status_groups, status), do: {:ok, status}
  defp list_status(_status), do: {:error, :invalid_background_agent_job_list_status}

  defp page_options(limit, nil), do: [limit: limit]
  defp page_options(limit, keyset), do: [limit: limit, after: keyset]

  # A cursor carries its version, the parameters it belongs to, and the keyset
  # of the last row of its page. A cursor of another list or status is invalid.
  defp next_cursor(%{more?: true, results: [_ | _] = results}, scope) do
    keyset = List.last(results).__metadata__.keyset

    [@cursor_version | scope]
    |> Kernel.++([keyset])
    |> Enum.join("|")
    |> Base.url_encode64(padding: false)
  end

  defp next_cursor(_page, _scope), do: nil

  defp decode_cursor(nil, _scope), do: {:ok, nil}
  defp decode_cursor("", _scope), do: {:ok, nil}

  defp decode_cursor(cursor, scope) when is_binary(cursor) do
    expected = Enum.join([@cursor_version | scope], "|") <> "|"

    with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
         ^expected <> keyset when keyset != "" <- decoded do
      {:ok, keyset}
    else
      _reason -> {:error, :invalid_background_agent_job_cursor}
    end
  end

  defp decode_cursor(_cursor, _scope), do: {:error, :invalid_background_agent_job_cursor}

  defp list_projection(%Job{} = job) do
    %{
      job_id: job.id,
      title: job.title,
      status: Atom.to_string(job.status)
    }
  end

  defp console_agent_uid(nil), do: {:ok, nil}
  defp console_agent_uid(""), do: {:ok, nil}
  defp console_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp console_status(nil), do: {:ok, nil}
  defp console_status(""), do: {:ok, nil}

  defp console_status(status) do
    case JobState.cast_status(status) do
      {:ok, cast} -> {:ok, cast}
      :error -> {:error, :invalid_background_agent_job_status}
    end
  end

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
end
