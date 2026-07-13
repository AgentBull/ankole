defmodule Ankole.Brain.Recall.Request do
  @moduledoc false

  alias Ankole.Brain.Scope

  @default_browse_limit 20
  @max_browse_limit 50

  @spec search(Scope.t(), map(), map()) :: {:ok, map()} | {:error, term()}
  def search(%Scope{} = scope, attrs, %{"result_limit" => configured_limit}) do
    with {:ok, query} <- required_text(attrs, "query"),
         {:ok, layer} <- enum(attrs, "layer", "all", ~w(chat knowledge all)),
         {:ok, channel_scope} <-
           enum(attrs, "channel_scope", "current_channel", ~w(current_channel all_channels)),
         {:ok, limit} <- bounded_limit(attrs, configured_limit),
         {:ok, time_range} <- time_range(attrs),
         {:ok, store_keys} <- store_keys(scope, text(attrs, "store")),
         {:ok, entry_type} <- optional_text(attrs, "entry_type"),
         {:ok, author_kind} <-
           optional_enum(attrs, "author_kind", ~w(human agent dreaming)) do
      {:ok,
       %{
         query: query,
         layer: layer,
         channel_scope: channel_scope,
         requested_channel_id: text(attrs, "channel_id"),
         actor_event: map(attrs, "actor_event"),
         limit: limit,
         time_range: time_range,
         store_keys: store_keys,
         entry_type: entry_type,
         author_kind: author_kind
       }}
    end
  end

  @spec browse(map()) :: {:ok, map()} | {:error, term()}
  def browse(attrs) do
    with {:ok, limit} <- browse_limit(attrs),
         {:ok, time_range} <- time_range(attrs),
         {:ok, cursor} <- browse_cursor(attrs) do
      {:ok,
       %{
         document_id: text(attrs, "document_id"),
         channel_id: text(attrs, "channel_id"),
         limit: limit,
         time_range: time_range,
         cursor: cursor
       }}
    end
  end

  defp store_keys(%Scope{readable_store_keys: :all}, nil), do: {:ok, :all}
  defp store_keys(%Scope{readable_store_keys: :all}, "current"), do: {:error, :no_current_store}
  defp store_keys(%Scope{readable_store_keys: :all}, "public"), do: {:ok, ["public"]}

  defp store_keys(%Scope{} = scope, nil), do: {:ok, scope.readable_store_keys}

  defp store_keys(%Scope{writable_store_key: store_key}, "current") when is_binary(store_key),
    do: {:ok, [store_key]}

  defp store_keys(%Scope{readable_store_keys: readable}, "public") when is_list(readable) do
    if "public" in readable, do: {:ok, ["public"]}, else: {:error, :brain_store_not_readable}
  end

  defp store_keys(_scope, store), do: {:error, {:invalid_store, store}}

  defp bounded_limit(attrs, configured_limit) do
    case integer(attrs, "limit") || configured_limit do
      limit when is_integer(limit) and limit > 0 -> {:ok, min(limit, configured_limit)}
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp browse_limit(attrs) do
    case integer(attrs, "limit") || @default_browse_limit do
      limit when is_integer(limit) and limit > 0 -> {:ok, min(limit, @max_browse_limit)}
      _invalid -> {:error, :invalid_limit}
    end
  end

  defp browse_cursor(attrs) do
    case text(attrs, "cursor") do
      nil ->
        {:ok, nil}

      cursor ->
        case String.split(cursor, "|", parts: 2) do
          [iso, document_id] ->
            case DateTime.from_iso8601(iso) do
              {:ok, datetime, _offset} -> {:ok, {datetime, document_id}}
              _invalid -> {:error, :invalid_cursor}
            end

          _parts ->
            {:error, :invalid_cursor}
        end
    end
  end

  defp time_range(attrs) do
    with {:ok, from} <- optional_datetime(attrs, "from"),
         {:ok, to} <- optional_datetime(attrs, "to"),
         :ok <- validate_time_range(from, to) do
      {:ok, {from, to}}
    end
  end

  defp validate_time_range(nil, _to), do: :ok
  defp validate_time_range(_from, nil), do: :ok

  defp validate_time_range(from, to) do
    if DateTime.compare(from, to) in [:lt, :eq], do: :ok, else: {:error, :invalid_time_range}
  end

  defp optional_datetime(attrs, key) do
    case text(attrs, key) do
      nil ->
        {:ok, nil}

      value ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} -> {:ok, datetime}
          {:error, _reason} -> {:error, {:invalid_datetime, key}}
        end
    end
  end

  defp enum(attrs, key, default, values) do
    case text(attrs, key) || default do
      value ->
        if value in values,
          do: {:ok, value},
          else: {:error, {:invalid_enum, key, value}}
    end
  end

  defp optional_enum(attrs, key, values) do
    case text(attrs, key) do
      nil ->
        {:ok, nil}

      value ->
        if value in values,
          do: {:ok, value},
          else: {:error, {:invalid_enum, key, value}}
    end
  end

  defp required_text(attrs, key) do
    case text(attrs, key) do
      value when is_binary(value) -> {:ok, value}
      nil -> {:error, {:missing, key}}
    end
  end

  defp optional_text(attrs, key), do: {:ok, text(attrs, key)}

  defp text(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          trimmed -> trimmed
        end

      _value ->
        nil
    end
  end

  defp integer(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp map(attrs, key) do
    case Map.get(attrs, key) || Map.get(attrs, String.to_atom(key)) do
      value when is_map(value) -> value
      _value -> %{}
    end
  end
end
