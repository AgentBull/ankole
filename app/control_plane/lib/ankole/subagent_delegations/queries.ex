defmodule Ankole.SubagentDelegations.Queries do
  @moduledoc false

  import Ecto.Query

  alias Ankole.Principals
  alias Ankole.Repo
  alias Ankole.SubagentDelegations.Schemas.Delegation
  alias Ankole.SubagentDelegations.Schemas.Event

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

      {:ok, %{delegations: page, next_cursor: next_cursor}}
    end
  end

  @spec get(String.t()) :: Delegation.t() | nil
  def get(delegation_id) when is_binary(delegation_id) do
    case Ecto.UUID.cast(delegation_id) do
      {:ok, delegation_id} -> Repo.get(Delegation, delegation_id)
      :error -> nil
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

  @spec get_summary_for_agent(String.t(), String.t()) ::
          {:ok,
           %{
             delegation: Delegation.t(),
             last_event_seq: integer() | nil,
             attempt_history: [map()]
           }}
          | {:error, term()}
  def get_summary_for_agent(delegation_id, agent_uid)
      when is_binary(delegation_id) and is_binary(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         %Delegation{} = delegation <- get_for_agent(delegation_id, agent_uid) do
      last_event_seq =
        Repo.one(
          from event in Event,
            where: event.delegation_id == ^delegation.id,
            select: max(event.seq)
        )

      {:ok,
       %{
         delegation: delegation,
         last_event_seq: last_event_seq,
         attempt_history: attempt_history(delegation)
       }}
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp attempt_history(%Delegation{attempts: attempts}) when attempts <= 1, do: []

  defp attempt_history(%Delegation{} = delegation) do
    Event
    |> where([event], event.delegation_id == ^delegation.id)
    |> order_by([event], desc: event.seq)
    |> limit(80)
    |> select([event], %{event_type: event.event_type, payload: event.payload})
    |> Repo.all()
    |> Enum.reduce(%{}, fn event, history ->
      case event.payload["attempt"] do
        attempt when is_integer(attempt) and attempt < delegation.attempts ->
          Map.update(history, attempt, attempt_summary(attempt, event), fn summary ->
            merge_attempt_event(summary, event)
          end)

        _value ->
          history
      end
    end)
    |> Map.values()
    |> Enum.sort_by(& &1.attempt, :desc)
    |> Enum.take(3)
    |> Enum.reverse()
  end

  defp attempt_summary(attempt, event) do
    %{
      attempt: attempt,
      event_types: [event.event_type]
    }
    |> maybe_put_attempt_summary(event_summary(event.payload))
  end

  defp merge_attempt_event(summary, event) do
    summary
    |> Map.update!(:event_types, fn event_types ->
      if event.event_type in event_types or length(event_types) >= 8 do
        event_types
      else
        event_types ++ [event.event_type]
      end
    end)
    |> maybe_put_attempt_summary(event_summary(event.payload))
  end

  defp event_summary(payload) do
    get_in(payload, ["result", "summary"]) ||
      get_in(payload, ["error", "summary"]) ||
      Map.get(payload, "summary")
  end

  defp maybe_put_attempt_summary(summary, value) when is_binary(value) do
    Map.put_new(summary, :summary, String.slice(value, 0, 1_000))
  end

  defp maybe_put_attempt_summary(summary, _value), do: summary

  @spec list_events(String.t()) :: [Event.t()]
  def list_events(delegation_id) when is_binary(delegation_id) do
    Repo.all(
      from event in Event,
        where: event.delegation_id == ^delegation_id,
        order_by: [asc: event.seq]
    )
  end

  @spec console_projection(Delegation.t()) :: map()
  def console_projection(%Delegation{} = delegation) do
    %{
      id: delegation.id,
      agent_uid: delegation.agent_uid,
      session_id: delegation.session_id,
      runtime: delegation.runtime,
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

  @spec console_event_projection(Event.t()) :: map()
  def console_event_projection(%Event{} = event) do
    %{
      id: event.id,
      seq: event.seq,
      direction: event.direction,
      event_type: event.event_type,
      payload: event.payload || %{},
      redaction: event.redaction || %{},
      occurred_at: iso8601(event.occurred_at)
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
  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")
  defp now, do: DateTime.utc_now(:microsecond)
end
