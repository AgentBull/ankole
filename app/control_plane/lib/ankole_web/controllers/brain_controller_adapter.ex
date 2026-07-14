defmodule AnkoleWeb.BrainController.Adapter do
  @moduledoc false

  alias Ankole.Brain

  @author_kinds ~w(human agent dreaming)
  @server_owned_operation_keys ~w(
    owner_uid store_key author_kind author_uid actor_kind actor_uid
  )

  @spec list_entries(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def list_entries(owner_uid, params) do
    with {:ok, updated_after} <- optional_datetime(params, "updated"),
         {:ok, cursor} <- page_cursor(params),
         {:ok, limit} <- page_limit(params),
         {:ok, page} <-
           Brain.list_entries(
             owner_uid,
             list_entry_opts(params, updated_after, cursor, limit)
           ) do
      {:ok, %{entries: page.entries, next_cursor: encode_cursor(page.next_cursor)}}
    end
  end

  @spec open_entry(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def open_entry(owner_uid, entry_id) do
    Brain.open_entry(owner_uid, entry_id)
  end

  @spec apply_operations(String.t(), map(), map(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def apply_operations(owner_uid, params, body, actor_uid) do
    with {:ok, operations} <- operations(body),
         {:ok, result} <-
           Brain.apply_human_operations(
             owner_uid,
             operations,
             actor_uid,
             store_key: optional_text(params, "store")
           ) do
      {:ok, json_safe(result)}
    end
  end

  @spec list_audit(String.t(), map(), String.t() | nil) :: {:ok, map()} | {:error, term()}
  def list_audit(owner_uid, params, entry_id \\ nil) do
    with {:ok, inserted_after} <- optional_datetime(params, "inserted_after"),
         {:ok, inserted_before} <- optional_datetime(params, "inserted_before"),
         {:ok, cursor} <- page_cursor(params),
         {:ok, limit} <- page_limit(params),
         {:ok, page} <-
           Brain.list_audit(
             owner_uid,
             list_audit_opts(
               params,
               entry_id,
               inserted_after,
               inserted_before,
               cursor,
               limit
             )
           ) do
      {:ok, %{audit_log: page.audit_log, next_cursor: encode_cursor(page.next_cursor)}}
    end
  end

  @spec source(String.t()) :: {:ok, map()} | {:error, :not_found}
  def source(document_id) do
    with {:ok, source} <- Brain.resolve_source(document_id) do
      {:ok, %{source: source}}
    end
  end

  @spec restore_audit(String.t(), String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore_audit(owner_uid, audit_id, actor_uid) do
    with {:ok, restoration} <- Brain.restore_audit(owner_uid, audit_id, actor_uid) do
      {:ok, %{restoration: json_safe(restoration)}}
    end
  end

  @spec restore_audits(String.t(), map(), String.t()) :: {:ok, map()} | {:error, term()}
  def restore_audits(owner_uid, body, actor_uid) do
    with {:ok, audit_ids} <- audit_ids(body),
         {:ok, restoration} <- Brain.restore_audits(owner_uid, audit_ids, actor_uid) do
      {:ok, %{restoration: json_safe(restoration)}}
    end
  end

  @spec run_dreaming(String.t()) :: {:ok, map()} | {:error, term()}
  def run_dreaming(owner_uid) do
    with {:ok, result} <- Brain.run_dreaming(owner_uid) do
      {:ok, %{run: json_safe(result)}}
    end
  end

  @spec dreaming_fitness(String.t(), map()) :: {:ok, map()} | {:error, term()}
  def dreaming_fitness(owner_uid, params) do
    with {:ok, horizon_days} <- optional_positive_integer(params, "horizon_days"),
         {:ok, lookback_days} <- optional_positive_integer(params, "lookback_days"),
         opts =
           [horizon_days: horizon_days, lookback_days: lookback_days]
           |> Enum.reject(fn {_key, value} -> is_nil(value) end),
         {:ok, fitness} <- Brain.dreaming_fitness(owner_uid, opts) do
      {:ok, %{fitness: json_safe(fitness)}}
    end
  end

  @spec required_text(map(), String.t()) :: {:ok, String.t()} | {:error, {:missing, String.t()}}
  def required_text(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> {:error, {:missing, key}}
          text -> {:ok, text}
        end

      _value ->
        {:error, {:missing, key}}
    end
  end

  defp list_entry_opts(params, updated_after, cursor, limit) do
    author = optional_text(params, "author")

    [
      query: optional_text(params, "query"),
      type: optional_text(params, "type"),
      store_key: optional_text(params, "store"),
      author_kind: author_kind(author),
      author_uid: author_uid(author),
      updated_after: updated_after,
      cursor: cursor,
      limit: limit
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp list_audit_opts(params, entry_id, inserted_after, inserted_before, cursor, limit) do
    actor = optional_text(params, "actor")

    [
      entry_id: entry_id,
      store_key: optional_text(params, "store"),
      action: optional_text(params, "action"),
      actor_kind: author_kind(actor),
      actor_uid: author_uid(actor),
      run_id: optional_text(params, "run_id"),
      inserted_after: inserted_after,
      inserted_before: inserted_before,
      cursor: cursor,
      limit: limit
    ]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp author_kind("human"), do: :human
  defp author_kind("agent"), do: :agent
  defp author_kind("dreaming"), do: :dreaming
  defp author_kind(_author), do: nil

  defp author_uid(author) when is_binary(author) and author not in @author_kinds, do: author
  defp author_uid(_author), do: nil

  defp optional_positive_integer(params, key) do
    case param(params, key) do
      nil -> {:ok, nil}
      value when is_integer(value) and value > 0 -> {:ok, value}
      value when is_binary(value) -> parse_positive_integer(value, key)
      _invalid -> {:error, {:invalid_integer, key}}
    end
  end

  defp parse_positive_integer(value, key) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _invalid -> {:error, {:invalid_integer, key}}
    end
  end

  defp optional_datetime(params, key) do
    case optional_text(params, key) do
      nil ->
        {:ok, nil}

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, {:invalid_datetime, key}}
        end
    end
  end

  defp page_limit(params) do
    case param(params, "limit") do
      nil -> {:ok, 50}
      value when is_integer(value) and value in 1..100 -> {:ok, value}
      value when is_binary(value) -> parse_page_limit(value)
      _invalid -> {:error, :invalid_page_limit}
    end
  end

  defp parse_page_limit(value) do
    case Integer.parse(value) do
      {limit, ""} when limit in 1..100 -> {:ok, limit}
      _invalid -> {:error, :invalid_page_limit}
    end
  end

  defp page_cursor(params) do
    case optional_text(params, "cursor") do
      nil ->
        {:ok, nil}

      cursor ->
        with {:ok, decoded} <- Base.url_decode64(cursor, padding: false),
             [iso, id] <- String.split(decoded, "|", parts: 2),
             {:ok, datetime, _offset} <- DateTime.from_iso8601(iso),
             {:ok, id} <- Ecto.UUID.cast(id) do
          {:ok, {datetime, id}}
        else
          _invalid -> {:error, :invalid_page_cursor}
        end
    end
  end

  defp encode_cursor(nil), do: nil

  defp encode_cursor({datetime, id}) do
    Base.url_encode64("#{DateTime.to_iso8601(datetime)}|#{id}", padding: false)
  end

  defp operations(body) when is_map(body) do
    case param(body, "operations") do
      operations when is_list(operations) and operations != [] ->
        operations
        |> Enum.reduce_while({:ok, []}, fn
          operation, {:ok, acc} when is_map(operation) ->
            sanitized =
              operation
              |> stringify_keys()
              |> Map.drop(@server_owned_operation_keys)
              |> drop_create_nil_defaults()

            {:cont, {:ok, [sanitized | acc]}}

          _operation, _acc ->
            {:halt, {:error, :invalid_operations}}
        end)
        |> case do
          {:ok, sanitized} -> {:ok, Enum.reverse(sanitized)}
          {:error, reason} -> {:error, reason}
        end

      _value ->
        {:error, :invalid_operations}
    end
  end

  defp operations(_body), do: {:error, :invalid_operations}

  defp audit_ids(body) when is_map(body) do
    case param(body, "audit_ids") do
      ids when is_list(ids) and ids != [] ->
        if Enum.all?(ids, &is_binary/1), do: {:ok, ids}, else: {:error, :invalid_audit_selection}

      _invalid ->
        {:error, :invalid_audit_selection}
    end
  end

  defp audit_ids(_body), do: {:error, :invalid_audit_selection}

  defp drop_create_nil_defaults(%{"operation" => operation_name} = operation)
       when operation_name in ["create_entry", :create_entry] do
    Enum.reduce(["summary", "aliases", "properties"], operation, fn key, acc ->
      if Map.get(acc, key) == nil, do: Map.delete(acc, key), else: acc
    end)
  end

  defp drop_create_nil_defaults(operation), do: operation

  defp json_safe(nil), do: nil
  defp json_safe(value) when is_binary(value) or is_number(value) or is_boolean(value), do: value
  defp json_safe(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp json_safe(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp json_safe(value) when is_atom(value), do: Atom.to_string(value)
  defp json_safe(value) when is_list(value), do: Enum.map(value, &json_safe/1)

  defp json_safe(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {string_key(key), json_safe(item)} end)
  end

  defp json_safe(value), do: inspect(value)

  defp stringify_keys(value) do
    Map.new(value, fn {key, item} -> {string_key(key), item} end)
  end

  defp optional_text(params, key) do
    case param(params, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          text -> text
        end

      _value ->
        nil
    end
  end

  defp param(params, key) do
    case Map.fetch(params, key) do
      {:ok, value} ->
        value

      :error ->
        Enum.find_value(params, fn {candidate, value} ->
          if string_key(candidate) == key, do: {:found, value}
        end)
        |> case do
          {:found, value} -> value
          nil -> nil
        end
    end
  end

  defp string_key(key) when is_atom(key), do: Atom.to_string(key)
  defp string_key(key), do: to_string(key)
end
