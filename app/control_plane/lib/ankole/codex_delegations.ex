defmodule Ankole.CodexDelegations do
  @moduledoc """
  Durable audit store for Codex delegation runs.

  Agent Computer owns the Codex process. PostgreSQL owns the audit trail, so the
  worker reports every trajectory event through RuntimeFabric RPC and never
  writes this state directly.
  """

  import Ecto.Query

  alias Ecto.Adapters.SQL

  alias Ankole.CodexDelegations.Schemas.Delegation
  alias Ankole.CodexDelegations.Schemas.Event
  alias Ankole.Principals
  alias Ankole.Repo

  @max_running_per_agent 3
  @terminal_statuses ~w(succeeded failed stopped)
  @running_statuses ~w(running waiting_on_user)
  @sensitive_keys MapSet.new(~w(
                    authorization
                    api_key
                    openai_api_key
                    ankole_aigateway_api_key
                    access_token
                    refresh_token
                    id_token
                    auth_token
                    bearer_token
                    token
                    codex_access_token
                  ))

  @doc """
  Creates a Codex delegation audit header.
  """
  @spec create_delegation(map()) :: {:ok, Delegation.t()} | {:error, term()}
  def create_delegation(attrs) when is_map(attrs) do
    now = now()

    attrs =
      attrs
      |> normalize_keys()
      |> Map.put_new("status", "queued")
      |> Map.put_new("queued_at", now)
      |> Map.put_new("result", %{})
      |> Map.put_new("error", %{})
      |> Map.put_new("metadata", %{})

    %Delegation{}
    |> Delegation.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Updates one delegation lifecycle row.
  """
  @spec update_delegation(String.t(), String.t(), map()) ::
          {:ok, Delegation.t()} | {:error, term()}
  def update_delegation(delegation_id, agent_uid, attrs)
      when is_binary(delegation_id) and is_binary(agent_uid) and is_map(attrs) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid) do
      Repo.transact(fn repo ->
        with :ok <- lock_agent_slots(repo, agent_uid),
             %Delegation{} = delegation <-
               get_delegation_for_agent(repo, delegation_id, agent_uid, lock: "FOR UPDATE"),
             attrs <- normalize_keys(attrs),
             :ok <- enforce_terminal_guard(delegation, attrs),
             :ok <- enforce_running_limit(repo, delegation, attrs) do
          delegation
          |> Delegation.changeset(
            attrs
            |> preserve_metadata(delegation)
            |> lifecycle_timestamps(delegation)
          )
          |> repo.update()
        else
          nil -> {:error, :delegation_not_found}
          {:error, _reason} = error -> error
        end
      end)
    end
  end

  @doc """
  Appends one full trajectory event after deterministic secret redaction.
  """
  @spec append_event(map()) :: {:ok, Event.t()} | {:error, term()}
  def append_event(attrs) when is_map(attrs) do
    attrs = normalize_keys(attrs)

    with {:ok, agent_uid} <- Principals.normalize_uid(text(attrs, "agent_uid")),
         %Delegation{} = delegation <-
           get_delegation_for_agent(text(attrs, "delegation_id"), agent_uid) do
      {payload, redaction} =
        attrs
        |> Map.get("payload", %{})
        |> redact_payload()

      event_attrs =
        attrs
        |> Map.put("agent_uid", agent_uid)
        |> Map.put("delegation_id", delegation.id)
        |> Map.put("payload", payload)
        |> Map.put("redaction", merge_redaction(Map.get(attrs, "redaction"), redaction))
        |> Map.put_new("occurred_at", now())

      event_changeset = Event.changeset(%Event{}, event_attrs)

      case Repo.insert(event_changeset) do
        {:ok, %Event{} = event} ->
          {:ok, event}

        {:error, %Ecto.Changeset{} = changeset} ->
          handle_append_conflict(changeset, delegation.id, Map.get(event_attrs, "seq"))
      end
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp handle_append_conflict(changeset, delegation_id, seq) do
    if delegation_seq_conflict?(changeset) do
      case Repo.get_by(Event, delegation_id: delegation_id, seq: seq) do
        %Event{} = event -> {:ok, event}
        nil -> {:error, changeset}
      end
    else
      {:error, changeset}
    end
  end

  defp delegation_seq_conflict?(%Ecto.Changeset{errors: errors}) do
    Enum.any?(errors, fn
      {_field, {_message, opts}} ->
        opts[:constraint] == :unique and
          to_string(opts[:constraint_name]) == "codex_delegation_events_delegation_seq_index"

      _error ->
        false
    end)
  end

  @doc """
  Fetches one delegation for tests, operators, and RPC status projection.
  """
  @spec get_delegation_for_agent(String.t() | nil, String.t()) :: Delegation.t() | nil
  def get_delegation_for_agent(nil, _agent_uid), do: nil

  def get_delegation_for_agent(delegation_id, agent_uid)
      when is_binary(delegation_id) and is_binary(agent_uid) do
    get_delegation_for_agent(Repo, delegation_id, agent_uid, [])
  end

  defp get_delegation_for_agent(repo, delegation_id, agent_uid, opts)
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

  defp maybe_lock(query, nil), do: query
  defp maybe_lock(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")

  @doc """
  Fetches one delegation with its latest trajectory sequence.
  """
  @spec get_delegation_summary_for_agent(String.t(), String.t()) ::
          {:ok, %{delegation: Delegation.t(), last_event_seq: integer() | nil}} | {:error, term()}
  def get_delegation_summary_for_agent(delegation_id, agent_uid)
      when is_binary(delegation_id) and is_binary(agent_uid) do
    with {:ok, agent_uid} <- Principals.normalize_uid(agent_uid),
         %Delegation{} = delegation <- get_delegation_for_agent(delegation_id, agent_uid) do
      last_event_seq =
        Repo.one(
          from event in Event,
            where: event.delegation_id == ^delegation.id,
            select: max(event.seq)
        )

      {:ok, %{delegation: delegation, last_event_seq: last_event_seq}}
    else
      nil -> {:error, :delegation_not_found}
      {:error, _reason} = error -> error
    end
  end

  defp lock_agent_slots(repo, agent_uid) do
    lock_key = "codex_delegations:running_slots:#{agent_uid}"

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
        {:error, {:codex_agent_running_limit_exceeded, @max_running_per_agent}}
    end
  end

  defp enforce_terminal_guard(%Delegation{status: status}, attrs)
       when status in @terminal_statuses do
    case Map.get(attrs, "status") do
      nil -> :ok
      ^status -> :ok
      _status -> {:error, :codex_delegation_terminal}
    end
  end

  defp enforce_terminal_guard(%Delegation{}, _attrs), do: :ok

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

  @doc """
  Lists trajectory events for one delegation in sequence order.
  """
  @spec list_events(String.t()) :: [Event.t()]
  def list_events(delegation_id) when is_binary(delegation_id) do
    Repo.all(
      from event in Event,
        where: event.delegation_id == ^delegation_id,
        order_by: [asc: event.seq]
    )
  end

  defp lifecycle_timestamps(attrs, delegation) do
    case Map.get(attrs, "status") do
      status when status in @running_statuses ->
        Map.put_new(attrs, "started_at", delegation.started_at || now())

      status when status in @terminal_statuses ->
        attrs
        |> Map.put_new("started_at", delegation.started_at || now())
        |> Map.put_new("completed_at", now())

      _status ->
        attrs
    end
  end

  @doc """
  Fails running Codex delegations owned by one worker route.
  """
  @spec fail_worker_route_delegations(module(), String.t() | nil, DateTime.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def fail_worker_route_delegations(_repo, route, _now, _worker_status)
      when not is_binary(route) or route == "",
      do: {:ok, 0}

  def fail_worker_route_delegations(repo, route, %DateTime{} = now, worker_status)
      when is_binary(worker_status) do
    delegations =
      repo.all(
        from delegation in Delegation,
          where: delegation.status in ^@running_statuses,
          where: fragment("?->>? = ?", delegation.metadata, "worker_route", ^route),
          lock: "FOR UPDATE"
      )

    delegations
    |> Enum.reduce_while({:ok, 0}, fn delegation, {:ok, count} ->
      error = %{
        "code" => "owner_worker_stale",
        "reason" => "Codex delegation owner worker is no longer live",
        "worker_route" => route,
        "worker_status" => worker_status
      }

      attrs = %{
        "status" => "failed",
        "started_at" => delegation.started_at || now,
        "completed_at" => now,
        "error" => error
      }

      case delegation |> Delegation.changeset(attrs) |> repo.update() do
        {:ok, _delegation} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp redact_payload(payload) when is_map(payload) do
    {redacted, paths} = redact_value(payload, [])

    redaction =
      case paths do
        [] -> %{}
        paths -> %{"redacted_paths" => Enum.reverse(paths)}
      end

    {redacted, redaction}
  end

  defp redact_payload(_payload), do: {%{"value" => nil}, %{"redacted_paths" => ["$"]}}

  defp redact_value(%{} = value, path) do
    Enum.reduce(value, {%{}, []}, fn {key, nested}, {acc, paths} ->
      key_text = to_string(key)
      next_path = path ++ [key_text]

      if sensitive_key?(key_text) do
        redacted = redacted_value(nested)
        {Map.put(acc, key_text, redacted), [json_path(next_path) | paths]}
      else
        {redacted, nested_paths} = redact_value(nested, next_path)
        {Map.put(acc, key_text, redacted), nested_paths ++ paths}
      end
    end)
  end

  defp redact_value(values, path) when is_list(values) do
    {values, indexed_paths, _index} =
      Enum.reduce(values, {[], [], 0}, fn nested, {acc, paths, index} ->
        {redacted, nested_paths} = redact_value(nested, path ++ [Integer.to_string(index)])
        {[redacted | acc], nested_paths ++ paths, index + 1}
      end)

    {Enum.reverse(values), indexed_paths}
  end

  defp redact_value(value, _path), do: {value, []}

  defp sensitive_key?(key) do
    normalized = key |> String.downcase() |> String.replace("-", "_")
    MapSet.member?(@sensitive_keys, normalized)
  end

  defp redacted_value(value) do
    digest =
      value
      |> inspect(limit: :infinity, printable_limit: :infinity)
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "[REDACTED:sha256=#{digest}]"
  end

  defp merge_redaction(existing, generated) when is_map(existing) and map_size(generated) > 0,
    do: Map.merge(existing, generated)

  defp merge_redaction(existing, _generated) when is_map(existing), do: existing
  defp merge_redaction(_existing, generated), do: generated

  defp json_path(parts) do
    "$." <> Enum.join(parts, ".")
  end

  defp normalize_keys(map) when is_map(map) do
    Map.new(map, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), value}
      {key, value} -> {key, value}
    end)
  end

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp now, do: DateTime.utc_now(:microsecond)
end
