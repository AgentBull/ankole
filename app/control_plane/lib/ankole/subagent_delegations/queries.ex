defmodule Ankole.SubagentDelegations.Queries do
  @moduledoc false

  import Ecto.Query

  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Turns

  @statuses Delegation.statuses()

  @spec list_for_channel(String.t(), String.t(), String.t() | nil) :: [Delegation.t()]
  def list_for_channel(agent_uid, session_id, signal_channel_id)
      when is_binary(agent_uid) and is_binary(session_id) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      Delegation
      |> where([delegation], delegation.agent_uid == ^agent_uid)
      |> visible_from_parent(session_id, signal_channel_id)
      |> order_by([delegation], desc: delegation.queued_at, desc: delegation.inserted_at)
      |> limit(100)
      |> Repo.all()
    else
      {:error, _reason} -> []
    end
  end

  @spec list_for_console(keyword()) ::
          {:ok, %{delegations: [Delegation.t()], next_cursor: String.t() | nil}}
          | {:error, term()}
  def list_for_console(opts \\ []) when is_list(opts) do
    with {:ok, agent_uid} <- console_agent_uid(Keyword.get(opts, :agent_uid)),
         {:ok, status} <- console_status(Keyword.get(opts, :status)),
         {:ok, cursor} <- decode_console_cursor(Keyword.get(opts, :cursor)) do
      limit = opts |> Keyword.get(:limit, 50) |> max(1) |> min(100)

      rows =
        Delegation
        |> maybe_filter_console_agent(agent_uid)
        |> maybe_filter_console_status(status)
        |> maybe_before_console_cursor(cursor)
        |> order_by([delegation], desc: delegation.queued_at, desc: delegation.id)
        |> limit(^(limit + 1))
        |> Repo.all()

      page = Enum.take(rows, limit)

      next_cursor =
        if length(rows) > limit do
          page |> List.last() |> encode_console_cursor()
        end

      {:ok,
       %{
         delegations: page,
         next_cursor: next_cursor,
         calibration_summary: calibration_summary(agent_uid)
       }}
    end
  end

  @spec get(String.t()) :: Delegation.t() | nil
  def get(delegation_id) when is_binary(delegation_id) do
    case Ecto.UUID.cast(delegation_id) do
      {:ok, delegation_id} ->
        Repo.get(Delegation, delegation_id)

      :error ->
        nil
    end
  end

  @spec get_for_agent(String.t() | nil, String.t()) :: Delegation.t() | nil
  def get_for_agent(nil, _agent_uid), do: nil

  def get_for_agent(delegation_id, agent_uid)
      when is_binary(delegation_id) and is_binary(agent_uid) do
    get_for_agent(Repo, delegation_id, agent_uid, [])
  end

  @doc false
  @spec get_for_agent(module(), String.t(), String.t(), keyword()) :: Delegation.t() | nil
  def get_for_agent(repo, delegation_id, agent_uid, opts)
      when is_binary(delegation_id) and is_binary(agent_uid) do
    case Ecto.UUID.cast(delegation_id) do
      {:ok, delegation_id} ->
        query =
          from delegation in Delegation,
            where: delegation.id == ^delegation_id and delegation.agent_uid == ^agent_uid

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
             delegation: Delegation.t(),
             execution: map(),
             attempt_history: [map()]
           }}
          | {:error, term()}
  def get_summary_for_agent(delegation_id, agent_uid, opts \\ [])
      when is_binary(delegation_id) and is_binary(agent_uid) and is_list(opts) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         %Delegation{} = delegation <- get_for_agent(delegation_id, agent_uid),
         {:ok, execution} <- Turns.execution_projection(delegation, opts) do
      {:ok,
       %{
         delegation: delegation,
         execution: execution,
         attempt_history: Turns.attempt_history(delegation),
         source_forecast: source_forecast(delegation)
       }}
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  @spec console_projection(Delegation.t()) :: map()
  def console_projection(%Delegation{} = delegation) do
    %{
      id: delegation.id,
      agent_uid: delegation.agent_uid,
      session_id: delegation.session_id,
      runtime: delegation.runtime,
      mode: delegation.mode,
      source_delegation_id: delegation.source_delegation_id,
      actual_outcome: delegation.actual_outcome,
      codex_account_id: delegation.codex_account_id,
      runtime_thread_id: delegation.runtime_thread_id,
      title: delegation.title,
      task: delegation.task,
      background: delegation.background,
      notes: delegation.notes,
      status: delegation.status,
      attempts: delegation.attempts,
      workdir: delegation.workdir,
      reply_route: delegation.reply_route || %{},
      result: delegation.result || %{},
      error: delegation.error || %{},
      metadata: delegation.metadata || %{},
      duration_seconds: duration_seconds(delegation),
      queued_at: iso8601(delegation.queued_at),
      started_at: iso8601(delegation.started_at),
      completed_at: iso8601(delegation.completed_at),
      inserted_at: iso8601(delegation.inserted_at),
      updated_at: iso8601(delegation.updated_at)
    }
  end

  defp visible_from_parent(query, session_id, signal_channel_id)
       when is_binary(signal_channel_id) and signal_channel_id != "" do
    where(
      query,
      [delegation],
      delegation.session_id == ^session_id or
        fragment("?->>'signal_channel_id' = ?", delegation.reply_route, ^signal_channel_id)
    )
  end

  defp visible_from_parent(query, session_id, _signal_channel_id) do
    where(query, [delegation], delegation.session_id == ^session_id)
  end

  defp console_agent_uid(nil), do: {:ok, nil}
  defp console_agent_uid(""), do: {:ok, nil}
  defp console_agent_uid(agent_uid), do: Principals.normalize_uid(agent_uid)

  defp console_status(nil), do: {:ok, nil}
  defp console_status(""), do: {:ok, nil}
  defp console_status(status) when status in @statuses, do: {:ok, status}
  defp console_status(_status), do: {:error, :invalid_subagent_status}

  defp maybe_filter_console_agent(query, nil), do: query

  defp maybe_filter_console_agent(query, agent_uid),
    do: where(query, [delegation], delegation.agent_uid == ^agent_uid)

  defp maybe_filter_console_status(query, nil), do: query

  defp maybe_filter_console_status(query, status),
    do: where(query, [delegation], delegation.status == ^status)

  defp maybe_before_console_cursor(query, nil), do: query

  defp maybe_before_console_cursor(query, {queued_at, id}) do
    where(
      query,
      [delegation],
      delegation.queued_at < ^queued_at or
        (delegation.queued_at == ^queued_at and delegation.id < ^id)
    )
  end

  defp encode_console_cursor(nil), do: nil

  defp encode_console_cursor(%Delegation{} = delegation) do
    "#{DateTime.to_iso8601(delegation.queued_at)}|#{delegation.id}"
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
      _reason -> {:error, :invalid_subagent_cursor}
    end
  end

  defp decode_console_cursor(_cursor), do: {:error, :invalid_subagent_cursor}

  defp duration_seconds(%Delegation{} = delegation) do
    case {delegation.started_at || delegation.queued_at, delegation.completed_at} do
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

  defp source_forecast(%Delegation{source_delegation_id: nil}), do: nil

  defp source_forecast(%Delegation{source_delegation_id: source_id, agent_uid: agent_uid}) do
    case get_for_agent(source_id, agent_uid) do
      %Delegation{runtime: "deep_research", mode: "forecast", status: "succeeded"} = source ->
        %{
          delegation_id: source.id,
          title: source.title,
          result: Map.take(source.result || %{}, ["dossier", "conclusion"]),
          completed_at: iso8601(source.completed_at)
        }

      _source ->
        nil
    end
  end

  defp calibration_summary(agent_uid) do
    forecast_query =
      Delegation
      |> where([delegation], delegation.runtime == "deep_research")
      |> where([delegation], delegation.mode == "forecast")
      |> where([delegation], delegation.status == "succeeded")
      |> maybe_filter_console_agent(agent_uid)

    forecast_count = Repo.aggregate(forecast_query, :count, :id)

    no_edge_count =
      forecast_query
      |> where(
        [delegation],
        fragment("?->'conclusion'->>'verdict' = 'no_edge'", delegation.result)
      )
      |> Repo.aggregate(:count, :id)

    resolved = resolved_forecast_calibration(agent_uid)
    brier_scores = Enum.map(resolved, & &1.brier_score)

    %{
      forecast_count: forecast_count,
      resolved_forecast_count: length(resolved),
      mean_brier_score: mean(brier_scores),
      confidence_buckets: confidence_buckets(resolved),
      no_edge_count: no_edge_count,
      no_edge_rate: ratio(no_edge_count, forecast_count)
    }
  end

  defp resolved_forecast_calibration(agent_uid) do
    Delegation
    |> join(:inner, [retrospect], forecast in Delegation,
      on: forecast.id == retrospect.source_delegation_id
    )
    |> where([retrospect, forecast], retrospect.runtime == "deep_research")
    |> where([retrospect, forecast], retrospect.mode == "retrospect")
    |> where([retrospect, forecast], retrospect.status == "succeeded")
    |> where([retrospect, forecast], forecast.runtime == "deep_research")
    |> where([retrospect, forecast], forecast.mode == "forecast")
    |> where([retrospect, forecast], forecast.status == "succeeded")
    |> maybe_filter_retrospect_agent(agent_uid)
    |> order_by([retrospect, _forecast],
      desc: retrospect.completed_at,
      desc: retrospect.id
    )
    |> select([retrospect, forecast], %{
      source_delegation_id: retrospect.source_delegation_id,
      retrospect_result: retrospect.result,
      forecast_result: forecast.result
    })
    |> Repo.all()
    |> Enum.uniq_by(& &1.source_delegation_id)
    |> Enum.flat_map(&calibration_observation/1)
  end

  defp maybe_filter_retrospect_agent(query, nil), do: query

  defp maybe_filter_retrospect_agent(query, agent_uid),
    do: where(query, [retrospect, _forecast], retrospect.agent_uid == ^agent_uid)

  defp calibration_observation(%{retrospect_result: retrospect, forecast_result: forecast}) do
    resolution = get_in(retrospect || %{}, ["conclusion"])
    source = get_in(forecast || %{}, ["conclusion"])
    probability = get_in(source || %{}, ["outcome_estimate", "probability"])
    actual_outcome = Map.get(resolution || %{}, "actual_outcome")
    confidence = Map.get(source || %{}, "confidence")
    verdict = Map.get(source || %{}, "verdict")

    if Map.get(resolution || %{}, "resolution_status") == "resolved" and
         is_boolean(actual_outcome) and is_number(probability) and probability >= 0 and
         probability <= 1 do
      expected_outcome = probability >= 0.5

      [
        %{
          brier_score:
            Float.round(:math.pow(probability - if(actual_outcome, do: 1, else: 0), 2), 6),
          confidence: if(is_integer(confidence) and confidence in 1..5, do: confidence),
          hit: verdict == "estimate" and expected_outcome == actual_outcome,
          scoreable_hit: verdict == "estimate"
        }
      ]
    else
      []
    end
  end

  defp confidence_buckets(observations) do
    observations
    |> Enum.filter(&(&1.scoreable_hit and is_integer(&1.confidence)))
    |> Enum.group_by(& &1.confidence)
    |> Enum.map(fn {confidence, bucket} ->
      hits = Enum.count(bucket, & &1.hit)

      %{
        confidence: confidence,
        forecasts: length(bucket),
        hits: hits,
        hit_rate: ratio(hits, length(bucket))
      }
    end)
    |> Enum.sort_by(& &1.confidence)
  end

  defp mean([]), do: nil
  defp mean(values), do: values |> Enum.sum() |> Kernel./(length(values)) |> Float.round(6)
  defp ratio(_numerator, 0), do: nil
  defp ratio(numerator, denominator), do: Float.round(numerator / denominator, 6)

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")
  defp now, do: DateTime.utc_now(:microsecond)
end
