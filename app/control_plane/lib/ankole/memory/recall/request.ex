defmodule Ankole.Memory.Recall.Request do
  @moduledoc false

  alias Ankole.Memory.Recall.Scope

  @default_browse_limit 20
  @max_browse_limit 50

  @doc false
  @spec search(map(), map()) :: {:ok, map()} | {:error, term()}
  def search(attrs, %{"default_limit" => _default, "max_limit" => _max} = recall_config) do
    with {:ok, query} <- required_text(attrs, "query"),
         {:ok, scope} <- search_scope(attrs),
         {:ok, context} <- Scope.resolve(attrs, scope),
         {:ok, limit} <- bounded_limit(attrs, recall_config),
         {:ok, time_range} <- time_range(attrs) do
      {:ok,
       Map.merge(context, %{
         query: query,
         scope: scope,
         limit: limit,
         time_range: time_range
       })}
    end
  end

  @doc false
  @spec browse(map()) :: {:ok, map()} | {:error, term()}
  def browse(attrs) do
    with {:ok, context} <- Scope.resolve(attrs, "permitted_context"),
         {:ok, signal_channel_id} <-
           browse_channel(attrs, context.current_channel_id, context.allowed_channels),
         {:ok, limit} <- browse_limit(attrs),
         {:ok, time_range} <- time_range(attrs),
         {:ok, cursor} <- browse_cursor(attrs) do
      {:ok,
       %{
         signal_channel_id: signal_channel_id,
         limit: limit,
         time_range: time_range,
         cursor: cursor
       }}
    end
  end

  defp browse_channel(%{"channel_id" => channel_id}, _current_channel_id, allowed_channels)
       when is_binary(channel_id) do
    case channel_id in allowed_channels do
      true -> {:ok, channel_id}
      false -> {:error, :memory_channel_not_permitted}
    end
  end

  defp browse_channel(_attrs, nil, _allowed_channels), do: {:error, :missing_current_channel}

  defp browse_channel(_attrs, current_channel_id, _allowed_channels),
    do: {:ok, current_channel_id}

  defp browse_cursor(attrs) do
    case text(attrs, "cursor") do
      nil ->
        {:ok, nil}

      cursor ->
        case String.split(cursor, "|", parts: 2) do
          [iso, source_entry_id] ->
            with {:ok, datetime, _offset} <- DateTime.from_iso8601(iso) do
              {:ok, {datetime, source_entry_id}}
            end

          _parts ->
            {:error, :invalid_cursor}
        end
    end
  end

  defp required_text(map, key) do
    case text(map, key) do
      value when is_binary(value) -> {:ok, value}
      _value -> {:error, {:missing, key}}
    end
  end

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

  defp search_scope(attrs) do
    case text(attrs, "scope") || "permitted_context" do
      scope when scope in ["current_channel", "permitted_context"] -> {:ok, scope}
      _scope -> {:error, :invalid_memory_search_scope}
    end
  end

  defp bounded_limit(attrs, %{"default_limit" => default_limit, "max_limit" => max_limit}) do
    limit = integer(attrs, "limit") || default_limit

    cond do
      limit < 1 -> {:error, :invalid_limit}
      limit > max_limit -> {:ok, max_limit}
      true -> {:ok, limit}
    end
  end

  defp browse_limit(attrs) do
    limit = integer(attrs, "limit") || @default_browse_limit

    cond do
      limit < 1 -> {:error, :invalid_limit}
      limit > @max_browse_limit -> {:ok, @max_browse_limit}
      true -> {:ok, limit}
    end
  end

  defp integer(map, key) do
    case Map.get(map, key) || Map.get(map, String.to_atom(key)) do
      value when is_integer(value) -> value
      _value -> nil
    end
  end

  defp time_range(attrs) do
    with {:ok, from} <- optional_datetime(attrs, "from"),
         {:ok, to} <- optional_datetime(attrs, "to") do
      {:ok, {from, to}}
    end
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
end
